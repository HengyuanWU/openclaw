# Docker Volume Isolation for Agent Workspace

## Context

OpenClaw agents need read/write access to runtime state (for example `AGENTS.md`, sessions, and workspace bootstrap files).  
If these paths are host bind mounts, agent writes directly affect host directories.

## Security Goal

Keep agent writes inside container-managed storage, so host filesystem impact is constrained to Docker-managed volume data.

## Decision

Use Docker named volumes for agent runtime state:

- `openclaw_config_data` -> `/home/node/.openclaw`
- `openclaw_workspace_data` -> `/home/node/.openclaw/workspace`

Do not use host bind mounts for these two paths in production-by-default setups.

## Threat Model Notes

- Container isolation is reduced when broad host paths are bind-mounted as writable.
- Named volumes still live on the host, but they remove direct write access to arbitrary host paths.
- Isolation still requires normal hardening:
  - No Docker socket mount unless explicitly required.
  - Loopback-only port publishing unless remote access is required.
  - Auth token required for non-loopback access.

## Migration Pattern

1. Stop compose stack.
2. Create named volumes.
3. Copy existing config/workspace data from old storage into volumes.
4. Update compose service mounts from bind to volume.
5. Bring stack up and verify:
   - gateway health is `healthy`
   - mounts are `type: volume`
   - container runtime user can write required state directories
   - no `EACCES` errors in gateway logs
6. Remove old host bind directories only after verification.

## Rollback

If needed, revert compose mounts to previous bind paths and restart stack.  
Use only if volume migration is incomplete or data validation fails.

## Operations Guardrails

- Keep volume declarations explicit (`external: true` + `name`) to avoid accidental rename/prefix drift.
- Avoid granting write access to repository roots, user home, or unrelated host paths.
- Treat volume backup/restore as the supported data management path.
- Use [Docker Compose Update SOP](/install/docker-update-sop) for release updates and rollback drills.
