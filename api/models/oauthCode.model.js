import mongoose from 'mongoose';

const oauthCodeSchema = new mongoose.Schema(
  {
    codeHash: { type: String, required: true, unique: true },
    principalId: { type: mongoose.Schema.Types.ObjectId, required: true },
    principalType: {
      type: String,
      enum: ['account', 'namespace', 'legacy-namespace'],
      required: true,
    },
    deviceId: { type: String, required: true },
    deviceName: { type: String, default: '' },
    created: { type: Boolean, default: false },
    expiresAt: { type: Date, required: true, index: { expires: 0 } },
  },
  { timestamps: true }
);

export const OAuthCode = mongoose.model('OAuthCode', oauthCodeSchema);
export default OAuthCode;
