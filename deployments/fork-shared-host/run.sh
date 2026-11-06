#!/usr/bin/env bash
# Build and run THIS Plane fork on the shared Contabo host.
# Never pulls makeplane images. Never binds public 80/443.
set -euo pipefail

PRODUCT_SHA="053b2c0e5874fb3225404a8775d04f38f9e1704c"
PRODUCT_BRANCH="preview"
COMPOSE_PROJECT="plane-evo"
LOOPBACK_BIND="127.0.0.1:18080"
FORBIDDEN_HOST="13.140.219.162"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
ENV_FILE="${PLANE_ENV_FILE:-$SCRIPT_DIR/plane.env}"

cd "$REPO_ROOT"

usage() {
  cat <<'EOF'
Usage: run.sh <build|config|up|migrate-wait|health|backup|down|logs> [args]

  build         Sequential image build from this checkout (pull never)
  config        Render compose and run collision/stock-image guards
  up            Start stack (pull never, no implicit image fetch)
  migrate-wait  Block until migrator exits 0
  health        Hit loopback health endpoints
  backup DIR    Tar named volumes into DIR/<timestamp>/
  down          Stop containers (volumes kept)
  logs [svc]    Follow logs

Requires: Docker Compose v2, plane.env (copy of plane.env.example with secrets filled).
Does not generate secrets. Does not touch DNS, nginx enablement, or 13.140.219.162.
EOF
}

need_env() {
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "Missing $ENV_FILE — copy plane.env.example and fill REPLACE_* values." >&2
    exit 1
  fi
}

set_image_tag() {
  local head
  head="$(git -C "$REPO_ROOT" rev-parse --short=12 HEAD)"
  export PLANE_IMAGE_TAG="${PLANE_IMAGE_TAG:-$head}"
}

compose() {
  docker compose \
    -p "$COMPOSE_PROJECT" \
    -f "$COMPOSE_FILE" \
    --env-file "$ENV_FILE" \
    "$@"
}

refuse_placeholders() {
  if grep -Eq '^[^#]*REPLACE_[A-Z0-9_]+' "$ENV_FILE"; then
    echo "Refuse to start: $ENV_FILE still contains REPLACE_* placeholders. Fill secrets on the host." >&2
    exit 1
  fi
  local key
  for key in SECRET_KEY LIVE_SERVER_SECRET_KEY POSTGRES_PASSWORD RABBITMQ_PASSWORD AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY DATABASE_URL AMQP_URL; do
    local value
    value="$(grep -E "^${key}=" "$ENV_FILE" | tail -n1 | cut -d= -f2- || true)"
    if [[ -z "$value" || "$value" == change-this-key-on-deployment || "$value" == access-key || "$value" == secret-key ]]; then
      echo "Refuse to start: $key is empty or still a stock placeholder. Fill it on the host." >&2
      exit 1
    fi
  done
}

refuse_wrong_host() {
  if [[ "${PLANE_DEPLOY_HOST:-}" == "$FORBIDDEN_HOST" ]]; then
    echo "Refuse to run: $FORBIDDEN_HOST is the EvoCRM VPS and is out of scope." >&2
    exit 1
  fi
}

guard_rendered_compose() {
  local rendered
  rendered="$(compose config)"
  if echo "$rendered" | grep -Eq 'makeplane/plane-'; then
    echo "FATAL: rendered compose still references makeplane/* images. Aborting." >&2
    exit 1
  fi
  if echo "$rendered" | grep -Eq 'published: ["'\'']?(80|443)["'\'']?'; then
    echo "FATAL: rendered compose would publish host 80 or 443 (sibling nginx/Postiz)." >&2
    exit 1
  fi
  if ! echo "$rendered" | grep -q 'plane-evo/plane-frontend'; then
    echo "FATAL: rendered compose is not using plane-evo/* images." >&2
    exit 1
  fi
  echo "Guards passed: fork images, no public 80/443."
}

