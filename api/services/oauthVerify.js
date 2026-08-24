import { createRemoteJWKSet, jwtVerify } from 'jose';
import config from '../config/index.js';
import { apiError } from '../middleware/validate.js';

const googleJWKS = createRemoteJWKSet(new URL('https://www.googleapis.com/oauth2/v3/certs'));

const providerConfiguration = (provider) => {
  const providerConfig = config.authProviders?.[provider] || {};
  const configuredAudiences = Array.isArray(providerConfig.audiences)
    ? providerConfig.audiences.filter(Boolean)
    : [];
  const audiences = configuredAudiences.length === 0 && providerConfig.clientId
    ? [providerConfig.clientId]
    : configuredAudiences;
  if (!providerConfig.enabled || audiences.length === 0) {
    throw apiError(503, 'PROVIDER_NOT_CONFIGURED', `${provider} login is not configured.`);
  }
  return { audiences };
};

const requireToken = (token) => {
  if (typeof token !== 'string' || token.trim() === '') {
    throw apiError(422, 'TOKEN_INVALID', 'Identity token is required.');
  }
  return token;
};

const normalizeIdentity = (payload, provider) => {
  if (!payload.sub) {
    throw apiError(422, 'TOKEN_INVALID', `${provider} identity token has no subject.`);
  }

  return {
    sub: String(payload.sub),
    email: typeof payload.email === 'string' ? payload.email.toLowerCase() : undefined,
  };
};

export const verifyGoogleIdToken = async (idToken) => {
  const { audiences } = providerConfiguration('google');
  try {
    const { payload } = await jwtVerify(requireToken(idToken), googleJWKS, {
      issuer: ['accounts.google.com', 'https://accounts.google.com'],
      audience: audiences,
    });
    return normalizeIdentity(payload, 'Google');
  } catch (error) {
    if (error?.statusCode) throw error;
    throw apiError(401, 'TOKEN_INVALID', 'Google identity token verification failed.');
  }
};
