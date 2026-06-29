#!/usr/bin/env bash
# Offboarding: remove component from Renovate config in rhoai-konflux-central.
#
# Exit codes:
#   0  PR raised — prints PR_URL=<url>; writes pipeline_state.json
#   1  Unexpected failure; pipeline_state.json NOT written
#   2  Component not found in Renovate config (already removed) — writes pipeline_state.json (status=done)
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

EXISTING_URL=$(jq -r '.steps.remove_renovate.pr_url // ""' "$PIPELINE_STATE")
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

REPO_NAME="${REPO_URL##*/}"; REPO_NAME="${REPO_NAME%.git}"

RKC_URL="${RHOAI_KONFLUX_CENTRAL_REPO_URL:-https://github.com/red-hat-data-services/konflux-central.git}"
RKC_PATH=$(echo "$RKC_URL" | sed 's|https://github.com/||;s|\.git$||')
SRC_BRANCH="main"

# Fast-path check: see if REPO_NAME appears in config.yaml before cloning
API_URL="https://api.github.com/repos/${RKC_PATH}/contents/config.yaml?ref=${SRC_BRANCH}"
CONFIG_CONTENT=$(curl -s \
  -H "Authorization: token $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github.v3.raw" \
  "$API_URL" 2>/dev/null || echo "")

if [[ -n "$CONFIG_CONTENT" ]] && ! echo "$CONFIG_CONTENT" | grep -qF "$REPO_NAME"; then
  echo "Repository '${REPO_NAME}' not found in Renovate config — already removed."
  uv run --script "$SCRIPTS_DIR/update_jira_issue.py" "$JIRA_URL" \
    --add-label "offboard-renovate-pr-merged" \
    --comment "Repository '${REPO_NAME}' already absent from Renovate config in rhoai-konflux-central. No action needed." || true
  bash "$SCRIPTS_DIR/update_pipeline_state.sh" \
    --state "$PIPELINE_STATE" --step remove_renovate --status done
  exit 2
fi

# Clone
cd "$WORKDIR"
PLAYPEN_OUTPUT=$(bash "$SCRIPTS_DIR/setup_github_playpen.sh" \
  --src-url     "$RKC_URL" \
  --src-branch  "$SRC_BRANCH" \
  --dest-branch "${JIRA_ID}-offboard-renovate" \
  --sparse-files "config.yaml") || {
  echo "ERROR: Playpen setup failed." >&2; exit 1
}
CLONE_DIR=$(echo "$PLAYPEN_OUTPUT" | head -1)
DEST_BRANCH=$(echo "$PLAYPEN_OUTPUT" | tail -1)

CONFIG_FILE="$CLONE_DIR/config.yaml"
[[ ! -f "$CONFIG_FILE" ]] && {
  echo "ERROR: config.yaml not found in clone." >&2; exit 1
}

# Remove renovate repo entry
RC=0
uv run --script "$SCRIPTS_DIR/edit_yaml.py" remove-renovate-repo \
  "$CONFIG_FILE" \
  --renovate-config "renovate/default-renovate-distribution.json" \
  --name "red-hat-data-services/${REPO_NAME}" || RC=$?

if [[ "$RC" -eq 2 ]]; then
  echo "Repository '${REPO_NAME}' not found in Renovate config — already removed."
  uv run --script "$SCRIPTS_DIR/update_jira_issue.py" "$JIRA_URL" \
    --add-label "offboard-renovate-pr-merged" \
    --comment "Repository '${REPO_NAME}' already absent from Renovate config in rhoai-konflux-central. No action needed." || true
  bash "$SCRIPTS_DIR/update_pipeline_state.sh" \
    --state "$PIPELINE_STATE" --step remove_renovate --status done
  exit 2
elif [[ "$RC" -ne 0 ]]; then
  echo "ERROR: edit_yaml.py remove-renovate-repo failed with exit code $RC." >&2; exit 1
fi

if is_dry_run; then
  cd "$CLONE_DIR"
  git add -A
  git commit -m "dry-run" --allow-empty 2>/dev/null || true
  dry_run_show_diff "$CLONE_DIR"
  dry_run_skip_pr "GitHub PR" "Remove ${REPO_NAME} from Renovate config (offboarding)" "main"
  bash "$SCRIPTS_DIR/update_pipeline_state.sh" \
    --state "$PIPELINE_STATE" --step remove_renovate --status dry_run
  exit 0
fi

bash "$SCRIPTS_DIR/git_commit_push.sh" \
  --clone-dir "$CLONE_DIR" \
  --files     "config.yaml" \
  --message   "Remove ${REPO_NAME} from Renovate config (offboarding)" \
  --branch    "$DEST_BRANCH"

PR_URL=""
for attempt in 1 2 3; do
  PR_URL=$(uv run --script "$SCRIPTS_DIR/raise_github_pr.py" \
    --src-url     "$RKC_URL" \
    --src-branch  "$DEST_BRANCH" \
    --dest-url    "$RKC_URL" \
    --dest-branch "$SRC_BRANCH" \
    --title       "Remove ${REPO_NAME} from Renovate config (offboarding)" \
    --description "Removes '${REPO_NAME}' from the Renovate distribution config in config.yaml.

Jira: ${JIRA_URL}" 2>/dev/null) && break
  [[ "$attempt" -eq 3 ]] && {
    echo "ERROR: Could not create PR after 3 attempts." >&2; exit 1
  }
  sleep 5
done

uv run --script "$SCRIPTS_DIR/update_jira_issue.py" "$JIRA_URL" \
  --add-label "offboard-renovate-pr-raised" \
  --comment "[step:remove_renovate] GitHub PR raised to remove '${REPO_NAME}' from Renovate config.

PR URL: ${PR_URL}" || true

bash "$SCRIPTS_DIR/update_pipeline_state.sh" \
  --state "$PIPELINE_STATE" --step remove_renovate \
  --status pr_raised --url "$PR_URL" --url-field pr_url

echo "PR_URL=${PR_URL}"
