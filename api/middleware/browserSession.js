import { randomBytes, timingSafeEqual } from 'node:crypto';
import config from '../config/index.js';
import { apiError } from './validate.js';

const REFRESH_COOKIE = 'ivy_refresh';
const CSRF_COOKIE = 'ivy_csrf';

const parseCookies = (header = '') => Object.fromEntries(
  header
    .split(';')
    .map((part) => part.trim())
    .filter(Boolean)
    .map((part) => {
      const separator = part.indexOf('=');
      if (separator < 0) return [part, ''];
      return [part.slice(0, separator), decodeURIComponent(part.slice(separator + 1))];
    })
);

const cookie = (name, value, { httpOnly = false, maxAge = null } = {}) => {
  const parts = [
    `${name}=${encodeURIComponent(value)}`,
    'Path=/api/v1/auth',
    'SameSite=Lax',
  ];
  if (httpOnly) parts.push('HttpOnly');
  if (config.env === 'production') parts.push('Secure');
  if (maxAge !== null) parts.push(`Max-Age=${Math.max(0, Math.floor(maxAge / 1000))}`);
  return parts.join('; ');
};

export const isWebClient = (req) => req.get('x-ivy-client') === 'web';

export const refreshTokenFromRequest = (req) => {
  if (isWebClient(req)) {
    return parseCookies(req.get('cookie'))[REFRESH_COOKIE] || '';
  }
  return req.body?.refreshToken || '';
};

export const setBrowserSessionCookies = (res, refreshToken) => {
  const csrfToken = randomBytes(24).toString('base64url');
  res.append('Set-Cookie', cookie(REFRESH_COOKIE, refreshToken, {
    httpOnly: true,
    maxAge: config.refreshToken.ttlMs,
  }));
  res.append('Set-Cookie', cookie(CSRF_COOKIE, csrfToken, {
    maxAge: config.refreshToken.ttlMs,
  }));
  return csrfToken;
};

export const clearBrowserSessionCookies = (res) => {
  res.append('Set-Cookie', cookie(REFRESH_COOKIE, '', { httpOnly: true, maxAge: 0 }));
  res.append('Set-Cookie', cookie(CSRF_COOKIE, '', { maxAge: 0 }));
};

export const requireWebCsrf = (req, _res, next) => {
  if (!isWebClient(req)) {
    next();
    return;
  }
  const cookies = parseCookies(req.get('cookie'));
  const cookieToken = cookies[CSRF_COOKIE] || '';
  const headerToken = req.get('x-csrf-token') || '';
  const cookieBytes = Buffer.from(cookieToken);
  const headerBytes = Buffer.from(headerToken);
  if (
    cookieBytes.length === 0
    || cookieBytes.length !== headerBytes.length
    || !timingSafeEqual(cookieBytes, headerBytes)
  ) {
    next(apiError(403, 'CSRF_INVALID', 'CSRF token is missing or invalid.'));
    return;
  }
  next();
};
