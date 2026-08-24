import jwt from 'jsonwebtoken';
import config from '../config/index.js';
import User from '../models/user.model.js';
import Namespace from '../models/namespace.model.js';
import { apiError } from './validate.js';

export const authenticateClient = async (req, _res, next) => {
  try {
    const header = req.get('authorization') || '';
    const [scheme, token] = header.split(' ');
    if (scheme !== 'Bearer' || !token) {
      throw apiError(401, 'UNAUTHORIZED', 'Bearer token is required.');
    }

    const payload = jwt.verify(token, config.clientJwt.secret);
    if (payload.type && payload.type !== 'client') {
      throw apiError(401, 'UNAUTHORIZED', 'Invalid token audience.');
    }

    let principalType = payload.principalType;
    let principal;
    if (principalType === 'namespace') {
      principal = await Namespace.findById(payload.sub);
    } else {
      principal = await User.findById(payload.sub);
      if (!principalType && principal) {
        const isLegacyNamespace = !principal.locked
          && !principal.passwordHash
          && !principal.googleSub;
        principalType = isLegacyNamespace ? 'legacy-namespace' : 'account';
      }
    }
    if (!principal) {
      throw apiError(401, 'UNAUTHORIZED', 'Account or namespace no longer exists.');
    }

    req.user = principal;
    req.userId = principal._id;
    req.principalType = principalType;
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
