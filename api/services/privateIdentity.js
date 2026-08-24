import { createHash } from 'node:crypto';

const supportedProviders = new Set(['email', 'google']);

export const privateAccountHandle = (provider, subject) => {
  if (!supportedProviders.has(provider)) {
    throw new TypeError(`Unsupported private account provider: ${provider}`);
  }
  if (typeof subject !== 'string' || subject.trim() === '') {
    throw new TypeError('Private account subject is required.');
  }
  const digest = createHash('sha256')
    .update(`${provider}\0${subject.trim()}`)
    .digest('hex');
  return `private:${provider}:${digest}`;
};
