# ivy

This public mirror contains only the macOS application and API source:

- `Sources/IvyCore/`, `Sources/Ivy/`, `Tests/`, `Package.swift`, and `Info.plist` — the macOS sticky-notes application.
- `api/` and `docker-compose.yml` — the Express 5 + Mongoose 8 authentication and sync API.

The admin application, release automation, internal context, and production credentials are maintained separately and are not part of this mirror. The published source is available for inspection; no license to copy, modify, or redistribute it is granted.

## Run the API

The API requires Node.js 22 and MongoDB. Authentication provider credentials belong only in the ignored local configuration:

```sh
cp api/config/auth.providers.example.json api/config/auth.providers.json
cd api
npm install
MONGO_URI='mongodb://127.0.0.1:27027/ivy-api-dev' \
CLIENT_JWT_SECRET='replace-me' \
ADMIN_JWT_SECRET='replace-me' \
ADMIN_PASSWORD='replace-me' \
npm run dev
```

`release.sh` deploys the API before it publishes the app's update feed. When a
release changes what the API sends to existing clients, run it as
`DEPLOY_API=0 sh release.sh` first and `./api/deploy.sh` once those clients have
had a chance to update — otherwise the running version breaks before its
replacement is available.

For production, `./api/deploy.sh` stages and pushes the current branch, uploads that exact revision to the `leafiy.com` server, builds an isolated MongoDB and API runtime, installs the Caddy sites, and runs public HTTPS smoke tests. macOS clients use `https://ivy-api.leafiy.com`; `https://ivy.leafiy.com` serves the web client from `web/`, built by the deploy script and installed under `/srv/ivy-web` where Caddy can read it. Neither domain exposes the admin. The admin remains local-only, with its Vite development proxy targeting the production API. The uploader remains `https://uploader.qiansmile.com/api`. Run `./api/deploy.sh --help` for prerequisites and environment overrides.

See `api/config/README.md` for email and Google provider fields. Notes sync as one portable SQLite database. The database limit is 10 MB per account; attachments have a separate 50 MB limit and store only their uploaded URLs in SQLite.

Ivy has two separate sync identities. A public namespace is password-free and shareable with anyone who knows its name. Google and email create private accounts; there are no account-binding or namespace-upgrade flows.

## Run the web client

The web client requires Node.js 22 and pnpm:

```sh
cd web
pnpm install
pnpm dev      # http://localhost:5173, proxying /api/v1 to the production API
pnpm build    # → web/dist
pnpm test     # the inline-markup parser's boundary table
./deploy.sh   # → https://ivy.leafiy.com
```

`web/deploy.sh` builds `dist/`, uploads it beside the live bundle under
`/srv/ivy-web`, and moves one symlink, so a visitor's next page load is the new
build and there is no half-swapped state in between; a failed smoke test puts
the previous bundle straight back. It touches neither MongoDB, nor the API
container, nor the Caddy configuration — `./api/deploy.sh` owns those, and it
has to have run once so the site exists to swap under. `release.sh` runs
`web/deploy.sh` on every release, ahead of the API.

It is React 19 on [Astryx](https://github.com/facebook/astryx), and it holds no
notes of its own: the API parses and writes the same portable SQLite snapshot
the macOS app syncs, so both clients see one set of notes. See `web/README.md`.

## Debug the whole stack

`docker-compose.dev.yml` brings up Mongo, Redis, the API, and the web client
together, separate from `docker-compose.yml`, which describes production.
`dev.sh` is the short way in — it starts them and then waits until they are
actually answering, which is a good while after the containers exist:

```sh
sh dev.sh            # start, wait, and print what to open
sh dev.sh stop       # stop, keeping the notes
sh dev.sh reset      # stop and throw the notes away
sh dev.sh logs       # follow the API and the web client
```

Or drive compose directly:

```sh
docker compose -f docker-compose.dev.yml up
# API  http://localhost:7799
# web  http://localhost:5199
docker compose -f docker-compose.dev.yml exec mongo mongosh ivy-dev
```

The API runs on `node:22-slim`, the same base the production image uses, so
`node:sqlite` behaves here as it will there. Source is bind-mounted and the API
runs under `node --watch`; `node_modules` lives in a named volume per service
because the host's copies are built for a different platform. The ports avoid
7788 and 5173 on purpose: a native API or Vite already running would claim
those, and on macOS `localhost` resolves to `::1` first, so requests would
quietly reach that one instead of the container.

Without `api/config/auth.providers.json` the API leaves email and Google
disabled and still starts. Public namespaces need no provider, which is enough
to exercise everything about notes and sync.

A debug build of the macOS app can join the same local stack, so the two
clients can be watched syncing against one throwaway database:

```sh
IVY_API_BASE_URL=http://127.0.0.1:7799 swift run ivy
```

`IVY_API_BASE_URL` is read only under `#if DEBUG`; a release build always talks
to production.

With the stack up, one more suite can run — end-to-end checks that drive the
real merge code against the real API, real Mongo, and a real snapshot on OSS.
They skip themselves unless `IVY_INTEGRATION_API` names a stack, so the
ordinary `swift test` stays hermetic and offline:

```sh
IVY_INTEGRATION_API=http://127.0.0.1:7799 \
IVY_INTEGRATION_NAMESPACE=ivy-acceptance-14 \
    swift test --filter LiveSyncIntegrationTests
```

`IVY_INTEGRATION_NAMESPACE` reuses one account across runs; creating a
namespace is capped at five an hour per IP, and minting one per run would
exhaust that by the fifth.

## Build the macOS app

The app requires macOS 14, Swift 5.10, and the sibling `leafiy-ui` Swift package at `../leafiy-ui`.

```sh
sh build-app.sh
```

Icon assets required for packaging are `ivy.png` and `Sources/Ivy/Resources/Icons/ivy.png`.

Interface and rich-text controls use a curated, source-faithful SVG subset of [Lucide Icons](https://lucide.dev/) 1.27.0 through the semantic `IvyIcon` mapping. The Lucide/Feather license notice ships in `Sources/Ivy/Resources/Licenses/Lucide.txt`.
