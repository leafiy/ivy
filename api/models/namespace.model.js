import mongoose from 'mongoose';

const subscriptionSchema = new mongoose.Schema(
  {
    planId: { type: String, default: 'free' },
    expiresAt: { type: Date, default: null },
  },
  { _id: false }
);

const databaseSyncSchema = new mongoose.Schema(
  {
    url: { type: String, default: null },
    sizeBytes: { type: Number, default: 0 },
    version: { type: Number, default: 0 },
    updatedAt: { type: Date, default: null },
    sourceDeviceId: { type: String, default: null },
  },
  { _id: false }
);

const namespaceSchema = new mongoose.Schema(
  {
    name: { type: String, required: true, trim: true },
    key: { type: String, required: true, unique: true, trim: true },
    subscription: { type: subscriptionSchema, default: () => ({ planId: 'free', expiresAt: null }) },
    databaseSync: { type: databaseSyncSchema, default: () => ({}) },
    attachmentUsageBytes: { type: Number, default: 0, min: 0 },
  },
  { timestamps: true }
);

export const Namespace = mongoose.model('Namespace', namespaceSchema);
export default Namespace;
