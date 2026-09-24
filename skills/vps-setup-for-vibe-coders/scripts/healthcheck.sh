#!/usr/bin/env bash
# Operational health + security regression check. Run weekly and after changes.
#
# Adapt the CONFIG block to the stack. The regression checks at the bottom are
# the point of this script: each corresponds to a failure mode that fails OPEN
# while looking healthy, so ordinary "is it running" monitoring misses them.
set -uo pipefail

# ----------------------------------------------------------------- CONFIG
DOMAIN="${DOMAIN:-example.com}"
EXPECTED_CONTAINERS="${EXPECTED_CONTAINERS:-0}"     # 0 = skip the count check
PUBLIC_URLS=("https://${DOMAIN}")
TRAEFIK_SOCKET_NET="${TRAEFIK_SOCKET_NET:-traefik_socket-proxy}"
BACKEND_NET="${BACKEND_NET:-backend}"
REDIS_IMAGE="${REDIS_IMAGE:-redis:8.10.1-alpine}"
PG_CONTAINER="${PG_CONTAINER:-}"                    # empty = skip DB checks
PG_OWNER="${PG_OWNER:-}"
PG_DB="${PG_DB:-}"
PG_APP_ROLE="${PG_APP_ROLE:-}"
BACKUP_DIR="${BACKUP_DIR:-$HOME/backups}"
# -------------------------------------------------------------------------

P=0; W=0; F=0
ok(){   printf '  \033[32mPASS\033[0m  %s\n' "$*"; P=$((P+1)); }
warn(){ printf '  \033[33mWARN\033[0m  %s\n' "$*"; W=$((W+1)); }
bad(){  printf '  \033[31mFAIL\033[0m  %s\n' "$*"; F=$((F+1)); }
hdr(){  printf '\n\033[1m%s\033[0m\n' "$*"; }

hdr "Containers"
RUNNING=$(docker ps -q | wc -l | tr -d ' ')
if [ "$EXPECTED_CONTAINERS" -gt 0 ]; then
  [ "$RUNNING" -eq "$EXPECTED_CONTAINERS" ] && ok "$RUNNING running" \
    || warn "$RUNNING running, expected $EXPECTED_CONTAINERS"
else ok "$RUNNING containers running"; fi
UNHEALTHY=$(docker ps --filter health=unhealthy --format '{{.Names}}')
[ -z "$UNHEALTHY" ] && ok "no unhealthy containers" || bad "unhealthy: $UNHEALTHY"
for c in $(docker ps --format '{{.Names}}'); do
  rc=$(docker inspect "$c" --format '{{.RestartCount}}')
  [ "$rc" -gt 5 ] && warn "$c restarted $rc times (crash loop?)"
done

hdr "Resources"
DISK=$(df --output=pcent / | tail -1 | tr -dc '0-9')
[ "$DISK" -lt 80 ] && ok "disk ${DISK}%" || { [ "$DISK" -lt 90 ] && warn "disk ${DISK}%" || bad "disk ${DISK}%"; }
MEM=$(free -m | awk '/^Mem:/{printf "%d", $7*100/$2}')
[ "$MEM" -gt 15 ] && ok "memory ${MEM}% available" || warn "only ${MEM}% memory available"
# No swap: a memory spike hangs the box, SSH included, instead of slowing it (traps 19).
SWAP=$(free -m | awk '/^Swap:/{print $2}')
if [ "$SWAP" -eq 0 ]; then warn "no swap — a memory spike will hang the box (traps 19)"
else
  SWAPUSED=$(free -m | awk '/^Swap:/{printf "%d", $3*100/$2}')
  [ "$SWAPUSED" -lt 50 ] && ok "swap ${SWAP}MB, ${SWAPUSED}% used" \
    || warn "swap ${SWAPUSED}% used — an app needs a higher mem_limit or is leaking"
fi
NOLIMIT=$(docker ps -q | xargs -r docker inspect --format '{{if eq .HostConfig.Memory 0}}{{.Name}}{{end}}' | sed 's#^/##' | grep . | tr '\n' ' ')
[ -z "$NOLIMIT" ] && ok "every container has a memory limit" || warn "no memory limit: $NOLIMIT"

hdr "Host security posture"
LISTEN=$(sudo -n ss -tulpn 2>/dev/null | grep LISTEN | grep -vcE '127\.0\.0\.|\[::1\]')
[ "$LISTEN" -le 2 ] && ok "$LISTEN public listener(s) — SSH only" \
  || warn "$LISTEN public listeners — expected 2 (SSH v4+v6)"
docker ps --format '{{.Ports}}' | grep -qE '0\.0\.0\.0|:::' \
  && bad "a container publishes on ALL interfaces (Docker bypasses UFW)" \
  || ok "no container published to 0.0.0.0"
