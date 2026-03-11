#!/bin/bash
set -euo pipefail

# =============================================================================
# DO NOT EDIT — devcontainer-wt template engine (minimum mode)
# This script runs on the HOST before the container starts. It detects the
# worktree/project context and generates .env files.
#
# Minimum mode: no Docker network, no Traefik, no shared infra.
# =============================================================================

# --- Worktree and project detection ---

WORKTREE_DIR_NAME=$(basename "$PWD")

# Sanitize worktree name for use in DB names, container names, etc.
# Replace any non-alphanumeric character (except hyphen) with underscore, then lowercase.
WORKTREE_NAME=$(echo "$WORKTREE_DIR_NAME" | sed 's/[^a-zA-Z0-9-]/_/g' | tr '[:upper:]' '[:lower:]')

# Detect the current branch name.
# Replace slashes with hyphens and sanitize for DNS-safe names.
BRANCH_NAME=$(git branch --show-current | sed 's|/|-|g; s/[^a-zA-Z0-9-]/_/g' | tr '[:upper:]' '[:lower:]')

# Detect project name: use PROJECT_NAME env var if set, otherwise derive from main repo directory.
# The main repo directory is the parent of the git common dir.
gitdir="$(git rev-parse --git-common-dir)"
case $gitdir in
  /*) ;;
  *) gitdir="$PWD/$gitdir"
esac
GIT_COMMON_DIR=$(cd "$gitdir" && pwd)
MAIN_REPO_NAME=$(basename "$(dirname "$GIT_COMMON_DIR")")
PROJECT_NAME="${PROJECT_NAME:-$MAIN_REPO_NAME}"

LOCAL_WORKSPACE_FOLDER="$PWD"

# --- Local compose overrides ---

if [ ! -f ".devcontainer/docker-compose.local.yml" ]; then
  echo "# Personal Docker Compose overrides (gitignored). See docker-compose.local.yml.template for examples." \
    > .devcontainer/docker-compose.local.yml
  echo "[devcontainer-wt] Created empty docker-compose.local.yml stub."
fi

# --- Write .env for docker-compose variable substitution ---

cat > .devcontainer/.env <<EOF
WORKTREE_NAME=${WORKTREE_NAME}
BRANCH_NAME=${BRANCH_NAME}
GIT_COMMON_DIR=${GIT_COMMON_DIR}
MAIN_REPO_NAME=${MAIN_REPO_NAME}
PROJECT_NAME=${PROJECT_NAME}
LOCAL_WORKSPACE_FOLDER=${LOCAL_WORKSPACE_FOLDER}
EOF

# --- Expand .env.app.template → .env.app ---

# The .env.app.template uses ${VARIABLE} placeholders.
# All variables from init.sh are available for substitution.
if [ -f ".env.app.template" ]; then
  export WORKTREE_NAME BRANCH_NAME MAIN_REPO_NAME PROJECT_NAME
  envsubst < .env.app.template > .devcontainer/.env.app
  echo "[devcontainer-wt] .env.app generated from template."
else
  # Create empty .env.app so docker-compose env_file doesn't fail.
  touch .devcontainer/.env.app
fi

echo "[devcontainer-wt] init.sh complete for worktree '${WORKTREE_NAME}' branch '${BRANCH_NAME}' (project: ${PROJECT_NAME}, mode: minimum)"
