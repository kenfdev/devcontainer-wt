#!/bin/bash
set -euo pipefail

# =============================================================================
# Worktree creation hook — runs on the HOST after a new worktree is created.
# Copies gitignored files listed in .worktreeinclude to the new worktree.
#
# Wire this into your worktree tool:
#   git-wt: git config --add wt.hook ".worktree/hooks/on-create.sh"
#   manual: cd ../myapp-feature-x && .worktree/hooks/on-create.sh
# =============================================================================

# --- Resolve main worktree ---

gitdir="$(git rev-parse --git-common-dir)"
case $gitdir in
  /*) ;;
  *) gitdir="$PWD/$gitdir"
esac
GIT_COMMON_DIR=$(cd "$gitdir" && pwd)
MAIN_REPO_DIR=$(dirname "$GIT_COMMON_DIR")

# --- Copy .worktreeinclude files ---

copy_from_include_file() {
  local include_file="$1" target_root="$2"
  [[ -f "$include_file" ]] || return 0

  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    (
      cd "$MAIN_REPO_DIR"
      shopt -s dotglob nullglob
      shopt -s globstar 2>/dev/null || true
      for f in $line; do
        [[ -f "$f" ]] || continue
        mkdir -p "${target_root}/$(dirname "$f")"
        cp "$f" "${target_root}/${f}"
        echo "[devcontainer-wt] Copied: ${f}"
      done
    )
  done < "$include_file"
}

copy_from_include_file "${MAIN_REPO_DIR}/.worktreeinclude" "$PWD"
copy_from_include_file "${MAIN_REPO_DIR}/.worktreeinclude.local" "$PWD"

echo "[devcontainer-wt] on-create complete."
