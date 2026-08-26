import Plan from '../models/plan.model.js';
import Attachment from '../models/attachment.model.js';
import { apiError } from '../middleware/validate.js';

export const NOTE_DATABASE_LIMIT_BYTES = 10 * 1024 * 1024;
export const ATTACHMENT_LIMIT_BYTES = 50 * 1024 * 1024;

export const FREE_PLAN = {
  planId: 'free',
  name: 'Free',
  storageLimitMB: 10,
  price: {},
  durationDays: null,
  active: true,
};

// Currently uncalled: every quota the clients see is a constant, so nothing
// consults a user's plan. Kept because plans themselves are still real —
// admin edits them and `listPlans` sells them — and whatever gives a
// subscription teeth again will resolve one this way.
export const getPlanForUser = async (user) => {
  const planId = user.subscription?.planId || 'free';
  const plan = await Plan.findOne({ planId, active: true }).lean();
  return plan || FREE_PLAN;
};

const bytesToMB = (bytes) => Number((bytes / 1024 / 1024).toFixed(2));

// One file, one size. Nothing derives a second object from an upload, so the
// quota is simply the sum of what was sent.
const attachmentBytesExpression = '$sizeBytes';

export const getStorageUsage = async (user) => {
  const aggregate = await Attachment.aggregate([
    { $match: { userId: user._id } },
    { $group: { _id: null, bytes: { $sum: attachmentBytesExpression } } },
  ]);
  const noteDatabaseBytes = Number(user.databaseSync?.sizeBytes || 0);
  const attachmentBytes = Math.max(
    Number(user.attachmentUsageBytes || 0),
    Number(aggregate[0]?.bytes || 0)
  );

  return {
    noteDatabaseBytes,
    noteDatabaseMB: bytesToMB(noteDatabaseBytes),
    attachmentBytes,
    attachmentMB: bytesToMB(attachmentBytes),
  };
};

// Legacy admin callers display a single number. Keep it as a combined total.
export const getStorageUsageMB = async (userOrId) => {
  if (typeof userOrId === 'object' && userOrId?._id) {
    const usage = await getStorageUsage(userOrId);
    return Number((usage.noteDatabaseMB + usage.attachmentMB).toFixed(2));
  }

  const aggregate = await Attachment.aggregate([
    { $match: { userId: userOrId } },
    { $group: { _id: null, bytes: { $sum: attachmentBytesExpression } } },
  ]);
  return bytesToMB(Number(aggregate[0]?.bytes || 0));
};

export const assertNoteDatabaseQuota = (sizeBytes) => {
  if (!Number.isFinite(sizeBytes) || sizeBytes < 0 || sizeBytes > NOTE_DATABASE_LIMIT_BYTES) {
    throw apiError(403, 'NOTE_DATABASE_LIMIT', 'Note database exceeds the 10 MB limit.', {
      limitBytes: NOTE_DATABASE_LIMIT_BYTES,
    });
  }
};

export const reserveAttachmentQuota = async (user, additionalBytes = 0) => {
  if (!Number.isFinite(additionalBytes) || additionalBytes < 0) {
    throw apiError(422, 'ATTACHMENT_SIZE_INVALID', 'Attachment size is invalid.');
  }
  const Principal = user.constructor;
  const reserved = await Principal.findOneAndUpdate(
    {
      _id: user._id,
      $expr: {
        $lte: [
          { $add: [{ $ifNull: ['$attachmentUsageBytes', 0] }, additionalBytes] },
          ATTACHMENT_LIMIT_BYTES,
        ],
      },
    },
    { $inc: { attachmentUsageBytes: additionalBytes } },
    { new: true }
  );
  if (!reserved) {
    const usage = await getStorageUsage(user);
    throw apiError(403, 'ATTACHMENT_LIMIT', 'Attachments exceed the 50 MB limit.', {
      limitBytes: ATTACHMENT_LIMIT_BYTES,
      usedBytes: usage.attachmentBytes,
    });
  }
  return reserved;
};

export const releaseAttachmentQuota = async (user, bytes) => {
  if (!Number.isFinite(bytes) || bytes <= 0) return;
  const Principal = user.constructor;
  await Principal.updateOne(
    { _id: user._id },
    [{
      $set: {
        attachmentUsageBytes: {
          $max: [0, { $subtract: [{ $ifNull: ['$attachmentUsageBytes', 0] }, bytes] }],
        },
      },
    }]
  );
};
