import mongoose from 'mongoose';

const clientSessionSchema = new mongoose.Schema(
  {
    principalId: { type: mongoose.Schema.Types.ObjectId, required: true, index: true },
    principalType: {
      type: String,
      enum: ['account', 'namespace', 'legacy-namespace'],
      required: true,
    },
    deviceId: { type: String, required: true },
    familyId: { type: String, required: true, index: true },
    tokenHash: { type: String, required: true, unique: true },
    expiresAt: { type: Date, required: true, index: { expires: 0 } },
    revokedAt: { type: Date, default: null },
    replacedByTokenHash: { type: String, default: null },
  },
  { timestamps: true }
);

clientSessionSchema.index({ principalId: 1, deviceId: 1, revokedAt: 1 });

export const ClientSession = mongoose.model('ClientSession', clientSessionSchema);
export default ClientSession;
