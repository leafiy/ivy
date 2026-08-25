import config from '../config/index.js';
import { apiError } from '../middleware/validate.js';

let cachedToken = null;
let tokenExpiresAt = 0;

const endpoint = (path) => `${config.uploader.baseUrl.replace(/\/$/, '')}${path}`;

const initUploaderToken = async () => {
  const response = await fetch(endpoint('/init'), {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({}),
  });

  if (!response.ok) {
    throw apiError(502, 'UPLOADER_UNAVAILABLE', 'Failed to initialize uploader token.');
  }

  const body = await response.json();
  const expiresAt = typeof body.expiresIn === 'number'
    ? Date.now() + body.expiresIn * 1000
    : Date.parse(body.expiresIn);
  if (!body.accessToken || !Number.isFinite(expiresAt)) {
    throw apiError(502, 'UPLOADER_BAD_RESPONSE', 'Uploader init response is invalid.');
  }

  cachedToken = body.accessToken;
  tokenExpiresAt = expiresAt - 60_000;
  return cachedToken;
};

const getUploaderToken = async (forceRefresh = false) => {
  if (!forceRefresh && cachedToken && Date.now() < tokenExpiresAt) {
    return cachedToken;
  }
  return initUploaderToken();
};

export const getDirectUploadAuthorization = async (filePath) => ({
  uploadURL: endpoint('/upload/files'),
  authorization: `Uploader ${await getUploaderToken()}`,
  filePath,
});

const postFiles = async (files, filePath, token) => {
  const form = new FormData();
  for (const file of files) {
    const blob = new Blob([file.buffer], { type: file.mimetype || 'application/octet-stream' });
    form.append('files', blob, file.originalname || 'file');
  }
  if (filePath) {
    form.append('filePath', filePath);
  }

  return fetch(endpoint('/upload/files'), {
    method: 'POST',
    headers: {
      'uploader-authorization': `Uploader ${token}`,
    },
    body: form,
  });
};

export const uploadFilesToLatte = async (files, { filePath }) => {
  let token = await getUploaderToken();
  let response = await postFiles(files, filePath, token);

  if (response.status === 401 || response.status === 403) {
    token = await getUploaderToken(true);
    response = await postFiles(files, filePath, token);
  }

  if (!response.ok) {
    throw apiError(502, 'UPLOADER_UNAVAILABLE', 'Uploader file upload failed.');
  }

  const body = await response.json();
  return {
    urls: Array.isArray(body.urls) ? body.urls : [],
    uuids: Array.isArray(body.uuids) ? body.uuids : [],
  };
};
