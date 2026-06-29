#!/usr/bin/env bash
# Offboarding: remove component's Quay repo config from app-interface (RHOAI only).
#
# Removes entries for ${COMPONENT_NAME}-rhel9 and ${COMPONENT_NAME} from
# data/services/rhoai/quay/rhoai.yml and raises a GitLab MR.
#
# Exit codes:
#   0  MR raised — prints MR_URL=<url>; writes pipeline_state.json
#   1  Unexpected failure; pipeline_state.json NOT written
#   2  Entry not found (already removed) — writes pipeline_state.json (status=done)
set -euo pipefail

export PATH="${HOME}/.local/bin:${PATH}"
export GIT_SSL_NO_VERIFY=true

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

EXISTING_URL=$(jq -r '.steps.remove_quay.mr_url // ""' "$PIPELINE_STATE")
if [[ -n "$EXISTING_URL" ]]; then
  echo "MR already recorded in state: $EXISTING_URL"
  echo "MR_URL=$EXISTING_URL"
  exit 0
fi

YAML_FILE="$WORKDIR/component_offboarding_details.yaml"
[[ ! -f "$YAML_FILE" ]] && { echo "ERROR: $YAML_FILE not found" >&2; exit 1; }

COMPONENT_NAME=$(grep -m1 'component_name:' "$YAML_FILE" | awk '{print $2}')
[[ -z "$COMPONENT_NAME" ]] && {
  echo "ERROR: component_name missing from YAML." >&2; exit 1
}

APP_INTERFACE_URL="${APP_INTERFACE_REPO_URL:-https://gitlab.cee.redhat.com/service/app-interface.git}"
APP_INTERFACE_PATH=$(echo "$APP_INTERFACE_URL" | sed 's|https://gitlab.cee.redhat.com/||;s|\.git$||')
APP_INTERFACE_PATH_ENCODED=$(echo "$APP_INTERFACE_PATH" | sed 's|/|%2F|g')

TARGET_FILE="data/services/rhoai/quay/rhoai.yml"
TARGET_FILE_ENCODED=$(echo "$TARGET_FILE" | sed 's|/|%2F|g')

ENTRY_RHEL9="${COMPONENT_NAME}-rhel9"
ENTRY_PLAIN="${COMPONENT_NAME}"

echo "COMPONENT_NAME     : $COMPONENT_NAME"
echo "ENTRY_RHEL9        : $ENTRY_RHEL9"
echo "ENTRY_PLAIN        : $ENTRY_PLAIN"
echo "APP_INTERFACE_URL  : $APP_INTERFACE_URL"

# Fast-path: check if component name appears in the file before cloning
QUAY_YAML_TMPFILE=$(mktemp)
HTTP_STATUS=$(curl -sk -w "%{http_code}" \
  -H "Authorization: Bearer $GITLAB_TOKEN" \
  "https://gitlab.cee.redhat.com/api/v4/projects/${APP_INTERFACE_PATH_ENCODED}/repository/files/${TARGET_FILE_ENCODED}/raw?ref=master" \
  -o "$QUAY_YAML_TMPFILE" 2>/dev/null || echo "000")

FOUND_ANY=false
if [[ "$HTTP_STATUS" == "200" ]]; then
  if grep -qF "$COMPONENT_NAME" "$QUAY_YAML_TMPFILE"; then
    FOUND_ANY=true
  fi
fi
rm -f "$QUAY_YAML_TMPFILE"

if [[ "$FOUND_ANY" == "false" ]]; then
  echo "Quay repo config for '${COMPONENT_NAME}' not found in app-interface — already removed."
  uv run --script "$SCRIPTS_DIR/update_jira_issue.py" "$JIRA_URL" \
    --add-label "offboard-quay-done" \
    --comment "Quay repo config for '${COMPONENT_NAME}' already absent from app-interface. No action needed." || true
  bash "$SCRIPTS_DIR/update_pipeline_state.sh" \
    --state "$PIPELINE_STATE" --step remove_quay --status done
  exit 2
fi

# Clone
cd "$WORKDIR"
PLAYPEN_OUTPUT=$(GITLAB_SSL_VERIFY=false bash "$SCRIPTS_DIR/setup_gitlab_playpen.sh" \
  --src-url  "$APP_INTERFACE_URL" \
  --dest-url "$APP_INTERFACE_URL" \
  --src-branch master \
  --dest-branch "${JIRA_ID}-offboard-quay" \
  --sparse-files "$TARGET_FILE") || {
  echo "ERROR: Playpen setup for app-interface failed. Check VPN." >&2; exit 1
}
CLONE_DIR=$(echo "$PLAYPEN_OUTPUT" | head -1)
DEST_BRANCH=$(echo "$PLAYPEN_OUTPUT" | tail -1)

