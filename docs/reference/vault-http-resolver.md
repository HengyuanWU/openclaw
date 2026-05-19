---
summary: "Local Vault CE AppRole resolver for OpenClaw exec SecretRef"
read_when:
  - Running a local Vault Community Edition service
  - Using OpenClaw SecretRef with source: \"exec\"
  - Needing strict-fail by default with selective cache fallback
title: "Vault HTTP Resolver"
---

# Vault HTTP resolver

This guide describes a local Node.js resolver executable for OpenClaw `source: "exec"` SecretRefs.

## Script location

- `scripts/openclaw-vault-resolver.mjs`

## Environment variables

Required:

- `OPENCLAW_VAULT_ROLE_ID`
- `OPENCLAW_VAULT_SECRET_ID`

Optional:

- `OPENCLAW_VAULT_ADDR` (default: `http://127.0.0.1:8200`)
- `OPENCLAW_VAULT_KV_MOUNT` (default: `secret`)
- `OPENCLAW_VAULT_KV_BASE_PATH` (default: `openclaw`)
- `OPENCLAW_VAULT_HTTP_TIMEOUT_MS` (default: `5000`)
- `OPENCLAW_VAULT_CACHE_ALLOWLIST` (CSV: `id=ttlMs,id2=ttlMs`)

Template file:

- `scripts/systemd/openclaw-vault-resolver.env.example`

TLS note:

- The resolver script default is plain HTTP for minimal local setups.
- For Docker Compose or any browser-accessible Vault UI, prefer HTTPS and set `OPENCLAW_VAULT_ADDR` explicitly.
- If Vault uses a private CA, OpenClaw must trust that CA. In the Compose example below this is done with `NODE_EXTRA_CA_CERTS`; the resolver itself does not have a separate CA path variable.

Cache behavior:

- Strict-fail by default.
- Only ids in `OPENCLAW_VAULT_CACHE_ALLOWLIST` can use in-memory fallback cache.

## Mapping contract

Fixed id mapping:

- `id=providers/openai/apiKey`
- resolver reads `secret/data/openclaw/providers/openai`
- resolver returns field `apiKey`

## Vault policy example

```hcl
path "secret/data/openclaw/*" {
  capabilities = ["read"]
}
```

## AppRole bootstrap example

```bash
# 1) Enable AppRole auth method once
vault auth enable approle

# 2) Write least-privilege read policy
cat > /tmp/openclaw-resolver-read.hcl <<'HCL'
path "secret/data/openclaw/*" {
  capabilities = ["read"]
}
HCL
vault policy write openclaw-resolver-read /tmp/openclaw-resolver-read.hcl

# 3) Create role bound to that policy
vault write auth/approle/role/openclaw-resolver \
  token_policies="openclaw-resolver-read" \
  token_ttl="30m" \
  token_max_ttl="2h"

# 4) Fetch credentials for resolver environment
vault read -field=role_id auth/approle/role/openclaw-resolver/role-id
vault write -f -field=secret_id auth/approle/role/openclaw-resolver/secret-id
```

## OpenClaw config snippet

```json5
{
  secrets: {
    providers: {
      vault_local: {
        source: "exec",
        command: "/absolute/path/to/scripts/openclaw-vault-resolver.mjs",
        jsonOnly: true,
        timeoutMs: 8000,
        noOutputTimeoutMs: 8000,
        passEnv: [
          "OPENCLAW_VAULT_ROLE_ID",
          "OPENCLAW_VAULT_SECRET_ID",
          "OPENCLAW_VAULT_ADDR",
          "OPENCLAW_VAULT_KV_MOUNT",
          "OPENCLAW_VAULT_KV_BASE_PATH",
          "OPENCLAW_VAULT_HTTP_TIMEOUT_MS",
          "OPENCLAW_VAULT_CACHE_ALLOWLIST",
          "PATH",
        ],
      },
    },
  },
  models: {
    providers: {
      openai: {
        baseUrl: "https://api.openai.com/v1",
        models: [{ id: "gpt-5", name: "gpt-5" }],
        apiKey: { source: "exec", provider: "vault_local", id: "providers/openai/apiKey" },
      },
    },
  },
}
```

