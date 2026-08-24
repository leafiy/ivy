import { randomInt } from 'node:crypto';
import bcrypt from 'bcryptjs';
import jwt from 'jsonwebtoken';
import config from '../config/index.js';
import User from '../models/user.model.js';
import Namespace from '../models/namespace.model.js';
import Device from '../models/device.model.js';
import EmailCode from '../models/emailCode.model.js';
import { sendVerificationCode } from '../services/email.js';
import { verifyGoogleIdToken } from '../services/oauthVerify.js';
import { privateAccountHandle } from '../services/privateIdentity.js';
import {
  ATTACHMENT_LIMIT_BYTES,
  NOTE_DATABASE_LIMIT_BYTES,
  getPlanForUser,
  getStorageUsage,
} from '../services/quota.js';
import {
  apiError,
  assertNamespace,
  namespaceKey,
  normalizeNamespace,
  requireString,
} from '../middleware/validate.js';

const normalizeEmail = (email) => requireString(email, 'email').toLowerCase();

const signClientToken = (principal, principalType) =>
  jwt.sign(
    { sub: principal._id.toString(), type: 'client', principalType },
    config.clientJwt.secret,
    { expiresIn: config.clientJwt.expiresIn }
  );

const signOAuthState = ({ provider, device }) =>
  jwt.sign(
    { type: `${provider}-oauth-state`, device },
    config.clientJwt.secret,
    { expiresIn: '10m' }
  );

const methodsForPrivateAccount = (user) => {
  const methods = [];
  if (user.passwordHash) methods.push('password');
  if (user.googleSub) methods.push('google');
  return methods;
};

const serializeDevice = (device) => ({
  id: device.deviceId,
  name: device.name,
  lastSeenAt: device.lastSeenAt.toISOString(),
});

export const buildMe = async (principal, principalType = 'account') => {
  const [plan, devices, usage] = await Promise.all([
    getPlanForUser(principal),
    Device.find({ userId: principal._id }).sort({ lastSeenAt: -1 }).lean(),
    getStorageUsage(principal),
  ]);
  const isNamespace = principalType === 'namespace' || principalType === 'legacy-namespace';

  return {
    id: principal._id.toString(),
    accountType: isNamespace ? 'namespace' : 'private',
    namespace: isNamespace ? (principal.name || principal.username) : null,
    email: isNamespace ? null : (principal.displayEmail || principal.email || null),
    methods: isNamespace ? ['namespace'] : methodsForPrivateAccount(principal),
    subscription: {
      planId: principal.subscription?.planId || 'free',
      expiresAt: principal.subscription?.expiresAt ? principal.subscription.expiresAt.toISOString() : null,
    },
    quota: {
      deviceLimit: plan.deviceLimit,
      storageLimitMB: NOTE_DATABASE_LIMIT_BYTES / 1024 / 1024,
      noteDatabaseLimitMB: NOTE_DATABASE_LIMIT_BYTES / 1024 / 1024,
      attachmentLimitMB: ATTACHMENT_LIMIT_BYTES / 1024 / 1024,
    },
    usage: {
      devices: devices.length,
      storageMB: usage.noteDatabaseMB,
      noteDatabaseMB: usage.noteDatabaseMB,
      attachmentMB: usage.attachmentMB,
    },
    database: {
      version: Number(principal.databaseSync?.version || 0),
      sizeBytes: Number(principal.databaseSync?.sizeBytes || 0),
      updatedAt: principal.databaseSync?.updatedAt ? principal.databaseSync.updatedAt.toISOString() : null,
      downloadURL: principal.databaseSync?.url || null,
      sourceDeviceId: principal.databaseSync?.sourceDeviceId || null,
    },
    devices: devices.map(serializeDevice),
  };
};

export const authConfig = async (_req, res) => {
  const providers = config.authProviders || {};
  const googleEnabled = Boolean(
    providers.google?.enabled
    && providers.google?.clientId
    && providers.google?.clientSecret
    && providers.google?.redirectURI
    && providers.google?.appCallbackURL
  );
  res.json({
    passwordless: { enabled: true },
    email: { enabled: Boolean(providers.email?.enabled) },
    google: { enabled: googleEnabled },
  });
};

const assertDevicePayload = (device) => {
  if (!device || typeof device !== 'object') {
    throw apiError(422, 'DEVICE_INVALID', 'device is required.');
  }
  const id = requireString(device.id, 'device.id');
  const name = typeof device.name === 'string' ? device.name.trim() : '';
  return { id, name };
};

