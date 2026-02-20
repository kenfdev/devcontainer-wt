#!/bin/bash
set -euo pipefail

# =============================================================================
# CUSTOMIZE — Cleanup hook for worktree removal
#
# This script runs on the HOST before a worktree's container is removed.
# It is called by `./worktree.sh remove` and `./worktree.sh prune`.
#
# Available environment variables:
#   WORKTREE_NAME   — sanitized worktree directory name (e.g., myapp-feature-x)
#   PROJECT_NAME    — project name (e.g., myapp)
#   BRANCH_NAME     — sanitized branch name (e.g., feature-x), may be empty for orphans
#
# Add project-specific cleanup below (e.g., dropping databases, clearing caches).
# If this script has no active commands, cleanup proceeds silently.
# =============================================================================

# Examples (uncomment and adapt for your project):

# Drop per-worktree PostgreSQL database
# docker exec "postgres-${PROJECT_NAME}" dropdb -U dev --if-exists "${PROJECT_NAME}_${WORKTREE_NAME}" 2>/dev/null || true

# Drop per-worktree MySQL database
# docker exec "mysql-${PROJECT_NAME}" mysql -u dev -pdev -e "DROP DATABASE IF EXISTS \`${PROJECT_NAME}_${WORKTREE_NAME}\`" 2>/dev/null || true

# Clear per-worktree Redis keys
# docker exec "redis-${PROJECT_NAME}" redis-cli --scan --pattern "${PROJECT_NAME}:${WORKTREE_NAME}:*" | \
#   xargs -r docker exec -i "redis-${PROJECT_NAME}" redis-cli DEL 2>/dev/null || true