sudo -n ufw status 2>/dev/null | grep -q '^Status: active' && ok "ufw active" || bad "ufw NOT active"
UNPINNED=$(docker ps --format '{{.Image}}' | grep -c ':latest' || true)
[ "$UNPINNED" -eq 0 ] && ok "all images pinned" || bad "$UNPINNED container(s) on :latest"

hdr "Security regressions"
# Each of these failed OPEN in a real deployment while reporting healthy.

# The reverse proxy must never be able to write to the Docker API: create+start
# is a complete path from a web compromise to root on the host.
if docker network inspect "$TRAEFIK_SOCKET_NET" >/dev/null 2>&1; then
  CODE=$(docker run --rm --network "$TRAEFIK_SOCKET_NET" curlimages/curl:latest -sS -o /dev/null \
    -w '%{http_code}' -X POST http://socket-proxy:2375/containers/create --max-time 10 2>/dev/null)
  [ "$CODE" = "403" ] && ok "socket proxy denies container create (403)" \
    || bad "socket proxy returned $CODE for container create — EXPECTED 403"
fi

# An unreadable secret makes --requirepass "" which silently disables auth.
if docker network inspect "$BACKEND_NET" >/dev/null 2>&1; then
  R=$(docker run --rm --network "$BACKEND_NET" "$REDIS_IMAGE" redis-cli -h redis ping 2>&1 | head -1)
  case "$R" in
    NOAUTH*) ok "redis rejects unauthenticated access" ;;
    PONG*)   bad "redis answered PONG with NO password — it is open" ;;
    *)       warn "redis check inconclusive: $R" ;;
  esac
fi

# The application's DB role must never be a superuser.
if [ -n "$PG_CONTAINER" ] && [ -n "$PG_APP_ROLE" ]; then
  S=$(docker exec "$PG_CONTAINER" sh -c \
    "PGPASSWORD=\"\$(cat /run/secrets/postgres_password)\" psql -U $PG_OWNER -d $PG_DB -tAc \
     \"SELECT rolsuper FROM pg_roles WHERE rolname='$PG_APP_ROLE'\"" 2>/dev/null | tr -d ' ')
  [ "$S" = "f" ] && ok "$PG_APP_ROLE is not a superuser" \
    || bad "$PG_APP_ROLE rolsuper='$S' — EXPECTED f"
fi

hdr "Public endpoints"
for u in "${PUBLIC_URLS[@]}"; do
  C=$(curl -sS -o /dev/null -w '%{http_code}' "$u" --max-time 20 2>/dev/null)
  [ "$C" = "200" ] && ok "$u -> 200" || bad "$u -> $C"
done
if docker ps --format '{{.Names}}' | grep -q cloudflared; then
  CFC=$(docker ps --filter name=cloudflared --format '{{.Names}}' | head -1)
  UP=$(docker inspect "$CFC" --format '{{.State.Running}}')
  # Look for a failure signal, not a liveness one: a quiet log is normal for a
  # healthy tunnel, and a check that cries wolf gets ignored.
  ERR=$(docker logs --since 30m "$CFC" 2>&1 | grep -ciE 'failed to dial|unregistered|connection refused' || true)
  if [ "$UP" != "true" ]; then bad "cloudflared not running"
  elif [ "$ERR" -gt 0 ]; then warn "cloudflared logged $ERR connection error(s) in 30m"
  else ok "cloudflared running, no connection errors"; fi
fi

hdr "Backups"
NEWEST=$(ls -1d "$BACKUP_DIR"/*/ 2>/dev/null | sort | tail -1)
if [ -n "$NEWEST" ]; then
  AGE=$(( ( $(date +%s) - $(stat -c %Y "$NEWEST") ) / 3600 ))
  [ "$AGE" -lt 48 ] && ok "newest backup ${AGE}h old" || bad "newest backup ${AGE}h old"
  find "$NEWEST" -name '*.dump' -size +0 -print -quit | grep -q . \
    && ok "latest dump is non-empty" || bad "latest dump missing or empty"
else bad "no backups found in $BACKUP_DIR"; fi

hdr "OS updates"
SEC=$(apt-get -s -o Debug::NoLocking=true upgrade 2>/dev/null | grep -ciE '^Inst.*security' || true)
[ "$SEC" -eq 0 ] && ok "no pending security updates" || warn "$SEC security update(s) pending"
[ -f /var/run/reboot-required ] && warn "REBOOT REQUIRED (patched kernel not running)" || ok "no reboot pending"

printf '\n\033[1mSummary:\033[0m %d pass, %d warn, %d fail\n' "$P" "$W" "$F"
[ "$F" -gt 0 ] && exit 1 || exit 0
