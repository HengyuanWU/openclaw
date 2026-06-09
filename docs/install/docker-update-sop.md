---
summary: "Standard operating procedure for updating Docker Compose deployments, including sandbox-enabled setups"
read_when:
  - You operate OpenClaw with Docker Compose in production or long-lived environments
  - You need a repeatable update and rollback procedure
  - You run sandbox mode and use a custom image with Docker CLI support
title: "Docker Compose Update SOP"
---

# Docker Compose Update SOP

This SOP defines a single update flow for Docker Compose deployments that must keep sandbox support enabled.
It keeps the default Compose service/container naming and uses one local runtime image tag.

## Scope and assumptions

- Deployment path: `/data/compose/openclaw`
- Compose file: `/data/compose/openclaw/docker-compose.yml`
- Env file: `/data/compose/openclaw/.env`
- Long-running service: `openclaw-gateway`
- On-demand CLI service: `openclaw-cli`
- Docker BuildKit + buildx are available on the host:
  - `docker buildx version`
  - if missing on Ubuntu/Debian: `sudo apt-get install -y docker-buildx`

If your paths differ, adjust commands before running.

## Update strategy

This SOP uses one stable runtime tag:

- `OPENCLAW_IMAGE=openclaw:local`

Why:

- container/service names stay default (`openclaw-gateway`, `openclaw-openclaw-gateway-1`)
- the runtime image always includes Docker CLI for sandbox execution
- updates are repeatable by rebuilding the same local tag

Do not point runtime directly at `ghcr.io/openclaw/openclaw:latest` when sandbox must remain enabled.

## One-time baseline setup

Run this once when adopting this SOP:

1. Set local runtime image tag in deployment env:
   - `OPENCLAW_IMAGE=openclaw:local`
2. Keep sandbox intent explicit in deployment env:
   - `OPENCLAW_SANDBOX=1`
3. Set Docker socket group id in deployment env:
   - `DOCKER_GID=$(stat -c '%g' /var/run/docker.sock)`
4. Ensure Compose gateway service keeps these lines enabled:
   - mount: `/var/run/docker.sock:/var/run/docker.sock`
   - `group_add: ["${DOCKER_GID:-999}"]`
5. When sandbox mode is enabled, keep OpenClaw state on host bind mounts, not named volumes:
   - recommended:
     - `/home/node/.openclaw:/home/node/.openclaw`
     - `/home/node/.openclaw/workspace:/home/node/.openclaw/workspace`
   - avoid:
     - named volumes at `/home/node/.openclaw` or `/home/node/.openclaw/workspace`
   - why:
     - sibling sandbox containers mount host paths, not the gateway container's private named-volume namespace
     - if the gateway keeps `.openclaw` only inside named volumes, sandbox `/workspace` can come up empty and mirrored files such as `skills/*/SKILL.md`, `MEMORY.md`, and sandbox state files will be missing

These are prerequisites. They are not repeated renames and do not change container names.

## Pre-update checklist

1. Confirm current health:
   - `docker compose -f /data/compose/openclaw/docker-compose.yml ps`
   - `docker compose -f /data/compose/openclaw/docker-compose.yml logs --tail=120 openclaw-gateway`
2. If your deployment depends on a local secret backend, verify it before rebuilding images:
   - example for local Vault:
     - `docker compose -f /data/compose/openclaw/docker-compose.yml exec -T vault sh -lc 'VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=/vault/tls/vault.crt vault status'`
   - expected: `Sealed false`
   - if the secret backend is already unhealthy before the upgrade, fix that first or treat post-upgrade gateway restart failures as independent from the image update
3. Record current source revision (rollback anchor):
   - `cd /home/ubuntu/projects/openclaw`
   - `git rev-parse --short HEAD`
   - optional, if your checkout tracks tags:
     - `git describe --tags --always`
4. Choose target upgrade reference before touching containers:
   - stable release example: `vYYYY.M.D`
   - bleeding edge example: `origin/main`
   - write this value down as `TARGET_REF`