const upsertDeviceForUser = async (user, rawDevice) => {
  const device = assertDevicePayload(rawDevice);
  const existing = await Device.findOne({ userId: user._id, deviceId: device.id });

  if (!existing) {
    const [plan, count] = await Promise.all([
      getPlanForUser(user),
      Device.countDocuments({ userId: user._id }),
    ]);
    if (count >= plan.deviceLimit) {
      throw apiError(403, 'DEVICE_LIMIT', 'Device limit exceeded.');
    }
  }

  await Device.updateOne(
    { userId: user._id, deviceId: device.id },
    { $set: { name: device.name, lastSeenAt: new Date() } },
    { upsert: true }
  );
};

const verifyEmailCode = async (email, code) => {
  const normalizedEmail = normalizeEmail(email);
  const rawCode = requireString(code, 'code');
  const record = await EmailCode.findOne({
    email: normalizedEmail,
    expiresAt: { $gt: new Date() },
  }).sort({ createdAt: -1 });

  if (!record) {
    throw apiError(422, 'EMAIL_CODE_INVALID', 'Verification code is invalid or expired.');
  }

  const ok = await bcrypt.compare(rawCode, record.codeHash);
  if (!ok) {
    throw apiError(422, 'EMAIL_CODE_INVALID', 'Verification code is invalid or expired.');
  }

  await EmailCode.deleteMany({ email: normalizedEmail });
  return normalizedEmail;
};

const duplicateError = (error) => {
  if (error?.code !== 11000) return null;
  const field = Object.keys(error.keyPattern || error.keyValue || {})[0];
  if (field === 'key') return apiError(409, 'NAMESPACE_TAKEN', 'Namespace is already in use.');
  if (field === 'username') return apiError(409, 'ACCOUNT_CONFLICT', 'Private account already exists.');
  if (field === 'email') return apiError(409, 'EMAIL_TAKEN', 'Email is already registered.');
  if (field === 'googleSub') return apiError(409, 'GOOGLE_TAKEN', 'Google identity already has an account.');
  return apiError(409, 'CONFLICT', 'Resource already exists.');
};

const savePrincipal = async (principal) => {
  try {
    return await principal.save();
  } catch (error) {
    throw duplicateError(error) || error;
  }
};

const issueAuthResponse = async (res, principal, created, principalType) => {
  const token = signClientToken(principal, principalType);
  const me = await buildMe(principal, principalType);
  res.json({ token, created, user: me });
};

export const login = async (req, res) => {
  const name = normalizeNamespace(req.body.namespace ?? req.body.username);
  assertNamespace(name);
  const key = namespaceKey(name);
  assertDevicePayload(req.body.device);

  let principal = await Namespace.findOne({ key });
  let principalType = 'namespace';
  if (!principal) {
    principal = await User.findOne({
      username: key,
      locked: false,
      passwordHash: { $exists: false },
      googleSub: { $exists: false },
    });
    if (principal) principalType = 'legacy-namespace';
  }
  const created = !principal;
  if (!principal) principal = await savePrincipal(new Namespace({ name, key }));

  await upsertDeviceForUser(principal, req.body.device);
  await issueAuthResponse(res, principal, created, principalType);
};

export const sendEmailCode = async (req, res) => {
  if (!config.authProviders?.email?.enabled) {
    throw apiError(503, 'PROVIDER_NOT_CONFIGURED', 'Email registration is not configured.');
  }
  const email = normalizeEmail(req.body.email);
  const code = String(randomInt(100_000, 1_000_000));
  const codeHash = await bcrypt.hash(code, 10);

  await EmailCode.deleteMany({ email });
  await EmailCode.create({
    email,
    codeHash,
    expiresAt: new Date(Date.now() + 10 * 60 * 1000),
  });

  await sendVerificationCode(email, code);
  res.json({ sent: true, expiresIn: 600 });
};

export const loginWithEmail = async (req, res) => {
  if (!config.authProviders?.email?.enabled) {
    throw apiError(503, 'PROVIDER_NOT_CONFIGURED', 'Email login is not configured.');
  }
  const email = normalizeEmail(req.body.email);
  const password = requireString(req.body.password, 'password');
  assertDevicePayload(req.body.device);
  const user = await User.findOne({ email });
  if (!user?.passwordHash || !(await bcrypt.compare(password, user.passwordHash))) {
    throw apiError(401, 'UNAUTHORIZED', 'Invalid email or password.');
  }
  await upsertDeviceForUser(user, req.body.device);
  await issueAuthResponse(res, user, false, 'account');
};