QUAY_YAML="$CLONE_DIR/$TARGET_FILE"
[[ ! -f "$QUAY_YAML" ]] && {
  echo "ERROR: $TARGET_FILE not found in clone." >&2; exit 1
}

# Remove entries — exit code 2 means not found, which is fine
CHANGES_MADE=false

if uv run --script "$SCRIPTS_DIR/edit_yaml.py" remove-items-array-entry \
  "$QUAY_YAML" --name "$ENTRY_RHEL9"; then
  CHANGES_MADE=true
else
  RC=$?
  [[ "$RC" -ne 2 ]] && { echo "ERROR: Failed to remove $ENTRY_RHEL9." >&2; exit 1; }
  echo "Entry '$ENTRY_RHEL9' not found — skipping."
fi

if uv run --script "$SCRIPTS_DIR/edit_yaml.py" remove-items-array-entry \
  "$QUAY_YAML" --name "$ENTRY_PLAIN"; then
  CHANGES_MADE=true
else
  RC=$?
  [[ "$RC" -ne 2 ]] && { echo "ERROR: Failed to remove $ENTRY_PLAIN." >&2; exit 1; }
  echo "Entry '$ENTRY_PLAIN' not found — skipping."
fi

if [[ "$CHANGES_MADE" == "false" ]]; then
  echo "Neither '${ENTRY_RHEL9}' nor '${ENTRY_PLAIN}' found in $TARGET_FILE — already removed."
  uv run --script "$SCRIPTS_DIR/update_jira_issue.py" "$JIRA_URL" \
    --add-label "offboard-quay-done" \
    --comment "Quay repo config entries for '${COMPONENT_NAME}' already absent from app-interface. No action needed." || true
  bash "$SCRIPTS_DIR/update_pipeline_state.sh" \
    --state "$PIPELINE_STATE" --step remove_quay --status done
  exit 2
fi

if is_dry_run; then
  cd "$CLONE_DIR"
  git add -A
  git commit -m "dry-run" --allow-empty 2>/dev/null || true
  dry_run_show_diff "$CLONE_DIR"
  dry_run_skip_pr "GitLab MR" "Remove ${COMPONENT_NAME} Quay repo config (offboarding)" "master"
  bash "$SCRIPTS_DIR/update_pipeline_state.sh" \
    --state "$PIPELINE_STATE" --step remove_quay --status dry_run
  exit 0
fi

bash "$SCRIPTS_DIR/git_commit_push.sh" \
  --clone-dir "$CLONE_DIR" \
  --files     "$TARGET_FILE" \
  --message   "Remove ${COMPONENT_NAME} Quay repo config (offboarding)

Removes Quay repo entries for ${COMPONENT_NAME} from
${TARGET_FILE}.

Related: ${JIRA_ID}" \
  --branch "$DEST_BRANCH"

MR_URL=""
for attempt in 1 2 3; do
  MR_URL=$(GITLAB_SSL_VERIFY=false uv run --script "$SCRIPTS_DIR/raise_gitlab_mr.py" \
    --src-url     "$APP_INTERFACE_URL" \
    --src-branch  "$DEST_BRANCH" \
    --dest-url    "$APP_INTERFACE_URL" \
    --dest-branch master \
    --title       "Remove ${COMPONENT_NAME} Quay repo config (offboarding)" \
    --description "Removes Quay repo config entries for \`${COMPONENT_NAME}\` from \`${TARGET_FILE}\`.

Component: ${COMPONENT_NAME}
Jira: ${JIRA_URL}" 2>/dev/null) && break
  [[ "$attempt" -eq 3 ]] && {
    echo "ERROR: Could not create MR after 3 attempts." >&2; exit 1
  }
  sleep 5
done

uv run --script "$SCRIPTS_DIR/update_jira_issue.py" "$JIRA_URL" \
  --add-label "offboard-quay-mr-raised" \
  --comment "[step:remove_quay] GitLab MR raised to remove '${COMPONENT_NAME}' Quay repo config from app-interface.

MR URL: ${MR_URL}" || true

bash "$SCRIPTS_DIR/update_pipeline_state.sh" \
  --state "$PIPELINE_STATE" --step remove_quay \
  --status mr_raised --url "$MR_URL" --url-field mr_url

echo "MR_URL=${MR_URL}"
