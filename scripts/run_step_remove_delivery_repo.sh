#!/usr/bin/env bash
# Offboarding: remove component's delivery repository entry from pyxis-repo-configs (RHOAI only).
#
# Removes the component's repository block matching rhoai/${COMPONENT_NAME}-rhel9
# from products/rhoai/rhoai.yaml and raises a GitLab MR.
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

EXISTING_URL=$(jq -r '.steps.remove_delivery_repo.mr_url // ""' "$PIPELINE_STATE")
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

# Delivery repo entries use the rhoai repository name
DELIVERY_REPO_NAME="rhoai/${COMPONENT_NAME}-rhel9"

PYXIS_URL="${PYXIS_REPO_CONFIGS_REPO_URL:-https://gitlab.cee.redhat.com/releng/pyxis-repo-configs.git}"
PYXIS_PATH=$(echo "$PYXIS_URL" | sed 's|https://gitlab.cee.redhat.com/||;s|\.git$||')
PYXIS_PATH_ENCODED=$(echo "$PYXIS_PATH" | sed 's|/|%2F|g')

echo "COMPONENT_NAME    : $COMPONENT_NAME"
echo "DELIVERY_REPO_NAME: $DELIVERY_REPO_NAME"
echo "PYXIS_URL         : $PYXIS_URL"

# Fast-path: check if entry exists via GitLab API before cloning
RHOAI_YAML_TMPFILE=$(mktemp)
HTTP_STATUS=$(curl -sk -w "%{http_code}" \
  -H "Authorization: Bearer $GITLAB_TOKEN" \
  "https://gitlab.cee.redhat.com/api/v4/projects/${PYXIS_PATH_ENCODED}/repository/files/products%2Frhoai%2Frhoai.yaml/raw?ref=main" \
  -o "$RHOAI_YAML_TMPFILE" 2>/dev/null || echo "000")

ENTRY_EXISTS=false
if [[ "$HTTP_STATUS" == "200" ]]; then
  if grep -qF "$DELIVERY_REPO_NAME" "$RHOAI_YAML_TMPFILE"; then
    ENTRY_EXISTS=true
  fi
fi
rm -f "$RHOAI_YAML_TMPFILE"

if [[ "$ENTRY_EXISTS" == "false" ]]; then
  echo "Delivery repo entry for '${COMPONENT_NAME}' not found in pyxis-repo-configs — already removed."
  uv run --script "$SCRIPTS_DIR/update_jira_issue.py" "$JIRA_URL" \
    --add-label "offboard-delivery-repo-done" \
    --comment "Delivery repo entry for '${COMPONENT_NAME}' already absent from pyxis-repo-configs. No action needed." || true
  bash "$SCRIPTS_DIR/update_pipeline_state.sh" \
    --state "$PIPELINE_STATE" --step remove_delivery_repo --status done
  exit 2
fi

# Clone
cd "$WORKDIR"
PLAYPEN_OUTPUT=$(GITLAB_SSL_VERIFY=false bash "$SCRIPTS_DIR/setup_gitlab_playpen.sh" \
  --src-url  "$PYXIS_URL" \
  --dest-url "$PYXIS_URL" \
  --src-branch main \
  --dest-branch "${JIRA_ID}-offboard-delivery-repo" \
  --sparse-files "products/rhoai/rhoai.yaml") || {
  echo "ERROR: Playpen setup for pyxis-repo-configs failed. Check VPN." >&2; exit 1
}
CLONE_DIR=$(echo "$PLAYPEN_OUTPUT" | head -1)
DEST_BRANCH=$(echo "$PLAYPEN_OUTPUT" | tail -1)

RHOAI_YAML="$CLONE_DIR/products/rhoai/rhoai.yaml"
[[ ! -f "$RHOAI_YAML" ]] && {
  echo "ERROR: products/rhoai/rhoai.yaml not found." >&2; exit 1
}

# Remove entry
REMOVE_RESULT=$(uv run --script "$SCRIPTS_DIR/remove_delivery_repo_entry.py" \
  --yaml-file "$RHOAI_YAML" \
  --repository-name "$DELIVERY_REPO_NAME") || {
  echo "ERROR: Could not remove entry from products/rhoai/rhoai.yaml." >&2; exit 1
}

if [[ "$REMOVE_RESULT" == "not-found" ]]; then
  echo "Delivery repo entry for '${COMPONENT_NAME}' not found after clone — already removed."
  uv run --script "$SCRIPTS_DIR/update_jira_issue.py" "$JIRA_URL" \
    --add-label "offboard-delivery-repo-done" \
    --comment "Delivery repo entry for '${COMPONENT_NAME}' already absent from products/rhoai/rhoai.yaml. No action needed." || true
  bash "$SCRIPTS_DIR/update_pipeline_state.sh" \
    --state "$PIPELINE_STATE" --step remove_delivery_repo --status done
  exit 2
fi

if is_dry_run; then
  cd "$CLONE_DIR"
  git add -A
  git commit -m "dry-run" --allow-empty 2>/dev/null || true
  dry_run_show_diff "$CLONE_DIR"
  dry_run_skip_pr "GitLab MR" "Remove ${COMPONENT_NAME} delivery repo entry (offboarding)" "main"
  bash "$SCRIPTS_DIR/update_pipeline_state.sh" \
    --state "$PIPELINE_STATE" --step remove_delivery_repo --status dry_run
  exit 0
fi

bash "$SCRIPTS_DIR/git_commit_push.sh" \
  --clone-dir "$CLONE_DIR" \
  --files     "products/rhoai/rhoai.yaml" \
  --message   "Remove ${COMPONENT_NAME} delivery repo entry (offboarding)

Removes ${DELIVERY_REPO_NAME} repository block from
products/rhoai/rhoai.yaml.

Related: ${JIRA_ID}" \
  --branch "$DEST_BRANCH"

MR_URL=""
for attempt in 1 2 3; do
  MR_URL=$(GITLAB_SSL_VERIFY=false uv run --script "$SCRIPTS_DIR/raise_gitlab_mr.py" \
    --src-url     "$PYXIS_URL" \
    --src-branch  "$DEST_BRANCH" \
    --dest-url    "$PYXIS_URL" \
    --dest-branch main \
    --title       "Remove ${COMPONENT_NAME} delivery repo entry (offboarding)" \
    --description "Removes \`${DELIVERY_REPO_NAME}\` repository block from \`products/rhoai/rhoai.yaml\`.

Component: ${COMPONENT_NAME}
Jira: ${JIRA_URL}" 2>/dev/null) && break
  [[ "$attempt" -eq 3 ]] && {
    echo "ERROR: Could not create MR after 3 attempts." >&2; exit 1
  }
  sleep 5
done

uv run --script "$SCRIPTS_DIR/update_jira_issue.py" "$JIRA_URL" \
  --add-label "offboard-delivery-repo-mr-raised" \
  --comment "[step:remove_delivery_repo] GitLab MR raised to remove '${COMPONENT_NAME}' delivery repo entry.

MR URL: ${MR_URL}
Repository: ${DELIVERY_REPO_NAME}" || true

bash "$SCRIPTS_DIR/update_pipeline_state.sh" \
  --state "$PIPELINE_STATE" --step remove_delivery_repo \
  --status mr_raised --url "$MR_URL" --url-field mr_url

echo "MR_URL=${MR_URL}"