5. Snapshot effective compose config:
   - `docker compose -f /data/compose/openclaw/docker-compose.yml config > /tmp/openclaw-compose.preupdate.yaml`
6. Record current image digest:
   - `docker compose -f /data/compose/openclaw/docker-compose.yml images`
7. Confirm BuildKit availability (required by this repo Dockerfiles):
   - `docker buildx version`
8. If your deployment uses non-bundled external plugins from `~/.openclaw/extensions`, inventory them before the host update:
   - `docker compose -f /data/compose/openclaw/docker-compose.yml run --rm -T openclaw-cli plugins list`
   - for each external plugin you care about, record:
     - plugin id
     - installed version
     - install source (`npm`, `archive`, `path`, or `git`)
   - do not assume an old external plugin will remain compatible after the host update just because it survives on the persistent volume

## Update procedure

1. Sync OpenClaw source to your selected target reference:
   - `cd /home/ubuntu/projects/openclaw`
   - `git fetch origin --tags`
   - stable/tag example:
     - `git checkout vYYYY.M.D`
   - mainline example:
     - `git checkout main`
     - `git pull --ff-only origin main`
2. Confirm runtime tag is local:
   - `rg '^OPENCLAW_IMAGE=' /data/compose/openclaw/.env`
   - expected value: `OPENCLAW_IMAGE=openclaw:local`
3. Pull upstream base image:
   - `cd /home/ubuntu/projects/openclaw`
   - `scripts/docker/pull-openclaw-image.sh`
   - monitor progress in another shell:
     - `tail -f /tmp/openclaw-deploy.log`
   - if `/tmp/openclaw-deploy.log` is not writable in your environment, run:
     - `scripts/docker/pull-openclaw-image.sh --log-file /data/compose/openclaw/openclaw-deploy.log --state-file /data/compose/openclaw/openclaw-deploy.state`
   - if `docker pull` keeps failing through `dockerd` with registry/network errors such as `EOF`, token timeouts, or `failed to register layer ... file exists`, do not keep hammering the same path on a small host
   - first, verify shell-level access to GHCR through your proxy:
     - `curl -I -x "${HTTPS_PROXY:-http://127.0.0.1:7890}" https://ghcr.io/token?scope=repository:openclaw/openclaw:pull\&service=ghcr.io`
   - if shell access works but `docker pull` still fails, bypass `dockerd` pull with `skopeo`:
     - `sudo apt-get update && sudo apt-get install -y skopeo`
     - `HTTP_PROXY="${HTTP_PROXY:-http://127.0.0.1:7890}" HTTPS_PROXY="${HTTPS_PROXY:-http://127.0.0.1:7890}" ALL_PROXY="${ALL_PROXY:-socks5h://127.0.0.1:7891}" NO_PROXY="${NO_PROXY:-127.0.0.1,localhost}" skopeo copy --retry-times 10 --override-os linux --override-arch amd64 docker://ghcr.io/openclaw/openclaw:latest docker-archive:/data/compose/openclaw/openclaw-ghcr-latest.tar:ghcr.io/openclaw/openclaw:latest`
     - `docker load -i /data/compose/openclaw/openclaw-ghcr-latest.tar`
   - if you hit a local Docker metadata error such as `failed to register layer ... file exists`, restart Docker once and retry:
     - `sudo systemctl restart docker`
