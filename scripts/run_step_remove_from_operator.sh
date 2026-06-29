#!/usr/bin/env bash
# Offboarding: remove component from operator manifests config.
#
# Exit 2 immediately when is_operator=false (no-op).
# Otherwise removes the entry from build/manifests-config.yaml and raises a PR.
#
# Exit codes:
#   0  PR raised — prints PR_URL=<url>; writes pipeline_state.json
#   1  Unexpected failure; pipeline_state.json NOT written
#   2  is_operator=false (skipped) OR entry not found (already removed);
#      writes pipeline_state.json (status=done or skipped)
set -euo pipefail

export PATH="${HOME}/.local/bin:${PATH}"

JIRA_URL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --jira-url) JIRA_URL="$2"; shift 2 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$JIRA_URL" ]] && { echo "ERROR: --jira-url is required" >&2; exit 1; }

JIRA_ID="${JIRA_URL%/}"; JIRA_ID="${JIRA_ID##*/}"
WORKDIR="${WORKDIR:-$(pwd)/${JIRA_ID}}"
PIPELINE_STATE="${PIPELINE_STATE:-${WORKDIR}/pipeline_state.json}"
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPTS_DIR/dry_run_helpers.sh"

[[ ! -f "$PIPELINE_STATE" ]] && {
  echo "ERROR: pipeline_state.json not found at $PIPELINE_STATE" >&2; exit 1
}

EXISTING_URL=$(jq -r '.steps.remove_operator.pr_url // ""' "$PIPELINE_STATE")
if [[ -n "$EXISTING_URL" ]]; then
  echo "PR already recorded in state: $EXISTING_URL"
  echo "PR_URL=$EXISTING_URL"
  exit 0
fi

YAML_FILE="$WORKDIR/component_offboarding_details.yaml"
[[ ! -f "$YAML_FILE" ]] && { echo "ERROR: $YAML_FILE not found" >&2; exit 1; }

eval "$(bash "$SCRIPTS_DIR/parse_offboarding_details.sh" \
  --workdir     "$WORKDIR" \
  --jira-id     "$JIRA_ID" \
  --scripts-dir "$SCRIPTS_DIR")"

REPO_BRANCH=$(grep -m1 'repo_branch:' "$YAML_FILE" | awk '{print $2}' 2>/dev/null || echo "main")

if [[ "$IS_OPERATOR" != "true" ]]; then
  echo "is_operator=false — skipping operator manifest removal."
  uv run --script "$SCRIPTS_DIR/update_jira_issue.py" "$JIRA_URL" \
    --add-label "offboard-operator-not-needed" \
    --comment "Skipping operator manifest removal for '$COMPONENT_NAME' (is_operator=false)." || true
  bash "$SCRIPTS_DIR/update_pipeline_state.sh" \
    --state "$PIPELINE_STATE" --step remove_operator --status skipped
  exit 2
fi

eval "$(bash "$SCRIPTS_DIR/resolve_operator_url.sh" \
  --product-context "$PRODUCT_CONTEXT")"
echo "ODH_OPERATOR_URL  : $ODH_OPERATOR_URL"

if [[ "$PRODUCT_CONTEXT" == "RHOAI" && -n "$REPO_BRANCH" ]]; then
  OPERATOR_TARGET_BRANCH="$REPO_BRANCH"
else
  OPERATOR_TARGET_BRANCH="main"
fi

cd "$WORKDIR"
PLAYPEN_OUTPUT=$(bash "$SCRIPTS_DIR/setup_github_playpen.sh" \
  --src-url     "$ODH_OPERATOR_URL" \
  --src-branch  "$OPERATOR_TARGET_BRANCH" \
  --dest-branch "${JIRA_ID}-offboard" \
  --sparse-files "build/manifests-config.yaml build/operator-nudging.yaml") || {
  echo "ERROR: Playpen setup for operator repo failed." >&2; exit 1
}
CLONE_DIR=$(echo "$PLAYPEN_OUTPUT" | head -1)
DEST_BRANCH=$(echo "$PLAYPEN_OUTPUT" | tail -1)

MANIFESTS_CONFIG="$CLONE_DIR/build/manifests-config.yaml"
OPERATOR_NUDGING="$CLONE_DIR/build/operator-nudging.yaml"

