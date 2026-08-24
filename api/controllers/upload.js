import multer from 'multer';
import Attachment from '../models/attachment.model.js';
import { apiError, requireString } from '../middleware/validate.js';
import {
  ATTACHMENT_LIMIT_BYTES,
  getStorageUsage,
  releaseAttachmentQuota,
  reserveAttachmentQuota,
} from '../services/quota.js';
import { uploadFilesToLatte } from '../services/uploader.js';
import { createThumbnail, isThumbnailableImage, thumbnailFilename } from '../services/thumbnails.js';

const storage = multer.memoryStorage();

export const uploadFilesMiddleware = multer({
  storage,
  limits: { files: 10, fileSize: ATTACHMENT_LIMIT_BYTES },
}).array('files', 10);

const fileBytes = (file) => Number(file.size || file.buffer?.length || 0);

/**
 * Builds one thumbnail buffer per image file (same index as `files`).
 * Non-images and undecodable images produce null: they upload unchanged
 * and clients render them as plain file rows.
 */
const buildThumbnails = (files) =>
  Promise.all(files.map(async (file) => {
    if (!isThumbnailableImage(file.mimetype)) return null;
    try {
      return await createThumbnail(file.buffer);
    } catch {
      return null;
    }
  }));

export const uploadFiles = async (req, res) => {
  const files = Array.isArray(req.files) ? req.files : [];
  if (files.length === 0) {
    throw apiError(422, 'FILES_REQUIRED', 'files is required.');
  }
  if (files.length > 10) {
    throw apiError(422, 'FILES_TOO_MANY', 'At most 10 files may be uploaded.');
  }

  const thumbnails = await buildThumbnails(files);

  // Thumbnails count against the same quota, so reserve originals and
  // thumbnails in one atomic step before anything reaches the uploader.
  const originalBytes = files.reduce((sum, file) => sum + fileBytes(file), 0);
  const thumbnailBytes = thumbnails.reduce((sum, buffer) => sum + (buffer ? buffer.length : 0), 0);
  const totalBytes = originalBytes + thumbnailBytes;
  await reserveAttachmentQuota(req.user, totalBytes);
  try {
    const basePath = `ivy/${req.user._id.toString()}/attachments`;
    const result = await uploadFilesToLatte(files, { filePath: basePath });

    if (result.urls.length !== files.length) {
      throw apiError(502, 'UPLOADER_BAD_RESPONSE', 'Uploader returned an incomplete attachment list.');
    }

    const thumbnailFiles = [];
    const thumbnailFileIndexes = [];
    thumbnails.forEach((buffer, index) => {
      if (!buffer) return;
      thumbnailFileIndexes.push(index);
      thumbnailFiles.push({
        buffer,
        size: buffer.length,
        mimetype: 'image/webp',
        originalname: thumbnailFilename(files[index].originalname),
      });
    });

    const thumbnailUrls = new Array(files.length).fill(null);
    const thumbnailUuids = new Array(files.length).fill(null);
    if (thumbnailFiles.length > 0) {
      const thumbnailResult = await uploadFilesToLatte(thumbnailFiles, {
        filePath: `${basePath}/thumbnails`,
      });
      if (thumbnailResult.urls.length !== thumbnailFiles.length) {
        throw apiError(502, 'UPLOADER_BAD_RESPONSE', 'Uploader returned an incomplete thumbnail list.');
      }
      thumbnailFileIndexes.forEach((fileIndex, position) => {
        thumbnailUrls[fileIndex] = thumbnailResult.urls[position];
        thumbnailUuids[fileIndex] = thumbnailResult.uuids[position] || null;
      });
    }

    await Attachment.insertMany(files.map((file, index) => ({
      userId: req.user._id,
      url: result.urls[index],
      uploaderUuid: result.uuids[index] || null,
      thumbnailUrl: thumbnailUrls[index],
      thumbnailUuid: thumbnailUuids[index],
      thumbnailBytes: thumbnails[index] ? thumbnails[index].length : 0,
      sizeBytes: fileBytes(file),
      contentType: file.mimetype || 'application/octet-stream',
      originalName: file.originalname || 'file',
    })));

    res.json({
      urls: result.urls,
      uuids: result.uuids,
      attachments: files.map((file, index) => ({
        url: result.urls[index],
        thumbnailUrl: thumbnailUrls[index],
        name: file.originalname || 'file',
        sizeBytes: fileBytes(file),
        contentType: file.mimetype || 'application/octet-stream',
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
