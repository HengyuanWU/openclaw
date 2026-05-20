---
summary: "Docker Compose deployment handover runbook and live snapshot checklist"
read_when:
  - You are taking over an existing Docker Compose deployment
  - You need to verify current runtime state quickly without re-discovery
title: "Docker Compose Handover"
---

# Docker Compose Handover

This page records a practical handover baseline for an existing OpenClaw Docker Compose deployment, plus the exact commands to re-verify state after changes.

For routine upgrades, follow [Docker Compose Update SOP](/install/docker-update-sop).

## Snapshot timestamp

- Snapshot captured on **May 19, 2026 (UTC+8)**.
- Runtime should always be re-verified before making changes. Do not assume this snapshot is still current.

## Live deployment baseline (current handover)

Use this as the first-pass truth when onboarding a new maintainer.

### Compose project and files

- Compose project name: `openclaw`
- Active compose file: `/data/compose/openclaw/docker-compose.yml`
- Deployment `.env` path: `/data/compose/openclaw/.env`

### Services and runtime mode

- Long-running service: `openclaw-gateway`
- On-demand service: `openclaw-cli` (`docker compose run --rm ...`)
- Restart policy: `unless-stopped`
- Gateway health status at snapshot time: `healthy`

### Image and version baseline

- Runtime image: `openclaw:local`
- OCI version label at snapshot time: `2026.5.12`
- Node runtime in container env: `24.14.0`

### Network and exposed ports

- Gateway bind mode: `lan`
- Published host ports:
  - `127.0.0.1:18789 -> 18789/tcp` (gateway/control UI)
  - `127.0.0.1:18790 -> 18790/tcp` (bridge)

### Persistent data paths

- Host bind mount: `/home/node/.openclaw:/home/node/.openclaw`
- Host bind mount: `/home/node/.openclaw/workspace:/home/node/.openclaw/workspace`
- When sandbox mode is enabled, avoid named volumes for these paths. Sibling sandbox containers mount host paths, so named volumes can leave sandbox `/workspace` empty even when the gateway container itself can see files.

### Runtime config highlights (redacted)

- `gateway.mode`: `local`
- `gateway.bind`: `lan`
- `gateway.controlUi.allowedOrigins`:
  - `http://127.0.0.1:18789`
  - `http://localhost:18789`
- Plugin entry enabled: `feishu`
- Channel enabled: `feishu`
- Model provider configured: `bailian` (API key redacted)

## Known warnings observed in live logs

These warnings are present in current runtime output and should be resolved or intentionally accepted.

- `plugins.entries.feishu` duplicate plugin id warning (`/app/extensions/feishu/index.ts` and `/home/node/.openclaw/extensions/feishu/index.ts` both seen).
- Intermittent plugin load error:
  - `Cannot find module '@larksuiteoapi/node-sdk'` from `/app/extensions/feishu/src/client.ts`.
- Security hardening warning when binding non-loopback:
  - gateway warns about exposure risk when `--bind` is non-loopback.

## Fast verification commands (handover checklist)

Run these before any deploy/update/debug action:

```bash
docker compose -f /data/compose/openclaw/docker-compose.yml ps
docker compose -f /data/compose/openclaw/docker-compose.yml config
docker compose -f /data/compose/openclaw/docker-compose.yml logs --tail=120 openclaw-gateway
docker compose -f /data/compose/openclaw/docker-compose.yml run --rm -T openclaw-cli channels status --probe
docker compose -f /data/compose/openclaw/docker-compose.yml run --rm -T openclaw-cli sandbox explain
```

For update preflight on restricted networks:

```bash
docker pull docker/dockerfile:1.7
```

If that pull fails (for example `EOF`), follow the fallback branch in
[Docker Compose Update SOP](/install/docker-update-sop) before rebuild.

For config inspection inside the running gateway container:

```bash
docker compose -f /data/compose/openclaw/docker-compose.yml exec -T openclaw-gateway \
  sh -lc 'ls -la /home/node/.openclaw'
```

## Minimal takeover procedure (for new maintainers)

1. Confirm compose project is healthy with `docker compose ... ps`.
2. Confirm gateway is reachable and paired device flow works:
   - `docker compose ... run --rm -T openclaw-cli dashboard --no-open`
3. Confirm channel probe output and inspect warnings:
   - `docker compose ... run --rm -T openclaw-cli channels status --probe`
4. Review latest gateway logs for crash/restart loops:
   - `docker compose ... logs --tail=200 openclaw-gateway`
5. Validate persistent bind mounts are attached and keep host-path parity for sandboxing:
   - `docker inspect openclaw-openclaw-gateway-1 --format '{{json .Mounts}}'`
   - expected binds include `/home/node/.openclaw -> /home/node/.openclaw` and `/home/node/.openclaw/workspace -> /home/node/.openclaw/workspace`
6. If a sandboxed session shows empty `/workspace` or missing `skills/*/SKILL.md`, inspect the host sandbox tree before debugging agents:
   - `find /home/node/.openclaw/sandboxes -maxdepth 2 -mindepth 1 | sed -n '1,80p'`
7. Check plugin/channel configuration in `/home/node/.openclaw/openclaw.json` (inside container) with secrets redacted before sharing.

## Update workflow for this handover page

When deployment settings change, update this page in the same PR with:

1. New snapshot date/time.
2. Changed image tag or runtime version.
3. Changed ports/bind mode/volumes.
4. New warnings removed or introduced.
5. Verification command output summary (redacted, no tokens/secrets).

## Security notes for handover docs

- Never commit raw tokens, cookies, API keys, or full auth headers.
- If sharing command output, replace sensitive values with `<redacted>`.
- Keep external exposure explicit (loopback vs LAN/public), and verify firewall policy before opening non-loopback binds.
