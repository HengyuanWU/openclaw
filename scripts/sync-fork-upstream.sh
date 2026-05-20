#!/usr/bin/env bash
set -euo pipefail

ORIGIN_REMOTE="origin"
UPSTREAM_REMOTE="upstream"
MAIN_BRANCH="main"
CUSTOM_BRANCH=""
DRY_RUN=0
ORIGINAL_BRANCH=""

usage() {
  cat <<'USAGE'
Usage: scripts/sync-fork-upstream.sh [options]

Sync a fork's main branch from upstream/main, then rebase a customization branch
onto the updated main branch and force-push it back to the fork.

Options:
  -b, --custom-branch <branch>  Customization branch to rebase
  -m, --main-branch <branch>    Main branch to sync (default: main)
  -o, --origin <remote>         Fork remote to push to (default: origin)
  -u, --upstream <remote>       Upstream remote to fetch from (default: upstream)
  --dry-run                     Print the Git commands without executing them
  -h, --help                    Show this help

Behavior:
  1. git switch <main>
  2. git fetch <upstream>
  3. git merge --ff-only <upstream>/<main>
  4. git push <origin> <main>
  5. git switch <custom-branch>
  6. git rebase <main>
  7. git push --force-with-lease <origin> <custom-branch>

If --custom-branch is omitted, the script uses the current branch when it is not
the main branch.
USAGE
}

die() {
  echo "$*" >&2
  exit 1
}

restore_original_branch() {
  local exit_code=$?
  local current_branch=""

  if [[ "$exit_code" -eq 0 || -z "$ORIGINAL_BRANCH" ]]; then
    return 0
  fi

  if [[ -d "$(git rev-parse --git-path rebase-merge)" || -d "$(git rev-parse --git-path rebase-apply)" ]]; then
    current_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    echo "Sync failed during rebase; staying on ${current_branch:-the current branch} for manual resolution." >&2
    trap - EXIT
    exit "$exit_code"
  fi

  current_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [[ -n "$current_branch" && "$current_branch" != "$ORIGINAL_BRANCH" ]]; then
    git switch "$ORIGINAL_BRANCH" >/dev/null 2>&1 || true
    echo "Sync failed; switched back to $ORIGINAL_BRANCH." >&2
  fi

  trap - EXIT
  exit "$exit_code"
}

run_cmd() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '+'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi

  "$@"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -b|--custom-branch)
      CUSTOM_BRANCH="${2:?missing value for $1}"
      shift 2
      ;;
    -m|--main-branch)
      MAIN_BRANCH="${2:?missing value for $1}"
      shift 2
      ;;
    -o|--origin)
      ORIGIN_REMOTE="${2:?missing value for $1}"
      shift 2
      ;;
    -u|--upstream)
      UPSTREAM_REMOTE="${2:?missing value for $1}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

git rev-parse --show-toplevel >/dev/null 2>&1 || die "Run this script inside a Git repository."
ORIGINAL_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
trap restore_original_branch EXIT

if [[ -z "$CUSTOM_BRANCH" ]]; then
  CUSTOM_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
fi

[[ "$CUSTOM_BRANCH" != "$MAIN_BRANCH" ]] || die "Custom branch must differ from $MAIN_BRANCH."

git remote get-url "$ORIGIN_REMOTE" >/dev/null 2>&1 || die "Missing remote: $ORIGIN_REMOTE"
git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1 || die "Missing remote: $UPSTREAM_REMOTE"
git show-ref --verify --quiet "refs/heads/$MAIN_BRANCH" || die "Missing local branch: $MAIN_BRANCH"
git show-ref --verify --quiet "refs/heads/$CUSTOM_BRANCH" || die "Missing local branch: $CUSTOM_BRANCH"

[[ -z "$(git status --short)" ]] || die "Working tree must be clean before syncing."

run_cmd git push --dry-run "$ORIGIN_REMOTE" "$MAIN_BRANCH"
run_cmd git switch "$MAIN_BRANCH"
run_cmd git fetch "$UPSTREAM_REMOTE"
run_cmd git merge --ff-only "$UPSTREAM_REMOTE/$MAIN_BRANCH"
run_cmd git push "$ORIGIN_REMOTE" "$MAIN_BRANCH"
run_cmd git switch "$CUSTOM_BRANCH"
run_cmd git rebase "$MAIN_BRANCH"

if git ls-remote --exit-code --heads "$ORIGIN_REMOTE" "$CUSTOM_BRANCH" >/dev/null 2>&1; then
  run_cmd git fetch "$ORIGIN_REMOTE" "$CUSTOM_BRANCH"
  run_cmd git push --force-with-lease "$ORIGIN_REMOTE" "$CUSTOM_BRANCH"
else
  run_cmd git push -u "$ORIGIN_REMOTE" "$CUSTOM_BRANCH"
fi
