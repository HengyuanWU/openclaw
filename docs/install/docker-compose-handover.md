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

- Snapshot captured on **June 4, 2026 (UTC+8)**.
- Runtime should always be re-verified before making changes. Do not assume this snapshot is still current.

## Live deployment baseline (current handover)

Use this as the first-pass truth when onboarding a new maintainer.

### Compose project and files

- Compose project name: `openclaw`
- Active compose file: `/data/compose/openclaw/docker-compose.yml`
- Deployment `.env` path: `/data/compose/openclaw/.env`
- Coding-agent runtime Dockerfile: `/data/compose/openclaw/Dockerfile.coding-agents`

### Services and runtime mode

- Long-running service: `openclaw-gateway`
- On-demand service: `openclaw-cli` (`docker compose run --rm ...`)
- Restart policy: `unless-stopped`
- Gateway health status at snapshot time: `healthy`

### Image and version baseline

- Runtime image: `openclaw:local-coding-agents`
- Base runtime image: `openclaw:local`
- OpenClaw CLI version at snapshot time: `2026.5.28`
- Node runtime in container env: `24.14.0`
- Coding-agent CLIs installed in the runtime image:
  - `codex` (`codex-cli 0.137.0`)
  - `claude` (`Claude Code 2.1.162`)
  - `opencode` (`1.15.13`)

The local runtime image is built from `Dockerfile.coding-agents` next to the active compose file. It installs only the external coding-agent CLIs on top of `openclaw:local`; it does not change the sandbox image.

### Network and exposed ports

- Gateway bind mode: `lan`
- Published host ports:
  - `127.0.0.1:18789 -> 18789/tcp` (gateway/control UI)
  - `127.0.0.1:18790 -> 18790/tcp` (bridge)

### Persistent data paths

- Host bind mount: `/data/openclaw-home:/home/node`
- Host bind mount: `./openclaw-certs:/home/node/.openclaw/certs:ro`
- Gateway-only bind mount: `/var/run/docker.sock:/var/run/docker.sock`
- When sandbox mode is enabled, avoid named volumes for these paths. Sibling sandbox containers mount host paths, so named volumes can leave sandbox `/workspace` empty even when the gateway container itself can see files.
- The full container home is persisted because external coding-agent CLIs keep auth and runtime state outside OpenClaw's own state directory:
  - Codex: `/home/node/.codex`
  - Claude Code: `/home/node/.claude` and `/home/node/.claude.json`
  - OpenCode: `/home/node/.local/share/opencode`

Do not mount the host user's whole home directory into the container. Copy or log in to only the required CLI auth stores, and never print auth file contents.

### Proxy baseline

The gateway and CLI services use standard HTTP proxy environment variables so child CLI processes inherit outbound routing:

```yaml
HTTP_PROXY: http://172.19.0.1:7890
HTTPS_PROXY: http://172.19.0.1:7890
http_proxy: http://172.19.0.1:7890
https_proxy: http://172.19.0.1:7890
NO_PROXY: localhost,127.0.0.1,::1,openclaw-gateway,openclaw-cli,openclaw-vault,vault,host.docker.internal
no_proxy: localhost,127.0.0.1,::1,openclaw-gateway,openclaw-cli,openclaw-vault,vault,host.docker.internal
```

`ALL_PROXY` is intentionally not set for the gateway or CLI services. Some CLIs and HTTP libraries treat `ALL_PROXY` as a SOCKS or catch-all fallback; in this deployment, keeping only `HTTP_PROXY` and `HTTPS_PROXY` avoids routing Codex streaming requests through a SOCKS fallback.

The host proxy must listen on the Docker bridge address used by the compose network. At the snapshot time, the proxy listens on `172.19.0.1:7890`. The host `127.0.0.1` is not reachable from bridge-network containers as the host loopback.

The Docker daemon also has a systemd proxy drop-in. At the snapshot time, `docker info` reports:

```text
HTTPProxy=http://172.19.0.1:7890
HTTPSProxy=http://172.19.0.1:7890
NoProxy=localhost,127.0.0.1,::1
```

Keep the daemon proxy aligned with the host proxy listener before running `docker pull` or image builds that need network access.

### Coding-agent baseline

The bundled `coding-agent` skill is enabled and ready:

