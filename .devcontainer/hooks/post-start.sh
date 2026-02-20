#!/bin/bash
set -euo pipefail

echo "=== devcontainer-wt: starting worktree '${WORKTREE_NAME}' ==="

# =============================================================================
# DO NOT EDIT — Git worktree symlink fix
# If this is a worktree (not the main repo), the .git file contains a host path
# (e.g., gitdir: /Users/you/myapp/.git/worktrees/feature-x) that doesn't resolve
# inside the container. Instead of rewriting the file, we create a symlink so the
# host path resolves transparently. The .git file is NEVER modified.
# =============================================================================
if [ -f ".git" ]; then
  host_gitdir=$(sed 's/gitdir: //' .git)
  host_git_common="${host_gitdir%/worktrees/*}"

  # Create symlink: /Users/you/myapp/.git → /workspaces/myapp/.git
  # Needs sudo because the host path (e.g. /Users/...) requires creating
  # directories at the filesystem root, which the remoteUser cannot do.
  sudo mkdir -p "$(dirname "$host_git_common")"
  sudo ln -sfn "/workspaces/${MAIN_REPO_NAME}/.git" "$host_git_common"

  # Verify git works
  if git status --short > /dev/null 2>&1; then
    echo "[devcontainer-wt] Git symlink fix applied. Git is working."
  else
    echo "[devcontainer-wt] WARNING: Git check failed after symlink fix."
    echo "[devcontainer-wt] Host gitdir: $host_gitdir"
    echo "[devcontainer-wt] Symlink: $host_git_common → /workspaces/${MAIN_REPO_NAME}/.git"
  fi
fi

# =============================================================================
# CUSTOMIZE — Project setup below
# Everything below this line is yours to edit. Add dependency installation,
# database initialization, migrations, dev server startup, etc.
# All commands should be idempotent (safe to run on every container start).
# =============================================================================

# --- Install dependencies ---
# Examples:
#   npm install
#   pnpm install
#   bundle install
#   pip install -r requirements.txt

# --- Database initialization ---
# Create a per-worktree database if it doesn't exist.
# Examples:
#   PGPASSWORD=dev psql -h "postgres-${PROJECT_NAME}" -U dev -tc \
#     "SELECT 1 FROM pg_database WHERE datname = '${PROJECT_NAME}_${WORKTREE_NAME}'" | \
#     grep -q 1 || \
#     PGPASSWORD=dev createdb -h "postgres-${PROJECT_NAME}" -U dev "${PROJECT_NAME}_${WORKTREE_NAME}"

# --- Migrations ---
# Examples:
#   npx prisma migrate deploy
#   rails db:migrate
#   alembic upgrade head

echo "=== devcontainer-wt: worktree '${WORKTREE_NAME}' ready ==="
