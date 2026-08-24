import config from '../config/index.js';

export class ApiError extends Error {
  constructor(statusCode, code, message, details = {}) {
    super(message);
    this.statusCode = statusCode;
    this.code = code;
    this.details = details;
  }
}

export const apiError = (statusCode, code, message, details = {}) =>
  new ApiError(statusCode, code, message, details);

export const asyncHandler = (handler) => (req, res, next) => {
  Promise.resolve(handler(req, res, next)).catch(next);
};

export const normalizeNamespace = (value) => {
  if (typeof value !== 'string') return '';
  return value.normalize('NFKC').trim().replace(/\s+/gu, ' ');
};

export const namespaceKey = (value) => normalizeNamespace(value).toLocaleLowerCase('en-US');

export const isValidNamespace = (value) => {
  const name = normalizeNamespace(value);
  const length = Array.from(name).length;
  return length >= config.namespace.minLength
    && length <= config.namespace.maxLength
    && !/[\p{Cc}\p{Cf}\p{Cs}]/u.test(name);
};

export const assertNamespace = (value) => {
  if (!isValidNamespace(value)) {
    throw apiError(
      422,
      'NAMESPACE_INVALID',
      `Namespace must be ${config.namespace.minLength}-${config.namespace.maxLength} visible characters.`
    );
  }
};

export const assertColor = (color) => {
  if (!config.noteColors.includes(color)) {
    throw apiError(422, 'COLOR_INVALID', 'Note color is not supported.');
  }
};

export const parseIsoDate = (value, fieldName) => {
  if (value === null || value === undefined) return null;
  if (typeof value !== 'string') {
    throw apiError(422, 'DATE_INVALID', `${fieldName} must be an ISO8601 UTC string or null.`);
  }
  const date = new Date(value);
  if (Number.isNaN(date.getTime()) || date.toISOString() !== value) {
    throw apiError(422, 'DATE_INVALID', `${fieldName} must be an ISO8601 UTC string or null.`);
  }
  return date;
};

export const requireString = (value, fieldName) => {
  if (typeof value !== 'string' || value.trim() === '') {
    throw apiError(422, 'VALIDATION_ERROR', `${fieldName} is required.`);
  }
  return value.trim();
};
