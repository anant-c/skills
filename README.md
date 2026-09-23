# Skills

Agent skills I use for real work, tested on real machines. Free and MIT-licensed.

Each skill is a folder of instructions that an AI coding agent (Claude Code,
Cursor, Codex and others) follows to do one job well: the steps, the traps, and
the checks that prove it worked.

## Install

```bash
npx skills add anant-c/skills                        # pick from the list
npx skills add anant-c/skills --skill vps-hardening  # just one
```

Or copy a folder from `skills/` into `~/.claude/skills/`.

## Skills

| Skill | What it does |
|---|---|
| [vps-hardening](skills/vps-hardening) | Turns a fresh Ubuntu VPS into a production-capable host with **no open ports except SSH**: Cloudflare Tunnel, Traefik, a read-only Docker socket proxy, Postgres/Redis on an internal network, tested backups and a 19-point health check. Every step is verified by trying to break it. Write-up: [vps-production-hardening](https://github.com/anant-c/vps-production-hardening). |

## How these are built

- **Tested, not written from memory.** Each skill has been run end to end on a
  real system, and the failures from that run went back into the skill.
- **They verify instead of asserting.** A green health check is not proof. The
  skills send the request an attacker or a user would send, and read the
  response.
- **They carry the traps.** The most valuable file in a skill is usually the list
  of things that fail silently.

## License

MIT