## OpenClaw config set sequence

```bash
openclaw config set secrets.providers.vault_local.source exec
openclaw config set secrets.providers.vault_local.command /absolute/path/to/scripts/openclaw-vault-resolver.mjs
openclaw config set secrets.providers.vault_local.jsonOnly true
openclaw config set secrets.providers.vault_local.timeoutMs 8000
openclaw config set secrets.providers.vault_local.noOutputTimeoutMs 8000
openclaw config set secrets.providers.vault_local.passEnv '["OPENCLAW_VAULT_ROLE_ID","OPENCLAW_VAULT_SECRET_ID","OPENCLAW_VAULT_ADDR","OPENCLAW_VAULT_KV_MOUNT","OPENCLAW_VAULT_KV_BASE_PATH","OPENCLAW_VAULT_HTTP_TIMEOUT_MS","OPENCLAW_VAULT_CACHE_ALLOWLIST","PATH"]'

openclaw config set models.providers.openai.apiKey.source exec
openclaw config set models.providers.openai.apiKey.provider vault_local
openclaw config set models.providers.openai.apiKey.id providers/openai/apiKey
```

## Docker compose production SOP

Use this when OpenClaw runs in Docker Compose and you need Vault `exec` SecretRef to take effect in the live gateway runtime.

1. Make the resolver executable available inside the gateway container.

- Either bind-mount a host file into the container, or copy it into the persistent config volume.
- Use an absolute in-container path for `secrets.providers.<provider>.command`.
- Keep command file permissions strict (`chmod 700` recommended). If permissions are broader, OpenClaw may reject the command path as insecure.

2. Inject Vault runtime environment variables into service environment.

- Add `OPENCLAW_VAULT_ROLE_ID` and `OPENCLAW_VAULT_SECRET_ID` to `openclaw-gateway`.
- Add optional keys as needed: `OPENCLAW_VAULT_ADDR`, `OPENCLAW_VAULT_KV_MOUNT`, `OPENCLAW_VAULT_KV_BASE_PATH`, `OPENCLAW_VAULT_HTTP_TIMEOUT_MS`, `OPENCLAW_VAULT_CACHE_ALLOWLIST`.
- If your command path uses shebang `#!/usr/bin/env node`, include `PATH` in `passEnv`.
- For the common sidecar pattern, set `OPENCLAW_VAULT_ADDR=https://vault:8200`.
- If Vault is signed by a private CA, mount the CA certificate into the gateway container and set `NODE_EXTRA_CA_CERTS` to that CA file. OpenClaw is a Vault HTTPS client here; this does not put the OpenClaw web UI itself behind HTTPS.

Example Compose wiring:

```yaml
services:
  openclaw-gateway:
    environment:
      OPENCLAW_VAULT_ADDR: https://vault:8200
      NODE_EXTRA_CA_CERTS: /home/node/.openclaw/certs/vault-ca.crt
    volumes:
      - ./openclaw-certs:/home/node/.openclaw/certs:ro

  vault:
    environment:
      VAULT_ADDR: https://127.0.0.1:8200
      VAULT_CACERT: /vault/tls/ca/local-root-ca.crt
    volumes:
      - ./vault/tls:/vault/tls:ro,z
    healthcheck:
      test:
        [
          "CMD-SHELL",
          "VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=/vault/tls/ca/local-root-ca.crt vault status >/dev/null 2>&1",
        ]
```

Recommended file split for private CA deployments:

- `vault/tls/ca/local-root-ca.crt`: local root CA certificate
- `vault/tls/ca/local-root-ca.key`: local root CA private key; keep offline after issuing leaf certs
- `vault/tls/vault.crt`: Vault server leaf certificate
- `vault/tls/vault.key`: Vault server leaf private key
- `openclaw-certs/vault-ca.crt`: copy of the issuing CA certificate trusted by OpenClaw

