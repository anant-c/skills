---
name: vps-hardening
description: Harden a fresh Ubuntu VPS into a production-capable host - SSH, UFW, Docker, Docker socket proxy, Cloudflare Tunnel, Traefik, app stacks with PostgreSQL/Redis, least-privilege database roles, tested backups, and a health check. Use this whenever someone is setting up a VPS or cloud server, deploying Docker apps to a server, asking about Cloudflare Tunnel, Traefik, reverse proxies, exposing a service on a domain, securing a server, "getting this online", locking down SSH or a firewall, Portainer, or wondering whether their server setup is safe - even if they do not use the word "hardening". Also use it to audit or review an existing server setup.
---

# VPS hardening

Turn a fresh Ubuntu VPS into something you can run production software on, and
prototype quickly against, without leaving an open door.

The target architecture: **nothing listening publicly except SSH.** Web traffic
arrives through a Cloudflare Tunnel, so there are no inbound ports and the origin
IP never appears in DNS.

```
Internet → Cloudflare (terminates TLS) → tunnel → cloudflared → Traefik → containers
                                                                    ↓
                                                  internal network: PostgreSQL, Redis
```

## Philosophy — read this before recommending anything

**Aim for "hard enough to run production on", not maximum security.** A VPS that
takes three weeks to set up and that nobody understands is worse than one that is
solidly hardened and shipped this afternoon.

Concretely, this means:

- **Every control needs a reason.** If you cannot explain what attack a setting
  prevents, do not add it. An IDS nobody reads is worse than no IDS: it costs
  resources and manufactures a false sense of coverage.
- **Prefer removing exposure over adding layers.** Taking an admin panel off the
  internet beats putting three authentication layers in front of it.
- **Boring and understandable beats clever.** The person maintaining this in six
  months is the user, with no context. Optimise for that.
- **Do not gold-plate before there is an application.** Rate limiting, WAF rules
  and image scanning are real controls, but they are premature on a box with no
  app on it yet. Say so rather than quietly building them.

When the user wants to skip something, that is usually fine. Tell them what they
are accepting, in one sentence, and move on. Do not lecture.

## How to work through this

**Interview first, then build.** Gather the configuration up front so you are not
stopping every two minutes to ask. See "Configuration to gather" below.

**Verify every step before moving to the next.** This is the single most
important habit in this skill. Almost every serious failure in this domain fails
*open* while looking healthy — a service starts, a health check goes green, and
there is no security. Reading a config file is not verification. Sending a
request and reading the response is.

**Work in phases, and stop on failure.** If something breaks, diagnose it before
changing anything else. Do not stack changes on top of a broken state; you lose
the ability to tell which change caused what.

**Never break SSH.** Before any SSH or firewall change: confirm the current
session works, validate with `sshd -t` *before* reloading, use `reload` not
`restart`, and confirm a brand-new connection succeeds before considering it done.
The user's live session is their safety line.

## Configuration to gather

Ask for these in one go at the start. Everything else has a sensible default.

| Need | Why | Default if unsure |
|---|---|---|
| SSH host/alias for the server | how you will connect | ask |
| Admin username | root login gets disabled | `ubuntu` |
| Domain name | routing + tunnel | required |
| Cloudflare account access | tunnel + DNS live in their dashboard | required |
| What they will deploy | decides whether Postgres/Redis are needed | a placeholder app |
| Admin UI wanted? (Portainer) | if yes, plan for loopback + SSH tunnel | yes, loopback only |
| Existing setup, or fresh? | audit vs build | ask |

If they are **not** starting fresh, do not assume anything about the current
state. Inspect it first (see `references/verification.md`) and tell them what you
found before proposing changes.

## The phases

Work in this order — later phases depend on earlier ones. Verify as you go.

**Phases 1–5 have exact commands in `references/host-setup.md`. Follow them**;
these are the phases where a mistake locks the user out.

**1. Baseline.** `ss -tulpn` to see what is listening, `df -h`, `free -h`. Every
line bound to `0.0.0.0` is a promise to the internet. Note the running kernel,
whether any non-root user exists, and whether `ufw` and `cron` are installed:
minimal provider images often lack both.

**1b. Admin user.** Provider images often have **only root**. Create a sudo user
with the same `authorized_keys`, and prove a brand-new login plus `sudo -n true`
work, *before* phase 2 disables root login. If the box still has a weak initial
root password, replace it with a long random one now: bots try those within
minutes.

**2. SSH.** Keys only: `PermitRootLogin no`, `PasswordAuthentication no`,
`KbdInteractiveAuthentication no`, in `/etc/ssh/sshd_config.d/10-hardening.conf`.
The `10-` matters: sshd uses the first value it reads, and cloud-init's
`50-cloud-init.conf` turns passwords back **on** (traps 15). Verify with
`sshd -T` and a real password attempt that must be refused. Keep
`AllowTcpForwarding yes`, because later phases reach the admin UI through an SSH
tunnel.

**3. Firewall.** Install `ufw` if missing. Default deny incoming, allow outgoing,
allow 22/tcp *before* enabling. **Then tell them Docker bypasses UFW**: this
surprises nearly everyone and changes how they must think about published ports.
If the upgrade installed a kernel, reboot now and confirm SSH, UFW and the kernel
came back.

**4. Docker.** Install from Docker's repo (check it supports the release), set
`daemon.json` (`live-restore`, `local` log driver). Explain that being in the
`docker` group is equivalent to passwordless root, and why that makes "which
containers can reach the Docker API" the most important access decision on the
box.

**5. Networks.** Create `proxy` (bridge), `backend` (**internal**), `edge`
(bridge, small subnet). Prove isolation rather than assuming it.

