# Host setup: phases 1–5, as commands

Tested on a fresh provider image of Ubuntu 26.04 LTS (2026-09). Run as root
over SSH on a fresh box until step 2 creates the admin user; after that, run as
that user with `sudo`.

**Keep your first SSH session open for this whole file.** It is your way back in
if a change goes wrong.

## 1. Baseline — look before you change anything

```bash
ss -tulpn | grep LISTEN               # every 0.0.0.0 / [::] line faces the internet
uname -r; ls /boot/vmlinuz-*          # running kernel vs installed kernels
getent passwd | awk -F: '$3>=1000 && $3<65534 {print $1}'   # any non-root users?
ls -la /etc/ssh/sshd_config.d/        # cloud-init drop-ins live here (see traps 15)
which ufw cron || true                # minimal images may lack both (traps 17)
```

Tell the user what you found before proceeding: what listens publicly, whether a
non-root user exists, and which of `ufw` / `cron` are missing.

Then update and install what later phases assume:

```bash
export DEBIAN_FRONTEND=noninteractive
apt-get update && apt-get -y full-upgrade
apt-get -y install ufw cron ca-certificates curl
```

If `/var/run/reboot-required` exists afterwards, a new kernel is installed but
not running. Reboot **after** step 3 so the reboot also proves that SSH and the
firewall come back.

## 2. Admin user — before SSH is locked down

Provider images often ship with **only root**. Phase 2 sets
`PermitRootLogin no`; doing that before a second user exists locks everyone out.

```bash
ADMIN=ubuntu     # or the user's preferred name; ask
id "$ADMIN" >/dev/null 2>&1 || adduser --disabled-password --gecos "" "$ADMIN"
usermod -aG sudo "$ADMIN"
# Key-only user, so passwordless sudo (the cloud-image default). The key is the credential.
echo "$ADMIN ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-$ADMIN
chmod 440 /etc/sudoers.d/90-$ADMIN && visudo -cf /etc/sudoers.d/90-$ADMIN
install -d -m 700 -o "$ADMIN" -g "$ADMIN" /home/$ADMIN/.ssh
install -m 600 -o "$ADMIN" -g "$ADMIN" /root/.ssh/authorized_keys /home/$ADMIN/.ssh/authorized_keys
```

**Verify from a new connection** before going further:

```bash
ssh -o BatchMode=yes $ADMIN@<host> 'whoami && sudo -n true && echo SUDO_OK'
```

If the only way in so far was a password, install the key for root first
(`ssh-copy-id root@<host>`), and confirm a `BatchMode=yes` login works. Then
replace any weak initial root password with a long random one and tell the user
to store it in a password manager: it is what the provider's web console needs
if SSH ever breaks.

## 3. SSH — keys only

sshd uses the **first** value it reads for most settings, and it reads
`sshd_config.d/*.conf` in name order. Cloud-init ships `50-cloud-init.conf` with
`PasswordAuthentication yes`, so the hardening file must sort **before** it.

```bash
sudo tee /etc/ssh/sshd_config.d/10-hardening.conf >/dev/null <<'EOF'
# Named 10- so it is read before 50-cloud-init.conf (sshd uses the first value it reads).
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AllowUsers ubuntu
MaxAuthTries 3
X11Forwarding no
# kept on: the admin UI is reached through an SSH tunnel
AllowTcpForwarding yes
EOF
sudo chmod 600 /etc/ssh/sshd_config.d/10-hardening.conf
sudo sshd -t && sudo systemctl reload ssh      # validate BEFORE reload; reload, not restart
```

Replace `AllowUsers ubuntu` with the actual admin user.

Verify the **effective** config and the **behaviour**, not the file:

```bash
sudo sshd -T | grep -E '^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication|allowusers) '
# from the laptop, each as a NEW connection:
ssh -o BatchMode=yes <alias> 'echo NEW CONNECTION OK'
ssh -o BatchMode=yes root@<host> true                     # must be: Permission denied (publickey)
ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no <user>@<host> true
                                                          # must be: Permission denied (publickey)
                                                          # i.e. password is not even offered
ssh -f -N -L 9999:localhost:22 <alias> && nc -z localhost 9999 && echo FORWARD_OK
```

## 3b. Swap

Provider images usually ship with **no swap**. Without it, one memory spike (a
build, a leaking Node process) makes the box thrash until nothing answers, SSH
included, while the tunnel keeps reporting the site as up (traps 19). With swap,
the same spike is a slowdown you can see and fix. Use 2 GB; on a 1–2 GB box it is
not optional.

```bash
swapon --show                      # already have swap? skip this section
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile           # before mkswap: swap holds process memory, secrets included
sudo mkswap /swapfile
sudo swapon /swapfile
grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
# use swap as a last resort, not as a place to park running apps
echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-swappiness.conf
sudo sysctl -p /etc/sysctl.d/99-swappiness.conf
```

Some images already have a `/swapfile` line in `/etc/fstab` but no file behind it,
so swap silently never comes up. The `grep` guard keeps that line instead of adding
a duplicate; it works once the file exists.

Verify: `swapon --show` lists `/swapfile` at 2G, `sysctl vm.swappiness` is 10, and
`sudo findmnt --verify` reports **0 errors**. Its warning that the swap source is
"a regular file" is expected. The reboot at the end of the next section proves
it persists.

## 4. Firewall

Allow SSH **before** enabling, or the enable cuts your session.

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw default deny routed
sudo ufw allow 22/tcp comment ssh
sudo ufw --force enable
sudo ufw status verbose
```

Verify from outside, from the laptop: `nc -z -w5 <ip> 8080` must fail. Then tell
the user, in one or two sentences, that **Docker bypasses UFW** (traps 1).

Now reboot, and confirm that SSH hardening, UFW, swap and any new kernel all
came back:

```bash
sudo systemctl reboot
# then, from a new connection:
uname -r; [ -f /var/run/reboot-required ] && echo STILL_PENDING
sudo ufw status | head -1; sudo sshd -T | grep -E '^(passwordauthentication|permitrootlogin) '
swapon --show; sysctl vm.swappiness
```

## 5. Docker

Check that Docker's own repo supports the release. A brand-new Ubuntu release
can take a while to appear there; the distro's `docker.io` package works as a
fallback.

```bash
. /etc/os-release
curl -fsS -o /dev/null -w '%{http_code}\n' \
  https://download.docker.com/linux/ubuntu/dists/$VERSION_CODENAME/Release   # 200 = supported
```

```bash
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $VERSION_CODENAME stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt-get update
sudo apt-get -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{
  "live-restore": true,
  "log-driver": "local",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
sudo systemctl restart docker
sudo usermod -aG docker ubuntu     # root-equivalent; this user already has sudo, so nothing new is granted
```

Verify from a new session (group membership needs a fresh login):

```bash
docker info --format 'live-restore={{.LiveRestoreEnabled}} log={{.LoggingDriver}}'
ss -tlnH | grep -E ':2375|:2376' || echo "no TCP API (good)"
```

## 6. Networks

```bash
docker network create proxy
docker network create --internal backend
docker network create --driver bridge --subnet 172.21.0.0/24 edge
```

Prove that `backend` really has no internet:

```bash
docker run --rm --network backend alpine:3.22 sh -c \
  'nc -z -w4 1.1.1.1 443 && echo REACHABLE-FAIL || echo BLOCKED-PASS'
```

Continue with Traefik and cloudflared in `compose-templates.md`.
