import { createHmac } from 'node:crypto';
import config from '../config/index.js';

const redisIncrementScript = `
local count = redis.call('INCR', KEYS[1])
if count == 1 then
  redis.call('PEXPIREAT', KEYS[1], ARGV[1])
end
return count
`;

export class MemoryRateLimitStore {
  constructor() {
    this.entries = new Map();
  }

  async increment(key, resetAt, now = Date.now()) {
    const current = this.entries.get(key);
    if (!current || current.resetAt <= now) {
      this.entries.set(key, { count: 1, resetAt });
      return 1;
    }
    current.count += 1;
    return current.count;
  }

  clear() {
    this.entries.clear();
  }
}

class RedisRateLimitStore {
  constructor(client) {
    this.client = client;
  }

  async increment(key, resetAt) {
    return Number(await this.client.eval(redisIncrementScript, {
      keys: [key],
      arguments: [String(resetAt)],
    }));
  }
}

let activeStore = new MemoryRateLimitStore();
let redisClient = null;

export const connectRateLimitStore = async () => {
  if (!config.rateLimit.redisUrl) return;
  const { createClient } = await import('redis');
  redisClient = createClient({ url: config.rateLimit.redisUrl });
  redisClient.on('error', (error) => console.error('Redis rate-limit error:', error.message));
  await redisClient.connect();
  activeStore = new RedisRateLimitStore(redisClient);
};

export const closeRateLimitStore = async () => {
  if (redisClient?.isOpen) await redisClient.quit();
  redisClient = null;
  activeStore = new MemoryRateLimitStore();
};

export const setRateLimitStoreForTesting = (store) => {
  activeStore = store;
};

const rateLimitKey = (scope, identity) => {
  const digest = createHmac('sha256', config.rateLimit.keySecret)
    .update(String(identity))
    .digest('hex');
  return `ivy:rate-limit:${scope}:${digest}`;
};

export const consumeRateLimit = async ({
  scope,
  identity,
  limit,
  windowMs,
  now = Date.now(),
  store = activeStore,
}) => {
  const resetAt = Math.floor(now / windowMs) * windowMs + windowMs;
  const count = await store.increment(rateLimitKey(scope, identity), resetAt, now);
  return {
    allowed: count <= limit,
    count,
    limit,
    remaining: Math.max(0, limit - count),
    resetAt,
    retryAfterSeconds: Math.max(1, Math.ceil((resetAt - now) / 1000)),
  };
};

export const createRateLimiter = ({ scope, limit, windowMs, key }) =>
  async (req, res, next) => {
    if (req.method === 'OPTIONS') {
      next();
      return;
    }
    try {
      const identity = await key(req);
      const result = await consumeRateLimit({ scope, identity: identity || 'unknown', limit, windowMs });
      res.set('RateLimit-Limit', String(result.limit));
      res.set('RateLimit-Remaining', String(result.remaining));
      res.set('RateLimit-Reset', String(Math.ceil(result.resetAt / 1000)));
      if (!result.allowed) {
        res.set('Retry-After', String(result.retryAfterSeconds));
        res.status(429).json({
          error: {
            code: 'RATE_LIMITED',
            message: 'Too many requests.',
            retryAfterSeconds: result.retryAfterSeconds,
          },
        });
        return;
      }
      next();
    } catch (error) {
      next(error);
    }
  };

export const requestIp = (req) => req.ip || req.socket.remoteAddress || 'unknown';
