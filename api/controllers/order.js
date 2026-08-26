import Plan from '../models/plan.model.js';
import { FREE_PLAN } from '../services/quota.js';
import { apiError, requireString } from '../middleware/validate.js';

const serializePlan = (plan) => ({
  planId: plan.planId,
  name: plan.name,
  storageLimitMB: plan.storageLimitMB,
  price: plan.price || {},
  durationDays: plan.durationDays ?? null,
  active: Boolean(plan.active),
});

export const listPlans = async (_req, res) => {
  const plans = await Plan.find({ active: true }).sort({ planId: 1 }).lean();
  const hasFree = plans.some((plan) => plan.planId === FREE_PLAN.planId);
  const merged = hasFree ? plans : [FREE_PLAN, ...plans];
  res.json({ plans: merged.map(serializePlan) });
};

const notImplemented = (message) => {
  throw apiError(501, 'NOT_IMPLEMENTED', message);
};

export const createStripeCheckout = async (_req, _res) => {
  // TODO(Stripe Checkout): create Checkout Session and persist Order when payment integration is configured.
  notImplemented('Stripe Checkout is not implemented.');
};

export const createWechatPrepay = async (_req, _res) => {
  // TODO(WeChat Native): create Native prepay order and persist Order when merchant config is available.
  notImplemented('WeChat Native prepay is not implemented.');
};

export const getOrder = async (req, _res) => {
  requireString(req.params.id, 'id');
  notImplemented('Client order lookup is not implemented.');
};

export const stripeWebhook = async (_req, _res) => {
  // TODO(Stripe Checkout): verify webhook signature from raw body and update Order status.
  notImplemented('Stripe webhook handling is not implemented.');
};

export const wechatWebhook = async (_req, _res) => {
  // TODO(WeChat Native): verify callback signature from raw body and update Order status.
  notImplemented('WeChat webhook handling is not implemented.');
};