- `skills.entries.coding-agent.enabled`: `true`
- `tools.exec.host`: `gateway`
- Skill requirements at snapshot time:
  - Any binaries: `claude`, `codex`, and `opencode` present
  - Config gate: satisfied
  - Visible to model: yes
  - Available as command: yes

Run coding-agent workers from the gateway container, not from the OpenClaw sandbox container. The gateway owns the external CLI processes, their auth state, proxy environment, and Docker daemon access. Do not mount the Docker socket into OpenClaw sandbox containers or custom Codex sandboxes.

The gateway container has Codex login state under `/home/node/.codex`. Validate login without printing tokens:

```bash
docker exec openclaw-openclaw-gateway-1 sh -lc 'HOME=/home/node codex login status'
```

Expected result:

```text
Logged in using ChatGPT
```

### Sandbox baseline

The current OpenClaw sandbox container is separate from the gateway runtime:

- Sandbox image: `openclaw-sandbox:bookworm-slim`
- Network mode: `none`
- Read-only root filesystem: `true`
- Restart policy: `no`

The sandbox has no Docker socket. If Docker is restarted, this sandbox container may exit and will not auto-restart. Restart it only if preserving the currently named sandbox container matters; otherwise the next OpenClaw agent run can create a fresh sandbox.

### Vault baseline

Vault runs as `openclaw-vault` and is required for SecretRef-backed provider credentials. After a Docker daemon restart, Vault may come back sealed; when sealed, the gateway can enter a restart loop with `Vault is sealed` secret resolution errors.

Check Vault without printing tokens:

```bash
docker exec openclaw-vault sh -lc \
  'VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=/vault/tls/ca/local-root-ca.crt vault status -format=json'
```

Healthy expected fields:

```json
{
  "initialized": true,
  "sealed": false
}
```

If Vault is sealed, unseal it with the existing operator key file. Do not print the key:

```bash
key=$(/home/ubuntu/clashctl/bin/yq -r '.unseal_keys_b64[0]' /data/compose/openclaw/vault/init-keys.json)
docker exec -e VAULT_UNSEAL_KEY="$key" openclaw-vault sh -lc \
  'VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=/vault/tls/ca/local-root-ca.crt vault operator unseal "$VAULT_UNSEAL_KEY" >/dev/null'
unset key
docker restart openclaw-openclaw-gateway-1
```

### Runtime config highlights (redacted)

- `gateway.mode`: `local`
- `gateway.bind`: `lan`
- `gateway.controlUi.allowedOrigins`:
  - `http://127.0.0.1:18789`
  - `http://localhost:18789`
- Plugin entry enabled: `feishu`
- Channel enabled: `feishu`
- Model provider configured: `bailian` (API key redacted)
- Coding-agent skill enabled: `skills.entries.coding-agent.enabled = true`
- Exec host configured for coding-agent workers: `tools.exec.host = gateway`

## Known warnings observed in live logs

These warnings are present in current runtime output and should be resolved or intentionally accepted.

- Security hardening warning when binding non-loopback:
  - gateway warns about exposure risk when `--bind` is non-loopback.
- If Vault is sealed, the gateway logs required-secret startup failures until Vault is unsealed and the gateway is restarted.
- Compose may print `OPENCLAW_GATEWAY_TOKEN` warnings when running one-off CLI commands without the deployment env loaded by the caller. Do not paste token values into logs or docs.

## Fast verification commands (handover checklist)

Run these before any deploy/update/debug action:

```bash
docker compose -f /data/compose/openclaw/docker-compose.yml --env-file /data/compose/openclaw/.env ps
docker compose -f /data/compose/openclaw/docker-compose.yml --env-file /data/compose/openclaw/.env config --no-interpolate
docker compose -f /data/compose/openclaw/docker-compose.yml --env-file /data/compose/openclaw/.env logs --tail=120 openclaw-gateway
docker compose -f /data/compose/openclaw/docker-compose.yml --env-file /data/compose/openclaw/.env run --rm -T openclaw-cli skills info coding-agent
docker compose -f /data/compose/openclaw/docker-compose.yml --env-file /data/compose/openclaw/.env run --rm -T openclaw-cli config get tools.exec.host
docker compose -f /data/compose/openclaw/docker-compose.yml --env-file /data/compose/openclaw/.env run --rm -T openclaw-cli sandbox explain
```

