# Authentication provider configuration

Copy `auth.providers.example.json` to `auth.providers.json`, then fill in the local copy. Providers remain hidden/disabled in Ivy until `enabled` is `true` and the required values are present.

- `email.aliyun`: Aliyun DirectMail endpoint, access keys, sending account, and sender alias.
- `google.clientId` and `google.clientSecret`: Google OAuth web client credentials.
- `google.audiences`: accepted Google ID-token audiences. It may be left empty to use `clientId`.
- `google.redirectURIs`: maps `NODE_ENV` values to authorized Google redirect URIs. Each URI must be registered on the same OAuth web client and point to `/api/v1/auth/oauth/google/callback` on the corresponding API host. The legacy `google.redirectURI` value remains supported as a fallback.
- `google.appCallbackURL`: keep `ivy://oauth/google` unless the app URL scheme is changed too.

The public mirror never contains `auth.providers.json`, and the gitignore rule keeps credentials out of commits here. In Docker Compose the file is mounted read-only into the API container from the host, and `api/.dockerignore` excludes it from the build context, so credentials stay outside the published image.
