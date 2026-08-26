import config from '../config/index.js';
import { apiError } from './validate.js';

const allowedHeaders = 'authorization, content-type, x-csrf-token, x-ivy-client';
const allowedMethods = 'DELETE, GET, OPTIONS, PATCH, POST, PUT';

export const browserCors = (req, res, next) => {
  const origin = req.get('origin');
  if (!origin) {
    next();
    return;
  }
  if (!config.web.allowedOrigins.includes(origin)) {
    next(apiError(403, 'ORIGIN_NOT_ALLOWED', 'Request origin is not allowed.'));
    return;
  }

  res.set('Access-Control-Allow-Origin', origin);
  res.set('Access-Control-Allow-Credentials', 'true');
  res.set('Access-Control-Allow-Headers', allowedHeaders);
  res.set('Access-Control-Allow-Methods', allowedMethods);
  res.set('Vary', 'Origin');
  if (req.method === 'OPTIONS') {
    res.status(204).end();
    return;
  }
  next();
};

export default browserCors;
