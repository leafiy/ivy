import mongoose from 'mongoose';

const priceSchema = new mongoose.Schema(
  {
    stripe: { type: String },
    wechatFen: { type: Number },
  },
  { _id: false }
);

const planSchema = new mongoose.Schema({
  planId: { type: String, required: true, unique: true },
  name: { type: String, required: true },
  storageLimitMB: { type: Number, required: true },
  price: { type: priceSchema, default: () => ({}) },
  durationDays: { type: Number, default: null },
  active: { type: Boolean, default: true, index: true },
});

export const Plan = mongoose.model('Plan', planSchema);
export default Plan;
