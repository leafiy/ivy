# Authentication provider configuration

Copy `auth.providers.example.json` to the ignored `auth.providers.json`, then fill the local or host-only copy. Providers remain hidden/disabled in Ivy until `enabled` is `true` and the required values are present.

- `email.aliyun`: Aliyun DirectMail endpoint, access keys, sending account, and sender alias.
- `google.clientId` and `google.clientSecret`: Google OAuth web client credentials.
- `google.audiences`: accepted Google ID-token audiences. It may be left empty to use `clientId`.
- `google.redirectURIs`: maps `NODE_ENV` values to authorized Google redirect URIs. Each URI must be registered on the same OAuth web client and point to `/api/v1/auth/oauth/google/callback` on the corresponding API host. The legacy `google.redirectURI` value remains supported as a fallback.
- `google.appCallbackURL`: keep `ivy://oauth/google` unless the app URL scheme is changed too.

Never commit `auth.providers.json`. In Docker Compose the ignored JSON file is mounted read-only into the API container, so production values remain outside both the canonical repository and its public mirror.
