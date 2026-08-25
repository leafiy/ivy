import Attachment from '../models/attachment.model.js';
import { apiError, requireString } from '../middleware/validate.js';
import {
  ATTACHMENT_LIMIT_BYTES,
  getStorageUsage,
  releaseAttachmentQuota,
  reserveAttachmentQuota,
} from '../services/quota.js';
import { getDirectUploadAuthorization } from '../services/uploader.js';

const FILES_ORIGIN = 'https://files.qiansmile.com';

const attachmentPath = (user) => `ivy/${user._id.toString()}/attachments`;

const registeredFile = (value, index, filePath) => {
  if (!value || typeof value !== 'object') {
    throw apiError(422, 'FILE_INVALID', `files[${index}] is invalid.`);
  }

  const url = requireString(value.url, `files[${index}].url`);
  let parsedURL;
  try {
    parsedURL = new URL(url);
  } catch {
    throw apiError(422, 'FILE_URL_INVALID', `files[${index}].url is invalid.`);
  }
  if (parsedURL.origin !== FILES_ORIGIN || !parsedURL.pathname.startsWith(`/${filePath}/`)) {
    throw apiError(422, 'FILE_URL_INVALID', `files[${index}].url is outside this account's upload path.`);
  }

  const sizeBytes = Number(value.sizeBytes);
  if (!Number.isSafeInteger(sizeBytes) || sizeBytes < 0 || sizeBytes > ATTACHMENT_LIMIT_BYTES) {
    throw apiError(422, 'ATTACHMENT_SIZE_INVALID', `files[${index}].sizeBytes is invalid.`);
  }

  return {
    url,
    uuid: requireString(value.uuid, `files[${index}].uuid`),
    name: requireString(value.name, `files[${index}].name`).slice(0, 500),
    sizeBytes,
    contentType: requireString(value.contentType, `files[${index}].contentType`).slice(0, 200),
  };
};

export const uploadAuthorization = async (req, res) => {
  res.json(await getDirectUploadAuthorization(attachmentPath(req.user)));
};

export const uploadFiles = async (req, res) => {
  const values = Array.isArray(req.body?.files) ? req.body.files : [];
  if (values.length === 0) {
    throw apiError(422, 'FILES_REQUIRED', 'files is required.');
  }
  if (values.length > 10) {
    throw apiError(422, 'FILES_TOO_MANY', 'At most 10 files may be registered.');
  }

  const filePath = attachmentPath(req.user);
  const files = values.map((value, index) => registeredFile(value, index, filePath));
  const totalBytes = files.reduce((sum, file) => sum + file.sizeBytes, 0);
  await reserveAttachmentQuota(req.user, totalBytes);
  try {
    await Attachment.insertMany(files.map((file) => ({
      userId: req.user._id,
      url: file.url,
      uploaderUuid: file.uuid,
      sizeBytes: file.sizeBytes,
      contentType: file.contentType,
      originalName: file.name,
    })));

    res.json({
      urls: files.map((file) => file.url),
      uuids: files.map((file) => file.uuid),
      attachments: files.map((file) => ({
        url: file.url,
        thumbnailUrl: null,
        name: file.name,
        sizeBytes: file.sizeBytes,
        contentType: file.contentType,
      })),
    });
  } catch (error) {
    await releaseAttachmentQuota(req.user, totalBytes);
    throw error;
  }
};

/**
 * Clients call this before uploading so an over-quota batch fails fast,
 * without streaming megabytes to the server first. The reservation in
 * uploadFiles remains the authoritative check.
 */
export const attachmentQuota = async (req, res) => {
  const usage = await getStorageUsage(req.user);
  const usedBytes = usage.attachmentBytes;
  res.json({
    limitBytes: ATTACHMENT_LIMIT_BYTES,
    usedBytes,
    remainingBytes: Math.max(0, ATTACHMENT_LIMIT_BYTES - usedBytes),
  });
};

export const deleteFile = async (req, res) => {
  const url = requireString(req.body?.url, 'url');
  const attachment = await Attachment.findOneAndDelete({ userId: req.user._id, url });
  if (!attachment) {
    throw apiError(404, 'ATTACHMENT_NOT_FOUND', 'Attachment not found.');
  }
  const freedBytes = Number(attachment.sizeBytes || 0) + Number(attachment.thumbnailBytes || 0);
  await releaseAttachmentQuota(req.user, freedBytes);
  res.json({ deleted: true, freedBytes });
};
