FROM node:22-slim

WORKDIR /app

COPY package.json pnpm-lock.yaml ./
RUN corepack enable \
    && pnpm install --frozen-lockfile --prod

ARG IVY_SOURCE_REVISION=development
LABEL org.opencontainers.image.revision=$IVY_SOURCE_REVISION

COPY . .

ENV NODE_ENV=production
CMD ["node", "app.js"]