# Check if component appears in either file
FOUND_IN_MANIFESTS=false
FOUND_IN_NUDGING=false
[[ -f "$MANIFESTS_CONFIG" ]] && grep -qF "$COMPONENT_NAME" "$MANIFESTS_CONFIG" 2>/dev/null && FOUND_IN_MANIFESTS=true
[[ -f "$OPERATOR_NUDGING" ]] && grep -qF "$COMPONENT_NAME" "$OPERATOR_NUDGING" 2>/dev/null && FOUND_IN_NUDGING=true

if [[ "$FOUND_IN_MANIFESTS" == "false" && "$FOUND_IN_NUDGING" == "false" ]]; then
  echo "Entry '${COMPONENT_NAME}' not found in manifests-config.yaml or operator-nudging.yaml — already removed."
  uv run --script "$SCRIPTS_DIR/update_jira_issue.py" "$JIRA_URL" \
    --add-label "offboard-operator-pr-merged" \
    --comment "Operator entries for '${COMPONENT_NAME}' already absent. No action needed." || true
  bash "$SCRIPTS_DIR/update_pipeline_state.sh" \
    --state "$PIPELINE_STATE" --step remove_operator --status done
  exit 2
fi

FILES_CHANGED=""

# Remove from manifests-config.yaml (operator manifest mapping)
if [[ "$FOUND_IN_MANIFESTS" == "true" ]]; then
  uv run --script "$SCRIPTS_DIR/edit_yaml.py" remove-map-key \
    "$MANIFESTS_CONFIG" \
    --map-key "map" \
    --name "$COMPONENT_NAME" || true
  FILES_CHANGED="build/manifests-config.yaml"
fi

# Remove from operator-nudging.yaml (RELATED_IMAGE entry)
# The entry name uses uppercased component name with hyphens as underscores
if [[ "$FOUND_IN_NUDGING" == "true" ]]; then
  COMPONENT_UPPER=$(echo "$COMPONENT_NAME" | tr '[:lower:]-' '[:upper:]_')
  RELATED_IMAGE_NAME="RELATED_IMAGE_${COMPONENT_UPPER}_IMAGE"
  uv run --script "$SCRIPTS_DIR/edit_yaml.py" remove-array-entry \
    "$OPERATOR_NUDGING" \
    --array-key "relatedImages" \
    --name "$RELATED_IMAGE_NAME" || true
  FILES_CHANGED="$FILES_CHANGED build/operator-nudging.yaml"
fi

if is_dry_run; then
  cd "$CLONE_DIR"
  git add -A
  git commit -m "dry-run" --allow-empty 2>/dev/null || true
  dry_run_show_diff "$CLONE_DIR"
  dry_run_skip_pr "GitHub PR" "Remove ${COMPONENT_NAME} from operator build config (offboarding)" "$OPERATOR_TARGET_BRANCH"
  bash "$SCRIPTS_DIR/update_pipeline_state.sh" \
    --state "$PIPELINE_STATE" --step remove_operator --status dry_run
  exit 0
fi

bash "$SCRIPTS_DIR/git_commit_push.sh" \
  --clone-dir "$CLONE_DIR" \
  --files     "$FILES_CHANGED" \
  --message   "Remove ${COMPONENT_NAME} from operator build config (offboarding)" \
  --branch    "$DEST_BRANCH"

PR_URL=""
for attempt in 1 2 3; do
  PR_URL=$(uv run --script "$SCRIPTS_DIR/raise_github_pr.py" \
    --src-url     "$ODH_OPERATOR_URL" \
    --src-branch  "$DEST_BRANCH" \
    --dest-url    "$ODH_OPERATOR_URL" \
    --dest-branch "$OPERATOR_TARGET_BRANCH" \
    --title       "Remove ${COMPONENT_NAME} from operator build config (offboarding)" \
    --description "Removes '${COMPONENT_NAME}' entries from build/manifests-config.yaml and build/operator-nudging.yaml.

Jira: ${JIRA_URL}" 2>/dev/null) && break
  [[ "$attempt" -eq 3 ]] && {
    echo "ERROR: Could not create PR after 3 attempts." >&2; exit 1
  }
  sleep 5
done

uv run --script "$SCRIPTS_DIR/update_jira_issue.py" "$JIRA_URL" \
  --add-label "offboard-operator-pr-raised" \
  --comment "[step:remove_operator] GitHub PR raised to remove '${COMPONENT_NAME}' from operator manifests.

PR URL: ${PR_URL}" || true

bash "$SCRIPTS_DIR/update_pipeline_state.sh" \
  --state "$PIPELINE_STATE" --step remove_operator \
  --status pr_raised --url "$PR_URL" --url-field pr_url

echo "PR_URL=${PR_URL}"
