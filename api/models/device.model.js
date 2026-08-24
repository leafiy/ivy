import mongoose from 'mongoose';

const deviceSchema = new mongoose.Schema({
  userId: { type: mongoose.Schema.Types.ObjectId, ref: 'User', required: true, index: true },
  deviceId: { type: String, required: true },
  name: { type: String, default: '' },
  lastSeenAt: { type: Date, required: true },
});

deviceSchema.index({ userId: 1, deviceId: 1 }, { unique: true });

export const Device = mongoose.model('Device', deviceSchema);
export default Device;
