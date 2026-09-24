# Compose templates

Replace `<domain>` throughout. Pin every image to an exact version — check current
tags rather than copying the ones here, which will age.

Directory layout that works well:

```
~/docker/
├── traefik/       compose.yml, dynamic/security-headers.yml
├── cloudflared/   compose.yml, secrets/tunnel_token
├── portainer/     compose.yml            (optional)
├── <appname>/     compose.yml, secrets/, html/
├── _scripts/      backup.sh, healthcheck.sh
└── _backups/
```

## Networks (create once, by hand)

Compose will not create external networks.

```bash
docker network create proxy
docker network create --internal backend
docker network create --driver bridge --subnet 172.21.0.0/24 edge
```

| Network | Internal? | Members |
|---|---|---|
| `edge` | no | cloudflared + Traefik only |
| `proxy` | no | Traefik + public-facing apps |
| `backend` | **yes** | apps + databases |

`edge` exists so `forwardedheaders.trustedips` can be narrow. Without it you must
trust the whole app network, and any container can forge visitor IPs.

## Traefik + read-only socket proxy

```yaml
services:
  socket-proxy:
    image: ghcr.io/tecnativa/docker-socket-proxy:v0.5.0
    restart: unless-stopped
    # READ-ONLY. POST=0 is the important one: with POST=1 this allows container
    # create/start/exec, i.e. root on the host, from an internet-facing proxy.
    environment:
      POST: "0"
      CONTAINERS: "1"
      NETWORKS: "1"
      EVENTS: "1"
      INFO: "1"
      IMAGES: "0"
      VOLUMES: "0"
      EXEC: "0"
      SECRETS: "0"
      SWARM: "0"
      SYSTEM: "0"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    cap_drop: [ALL]
    cap_add: [CHOWN, SETUID, SETGID]     # haproxy drops to its own user
    security_opt: ["no-new-privileges:true"]
    read_only: true
    tmpfs: [/tmp, /run, /var/lib/haproxy]   # entrypoint writes /tmp/haproxy.cfg
    mem_limit: 64m
    pids_limit: 50
    networks: [socket-proxy]

  traefik:
    image: traefik:3.7.13
    restart: unless-stopped
    command:
      - --api.dashboard=false
      - --global.checknewversion=false
      - --global.sendanonymoususage=false
      - --providers.docker=true
      - --providers.docker.endpoint=tcp://socket-proxy:2375
      - --providers.docker.exposedbydefault=false
      - '--providers.docker.defaultrule=Host(`{{ with index .Labels "com.docker.compose.service" }}{{ normalize . }}{{ else }}{{ normalize .Name }}{{ end }}.<domain>`)'
      - --providers.file.directory=/etc/traefik/dynamic
      - --providers.file.watch=true
      - --entrypoints.web.address=:80
      - --entrypoints.websecure.address=:443
      # Trust ONLY the edge subnet, so Cloudflare's X-Forwarded-Proto: https
      # survives instead of being rewritten to http.
      - --entrypoints.web.forwardedheaders.trustedips=172.21.0.0/24
      - --entrypoints.websecure.forwardedheaders.trustedips=172.21.0.0/24
      # Strip headers whose name aliases a managed header (X_Auth_User).
      - --entrypoints.web.http.aliasheadersstrategy=delete
      - --entrypoints.websecure.http.aliasheadersstrategy=delete
      - --log.level=INFO
      - --accesslog=true
      - --accesslog.format=json
    volumes:
      - ./dynamic:/etc/traefik/dynamic:ro
    cap_drop: [ALL]
    cap_add: [NET_BIND_SERVICE]          # binds :80 inside the container
    security_opt: ["no-new-privileges:true"]
    read_only: true
    tmpfs: [/tmp]
    mem_limit: 256m
    pids_limit: 200
    networks: [proxy, socket-proxy, edge]
    depends_on: [socket-proxy]

networks:
  proxy: { external: true }
  edge:  { external: true }
  socket-proxy:
    name: traefik_socket-proxy
    internal: true
```

`dynamic/security-headers.yml`:

```yaml
http:
  middlewares:
    security-headers:
      headers:
        stsSeconds: 31536000
        stsIncludeSubdomains: false   # turn on only when every subdomain is HTTPS
        stsPreload: false
        forceSTSHeader: true          # Traefik never sees TLS; without this, no HSTS
        frameDeny: true
        contentTypeNosniff: true
        referrerPolicy: "strict-origin-when-cross-origin"
        # No contentSecurityPolicy here on purpose: CSP is per-app. A global one
        # overrides apps that ship their own, stricter policy, and breaks them.
        customResponseHeaders:
          Server: ""
          X-Powered-By: ""
```

