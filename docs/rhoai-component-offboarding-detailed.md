# RHOAI Component Offboarding — Detailed Blueprint

This document is the inverse of the onboarding pipeline implemented by the
`onboard-konflux-components-for-odh-and-rhoai` skill. Each step describes
exactly what was created during onboarding and what must be removed to
offboard a component from a specific RHOAI version.

---

## Prerequisites

### Credentials

| Variable | Scope | Required for |
|----------|-------|-------------|
| `GITHUB_USER` / `GITHUB_TOKEN` (repo scope) | GitHub | Steps 1–4, 6, 10, 11 |
| `GITLAB_USER` / `GITLAB_TOKEN` (api + write_repository) | GitLab | Steps 5, 7, 8, 9 |

### Tools

`git`, `jq`, `yamllint`, `kustomize` (or `kubectl`), `gh` CLI

### VPN

Red Hat VPN must be active for Steps 5, 7, 8, 9 (all GitLab on `gitlab.cee.redhat.com`).

---

## Inputs

| Field | Description | Example | How to find it |
|-------|-------------|---------|----------------|
| `component_name` | The Konflux component name(s) being offboarded | `odh-llm-d-inference-scheduler` | Onboarding Jira → `component_onboarding_details.yaml` → `inputs.component_name` |
| `repo_name` | The GitHub repo name used in `pipelineruns/` directory | `llm-d-inference-scheduler` | Onboarding Jira → `inputs.repo_url` → last path segment |
| `repo_url` | Full GitHub URL of the component source repo | `https://github.com/red-hat-data-services/llm-d-inference-scheduler` | Onboarding Jira → `inputs.repo_url` |
| `target_rhoai_version` | The version being offboarded from | `3.5-ea-2` | Onboarding Jira → `inputs.target_rhoai_version` |
| `is_operator` | Whether the component has operator manifest integration | `true` / `false` | Onboarding Jira → `inputs.is_operator` |
| `dockerfile_path` | Path to the Dockerfile in the source repo | `Dockerfile.konflux` | Onboarding Jira → `inputs.dockerfile_path` |
| `context_path` | Build context path | `./` | Onboarding Jira → `inputs.context_path` |
| `component_exists_in_older_versions` | Whether older released versions still use this component | `true` / `false` | Check RPA files in konflux-release-data for older version references |
| `replacement_component` | Name of the replacement component (if any) | `odh-llm-d-router-endpoint-picker` | For PR/MR descriptions |

### Derived Variables

These are computed from `target_rhoai_version` by the onboarding script
`scripts/parse_rhoai_version.sh`. You need them to locate the correct files.

| Input | `VERSION_VAR` | `BRANCH_NAME` | `VERSION_NAME` (PDS dir) | `RPA_VAR` (RPA filenames) |
|-------|--------------|---------------|--------------------------|--------------------------|
| `3.5-ea-2` | `v3-5-ea-2` | `rhoai-3.5-ea.2` | `v3.5-ea.2` | `v3-5-ea-2` |
| `3.5-ea-1` | `v3-5-ea-1` | `rhoai-3.5-ea.1` | `v3.5-ea.1` | `v3-5-ea-1` |
| `3.4` | `v3-4` | `rhoai-3.4` | `v3.4` | `v3-4` |

Derivation rules:
- `VERSION_VAR`: replace `.` with `-`, prepend `v` → `3.5-ea-2` becomes `v3-5-ea-2`
- `BRANCH_NAME`: replace last `-` in EA suffix with `.`, prepend `rhoai-` → `rhoai-3.5-ea.2`
- `VERSION_NAME`: replace last `-` in EA suffix with `.`, prepend `v` → `v3.5-ea.2`
- `RPA_VAR`: same as `VERSION_VAR`

---

## Repository Reference