4. Export build env for BuildKit and optional proxy:
   - `export DOCKER_BUILDKIT=1`
   - optional, when your proxy endpoint is local (for example `127.0.0.1:7890`):
     - `export OPENCLAW_BUILD_HTTP_PROXY="${HTTP_PROXY:-http://127.0.0.1:7890}"`
     - `export OPENCLAW_BUILD_HTTPS_PROXY="${HTTPS_PROXY:-http://127.0.0.1:7890}"`
     - `export OPENCLAW_BUILD_NETWORK=host`
   - shell guardrail: do not use "inline temporary assignment + same-line `$OPENCLAW_BUILD_*` expansion". In Bash, expansion happens before that temporary assignment is applied, so proxy build args can become empty.
   - avoid this pattern:
     - `OPENCLAW_BUILD_HTTP_PROXY="${HTTP_PROXY}" docker build --build-arg HTTP_PROXY="$OPENCLAW_BUILD_HTTP_PROXY" ...`
   - use this pattern:
     - `export OPENCLAW_BUILD_HTTP_PROXY="${HTTP_PROXY:-http://127.0.0.1:7890}"`
     - `export OPENCLAW_BUILD_HTTPS_PROXY="${HTTPS_PROXY:-http://127.0.0.1:7890}"`
     - `docker build ${OPENCLAW_BUILD_NETWORK:+--network "$OPENCLAW_BUILD_NETWORK"} --build-arg HTTP_PROXY="$OPENCLAW_BUILD_HTTP_PROXY" --build-arg HTTPS_PROXY="$OPENCLAW_BUILD_HTTPS_PROXY" ...`
   - important: if you use `--build-arg HTTP_PROXY=...` / `HTTPS_PROXY=...`, do not pass empty values. Empty build args can override host proxy env and make in-build downloads bypass proxy.
   - quick check before build:
     - `env | rg -i '(^|_)(http_proxy|https_proxy|all_proxy|OPENCLAW_BUILD_HTTP_PROXY|OPENCLAW_BUILD_HTTPS_PROXY|OPENCLAW_BUILD_NETWORK)'`
     - `echo "HTTP_PROXY=$OPENCLAW_BUILD_HTTP_PROXY HTTPS_PROXY=$OPENCLAW_BUILD_HTTPS_PROXY"`
   - note: daemon-level proxy settings do not always cover in-build downloads (`curl`, package managers). Build args keep this explicit and repeatable.
   - BuildKit frontend preflight:
     - this repo uses Dockerfile syntax directives such as `# syntax=docker/dockerfile:1.7`
     - BuildKit fetches that frontend image before Dockerfile stages run
     - this fetch is not controlled by Docker `--build-arg HTTP_PROXY=...` settings
     - quick preflight:
       - `docker pull docker/dockerfile:1.7`
     - if preflight fails with registry/network errors (for example `EOF`):
       - verify Docker daemon proxy or mirror settings first
       - then retry build
     - emergency fallback (when daemon-side fix is not immediately available):
       - create a temporary Dockerfile copy without the first `# syntax=...` line, then build with that temporary file
       - example:
         - `awk 'NR==1 && $0 ~ /^# syntax=docker\/dockerfile:/ {next} {print}' Dockerfile > /tmp/Dockerfile.openclaw.nosyntax`
         - `docker build ${OPENCLAW_BUILD_NETWORK:+--network "$OPENCLAW_BUILD_NETWORK"} --build-arg HTTP_PROXY="${OPENCLAW_BUILD_HTTP_PROXY:-}" --build-arg HTTPS_PROXY="${OPENCLAW_BUILD_HTTPS_PROXY:-}" --build-arg OPENCLAW_INSTALL_DOCKER_CLI=1 -t openclaw:local -f /tmp/Dockerfile.openclaw.nosyntax .`
       - apply the same temporary-file approach for `Dockerfile.sandbox` if needed
       - remove temporary files after the upgrade and treat this as a temporary workaround, not baseline config