3. Configure OpenClaw inside Compose.

```bash
docker compose -f <compose-file> run --rm -T openclaw-cli \
  config set secrets.providers.vault_local.source exec
docker compose -f <compose-file> run --rm -T openclaw-cli \
  config set secrets.providers.vault_local.command /opt/openclaw/bin/openclaw-vault-resolver.mjs
docker compose -f <compose-file> run --rm -T openclaw-cli \
  config set secrets.providers.vault_local.jsonOnly true
docker compose -f <compose-file> run --rm -T openclaw-cli \
  config set secrets.providers.vault_local.timeoutMs 8000
docker compose -f <compose-file> run --rm -T openclaw-cli \
  config set secrets.providers.vault_local.noOutputTimeoutMs 8000
docker compose -f <compose-file> run --rm -T openclaw-cli \
  config set secrets.providers.vault_local.passEnv '["OPENCLAW_VAULT_ROLE_ID","OPENCLAW_VAULT_SECRET_ID","OPENCLAW_VAULT_ADDR","OPENCLAW_VAULT_KV_MOUNT","OPENCLAW_VAULT_KV_BASE_PATH","OPENCLAW_VAULT_HTTP_TIMEOUT_MS","OPENCLAW_VAULT_CACHE_ALLOWLIST","PATH"]'
docker compose -f <compose-file> run --rm -T openclaw-cli \
  config set models.providers.openai.apiKey.source exec
docker compose -f <compose-file> run --rm -T openclaw-cli \
  config set models.providers.openai.apiKey.provider vault_local
docker compose -f <compose-file> run --rm -T openclaw-cli \
  config set models.providers.openai.apiKey.id providers/openai/apiKey
```

4. Restart and validate.

```bash
docker compose -f <compose-file> up -d openclaw-gateway
docker compose -f <compose-file> run --rm -T openclaw-cli secrets audit --check
docker compose -f <compose-file> run --rm -T openclaw-cli secrets reload
docker compose -f <compose-file> logs --tail=200 openclaw-gateway
```

5. If resolver still does not take effect, check these first.

- `openclaw.json` still points to `source: "file"` for the target credential.
- `secrets.providers.<provider>` is missing or provider name does not match the SecretRef.
- Resolver executable path does not exist inside container.
- Resolver command path permissions are too open.
- `OPENCLAW_VAULT_*` variables are not present in the running gateway container.
- Vault server certificate SANs do not cover the address the client actually uses, such as `vault`, `localhost`, or `127.0.0.1`.
- OpenClaw does not trust the private CA that issued the Vault server certificate.

See also:

- [Docker Compose Handover](/install/docker-compose-handover)
- [Docker Compose Update SOP](/install/docker-update-sop)

## Manual protocol test

```bash
echo '{"protocolVersion":1,"provider":"vault_local","ids":["providers/openai/apiKey"]}' \
  | OPENCLAW_VAULT_ROLE_ID=... OPENCLAW_VAULT_SECRET_ID=... node scripts/openclaw-vault-resolver.mjs
```

Expected shape:

```json
{ "protocolVersion": 1, "values": { "providers/openai/apiKey": "..." } }
```

## Validation flow

```bash
openclaw secrets audit --check
openclaw secrets reload
```

## Root token and unseal key SOP

For single-host production-style setups, keep recovery materials offline and rotate AppRole credentials on a schedule.

1. Keep root token and unseal key offline.

- Export recovery files from your compose directory (`vault/init-keys.json`, `vault/root.token`) to encrypted offline storage.
- Keep at least two offline copies in separate locations.
- Do not keep long-term root token plaintext in shell history or chat logs.

2. Use short-lived admin sessions.

- Use root token only to mint short-lived admin tokens for maintenance.
- Revoke temporary admin tokens after maintenance.

3. Rotate AppRole `secret_id` regularly.

- Recommended interval: every 7-30 days.
- Sequence: mint new `secret_id` -> update compose `.env` -> restart gateway -> verify -> revoke old accessor.

4. Rekey unseal material on a low-frequency schedule.