For update preflight on restricted networks:

```bash
docker pull docker/dockerfile:1.7
docker info --format 'HTTPProxy={{.HTTPProxy}} HTTPSProxy={{.HTTPSProxy}} NoProxy={{.NoProxy}}'
```

If that pull fails (for example `EOF`), follow the fallback branch in [Docker Compose Update SOP](/install/docker-update-sop) before rebuild. If it fails with a proxy connection to `127.0.0.1:7890`, the Docker daemon proxy drop-in is stale; update the daemon proxy to the Docker bridge listener and restart Docker during a maintenance window.

For config inspection inside the running gateway container:

```bash
docker compose -f /data/compose/openclaw/docker-compose.yml exec -T openclaw-gateway \
  sh -lc 'ls -la /home/node/.openclaw'
```

For coding-agent readiness inside the running gateway container:

```bash
docker exec openclaw-openclaw-gateway-1 sh -lc '
  command -v codex && codex --version
  command -v claude && claude --version
  command -v opencode && opencode --version
  HOME=/home/node codex login status
  curl -fsS -o /dev/null -w "proxy-http:%{http_code}\n" https://example.com/
'
```

Expected proof summary:

```text
codex-cli 0.137.0
2.1.162 (Claude Code)
1.15.13
Logged in using ChatGPT
proxy-http:200
```

## Minimal takeover procedure (for new maintainers)

1. Confirm compose project is healthy with `docker compose ... ps`.
2. Confirm gateway is reachable and paired device flow works:
   - `docker compose ... run --rm -T openclaw-cli dashboard --no-open`
3. Confirm channel probe output and inspect warnings:
   - `docker compose ... run --rm -T openclaw-cli channels status --probe`
4. Review latest gateway logs for crash/restart loops:
   - `docker compose ... logs --tail=200 openclaw-gateway`
5. Validate persistent bind mounts are attached and keep host-path parity for sandboxing and CLI auth:
   - `docker inspect openclaw-openclaw-gateway-1 --format '{{json .Mounts}}'`
   - expected binds include `/data/openclaw-home -> /home/node`, `./openclaw-certs -> /home/node/.openclaw/certs:ro`, and `/var/run/docker.sock -> /var/run/docker.sock`
6. If a sandboxed session shows empty `/workspace` or missing `skills/*/SKILL.md`, inspect the host sandbox tree before debugging agents:
   - `find /data/openclaw-home/.openclaw/sandboxes -maxdepth 2 -mindepth 1 | sed -n '1,80p'`
7. Check coding-agent readiness:
   - `docker compose ... run --rm -T openclaw-cli skills info coding-agent`
   - `docker exec openclaw-openclaw-gateway-1 sh -lc 'HOME=/home/node codex login status'`
8. Check plugin/channel configuration in `/home/node/.openclaw/openclaw.json` (inside container) with secrets redacted before sharing.

## Docker restart procedure

Restart Docker only during a quiet window. This deployment has `LiveRestore=false`, so restarting Docker interrupts containers.

Expected restart behavior:

- `openclaw-gateway`, `openclaw-vault`, and `scrapling-mcp` use `unless-stopped` and should come back automatically.
- `searxng-core` and `searxng-valkey` use `always` and should come back automatically.
- Existing OpenClaw sandbox containers have restart policy `no`; they may exit and need manual restart only if the current sandbox session must be preserved.
- Vault may return sealed; unseal it before expecting the gateway to become healthy.

Procedure:

```bash
sudo systemctl daemon-reload
sudo systemctl restart docker
docker info --format 'HTTPProxy={{.HTTPProxy}} HTTPSProxy={{.HTTPSProxy}} NoProxy={{.NoProxy}}'
docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
```

If Vault is sealed:

1. Run the Vault status command from [Vault baseline](#vault-baseline).
2. Run the unseal command from [Vault baseline](#vault-baseline).
3. Restart the gateway:

```bash
docker restart openclaw-openclaw-gateway-1
```

If a sandbox container exited and must be preserved:

```bash
docker start <sandbox-container-name>
```

Then re-run the fast verification checklist.

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