cmd_config() {
  need_env
  set_image_tag
  refuse_wrong_host
  compose config >/dev/null
  guard_rendered_compose
  echo "Project=$COMPOSE_PROJECT image_tag=$PLANE_IMAGE_TAG loopback=$LOOPBACK_BIND"
  echo "HEAD=$(git -C "$REPO_ROOT" rev-parse HEAD)"
  echo "Product ancestor $PRODUCT_SHA ($PRODUCT_BRANCH) required."
  if git -C "$REPO_ROOT" merge-base --is-ancestor "$PRODUCT_SHA" HEAD; then
    echo "Ancestor check: OK"
  else
    echo "WARNING: HEAD is not descended from $PRODUCT_SHA" >&2
  fi
}

cmd_build() {
  need_env
  set_image_tag
  refuse_wrong_host
  guard_rendered_compose
  echo "Building fork images sequentially. Do not run this on the 8GB VPS while Postiz is live unless swap is confirmed."
  echo "CONTRIBUTING.md: 12 GB RAM recommended for builds; 8 GB often OOMs."
  export COMPOSE_PARALLEL_LIMIT="${COMPOSE_PARALLEL_LIMIT:-1}"
  local svc
  for svc in api proxy live web space admin; do
    echo "=== building $svc (tag $PLANE_IMAGE_TAG) ==="
    compose build --pull never "$svc"
  done
  echo "Build complete. Images:"
  docker images "plane-evo/*:${PLANE_IMAGE_TAG}"
}

cmd_up() {
  need_env
  set_image_tag
  refuse_wrong_host
  refuse_placeholders
  guard_rendered_compose
  compose up -d --pull never --no-build
  cmd_migrate_wait
  cmd_health
}

cmd_migrate_wait() {
  echo "Waiting for migrator plane-evo-migrator..."
  local i=0
  while docker inspect -f '{{.State.Status}}' plane-evo-migrator 2>/dev/null | grep -q running; do
    sleep 2
    i=$((i + 2))
    if [[ "$i" -gt 300 ]]; then
      echo "Migrator still running after 300s. Check: docker logs plane-evo-migrator" >&2
      exit 1
    fi
  done
  local code
  code="$(docker inspect -f '{{.State.ExitCode}}' plane-evo-migrator 2>/dev/null || echo missing)"
  if [[ "$code" != "0" ]]; then
    echo "Migrator exit code: $code" >&2
    docker logs plane-evo-migrator >&2 || true
    exit 1
  fi
  echo "Migrations completed (exit 0)."
}

cmd_health() {
  echo "Health via $LOOPBACK_BIND (host nginx is a separate step)."
  curl -fsS "http://127.0.0.1:18080/" | head -c 200 || {
    echo "API/root health failed on loopback. Is proxy up?" >&2
    exit 1
  }
  echo
  curl -fsS "http://127.0.0.1:18080/live/health/" >/dev/null || {
    echo "Live /live/health/ failed (websocket collab). Check plane-evo-live." >&2
    exit 1
  }
  echo "loopback root OK"
  echo "loopback /live/health/ OK"
  echo "God Mode (first admin): https://plane.evotechly.com/god-mode/"
  echo "App: https://plane.evotechly.com/"
}

cmd_backup() {
  local dest="${1:-}"
  if [[ -z "$dest" ]]; then
    echo "Usage: run.sh backup /var/backups/plane-evo" >&2
    exit 1
  fi
  local stamp
  stamp="$(date +%Y%m%d-%H%M%S)"
  local folder="$dest/$stamp"
  mkdir -p "$folder"
  local vol suffix
  for suffix in pgdata redisdata uploads rabbitmq_data; do
    vol="${COMPOSE_PROJECT}_${suffix}"
    echo "Backing up $vol"
    docker run --rm \
      -v "$vol":/vol:ro \
      -v "$folder":/backup \
      alpine:3.20 \
      tar -czf "/backup/${suffix}.tar.gz" -C /vol .
  done
  echo "Backup written to $folder"
}

cmd_down() {
  need_env
  set_image_tag
  compose down
}

cmd_logs() {
  need_env
  set_image_tag
  if [[ -n "${1:-}" ]]; then
    compose logs -f "$1"
  else
    compose logs -f
  fi
}

main() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    build) cmd_build ;;
    config) cmd_config ;;
    up) cmd_up ;;
    migrate-wait) cmd_migrate_wait ;;
    health) cmd_health ;;
    backup) cmd_backup "${1:-}" ;;
    down) cmd_down ;;
    logs) cmd_logs "${1:-}" ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
