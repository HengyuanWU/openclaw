---
summary: "Standard operating procedure for adding a new LLM API/provider to an existing OpenClaw deployment and proving it works"
read_when:
  - You need to add a new model provider or OpenAI-compatible relay to an existing deployment
  - You want a repeatable verification flow before switching the default model
  - You need to keep provider auth in SecretRefs instead of inline plaintext
title: "LLM Provider Onboarding SOP"
---

Add a new LLM provider in a way that is easy to verify and easy to keep working across updates.

This SOP is for long-lived deployments where you already have a working Gateway and want to add one more provider, relay, or API key without accidentally breaking the current default route.

For containerized installs, replace `openclaw ...` with your normal CLI wrapper, for example `docker compose -f <compose-file> run --rm -T openclaw-cli ...`.

## Before you begin

- Confirm the current deployment is healthy before changing provider config:

```bash
openclaw gateway status --deep
openclaw health
```

- Decide which provider id you are adding, which model you will verify first, and where the credential will live.
- Keep the current default model unchanged during onboarding. Verify the new provider with an explicit `--model provider/model` run before switching defaults.

Recommended placeholders used below:

- `<provider-id>`: provider id you want to expose in model refs
- `<model-id>`: exact first model to prove, for example `gpt-5.5`
- `<relay-base-url>`: custom API base URL when you are not using a built-in hosted route
- `<secret-provider-alias>`: your configured SecretRef provider alias, for example `vault_local`
- `<secret-id>`: the secret id inside that provider, for example `providers/<provider-id>/apiKey`

## Choose the provider id first

This decision matters more than the API key.

Recommended path:

- Use the built-in provider id only when you intentionally want that provider's native behavior.
- Use a dedicated custom provider id for OpenAI-compatible relays and third-party proxies.

Examples:

- Official OpenAI API: `openai`
- OpenAI-compatible relay: `aicodemirror`, `relay-openai`, or another deployment-specific id

Why:

- `openai/<model>` has OpenAI-specific runtime behavior and compatibility logic.
- A custom id keeps relay behavior explicit and avoids accidental coupling to official OpenAI defaults.

If you intentionally reuse `openai` with a non-OpenAI `baseUrl`, pin the provider runtime to PI:

```json5
{
  models: {
    providers: {
      openai: {
        agentRuntime: { id: "pi" },
      },
    },
  },
}
```

See [Model providers](/concepts/model-providers) and [Agent runtimes](/concepts/agent-runtimes) for the provider/runtime split.

## Add the provider config

Recommended path: patch the provider entry as one object, then validate before writing.

Example patch for a custom OpenAI-compatible relay:

```json5
{
  models: {
    providers: {
      "<provider-id>": {
        baseUrl: "<relay-base-url>",
        apiKey: {
          source: "exec",
          provider: "<secret-provider-alias>",
          id: "<secret-id>",
        },
        models: [],
        agentRuntime: { id: "pi" },
      },
    },
  },
}
```

Validate the patch first:

```bash
openclaw config patch --file ./provider.patch.json5 --dry-run --allow-exec
```

Apply it:

```bash
openclaw config patch --file ./provider.patch.json5 --allow-exec
```

Notes:

- Keep the credential as a SecretRef object. Do not paste the API key into `openclaw.json`.
- For built-in non-relay providers that already have the right runtime semantics, `agentRuntime` is often unnecessary.
- For OpenAI-compatible relays, `agentRuntime.id: "pi"` is the safe default.

See [Config](/cli/config) and [Secrets](/cli/secrets) for the command contracts.

## Make one exact model selectable

If you use `agents.defaults.models` as an allowlist, add one exact model first:

```bash
openclaw config set agents.defaults.models '{"<provider-id>/<model-id>":{}}' --strict-json --merge
```

Avoid starting with only `provider/*` until the first exact model has passed a real turn.

Why:

- Exact model refs give you a single concrete verification target.
- Wildcard entries are useful later for discovery and routing, but they are not the best first proof target.

## Reload secrets and restart the gateway

Refresh the active secret snapshot:

```bash
openclaw secrets reload
```

Then restart the Gateway:

```bash
openclaw gateway restart
```

This keeps the verification path honest. Do not assume the running process has already picked up your new provider state.

## Verify in layers

Use one narrow proof per layer.

### Check the stored provider config

```bash
openclaw config get models
```

Confirm:

- the provider id is present
- `baseUrl` is what you intended
- the credential is still a SecretRef
- `agentRuntime.id` is present when you need PI

### Check the visible model catalog

```bash
openclaw models list
```

If you added an allowlist entry, confirm the exact `provider/model` appears.

### Run a real agent turn

This is the decisive proof.

```bash
openclaw agent \
  --agent main \
  --session-id llm-provider-proof \
  --message "Reply with exactly OK." \
  --model <provider-id>/<model-id> \
  --thinking off \
  --json
```

Expected result:

- `status: "ok"`
- `summary: "completed"`
- response payload text is `OK`
- returned metadata shows the intended `provider` and `model`

Treat this step as authoritative even if a lighter helper command behaves differently.

## Switch the default model only after the proof is green

After the explicit test model works, switch the default if you actually want to route new turns there:

```bash
openclaw models set <provider-id>/<model-id>
```

Then re-check:

```bash
openclaw models status
```

## Troubleshooting

### `models status --probe` times out, but a real agent turn works

Do not treat that alone as provider failure.

Use the real `openclaw agent --model <provider/model>` proof as the release gate, then debug the probe path separately if you care about the helper command itself.

### `No API key found for provider "<provider-id>"`

Check, in order:

1. The provider entry exists in `openclaw.json`
2. The credential is on a supported SecretRef surface
3. `openclaw secrets reload` succeeded
4. The Gateway was restarted after the config change
5. The runtime model store did not preserve stale provider data from an older setup

If the provider was previously configured with a different `baseUrl` or inline key, verify the live run instead of assuming the runtime cache is already aligned.

### The relay works in a direct SDK test, but OpenClaw still routes incorrectly

This usually means the provider/runtime split is still ambiguous.

Recommended fixes:

- prefer a dedicated custom provider id for relays
- if you intentionally use `openai`, set `models.providers.openai.agentRuntime.id` to `pi`
- verify with an explicit `--model provider/model` run

### `config patch --dry-run` fails on unrelated schema errors

Fix the unrelated config drift first or use your existing healthy config as the patch base.

Useful checks:

```bash
openclaw doctor --fix
openclaw config get models
```

### Adding provider auth changed what `models list` shows

That can happen when:

- you use an allowlist
- you added a wildcard entry too early
- the new provider exposes a different runtime-specific catalog

Start with one exact allowlist model, verify it, then widen discovery only if you need it.

## Production notes

- Keep relay and third-party provider credentials in SecretRefs, not plaintext config.
- Prefer a custom provider id for OpenAI-compatible relays unless you explicitly want `openai` semantics.
- Re-run the exact explicit-model proof after major upgrades, secret rotations, or runtime changes.
- If you later add `provider/*` wildcard allowlist entries, keep at least one exact model proof command in your runbook.

## Related

- [Updating](/install/updating)
- [Docker Compose Update SOP](/install/docker-update-sop)
- [Model providers](/concepts/model-providers)
- [Models](/cli/models)
- [Config](/cli/config)
- [Secrets](/cli/secrets)