**6. Cloudflare Tunnel.** The user creates the tunnel in their dashboard. The
token is the `eyJ...` string in the "install connector" command. **Refresh
token** only rotates it; it does not display it. Store the token as a file
secret, never an env var. Run `cloudflared` on `edge` with **`--loglevel info`**
(debug logs record dashboard access tokens; traps 16). Add **two** routes: the
apex and `*.<domain>`, because the wildcard does not cover the apex. The service
URL is `http://traefik:80` (plain HTTP, not HTTPS). Then have them turn on
**SSL/TLS → Edge Certificates → Always Use HTTPS**; otherwise `http://` is
served in plain text.

*Migrating a domain from another box?* One hostname can only route to one tunnel,
and two connectors on the **same** tunnel split traffic between both servers.
Either create a new tunnel and move the routes once the new box serves, or, if
downtime is fine, delete the old tunnel **and its leftover CNAME records** first.

**7. Traefik + socket proxy.** Traefik on `edge` + `proxy` + its own socket-proxy
network. Socket proxy with **`POST=0`** — read-only. `exposedbydefault=false`.
Set `forwardedheaders.trustedips` to the `edge` subnet only.

**8. Admin UI (optional).** If they want Portainer: it needs *write* Docker
access, which is root-equivalent. Give it its **own** write-capable socket proxy
on a separate network, and bind it to `127.0.0.1` only, reached via
`ssh -L 9000:localhost:9000 <host>`.

**9. Application stack.** Public service on `proxy`, database and cache on
`backend`. Use `references/compose-templates.md`. No `ports:` anywhere.

**10. Database least privilege.** The `POSTGRES_USER` is a superuser — never give
it to the application. Create a role that can read and write rows but not alter
schema. Redis gets an ACL user, not a shared password.

**11. Backups.** Logical dumps plus `pg_dumpall --globals-only` (roles live
outside the database). Schedule `scripts/backup.sh` with cron, and confirm `cron`
is actually installed and active (traps 17). **Then actually restore it** into a
throwaway container, and write the box's own `~/docker/_docs/RESTORE.md` from
`references/restore.md`, because the runbook has to exist before the disaster.

**12. Health check + handover.** Install `scripts/healthcheck.sh`, adapted to
their stack. Write down what is still missing.

Full commands for phases 1–5: `references/host-setup.md`.
Compose files: `references/compose-templates.md`.
Verification commands for every phase: `references/verification.md`.
Restore runbook template: `references/restore.md`.

## Read the traps file

`references/traps.md` lists the failure modes that are specific to this stack and
that cost real debugging time. **Read it before phases 2, 3, 6, 7, 9, 10 and 11** — most
of them are silent, and several fail open while reporting healthy.

The short version, so you know what you are looking for:

- Docker bypasses UFW; `127.0.0.1:` in a port mapping is doing the security work
- A container that cannot read its secret may start with **no authentication**
- Health checks routinely pass on a completely unauthenticated service
- A Docker socket proxy is not automatically safe — test it, do not trust flags
- PostgreSQL 18 moved `PGDATA`; the old mount path silently destroys data
- `X-Forwarded-Proto` defaults to a lie, which breaks logins in ways that look
  like application bugs
- Cloud-init's sshd drop-in silently turns password login back on
- cloudflared at debug log level writes dashboard access tokens into `docker logs`
- Minimal images lack `cron`, so the backup job "exists" and never runs

## Verifying, not assuming

Whenever you claim something is secure, demonstrate it. The pattern that matters:
make the request an attacker would make, and read the actual response.

```bash
# Is the database really unreachable from the internet?
curl -sS --max-time 8 http://<VPS_IP>:5432   # must time out

# Can a container that should not reach the DB, reach it?
docker run --rm --network proxy alpine sh -c 'nc -z -w3 postgres 5432 && echo REACHABLE || echo BLOCKED'

# Is the socket proxy actually read-only?
docker run --rm --network <socket-net> curlimages/curl -sS -o /dev/null -w '%{http_code}' \
  -X POST http://socket-proxy:2375/containers/create     # must be 403

# Is Redis actually requiring a password?
docker run --rm --network backend redis:<tag> redis-cli -h redis ping   # must be NOAUTH
```

If a check returns something unexpected, **stop and investigate**. An unexpected
`400` where you expected `403` means the request reached the daemon.

## Reporting to the user

At the end of each phase, briefly state: what changed, what you verified (with
the actual evidence), and anything you deliberately skipped. Keep it short.

At the very end, be honest about what is *not* covered. A setup summary that
reads like a victory lap is not useful. Typical remaining gaps on a fresh build:

- **Off-site backups** — backups on the same disk do not survive losing the VPS
- **Alerting** — a health check nobody runs is not monitoring
- **DNS/registrar security** — DNSSEC, transfer lock, MFA; whoever holds the
  domain bypasses everything else
- **Rate limiting, WAF, image scanning** — reasonable once there is a real app

Recommend these in priority order, and be clear that off-site backups and
registrar security are usually worth more than any additional server-side control.

## Secrets

Secrets go in files, never environment variables — `docker inspect` shows env,
and it leaks into logs and child processes.

Compose **ignores** `uid`/`gid`/`mode` on secrets outside Swarm, so each mount
inherits the host file's ownership, and every service reads its secret as a
different user. Get this wrong and services fail *open*.

After setting any secret, verify the container can read it:

```bash
docker compose exec <svc> sh -c \
  'for f in /run/secrets/*; do [ -s "$f" ] && cat "$f" >/dev/null 2>&1 \
   && echo "OK $f" || echo "UNREADABLE $f"; done'
```

Keep the secrets directory `0700` — that is what actually protects them on the
host — and make services fail closed when a secret is empty.
