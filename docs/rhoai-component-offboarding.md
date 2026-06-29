# RHOAI Component Offboarding — Step-by-Step Template

## Inputs

| Field | Description | Example |
|-------|-------------|---------|
| `component_name` | The Konflux component name(s) being offboarded | `odh-llm-d-inference-scheduler`, `odh-llm-d-routing-sidecar` |
| `repo_name` | The GitHub repo directory name used in `pipelineruns/` | `llm-d-inference-scheduler` |
| `target_rhoai_version` | The version branch being offboarded from | `3.5-ea-2` |
| `is_operator` | Whether the component has operator manifest integration | `true` / `false` |
| `component_exists_in_older_versions` | Whether older released versions still use this component | `true` / `false` |
| `replacement_component` | Name of the replacement (if any) — for PR descriptions | `odh-llm-d-router-endpoint-picker` |

## Step 1: rhods-operator (version branch)

**Branch:** `rhoai-<VERSION>` (e.g. `rhoai-3.5-ea.2`)

**If `is_operator == true`:**
- Remove component block(s) from `build/manifests-config.yaml`

**Always:**
- Remove component image entries from `build/operator-nudging.yaml`

> **Note:** Also check for `params.env` or any other files under `build/` that reference the component.

**Skip if:** Component has no entries in either file on this branch.

## Step 2: RHOAI-Build-Config (version branch)

**Branch:** `rhoai-<VERSION>` (e.g. `rhoai-3.5-ea.2`)

- Remove `RELATED_IMAGE_*` entries from `bundle/bundle-patch.yaml`
- Remove `repo_mappings` entries from `config/build-config.yaml`
- Remove any ARG/label lines from `bundle/Dockerfile` if present

## Step 3: konflux-central — push pipelines (version branch)

**Branch:** `rhoai-<VERSION>` (e.g. `rhoai-3.5-ea.2`)

- Delete push PipelineRun YAML(s) from `pipelineruns/<repo_name>/.tekton/`
  - Pattern: `<component_name>-<VERSION_VAR>-push.yaml`
- If the directory is now empty on this branch, delete the entire `pipelineruns/<repo_name>/` directory

## Step 4: konflux-central — pull pipelines + workflow (main branch)

**Branch:** `main`

- Delete pull-request PipelineRun YAML(s) from `pipelineruns/<repo_name>/.tekton/`
  - Pattern: `<component_name>-pull-request.yaml`
- Delete the `pipelineruns/<repo_name>/` directory if now empty
- Remove `<repo_name>` from `.github/workflows/sync-pipelineruns.yml` repository list

> **Note:** Steps 3 and 4 are separate PRs (different branches).

## Step 5: konflux-release-data (GitLab, VPN required)

**Branch:** `main`

Remove entries from **4 locations**:

1. **ProjectDevelopmentStream** — `tenants-config/cluster/stone-prod-p02/tenants/rhoai-tenant/v<VERSION>/ProjectDevelopmentStream-v<VERSION>.yaml`
   - Remove the Component resource block(s) for the old component(s)

2. **ReleasePlanAdmission (prod)** — `config/stone-prod-p02.hjvn.p1/product/ReleasePlanAdmission/rhoai/rhoai-onprem-v<VERSION_VAR>-components-prod.yaml`
   - Remove component entries from `spec.data.mapping.components`

3. **ReleasePlanAdmission (stage)** — same path with `-stage.yaml`
   - Remove component entries from `spec.data.mapping.components`

4. **Pull-request Components** — `tenants-config/cluster/stone-prod-p02/tenants/rhoai-tenant/automation/resources.yaml`
   - Remove `pull-request-pipelines-<component_name>` Component resource(s)

**Then run `build-manifests.sh`** — this regenerates the `auto-generated/` directory and removes the corresponding auto-generated Component YAML files.

Validate with `yamllint` before committing.

## Step 6: rhods-devops-infra — auto-merge (main branch)

**Branch:** `main`

Check and remove entries from up to 4 files:
- `src/config/upstream-source-map.yaml`
- `src/config/main-release-source-map.yaml`
- `.github/workflows/upstream-auto-merge.yaml`
- `.github/workflows/main-release-auto-merge.yaml`

> **Careful:** Entries may reference version-specific suffixes (e.g. `llm-d-inference-scheduler-2.x`). Only remove entries relevant to the version being offboarded. Entries for other versions that are still active must stay.

## Step 7: pyxis-repo-configs — product listing (GitLab, VPN required)

**If `component_exists_in_older_versions == false`:**
- Remove line from `product-listings/rhoai/rhoai.yaml`
  - Pattern: `registry.access.redhat.com/rhoai/<component_name>-rhel9`

**If `component_exists_in_older_versions == true`:**
- **Skip.** Older released versions still publish to the Red Hat registry under this name. Removing the product listing would break those releases.

## Step 8: pyxis-repo-configs — delivery repo (GitLab, VPN required)

**If `component_exists_in_older_versions == false`:**
- Remove repository entry from `products/rhoai/rhoai.yaml`

**If `component_exists_in_older_versions == true`:**
- **Skip.** The delivery repo is shared across versions. Removing it would break image delivery for older releases.

## Step 9: app-interface — Quay repo (GitLab, VPN required)

**If `component_exists_in_older_versions == false`:**
- Remove entries from `data/services/rhoai/quay/rhoai.yml`
  - May have both `<component_name>-rhel9` and non-rhel9 variants

**If `component_exists_in_older_versions == true`:**
- **Skip.** Quay repos are shared across versions. Older builds still push images here.

## Step 10: Component source repos (optional)

**If the component repo is no longer used by any version:**
- Archive `red-hat-data-services/<repo_name>` on GitHub
- Clean up any `.tekton/` PipelineRun YAMLs referencing the old component

**If the repo is shared with the replacement component (same repo, different Dockerfile):**
- Leave the repo active
- Only clean up `.tekton/` YAMLs for the old component if they exist

## Step 11: renovate config (main branch)

**If the component had renovate enabled:**
- Remove repo from `config.yaml` `sync-repositories` array in `red-hat-data-services/konflux-central`
- Trigger `sync-renovate-configs` workflow to push the updated config to component repos

**If `component_exists_in_older_versions == true` and the same repo serves older versions:**
- **Skip.** Renovate may still be needed for the repo.

## Dependency Order

```
Phase 1 (parallel, no dependencies):
  ├─ Step 1: rhods-operator (version branch)
  ├─ Step 2: RHOAI-Build-Config (version branch)
  ├─ Step 6: rhods-devops-infra (if applicable)
  └─ Step 11: renovate config (if applicable)

Phase 2 (after Steps 1+2 merge):
  ├─ Step 3: konflux-central push pipelines (version branch)
  └─ Step 4: konflux-central pull pipelines + workflow (main)

Phase 3 (after Steps 3+4 merge):
  └─ Step 5: konflux-release-data (GitLab)

Phase 4 (after Step 5 merges, only if component_exists_in_older_versions == false):
  ├─ Step 7: pyxis-repo-configs product listing
  ├─ Step 8: pyxis-repo-configs delivery repo
  └─ Step 9: app-interface Quay repo

Phase 5 (after all above):
  └─ Step 10: archive source repos (if applicable)
```

## Verification

After all PRs/MRs merge, grep each repo for the old component name(s) on the relevant branches to confirm nothing was missed. Key things to check:
- `build/operator-nudging.yaml` (easy to forget)
- `sync-pipelineruns.yml` workflow (easy to forget)
- `ProjectDevelopmentStream` in krd (easy to forget — separate from RPAs)
- Auto-generated files in krd (should be cleaned by `build-manifests.sh` but verify)
