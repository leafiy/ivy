# node:sqlite — which the notes-database bridge needs to read and write the
# portable snapshot — stopped requiring --experimental-sqlite in Node 22.13.0.
# The floating 22 tag is already well past that and only moves forward; see
# `engines` in package.json.
FROM node:22-slim

WORKDIR /app

COPY package.json pnpm-lock.yaml ./
RUN corepack enable \
    && pnpm install --frozen-lockfile --prod

ARG IVY_SOURCE_REVISION=development
LABEL org.opencontainers.image.revision=$IVY_SOURCE_REVISION
# The label is for `docker image inspect`; the process reads the env, and
# reports it from /api/v1/health so deploy.sh can check who answers the port.
ENV IVY_SOURCE_REVISION=$IVY_SOURCE_REVISION

COPY . .

ENV NODE_ENV=production
CMD ["node", "app.js"]