5. Rebuild local runtime image with Docker CLI support:
   - `cd /home/ubuntu/projects/openclaw`
   - `docker build ${OPENCLAW_BUILD_NETWORK:+--network "$OPENCLAW_BUILD_NETWORK"} --build-arg HTTP_PROXY="${OPENCLAW_BUILD_HTTP_PROXY:-}" --build-arg HTTPS_PROXY="${OPENCLAW_BUILD_HTTPS_PROXY:-}" --build-arg OPENCLAW_INSTALL_DOCKER_CLI=1 -t openclaw:local -f Dockerfile .`
   - this is the preferred path when the host has enough memory for a full source rebuild
   - if a small VM repeatedly OOMs during `pnpm build:docker`, `tsdown`, or similar compile steps, stop retrying the full rebuild and switch to a thin wrapper over the official image
   - fetch `docker:cli` the same way if needed:
     - `HTTP_PROXY="${HTTP_PROXY:-http://127.0.0.1:7890}" HTTPS_PROXY="${HTTPS_PROXY:-http://127.0.0.1:7890}" ALL_PROXY="${ALL_PROXY:-socks5h://127.0.0.1:7891}" NO_PROXY="${NO_PROXY:-127.0.0.1,localhost}" skopeo copy --retry-times 10 --override-os linux --override-arch amd64 docker://docker.io/library/docker:cli docker-archive:/data/compose/openclaw/docker-cli-latest.tar:docker:cli`
     - `docker load -i /data/compose/openclaw/docker-cli-latest.tar`
   - then build a local wrapper from already-loaded images only:
     - `cat >/tmp/Dockerfile.openclaw.wrapper <<'EOF'`
     - `FROM docker:cli AS dockercli`
     - `FROM ghcr.io/openclaw/openclaw:latest`
     - `USER root`
     - `RUN mkdir -p /usr/local/libexec/docker/cli-plugins`
     - `COPY --from=dockercli /usr/local/bin/docker /usr/local/bin/docker`
     - `COPY --from=dockercli /usr/local/libexec/docker/cli-plugins/docker-buildx /usr/local/libexec/docker/cli-plugins/docker-buildx`
     - `COPY --from=dockercli /usr/local/libexec/docker/cli-plugins/docker-compose /usr/local/libexec/docker/cli-plugins/docker-compose`
     - `RUN chmod 0755 /usr/local/bin/docker /usr/local/libexec/docker/cli-plugins/docker-buildx /usr/local/libexec/docker/cli-plugins/docker-compose`
     - `USER node`
     - `EOF`
     - `DOCKER_BUILDKIT=0 docker build --pull=false -t openclaw:local -f /tmp/Dockerfile.openclaw.wrapper /tmp`
     - `rm -f /tmp/Dockerfile.openclaw.wrapper`
   - this wrapper keeps `OPENCLAW_IMAGE=openclaw:local` while avoiding a memory-heavy application rebuild
6. Ensure sandbox runtime image exists/updated:
   - `docker build ${OPENCLAW_BUILD_NETWORK:+--network "$OPENCLAW_BUILD_NETWORK"} --build-arg HTTP_PROXY="${OPENCLAW_BUILD_HTTP_PROXY:-}" --build-arg HTTPS_PROXY="${OPENCLAW_BUILD_HTTPS_PROXY:-}" -t openclaw-sandbox:bookworm-slim -f Dockerfile.sandbox .`
   - if rebuilding the sandbox image is temporarily impractical, at minimum ensure the tag still exists before restarting agents:
     - `docker images openclaw-sandbox:bookworm-slim`
   - if the tag is missing but you still have the known-good image ID from an old sandbox container, you can restore the tag as a temporary measure:
     - `docker inspect <old-sandbox-container> --format '{{.Image}}'`
     - `docker tag <image-id> openclaw-sandbox:bookworm-slim`
   - treat tag restoration as temporary. Refresh the sandbox image properly once the host can build or pull it safely.
7. Ensure Compose sandbox prerequisites remain enabled:
   - `docker compose -f /data/compose/openclaw/docker-compose.yml config | rg '/var/run/docker.sock|group_add|DOCKER_GID'`
   - `docker compose -f /data/compose/openclaw/docker-compose.yml config | rg '/home/node/.openclaw:/home/node/.openclaw|/home/node/.openclaw/workspace:/home/node/.openclaw/workspace'`
8. Recreate gateway on the rebuilt local tag:
   - `docker compose -f /data/compose/openclaw/docker-compose.yml up -d --force-recreate openclaw-gateway`
