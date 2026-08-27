#!/usr/bin/env bash
# Deploy Ivy's API to the leafiy.com production server.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

DEPLOY_HOST="${DEPLOY_HOST:-47.88.53.44}"
DEPLOY_USER="${DEPLOY_USER:-root}"
DEPLOY_SSH_PORT="${DEPLOY_SSH_PORT:-2222}"
REMOTE_BASE="${REMOTE_BASE:-/root/code/ivy}"
DEPLOY_REMOTE="${DEPLOY_REMOTE:-origin}"
DEPLOY_BRANCH="${DEPLOY_BRANCH:-$(git branch --show-current)}"
DEPLOY_COMMIT_MESSAGE="${DEPLOY_COMMIT_MESSAGE:-Deploy Ivy}"
EXPECTED_PUBLIC_IP="${EXPECTED_PUBLIC_IP:-$DEPLOY_HOST}"
DNS_OVER_HTTPS_URL="${DNS_OVER_HTTPS_URL:-https://dns.google/resolve}"
KEEP_RELEASES="${KEEP_RELEASES:-5}"

SITE_DOMAIN="ivy.leafiy.com"
API_DOMAIN="ivy-api.leafiy.com"
API_PORT="7788"
UPLOADER_BASE_URL="https://uploader.qiansmile.com/api"
CADDY_SOURCE="$SCRIPT_DIR/deploy/ivy.caddy"
CADDY_TARGET="/etc/caddy/sites/ivy.caddy"
# The API release lives under /root and is mode 0700. Caddy does not run as
# root, so the static client gets its own world-readable tree instead of being
# served out of there.
WEB_ROOT="${WEB_ROOT:-/srv/ivy-web}"
AUTH_CONFIG="$SCRIPT_DIR/config/auth.providers.json"

SSH=(
  ssh
  -p "$DEPLOY_SSH_PORT"
  -o BatchMode=yes
  -o StrictHostKeyChecking=accept-new
  -o ConnectTimeout=10
  -o ServerAliveInterval=15
  -o ServerAliveCountMax=3
  "$DEPLOY_USER@$DEPLOY_HOST"
)
SCP=(
  scp
  -P "$DEPLOY_SSH_PORT"
  -o BatchMode=yes
  -o StrictHostKeyChecking=accept-new
)

temporary_directory=""
release_id=""
remote_release=""

cleanup() {
  if [ -n "$temporary_directory" ]; then
    rm -rf "$temporary_directory"
  fi
}
trap cleanup EXIT

info() { printf '\033[1m%s\033[0m\n' "$*"; }
ok() { printf '\033[0;32mOK\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mERR\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage:
  ./api/deploy.sh

Deploys a fresh Ivy MongoDB and the Express API to the same server as
leafiy.com:
  - https://$API_DOMAIN -> Ivy API on 127.0.0.1:$API_PORT
  - https://$SITE_DOMAIN -> the Ivy web client, served from the release's web/dist

The deployment commits and pushes the current branch, uploads that exact
revision, builds the API image on the production host, installs the Caddy sites,
and verifies both public HTTPS surfaces. Production data from the retired
server is intentionally not migrated. The local-only admin proxies its
development requests to the production API. The uploader remains fixed at
$UPLOADER_BASE_URL.

Environment overrides:
  DEPLOY_HOST, DEPLOY_USER, DEPLOY_SSH_PORT, REMOTE_BASE
  DEPLOY_REMOTE, DEPLOY_BRANCH, DEPLOY_COMMIT_MESSAGE
  EXPECTED_PUBLIC_IP, DNS_OVER_HTTPS_URL, KEEP_RELEASES
EOF
}

validate_inputs() {
  for command in curl git jq pnpm scp ssh tar; do
    command -v "$command" >/dev/null || fail "$command is required"
  done
  [ -n "$DEPLOY_BRANCH" ] || fail "deployment requires a named Git branch"
  case "$KEEP_RELEASES" in
    ''|*[!0-9]*|0) fail "KEEP_RELEASES must be a positive integer" ;;
  esac
  [ -f "$AUTH_CONFIG" ] || fail "authentication provider config is missing: $AUTH_CONFIG"
  [ -f "$CADDY_SOURCE" ] || fail "Caddy site config is missing: $CADDY_SOURCE"
  [ -f docker-compose.yml ] || fail "docker-compose.yml is missing"
  jq -e '
    type == "object"
    and (.email.enabled == true)
    and (.google.enabled == true)
    and (.google.redirectURIs.production == "https://ivy-api.leafiy.com/api/v1/auth/oauth/google/callback")
  ' "$AUTH_CONFIG" >/dev/null || fail "authentication providers are not enabled for $API_DOMAIN"
}