export const register = async (req, res) => {
  assertDevicePayload(req.body.device);

  const email = normalizeEmail(req.body.email);
  if (await User.exists({ email })) {
    throw apiError(409, 'EMAIL_TAKEN', 'Email is already registered.');
  }

  await verifyEmailCode(email, req.body.code);
  const password = requireString(req.body.password, 'password');
  const passwordHash = await bcrypt.hash(password, 12);

  const user = await savePrincipal(
    new User({
      username: privateAccountHandle('email', email),
      email,
      passwordHash,
      locked: true,
    })
  );
  await upsertDeviceForUser(user, req.body.device);
  await issueAuthResponse(res, user, true, 'account');
};

const resolveOAuthUser = async ({ identity, provider, device, subField }) => {
  assertDevicePayload(device);
  let user = await User.findOne({ [subField]: identity.sub });
  const created = !user;

  if (!user) {
    user = await savePrincipal(
      new User({
        username: privateAccountHandle(provider, identity.sub),
        displayEmail: identity.email,
        [subField]: identity.sub,
        locked: true,
      })
    );
  } else if (identity.email && user.displayEmail !== identity.email) {
    user.displayEmail = identity.email;
    await savePrincipal(user);
  }

  await upsertDeviceForUser(user, device);
  return { user, created };
};

const oauthLogin = async ({ provider, req, res, verifyToken, subField }) => {
  const identity = await verifyToken(req.body.idToken || req.body.identityToken);
  const { user, created } = await resolveOAuthUser({
    identity,
    provider,
    device: req.body.device,
    subField,
  });
  await issueAuthResponse(res, user, created, 'account');
};

export const startGoogleOAuth = async (req, res) => {
  const google = config.authProviders?.google || {};
  if (!google.enabled || !google.clientId || !google.clientSecret || !google.redirectURI || !google.appCallbackURL) {
    throw apiError(503, 'PROVIDER_NOT_CONFIGURED', 'Google login is not configured.');
  }
  const device = assertDevicePayload(req.body.device);
  const state = signOAuthState({ provider: 'google', device });
  const url = new URL('https://accounts.google.com/o/oauth2/v2/auth');
  url.search = new URLSearchParams({
    client_id: google.clientId,
    redirect_uri: google.redirectURI,
    response_type: 'code',
    scope: 'openid email',
    state,
    prompt: 'select_account',
  }).toString();
  res.json({ authorizationURL: url.toString() });
};

export const googleOAuthCallback = async (req, res) => {
  const google = config.authProviders?.google || {};
  try {
    if (typeof req.query.error === 'string') {
      throw apiError(401, 'OAUTH_CANCELLED', 'Google login was cancelled.');
    }
    const code = requireString(req.query.code, 'code');
    const state = requireString(req.query.state, 'state');
    const statePayload = jwt.verify(state, config.clientJwt.secret);
    if (statePayload.type !== 'google-oauth-state') {
      throw apiError(401, 'OAUTH_STATE_INVALID', 'Google login state is invalid.');
    }
    const tokenResponse = await fetch('https://oauth2.googleapis.com/token', {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        code,
        client_id: google.clientId,
        client_secret: google.clientSecret,
        redirect_uri: google.redirectURI,
        grant_type: 'authorization_code',
      }),
    });
    const tokenBody = await tokenResponse.json();
    if (!tokenResponse.ok || !tokenBody.id_token) {
      throw apiError(401, 'TOKEN_INVALID', 'Google token exchange failed.');
    }
    const identity = await verifyGoogleIdToken(tokenBody.id_token);
    const { user } = await resolveOAuthUser({
      identity,
      provider: 'google',
      device: statePayload.device,
      subField: 'googleSub',
    });
    const callback = new URL(google.appCallbackURL);
    callback.searchParams.set('token', signClientToken(user, 'account'));
    res.redirect(302, callback.toString());
  } catch (error) {
    const callback = new URL(google.appCallbackURL || 'ivy://oauth/google');
    callback.searchParams.set('error', error.code || 'OAUTH_FAILED');
    callback.searchParams.set('message', error.message || 'Google login failed.');
    res.redirect(302, callback.toString());
  }
};

export const oauthGoogle = async (req, res) =>
  oauthLogin({
    provider: 'google',
    req,
    res,
    verifyToken: verifyGoogleIdToken,
    subField: 'googleSub',
  });

export const refresh = async (req, res) => {
  await issueAuthResponse(res, req.user, false, req.principalType);
};

export const me = async (req, res) => {
  res.json(await buildMe(req.user, req.principalType));
};