| Short name | Full URL | Type | Onboarding skill that created artifacts |
|-----------|----------|------|----------------------------------------|
| rhods-operator | `https://github.com/red-hat-data-services/rhods-operator` | GitHub | `integrate-component-with-odh-operator` |
| RHOAI-Build-Config | `https://github.com/red-hat-data-services/RHOAI-Build-Config` | GitHub | `integrate-component-with-bundle` |
| konflux-central | `https://github.com/red-hat-data-services/konflux-central` | GitHub | `add-component-to-rhoai-konflux-central`, `create-pull-pipelines-in-rhoai-konflux-central`, `enable-renovate-on-rhoai-component-repo` |
| konflux-release-data | `https://gitlab.cee.redhat.com/releng/konflux-release-data` | GitLab | `onboard-component-to-konflux-release-data` |
| rhods-devops-infra | `https://github.com/red-hat-data-services/rhods-devops-infra` | GitHub | `setup-auto-merge` |
| pyxis-repo-configs | `https://gitlab.cee.redhat.com/releng/pyxis-repo-configs` | GitLab | `create-rhoai-delivery-repo`, `update-rhoai-product-listing` |
| app-interface | `https://gitlab.cee.redhat.com/service/app-interface` | GitLab | `create-quay-repo` |
| Component source repo | `https://github.com/red-hat-data-services/<repo_name>` | GitHub | `add-rhoai-dockerfile-labels` |

---

## Pre-flight: Discovery

Before raising any PRs/MRs, run a grep across all repos to build the full
inventory of what needs removing. This catches entries you might not expect
(e.g. entries on multiple version branches, entries in workflows).

```bash
COMPONENT="odh-llm-d-inference-scheduler"
REPO_NAME="llm-d-inference-scheduler"

# GitHub repos — search all relevant branches
for repo in red-hat-data-services/rhods-operator \
            red-hat-data-services/RHOAI-Build-Config \
            red-hat-data-services/konflux-central \
            red-hat-data-services/rhods-devops-infra; do
  echo "=== $repo ==="
  gh search code "$COMPONENT" --repo "$repo" --json path,textMatches \
    --jq '.[] | "\(.path)"' 2>/dev/null | sort -u
done

# GitLab repos — search via API (VPN required)
for project in releng%2Fkonflux-release-data releng%2Fpyxis-repo-configs service%2Fapp-interface; do
  echo "=== $project ==="
  curl -s -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    "https://gitlab.cee.redhat.com/api/v4/projects/${project}/search?scope=blobs&search=${COMPONENT}&per_page=20" \
    | jq -r '.[].path' | sort -u
done
```

---

## Step 1: rhods-operator

**Repo:** `https://github.com/red-hat-data-services/rhods-operator`
**Branch:** `BRANCH_NAME` (e.g. `rhoai-3.5-ea.2`)
**Created by:** `integrate-component-with-odh-operator` skill

### What to remove

#### 1a. `build/manifests-config.yaml` — if `is_operator == true`

Remove the component's block from the `map:` section. The block looks like:

```yaml
map:
  <component_name>:
    src: <operator_manifest_src_path>
    dest: <operator_manifest_dest_path>
```

**Skip if `is_operator == false`** — the onboarding skill would have skipped this
file entirely, so there's nothing to remove.

#### 1b. `build/operator-nudging.yaml` — always check

Remove the component's image entry. The entry looks like:

```yaml
- name: RELATED_IMAGE_<COMPONENT_NAME_UPPER>_IMAGE
  value: quay.io/rhoai/<component_name>-rhel9@sha256:<digest>
```

Where `COMPONENT_NAME_UPPER` is the component name with hyphens replaced by
underscores, uppercased (e.g. `odh-llm-d-inference-scheduler` →
`ODH_LLM_D_INFERENCE_SCHEDULER`).

#### 1c. Other `build/` files — check manually

Grep `build/` for the component name. Other files like `params.env` may exist
depending on the operator's build setup.

```bash
gh api "repos/red-hat-data-services/rhods-operator/git/trees/${BRANCH_NAME}?recursive=1" \
  --jq '.tree[].path' | grep '^build/' | while read f; do
  result=$(gh api "repos/red-hat-data-services/rhods-operator/contents/$f?ref=${BRANCH_NAME}" \
    -H "Accept: application/vnd.github.raw+json" 2>/dev/null | grep "$COMPONENT")
  [[ -n "$result" ]] && echo "$f: $result"
done
```

---

## Step 2: RHOAI-Build-Config

