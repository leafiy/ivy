import jwt from 'jsonwebtoken';
import config from '../config/index.js';
import ClientSession from '../models/clientSession.model.js';
import { loadPrincipal } from '../services/clientSession.js';
import { apiError } from './validate.js';

export const authenticateClient = async (req, _res, next) => {
  try {
    const header = req.get('authorization') || '';
    const [scheme, token] = header.split(' ');
    if (scheme !== 'Bearer' || !token) {
      throw apiError(401, 'UNAUTHORIZED', 'Bearer token is required.');
    }

    const payload = jwt.verify(token, config.clientJwt.secret);
    if (payload.type !== 'client' || !payload.sid || !payload.deviceId) {
      throw apiError(401, 'UNAUTHORIZED', 'Invalid token audience.');
    }

    const session = await ClientSession.findOne({
      _id: payload.sid,
      principalId: payload.sub,
      deviceId: payload.deviceId,
      revokedAt: null,
      expiresAt: { $gt: new Date() },
    });
    if (!session) {
      throw apiError(401, 'UNAUTHORIZED', 'Session is invalid or revoked.');
    }

    const principal = await loadPrincipal(payload.sub, payload.principalType);
    if (!principal) {
      throw apiError(401, 'UNAUTHORIZED', 'Account or namespace no longer exists.');
    }

    req.user = principal;
    req.userId = principal._id;
    req.principalType = payload.principalType;
    req.clientSession = session;
    req.deviceId = payload.deviceId;
    next();
  } catch (error) {
    if (error.name === 'JsonWebTokenError' || error.name === 'TokenExpiredError') {
      next(apiError(401, 'UNAUTHORIZED', 'Invalid or expired token.'));
      return;
    }
    next(error);
  }
};

export default authenticateClient;
