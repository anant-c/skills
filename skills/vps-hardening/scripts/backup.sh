#!/usr/bin/env bash
# Backs up what cannot be rebuilt. Adapt the CONFIG block.
#
# Deliberately NOT backed up:
#   - redis, when used as a cache with persistence off: nothing to lose
#   - docker images: pinned and re-pullable
#   - the postgres data DIRECTORY: logical dumps restore across versions and can
#     be verified; a raw copy of a live data dir is neither
set -euo pipefail

# ----------------------------------------------------------------- CONFIG
ROOT="${BACKUP_ROOT:-$HOME/backups}"
KEEP="${KEEP:-7}"
PG_CONTAINER="${PG_CONTAINER:-}"        # empty = skip postgres
PG_DB="${PG_DB:-}"
PG_OWNER="${PG_OWNER:-}"
VOLUMES=(${BACKUP_VOLUMES:-})           # space-separated named volumes
STOP_FOR_VOLUMES="${STOP_FOR_VOLUMES:-}"  # containers to stop during volume copy
CONFIG_DIR="${CONFIG_DIR:-docker}"      # relative to $HOME
SECRET_DIRS=(${SECRET_DIRS:-})          # relative to $HOME, e.g. docker/app/secrets
CLOUDFLARED_CONTAINER="${CLOUDFLARED_CONTAINER:-}"
# -------------------------------------------------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
DEST="$ROOT/$STAMP"
umask 077
mkdir -p "$DEST"/{postgres,volumes,config,secrets}
chmod 700 "$ROOT" "$DEST" "$DEST/secrets"
log(){ printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

# ---------------------------------------------------------------- postgres
if [ -n "$PG_CONTAINER" ]; then
  # Read the password INSIDE the container so it never reaches the host process list.
  log "postgres: dumping $PG_DB"
  docker exec "$PG_CONTAINER" sh -c \
    'PGPASSWORD="$(cat /run/secrets/postgres_password)" pg_dump -U '"$PG_OWNER"' -d '"$PG_DB"' -Fc' \
    > "$DEST/postgres/${PG_DB}.dump"

  # Roles live OUTSIDE the database. Without this a restore recreates the tables
  # but the application role does not exist and cannot log in.
  log "postgres: dumping globals (roles)"
  docker exec "$PG_CONTAINER" sh -c \
    'PGPASSWORD="$(cat /run/secrets/postgres_password)" pg_dumpall -U '"$PG_OWNER"' --globals-only' \
    > "$DEST/postgres/globals.sql"
fi

# ----------------------------------------------------------------- volumes
if [ "${#VOLUMES[@]}" -gt 0 ]; then
  # Databases that keep state in a single file (BoltDB, SQLite) can be copied
  # torn while a writer is attached. Stop them; the trap guarantees restart.
  if [ -n "$STOP_FOR_VOLUMES" ]; then
    restart_them(){ for c in $STOP_FOR_VOLUMES; do docker start "$c" >/dev/null 2>&1 || true; done; }
    trap restart_them EXIT
    for c in $STOP_FOR_VOLUMES; do log "stopping $c for a consistent copy"; docker stop "$c" >/dev/null; done
  fi
  for v in "${VOLUMES[@]}"; do
    log "volume: $v"
    docker run --rm -v "$v":/src:ro -v "$DEST/volumes":/dst alpine:latest \
      tar czf "/dst/${v}.tar.gz" -C /src .
    # The helper container writes as root with a default umask; these archives
    # can contain password hashes and session secrets.
    sudo -n chown "$(id -u):$(id -g)" "$DEST/volumes/${v}.tar.gz" 2>/dev/null || true
    chmod 600 "$DEST/volumes/${v}.tar.gz"
  done
  if [ -n "$STOP_FOR_VOLUMES" ]; then
    for c in $STOP_FOR_VOLUMES; do docker start "$c" >/dev/null; done
    trap - EXIT
  fi
fi

# ------------------------------------------------------------------ config
log "config: compose files and configuration"
tar czf "$DEST/config/config.tar.gz" -C "$HOME" \
  --exclude="${CONFIG_DIR}/_backups" --exclude="${CONFIG_DIR}/*/secrets" "$CONFIG_DIR"

# ----------------------------------------------------------------- secrets
# Separate from config so config can be copied around freely while secrets are
# handled deliberately. Some credentials are owned by a container's UID and are
# unreadable by this user, hence sudo for this archive only.
if [ "${#SECRET_DIRS[@]}" -gt 0 ]; then
  log "secrets: separate archive (0600)"
  sudo -n tar czf "$DEST/secrets/secrets.tar.gz" -C "$HOME" "${SECRET_DIRS[@]}"
  sudo -n chown "$(id -u):$(id -g)" "$DEST/secrets/secrets.tar.gz"
  chmod 600 "$DEST/secrets/secrets.tar.gz"
fi

# ---------------------------------------------------------------- manifest
log "manifest"
{
  echo "backup: $STAMP"
  echo "host:   $(hostname)"
  echo
  echo "== images (pinned, re-pullable) =="
  docker ps -a --format '{{.Names}}  {{.Image}}' | sort
  echo
  echo "== networks =="; docker network ls --format '{{.Name}}'
  echo
  echo "== volumes =="; docker volume ls --format '{{.Name}}'
  if [ -n "$CLOUDFLARED_CONTAINER" ]; then
    echo
    echo "== cloudflare tunnel ingress (lives in the dashboard, NOT on this box) =="
    docker logs "$CLOUDFLARED_CONTAINER" 2>&1 | grep -F "Updated to new configuration" \
      | tail -1 | sed -e 's/\\"/"/g' -e 's/.*config=//' \
      || echo "  NOT CAPTURED — read it from the Cloudflare dashboard"
  fi
} > "$DEST/MANIFEST.txt"

# --------------------------------------------------------------- retention
log "retention: keeping $KEEP"
ls -1d "$ROOT"/*/ 2>/dev/null | sort | head -n -"$KEEP" | while read -r old; do
  log "  pruning $(basename "$old")"; rm -rf "$old"
done

log "done -> $DEST"
du -sh "$DEST" | sed 's/^/  /'