**Repo:** `https://github.com/red-hat-data-services/RHOAI-Build-Config`
**Branch:** `BRANCH_NAME` (e.g. `rhoai-3.5-ea.2`)
**Created by:** `integrate-component-with-bundle` skill

### What to remove

#### 2a. `bundle/bundle-patch.yaml`

Remove the `relatedImages` entry for the component. The entry looks like:

```yaml
- name: RELATED_IMAGE_<COMPONENT_NAME_UPPER>_IMAGE
  value: quay.io/rhoai/<component_name>-rhel9@sha256:<digest>
```

The `name` field uses the same uppercased/underscored convention as
`operator-nudging.yaml`.

#### 2b. `config/build-config.yaml`

Remove the `repo_mappings` entry. The entry looks like:

```yaml
rhoai/<component_name>-rhel9: rhoai/<component_name>-rhel9
```

Under `config.replacements[0].repo_mappings`.

#### 2c. `bundle/Dockerfile` — check for ARG/label lines

The onboarding skill (`integrate-component-with-bundle`) may have added
ARG lines and LABEL lines for git URL / git commit tracking. Grep for the
component name and remove any matching lines.

---

## Step 3: konflux-central — push pipelines (version branch)

**Repo:** `https://github.com/red-hat-data-services/konflux-central`
**Branch:** `BRANCH_NAME` (e.g. `rhoai-3.5-ea.2`)
**Created by:** `add-component-to-rhoai-konflux-central` skill

### What to remove

Delete the push PipelineRun YAML(s) under:

```
pipelineruns/<repo_name>/.tekton/<component_name>-<VERSION_VAR>-push.yaml
```

Example:
```
pipelineruns/llm-d-inference-scheduler/.tekton/odh-llm-d-inference-scheduler-v3-5-ea-2-push.yaml
```

If multiple components shared the same `repo_name` directory (e.g. both
`odh-llm-d-inference-scheduler` and `odh-llm-d-routing-sidecar` were under
`pipelineruns/llm-d-inference-scheduler/`), remove all of them.

If the `pipelineruns/<repo_name>/` directory is empty after deletion on this
branch, delete the directory too.

---

## Step 4: konflux-central — pull pipelines + sync workflow (main branch)

**Repo:** `https://github.com/red-hat-data-services/konflux-central`
**Branch:** `main`
**Created by:** `create-pull-pipelines-in-rhoai-konflux-central` skill

### What to remove

#### 4a. Pull-request PipelineRun YAML(s)

Delete under:

```
pipelineruns/<repo_name>/.tekton/<component_name>-pull-request.yaml
```

Example:
```
pipelineruns/llm-d-inference-scheduler/.tekton/odh-llm-d-inference-scheduler-pull-request.yaml
```

If the `pipelineruns/<repo_name>/` directory is empty after deletion, delete
the directory too.

#### 4b. `.github/workflows/sync-pipelineruns.yml`

Remove `<repo_name>` from the `repositories:` options list. The entry looks like:

```yaml
          - <repo_name>
```

> **Note:** Steps 3 and 4 are **separate PRs** because they target different branches.

---

## Step 5: konflux-release-data (GitLab, VPN required)

**Repo:** `https://gitlab.cee.redhat.com/releng/konflux-release-data`
**Branch:** `main`
**Created by:** `onboard-component-to-konflux-release-data` skill

### What to remove — 4 locations

#### 5a. ProjectDevelopmentStream

**File:** `tenants-config/cluster/stone-prod-p02/tenants/rhoai-tenant/<VERSION_NAME>/ProjectDevelopmentStream-<VERSION_NAME>.yaml`

Example path: `.../v3.5-ea.2/ProjectDevelopmentStream-v3.5-ea.2.yaml`

Remove the Component resource block. It looks like:

