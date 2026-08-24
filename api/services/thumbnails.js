import sharp from 'sharp';

export const THUMBNAIL_MAX_WIDTH = 600;

/**
 * Image formats sharp can decode reliably. Every other upload (including
 * exotic image types) is stored as-is and rendered as a plain file row.
 */
const THUMBNAILABLE_TYPES = new Set([
  'image/jpeg',
  'image/png',
  'image/webp',
  'image/gif',
  'image/avif',
  'image/tiff',
  'image/bmp',
  'image/svg+xml',
  'image/heic',
  'image/heif',
]);

export const isThumbnailableImage = (contentType) =>
  THUMBNAILABLE_TYPES.has(String(contentType || '').toLowerCase());

/**
 * Compresses one uploaded image into a webp thumbnail no wider than 600px.
 * Never upscales smaller originals.
 */
export const createThumbnail = async (buffer) =>
  sharp(buffer)
    .rotate()
    .resize({ width: THUMBNAIL_MAX_WIDTH, withoutEnlargement: true })
    .webp({ quality: 80 })
    .toBuffer();

export const thumbnailFilename = (originalName) => {
  const base = String(originalName || 'image').replace(/\.[^.]*$/, '') || 'image';
  return `${base}.thumb.webp`;
};
