import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const env = process.env.NODE_ENV || 'development';
const isProduction = env === 'production';
const configDirectory = path.dirname(fileURLToPath(import.meta.url));

const defaultWebCallback = isProduction
  ? 'https://ivy.leafiy.com/auth/google'
  : 'http://localhost:5173/auth/google';

const resolveAuthProviderConfig = (providers) => {
  const google = providers?.google || {};
  return {
    ...providers,
    google: {
      ...google,
      redirectURI: google.redirectURIs?.[env] || google.redirectURI || '',
      // Where the API sends the browser once Google has come back to it.
      // Google itself only ever redirects to redirectURI, so adding the web
      // client needs no change at Google's end — this is our own second hop.
      webCallbackURL: google.webCallbackURLs?.[env] || google.webCallbackURL || defaultWebCallback,
    },
  };
};

const loadAuthProviders = () => {
  const filePath = process.env.AUTH_PROVIDERS_CONFIG
    ? path.resolve(process.env.AUTH_PROVIDERS_CONFIG)
    : path.join(configDirectory, 'auth.providers.json');

  try {
    return resolveAuthProviderConfig(JSON.parse(fs.readFileSync(filePath, 'utf8')));
  } catch (error) {
    if (error?.code === 'ENOENT' && !isProduction) {
      return { email: { enabled: false }, google: { enabled: false } };
    }
    throw new Error(`Unable to load auth provider config at ${filePath}: ${error.message}`);
  }
};

const requireSecret = (name, fallback) => {
  const value = process.env[name];
  if (value) return value;
  if (!isProduction && fallback) return fallback;
  throw new Error(`${name} is required in production`);
};

const intFromEnv = (name, fallback) => {
  const raw = process.env[name];
  if (!raw) return fallback;
  const parsed = Number.parseInt(raw, 10);
  return Number.isFinite(parsed) ? parsed : fallback;
};

const csvFromEnv = (name, fallback) => {
  const raw = process.env[name];
  if (!raw) return fallback;
  return raw
    .split(',')
    .map((item) => item.trim())
    .filter(Boolean);
};

export const noteColors = ['white', 'yellow', 'green', 'blue', 'pink', 'purple', 'gray'];

const common = {
  env,
  port: intFromEnv('PORT', 7788),
  clientJwt: {
    secret: requireSecret('CLIENT_JWT_SECRET', 'dev-client-secret-change-me'),
    expiresInSeconds: intFromEnv('CLIENT_JWT_EXPIRES_SECONDS', 15 * 60),
  },
  refreshToken: {
    ttlMs: intFromEnv('REFRESH_TOKEN_TTL_MS', 30 * 24 * 60 * 60 * 1000),
  },
  oauthCode: {
    ttlMs: intFromEnv('OAUTH_CODE_TTL_MS', 5 * 60 * 1000),
  },
  adminJwt: {
    secret: requireSecret('ADMIN_JWT_SECRET', 'dev-admin-secret-change-me'),
    expiresIn: process.env.ADMIN_JWT_EXPIRES_IN || '1d',
  },
  uploader: {
    baseUrl: process.env.UPLOADER_BASE_URL || 'https://uploader.qiansmile.com/api',
    allowedImagePrefixes: csvFromEnv('UPLOADER_ALLOWED_IMAGE_PREFIXES', []),
  },
  authProviders: loadAuthProviders(),
  namespace: {
    minLength: 1,
    maxLength: 80,
  },
  noteColors,
  rateLimit: {
    redisUrl: process.env.REDIS_URL || (isProduction ? 'redis://redis:6379' : ''),
    keySecret: requireSecret('RATE_LIMIT_KEY_SECRET', 'dev-rate-limit-secret-change-me'),
    policies: {
      global: {
        windowMs: intFromEnv('RATE_LIMIT_WINDOW_MS', 60_000),
        max: intFromEnv('RATE_LIMIT_MAX', isProduction ? 120 : 1_000),
      },
      namespaceCreateIp: { windowMs: 60 * 60 * 1000, max: 5 },
      namespaceCreateDevice: { windowMs: 24 * 60 * 60 * 1000, max: 10 },
      namespaceLoginIp: { windowMs: 60 * 1000, max: 30 },
      emailCooldown: { windowMs: 60 * 1000, max: 1 },
      emailDailyAddress: { windowMs: 24 * 60 * 60 * 1000, max: 5 },
      emailDailyIp: { windowMs: 24 * 60 * 60 * 1000, max: 20 },
      uploadGrant: { windowMs: 10 * 60 * 1000, max: 20 },
      authenticatedSync: { windowMs: 60 * 1000, max: 120 },
    },
  },
  web: {
    allowedOrigins: csvFromEnv(
      'WEB_ALLOWED_ORIGINS',
      isProduction
        ? ['https://ivy.leafiy.com']
        : ['http://localhost:3000', 'http://localhost:5173']
    ),
  },
  adminBootstrap: {
    username: process.env.ADMIN_USER || 'admin',
    password: requireSecret('ADMIN_PASSWORD', 'admin'),
  },
};

export const configs = {
  development: {
    ...common,
    mongoUri: process.env.MONGO_URI || 'mongodb://127.0.0.1:27027/ivy-api-dev',
  },
  production: {
    ...common,
    mongoUri: process.env.MONGO_URI || 'mongodb://mongodb:27017/ivy-api',
  },
};

const config = configs[env] || configs.development;
export default config;
