#!/usr/bin/env bash
#
# Deploy Wallendorf Mattermost fork to production.
#
# Usage:
#   ./scripts/deploy-prod.sh              # build + backup + deploy + verify
#   ./scripts/deploy-prod.sh --skip-build # deploy existing local artifacts only
#   ./scripts/deploy-prod.sh --dry-run    # show what would run
#   ./scripts/deploy-prod.sh --yes        # skip confirmation prompt
#
# Environment overrides:
#   DEPLOY_HOST=157.230.136.231
#   DEPLOY_USER=root
#   MATTERMOST_DIR=/opt/mattermost
#   BUILD_ENTERPRISE=false
#   SSH_KEY=~/.ssh/id_ed25519

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_HOST="${DEPLOY_HOST:-157.230.136.231}"
DEPLOY_USER="${DEPLOY_USER:-root}"
MATTERMOST_DIR="${MATTERMOST_DIR:-/opt/mattermost}"
BUILD_ENTERPRISE="${BUILD_ENTERPRISE:-false}"
SSH_TARGET="${DEPLOY_USER}@${DEPLOY_HOST}"

SERVER_BIN="${REPO_ROOT}/server/bin/linux_amd64/mattermost"
CLIENT_DIR="${REPO_ROOT}/webapp/channels/dist"

SKIP_BUILD=false
SKIP_BACKUP=false
DRY_RUN=false
ASSUME_YES=false

log() { printf '[deploy] %s\n' "$*"; }
run() {
    if [[ "$DRY_RUN" == true ]]; then
        printf '[dry-run] %s\n' "$*"
    else
        eval "$@"
    fi
}

ssh_cmd() {
    local ssh_opts=(-o BatchMode=yes -o ConnectTimeout=15)
    if [[ -n "${SSH_KEY:-}" ]]; then
        ssh_opts+=(-i "$SSH_KEY")
    fi
    if [[ "$DRY_RUN" == true ]]; then
        printf '[dry-run] ssh %s %q\n' "$SSH_TARGET" "$*"
    else
        ssh "${ssh_opts[@]}" "$SSH_TARGET" "$@"
    fi
}

rsync_client() {
    local rsync_opts=(-avz --delete --progress)
    if [[ -n "${SSH_KEY:-}" ]]; then
        rsync_opts+=(-e "ssh -i $SSH_KEY -o BatchMode=yes -o ConnectTimeout=15")
    else
        rsync_opts+=(-e "ssh -o BatchMode=yes -o ConnectTimeout=15")
    fi
    if [[ "$DRY_RUN" == true ]]; then
        printf '[dry-run] rsync %s %s/ %s:%s/client/\n' "${rsync_opts[*]}" "$CLIENT_DIR" "$SSH_TARGET" "$MATTERMOST_DIR"
    else
        rsync "${rsync_opts[@]}" "$CLIENT_DIR/" "${SSH_TARGET}:${MATTERMOST_DIR}/client/"
    fi
}

scp_binary() {
    local scp_opts=(-o BatchMode=yes -o ConnectTimeout=15)
    if [[ -n "${SSH_KEY:-}" ]]; then
        scp_opts+=(-i "$SSH_KEY")
    fi
    if [[ "$DRY_RUN" == true ]]; then
        printf '[dry-run] scp %s %s %s:/tmp/mattermost.new\n' "${scp_opts[*]}" "$SERVER_BIN" "$SSH_TARGET"
    else
        scp "${scp_opts[@]}" "$SERVER_BIN" "${SSH_TARGET}:/tmp/mattermost.new"
    fi
}

usage() {
    sed -n '2,12p' "$0" | sed 's/^# \?//'
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-build) SKIP_BUILD=true ;;
        --no-backup) SKIP_BACKUP=true ;;
        --dry-run) DRY_RUN=true ;;
        --yes|-y) ASSUME_YES=true ;;
        -h|--help) usage 0 ;;
        *) echo "Unknown option: $1" >&2; usage 1 ;;
    esac
    shift
done

build_local() {
    log "Building webapp (branded client)..."
    run "cd \"${REPO_ROOT}/webapp\" && npm ci && make dist"

    log "Building Linux amd64 server binary..."
    run "cd \"${REPO_ROOT}/server\" && make build-cmd-linux BUILD_ENTERPRISE=${BUILD_ENTERPRISE}"
}

verify_artifacts() {
    if [[ ! -f "$SERVER_BIN" ]]; then
        echo "Missing server binary: $SERVER_BIN" >&2
        echo "Run without --skip-build or: cd server && make build-cmd-linux BUILD_ENTERPRISE=${BUILD_ENTERPRISE}" >&2
        exit 1
    fi
    if [[ ! -f "$CLIENT_DIR/root.html" ]]; then
        echo "Missing web client: $CLIENT_DIR/root.html" >&2
        echo "Run without --skip-build or: cd webapp && make dist" >&2
        exit 1
    fi
    log "Artifacts OK:"
    log "  binary: $SERVER_BIN ($(du -h "$SERVER_BIN" | awk '{print $1}'))"
    log "  client: $CLIENT_DIR ($(du -sh "$CLIENT_DIR" | awk '{print $1}'))"
}

