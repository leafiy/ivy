import mongoose from 'mongoose';

const attachmentSchema = new mongoose.Schema(
  {
    userId: { type: mongoose.Schema.Types.ObjectId, ref: 'User', required: true, index: true },
    url: { type: String, required: true },
    uploaderUuid: { type: String, default: null },
    sizeBytes: { type: Number, required: true, min: 0 },
    contentType: { type: String, default: 'application/octet-stream' },
    originalName: { type: String, default: 'file' },
  },
  { timestamps: true }
);

attachmentSchema.index({ userId: 1, createdAt: -1 });

export const Attachment = mongoose.model('Attachment', attachmentSchema);
export default Attachment;