9. Sync external plugin versions to the upgraded host contract:
   - this applies to plugins installed under `~/.openclaw/extensions` that are not bundled inside `/app/dist/extensions`
   - recommended check:
     - `docker compose -f /data/compose/openclaw/docker-compose.yml run --rm -T openclaw-cli plugins list`
     - `docker compose -f /data/compose/openclaw/docker-compose.yml run --rm -T openclaw-cli plugins inspect <plugin-id>`
   - compare each external plugin version with the upgraded host version from:
     - `docker compose -f /data/compose/openclaw/docker-compose.yml run --rm -T openclaw-cli --version`
   - if the external plugin was installed from a tracked source and has an install record, update it:
     - single plugin:
       - `docker compose -f /data/compose/openclaw/docker-compose.yml run --rm -T openclaw-cli plugins update <plugin-id>`
     - all tracked external plugins:
       - `docker compose -f /data/compose/openclaw/docker-compose.yml run --rm -T openclaw-cli plugins update --all`
   - if `plugins update <plugin-id>` says there is no install record, do not stop there:
     - reinstall the plugin from an explicit compatible source instead
     - npm example:
       - `docker compose -f /data/compose/openclaw/docker-compose.yml run --rm -T openclaw-cli plugins install @openclaw/<plugin-name>@<host-version> --force --pin`
     - archive example:
       - `docker compose -f /data/compose/openclaw/docker-compose.yml run --rm -T openclaw-cli plugins install /home/node/.openclaw/<plugin-archive>.tgz --force`
   - if you updated or reinstalled any external plugin, restart the gateway again so the new plugin payload is loaded:
     - `docker compose -f /data/compose/openclaw/docker-compose.yml up -d --force-recreate openclaw-gateway`
   - example failure mode this step prevents:
     - host upgraded successfully, but an old external plugin still imports a retired Plugin SDK entrypoint and fails to load at startup

This update flow must be run on every version upgrade.

## Post-update verification

Run all checks before declaring success:

1. Container status:
   - `docker compose -f /data/compose/openclaw/docker-compose.yml ps`
2. Gateway health and startup logs:
   - `docker compose -f /data/compose/openclaw/docker-compose.yml logs --tail=200 openclaw-gateway`
   - if the gateway enters a restart loop with `required secrets are unavailable`, `Vault is sealed`, or unresolved `SecretRef` errors, do not misdiagnose that as an image-build failure
   - verify the secret backend separately before continuing:
     - `docker compose -f /data/compose/openclaw/docker-compose.yml exec -T vault sh -lc 'VAULT_ADDR=https://127.0.0.1:8200 VAULT_CACERT=/vault/tls/vault.crt vault status'`
3. CLI connectivity:
   - `docker compose -f /data/compose/openclaw/docker-compose.yml run --rm -T openclaw-cli gateway probe`
4. Channel probe:
   - `docker compose -f /data/compose/openclaw/docker-compose.yml run --rm -T openclaw-cli channels status --probe`
5. External plugin verification:
   - `docker compose -f /data/compose/openclaw/docker-compose.yml run --rm -T openclaw-cli plugins list`
   - for any external plugin you updated, confirm:
     - source path points at the expected installed artifact
     - version matches the intended host-compatible release
     - startup/load errors are absent from gateway logs
   - if a channel plugin is external, do not treat `channels status --probe` as enough by itself; first confirm the plugin loaded without module-resolution or manifest-contract errors
6. Control UI URL check:
   - `docker compose -f /data/compose/openclaw/docker-compose.yml run --rm -T openclaw-cli dashboard --no-open`
7. Confirm CLI version from the upgraded image:
   - `docker compose -f /data/compose/openclaw/docker-compose.yml run --rm -T openclaw-cli --version`

## Sandbox verification (required when sandbox mode is enabled)

1. Confirm configured mode:
   - `docker compose -f /data/compose/openclaw/docker-compose.yml exec -T openclaw-gateway sh -lc 'node -e "const c=require(\"/home/node/.openclaw/openclaw.json\");console.log(c?.agents?.defaults?.sandbox?.mode ?? \"<unset>\")"'`
   - expected: `all` or `non-main` (not `<unset>`)
   - if unset, set and restart:
     - `docker compose -f /data/compose/openclaw/docker-compose.yml run --rm -T openclaw-cli config set agents.defaults.sandbox.mode all`
     - `docker compose -f /data/compose/openclaw/docker-compose.yml up -d --force-recreate openclaw-gateway`
