import jwt from 'jsonwebtoken';
import config from '../config/index.js';
import Admin from '../models/admin.model.js';
import { apiError } from './validate.js';

export const authenticateAdmin = async (req, _res, next) => {
  try {
    const header = req.get('authorization') || '';
    const [scheme, token] = header.split(' ');
    if (scheme !== 'Bearer' || !token) {
      throw apiError(401, 'UNAUTHORIZED', 'Admin bearer token is required.');
    }

    const payload = jwt.verify(token, config.adminJwt.secret);
    if (payload.type !== 'admin') {
      throw apiError(401, 'UNAUTHORIZED', 'Invalid admin token.');
    }

    const admin = await Admin.findById(payload.sub);
    if (!admin) {
      throw apiError(401, 'UNAUTHORIZED', 'Admin no longer exists.');
    }

    req.admin = admin;
    req.adminId = admin._id;
    next();
  } catch (error) {
    if (error.name === 'JsonWebTokenError' || error.name === 'TokenExpiredError') {
      next(apiError(401, 'UNAUTHORIZED', 'Invalid or expired admin token.'));
      return;
    }
    next(error);
  }
};

export default authenticateAdmin;
