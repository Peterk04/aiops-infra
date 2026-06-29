#!/usr/bin/env bash
# Shared dry-run helpers for offboarding wrapper scripts.
# Source this file after setting CLONE_DIR.
#
# Usage in wrapper scripts:
#   source "$SCRIPTS_DIR/dry_run_helpers.sh"
#
# Then replace the push/PR/Jira block with:
#   if is_dry_run; then
#     dry_run_show_diff "$CLONE_DIR"
#     dry_run_skip_pr "GitHub PR" "Remove foo (offboarding)" "$TARGET_BRANCH"
#     bash "$SCRIPTS_DIR/update_pipeline_state.sh" \
#       --state "$PIPELINE_STATE" --step "$STEP_KEY" --status dry_run
#     exit 0
#   fi

is_dry_run() {
  [[ "${DRY_RUN:-false}" == "true" ]]
}

dry_run_show_diff() {
  local clone_dir="$1"
  echo ""
  echo "═══════════════════════════════════════════════════════"
  echo "  DRY RUN — changes that WOULD be committed:"
  echo "═══════════════════════════════════════════════════════"
  cd "$clone_dir"
  git diff HEAD~1 --stat 2>/dev/null || git diff --cached --stat 2>/dev/null || true
  echo "───────────────────────────────────────────────────────"
  git diff HEAD~1 2>/dev/null || git diff --cached 2>/dev/null || true
  echo "═══════════════════════════════════════════════════════"
  echo ""
}

dry_run_skip_pr() {
  local pr_type="$1"   # "GitHub PR" or "GitLab MR"
  local title="$2"
  local target_branch="$3"
  echo "[DRY RUN] WOULD raise ${pr_type}:"
  echo "  Title  : ${title}"
  echo "  Target : ${target_branch}"
  echo "[DRY RUN] WOULD update Jira labels and post comment."
  echo "[DRY RUN] Skipping push, PR/MR creation, and Jira updates."
}