check_domain() {
  local domain="$1" response status addresses
  response="$(curl --retry 3 --retry-delay 1 --retry-connrefused -fsS \
    --get \
    --data-urlencode "name=$domain" \
    --data-urlencode "type=A" \
    "$DNS_OVER_HTTPS_URL")" || fail "cannot resolve $domain through $DNS_OVER_HTTPS_URL"
  status="$(printf '%s' "$response" | jq -er '.Status')" || fail "invalid DNS response for $domain"
  [ "$status" = "0" ] || fail "DNS lookup for $domain returned status $status"
  addresses="$(printf '%s' "$response" | jq -r '.Answer[]? | select(.type == 1) | .data')"
  printf '%s\n' "$addresses" | grep -Fxq "$EXPECTED_PUBLIC_IP" || {
    printf 'A records for %s: %s\n' "$domain" "${addresses:-none}" >&2
    fail "$domain must point to $EXPECTED_PUBLIC_IP"
  }
}

check_remote() {
  info "Check leafiy.com production host"
  "${SSH[@]}" 'set -e
    command -v caddy >/dev/null
    command -v curl >/dev/null
    command -v docker >/dev/null
    command -v jq >/dev/null
    command -v openssl >/dev/null
    docker compose version >/dev/null
    systemctl is-active --quiet caddy
    ! docker ps --format "{{.Ports}}" | grep -q "127.0.0.1:7788->" || docker ps --format "{{.Names}}" | grep -Fxq ivy-api-1'
  ok "production host is ready"
}


commit_and_push_source() {
  info "Commit and push deployment source"
  git add -A
  if ! git diff --cached --quiet; then
    git commit -m "$DEPLOY_COMMIT_MESSAGE"
  fi
  [ -z "$(git status --porcelain)" ] || fail "working tree changed during commit"

  local commit remote_commit
  commit="$(git rev-parse HEAD)"
  git push "$DEPLOY_REMOTE" "HEAD:refs/heads/$DEPLOY_BRANCH"
  remote_commit="$(git ls-remote --exit-code "$DEPLOY_REMOTE" "refs/heads/$DEPLOY_BRANCH" | awk 'NR == 1 { print $1}')" || \
    fail "cannot read $DEPLOY_REMOTE/$DEPLOY_BRANCH"
  [ "$remote_commit" = "$commit" ] || fail "remote branch does not match local commit"

  release_id="$(date -u +%Y%m%dT%H%M%SZ)-${commit:0:12}"
  remote_release="$REMOTE_BASE/releases/$release_id"
  ok "source pushed at $commit"
}

build_web() {
  info "Build the web client"
  # Built here, not on the server: the production host runs the API in a
  # container and has no Node toolchain of its own. dist/ is gitignored, so it
  # travels as its own tarball rather than inside the source archive.
  command -v pnpm >/dev/null || fail "pnpm is required to build the web client"
  ( cd "$SCRIPT_DIR/../web" && pnpm install --frozen-lockfile && pnpm build )
  [ -f "$SCRIPT_DIR/../web/dist/index.html" ] || fail "web build produced no dist/index.html"
  ok "web client built"
}

stage_release() {
  info "Upload immutable release $release_id"
  temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/ivy-deploy.XXXXXX")"
  git archive --format=tar --output="$temporary_directory/source.tar" HEAD
  tar -cf "$temporary_directory/web-dist.tar" -C "$SCRIPT_DIR/../web/dist" .

  "${SSH[@]}" install -d -m 0700 "$remote_release"
  "${SCP[@]}" \
    "$temporary_directory/source.tar" \
    "$temporary_directory/web-dist.tar" \
    "$DEPLOY_USER@$DEPLOY_HOST:$remote_release/"

  "${SSH[@]}" bash -s -- "$REMOTE_BASE" "$remote_release" "$WEB_ROOT" "$release_id" <<'REMOTE'
set -Eeuo pipefail
remote_base="$1"
remote_release="$2"
web_root="$3"
release_id="$4"

mkdir -p "$remote_base/releases" "$remote_base/secrets"
tar -xf "$remote_release/source.tar" -C "$remote_release"
install -m 0600 "$remote_release/api/config/auth.providers.json" "$remote_base/secrets/auth.providers.json"

# The static client goes somewhere Caddy can actually reach. It carries no
# secrets — it is the bundle every visitor downloads — so world-readable is
# exactly right.
install -d -m 0755 "$web_root" "$web_root/releases" "$web_root/releases/$release_id"
tar -xf "$remote_release/web-dist.tar" -C "$web_root/releases/$release_id"
chmod -R a+rX "$web_root/releases/$release_id"
[ -f "$web_root/releases/$release_id/index.html" ]

rm -f "$remote_release/api/config/auth.providers.json" "$remote_release/source.tar" "$remote_release/web-dist.tar"
REMOTE
  ok "release uploaded without leaving credential archives"
}

