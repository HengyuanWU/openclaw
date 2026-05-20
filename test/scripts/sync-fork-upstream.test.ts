import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { createScriptTestHarness } from "./test-helpers.js";

const scriptPath = path.join(process.cwd(), "scripts", "sync-fork-upstream.sh");
const { createTempDir } = createScriptTestHarness();

function run(cwd: string, command: string, args: string[]) {
  return execFileSync(command, args, {
    cwd,
    encoding: "utf8",
  }).trim();
}

function git(cwd: string, ...args: string[]) {
  return run(cwd, "git", args);
}

function writeRepoFile(repo: string, relativePath: string, contents: string) {
  const fullPath = path.join(repo, relativePath);
  mkdirSync(path.dirname(fullPath), { recursive: true });
  writeFileSync(fullPath, contents);
}

function createCommit(repo: string, message: string, relativePath: string, contents: string) {
  writeRepoFile(repo, relativePath, contents);
  git(repo, "add", relativePath);
  git(repo, "commit", "-qm", message);
}

function createSeededRemotePair() {
  const root = createTempDir("sync-fork-upstream-");
  const upstreamBare = path.join(root, "upstream.git");
  const upstreamWork = path.join(root, "upstream-work");
  const originBare = path.join(root, "origin.git");
  const localRepo = path.join(root, "local");

  git(root, "init", "-q", "--bare", upstreamBare);
  git(root, "init", "-q", upstreamWork);
  git(upstreamWork, "config", "user.email", "test@example.com");
  git(upstreamWork, "config", "user.name", "Test User");
  git(upstreamWork, "checkout", "-qb", "main");
  createCommit(upstreamWork, "seed upstream", "README.md", "seed\n");
  git(upstreamWork, "remote", "add", "origin", upstreamBare);
  git(upstreamWork, "push", "-u", "origin", "main");
  git(upstreamBare, "symbolic-ref", "HEAD", "refs/heads/main");

  git(root, "clone", "-q", "--bare", upstreamBare, originBare);
  git(originBare, "symbolic-ref", "HEAD", "refs/heads/main");
  git(root, "clone", "-q", originBare, localRepo);
  git(localRepo, "config", "user.email", "test@example.com");
  git(localRepo, "config", "user.name", "Test User");
  git(localRepo, "remote", "add", "upstream", upstreamBare);

  return {
    localRepo,
    originBare,
    upstreamWork,
  };
}

describe("scripts/sync-fork-upstream.sh", () => {
  it("syncs main from upstream and rebases a customization branch onto it", () => {
    const { localRepo, originBare, upstreamWork } = createSeededRemotePair();
    const customBranch = "customizations";

    git(localRepo, "switch", "-c", customBranch);
    createCommit(localRepo, "custom change", "custom.txt", "local-only\n");
    git(localRepo, "push", "-u", "origin", customBranch);

    createCommit(upstreamWork, "upstream update", "README.md", "seed\nupstream\n");
    git(upstreamWork, "push", "origin", "main");

    run(localRepo, "bash", [scriptPath, "--custom-branch", customBranch]);

    expect(git(localRepo, "rev-parse", "main")).toBe(git(localRepo, "rev-parse", "upstream/main"));
    expect(git(localRepo, "rev-parse", "main")).toBe(git(localRepo, "rev-parse", "origin/main"));
    expect(git(localRepo, "rev-parse", "HEAD")).toBe(git(localRepo, "rev-parse", customBranch));
    expect(git(localRepo, "merge-base", "HEAD", "main")).toBe(git(localRepo, "rev-parse", "main"));
    expect(git(localRepo, "status", "--short")).toBe("");
    expect(git(localRepo, "show", "--quiet", "--format=%s", "HEAD")).toBe("custom change");

    const originCustomHead = git(originBare, "rev-parse", `refs/heads/${customBranch}`);
    expect(originCustomHead).toBe(git(localRepo, "rev-parse", "HEAD"));
  });

  it("refreshes the fork branch before force-with-lease after a remote rename", () => {
    const { localRepo, originBare, upstreamWork } = createSeededRemotePair();
    const customBranch = "customizations";

    git(localRepo, "switch", "-c", customBranch);
    createCommit(localRepo, "custom v1", "custom.txt", "v1\n");
    git(localRepo, "push", "-u", "origin", customBranch);

    git(localRepo, "remote", "rename", "origin", "upstream-old");
    git(localRepo, "remote", "add", "origin", originBare);

    createCommit(upstreamWork, "upstream update", "README.md", "seed\nupstream\n");
    git(upstreamWork, "push", "origin", "main");

    git(localRepo, "reset", "--hard", "HEAD~1");
    createCommit(localRepo, "custom v2", "custom.txt", "v2\n");

    run(localRepo, "bash", [scriptPath, "--custom-branch", customBranch]);

    expect(git(localRepo, "rev-parse", "main")).toBe(git(localRepo, "rev-parse", "upstream/main"));
    expect(git(localRepo, "rev-parse", "HEAD")).toBe(
      git(originBare, "rev-parse", `refs/heads/${customBranch}`),
    );
    expect(git(localRepo, "show", "--quiet", "--format=%s", "HEAD")).toBe("custom v2");
  });

  it("fails before branch switching when origin push auth is unavailable", () => {
    const { localRepo } = createSeededRemotePair();
    const customBranch = "customizations";

    git(localRepo, "switch", "-c", customBranch);
    createCommit(localRepo, "custom change", "custom.txt", "local-only\n");
    git(localRepo, "remote", "set-url", "origin", path.join(localRepo, "missing-origin.git"));

    expect(() => run(localRepo, "bash", [scriptPath, "--custom-branch", customBranch])).toThrow();
    expect(git(localRepo, "rev-parse", "--abbrev-ref", "HEAD")).toBe(customBranch);
  });
});
