#!/usr/bin/env node

import process from "node:process";

const tokenState = {
  token: "",
  expiresAtMs: 0,
};

function trimSlash(value) {
  return value.replace(/^\/+|\/+$/g, "");
}

export function parseResolverRequest(raw) {
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new Error("request must be valid JSON");
  }
  if (!parsed || typeof parsed !== "object") {
    throw new Error("request must be an object");
  }
  if (parsed.protocolVersion !== 1) {
    throw new Error("protocolVersion must be 1");
  }
  if (typeof parsed.provider !== "string" || parsed.provider.trim().length === 0) {
    throw new Error("provider must be a non-empty string");
  }
  if (!Array.isArray(parsed.ids) || parsed.ids.length === 0) {
    throw new Error("ids must be a non-empty array");
  }
  for (const id of parsed.ids) {
    if (typeof id !== "string" || id.trim().length === 0) {
      throw new Error("ids entries must be non-empty strings");
    }
  }
  return {
    protocolVersion: 1,
    provider: parsed.provider,
    ids: [...new Set(parsed.ids.map((value) => String(value).trim()))],
  };
}

export function mapIdToVaultTarget(id, mapping) {
  const kvMount = trimSlash(String(mapping?.kvMount ?? "secret"));
  const kvBasePath = trimSlash(String(mapping?.kvBasePath ?? "openclaw"));
  if (!kvMount) {
    throw new Error("kvMount must be non-empty");
  }

  const segments = String(id)
    .split("/")
    .map((segment) => segment.trim());
  if (segments.length < 2) {
    throw new Error("invalid_id_mapping: id must include at least one path segment and one field");
  }
  if (segments.some((segment) => !segment || segment === "." || segment === "..")) {
    throw new Error("invalid_id_mapping: id contains invalid path segments");
  }

  const field = segments.at(-1);
  const subPath = segments.slice(0, -1).join("/");
  const vaultDataPath = [kvMount, "data", kvBasePath, subPath].filter(Boolean).join("/");

  return {
    field,
    vaultDataPath,
  };
}

function parseCacheAllowlist(raw) {
  const out = {};
  const text = String(raw ?? "").trim();
  if (!text) {
    return out;
  }
  for (const chunk of text.split(",")) {
    const entry = chunk.trim();
    if (!entry) {
      continue;
    }
    const [id, ttlRaw] = entry.split("=");
    const key = String(id ?? "").trim();
    const ttlMs = Number(ttlRaw);
    if (!key || !Number.isFinite(ttlMs) || ttlMs <= 0) {
      continue;
    }
    out[key] = Math.floor(ttlMs);
  }
  return out;
}

function loadRuntimeConfig(env) {
  const vaultAddr = String(env.OPENCLAW_VAULT_ADDR ?? "http://127.0.0.1:8200").trim();
  const roleId = String(env.OPENCLAW_VAULT_ROLE_ID ?? "").trim();
  const secretId = String(env.OPENCLAW_VAULT_SECRET_ID ?? "").trim();
  if (!roleId) {
    throw new Error("OPENCLAW_VAULT_ROLE_ID is required");
  }
  if (!secretId) {
    throw new Error("OPENCLAW_VAULT_SECRET_ID is required");
  }

  const timeoutMs = Number(env.OPENCLAW_VAULT_HTTP_TIMEOUT_MS ?? 5000);
  return {
    vaultAddr,
    roleId,
    secretId,
    timeoutMs: Number.isFinite(timeoutMs) && timeoutMs > 0 ? Math.floor(timeoutMs) : 5000,
    mapping: {
      kvMount: String(env.OPENCLAW_VAULT_KV_MOUNT ?? "secret"),
      kvBasePath: String(env.OPENCLAW_VAULT_KV_BASE_PATH ?? "openclaw"),
    },
    allowlistCacheTtlMs: parseCacheAllowlist(env.OPENCLAW_VAULT_CACHE_ALLOWLIST),
  };
}

async function readStdin() {
  const chunks = [];
  for await (const chunk of process.stdin) {
    chunks.push(typeof chunk === "string" ? Buffer.from(chunk) : chunk);
  }
  return Buffer.concat(chunks).toString("utf8").trim();
}

async function fetchJson(fetchImpl, url, init, timeoutMs) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetchImpl(url, {
      ...init,
      signal: controller.signal,
      headers: {
        "content-type": "application/json",
        ...(init?.headers ?? {}),
      },
    });
    const text = await response.text();
    let parsed = null;
    if (text) {
      try {
        parsed = JSON.parse(text);
      } catch {
        parsed = null;
      }
    }
    if (!response.ok) {
      const reason = parsed?.errors?.[0] || parsed?.error || `HTTP ${response.status}`;
      throw new Error(String(reason));
    }
    if (!parsed || typeof parsed !== "object") {
      throw new Error("invalid JSON response");
    }
    return parsed;
  } finally {
    clearTimeout(timeout);
  }
}

