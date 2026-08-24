FROM node:22-slim

WORKDIR /app

COPY package.json ./
# This skeleton intentionally has no lockfile yet; after the first install creates one,
# switch this layer to `npm ci --omit=dev` for reproducible production builds.
RUN npm install --omit=dev

COPY . .

ENV NODE_ENV=production
CMD ["node", "app.js"]
