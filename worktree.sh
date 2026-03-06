#!/bin/bash
set -euo pipefail

# Guard: must run on host, not inside a container
if [ -f /.dockerenv ] || [ -f /run/.containerenv ] || grep -qsw 'docker\|containerd' /proc/1/cgroup 2>/dev/null; then
  echo "Error: worktree.sh must be run on the host machine, not inside a container." >&2
  exit 1
fi

# =============================================================================
# devcontainer-wt CLI — worktree lifecycle management
#
# Usage:
#   ./worktree.sh add [branch]       Create a new worktree
#   ./worktree.sh remove [--force] <path>  Remove a worktree and its container
#   ./worktree.sh list               List worktrees with container status
#   ./worktree.sh prune              Clean up orphaned containers
# =============================================================================

# --- Colors & logging ---

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

info()    { echo -e "${BLUE}[devcontainer-wt]${NC} $*"; }
warn()    { echo -e "${YELLOW}[devcontainer-wt]${NC} $*"; }
error()   { echo -e "${RED}[devcontainer-wt]${NC} $*" >&2; }
success() { echo -e "${GREEN}[devcontainer-wt]${NC} $*"; }

# --- Project detection (same logic as init.sh) ---

detect_project() {
  local gitdir
  gitdir="$(git rev-parse --git-common-dir 2>/dev/null)" || {
    error "Not a git repository."
    exit 1
  }
  case $gitdir in
    /*) ;;
    *) gitdir="$PWD/$gitdir"
  esac
  GIT_COMMON_DIR=$(cd "$gitdir" && pwd)
  MAIN_REPO_DIR=$(dirname "$GIT_COMMON_DIR")
  MAIN_REPO_NAME=$(basename "$MAIN_REPO_DIR")
  PROJECT_NAME="${PROJECT_NAME:-$MAIN_REPO_NAME}"
}

# --- Worktreeinclude file copy ---

# Copy files matching patterns in .worktreeinclude and .worktreeinclude.local
# from the main worktree to a target worktree directory.
copy_worktreeinclude_files() {
  local target_root="$1"
  local include_file="${MAIN_REPO_DIR}/.worktreeinclude"
  local local_file="${MAIN_REPO_DIR}/.worktreeinclude.local"

  if [ ! -f "$include_file" ] && [ ! -f "$local_file" ]; then
    return
  fi

  _copy_from_include_file "$include_file" "$target_root"
  _copy_from_include_file "$local_file" "$target_root"
}

_copy_from_include_file() {
  local include_file="$1" target_root="$2"

  [ -f "$include_file" ] || return 0

  while IFS= read -r line; do
    # Skip comments and empty lines
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    (
      cd "$MAIN_REPO_DIR"
      shopt -s dotglob globstar nullglob
      for f in $line; do
        [[ "$f" == *node_modules* ]] && continue
        if [ -f "$f" ]; then
          mkdir -p "${target_root}/$(dirname "$f")"
          cp "$f" "${target_root}/${f}"
          info "  Copied: ${f}"
        fi
      done
    )
  done < "$include_file"
}

# --- Cleanup hook ---

# Run the on-remove.sh hook if it exists.
# Args: $1=WORKTREE_NAME, $2=PROJECT_NAME, $3=BRANCH_NAME (optional)
run_on_remove_hook() {
  local wt_name="$1"
  local proj_name="$2"
  local branch_name="${3:-}"
  local hook_path="${MAIN_REPO_DIR}/.devcontainer/hooks/on-remove.sh"

  if [ -f "$hook_path" ] && [ -x "$hook_path" ]; then
    info "Running on-remove hook for worktree '${wt_name}'..."
    WORKTREE_NAME="$wt_name" PROJECT_NAME="$proj_name" BRANCH_NAME="$branch_name" \
      "$hook_path" || warn "on-remove hook returned non-zero exit code."
  fi
}

# --- Subcommand: add ---

cmd_add() {
  local branch="${1:-}"

  if [ -z "$branch" ]; then
    echo -en "${BLUE}[devcontainer-wt]${NC} Branch name: " > /dev/tty
    read -r branch < /dev/tty
    if [ -z "$branch" ]; then
      error "Branch name is required."
      exit 1
    fi
  fi

  local dir_name="${PROJECT_NAME}-${branch}"
  local worktree_path="${MAIN_REPO_DIR}/../${dir_name}"

  info "Creating worktree at ${BOLD}${worktree_path}${NC} (branch: ${branch})..."
  git worktree add "$worktree_path" -b "$branch"

  # Copy files listed in .worktreeinclude / .worktreeinclude.local
  copy_worktreeinclude_files "$worktree_path"

  echo
  success "Worktree created: ${worktree_path}"
  echo
  info "Next steps:"
  info "  ${BOLD}code ${worktree_path}${NC}   -- open in VS Code"
  info "  Then click ${BOLD}\"Reopen in Container\"${NC}"
}

# --- Subcommand: remove ---

cmd_remove() {
  local force=false
  local wt_path=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --force|-f) force=true; shift ;;
      -*) error "Unknown option: $1"; exit 1 ;;
      *) wt_path="$1"; shift ;;
    esac
  done

  if [ -z "$wt_path" ]; then
    error "Usage: ./worktree.sh remove [--force] <path>"
    exit 1
  fi

  # Resolve to absolute path
  wt_path=$(cd "$wt_path" 2>/dev/null && pwd) || {
    error "Path does not exist: $1"
    exit 1
  }

  # Validate it's a git worktree
  if ! git worktree list --porcelain | grep -q "^worktree ${wt_path}$"; then
    error "'${wt_path}' is not a git worktree."
    exit 1
  fi

  # Derive worktree name and branch
  local wt_dir_name
  wt_dir_name=$(basename "$wt_path")
  local wt_name
  wt_name=$(echo "$wt_dir_name" | sed 's/[^a-zA-Z0-9-]/_/g' | tr '[:upper:]' '[:lower:]')

  local branch_name=""
  if [ -f "${wt_path}/.devcontainer/.env" ]; then
    branch_name=$(grep '^BRANCH_NAME=' "${wt_path}/.devcontainer/.env" 2>/dev/null | cut -d= -f2) || true
  fi

  local container_name="app-${PROJECT_NAME}-${wt_name}"

  # Run cleanup hook
  run_on_remove_hook "$wt_name" "$PROJECT_NAME" "$branch_name"

  # Stop and remove the container
  if docker inspect "$container_name" > /dev/null 2>&1; then
    info "Removing container ${BOLD}${container_name}${NC}..."
    docker rm -f "$container_name" 2>/dev/null || true
  fi

  # Remove the worktree
  info "Removing worktree at ${BOLD}${wt_path}${NC}..."
  if [ "$force" = true ]; then
    git worktree remove --force "$wt_path"
  else
    git worktree remove "$wt_path"
  fi

  success "Worktree removed: ${wt_path}"

  # Clean up any other orphans
  echo
  cmd_prune
}

# --- Subcommand: list ---

cmd_list() {
  echo
  printf "  ${BOLD}%-40s %-20s %-12s${NC}\n" "PATH" "BRANCH" "CONTAINER"
  printf "  %-40s %-20s %-12s\n" "----" "------" "---------"

  local wt_path="" wt_branch=""
  local porcelain
  porcelain=$(git worktree list --porcelain)

  while IFS= read -r line; do
    case "$line" in
      "worktree "*)
        wt_path="${line#worktree }"
        wt_branch=""
        ;;
      "branch "*)
        wt_branch="${line#branch refs/heads/}"
        ;;
      "")
        _print_worktree_row
        wt_path=""
        wt_branch=""
        ;;
    esac
  done <<< "$porcelain"

  # Handle last entry if output doesn't end with blank line
  _print_worktree_row

  echo
}

_print_worktree_row() {
  [ -z "${wt_path:-}" ] && return

  local wt_dir_name wt_name container_name status status_display
  wt_dir_name=$(basename "$wt_path")
  wt_name=$(echo "$wt_dir_name" | sed 's/[^a-zA-Z0-9-]/_/g' | tr '[:upper:]' '[:lower:]')
  container_name="app-${PROJECT_NAME}-${wt_name}"

  status=$(docker inspect -f '{{.State.Status}}' "$container_name" 2>/dev/null) || status="none"

  case "$status" in
    running)              status_display="${GREEN}running${NC}" ;;
    exited|created|paused) status_display="${YELLOW}${status}${NC}" ;;
    none)                 status_display="${DIM}none${NC}" ;;
    *)                    status_display="${DIM}${status}${NC}" ;;
  esac

  printf "  %-40s %-20s " "$wt_path" "${wt_branch:-(detached)}"
  echo -e "$status_display"
}

# --- Subcommand: prune ---

cmd_prune() {
  info "Checking for orphaned containers (project: ${PROJECT_NAME})..."

  local orphan_count=0
  local containers
  containers=$(docker ps -a --filter "label=devcontainer-wt.project=${PROJECT_NAME}" \
    --format '{{.Names}}\t{{.Label "devcontainer-wt.worktree-dir"}}\t{{.Label "devcontainer-wt.worktree"}}\t{{.Label "devcontainer-wt.branch"}}' 2>/dev/null) || true

  if [ -n "$containers" ]; then
    while IFS=$'\t' read -r container_name worktree_dir wt_name branch_name; do
      [ -z "$container_name" ] && continue
      if [ ! -d "$worktree_dir" ]; then
        orphan_count=$((orphan_count + 1))
        info "Orphaned container: ${BOLD}${container_name}${NC} (worktree dir: ${worktree_dir})"

        # Run cleanup hook
        run_on_remove_hook "${wt_name:-}" "${PROJECT_NAME}" "${branch_name:-}"

        # Remove the container
        info "Removing ${container_name}..."
        docker rm -f "$container_name" 2>/dev/null || true
        success "Removed orphaned container: ${container_name}"
      fi
    done <<< "$containers"
  fi

  # Also clean git's internal worktree metadata
  git worktree prune 2>/dev/null || true

  if [ "$orphan_count" -eq 0 ]; then
    success "No orphaned containers found."
  fi
}

# --- Usage ---

usage() {
  echo -e "${BOLD}devcontainer-wt CLI${NC} — worktree lifecycle management

${BOLD}Usage:${NC}
  ./worktree.sh add [branch]       Create a new worktree with a new branch
  ./worktree.sh remove [--force] <path>  Remove a worktree and its container
  ./worktree.sh list               List worktrees with container status
  ./worktree.sh prune              Clean up orphaned containers

${BOLD}Examples:${NC}
  ./worktree.sh add feature-login
  ./worktree.sh add                       # prompts for branch name
  ./worktree.sh remove ../myapp-feature-login
  ./worktree.sh remove --force ../myapp-feature-login
  ./worktree.sh list
  ./worktree.sh prune"
}

# --- Main ---

detect_project

case "${1:-}" in
  add)    shift; cmd_add "$@" ;;
  remove) shift; cmd_remove "$@" ;;
  list)   cmd_list ;;
  prune)  cmd_prune ;;
  -h|--help|help)
    usage ;;
  "")
    usage ;;
  *)
    error "Unknown command: $1"
    echo
    usage
    exit 1
    ;;
esac
