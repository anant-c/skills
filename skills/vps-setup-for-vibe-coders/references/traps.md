# Traps

Failure modes specific to this stack. Most are **silent**, and several fail
*open* — the service starts, the health check goes green, and there is no
security. Read the relevant ones before phases 3, 7, 9, 10 and 11.

## Contents

1. [Docker bypasses UFW](#1-docker-bypasses-ufw)
2. [A container that cannot read its secret fails OPEN](#2-a-container-that-cannot-read-its-secret-fails-open)
3. [Health checks lie](#3-health-checks-lie)
4. [`:ro` on the Docker socket does not make the API read-only](#4-ro-on-the-docker-socket-does-not-make-the-api-read-only)
5. [A socket proxy is not automatically safe](#5-a-socket-proxy-is-not-automatically-safe)
6. [PostgreSQL 18 moved PGDATA](#6-postgresql-18-moved-pgdata)
7. [X-Forwarded-Proto defaults to a lie](#7-x-forwarded-proto-defaults-to-a-lie)
8. [Header aliasing bypasses the proxy](#8-header-aliasing-bypasses-the-proxy)
9. [Internal networks cannot publish ports](#9-internal-networks-cannot-publish-ports)
10. [Traefik's `.Name` is not the container name](#10-traefiks-name-is-not-the-container-name)
11. [Read-only filesystems break config-generating entrypoints](#11-read-only-filesystems-break-config-generating-entrypoints)
12. [Installed is not running](#12-installed-is-not-running)
13. [Roles live outside the database](#13-roles-live-outside-the-database)
14. [Silent failures in backup scripts](#14-silent-failures-in-backup-scripts)
15. [Cloud-init turns SSH passwords back on](#15-cloud-init-turns-ssh-passwords-back-on)
16. [cloudflared debug logs record access tokens](#16-cloudflared-debug-logs-record-access-tokens)
17. [Minimal images lack cron and ufw](#17-minimal-images-lack-cron-and-ufw)
18. [Your own checks can lie too](#18-your-own-checks-can-lie-too)

---

## 1. Docker bypasses UFW

UFW says `deny incoming`. A container publishes `9000:9000`. **The world can reach
it.** Docker writes iptables rules evaluated before UFW's.

```yaml
ports: ["9000:9000"]            # the entire internet
ports: ["127.0.0.1:9000:9000"]  # this machine only
```

The `127.0.0.1:` prefix is the security control here — not the firewall. Best
answer is to publish no ports at all and route through Traefik.

**Verify from another machine:** `curl -v --max-time 8 http://<VPS_IP>:9000/`

## 2. A container that cannot read its secret fails OPEN

The most dangerous pattern in this stack.

```
secret file is 0600 owned by uid 1000
  → container runs as uid 999, cannot read it
  → cat returns an empty string
  → --requirepass "" means NO PASSWORD
  → service is wide open, and reports healthy
```

Compose **ignores** `uid`/`gid`/`mode` on secrets outside Swarm — it warns and
drops them. The mount inherits the *host* file's ownership.

Different services read secrets as different users: the Postgres entrypoint as
**root**, its initdb scripts as **uid 70**, Redis as **999:1000**, an app as
whatever it runs as. No single group covers them, so a secret shared by two
services usually ends up `0644`. The `0700` **directory** is the real protection.

**Always fail closed:**

```sh
PASS="$(cat /run/secrets/x)"; [ -n "$PASS" ] || { echo "FATAL: secret empty" >&2; exit 1; }
```

**Always verify inside the container** after changing secrets or users.

## 3. Health checks lie

`redis-cli -a <password> ping` returns `PONG` whether or not authentication is
configured. A health check built on it passes on a completely open Redis.

Test the property you actually care about:

```sh
# assert requirepass is genuinely set, not just that redis answers
[ -n "$(redis-cli -a "$PASS" --no-auth-warning config get requirepass | sed -n 2p)" ]
```

Generalise: *"the service responded"* is not *"the service is configured
correctly."*

## 4. `:ro` on the Docker socket does not make the API read-only

```yaml
- /var/run/docker.sock:/var/run/docker.sock:ro
```

The `:ro` applies to the *socket file*. The **API is fully writable** through it —
you can create containers, which means root on the host. Anything with this mount
owns the machine.

## 5. A socket proxy is not automatically safe

A proxy with `POST=1` permits container create, start and exec. Measured on a real
deployment:

| Request | Response | Meaning |
|---|---|---|
| `POST /containers/create` | `400 config cannot be empty` | **Docker's** error — it got through |
| `POST /containers/<id>/start` | `304` | permitted |
| `POST /containers/<id>/exec` | `201 Created` | permitted |
| `GET /secrets` *(control)* | `403` | the proxy blocks what it is told to |

The control test matters: the proxy denies with `403`, so `400`/`304`/`201` are
the daemon replying.

Worse: `ALLOW_START=0` and `EXEC=0` were **set** and did **not** take effect for
those paths. Do not trust the flag names.

**Rule:** the reverse proxy gets `POST=0`. Anything needing write access gets its
own proxy on a network the reverse proxy cannot reach.

**Verify:** `POST /containers/create` must return **403**.

## 6. PostgreSQL 18 moved PGDATA

```
PGDATA=/var/lib/postgresql/18/docker     # v18
image declares its volume at /var/lib/postgresql
```

Older guides say mount `/var/lib/postgresql/data`. On v18 the real data is **not**
inside that mount — it lands in the container's writable layer and is destroyed on
every recreate. Everything works until the first redeploy.

```yaml
volumes:
  - pgdata:/var/lib/postgresql      # correct for v18
```

Always check the image rather than assuming:

```bash
docker inspect postgres:<tag> --format '{{.Config.Env}}' | tr ' ' '\n' | grep PGDATA
```

**Verify:** write a row, `docker compose up -d --force-recreate`, read it back.

## 7. X-Forwarded-Proto defaults to a lie

Cloudflare terminates TLS and forwards plain HTTP. Traefik distrusts the sender by
default and **overwrites** the header to `http`.

Apps then generate `http://` redirects, refuse to set secure cookies, and
**logins silently fail** — while the infrastructure looks perfectly healthy.

```yaml
- --entrypoints.web.forwardedheaders.trustedips=<edge subnet>
```

Scope it to a network containing **only** the tunnel and the proxy. Trusting the
whole app network lets any container forge being any visitor — verified: a
container on the shared network successfully injected `X-Forwarded-For: 9.9.9.9`.

## 8. Header aliasing bypasses the proxy

Backends that map headers to variables (PHP, CGI, WSGI, nginx) turn `X-Auth-User`
into `HTTP_X_AUTH_USER`. So a header literally named `X_Auth_User` lands in the
same variable, bypassing what the proxy set.

```yaml
- --entrypoints.web.http.aliasheadersstrategy=delete
```

`delete` over `reject`: strips the spoof without 400-ing legitimate clients.

## 9. Internal networks cannot publish ports

A container on **only** an `internal: true` network cannot publish a host port.
Docker creates **no listener** and does **not** error. The port is simply dead.

If a container needs both, give it a second non-internal network for the mapping.

## 10. Traefik's `.Name` is not the container name

In the Docker provider, for Compose containers `.Name` is `<service>-<project>`,
and it ignores `container_name:` entirely.

| Deployed as | `.Name` |
|---|---|
| service `app1`, project `autotest` | `app1-autotest` |
| service `app2`, project `app2` | `app2-app2` |
| `docker run --name app3` | `app3` |

For predictable hostnames from the service name:

```
Host(`{{ with index .Labels "com.docker.compose.service" }}{{ normalize . }}{{ else }}{{ normalize .Name }}{{ end }}.<domain>`)
```

## 11. Read-only filesystems break config-generating entrypoints

```
can't create /tmp/haproxy.cfg: Read-only file system
```

Many images generate config at startup. `read_only: true` needs matching `tmpfs`
entries — commonly `/tmp`, `/run`, and an image-specific path.

Apply hardening incrementally and read the logs. Never blanket-apply across
everything at once.

## 12. Installed is not running

```bash
uname -r                       # running kernel
dpkg -l | grep linux-image     # installed kernels
[ -f /var/run/reboot-required ] && cat /var/run/reboot-required.pkgs
```

Unattended-upgrades installs kernel and libc patches; they do nothing until
reboot. Long uptime plus auto-updates means unapplied security fixes.

Rebooting is safe when every container is `restart: unless-stopped`, docker is
enabled at boot, and networks persist — verify all three first.

## 13. Roles live outside the database

`pg_dump` does not include roles. Restore only that and the tables come back with
an application that **cannot log in**.

```bash
pg_dumpall --globals-only > globals.sql
```

## 14. Silent failures in backup scripts

A manifest step that greps for something and finds nothing will happily write an
empty section and exit 0. Backups can look fine for months.

Check backup **contents**, not just the exit code. And test the script under a
real cron environment (`env -i`, no TTY) — `$PATH`, `$HOME` and `sudo` behave
differently there.

---

## 15. Cloud-init turns SSH passwords back on

Provider images ship `/etc/ssh/sshd_config.d/50-cloud-init.conf` containing
`PasswordAuthentication yes`. sshd uses the **first** value it reads for most
settings, and reads the drop-ins in name order. A hardening file named
`99-hardening.conf` therefore loses to it, **silently**: the file reads
correctly and passwords still work.

Name the file `10-hardening.conf`. Verify the effective config with
`sudo sshd -T | grep passwordauthentication`, and try a password login from
outside. The server must answer `Permission denied (publickey)`, meaning
passwords are not even offered.

## 16. cloudflared debug logs record access tokens

With `--loglevel debug`, cloudflared logs every management request in full.
Each time the owner opens the tunnel page in the Cloudflare dashboard, `docker
logs` gains a short-lived dashboard access token (a JWT in the URL) plus the
admin's IP address and browser headers. Anyone who can read container logs,
including anything with Docker API read access, can collect them.

Pin `--loglevel info` in the compose command. Debug is for a debugging session,
not a default.

## 17. Minimal images lack cron and ufw

Some provider images of Ubuntu 26.04 ship without `ufw` and without `cron`.
Without cron, `crontab -` fails, the backup "schedule" never exists, and nothing
complains until you need a backup. Install both explicitly and verify:

```bash
systemctl is-active cron && crontab -l | grep backup.sh
```

The health check's "newest backup is < 26h old" check is what catches this
after the fact. Keep it.

## 18. Your own checks can lie too

Two false results from one real run:

- Testing the app's database role with `docker exec <postgres> psql -U app_role`
  failed with "no password supplied". The app's secret is mounted into the
  **app** container, not the database container. Test from a throwaway client
  on `backend` with the app's secret mounted, which is how the app connects.
- `redis-cli ping | tail -1` printed an empty line, because redis-cli ends with a
  blank line and `NOAUTH` was on the line before. That looks like "no output".

Never truncate the output of a security check, and run each check from the
position the real client or attacker would be in.

## 19. No swap: one memory spike hangs the whole box

Most provider images ship with no swap. When memory runs out, Linux does not
crash cleanly: it thrashes, evicting and re-reading the same pages, until
nothing answers. SSH times out, so you cannot log in to fix it, and the tunnel
keeps telling Cloudflare the origin exists, so nothing looks down from outside.
On a 1–2 GB box a single `npm run build` or an image-heavy request is enough.

Two fixes, and you want both:

- **Swap** (host-setup 3b) turns the hang into a slowdown you can see and fix.
- **A `mem_limit` on every container** means the one that misbehaves is killed
  and restarted by Docker, instead of taking every other subdomain down with it.

The health check warns when swap is missing, when more than half of it is in
use (an app needs a higher limit or is leaking), and when any container runs
without a memory limit.

## The meta-lesson

Almost all of these fail **open** while **looking healthy**. Config that reads
correctly, checks that report green, services that start cleanly — and no
security.

**Test the property you care about, from the position of an attacker, and read
the actual response.** Not the config file. Not the flag name. The behaviour.