## cloudflared

```yaml
services:
  cloudflared:
    image: cloudflare/cloudflared:2026.9.1
    # info, not debug: debug logs record dashboard access tokens (traps 16)
    command: tunnel --no-autoupdate --loglevel info run --token-file /run/secrets/tunnel_token
    restart: unless-stopped
    user: "65532:65532"
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    read_only: true
    tmpfs: [/tmp]
    mem_limit: 128m
    pids_limit: 100
    secrets: [tunnel_token]
    networks: [edge]

secrets:
  tunnel_token:
    file: ./secrets/tunnel_token

networks:
  edge: { external: true }
```

In the Cloudflare dashboard (Zero Trust → Networks → Tunnels → Configure →
Public Hostnames), add **both**:

```
<domain>      → http://traefik:80     # the wildcard does NOT cover the apex
*.<domain>    → http://traefik:80
```

Service type must be **HTTP**, not HTTPS — Traefik listens for plain HTTP.

The token file must be readable by cloudflared's user (uid 65532):

```bash
mkdir -p secrets && printf '%s' '<token>' > secrets/tunnel_token
chmod 600 secrets/tunnel_token && sudo chown -R 65532:65532 secrets && sudo chmod 700 secrets
```

Then confirm `docker logs cloudflared-cloudflared-1 | grep "Registered tunnel connection"`
shows connections, and turn on **Always Use HTTPS** in the Cloudflare dashboard
(SSL/TLS → Edge Certificates).

## Application stack

```yaml
services:
  app:
    image: <your-app>:<pinned-version>
    restart: unless-stopped
    user: "101:101"
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    read_only: true
    tmpfs: [/tmp]
    mem_limit: 128m
    cpus: "0.25"
    pids_limit: 100
    networks: [proxy, backend]      # the only service spanning both
    environment:
      DATABASE_HOST: postgres       # service names, never container IPs
      DATABASE_USER: ${POSTGRES_USER}_app   # least-privilege role, not the owner
      REDIS_USER: app
    secrets: [app_db_password, redis_password]
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://127.0.0.1:8080/"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s
    depends_on:
      postgres: { condition: service_healthy }
      redis:    { condition: service_healthy }
    labels:
      # No rule needed: the hostname comes from the compose SERVICE name.
      - traefik.enable=true
      - traefik.docker.network=proxy
      - traefik.http.routers.app.entrypoints=web
      - traefik.http.routers.app.middlewares=security-headers@file
      - traefik.http.services.app.loadbalancer.server.port=8080

  postgres:
    image: postgres:18.6-alpine
    restart: unless-stopped
    networks: [backend]
    environment:
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD_FILE: /run/secrets/postgres_password
      POSTGRES_INITDB_ARGS: "--auth-host=scram-sha-256 --auth-local=scram-sha-256"
    secrets: [postgres_password, app_db_password]
    # v18: PGDATA is /var/lib/postgresql/18/docker and the volume is declared at
    # /var/lib/postgresql. The pre-18 path puts data OUTSIDE the volume.
    volumes:
      - pgdata:/var/lib/postgresql
      - ./initdb:/docker-entrypoint-initdb.d:ro
    cap_drop: [ALL]
    cap_add: [CHOWN, DAC_OVERRIDE, FOWNER, SETGID, SETUID]  # entrypoint drops root
    security_opt: ["no-new-privileges:true"]
    mem_limit: 512m
    pids_limit: 200
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $${POSTGRES_USER} -d $${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s

  redis:
    image: redis:8.10.1-alpine
    restart: unless-stopped
    networks: [backend]
    # Fail CLOSED: an unreadable ACL file would otherwise mean no auth at all.
    command:
      - sh
      - -c
      - 'ACL=/run/secrets/redis_acl; grep -q "^user app on" "$$ACL" 2>/dev/null || { echo "FATAL: redis ACL missing or unreadable" >&2; exit 1; }; exec redis-server --aclfile "$$ACL" --save "" --appendonly no'
    secrets: [redis_password, redis_acl]
    user: "999:1000"
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    read_only: true
    mem_limit: 256m
    pids_limit: 100
    healthcheck:
      test: ["CMD-SHELL", "redis-cli --user app -a \"$$(cat /run/secrets/redis_password)\" --no-auth-warning ping | grep -q PONG"]
      interval: 10s
      timeout: 5s
      retries: 5

secrets:
  postgres_password: { file: ./secrets/postgres_password }
  app_db_password:   { file: ./secrets/app_db_password }
  redis_password:    { file: ./secrets/redis_password }
  redis_acl:         { file: ./secrets/redis_acl }

volumes:
  pgdata:

networks:
  proxy:   { external: true }
  backend: { external: true }
```

