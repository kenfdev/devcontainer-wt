#!/bin/bash
set -euo pipefail

echo "=== devcontainer-wt: starting worktree '${WORKTREE_NAME}' ==="

# --- Git worktree symlink fix ---
# If this is a worktree (not the main repo), the .git file contains a host path
# (e.g., gitdir: /Users/you/myapp/.git/worktrees/feature-x) that doesn't resolve
# inside the container. Instead of rewriting the file, we create a symlink so the
# host path resolves transparently. The .git file is NEVER modified.
if [ -f ".git" ]; then
  host_gitdir=$(sed 's/gitdir: //' .git)
  host_git_common="${host_gitdir%/worktrees/*}"

  # Create symlink: /Users/you/myapp/.git → /workspaces/myapp/.git
  mkdir -p "$(dirname "$host_git_common")"
  ln -sfn "/workspaces/${MAIN_REPO_NAME}/.git" "$host_git_common"

  # Verify git works
  if git status --short > /dev/null 2>&1; then
    echo "[devcontainer-wt] Git symlink fix applied. Git is working."
  else
    echo "[devcontainer-wt] WARNING: Git check failed after symlink fix."
    echo "[devcontainer-wt] Host gitdir: $host_gitdir"
    echo "[devcontainer-wt] Symlink: $host_git_common → /workspaces/${MAIN_REPO_NAME}/.git"
  fi
fi

# --- Install dependencies ---
cd /workspaces/${WORKTREE_NAME}
npm install

# --- Database initialization ---
# Create a per-worktree database if it doesn't exist.
PGPASSWORD=dev psql -h "postgres-${PROJECT_NAME}" -U dev -tc \
  "SELECT 1 FROM pg_database WHERE datname = '${PROJECT_NAME}_${WORKTREE_NAME}'" | \
  grep -q 1 || \
  PGPASSWORD=dev createdb -h "postgres-${PROJECT_NAME}" -U dev "${PROJECT_NAME}_${WORKTREE_NAME}" 2>/dev/null || \
  echo "[devcontainer-wt] Note: Could not create DB (Postgres may not be running yet if this is a feature worktree starting before main)."

# --- Dev server ---
nohup node src/server.js > /tmp/dev-server.log 2>&1 &

echo "=== devcontainer-wt: worktree '${WORKTREE_NAME}' ready ==="
