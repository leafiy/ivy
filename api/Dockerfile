FROM node:22-slim

WORKDIR /app

COPY package.json pnpm-lock.yaml ./
RUN corepack enable \
    && pnpm install --frozen-lockfile --prod

COPY . .

ENV NODE_ENV=production
CMD ["node", "app.js"]
