import test from 'node:test';
import assert from 'node:assert/strict';
import { sendVerificationCode } from '../services/email.js';

test('verification email uses the configured Ivy sender', async () => {
  let endpoint;
  let requestOptions;
  const request = async (url, options) => {
    endpoint = url;
    requestOptions = options;
    return { ok: true };
  };

  const result = await sendVerificationCode('reader@example.com', '123456', request);
  const parameters = Object.fromEntries(requestOptions.body);

  assert.equal(endpoint, 'https://dm.aliyuncs.com');
  assert.equal(requestOptions.method, 'POST');
  assert.equal(parameters.AccountName, 'admin@ivy.leafiy.com');
  assert.equal(parameters.FromAlias, 'admin@ivy.leafiy.com');
  assert.equal(parameters.ToAddress, 'reader@example.com');
  assert.equal(parameters.Subject, 'Ivy 邮箱验证码');
  assert.match(parameters.HtmlBody, /123456/);
  assert.notEqual(parameters.Signature, '');
  assert.deepEqual(result, { queued: true });
});
