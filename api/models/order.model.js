import mongoose from 'mongoose';

const orderSchema = new mongoose.Schema(
  {
    userId: { type: mongoose.Schema.Types.ObjectId, ref: 'User', required: true, index: true },
    provider: { type: String, enum: ['stripe', 'wechat'], required: true },
    providerRef: { type: String },
    planId: { type: String, required: true },
    status: { type: String, required: true, index: true },
    refundMarkedAt: { type: Date, default: null },
  },
  { timestamps: true }
);

orderSchema.index({ provider: 1, providerRef: 1 });

export const Order = mongoose.model('Order', orderSchema);
export default Order;
