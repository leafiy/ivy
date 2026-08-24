import mongoose from 'mongoose';

const noteSchema = new mongoose.Schema(
  {
    _id: { type: String, required: true },
    userId: { type: mongoose.Schema.Types.ObjectId, ref: 'User', required: true, index: true },
    text: { type: String, default: '' },
    color: { type: String, required: true },
    images: [{ type: String }],
    type: { type: String, default: 'text' },
    updatedAt: { type: Date, required: true, index: true },
    deletedAt: { type: Date, default: null },
  },
  { timestamps: { createdAt: true, updatedAt: false } }
);

noteSchema.index({ userId: 1, updatedAt: 1 });

export const Note = mongoose.model('Note', noteSchema);
export default Note;
