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

const userSchema = new mongoose.Schema(
  {
    username: { type: String, required: true, unique: true, lowercase: true, trim: true },
    email: { type: String, unique: true, sparse: true, lowercase: true, trim: true },
    displayEmail: { type: String, lowercase: true, trim: true },
    passwordHash: { type: String },
    googleSub: { type: String, unique: true, sparse: true },
    // Legacy-only discriminator. New public namespaces live in their own collection.
    locked: { type: Boolean, default: true },
    subscription: { type: subscriptionSchema, default: () => ({ planId: 'free', expiresAt: null }) },
    databaseSync: { type: databaseSyncSchema, default: () => ({}) },
    attachmentUsageBytes: { type: Number, default: 0, min: 0 },
  },
  { timestamps: true }
);

export const User = mongoose.model('User', userSchema);
export default User;