```yaml
  - apiVersion: appstudio.redhat.com/v1alpha1
    kind: Component
    metadata:
      annotations:
        build.appstudio.openshift.io/pipeline: '{"name":"docker-build-multi-platform-oci-ta","bundle":"latest"}'
        build.appstudio.openshift.io/request: configure-pac-no-mr
      name: <component_name>-{{.versionName}}
    spec:
      application: rhoai-{{.versionName}}
      build-nudges-ref:
        - odh-operator-{{.versionName}}
      componentName: <component_name>-{{.versionName}}
      containerImage: quay.io/rhoai/<component_name>-rhel9
      source:
        git:
          context: <context_path>
          dockerfileUrl: <dockerfile_path>
          revision: "{{.branch}}"
          url: <repo_url>
```

> `{{.versionName}}` and `{{.branch}}` are Go template variables — they appear
> literally in the file.

#### 5b. ReleasePlanAdmission — prod

**File:** `config/stone-prod-p02.hjvn.p1/product/ReleasePlanAdmission/rhoai/rhoai-onprem-<RPA_VAR>-components-prod.yaml`

Example path: `.../rhoai-onprem-v3-5-ea-2-components-prod.yaml`

Remove the component entry from `spec.data.mapping.components`:

```yaml
        - name: <component_name>-<RPA_VAR>
          repositories:
            - url: registry.redhat.io/rhoai/<component_name>-rhel9
```

#### 5c. ReleasePlanAdmission — stage

**File:** Same path as 5b but with `-stage.yaml` suffix.

Same structure, but with `registry.stage.redhat.io`:

```yaml
        - name: <component_name>-<RPA_VAR>
          repositories:
            - url: registry.stage.redhat.io/rhoai/<component_name>-rhel9
```

#### 5d. Pull-request Component — automation/resources.yaml

**File:** `tenants-config/cluster/stone-prod-p02/tenants/rhoai-tenant/automation/resources.yaml`

Remove the Component resource block:

```yaml
---
apiVersion: appstudio.redhat.com/v1alpha1
kind: Component
metadata:
  annotations:
    build.appstudio.openshift.io/request: configure-pac-no-mr
    build.appstudio.openshift.io/pipeline: '{"name":"docker-build-multi-platform-oci-ta","bundle":"latest"}'
  name: pull-request-pipelines-<component_name>
spec:
  application: automation
  componentName: pull-request-pipelines-<component_name>
  containerImage: quay.io/rhoai/pull-request-pipelines
  source:
    git:
      context: <context_path>
      dockerfileUrl: <dockerfile_path>
      url: <repo_url>
```

#### 5e. Run `build-manifests.sh`

After making all edits, run `build-manifests.sh` from the repo root. This
regenerates the `tenants-config/auto-generated/` directory. The auto-generated
Component YAML files for the removed components will be deleted automatically:

```
tenants-config/auto-generated/cluster/stone-prod-p02/tenants/rhoai-tenant/
  appstudio.redhat.com_v1alpha1_component_<component_name>-<VERSION_NAME>.yaml
  appstudio.redhat.com_v1alpha1_component_pull-request-pipelines-<component_name>.yaml
```

Validate with `yamllint` before committing.

---

## Step 6: rhods-devops-infra — auto-merge

**Repo:** `https://github.com/red-hat-data-services/rhods-devops-infra`
**Branch:** `main`
**Created by:** `setup-auto-merge` skill

### What to remove — up to 4 files

Check each file for entries referencing the component. Not all files will
have entries — the onboarding may have only added to a subset.

#### 6a. `src/config/upstream-source-map.yaml`

Entry looks like:

```yaml
- name: <repo_name>
  automerge: 'yes'
  src:
    url: <upstream_repo_url>.git
    branch: main
  dest:
    url: <repo_url>.git
    branch: main
```

#### 6b. `src/config/main-release-source-map.yaml`

Entry looks like:

```yaml
- name: <repo_name>
  automerge: 'yes'
  repo-url: <repo_url>.git
```

#### 6c. `.github/workflows/upstream-auto-merge.yaml`

Entry in the `repositories:` input options list:

```yaml
          - <repo_name>
```

#### 6d. `.github/workflows/main-release-auto-merge.yaml`

Same format as 6c.

> **Careful:** Entries may reference version-specific suffixes (e.g.
> `llm-d-inference-scheduler-2.x`). Only remove entries relevant to the
> version being offboarded. Entries for other versions that are still active
> must stay.

---

