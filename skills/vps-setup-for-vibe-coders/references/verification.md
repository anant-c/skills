# Verification

Run these after the matching phase. **Never truncate the output of a security
check** (`| tail -1`, `| head`). A blank last line has hidden a `NOAUTH` before
(traps 18). The principle throughout: **make the request
an attacker would make, and read the actual response.** Reading a config file
proves nothing — most failures in this stack look healthy.

## Baseline / host

```bash
ss -tulpn | grep LISTEN          # every 0.0.0.0 line is a promise to the internet
sudo ufw status verbose          # expect: deny (incoming), deny (routed)
sudo sshd -T | grep -iE '^(permitrootlogin|passwordauthentication|port|allowtcpforwarding)'
uname -r; [ -f /var/run/reboot-required ] && echo "REBOOT PENDING"
```

Expected public listeners at the end of the build: **SSH only** (plus
`127.0.0.1:9000` if Portainer is installed).

## Before any SSH change

```bash
sudo sshd -t                     # validate BEFORE applying — this is the safety gate
sudo systemctl reload ssh        # reload, not restart: existing sessions survive
ssh -o BatchMode=yes <host> 'echo NEW CONNECTION OK'    # from a NEW connection
ssh -f -N -L 9999:localhost:9000 <host> && echo "port forwarding still works"
```

Never close the working session until a brand-new one succeeds.

## Docker

```bash
ss -tulpn | grep -E ':2375|:2376'    # must be EMPTY — the API on TCP is a root shell
docker ps --format '{{.Names}} {{.Ports}}' | grep -E '0\.0\.0\.0|:::'   # must be empty
docker ps --format '{{.Image}}' | grep ':latest'                        # must be empty
```

Which containers hold the raw socket:

```bash
for c in $(docker ps --format '{{.Names}}'); do
  docker inspect "$c" --format '{{.Name}} {{range .Mounts}}{{.Source}} {{end}}' \
    | grep -q docker.sock && echo "RAW SOCKET: $c"
done
```

Only socket proxies should appear.

## Network isolation — prove it, don't assume it

```bash
# proxy-only container must NOT reach the database
docker run --rm --network proxy alpine sh -c \
  'nc -z -w3 postgres 5432 && echo REACHABLE-FAIL || echo BLOCKED-PASS'

# backend containers must NOT reach the internet
docker run --rm --network backend alpine sh -c \
  'nc -z -w4 1.1.1.1 443 && echo REACHABLE-FAIL || echo BLOCKED-PASS'

# the app, on both, SHOULD reach the database
docker exec <app> sh -c 'nc -z -w3 postgres 5432 && echo OK'
```

## Socket proxy — the one people skip

```bash
CID=$(docker inspect <any-container> --format '{{.Id}}')
P(){ docker run --rm --network <socket-net> curlimages/curl:latest -sS -o /dev/null \
     -w "$2 -> %{http_code}\n" -X POST "http://socket-proxy:2375$1" --max-time 10; }
P "/containers/create"      "create"
P "/containers/$CID/start"  "start "
P "/containers/$CID/exec"   "exec  "
```

Against the reverse proxy's socket: **all must be 403.** Anything else (400, 304,
201) means the request reached the Docker daemon — that is a path to host root.

Reads must still work:

```bash
docker run --rm --network <socket-net> curlimages/curl:latest -sS -o /dev/null \
  -w 'containers/json -> %{http_code}\n' http://socket-proxy:2375/containers/json   # 200
```

## Forwarded headers

Deploy a temporary echo service, then request it through the real chain:

```yaml
services:
  hdrtest:
    image: traefik/whoami:v1.11
    restart: "no"
    networks: [proxy]
    labels:
      - traefik.enable=true
      - traefik.http.routers.hdrtest.rule=Host(`<domain>`) && PathPrefix(`/__hdrtest`)
      - traefik.http.middlewares.hdr-strip.stripprefix.prefixes=/__hdrtest
      - traefik.http.routers.hdrtest.middlewares=hdr-strip
```

```bash
curl -sS "https://<domain>/__hdrtest" | grep -iE 'X-Forwarded-(Proto|For|Port)'
```

Expect `X-Forwarded-Proto: https`, `Port: 443`, and your real IP in
`X-Forwarded-For`. If Proto says `http`, `trustedips` is wrong and apps will
generate broken links and drop secure cookies.

Then confirm a container **cannot** forge it:

```bash
docker run --rm --network proxy curlimages/curl -sS "http://traefik:80/__hdrtest" \
  -H "Host: <domain>" -H "X-Forwarded-For: 9.9.9.9" -H "X_Auth_User: admin"
```

`9.9.9.9` must be discarded, and `X_Auth_User` must not reach the backend.

**Remove the echo service immediately afterwards.**

## Database and cache

```bash
# unauthenticated redis must be refused
docker run --rm --network backend redis:<tag> redis-cli -h redis ping    # NOAUTH

# the app role must not be able to escalate. Connect the way the app does:
# from backend, with the APP's secret (it is not mounted in the postgres container).
APPSQL(){ docker run --rm --network backend -v "$PWD/secrets/app_db_password:/pw:ro" \
  postgres:<tag> sh -c "PGPASSWORD=\"\$(cat /pw)\" psql -w -h postgres -U <app_role> -d <db> -c \"$1\""; }
APPSQL "CREATE TABLE evil(x int);"     # ERROR: permission denied for schema public
APPSQL "DROP TABLE <table>;"           # ERROR: must be owner
APPSQL "SELECT count(*) FROM <table>;" # works
docker exec <pg> psql -U <owner> -c \
  "SELECT rolname, rolsuper FROM pg_roles WHERE rolcanlogin;"              # app role: f
```

Secret readability — do this after any permission or user change:

```bash
docker compose exec <svc> sh -c \
  'for f in /run/secrets/*; do [ -s "$f" ] && cat "$f" >/dev/null 2>&1 \
   && echo "OK $f" || echo "UNREADABLE $f"; done'
```

`UNREADABLE` means the service may be running with **no authentication**.

## Persistence

```bash
# write, recreate, read back — catches the PGDATA mount trap
docker exec <pg> psql -U <owner> -d <db> -c \
  "CREATE TABLE IF NOT EXISTS _check(v text); INSERT INTO _check VALUES ('x');"
docker compose up -d --force-recreate postgres && sleep 20
docker exec <pg> psql -U <owner> -d <db> -c "SELECT count(*) FROM _check;"   # must be 1
```

## External exposure — from a machine that is not the VPS

```bash
dig +short <domain> A        # Cloudflare IPs only, never the VPS IP
for p in 80 443 9000 5432 6379 2375; do
  curl -sS -o /dev/null --max-time 6 "http://<VPS_IP>:$p" \
    && echo "port $p OPEN - FAIL" || echo "port $p closed - PASS"
done
```

## Backups

```bash
pg_restore --list <backup>.dump | head        # proves the archive is readable
grep -c 'CREATE ROLE' globals.sql             # roles captured?
find ~/backups -type f -exec stat -c '%a %n' {} \;   # everything 0600?
```

Then restore into a **throwaway** container on an isolated network and check both
the data *and* that the app role is still constrained. A restore that silently
returns the app to superuser is its own incident.

Test the backup script under a real cron environment:

```bash
env -i HOME="$HOME" PATH=/usr/bin:/bin /bin/sh -c "$HOME/docker/_scripts/backup.sh"
```

`$PATH`, `$HOME` and `sudo` all behave differently under cron.