- Run rekey during maintenance windows.
- Validate unseal flow after rekey.
- Replace offline escrow copies immediately after rekey.

5. Expect manual unseal after container recreate unless you configured auto-unseal.

- TLS certificate rotation can require recreating the Vault container.
- With raft storage and no auto-unseal, Vault comes back initialized but sealed.
- After restart, run `vault operator unseal` with the stored unseal key material, then confirm `vault status` reports `Sealed false`.

## Browser UI over SSH tunnel

Use this when Vault UI is only exposed through SSH port forwarding to your local browser.

1. Serve Vault over HTTPS, not HTTP.

- SSH forwarding only moves bytes between local `localhost:<port>` and remote `127.0.0.1:8200`.
- It does not make an HTTP Vault endpoint secure and it does not make an untrusted certificate trusted.

2. Use a private root CA and a separate Vault leaf certificate.

- Root CA: signs certificates and is trusted by your local machine.
- Leaf certificate: presented by Vault and should include SANs for `vault`, `localhost`, and `127.0.0.1` when you use both sidecar access and local browser access through the tunnel.
- Avoid using one self-signed certificate as both CA and server certificate.

3. Trust the root CA on the local machine that runs the browser.

- Import the root CA certificate into the local OS or browser trust store.
- Then open `https://localhost:8200/ui` or the forwarded HTTPS URL directly.
- If the browser still shows a warning after the CA is trusted, verify that the certificate SANs match the forwarded hostname.

4. Understand why public websites usually do not need this step.

- Public websites normally use certificates issued by public CAs such as Let's Encrypt.
- Browsers and operating systems already trust those public CAs by default.
- Private SSH-tunnel-only services usually use an internal CA, so you must add trust locally yourself.

## Automation scripts

This repository provides helper scripts for rotation and verification:

- `scripts/rotate-secret-id.sh`
- `scripts/verify-vault-openclaw.sh`

Rotate AppRole `secret_id` and refresh OpenClaw runtime:

```bash
scripts/rotate-secret-id.sh \
  --compose-dir /data/compose/openclaw \
  --role openclaw-resolver
```

Verify Vault + OpenClaw integration end-to-end:

```bash
scripts/verify-vault-openclaw.sh \
  --compose-dir /data/compose/openclaw \
  --role openclaw-resolver \
  --policy openclaw-resolver-read \
  --id providers/openai/apiKey
```

Useful options:

- `--env-file <path>`: explicit compose env path (default: `<compose-dir>/.env`)
- `--vault-addr <url>`: override Vault address
- `--vault-cacert <path>`: override Vault CA cert path; point this at the issuing CA certificate, not the Vault leaf certificate, if you split CA and server certs
- `--root-token-file <path>`: token source file when `VAULT_TOKEN` is unset
- `--no-revoke-old` on `rotate-secret-id.sh`: keep previous `secret_id` active
- `--skip-reload` on `verify-vault-openclaw.sh`: skip `openclaw-cli secrets reload`

## Service environment injection

### systemd

```ini
# /etc/systemd/system/openclaw-gateway.service.d/vault-resolver.conf
[Service]
EnvironmentFile=/etc/openclaw/openclaw-vault-resolver.env
```

Then:

```bash
sudo systemctl daemon-reload
sudo systemctl restart openclaw-gateway
```

### launchd (macOS)

Use your service plist environment block:

```xml
<key>EnvironmentVariables</key>
<dict>
  <key>OPENCLAW_VAULT_ADDR</key><string>http://127.0.0.1:8200</string>
  <key>OPENCLAW_VAULT_ROLE_ID</key><string>...</string>
  <key>OPENCLAW_VAULT_SECRET_ID</key><string>...</string>
  <key>OPENCLAW_VAULT_KV_MOUNT</key><string>secret</string>
  <key>OPENCLAW_VAULT_KV_BASE_PATH</key><string>openclaw</string>
</dict>
```

## Notes

- The resolver does not persist cache to disk.
- The resolver prints errors to stderr and never prints secret values.