## Step 7: pyxis-repo-configs — product listing (GitLab, VPN required)

**Repo:** `https://gitlab.cee.redhat.com/releng/pyxis-repo-configs`
**Branch:** `main`
**Created by:** `update-rhoai-product-listing` skill

### What to remove

**File:** `product-listings/rhoai/rhoai.yaml`

Remove the line from the `repositories:` array:

```yaml
  - registry.access.redhat.com/rhoai/<component_name>-rhel9
```

### Condition: `component_exists_in_older_versions`

**If `true` → SKIP this step entirely.**

The product listing is shared across all versions. Older released versions
still publish to `registry.access.redhat.com` under this component name.
Removing the listing would prevent those older images from being discoverable
in the Red Hat catalog. The listing has no effect on whether new builds are
produced — it only controls registry metadata.

**If `false`** → safe to remove. No older version references this component.

---

## Step 8: pyxis-repo-configs — delivery repo (GitLab, VPN required)

**Repo:** `https://gitlab.cee.redhat.com/releng/pyxis-repo-configs`
**Branch:** `main`
**Created by:** `create-rhoai-delivery-repo` skill

### What to remove

**File:** `products/rhoai/rhoai.yaml`

Remove the repository block:

```yaml
- repository: rhoai/<component_name>-rhel9
  content_stream_tags:
    - <CONTENT_STREAM_TAG>
  component_name: <component_name>
  display_name: <display_name>
  short_description: <short_description>
  long_description: <long_description>
  release_category: <release_category>
```

### Condition: `component_exists_in_older_versions`

**If `true` → SKIP this step entirely.**

The delivery repo is the pipeline through which images flow from Konflux to
the Red Hat registries. It is shared across versions. Removing it would
prevent older version builds from being delivered even if their Konflux
pipelines are still active.

**If `false`** → safe to remove.

---

## Step 9: app-interface — Quay repo (GitLab, VPN required)

**Repo:** `https://gitlab.cee.redhat.com/service/app-interface`
**Branch:** `master` (note: `master`, not `main`)
**Created by:** `create-quay-repo` skill

### What to remove

**File:** `data/services/rhoai/quay/rhoai.yml`

There may be **two entries** — one with `-rhel9` suffix and one without:

```yaml
- name: <component_name>-rhel9
  description: '<description>'
  public: true

- name: <component_name>
  description: '<description>'
  public: true
```

Remove both if present.

### Condition: `component_exists_in_older_versions`

**If `true` → SKIP this step entirely.**

Quay repos store the built images. Older version pipelines still push to
`quay.io/rhoai/<component_name>-rhel9`. Removing the Quay repo config
would break those builds.

**If `false`** → safe to remove.

---

## Step 10: Component source repos (optional)

**Repo:** `https://github.com/red-hat-data-services/<repo_name>`
**Branch:** `main` (or default branch)
**Created by:** `add-rhoai-dockerfile-labels` skill (Dockerfile labels)

### What to remove

#### 10a. Archive the repo — if no longer used by any version

```bash
gh repo edit red-hat-data-services/<repo_name> --archived
```

#### 10b. Clean up `.tekton/` PipelineRun YAMLs

The component source repo may contain PipelineRun YAMLs that Konflux
Pipelines-as-Code (PAC) watches. These will cause errors if the Konflux
Component resources have been deleted. Remove any YAMLs referencing the
offboarded component from `.tekton/`.

> **If the repo is shared with a replacement component** (same repo, different
> Dockerfile — e.g. `llm-d-router` builds both `odh-llm-d-router-endpoint-picker`
> and `odh-llm-d-router-disagg-sidecar`), leave the repo active and only
> remove `.tekton/` YAMLs for the old component.

#### 10c. Remove Dockerfile labels — if the repo stays active

The onboarding skill `add-rhoai-dockerfile-labels` added 7 mandatory RHOAI
labels after the last `FROM` in the Dockerfile. If the Dockerfile is no
longer used for RHOAI builds, these can be removed:

