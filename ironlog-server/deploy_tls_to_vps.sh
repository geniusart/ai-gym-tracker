#!/usr/bin/env bash
set -euo pipefail

# Deploys the IronLog API to the production VDS (see docs/DEPLOY.md).
#
# Layout on the box (see /opt/ironlog/server/.env):
#   /opt/ironlog/server   compose project "ironlog": app, mongo
#   /opt/ironlog/schemas  mounted into app as /schemas
#   /opt/ironlog/docs     mounted into app as /docs
#
# The VDS is shared with other tenants. ironlog has no Caddy of its own: TLS
# ends in the host Caddy, whose /etc/caddy/Caddyfile is hand-maintained and
# multi-tenant (opencall.guru, mif.academy, egorianin.ru, ...). It is never
# synced from here. The compose file publishes ports on 127.0.0.1 only.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVER="${IRONLOG_DEPLOY_SERVER:-root@185.92.222.132}"
REMOTE_DIR="${IRONLOG_DEPLOY_DIR:-/opt/ironlog/server}"
REMOTE_ROOT="$(dirname "${REMOTE_DIR}")"
PUBLIC_HOST="${IRONLOG_PUBLIC_HOST:-ironlog.egorianin.ru}"
SSH_KEY="${IRONLOG_DEPLOY_SSH_KEY:-${HOME}/.ssh/shorts_lab_vds_ed25519}"
# Short path with a connection hash: macOS $TMPDIR is long enough to break
# the 104-byte limit on unix socket paths.
CONTROL_PATH="/tmp/ironlog-deploy-%C"
SSH_OPTS=(
  -o ControlMaster=auto
  -o ControlPersist=5m
  -o ControlPath="${CONTROL_PATH}"
)
# The host allows key-only login with MaxAuthTries 3: offer just this key.
if [[ -f "${SSH_KEY}" ]]; then
  SSH_OPTS+=(-o IdentitiesOnly=yes -i "${SSH_KEY}")
fi
RSYNC_SSH="ssh ${SSH_OPTS[*]}"

echo "Deploying IronLog API to ${SERVER}:${REMOTE_DIR}"

ssh "${SSH_OPTS[@]}" "${SERVER}" "mkdir -p '${REMOTE_DIR}' '${REMOTE_ROOT}/schemas' '${REMOTE_ROOT}/docs' '${REMOTE_ROOT}/deploy-backups'"
ssh "${SSH_OPTS[@]}" "${SERVER}" "cd '${REMOTE_DIR}' && tar --exclude='.venv*' --exclude='.pytest_cache' -czf '${REMOTE_ROOT}/deploy-backups/pre-deploy-$(date +%Y%m%d-%H%M%S).tgz' . || true"

# Application code and the compose file only. .env stays untouched, and the
# host Caddyfile is not ours to sync (see header).
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

# rsync -a keeps local modes, and a local 0600 doc is unreadable for the
# container's non-root appuser (503 on /agent-instructions/plan-import).
# macOS openrsync has no --chmod, so fix the modes on the host.
ssh "${SSH_OPTS[@]}" "${SERVER}" "chmod -R a+rX '${REMOTE_ROOT}/schemas' '${REMOTE_ROOT}/docs'"

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
