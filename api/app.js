import express from 'express';
import config from './config/index.js';
import connectDb from './db.js';
import routes from './routes.js';
import { bootstrapAdmin } from './controllers/admin.js';

const app = express();

const createRateLimiter = ({ windowMs, max }) => {
  const hits = new Map();

  return (req, res, next) => {
    const now = Date.now();
    const key = req.ip || req.socket.remoteAddress || 'unknown';
    const entry = hits.get(key);

    if (!entry || entry.resetAt <= now) {
      hits.set(key, { count: 1, resetAt: now + windowMs });
      next();
      return;
    }

    entry.count += 1;
    if (entry.count > max) {
      res.status(429).json({ error: { code: 'RATE_LIMITED', message: 'Too many requests.' } });
      return;
    }

    next();
  };
};

app.disable('x-powered-by');
if (config.env === 'production') {
  app.set('trust proxy', 1);
}

app.use(createRateLimiter(config.rateLimit));
app.use(
  express.json({
    limit: '1mb',
    verify: (req, _res, buffer) => {
      if (req.originalUrl?.startsWith('/api/v1/webhooks/')) {
        req.rawBody = Buffer.from(buffer);
      }
    },
  })
);

app.use(routes);

app.use((_req, _res, next) => {
  const error = new Error('Route not found.');
  error.statusCode = 404;
  error.code = 'NOT_FOUND';
  next(error);
});

app.use((err, _req, res, _next) => {
  const isValidation = err.name === 'ValidationError';
  const isDuplicate = err.code === 11000;
  const isMulterLimit = typeof err.code === 'string' && err.code.startsWith('LIMIT_');
  const statusCode = err.statusCode || (isValidation || isMulterLimit ? 422 : isDuplicate ? 409 : 500);
  const code = typeof err.code === 'string'
    ? err.code
    : isDuplicate
      ? 'CONFLICT'
      : isValidation
        ? 'VALIDATION_ERROR'
        : 'INTERNAL_ERROR';
  const message = statusCode >= 500 ? 'Internal server error.' : err.message;

  res.status(statusCode).json({
    error: {
      code,
      message,
      ...(err.details || {}),
    },
  });
});

await connectDb();
await bootstrapAdmin();

const server = app.listen(config.port, () => {
  console.log(`ivy-api listening on ${config.port}`);
});

export { app, server };
export default app;
