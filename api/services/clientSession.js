import { createHash, randomBytes, randomUUID } from 'node:crypto';
import jwt from 'jsonwebtoken';
import config from '../config/index.js';
import ClientSession from '../models/clientSession.model.js';
import Namespace from '../models/namespace.model.js';
import User from '../models/user.model.js';
import { apiError, requireString } from '../middleware/validate.js';

export const hashOpaqueToken = (token) =>
  createHash('sha256').update(String(token)).digest('hex');

const opaqueToken = () => randomBytes(32).toString('base64url');

export const loadPrincipal = async (principalId, principalType) => {
  if (principalType === 'namespace') return Namespace.findById(principalId);
  return User.findById(principalId);
};

const signAccessToken = (principal, principalType, session) =>
  jwt.sign(
    {
      sub: principal._id.toString(),
      type: 'client',
      principalType,
      sid: session._id.toString(),
      deviceId: session.deviceId,
    },
    config.clientJwt.secret,
    { expiresIn: config.clientJwt.expiresInSeconds }
  );

const sessionResult = (principal, principalType, session, refreshToken) => ({
  accessToken: signAccessToken(principal, principalType, session),
  refreshToken,
  expiresIn: config.clientJwt.expiresInSeconds,
  principal,
  principalType,
  deviceId: session.deviceId,
});

export const issueClientSession = async (principal, principalType, device) => {
  const refreshToken = opaqueToken();
  const now = new Date();
  const expiresAt = new Date(now.getTime() + config.refreshToken.ttlMs);

  await ClientSession.updateMany(
    {
      principalId: principal._id,
      deviceId: device.id,
      revokedAt: null,
    },
    { $set: { revokedAt: now } }
  );

  const session = await ClientSession.create({
    principalId: principal._id,
    principalType,
    deviceId: device.id,
    familyId: randomUUID(),
    tokenHash: hashOpaqueToken(refreshToken),
    expiresAt,
  });
  return sessionResult(principal, principalType, session, refreshToken);
};

const invalidRefreshToken = () =>
  apiError(401, 'REFRESH_TOKEN_INVALID', 'Refresh token is invalid or expired.');

export const rotateClientSession = async (rawRefreshToken, rawDeviceId) => {
  const refreshToken = requireString(rawRefreshToken, 'refreshToken');
  const deviceId = requireString(rawDeviceId, 'device.id');
  const tokenHash = hashOpaqueToken(refreshToken);
  const existing = await ClientSession.findOne({ tokenHash });
  const now = new Date();

  if (!existing || existing.expiresAt <= now || existing.deviceId !== deviceId) {
    throw invalidRefreshToken();
  }
  if (existing.revokedAt) {
    if (existing.replacedByTokenHash) {
      await ClientSession.updateMany(
        { familyId: existing.familyId, revokedAt: null },
        { $set: { revokedAt: now } }
      );
    }
    throw invalidRefreshToken();
  }

  const nextRefreshToken = opaqueToken();
  const nextTokenHash = hashOpaqueToken(nextRefreshToken);
  const claimed = await ClientSession.findOneAndUpdate(
    { _id: existing._id, revokedAt: null },
    { $set: { revokedAt: now, replacedByTokenHash: nextTokenHash } },
    { new: false }
  );
  if (!claimed) {
    await ClientSession.updateMany(
      { familyId: existing.familyId, revokedAt: null },
      { $set: { revokedAt: now } }
    );
    throw invalidRefreshToken();
  }

  const principal = await loadPrincipal(existing.principalId, existing.principalType);
  if (!principal) throw invalidRefreshToken();

  const session = await ClientSession.create({
    principalId: existing.principalId,
    principalType: existing.principalType,
    deviceId,
    familyId: existing.familyId,
    tokenHash: nextTokenHash,
    expiresAt: new Date(now.getTime() + config.refreshToken.ttlMs),
  });
  return sessionResult(principal, existing.principalType, session, nextRefreshToken);
};

export const revokeClientSession = async (rawRefreshToken, rawDeviceId) => {
  if (!rawRefreshToken) return;
  const tokenHash = hashOpaqueToken(rawRefreshToken);
  const query = { tokenHash, revokedAt: null };
  if (rawDeviceId) query.deviceId = String(rawDeviceId);
  await ClientSession.updateOne(query, { $set: { revokedAt: new Date() } });
};
