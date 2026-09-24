# Restore runbook template

Write a copy of this to `~/docker/_docs/RESTORE.md` on the box during phase 11,
with the real names filled in. The runbook has to exist **before** the disaster.

This procedure was used end to end on 2026-09-23 to move a live stack onto a
fresh Ubuntu 26.04 box. The data matched, the app role came back still unable to
create tables, and the health check passed 19/19.

Placeholders: `<app>` is the app stack directory, `<db>` the database, `<owner>`
the owning (migration) role, `<ts>` a backup timestamp.

```
~/backups/<ts>/
├── postgres/<db>.dump            pg_dump custom format
├── postgres/globals.sql          roles; without these the app cannot log in
├── volumes/portainer_*.tar.gz    Portainer DB (admin hash: treat as a secret)
├── config/docker-config.tar.gz   compose files, traefik dynamic config, site content, docs
├── secrets/secrets.tar.gz        DB passwords, redis ACL, tunnel token
└── MANIFEST.txt                  image versions, networks, volumes, tunnel ingress rules
```

## A. Restore one database (bad migration, dropped table)

```sh
B=~/backups/<ts>; cd ~/docker/<app>
PG="docker exec -i <app>-postgres-1 sh -c"
docker compose stop <public-service>            # nothing writes during the restore

$PG 'PGPASSWORD="$(cat /run/secrets/postgres_password)" psql -U <owner> -d postgres' <<'SQL'
DROP DATABASE IF EXISTS <db>;
CREATE DATABASE <db> OWNER <owner>;
SQL
$PG 'PGPASSWORD="$(cat /run/secrets/postgres_password)" pg_restore -U <owner> -d <db> --no-owner --role=<owner>' \
  < "$B/postgres/<db>.dump"

# Verify BEFORE the app comes back: row counts, then least privilege.
$PG 'PGPASSWORD="$(cat /run/secrets/postgres_password)" psql -U <owner> -d <db> -c "SELECT relname, n_live_tup FROM pg_stat_user_tables;"'
docker compose start <public-service>
```

If the roles are gone too, first run
`$PG '... psql -U <owner> -d postgres' < $B/postgres/globals.sql`.
"already exists" errors for surviving roles are harmless.

## B. Restore Portainer

```sh
docker stop portainer
docker run --rm -v portainer_portainer_data:/dst -v "$B/volumes":/src:ro alpine:3.22 \
  sh -c 'rm -rf /dst/* && tar xzf /src/portainer_portainer_data.tar.gz -C /dst'
docker start portainer
```

Losing Portainer is not an emergency. A fresh volume plus a new admin account
works too.

## C. Full rebuild on a new host

1. Phases 1–5 from `host-setup.md`: admin user, SSH, UFW, Docker, networks.
   **Install `cron`**.
2. Copy the backup directory to the new box, then restore config and secrets:

   ```sh
   tar xzf $B/config/docker-config.tar.gz -C ~
   sudo tar xzf $B/secrets/secrets.tar.gz -C ~
   sudo chown -R 65532:65532 ~/docker/cloudflared/secrets     # cloudflared's uid
   chmod 700 ~/docker/*/secrets
   # Re-apply the per-file modes the services depend on. Wrong modes can mean
   # NO authentication (traps 2). Record the real modes for this stack here:
   #   chmod 0600 ~/docker/<app>/secrets/postgres_password
   #   chmod 0644 ~/docker/<app>/secrets/app_db_password
   #   chmod 0640 ~/docker/<app>/secrets/redis_acl
   ```

3. Infrastructure, then apps: `traefik` → `portainer` → apps → section A for
   each database → section B → `cloudflared` **last**, so the tunnel only
   carries traffic once something can answer it.
4. Tunnel: **same token** → nothing to change in Cloudflare (the tunnel dials
   out, so the new IP is irrelevant). **New tunnel** → add the apex and `*`
   routes again (`MANIFEST.txt` has them) and remove any leftover CNAMEs.
5. Reinstall the backup cron, run `backup.sh` once, and check that the new
   archive contains the tunnel token.
6. `healthcheck.sh` must pass, plus a port scan from outside: only 22 open.

**Measured: about 30 minutes** for the whole build and restore on a fresh
box, most of it package installs.

## Off-site copies

On-box backups do not survive losing the box. Pull them from a machine you
control, which needs no credentials on the VPS and can't be deleted by an
attacker who gets in:

```sh
rsync -az <host>:~/backups/ ~/server-backups/     # from the laptop, on a schedule
```

Encrypt before sending anywhere you don't control (`gpg --symmetric`), and keep
the passphrase off the VPS.