```dockerfile
LABEL name="rhoai/<component_name>-rhel9"
LABEL com.redhat.component="<component_name>-rhel9"
LABEL summary="<component_name>"
LABEL description="<component_name>"
LABEL maintainer="<component_name>"
LABEL io.k8s.display-name="<component_name>"
LABEL io.k8s.description="<component_name>"
```

---

## Step 11: renovate config

**Repo:** `https://github.com/red-hat-data-services/konflux-central`
**Branch:** `main`
**Created by:** `enable-renovate-on-rhoai-component-repo` skill + `sync-rhoai-renovate-configs` skill

### What to remove

#### 11a. `config.yaml`

Remove the repo entry from the `sync-repositories` array (first distribution
group):

```yaml
  - name: "red-hat-data-services/<repo_name>"
```

#### 11b. Trigger `sync-renovate-configs` workflow

After the PR removing the config entry merges, dispatch the
`sync-renovate-configs` workflow to propagate the change:

```bash
gh workflow run sync-renovate-configs.yml \
  --repo red-hat-data-services/konflux-central \
  --ref main \
  -f dry_run=false \
  -f renovate-config=all
```

This pushes updated renovate config to all component repos and removes
the `.renovaterc` from repos no longer in the list.

### Condition: `component_exists_in_older_versions`

**If `true` and the same repo serves older versions → SKIP.**
Renovate may still be needed for dependency updates on older branches.

**If `false`** → safe to remove.

---

## Dependency Order

```
Phase 1 (parallel, no dependencies):
  ├─ Step 1:  rhods-operator (version branch)
  ├─ Step 2:  RHOAI-Build-Config (version branch)
  ├─ Step 6:  rhods-devops-infra (if applicable)
  └─ Step 11: renovate config (if applicable)

Phase 2 (after Steps 1+2 merge):
  ├─ Step 3: konflux-central push pipelines (version branch)
  └─ Step 4: konflux-central pull pipelines + workflow (main)

Phase 3 (after Steps 3+4 merge):
  └─ Step 5: konflux-release-data (GitLab, VPN)

Phase 4 (after Step 5 merges, only if component_exists_in_older_versions == false):
  ├─ Step 7:  pyxis-repo-configs product listing (GitLab, VPN)
  ├─ Step 8:  pyxis-repo-configs delivery repo (GitLab, VPN)
  └─ Step 9:  app-interface Quay repo (GitLab, VPN)

Phase 5 (after all above):
  └─ Step 10: archive source repos (if applicable)
```

### Why this order matters

The order is the **reverse of onboarding** — downstream consumers are removed
first so nothing references the component by the time its build infrastructure
is torn down.

- **Steps 1–2 first:** The operator and bundle reference the component's
  container image. If Konflux pipelines are removed first, the operator build
  would fail trying to nudge a non-existent component.
- **Steps 3–4 after 1–2:** Once nothing references the built images, the
  pipelines that produce those images can be safely removed.
- **Step 5 after 3–4:** The Konflux Component resources and release
  configurations are the "source of truth" for the build system. Remove
  them last so there's no window where Konflux tries to build a component
  whose pipeline YAMLs have been deleted.
- **Steps 7–9 are version-independent:** These resources (Quay repos,
  delivery repos, product listings) are shared across all versions. They
  can only be removed after confirming no older version still uses the
  component.

---

## PR/MR Summary Table

| # | Repo | Branch | Files touched | VPN |
|---|------|--------|---------------|-----|
| 1 | rhods-operator | `rhoai-<BRANCH_VAR>` | `build/manifests-config.yaml` (if is_operator), `build/operator-nudging.yaml` | No |
| 2 | RHOAI-Build-Config | `rhoai-<BRANCH_VAR>` | `bundle/bundle-patch.yaml`, `config/build-config.yaml`, `bundle/Dockerfile` | No |
| 3 | konflux-central | `rhoai-<BRANCH_VAR>` | `pipelineruns/<repo_name>/.tekton/*-push.yaml` | No |
| 4 | konflux-central | `main` | `pipelineruns/<repo_name>/`, `.github/workflows/sync-pipelineruns.yml` | No |
| 5 | konflux-release-data | `main` | PDS, RPA prod, RPA stage, `automation/resources.yaml`, auto-generated | Yes |
| 6 | rhods-devops-infra | `main` | Up to 4 config/workflow files | No |
| 7 | pyxis-repo-configs | `main` | `product-listings/rhoai/rhoai.yaml` | Yes |
| 8 | pyxis-repo-configs | `main` | `products/rhoai/rhoai.yaml` | Yes |
| 9 | app-interface | `master` | `data/services/rhoai/quay/rhoai.yml` | Yes |
| 10 | Component source repo | `main` | `.tekton/`, Dockerfile labels | No |
| 11 | konflux-central | `main` | `config.yaml` + trigger workflow | No |

