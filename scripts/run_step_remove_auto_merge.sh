#!/usr/bin/env bash
# Offboarding: remove component from rhods-devops-infra auto-merge config.
#
# Removes REPO_NAME from up to 4 files:
#   src/config/upstream-source-map.yaml    (top-level YAML list, entry by name)
#   src/config/main-release-source-map.yaml (top-level YAML list, entry by name)
#   .github/workflows/upstream-auto-merge.yaml   (workflow matrix list)
#   .github/workflows/main-release-auto-merge.yaml (workflow matrix list)
#
# Exit codes:
#   0  PR raised — prints PR_URL=<url>; writes pipeline_state.json
#   1  Unexpected failure; pipeline_state.json NOT written
#   2  Component not found in auto-merge config (already removed) — writes pipeline_state.json (status=done)
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

EXISTING_URL=$(jq -r '.steps.remove_auto_merge.pr_url // ""' "$PIPELINE_STATE")
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

RHODS_DEVOPS_INFRA_REPO_URL="${RHODS_DEVOPS_INFRA_REPO_URL:-https://github.com/red-hat-data-services/rhods-devops-infra.git}"
RHODS_DEVOPS_PATH=$(echo "$RHODS_DEVOPS_INFRA_REPO_URL" | sed 's|https://github.com/||;s|\.git$||')

# Fast-path: check if REPO_NAME appears in upstream-source-map.yaml via GitHub API
API_URL="https://api.github.com/repos/${RHODS_DEVOPS_PATH}/contents/src/config/upstream-source-map.yaml?ref=main"
API_RESPONSE=$(curl -s \
  -H "Authorization: token $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github.v3.raw" \
  "$API_URL" 2>/dev/null || echo "")

if [[ -n "$API_RESPONSE" ]] && ! echo "$API_RESPONSE" | grep -qF "$REPO_NAME"; then
  echo "Repo '${REPO_NAME}' not found in upstream-source-map.yaml — already removed."
  uv run --script "$SCRIPTS_DIR/update_jira_issue.py" "$JIRA_URL" \
    --add-label "offboard-auto-merge-pr-merged" \
    --comment "Repo '${REPO_NAME}' already absent from rhods-devops-infra auto-merge config. No action needed." || true
  bash "$SCRIPTS_DIR/update_pipeline_state.sh" \
    --state "$PIPELINE_STATE" --step remove_auto_merge --status done
  exit 2
fi

# Clone with sparse checkout
cd "$WORKDIR"
PLAYPEN_OUTPUT=$(bash "$SCRIPTS_DIR/setup_github_playpen.sh" \
  --src-url     "$RHODS_DEVOPS_INFRA_REPO_URL" \
  --src-branch  "main" \
  --dest-branch "${JIRA_ID}-offboard-auto-merge" \
  --sparse-files "src/config .github/workflows") || {
  echo "ERROR: Playpen setup for rhods-devops-infra failed." >&2; exit 1
}
CLONE_DIR=$(echo "$PLAYPEN_OUTPUT" | head -1)
DEST_BRANCH=$(echo "$PLAYPEN_OUTPUT" | tail -1)

CHANGES_MADE=false
FILES_CHANGED=""

# ── 1. Remove from src/config/upstream-source-map.yaml ────────────────────────
UPSTREAM_MAP="$CLONE_DIR/src/config/upstream-source-map.yaml"
if [[ -f "$UPSTREAM_MAP" ]] && grep -q "^- name: ${REPO_NAME}$" "$UPSTREAM_MAP" 2>/dev/null; then
  python3 -c "
from ruamel.yaml import YAML
from pathlib import Path
yaml = YAML()
yaml.preserve_quotes = True
yaml.width = 4096
p = Path('$UPSTREAM_MAP')
data = yaml.load(p)
data = [e for e in data if not (isinstance(e, dict) and e.get('name') == '$REPO_NAME')]
yaml.dump(data, p)
"
  CHANGES_MADE=true
  FILES_CHANGED="src/config/upstream-source-map.yaml"
  echo "Removed '${REPO_NAME}' from upstream-source-map.yaml"
fi

# ── 2. Remove from src/config/main-release-source-map.yaml ───────────────────
MAIN_MAP="$CLONE_DIR/src/config/main-release-source-map.yaml"
if [[ -f "$MAIN_MAP" ]] && grep -q "^- name: ${REPO_NAME}$" "$MAIN_MAP" 2>/dev/null; then
  python3 -c "
from ruamel.yaml import YAML
from pathlib import Path
yaml = YAML()
yaml.preserve_quotes = True
yaml.width = 4096
p = Path('$MAIN_MAP')
data = yaml.load(p)
data = [e for e in data if not (isinstance(e, dict) and e.get('name') == '$REPO_NAME')]
yaml.dump(data, p)
"
  CHANGES_MADE=true
  FILES_CHANGED="${FILES_CHANGED:+$FILES_CHANGED }src/config/main-release-source-map.yaml"
  echo "Removed '${REPO_NAME}' from main-release-source-map.yaml"
