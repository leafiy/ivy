import express from 'express';
import config from './config/index.js';
import connectDb from './db.js';
import routes from './routes.js';
import browserCors from './middleware/cors.js';
import {
  connectRateLimitStore,
  createRateLimiter,
  requestIp,
} from './services/rateLimit.js';
import { bootstrapAdmin } from './controllers/admin.js';
import { flushAllNotes } from './services/noteDatabase.js';

const app = express();

const globalPolicy = config.rateLimit.policies.global;
const globalRateLimiter = createRateLimiter({
  scope: 'global-ip',
  limit: globalPolicy.max,
  windowMs: globalPolicy.windowMs,
  key: requestIp,
});

app.disable('x-powered-by');
if (config.env === 'production') {
  app.set('trust proxy', 1);
}

app.use(browserCors);
app.use(globalRateLimiter);
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
await connectRateLimitStore();

const server = app.listen(config.port, () => {
  console.log(`ivy-api listening on ${config.port}`);
});

// Online-only means the browser keeps no copy: a debounced note edit exists
// only here until it reaches OSS, so shutdown has to wait for it.
let shuttingDown = false;
const shutdown = async (signal) => {
  if (shuttingDown) return;
  shuttingDown = true;
  console.log(`ivy-api received ${signal}, flushing pending note databases`);
  server.close();
  await flushAllNotes();
  process.exit(0);
};
for (const signal of ['SIGTERM', 'SIGINT']) {
  process.on(signal, () => { shutdown(signal); });
}

export { app, server };
export default app;
