import test from 'node:test';
import assert from 'node:assert/strict';
import { uploadFiles } from '../controllers/upload.js';
import { getDirectUploadAuthorization } from '../services/uploader.js';

test('direct upload authorization targets the public uploader', async () => {
  const originalFetch = global.fetch;
  global.fetch = async (url) => {
    assert.equal(url, 'https://uploader.qiansmile.com/api/init');
    return {
      ok: true,
      async json() {
        return {
          accessToken: 'direct-token',
          expiresIn: new Date(Date.now() + 3_600_000).toISOString(),
        };
      },
    };
  };

  try {
    const authorization = await getDirectUploadAuthorization('ivy/user-1/attachments');
    assert.deepEqual(authorization, {
      uploadURL: 'https://uploader.qiansmile.com/api/upload/files',
      authorization: 'Uploader direct-token',
      filePath: 'ivy/user-1/attachments',
    });
  } finally {
    global.fetch = originalFetch;
  }
});

test('attachment registration rejects URLs outside the authenticated account path', async () => {
  const request = {
    user: { _id: { toString: () => 'user-1' } },
    body: {
      files: [{
        url: 'https://files.qiansmile.com/ivy/user-2/attachments/file.txt',
        uuid: 'uuid-1',
        name: 'file.txt',
        sizeBytes: 5,
        contentType: 'text/plain',
      }],
    },
  };

  await assert.rejects(
    () => uploadFiles(request, {}),
    (error) => error.code === 'FILE_URL_INVALID' && error.statusCode === 422
  );
});
