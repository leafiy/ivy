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

For production, `./api/deploy.sh` stages and pushes the current branch, uploads that exact revision to the `leafiy.com` server, builds an isolated MongoDB and API runtime, installs the Caddy sites, and runs public HTTPS smoke tests. macOS clients use `https://ivy-api.leafiy.com`; `https://ivy.leafiy.com` is reserved for a future web client and does not expose the admin. The admin remains local-only, with its Vite development proxy targeting the production API. The uploader remains `https://uploader.qiansmile.com/api`. Run `./api/deploy.sh --help` for prerequisites and environment overrides.

See `api/config/README.md` for email and Google provider fields. Notes sync as one portable SQLite database. The database limit is 10 MB per account; attachments have a separate 50 MB limit and store only their uploaded URLs in SQLite.

Ivy has two separate sync identities. A public namespace is password-free and shareable with anyone who knows its name. Google and email create private accounts; there are no account-binding or namespace-upgrade flows.

## Build the macOS app

The app requires macOS 14, Swift 5.10, and the sibling `leafiy-ui` Swift package at `../leafiy-ui`.

```sh
sh build-app.sh
```

Icon assets required for packaging are `ivy.png` and `Sources/Ivy/Resources/Icons/ivy.png`.

Interface and rich-text controls use a curated, source-faithful SVG subset of [Lucide Icons](https://lucide.dev/) 1.27.0 through the semantic `IvyIcon` mapping. The Lucide/Feather license notice ships in `Sources/Ivy/Resources/Licenses/Lucide.txt`.
