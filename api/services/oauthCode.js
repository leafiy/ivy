import { randomBytes } from 'node:crypto';
import config from '../config/index.js';
import OAuthCode from '../models/oauthCode.model.js';
import { apiError, requireString } from '../middleware/validate.js';
import { hashOpaqueToken, loadPrincipal } from './clientSession.js';

export const createOAuthExchangeCode = async ({ principal, principalType, device, created }) => {
  const code = randomBytes(32).toString('base64url');
  await OAuthCode.create({
    codeHash: hashOpaqueToken(code),
    principalId: principal._id,
    principalType,
    deviceId: device.id,
    deviceName: device.name,
    created,
    expiresAt: new Date(Date.now() + config.oauthCode.ttlMs),
  });
  return code;
};

export const consumeOAuthExchangeCode = async (rawCode) => {
  const code = requireString(rawCode, 'code');
  const record = await OAuthCode.findOneAndDelete({
    codeHash: hashOpaqueToken(code),
    expiresAt: { $gt: new Date() },
  });
  if (!record) {
    throw apiError(401, 'OAUTH_CODE_INVALID', 'OAuth code is invalid or expired.');
  }
  const principal = await loadPrincipal(record.principalId, record.principalType);
  if (!principal) {
    throw apiError(401, 'OAUTH_CODE_INVALID', 'OAuth account no longer exists.');
  }
  return {
    principal,
    principalType: record.principalType,
    device: { id: record.deviceId, name: record.deviceName },
    created: record.created,
  };
};