fi

# ── 3. Remove from .github/workflows/upstream-auto-merge.yaml ────────────────
UPSTREAM_WF="$CLONE_DIR/.github/workflows/upstream-auto-merge.yaml"
if [[ -f "$UPSTREAM_WF" ]] && grep -q "^[[:space:]]*- ${REPO_NAME}$" "$UPSTREAM_WF" 2>/dev/null; then
  sed -i.bak "/^[[:space:]]*- ${REPO_NAME}$/d" "$UPSTREAM_WF" && rm -f "${UPSTREAM_WF}.bak"
  CHANGES_MADE=true
  FILES_CHANGED="${FILES_CHANGED:+$FILES_CHANGED }.github/workflows/upstream-auto-merge.yaml"
  echo "Removed '${REPO_NAME}' from upstream-auto-merge.yaml"
fi

# ── 4. Remove from .github/workflows/main-release-auto-merge.yaml ────────────
MAIN_WF="$CLONE_DIR/.github/workflows/main-release-auto-merge.yaml"
if [[ -f "$MAIN_WF" ]] && grep -q "^[[:space:]]*- ${REPO_NAME}$" "$MAIN_WF" 2>/dev/null; then
  sed -i.bak "/^[[:space:]]*- ${REPO_NAME}$/d" "$MAIN_WF" && rm -f "${MAIN_WF}.bak"
  CHANGES_MADE=true
  FILES_CHANGED="${FILES_CHANGED:+$FILES_CHANGED }.github/workflows/main-release-auto-merge.yaml"
  echo "Removed '${REPO_NAME}' from main-release-auto-merge.yaml"
fi

# ── No changes? Mark as done ─────────────────────────────────────────────────
if [[ "$CHANGES_MADE" == "false" ]]; then
  echo "Repo '${REPO_NAME}' not found in any auto-merge config files — already removed."
  uv run --script "$SCRIPTS_DIR/update_jira_issue.py" "$JIRA_URL" \
    --add-label "offboard-auto-merge-pr-merged" \
    --comment "Repo '${REPO_NAME}' already absent from rhods-devops-infra auto-merge config. No action needed." || true
  bash "$SCRIPTS_DIR/update_pipeline_state.sh" \
    --state "$PIPELINE_STATE" --step remove_auto_merge --status done
  exit 2
fi

# ── Commit & push ─────────────────────────────────────────────────────────────
if is_dry_run; then
  cd "$CLONE_DIR"
  git add -A
  git commit -m "dry-run" --allow-empty 2>/dev/null || true
  dry_run_show_diff "$CLONE_DIR"
  dry_run_skip_pr "GitHub PR" "Remove ${REPO_NAME} from auto-merge config (offboarding)" "main"
  bash "$SCRIPTS_DIR/update_pipeline_state.sh" \
    --state "$PIPELINE_STATE" --step remove_auto_merge --status dry_run
  exit 0
fi

bash "$SCRIPTS_DIR/git_commit_push.sh" \
  --clone-dir "$CLONE_DIR" \
  --files     "$FILES_CHANGED" \
  --message   "Remove ${REPO_NAME} from auto-merge config (offboarding)" \
  --branch    "$DEST_BRANCH"

# ── Raise PR ──────────────────────────────────────────────────────────────────
PR_URL=""
for attempt in 1 2 3; do
  PR_URL=$(uv run --script "$SCRIPTS_DIR/raise_github_pr.py" \
    --src-url     "$RHODS_DEVOPS_INFRA_REPO_URL" \
    --src-branch  "$DEST_BRANCH" \
    --dest-url    "$RHODS_DEVOPS_INFRA_REPO_URL" \
    --dest-branch "main" \
    --title       "Remove ${REPO_NAME} from auto-merge config (offboarding)" \
    --description "Removes '${REPO_NAME}' from auto-merge configuration files in rhods-devops-infra.

Files modified: ${FILES_CHANGED}

Jira: ${JIRA_URL}" 2>/dev/null) && break
  [[ "$attempt" -eq 3 ]] && {
    echo "ERROR: Could not create PR after 3 attempts." >&2; exit 1
  }
  sleep 5
done

# ── Update Jira ───────────────────────────────────────────────────────────────
uv run --script "$SCRIPTS_DIR/update_jira_issue.py" "$JIRA_URL" \
  --add-label "offboard-auto-merge-pr-raised" \
  --comment "[step:remove_auto_merge] GitHub PR raised to remove '${REPO_NAME}' from auto-merge config.

PR URL: ${PR_URL}" || true

# ── Update pipeline state ────────────────────────────────────────────────────
bash "$SCRIPTS_DIR/update_pipeline_state.sh" \
  --state "$PIPELINE_STATE" --step remove_auto_merge \
  --status pr_raised --url "$PR_URL" --url-field pr_url

echo "PR_URL=${PR_URL}"
