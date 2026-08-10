#!/usr/bin/env bash
# Offboarding: remove component from ReleasePlanAdmission (RPA) files in konflux-release-data.
# RHOAI only — exits with 2 (skipped) for ODH.
# Split from run_step_remove_from_krd.sh to avoid GitLab Validator test conflicts.
#
# Exit codes:
#   0  MR raised — prints MR_URL=<url>; writes pipeline_state.json
#   1  Unexpected failure — stderr has error; pipeline_state.json NOT written
#   2  Already removed or ODH (skipped) — writes pipeline_state.json (status=done/skipped)
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

[[ ! -f "$PIPELINE_STATE" ]] && {
  echo "ERROR: pipeline_state.json not found at $PIPELINE_STATE" >&2; exit 1
}

EXISTING_URL=$(jq -r '.steps.remove_krd_rpa.mr_url // ""' "$PIPELINE_STATE")
if [[ -n "$EXISTING_URL" ]]; then
  echo "MR already recorded in state: $EXISTING_URL"
  echo "MR_URL=$EXISTING_URL"
  exit 0
fi

YAML_FILE="$WORKDIR/component_offboarding_details.yaml"
[[ ! -f "$YAML_FILE" ]] && { echo "ERROR: $YAML_FILE not found" >&2; exit 1; }

eval "$(bash "$SCRIPTS_DIR/parse_offboarding_details.sh" \
  --workdir     "$WORKDIR" \
  --jira-id     "$JIRA_ID" \
  --scripts-dir "$SCRIPTS_DIR")"

if [[ "$PRODUCT_CONTEXT" != "RHOAI" ]]; then
  echo "RPA files are RHOAI-only — skipping for ${PRODUCT_CONTEXT}."
  bash "$SCRIPTS_DIR/update_pipeline_state.sh" \
    --state "$PIPELINE_STATE" --step remove_krd_rpa --status skipped
  exit 2
fi

[[ -z "$TARGET_RHOAI_VERSION" ]] && {
  echo "ERROR: target_rhoai_version required for RHOAI but missing from YAML." >&2; exit 1
}

eval "$(bash "$SCRIPTS_DIR/parse_rhoai_version.sh" --version "$TARGET_RHOAI_VERSION")"

KONFLUX_COMPONENT_NAME="${COMPONENT_NAME}-${VERSION_VAR}"

KRD_URL="${KONFLUX_RELEASE_DATA_REPO_URL:-https://gitlab.cee.redhat.com/releng/konflux-release-data.git}"
SPARSE_PATHS="config/stone-prod-p02.hjvn.p1/product/ReleasePlanAdmission/rhoai"

cd "$WORKDIR"
PLAYPEN_OUTPUT=$(GITLAB_SSL_VERIFY=false bash "$SCRIPTS_DIR/setup_gitlab_playpen.sh" \
  --src-url     "$KRD_URL" \
  --src-branch  main \
  --dest-branch "${JIRA_ID}-offboard-rpa" \
  --sparse-files "$SPARSE_PATHS") || {
  echo "ERROR: Playpen setup for konflux-release-data (RPA) failed. Check VPN and GITLAB_TOKEN." >&2; exit 1
}
CLONE_DIR=$(echo "$PLAYPEN_OUTPUT" | head -1)
DEST_BRANCH=$(echo "$PLAYPEN_OUTPUT" | tail -1)

CHANGES_MADE=false

# RPA stage file
RPA_STAGE="$CLONE_DIR/config/stone-prod-p02.hjvn.p1/product/ReleasePlanAdmission/rhoai/rhoai-onprem-${VERSION_VAR}-components-stage.yaml"
if [[ -f "$RPA_STAGE" ]] && grep -q "name: ${KONFLUX_COMPONENT_NAME}" "$RPA_STAGE" 2>/dev/null; then
  uv run --script "$SCRIPTS_DIR/edit_yaml.py" remove-rpa-component \
    "$RPA_STAGE" \
    --array-key "spec.data.mapping.components" \
    --name "${KONFLUX_COMPONENT_NAME}" || true
  CHANGES_MADE=true
fi

# RPA prod file
RPA_PROD="$CLONE_DIR/config/stone-prod-p02.hjvn.p1/product/ReleasePlanAdmission/rhoai/rhoai-onprem-${VERSION_VAR}-components-prod.yaml"
if [[ -f "$RPA_PROD" ]] && grep -q "name: ${KONFLUX_COMPONENT_NAME}" "$RPA_PROD" 2>/dev/null; then
  uv run --script "$SCRIPTS_DIR/edit_yaml.py" remove-rpa-component \
    "$RPA_PROD" \
    --array-key "spec.data.mapping.components" \
    --name "${KONFLUX_COMPONENT_NAME}" || true
  CHANGES_MADE=true
fi

if [[ "$CHANGES_MADE" == "false" ]]; then
  echo "Component '${KONFLUX_COMPONENT_NAME}' not found in RPA files — already removed."
  uv run --script "$SCRIPTS_DIR/update_jira_issue.py" "$JIRA_URL" \
    --add-label "offboard-krd-rpa-mr-merged" \
    --comment "Component '${KONFLUX_COMPONENT_NAME}' already absent from ReleasePlanAdmission files. No action needed." || true
  bash "$SCRIPTS_DIR/update_pipeline_state.sh" \
    --state "$PIPELINE_STATE" --step remove_krd_rpa --status done
  exit 2
fi

cd "$CLONE_DIR"
git add -A
git commit -m "Remove ${KONFLUX_COMPONENT_NAME} from ReleasePlanAdmission files"

git push origin "$DEST_BRANCH" || {
  git fetch --unshallow origin || { echo "ERROR: Push failed." >&2; exit 1; }
  git push origin "$DEST_BRANCH" || { echo "ERROR: Push failed after unshallow." >&2; exit 1; }
}

MR_URL=""
for attempt in 1 2 3; do
  MR_URL=$(GITLAB_SSL_VERIFY=false uv run --script "$SCRIPTS_DIR/raise_gitlab_mr.py" \
    --src-url     "$KRD_URL" \
    --src-branch  "$DEST_BRANCH" \
    --dest-url    "$KRD_URL" \
    --dest-branch main \
    --title       "Remove ${KONFLUX_COMPONENT_NAME} from ReleasePlanAdmission (offboarding)" \
    --description "Remove '${COMPONENT_NAME}' component mapping from stage and prod ReleasePlanAdmission files.

Product: RHOAI
Component: ${COMPONENT_NAME}
RPA version: ${VERSION_VAR}
Jira: ${JIRA_URL}" 2>/dev/null) && break
  [[ "$attempt" -eq 3 ]] && {
    echo "ERROR: Could not create MR after 3 attempts." >&2; exit 1
  }
  sleep 5
done

uv run --script "$SCRIPTS_DIR/update_jira_issue.py" "$JIRA_URL" \
  --add-label "offboard-krd-rpa-mr-raised" \
  --comment "[step:remove_krd_rpa] GitLab MR raised to remove '${KONFLUX_COMPONENT_NAME}' from ReleasePlanAdmission files.

MR URL: ${MR_URL}" || true

bash "$SCRIPTS_DIR/update_pipeline_state.sh" \
  --state "$PIPELINE_STATE" --step remove_krd_rpa \
  --status mr_raised --url "$MR_URL" --url-field mr_url

echo "MR_URL=${MR_URL}"