configure_runtime() {
  info "Configure isolated Ivy runtime"
  "${SSH[@]}" bash -s -- "$REMOTE_BASE" "$remote_release" "$UPLOADER_BASE_URL" "$release_id" <<'REMOTE'
set -Eeuo pipefail
remote_base="$1"
remote_release="$2"
uploader_base_url="$3"
source_revision="$4"
env_file="$remote_base/.env"

mkdir -p "$remote_base"
touch "$env_file"
chmod 600 "$env_file"

append_generated_secret() {
  local name="$1" bytes="$2"
  if ! grep -q "^${name}=" "$env_file"; then
    printf '%s=%s\n' "$name" "$(openssl rand -hex "$bytes")" >>"$env_file"
  fi
}

set_env_value() {
  local name="$1" value="$2" temporary
  temporary="$(mktemp "${env_file}.XXXXXX")"
  awk -v prefix="${name}=" 'index($0, prefix) != 1' "$env_file" >"$temporary"
  printf '%s=%s\n' "$name" "$value" >>"$temporary"
  install -m 0600 "$temporary" "$env_file"
  rm -f "$temporary"
}

set_env_value MONGO_ROOT_USERNAME ivy_root
set_env_value IVY_MONGO_USER ivy_api
append_generated_secret MONGO_ROOT_PASSWORD 32
append_generated_secret IVY_MONGO_PASSWORD 32
append_generated_secret CLIENT_JWT_SECRET 48
append_generated_secret RATE_LIMIT_KEY_SECRET 48
append_generated_secret ADMIN_JWT_SECRET 48
append_generated_secret ADMIN_PASSWORD 24
set_env_value ADMIN_USER admin
set_env_value UPLOADER_BASE_URL "$uploader_base_url"
set_env_value IVY_AUTH_PROVIDERS_CONFIG "$remote_base/secrets/auth.providers.json"

set -a
. "$env_file"
set +a
set_env_value MONGO_URI "mongodb://${IVY_MONGO_USER}:${IVY_MONGO_PASSWORD}@mongo:27017/ivy-api?authSource=ivy-api"

compose=(
  docker compose
  -p ivy
  -f "$remote_release/docker-compose.yml"
  --env-file "$env_file"
  --project-directory "$remote_release"
)

"${compose[@]}" up -d mongo
for attempt in $(seq 1 45); do
  if "${compose[@]}" exec -T mongo mongosh --quiet \
    --username "$MONGO_ROOT_USERNAME" \
    --password "$MONGO_ROOT_PASSWORD" \
    --authenticationDatabase admin \
    --eval 'quit(db.adminCommand({ ping: 1 }).ok ? 0 : 1)' >/dev/null 2>&1; then
    break
  fi
  [ "$attempt" -lt 45 ] || exit 1
  sleep 1
done

"${compose[@]}" exec -T mongo mongosh --quiet \
  --username "$MONGO_ROOT_USERNAME" \
  --password "$MONGO_ROOT_PASSWORD" \
  --authenticationDatabase admin \
  --eval "
    const target = db.getSiblingDB('ivy-api');
    const username = process.env.IVY_MONGO_USER;
    const password = process.env.IVY_MONGO_PASSWORD;
    if (target.getUser(username)) {
      target.updateUser(username, { pwd: password, roles: [{ role: 'readWrite', db: 'ivy-api' }] });
    } else {
      target.createUser({ user: username, pwd: password, roles: [{ role: 'readWrite', db: 'ivy-api' }] });
    }
  " >/dev/null

docker build \
  --build-arg "IVY_SOURCE_REVISION=$source_revision" \
  --tag ivy-api:local \
  "$remote_release/api"
[ "$(docker image inspect -f '{{ index .Config.Labels "org.opencontainers.image.revision" }}' ivy-api:local)" = "$source_revision" ]
"${compose[@]}" up -d --force-recreate --no-build api
for attempt in $(seq 1 45); do
  if curl -fsS "http://127.0.0.1:7788/api/v1/auth/config" | \
    jq -e '.passwordless.enabled and .email.enabled and .google.enabled' >/dev/null 2>&1; then
    break
  fi
  [ "$attempt" -lt 45 ] || {
    "${compose[@]}" logs --tail 100 api >&2
    exit 1
  }
  sleep 1
done

[ "$(docker inspect -f '{{.State.Running}}' ivy-api-1)" = "true" ]
[ "$(docker inspect -f '{{.State.Running}}' ivy-mongo-1)" = "true" ]
REMOTE
  ok "fresh MongoDB and Ivy API are healthy"
}

