import test from 'node:test';
import assert from 'node:assert/strict';
import sharp from 'sharp';
import {
  THUMBNAIL_MAX_WIDTH,
  createThumbnail,
  isThumbnailableImage,
  thumbnailFilename,
} from '../services/thumbnails.js';

test('only decodable image types get thumbnails', () => {
  assert.equal(isThumbnailableImage('image/jpeg'), true);
  assert.equal(isThumbnailableImage('IMAGE/PNG'), true);
  assert.equal(isThumbnailableImage('image/svg+xml'), true);
  assert.equal(isThumbnailableImage('application/pdf'), false);
  assert.equal(isThumbnailableImage('video/mp4'), false);
  assert.equal(isThumbnailableImage(undefined), false);
});

test('thumbnail filenames keep the base name and switch to webp', () => {
  assert.equal(thumbnailFilename('photo.jpeg'), 'photo.thumb.webp');
  assert.equal(thumbnailFilename('archive.tar.gz'), 'archive.tar.thumb.webp');
  assert.equal(thumbnailFilename('noextension'), 'noextension.thumb.webp');
  assert.equal(thumbnailFilename(''), 'image.thumb.webp');
});

test('wide images compress down to 600px-wide webp thumbnails', async () => {
  const source = await sharp({
    create: { width: 1200, height: 400, channels: 3, background: { r: 200, g: 80, b: 120 } },
  }).png().toBuffer();

  const thumbnail = await createThumbnail(source);

  const metadata = await sharp(thumbnail).metadata();
  assert.equal(metadata.format, 'webp');
  assert.equal(metadata.width, THUMBNAIL_MAX_WIDTH);
  assert.equal(metadata.height, 200);
});

test('small images are never upscaled', async () => {
  const source = await sharp({
    create: { width: 320, height: 240, channels: 3, background: { r: 10, g: 20, b: 30 } },
  }).png().toBuffer();

  const thumbnail = await createThumbnail(source);

  const metadata = await sharp(thumbnail).metadata();
  assert.equal(metadata.width, 320);
  assert.equal(metadata.height, 240);
});

test('non-image bytes are rejected instead of producing a broken thumbnail', async () => {
  await assert.rejects(() => createThumbnail(Buffer.from('not an image')));
});
