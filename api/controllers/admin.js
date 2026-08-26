import bcrypt from 'bcryptjs';
import jwt from 'jsonwebtoken';
import config from '../config/index.js';
import Admin from '../models/admin.model.js';
import Plan from '../models/plan.model.js';
import User from '../models/user.model.js';
import Device from '../models/device.model.js';
import Order from '../models/order.model.js';
import { getStorageUsageMB } from '../services/quota.js';
import { apiError, requireString } from '../middleware/validate.js';

const signAdminToken = (admin) =>
  jwt.sign(
    { sub: admin._id.toString(), username: admin.username, type: 'admin' },
    config.adminJwt.secret,
    { expiresIn: config.adminJwt.expiresIn }
  );

const serializeAdmin = (admin) => ({ id: admin._id.toString(), username: admin.username });

const serializePlan = (plan) => ({
  planId: plan.planId,
  name: plan.name,
  storageLimitMB: plan.storageLimitMB,
  price: plan.price || {},
  durationDays: plan.durationDays ?? null,
  active: Boolean(plan.active),
});

const userMethods = (user) => {
  const methods = [];
  if (!user.locked) methods.push('username');
  if (user.passwordHash) methods.push('password');
  if (user.googleSub) methods.push('google');
  return methods;
};

const escapeRegex = (value) => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

export const bootstrapAdmin = async () => {
  const count = await Admin.countDocuments();
  if (count > 0) return;

  const username = config.adminBootstrap.username;
  const passwordHash = await bcrypt.hash(config.adminBootstrap.password, 12);
  await Admin.create({ username, passwordHash });
  console.warn(`Bootstrapped admin account "${username}". Change ADMIN_USER/ADMIN_PASSWORD before production use.`);
};

export const login = async (req, res) => {
  const username = requireString(req.body.username, 'username');
  const password = requireString(req.body.password, 'password');
  const admin = await Admin.findOne({ username });

  if (!admin || !(await bcrypt.compare(password, admin.passwordHash))) {
    throw apiError(401, 'UNAUTHORIZED', 'Invalid admin credentials.');
  }

  res.json({ token: signAdminToken(admin), admin: serializeAdmin(admin) });
};

export const refresh = async (req, res) => {
  res.json({ token: signAdminToken(req.admin), admin: serializeAdmin(req.admin) });
};

export const listPlans = async (_req, res) => {
  const plans = await Plan.find().sort({ planId: 1 }).lean();
  res.json({ plans: plans.map(serializePlan) });
};

export const createPlan = async (req, res) => {
  const plan = await Plan.create({
    planId: requireString(req.body.planId, 'planId'),
    name: requireString(req.body.name, 'name'),
    storageLimitMB: Number(req.body.storageLimitMB),
    price: req.body.price || {},
    durationDays: req.body.durationDays ?? null,
    active: req.body.active ?? true,
  });
  res.status(201).json({ plan: serializePlan(plan) });
};

export const updatePlan = async (req, res) => {
  const planId = requireString(req.body.planId || req.params.planId, 'planId');
  const patch = {};
  for (const field of ['name', 'storageLimitMB', 'price', 'durationDays', 'active']) {
    if (Object.hasOwn(req.body, field)) patch[field] = req.body[field];
  }

  const plan = await Plan.findOneAndUpdate({ planId }, { $set: patch }, { new: true, runValidators: true });
  if (!plan) throw apiError(404, 'NOT_FOUND', 'Plan not found.');
  res.json({ plan: serializePlan(plan) });
};

export const deletePlan = async (req, res) => {
  const planId = requireString(req.body.planId || req.query.planId || req.params.planId, 'planId');
  const result = await Plan.deleteOne({ planId });
  if (result.deletedCount === 0) throw apiError(404, 'NOT_FOUND', 'Plan not found.');
  res.status(204).send();
};

export const listUsers = async (req, res) => {
  const rawQuery = typeof req.query.query === 'string' ? req.query.query.trim() : '';
  const filter = rawQuery
    ? {
        $or: [
          { username: { $regex: escapeRegex(rawQuery), $options: 'i' } },
          { email: { $regex: escapeRegex(rawQuery), $options: 'i' } },
        ],
      }
    : {};

  const users = await User.find(filter).sort({ createdAt: -1 }).limit(100).lean();
  const enriched = await Promise.all(
    users.map(async (user) => ({
      id: user._id.toString(),
      username: user.username,
      email: user.email || null,
      locked: Boolean(user.locked),
      methods: userMethods(user),
      subscription: {
        planId: user.subscription?.planId || 'free',
        expiresAt: user.subscription?.expiresAt ? user.subscription.expiresAt.toISOString() : null,
      },
      deviceCount: await Device.countDocuments({ userId: user._id }),
      storageMB: await getStorageUsageMB(user),
      createdAt: user.createdAt?.toISOString(),
      updatedAt: user.updatedAt?.toISOString(),
    }))
  );

  res.json({ users: enriched });
};

export const listOrders = async (req, res) => {
  const rawQuery = typeof req.query.query === 'string' ? req.query.query.trim() : '';
  let filter = {};

  if (rawQuery) {
    const regex = { $regex: escapeRegex(rawQuery), $options: 'i' };
    const matchingUsers = await User.find(
      { $or: [{ username: regex }, { email: regex }] },
      { _id: 1 }
    ).lean();
    filter = {
      $or: [
        { provider: regex },
        { providerRef: regex },
        { planId: regex },
        { status: regex },
        { userId: { $in: matchingUsers.map((user) => user._id) } },
      ],
    };
  }

  const orders = await Order.find(filter)
    .sort({ createdAt: -1 })
    .limit(100)
    .populate('userId', 'username email')
    .lean();

  res.json({
    orders: orders.map((order) => ({
      id: order._id.toString(),
      userId: order.userId?._id?.toString() || order.userId?.toString(),
      user: order.userId?.username
        ? { username: order.userId.username, email: order.userId.email || null }
        : null,
      provider: order.provider,
      providerRef: order.providerRef || null,
      planId: order.planId,
      status: order.status,
      refundMarkedAt: order.refundMarkedAt ? order.refundMarkedAt.toISOString() : null,
      createdAt: order.createdAt?.toISOString(),
      updatedAt: order.updatedAt?.toISOString(),
    })),
  });
};

export const refundMark = async (req, res) => {
  const id = requireString(req.params.id, 'id');
  const order = await Order.findByIdAndUpdate(
    id,
    { $set: { status: 'refunded', refundMarkedAt: new Date() } },
    { new: true }
  );
  if (!order) throw apiError(404, 'NOT_FOUND', 'Order not found.');
  res.json({ order: { id: order._id.toString(), status: order.status, refundMarkedAt: order.refundMarkedAt.toISOString() } });
};
