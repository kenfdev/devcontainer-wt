#!/bin/bash
set -euo pipefail

# =============================================================================
# DO NOT EDIT — devcontainer-wt template engine
# This script runs on the HOST before the container starts. It detects the
# worktree/project context, creates the Docker network, generates .env files,
# and checks for orphaned containers.
# =============================================================================

# --- Worktree and project detection ---

WORKTREE_DIR_NAME=$(basename "$PWD")

# Sanitize worktree name for use in DB names, container names, etc.
# Replace any non-alphanumeric character (except hyphen) with underscore, then lowercase.
WORKTREE_NAME=$(echo "$WORKTREE_DIR_NAME" | sed 's/[^a-zA-Z0-9-]/_/g' | tr '[:upper:]' '[:lower:]')

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

NETWORK_NAME="devnet-${PROJECT_NAME}"
LOCAL_WORKSPACE_FOLDER="$PWD"

# --- Docker network ---

# Create per-project network if it doesn't exist (idempotent).
docker network create "$NETWORK_NAME" 2>/dev/null || true

# --- Write .env for docker-compose variable substitution ---

cat > .devcontainer/.env <<EOF
WORKTREE_NAME=${WORKTREE_NAME}
GIT_COMMON_DIR=${GIT_COMMON_DIR}
MAIN_REPO_NAME=${MAIN_REPO_NAME}
PROJECT_NAME=${PROJECT_NAME}
NETWORK_NAME=${NETWORK_NAME}
LOCAL_WORKSPACE_FOLDER=${LOCAL_WORKSPACE_FOLDER}
TRAEFIK_PORT=${TRAEFIK_PORT:-80}
EOF

# Activate infra profile only for the main worktree.
# Main worktree has .git as a directory; worktrees have .git as a file.
if [ -d ".git" ]; then
  echo "COMPOSE_PROFILES=infra" >> .devcontainer/.env
fi

# --- Expand .env.app.template → .env.app ---

# The .env.app.template uses ${VARIABLE} placeholders.
# All variables from init.sh are available for substitution.
if [ -f ".env.app.template" ]; then
  export WORKTREE_NAME MAIN_REPO_NAME PROJECT_NAME NETWORK_NAME
  envsubst < .env.app.template > .devcontainer/.env.app
  echo "[devcontainer-wt] .env.app generated from template."
else
  # Create empty .env.app so docker-compose env_file doesn't fail.
  touch .devcontainer/.env.app
fi

# --- Orphan container cleanup ---

# Automatically stop and remove containers whose worktree directories no longer
# exist (e.g., after `git worktree remove`). This runs every time any worktree
# starts, so orphans are cleaned up without manual intervention.
orphans=$(docker ps --filter "label=devcontainer-wt.project=${PROJECT_NAME}" \
  --format '{{.Names}} {{.Label "devcontainer-wt.worktree-dir"}}' 2>/dev/null || true)

if [ -n "$orphans" ]; then
  echo "$orphans" | while read -r container_name worktree_dir; do
    [ -z "$container_name" ] && continue
    if [ ! -d "$worktree_dir" ]; then
      echo "[devcontainer-wt] Orphaned container detected: $container_name (worktree dir: $worktree_dir)"
      echo "[devcontainer-wt] Removing orphaned container..."
      docker rm -f "$container_name" 2>/dev/null || true
    fi
  done
fi

echo "[devcontainer-wt] init.sh complete for worktree '${WORKTREE_NAME}' (project: ${PROJECT_NAME})"