preflight() {
    log "Checking SSH to ${SSH_TARGET}..."
    ssh_cmd "echo connected && hostname && test -d '${MATTERMOST_DIR}' && test -f '${MATTERMOST_DIR}/config/config.json'"
}

confirm() {
    if [[ "$ASSUME_YES" == true || "$DRY_RUN" == true ]]; then
        return 0
    fi
    local git_sha
    git_sha="$(cd "$REPO_ROOT" && git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    cat <<EOF

About to deploy to ${SSH_TARGET}
  install dir: ${MATTERMOST_DIR}
  git commit:  ${git_sha}
  binary:      ${SERVER_BIN}
  client:      ${CLIENT_DIR}
  backup:      $([[ "$SKIP_BACKUP" == true ]] && echo skipped || echo yes)

This will STOP Mattermost during deploy.

EOF
    read -r -p "Continue? [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]] || { log "Aborted."; exit 1; }
}

remote_backup() {
    if [[ "$SKIP_BACKUP" == true ]]; then
        log "Skipping remote backup (--no-backup)"
        return 0
    fi

    log "Creating remote backups..."
    ssh_cmd "MATTERMOST_DIR='${MATTERMOST_DIR}' bash -s" <<'REMOTE_BACKUP'
set -euo pipefail
MATTERMOST_DIR="${MATTERMOST_DIR:-/opt/mattermost}"
BACKUP_ROOT="/root/mattermost-backups"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${BACKUP_ROOT}/${STAMP}"
mkdir -p "$BACKUP_DIR"

echo "[backup] dir: $BACKUP_DIR"
cp -a "${MATTERMOST_DIR}/config" "${BACKUP_DIR}/config"

if [[ -f "${MATTERMOST_DIR}/bin/mattermost" ]]; then
    cp -a "${MATTERMOST_DIR}/bin/mattermost" "${BACKUP_DIR}/mattermost.bin"
fi

if command -v jq >/dev/null 2>&1; then
    DSN="$(jq -r '.SqlSettings.DataSource' "${MATTERMOST_DIR}/config/config.json")"
    DBNAME="$(printf '%s' "$DSN" | sed -E 's|.*/([^/?]+).*|\1|')"
else
    DBNAME="mattermost"
fi

echo "[backup] database: $DBNAME"
if command -v pg_dump >/dev/null 2>&1; then
    if id postgres >/dev/null 2>&1; then
        sudo -u postgres pg_dump "$DBNAME" | gzip > "${BACKUP_DIR}/postgres-${DBNAME}.sql.gz"
    else
        pg_dump "$DBNAME" | gzip > "${BACKUP_DIR}/postgres-${DBNAME}.sql.gz"
    fi
    echo "[backup] postgres dump saved"
else
    echo "[backup] WARNING: pg_dump not found — skipped DB backup" >&2
fi

echo "[backup] done: $BACKUP_DIR"
REMOTE_BACKUP
}

remote_deploy() {
    log "Uploading binary..."
    scp_binary

    log "Uploading web client (this may take a minute)..."
    rsync_client

    log "Installing on server and restarting..."
    ssh_cmd "MATTERMOST_DIR='${MATTERMOST_DIR}' bash -s" <<'REMOTE_DEPLOY'
set -euo pipefail

if systemctl is-active --quiet mattermost; then
    echo "[deploy] stopping mattermost"
    systemctl stop mattermost
else
    echo "[deploy] mattermost already stopped"
fi

install -m 755 /tmp/mattermost.new "${MATTERMOST_DIR}/bin/mattermost"
rm -f /tmp/mattermost.new

echo "[deploy] starting mattermost"
systemctl start mattermost

echo "[deploy] waiting for API..."
for i in $(seq 1 60); do
    if curl -sf "http://127.0.0.1:8065/api/v4/system/ping" >/dev/null; then
        echo "[deploy] ping OK"
        break
    fi
    if [[ "$i" -eq 60 ]]; then
        echo "[deploy] ERROR: server did not become ready" >&2
        journalctl -u mattermost --no-pager -n 40 >&2 || true
        exit 1
    fi
    sleep 2
done
REMOTE_DEPLOY
}

remote_verify() {
    log "Verifying deployment..."
    ssh_cmd "bash -s" <<'REMOTE_VERIFY'
set -euo pipefail
PING="$(curl -s http://127.0.0.1:8065/api/v4/system/ping)"
VERSION="$(curl -s 'http://127.0.0.1:8065/api/v4/config/client?format=old' | sed -n 's/.*\"Version\":\"\\([^\"]*\\)\".*/\\1/p')"
echo "[verify] ping:   $PING"
echo "[verify] version: $VERSION"
REMOTE_VERIFY
}

main() {
    cd "$REPO_ROOT"
    preflight
    if [[ "$SKIP_BUILD" == false ]]; then
        build_local
    fi
    verify_artifacts
    confirm
    remote_backup
    remote_deploy
    remote_verify
    log "Deploy complete → https://chat.wallendorfstudio.com"
}

main "$@"