2. Confirm Docker CLI is available in gateway container:
   - `docker compose -f /data/compose/openclaw/docker-compose.yml exec -T openclaw-gateway sh -lc 'docker --version'`
3. Confirm Docker socket mount exists:
   - `docker compose -f /data/compose/openclaw/docker-compose.yml config | rg '/var/run/docker.sock|group_add'`
4. Confirm gateway user can access socket:
   - `docker compose -f /data/compose/openclaw/docker-compose.yml exec -T openclaw-gateway sh -lc 'docker ps >/dev/null && echo sandbox-prereq-ok'`
5. Confirm host-path parity for sandbox workspaces:
   - `docker inspect openclaw-openclaw-gateway-1 --format '{{json .Mounts}}'`
   - expected bind mounts include:
     - `/home/node/.openclaw -> /home/node/.openclaw`
     - `/home/node/.openclaw/workspace -> /home/node/.openclaw/workspace`
   - avoid deployments where these destinations come from named volumes when sandbox mode is on
6. Confirm effective runtime is sandboxed:
   - `docker compose -f /data/compose/openclaw/docker-compose.yml run --rm -T openclaw-cli sandbox explain`
   - expected output includes:
     - `runtime: sandboxed`
     - `mode: all` (or your configured `non-main` session behavior)
7. If a sandboxed session reports empty `/workspace` or missing mirrored skill files, inspect the host sandbox directory directly:
   - `find /home/node/.openclaw/sandboxes -maxdepth 2 -mindepth 1 | sed -n '1,80p'`
   - if this tree is empty while the gateway container shows files under the same path, fix the Compose mounts before debugging skills or tools

If any sandbox prerequisite fails, treat the update as incomplete.

## Post-update cleanup

After a successful upgrade, remove temporary pull/build artifacts so the host does not keep accumulating large archives and dangling images:

1. Remove downloaded archive files and pull state:
   - `rm -f /data/compose/openclaw/openclaw-ghcr-latest.tar /data/compose/openclaw/docker-cli-latest.tar`
   - `rm -f /data/compose/openclaw/openclaw-deploy.log /data/compose/openclaw/openclaw-deploy.state`
2. Remove helper/import images that are not part of the steady-state runtime:
   - `docker rmi ghcr.io/openclaw/openclaw:latest docker:cli || true`
3. Remove dangling images and stale builder cache:
   - `docker image prune -f`
   - `docker builder prune -f`
4. Re-check free space:
   - `df -h / /data`

## Rollback procedure

1. Return source checkout to the recorded pre-update revision:
   - `cd /home/ubuntu/projects/openclaw`
   - `git checkout <pre_update_commit_or_tag>`
2. Rebuild previous known-good local runtime image tag:
   - `docker build ${OPENCLAW_BUILD_NETWORK:+--network "$OPENCLAW_BUILD_NETWORK"} --build-arg HTTP_PROXY="${OPENCLAW_BUILD_HTTP_PROXY:-}" --build-arg HTTPS_PROXY="${OPENCLAW_BUILD_HTTPS_PROXY:-}" --build-arg OPENCLAW_INSTALL_DOCKER_CLI=1 -t openclaw:local -f Dockerfile .`
3. Recreate gateway:
   - `docker compose -f /data/compose/openclaw/docker-compose.yml up -d --force-recreate openclaw-gateway`
4. Re-run post-update verification checks.
5. If runtime state corruption is suspected, restore volume backups before restarting.

## Operational guardrails

- Never print raw secrets in logs, screenshots, or tickets.
- Never use ad-hoc compose filenames that overlap existing project files.
- Keep all deployment changes under version control in the deployment repo.
- Treat sandbox mode changes as security-sensitive changes and verify them explicitly after every update.
- Keep Compose service/container naming unchanged; this SOP does not require renaming containers.

## Related docs

- [Docker Compose Handover](/install/docker-compose-handover)
- [Docker](/install/docker)
- [Docker Volume Isolation](/design/docker-volume-isolation)
- [Sandboxing](/gateway/sandboxing)
