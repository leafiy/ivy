import { createHmac, randomUUID } from 'node:crypto';
import config from '../config/index.js';

const percentEncode = (value) => encodeURIComponent(String(value))
  .replaceAll('!', '%21')
  .replaceAll("'", '%27')
  .replaceAll('(', '%28')
  .replaceAll(')', '%29')
  .replaceAll('*', '%2A');

const sendWithAliyunDirectMail = async (email, code, directMailConfig, request) => {
  const parameters = {
    AccessKeyId: directMailConfig.accessKeyId,
    AccountName: directMailConfig.accountName,
    Action: 'SingleSendMail',
    AddressType: '1',
    Format: 'JSON',
    FromAlias: directMailConfig.fromAlias || 'Ivy',
    HtmlBody: `<p>您的 Ivy 验证码是：<strong>${code}</strong></p><p>验证码 10 分钟内有效。</p>`,
    RegionId: directMailConfig.regionId || 'cn-hangzhou',
    ReplyToAddress: 'false',
    SignatureMethod: 'HMAC-SHA1',
    SignatureNonce: randomUUID(),
    SignatureVersion: '1.0',
    Subject: 'Ivy 邮箱验证码',
    Timestamp: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'),
    ToAddress: email,
    Version: '2015-11-23',
  };
  const canonicalized = Object.keys(parameters)
    .sort()
    .map((key) => `${percentEncode(key)}=${percentEncode(parameters[key])}`)
    .join('&');
  const stringToSign = `POST&%2F&${percentEncode(canonicalized)}`;
  parameters.Signature = createHmac('sha1', `${directMailConfig.accessKeySecret}&`)
    .update(stringToSign)
    .digest('base64');

  const response = await request(directMailConfig.endpoint || 'https://dm.aliyuncs.com', {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded; charset=utf-8' },
    body: new URLSearchParams(parameters),
  });
  if (!response.ok) {
    const body = await response.text();
    throw new Error(`Aliyun DirectMail rejected the message (${response.status}): ${body.slice(0, 300)}`);
  }
  return { queued: true };
};

export const sendVerificationCode = async (email, code, request = fetch) => {
  const emailConfig = config.authProviders?.email || {};
  const directMailConfig = emailConfig.aliyun || {};

  if (!emailConfig.enabled) {
    throw new Error('Email registration is not enabled in auth.providers.json.');
  }
  if (emailConfig.provider !== 'aliyun-direct-mail') {
    throw new Error(`Unsupported email provider: ${emailConfig.provider || 'missing'}.`);
  }
  if (!directMailConfig.accessKeyId || !directMailConfig.accessKeySecret || !directMailConfig.accountName) {
    throw new Error('Aliyun DirectMail is incomplete in auth.providers.json.');
  }

  return sendWithAliyunDirectMail(email, code, directMailConfig, request);
};

export default { sendVerificationCode };