async function loginWithAppRole(cfg, fetchImpl, nowMs) {
  const payload = {
    role_id: cfg.roleId,
    secret_id: cfg.secretId,
  };
  const data = await fetchJson(
    fetchImpl,
    `${cfg.vaultAddr.replace(/\/$/, "")}/v1/auth/approle/login`,
    {
      method: "POST",
      body: JSON.stringify(payload),
    },
    cfg.timeoutMs,
  );

  const token = data?.auth?.client_token;
  const leaseDurationSec = Number(data?.auth?.lease_duration ?? 0);
  if (typeof token !== "string" || token.trim().length === 0) {
    throw new Error("auth_failed");
  }
  const skewMs = 1_000;
  const durationMs =
    Number.isFinite(leaseDurationSec) && leaseDurationSec > 0 ? leaseDurationSec * 1000 : 60_000;
  tokenState.token = token;
  tokenState.expiresAtMs = nowMs() + Math.max(1_000, durationMs - skewMs);
  return token;
}

async function getVaultToken(cfg, fetchImpl, nowMs) {
  if (tokenState.token && tokenState.expiresAtMs > nowMs()) {
    return tokenState.token;
  }
  return loginWithAppRole(cfg, fetchImpl, nowMs);
}

function isVaultTokenReadError(message) {
  const normalized = String(message ?? "").toLowerCase();
  return (
    normalized.includes("permission denied") ||
    normalized.includes("bad token") ||
    (normalized.includes("token") && normalized.includes("expired")) ||
    (normalized.includes("token") && normalized.includes("invalid"))
  );
}

async function fetchVaultFieldValue({ id, cfg, fetchImpl, nowMs }) {
  const { field, vaultDataPath } = mapIdToVaultTarget(id, cfg.mapping);
  const doRead = async (token) =>
    fetchJson(
      fetchImpl,
      `${cfg.vaultAddr.replace(/\/$/, "")}/v1/${vaultDataPath}`,
      {
        method: "GET",
        headers: {
          "X-Vault-Token": token,
        },
      },
      cfg.timeoutMs,
    );

  let token = await getVaultToken(cfg, fetchImpl, nowMs);
  let body;
  try {
    body = await doRead(token);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    if (!isVaultTokenReadError(message)) {
      throw err;
    }
    tokenState.token = "";
    tokenState.expiresAtMs = 0;
    token = await getVaultToken(cfg, fetchImpl, nowMs);
    body = await doRead(token);
  }

  const value = body?.data?.data?.[field];
  if (typeof value !== "string" || value.length === 0) {
    throw new Error("field_not_found");
  }
  return value;
}

export async function resolveIdsWithPolicy(params) {
  const values = {};
  const errors = {};

  for (const id of params.ids) {
    const ttlMs = params.allowlistCacheTtlMs[id] ?? 0;
    try {
      const fresh = await params.resolveFresh(id);
      values[id] = fresh;
      if (ttlMs > 0) {
        params.cache.set(id, {
          value: fresh,
          expiresAtMs: params.nowMs() + ttlMs,
        });
      }
    } catch (err) {
      if (ttlMs > 0) {
        const cached = params.cache.get(id);
        if (cached && cached.expiresAtMs > params.nowMs()) {
          values[id] = cached.value;
          continue;
        }
      }
      const message = err instanceof Error ? err.message : String(err);
      errors[id] = { message };
    }
  }

  return {
    values,
    errors,
  };
}

const runtimeCache = new Map();

export function resetResolverStateForTests() {
  tokenState.token = "";
  tokenState.expiresAtMs = 0;
  runtimeCache.clear();
}

export async function runResolver({
  stdin = null,
  env = process.env,
  fetchImpl = globalThis.fetch,
  nowMs = () => Date.now(),
} = {}) {
  if (typeof fetchImpl !== "function") {
    throw new Error("global fetch is required");
  }

  const raw = stdin == null ? await readStdin() : String(stdin).trim();
  const request = parseResolverRequest(raw);
  const cfg = loadRuntimeConfig(env);

  const { values, errors } = await resolveIdsWithPolicy({
    ids: request.ids,
    nowMs,
    allowlistCacheTtlMs: cfg.allowlistCacheTtlMs,
    cache: runtimeCache,
    resolveFresh: async (id) => fetchVaultFieldValue({ id, cfg, fetchImpl, nowMs }),
  });

  const out = {
    protocolVersion: 1,
    values,
  };
  if (Object.keys(errors).length > 0) {
    out.errors = errors;
  }
  return out;
}

const isMain = import.meta.url === `file://${process.argv[1]}`;
if (isMain) {
  runResolver()
    .then((out) => {
      process.stdout.write(`${JSON.stringify(out)}\n`);
    })
    .catch((err) => {
      const message = err instanceof Error ? err.message : String(err);
      process.stderr.write(`[openclaw-vault-resolver] ${message}\n`);
      process.exitCode = 1;
    });
}