activate_release() {
  info "Activate Caddy sites"
  "${SSH[@]}" bash -s -- \
    "$REMOTE_BASE" "$remote_release" "$CADDY_TARGET" "$KEEP_RELEASES" "$WEB_ROOT" "$release_id" <<'REMOTE'
set -Eeuo pipefail
remote_base="$1"
remote_release="$2"
caddy_target="$3"
keep_releases="$4"
web_root="$5"
release_id="$6"

# Point the web symlink at this release before Caddy is reloaded, so the
# reload never lands on a root that is not there yet.
ln -sfn "$web_root/releases/$release_id" "$web_root/current.next"
mv -Tf "$web_root/current.next" "$web_root/current"
current_link="$remote_base/current"
previous_release="$(readlink -f "$current_link" 2>/dev/null || true)"
config_backup="$(mktemp /tmp/ivy.caddy.backup.XXXXXX)"
had_config=0
if [ -f "$caddy_target" ]; then
  cp -a "$caddy_target" "$config_backup"
  had_config=1
fi

rollback() {
  if [ -n "$previous_release" ]; then
    ln -sfn "$previous_release" "${current_link}.next"
    mv -Tf "${current_link}.next" "$current_link"
  else
    rm -f "$current_link"
  fi
  if [ "$had_config" = 1 ]; then
    install -m 0600 "$config_backup" "$caddy_target"
  else
    rm -f "$caddy_target"
  fi
  caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1 || true
}
trap rollback ERR

ln -sfn "$remote_release" "${current_link}.next"
mv -Tf "${current_link}.next" "$current_link"
install -m 0600 "$remote_release/api/deploy/ivy.caddy" "$caddy_target"
caddy validate --config /etc/caddy/Caddyfile
caddy reload --config /etc/caddy/Caddyfile
systemctl is-active --quiet caddy

trap - ERR
rm -f "$config_backup"

mapfile -t releases < <(printf '%s\n' "$remote_base"/releases/* | sort -r)
for ((index = keep_releases; index < ${#releases[@]}; index += 1)); do
  [ "${releases[$index]}" = "$previous_release" ] || rm -rf "${releases[$index]}"
done

# Same retention for the client bundles, minus whatever `current` points at.
mapfile -t web_releases < <(find "$web_root/releases" -mindepth 1 -maxdepth 1 -type d | sort -r)
live_web="$(readlink -f "$web_root/current" 2>/dev/null || true)"
for ((index = keep_releases; index < ${#web_releases[@]}; index += 1)); do
  [ "${web_releases[$index]}" = "$live_web" ] || rm -rf "${web_releases[$index]}"
done
REMOTE
  ok "Caddy serves $SITE_DOMAIN and $API_DOMAIN"
}

smoke_test() {
  info "Verify public HTTPS surfaces"
  local provider_config site_status
  provider_config="$(curl --retry 8 --retry-delay 2 --retry-connrefused -fsS \
    "https://$API_DOMAIN/api/v1/auth/config")"
  printf '%s' "$provider_config" | \
    jq -e '.passwordless.enabled and .email.enabled and .google.enabled' >/dev/null

  site_body="$(curl --retry 8 --retry-delay 2 --retry-connrefused -fsS "https://$SITE_DOMAIN/")"
  printf '%s' "$site_body" | grep -q '<div id="root">' \
    || fail "$SITE_DOMAIN did not serve the web client"

  # A deep link has to reach the app, not a 404: the client owns its routing.
  site_status="$(curl --retry 4 --retry-delay 2 -sS -o /dev/null -w '%{http_code}' "https://$SITE_DOMAIN/app")"
  [ "$site_status" = "200" ] || fail "deep link /app returned HTTP $site_status instead of 200"

  # The admin is local-only and must not be reachable from the public site.
  admin_status="$(curl -sS -o /dev/null -w '%{http_code}' "https://$SITE_DOMAIN/admin-api/v1/login" || true)"
  [ "$admin_status" != "200" ] || fail "$SITE_DOMAIN exposed the admin API"
  ok "HTTPS, auth providers, and the web client are healthy"
}

main() {
  case "${1:-}" in
    -h|--help|help) usage; exit 0 ;;
    '') ;;
    *) fail "unknown argument: $1" ;;
  esac

  validate_inputs
  info "Verify public DNS"
  check_domain "$SITE_DOMAIN"
  check_domain "$API_DOMAIN"
  ok "both domains point to $EXPECTED_PUBLIC_IP"
  check_remote
  build_web
  commit_and_push_source
  stage_release
  configure_runtime
  activate_release
  smoke_test
  printf '\n\033[0;32mIvy deployment complete:\033[0m https://%s / https://%s\n' \
    "$SITE_DOMAIN" "$API_DOMAIN"
}

main "$@"
