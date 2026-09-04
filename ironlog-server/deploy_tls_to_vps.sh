#!/usr/bin/env bash
set -euo pipefail

# Deploys the IronLog API to the production VDS.
#
# Layout on the box (see /opt/ironlog/server/.env):
#   /opt/ironlog/server   compose project "server": app, mongo, caddy
#   /opt/ironlog/schemas  mounted into app as /schemas
#   /opt/ironlog/docs     mounted into app as /docs
#
# The VDS is shared with other sites. Its Caddyfile is hand-maintained and
# multi-tenant (egorianin.ru, mif.academy, opencall.guru, ...), and
# docker-compose.override.yml carries the box-specific wiring. Neither file
# is in this repo and neither is ever synced from here -- pushing the
# repo's single-site Caddyfile would take every other site down.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVER="${IRONLOG_DEPLOY_SERVER:-root@72.56.99.246}"
REMOTE_DIR="${IRONLOG_DEPLOY_DIR:-/opt/ironlog/server}"
REMOTE_ROOT="$(dirname "${REMOTE_DIR}")"
PUBLIC_HOST="${IRONLOG_PUBLIC_HOST:-72.56.99.246.nip.io}"
CONTROL_PATH="${TMPDIR:-/tmp}/ironlog-deploy-%r@%h:%p"
SSH_OPTS=(
  -o ControlMaster=auto
  -o ControlPersist=5m
  -o ControlPath="${CONTROL_PATH}"
)
RSYNC_SSH="ssh -o ControlMaster=auto -o ControlPersist=5m -o ControlPath=${CONTROL_PATH}"

echo "Deploying IronLog API to ${SERVER}:${REMOTE_DIR}"

ssh "${SSH_OPTS[@]}" "${SERVER}" "mkdir -p '${REMOTE_DIR}' '${REMOTE_ROOT}/schemas' '${REMOTE_ROOT}/docs' '${REMOTE_ROOT}/deploy-backups'"
ssh "${SSH_OPTS[@]}" "${SERVER}" "cd '${REMOTE_DIR}' && tar --exclude='.venv*' --exclude='.pytest_cache' -czf '${REMOTE_ROOT}/deploy-backups/pre-deploy-$(date +%Y%m%d-%H%M%S).tgz' . || true"

# Application code and the base compose file only. Caddyfile and
# docker-compose.override.yml stay untouched on purpose (see header).
rsync -az --delete -e "${RSYNC_SSH}" \
  "${ROOT_DIR}/ironlog-server/app" \
  "${ROOT_DIR}/ironlog-server/tools" \
  "${ROOT_DIR}/ironlog-server/Dockerfile" \
  "${ROOT_DIR}/ironlog-server/requirements.txt" \
  "${ROOT_DIR}/ironlog-server/docker-compose.yml" \
  "${SERVER}:${REMOTE_DIR}/"

rsync -az --delete -e "${RSYNC_SSH}" \
  "${ROOT_DIR}/schemas/" \
  "${SERVER}:${REMOTE_ROOT}/schemas/"

rsync -az --delete -e "${RSYNC_SSH}" \
  "${ROOT_DIR}/docs/" \
  "${SERVER}:${REMOTE_ROOT}/docs/"

ssh "${SSH_OPTS[@]}" "${SERVER}" "cd '${REMOTE_DIR}' && touch .env && \
  (grep -q '^IRONLOG_SCHEMAS_DIR=' .env || printf '\nIRONLOG_SCHEMAS_DIR=${REMOTE_ROOT}/schemas\n' >> .env) && \
  (grep -q '^IRONLOG_DOCS_DIR=' .env || printf '\nIRONLOG_DOCS_DIR=${REMOTE_ROOT}/docs\n' >> .env) && \
  docker compose config >/dev/null && \
  docker compose up --build -d && \
  docker compose ps && \
  docker compose logs --tail=40 app"

echo
echo "Deployed. Check:"
echo "  https://${PUBLIC_HOST}/health"
echo "  https://${PUBLIC_HOST}/docs"
echo "  https://${PUBLIC_HOST}/agent-instructions/plan-import"