### Secrets

```bash
umask 077
openssl rand -base64 36 | tr -d '\n' > secrets/postgres_password
openssl rand -base64 36 | tr -d '\n' > secrets/app_db_password
openssl rand -base64 36 | tr -d '\n' > secrets/redis_password

HASH=$(printf '%s' "$(cat secrets/redis_password)" | sha256sum | cut -d' ' -f1)
printf 'user default off\nuser app on #%s ~* &* +@all -@admin -@dangerous\n' "$HASH" \
  > secrets/redis_acl

chmod 700 secrets                      # the directory is the real protection
chmod 0600 secrets/postgres_password   # read by the entrypoint, as root
chmod 0644 secrets/app_db_password     # read by initdb (uid 70) AND the app
chmod 0644 secrets/redis_password      # read by redis (gid 1000) AND the app
chmod 0640 secrets/redis_acl           # read by redis only
```

Those modes are not arbitrary — see `traps.md` §2. Verify readability inside each
container afterwards.

### `initdb/10-app-role.sh` — least-privilege database role

Runs once, on first initialisation. Note init scripts run as **uid 70**, not root,
so `app_db_password` must be readable by it.

```bash
#!/bin/bash
set -euo pipefail
SECRET=/run/secrets/app_db_password
APP_ROLE="${POSTGRES_USER}_app"
[ -r "$SECRET" ] || { echo "FATAL: $SECRET unreadable as $(id -un)" >&2; exit 1; }
APP_PW="$(cat "$SECRET")"
[ -n "$APP_PW" ] || { echo "FATAL: $SECRET empty" >&2; exit 1; }

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
     -v app_role="$APP_ROLE" -v app_pw="$APP_PW" -v db="$POSTGRES_DB" <<'EOSQL'
CREATE ROLE :"app_role" LOGIN PASSWORD :'app_pw'
  NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
REVOKE ALL ON DATABASE :"db" FROM PUBLIC;
GRANT CONNECT ON DATABASE :"db" TO :"app_role";
GRANT USAGE ON SCHEMA public TO :"app_role";
REVOKE CREATE ON SCHEMA public FROM :"app_role";
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO :"app_role";
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO :"app_role";
-- Cover tables created later by migrations, or new tables are unreadable.
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"app_role";
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO :"app_role";
EOSQL
```

## Portainer (optional) — loopback only

Portainer needs **write** Docker access, which is root-equivalent. Give it its own
proxy, and keep it off the internet.

```yaml
services:
  socket-proxy:
    image: ghcr.io/tecnativa/docker-socket-proxy:v0.5.0
    restart: unless-stopped
    environment:
      CONTAINERS: "1"
      EVENTS: "1"
      IMAGES: "1"
      INFO: "1"
      NETWORKS: "1"
      POST: "1"          # Portainer genuinely needs write
      VOLUMES: "1"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    cap_drop: [ALL]
    cap_add: [CHOWN, SETUID, SETGID]
    security_opt: ["no-new-privileges:true"]
    read_only: true
    tmpfs: [/tmp, /run, /var/lib/haproxy]
    networks: [socket-proxy]

  portainer:
    image: portainer/portainer-ce:2.45.1
    container_name: portainer
    restart: unless-stopped
    command: ["-H", "tcp://socket-proxy:2375", "--http-enabled"]
    # Loopback ONLY. Dropping the 127.0.0.1 prefix publishes a root-equivalent
    # admin panel to the internet, and UFW will not stop it.
    ports: ["127.0.0.1:9000:9000"]
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    mem_limit: 512m
    pids_limit: 200
    volumes: [portainer_data:/data]
    networks: [socket-proxy, local]   # 'local' exists only so the port can publish
    depends_on: [socket-proxy]

networks:
  socket-proxy:
    name: portainer_socket-proxy
    internal: true
  local:
    name: portainer_local

volumes:
  portainer_data:
```

Reach it with `ssh -L 9000:localhost:9000 <host>`, then `http://localhost:9000`.
This requires `AllowTcpForwarding yes` in sshd.