Steps 7–9 are **skipped when `component_exists_in_older_versions == true`**.
Steps 4 and 11 can be combined into a single PR if both target `main` on
`konflux-central`.

---

## Verification

After all PRs/MRs merge, re-run the pre-flight discovery grep (see top of
document) to confirm zero matches remain. Pay special attention to:

| What to check | Why it's easy to miss |
|---------------|---------------------|
| `build/operator-nudging.yaml` | Not part of the standard `is_operator` conditional — it always exists |
| `.github/workflows/sync-pipelineruns.yml` | Workflow file, not under `pipelineruns/` |
| `ProjectDevelopmentStream` in krd | Separate from the RPA files, different directory structure |
| Auto-generated files in krd | Should be deleted by `build-manifests.sh` — verify they're gone |
| `.tekton/` in component source repo | PAC will try to run pipelines for deleted Konflux Components |
| Multiple version branches | Push YAMLs may exist on older version branches (e.g. `rhoai-3.5-ea.1` AND `rhoai-3.5-ea.2`) |
| Both `-rhel9` and non-rhel9 Quay entries | `app-interface` may have two entries per component |
| `bundle/Dockerfile` ARG/label lines | Not in `bundle-patch.yaml` or `build-config.yaml` — separate file |

---

## Worked Example: Offboarding `odh-llm-d-inference-scheduler` from 3.5-ea-2

**Inputs:**
- `component_name`: `odh-llm-d-inference-scheduler`
- `repo_name`: `llm-d-inference-scheduler`
- `repo_url`: `https://github.com/red-hat-data-services/llm-d-inference-scheduler`
- `target_rhoai_version`: `3.5-ea-2`
- `is_operator`: `false`
- `component_exists_in_older_versions`: `true`
- `replacement_component`: `odh-llm-d-router-endpoint-picker`

**Derived:**
- `VERSION_VAR`: `v3-5-ea-2`
- `BRANCH_NAME`: `rhoai-3.5-ea.2`
- `VERSION_NAME`: `v3.5-ea.2`
- `RPA_VAR`: `v3-5-ea-2`

**PRs/MRs raised:**

| # | Repo | Branch | Action |
|---|------|--------|--------|
| 1 | rhods-operator | `rhoai-3.5-ea.2` | Removed entries from `build/operator-nudging.yaml` (skipped `manifests-config.yaml` — `is_operator=false`) |
| 2 | RHOAI-Build-Config | `rhoai-3.5-ea.2` | Removed `RELATED_IMAGE_ODH_LLM_D_INFERENCE_SCHEDULER_IMAGE` from `bundle/bundle-patch.yaml`, mapping from `config/build-config.yaml` |
| 3 | konflux-central | `rhoai-3.5-ea.2` | Deleted `pipelineruns/llm-d-inference-scheduler/.tekton/odh-llm-d-inference-scheduler-v3-5-ea-2-push.yaml` |
| 4 | konflux-central | `main` | Deleted `pipelineruns/llm-d-inference-scheduler/` directory, removed from `sync-pipelineruns.yml` |
| 5 | konflux-release-data | `main` | Removed from PDS `v3.5-ea.2`, both RPAs, `automation/resources.yaml`, ran `build-manifests.sh` |
| — | pyxis-repo-configs | — | **Skipped** — `component_exists_in_older_versions=true` |
| — | app-interface | — | **Skipped** — `component_exists_in_older_versions=true` |
| — | rhods-devops-infra | — | **Skipped** — auto-merge entries were for `2.x` version, not `3.5-ea-2` |
