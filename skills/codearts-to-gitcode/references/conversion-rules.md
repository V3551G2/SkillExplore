# CodeArts → GitCode Conversion Rules

This reference maps CodeArts pipeline/job constructs to GitCode Action YAML equivalents.

## Top-Level YAML Structure

### Naming conventions

**Entry workflow filename** — determined by pipeline type:
- PR pipelines (CodeArts pipeline name starts with `PR-` or uses merge_request triggers) → `PR-pipeline_<option>.yml` (e.g. `PR-pipeline_full.yml`)
- Nightly/Version pipelines (name contains `Nightly` or `Version`) → `Nightly-Version_<option>.yml`

The CodeArts pipeline name (`pipeline.name` from the API) already follows this convention, so use its
prefix to determine the filename.

**Stage naming** — each stage key is `stage_<n>` (sequential), and the `name` field is a `&`-joined
combination of task categories present in that stage:
- `CodeCheck` — static analysis: Antipoison, SCA, CodeCheck, pre-commit, lint, SAST, md_check
- `Build` — compilation: Build_x86, Build_arm, etc.
- `Test` — testing/smoke: UT, test, PreSmoke, integration

Examples:
- Stage with SCA + pre-commit (only static checks) → `name: CodeCheck`
- Stage with pre-commit + Build_x86 + PreSmoke → `name: CodeCheck&Build&Test`
- Stage with only Build_arm → `name: Build`

### Entry Workflow: PR-pipeline_full.yml

```yaml
name: PR-pipeline_full

on:
  pull_request_target:
    branches:
      - <branch1>
      - <branch2>
      - master
    types: [open, update, reopen, merge]
  pull_request_comment:
    types: [created]
    branches: [ '*' ]
    comments: [ '^(?:\/)?compile*' ]
  workflow_dispatch:

inputs:
  repo:
    type: string
    default: ${{ atomgit.event.repository.name }}
  owner:
    type: string
    default: <owner_name>
  REMOTE_URL:
    type: string
    default: ${{ atomgit.repositoryurl }}
  pr_id:
    type: string
    default: ${{ atomgit.event.pull_request.number }}
  TARGET_BRANCH:
    type: string
    default: ${{ atomgit.event.pull_request.base.ref }}
  workspace:
    type: string
    default: ${{ env.ATOMGIT_WORKSPACE }}

env:
  BUILD_SKIP: "no"
  # Define SWR image names here for easy maintenance
  img_<name>_<arch>: "swr.<region>.myhuaweicloud.com/<org>/<image>:<tag>"

stages:
  stage_0:
    name: stage_0
    select: selected_by_default
    jobs:
      # ... preparatory jobs (md_check, test env, etc.)
  stage_1:
    name: stage_1
    select: selected_by_default
    jobs:
      # ... static check, build, UT jobs
```

### Reusable Sub-Workflow: .<job_type>.yml

```yaml
name: <Human Readable Name>

on:
  workflow_call:
    inputs:
      REMOTE_URL:
        required: false
        type: string
        default: ${{ atomgit.repositoryurl }}
      pr_id:
        required: false
        type: string
        default: ${{ atomgit.event.pull_request.number }}
      IMAGE_FLAG:
        required: true
        type: string
      TARGET_BRANCH:
        required: false
        type: string
        default: ${{ atomgit.event.pull_request.base.ref }}
      runs_on_arch:
        required: true
        type: string
    secrets:
      <SECRET_NAME>:
        required: true

jobs:
  JOB_<name>:
    name: JOB_<name>
    select: selected_by_default
    runs-on: [ dedicate-hosted, "${{ inputs.runs_on_arch }}", large ]
    container:
      image: swr.<region>.myhuaweicloud.com/<org>/${{ inputs.IMAGE_FLAG }}
      options: --user root
    steps:
      # ... steps
```

## Runner Mapping

| CodeArts | GitCode runs-on |
|---|---|
| x86-64 builds (CodeCI arch=x86-64) | `[ dedicate-hosted, x64, large ]` |
| arm64 builds | `[ dedicate-hosted, arm64, large ]` |
| Lightweight static checks | `[ 'codearts-hosted', 'ubuntu-latest', 'x64', 'large' ]` |
| Custom cluster/self-hosted | Map to appropriate labels based on cluster_selected |

**In sub-workflows**, the arch is parameterized:
```yaml
runs-on: [ dedicate-hosted, "${{ inputs.runs_on_arch }}", large ]
```
Callers pass `runs_on_arch: "x64"` or `runs_on_arch: "arm64"`.

## Variable/Parameter Mapping

| CodeArts | GitCode | Notes |
|---|---|---|
| `${WORKSPACE}` | `${ATOMGIT_WORKSPACE}` | Working directory |
| `${servicename_1}` | `$(echo "${{ atomgit.repository }}" \| cut -d '/' -f 2)` | Extract repo name from owner/repo |
| `${pr_id}` / `${prid}` | `${{ inputs.pr_id }}` / `${{ atomgit.event.pull_request.number }}` | PR number |
| `${TARGET_BRANCH}` / `${servicebranch_1}` | `${{ inputs.TARGET_BRANCH }}` / `${{ atomgit.event.pull_request.base.ref }}` | Target branch |
| `${REMOTE_URL}` | `${{ inputs.REMOTE_URL }}` / `${{ atomgit.repositoryurl }}` | Repo URL |
| `${repo}` | `${{ inputs.repo }}` / `${{ atomgit.event.repository.name }}` | Repo name |
| Build param `${param_name}` (sensitiveVar=true) | `${{ secrets.PARAM_NAME }}` | Secrets configured in GitCode repo settings |
| Build param `${param_name}` (not sensitive) | `${{ inputs.param_name }}` or env var | Pass as workflow input |
| `${BUILDNUMBER}` / `${RUDDER_BUILD_NUMBER}` | `${{ atomgit.run_number }}` | Run number |
| Pipeline variables from `variables[]` | Map to `inputs` with defaults or `env` block | Not secret → input; secret → secrets |

**Priority rule**: Always prefer `atomgit` context over `env` vars for system-defined values.

### Entry Workflow: Use `env:`, NOT `inputs:` for atomgit defaults (CRITICAL!)

In the **entry workflow** (`PR-pipeline_full.yml`), system context variables derived from
`atomgit.event.*` MUST be defined in the `env:` block, NOT as `inputs:` with defaults.

**Why**: When a workflow is triggered by a PR (pull_request_target), `inputs` with atomgit
defaults do NOT get populated — GitCode treats inputs as required parameters that must be
supplied by the caller. Using `inputs.pr_id` with `default: ${{ atomgit... }}` causes error:
`Input required and not supplied: pr_id`.

**Correct pattern for entry workflow:**
```yaml
env:
  PR_ID: ${{ atomgit.event.pull_request.number }}
  TARGET_BRANCH: ${{ atomgit.event.pull_request.base.ref }}
  REMOTE_URL: ${{ atomgit.repositoryurl }}
  REPO_NAME: ${{ atomgit.event.repository.name }}
# Then reference as ${{ env.PR_ID }} in jobs
```

**Sub-workflows** (`.build_job.yml`, `.ut_python.yml`, etc.) CAN use `inputs:` because they
are called via `uses:` which passes inputs explicitly. Entry workflow env vars are passed
to sub-workflows via `with:` in the `uses:` call.

### Entry Workflow: Container images must be literal strings, NOT `${{ env.xxx }}`

In the **entry workflow** (`PR-pipeline_full.yml`), when a job has a `container:` section with
an `image:` field, the value MUST be a literal image URL string, NOT `${{ env.XXX }}`.

**Why**: Container image resolution happens early in workflow execution, before env vars are
fully evaluated. Using `${{ env.img_xxx }}` for container images can cause resolution failures.

```yaml
# WRONG:
env:
  img_antipoison_x86: "swr.cn-north-4.myhuaweicloud.com/..."
jobs:
  Antipoison:
    container:
      image: ${{ env.img_antipoison_x86 }}    # <-- DO NOT do this

# RIGHT:
jobs:
  Antipoison:
    container:
      image: "swr.cn-north-4.myhuaweicloud.com/huawei-ascend/demo_mindx:mindxdl_20230912_1"
```

This rule applies ONLY to the entry workflow. Sub-workflows use `inputs.IMAGE_FLAG` correctly
because their container image comes from the caller's `with:` parameter.

### Git version upgrade for checkout (CONDITIONAL — NOT for every job)

The `checkout` action requires git ≥ 2.18. Some older SWR container images ship with git 2.17
(ancient Ubuntu base). When checkout runs inside such a container it fails with:
`git version 2.17.1, minimum required is 2.18`.

**Default: do NOT add this step.** It adds ~30-60s per job, and most images (anything dated 2024+,
Ubuntu 20.04+, `mindspore_python*`, `pytorch_images_x86/*`) already have a recent enough git.

Only add the step BEFORE checkout for jobs whose container image is **known** to ship old git:

| Image pattern | Needs git upgrade? |
|---|---|
| `*/huawei-ascend/demo_mindx:*` | YES — old Ubuntu, ships git 2.17 |
| `*/ascend-mindx/mindx_x86:mindxdl_*` (older tags) | YES for tags before ~2025 |
| `*/mindspore/mindspore_python*` | NO — recent Python images |
| `*/pytorch_images_x86/*` | NO |
| `*/modelfoundry/karmada:*` | N/A — discarded entirely (unified pool) |

When needed, the snippet is:

```yaml
- name: git upgrade
  run: |
    apt-get update
    apt-get install -y software-properties-common
    add-apt-repository ppa:git-core/ppa -y
    apt-get update
    apt-get install -y git
    git --version
```

If unsure whether an image needs it, omit the step — the user will report the error on a specific
job if it happens, and you can add it then. See also `references/static-check-mapping.md`
("When to add the git upgrade step").

## Disabled Steps/Jobs Filtering (CRITICAL — do this FIRST)

Before any transformation, filter out ALL disabled items at THREE levels:

1. **Pipeline job level — strategy.select_strategy**: Each job in the pipeline definition has a
   `strategy` field. If `strategy.select_strategy == "never"`, the job is DISABLED (deselected by
   default). Skip this job entirely — do NOT fetch its config, do NOT generate YAML for it.
   ```json
   "strategy": {"select_strategy": "never"}  // DISABLED — skip
   "strategy": {"select_strategy": "selected"}  // enabled — include
   ```
2. **Pipeline step level — enable field**: Skip any step within an enabled job where `enable: false`.
3. **Job config step level**: Within each CodeCI job config, skip any step where `enable == false`.
   Do NOT include them in the generated YAML.

Common disabled steps to skip:
- `上传软件包到软件发布库` (module 20018) — commonly disabled in PR pipelines
- SWR container steps with `enable: false` in PreSmoke jobs (alternative local arm image, disabled in favor of karmada pool)

**Apply ALL three filters before analyzing job structure**, so you don't waste effort on unused jobs/steps.

## CodeArts Unified Resource Pool Job Pattern (CRITICAL to understand)

Many CodeArts build/UT/smoke jobs configured for **unified resource pools** use a three-step pattern.
This is identifiable by:
- Step sequence: `执行shell命令` (20017) → `下载文件管理的文件` (20061) → `使用SWR公共镜像` (20028)
- The SWR step's image is `swr.cn-southwest-2.myhuaweicloud.com/modelfoundry/karmada:latest` (karmada scheduler)
- The SWR step's command is `/workspace/workflowtool/entrypoint.sh`
- Job parameters include `CP_docker_image` and `CP_runs_on`

How it works in CodeArts:
1. **Host shell step** (module 20017, image: `shell4.2.46-git1.8.3-zip6.00`):
   Writes the actual execution script to `shell.sh` using a heredoc:
   ```bash
   cat > shell.sh <<- 'EOF'
   # actual build/UT commands here
   EOF
   ```
2. **Download file step** (module 20061): Downloads `kubeconfig_karmada.key` for cross-cluster scheduling.
3. **SWR/karmada step** (module 20028): The karmada scheduler reads kubeconfig, dispatches the
   workload to the target resource pool (specified by `CP_runs_on`), pulls `CP_docker_image`, and
   runs `shell.sh` inside it via `/workspace/workflowtool/entrypoint.sh`.

**In GitCode, this pattern transforms as follows:**
- **Discard step 2** (下载文件管理的文件) entirely — kubeconfig/karmada is CodeArts scheduling infrastructure
- **Discard step 3** (SWR/karmada container) entirely — no cross-cluster dispatch needed in GitCode
- **Extract step 1's script content**: Take the text between `<<- 'EOF'` and `EOF` (or `<< 'EOF'` and `EOF`) —
  this is the actual command body. Strip the heredoc wrapper; the inner content becomes the `run:` steps.
- **Use `CP_docker_image` as the container image** (from job parameters), NOT the karmada image
- **Map `CP_runs_on` to `runs-on`**: `amd64` → `x64`, `arm64-*` → `arm64`
- Split the extracted script into logical named steps (clone, setup, build/UT, upload) for readability

**CRITICAL — CWD tracking when splitting into steps (do NOT introduce path bugs):**

The heredoc script is ONE contiguous shell script where `cd` persists from line to line.
In GitCode, each `- name: ...\n  run: |` block starts FRESH at the container's WORKDIR
(typically `${ATOMGIT_WORKSPACE}`). `cd` in one `run:` block does NOT carry over to the next.

When you split a single heredoc into multiple named steps, you MUST track the working
directory and prepend an explicit `cd` at the start of each new step to land in the same
directory the original script would be in at that point.

**Common mistakes to avoid:**
- Starting a "setup" step at `${ATOMGIT_WORKSPACE}` when the original script, after
  `cd ${servicename_1}` then `cd /workspace` then `mkdir opensource && cd opensource`,
  expects `opensource/` to be a sibling of the cloned dev repo. In CodeArts `/workspace`
  is the job workspace; in GitCode `${ATOMGIT_WORKSPACE}` is the same thing.
- But: operations like `mkdir opensource` that happen AFTER `cd /workspace` AND after
  `cd ${servicename_1}` earlier in the script — trace carefully whether the resulting
  directory is at workspace root or inside the dev repo clone.

**Safe approach:** Trace the CWD line-by-line through the original heredoc, and at every
point where you split into a new step, start that step with an explicit `cd` to the
correct absolute path. For example:

```bash
# Original heredoc (CWD flow):
cd /workspace
git clone ... ${servicename_1}
cd ${servicename_1}           # CWD = /workspace/${servicename_1}
...
cd /workspace                  # CWD = /workspace (workspace root)
mkdir opensource               # creates /workspace/opensource
cd opensource                  # CWD = /workspace/opensource

# GitCode split — each run block starts at ATOMGIT_WORKSPACE, so:
- name: setup opensource
  run: |
    set -ex
    cd ${ATOMGIT_WORKSPACE}              # <-- explicit cd to where the original script was
    mkdir -p opensource
    cd opensource
    git clone https://.../makeself.git
    ...
```

If unsure about CWD at a split point, prefer FEWER, LARGER `run:` blocks over more smaller
ones. It is better to keep a long contiguous `run:` script than to split incorrectly and
silently produce paths that don't exist at runtime.

### CP_* Cross-Pipeline Parameters

Jobs called via pipeline CloudBuild steps receive CP_ parameters:

| CP Parameter | Meaning | GitCode Mapping |
|---|---|---|
| `CP_runs_on` | Target architecture (e.g., `arm64-cpu-16-mem-32G`, `amd64`) | Maps to `runs_on_arch` input: extract `arm64` → `arm64`, `amd64` → `x64` |
| `CP_docker_image` | Full container image (e.g., `swr.../mindx_arm:tag`) | Maps to `IMAGE_FLAG` — extract tag portion after org/ |
| `CP_pipeline_run_id` | Pipeline run ID | `${{ atomgit.run_id }}` or similar |
| `CP_repo_url` | Repo URL | `${{ inputs.REMOTE_URL }}` |
| `CP_merge_id` | PR/MR ID | `${{ inputs.pr_id }}` |
| `CP_target_branch` | Target branch | `${{ inputs.TARGET_BRANCH }}` |
| `CP_artifacts` | Artifact path pattern | Pass as input or hardcode in upload step |
| `CP_*` (others) | Pipeline context | Map to appropriate atomgit context |

**IMPORTANT**: The `CP_docker_image` is the ACTUAL image used in the SWR container step, overriding
any default image in the job config. When `CP_docker_image` is set, extract the image tag
(last segment after `/`) and use it for `IMAGE_FLAG`; extract registry/org prefix for `IMAGE_REGISTRY`.

Example: `CP_docker_image=swr.cn-south-1.myhuaweicloud.com/ascendhub/openclaw:2026.5.22`
→ `IMAGE_REGISTRY=swr.cn-south-1.myhuaweicloud.com/ascendhub`, `IMAGE_FLAG=openclaw:2026.5.22`

## official_shell_plugin Steps

Pipeline-level steps with `task=official_shell_plugin` contain inline shell scripts directly
in the pipeline definition (not in a CloudBuild job). The script is in:
```
step.inputs[key=OFFICIAL_SHELL_SCRIPT_INPUT].value
```

These convert to regular inline job steps in GitCode — no sub-workflow needed. Create a job
with an appropriate runner/container and put the script directly in a `run:` step.

These steps often do initialization work (e.g., setting up PR labels, posting results).

## Step Type Conversions

### 1. "执行shell命令" (module: 20017) — Host Shell

In CodeArts this runs shell on the host (image: `shell4.2.46-git1.8.3-zip6.00`).
In GitCode, convert these to regular `run:` steps. If the shell step creates a script file
(e.g., `cat > shell.sh << 'EOF'`), that script becomes part of a `run:` step in the container.

**Pattern**: CodeArts jobs often have a host shell step that writes a script, then a container step
that executes it. In GitCode, combine these: the script content goes directly into a `run:` step
inside the container.

### 2. "使用SWR公共镜像" (module: 20028) — Container Execution

**If this is part of the unified resource pool (karmada) pattern**, the SWR step is discarded
(see "Unified Resource Pool Job Pattern" section above). The image comes from `CP_docker_image`
and the command comes from the host shell step's heredoc.

**If this is a standalone SWR step** (non-karmada, e.g., in static check jobs where the image is
a real tool image like `demo_mindx:mindxdl_20230912_1` or `mindspore_python3.11:v0.1`), convert to
a job with `container:` configuration:

```yaml
job_name:
  runs-on: [ 'codearts-hosted', 'ubuntu-latest', 'x64', 'large' ]
  container:
    image: <image from properties.image - this is a REAL tool image, not karmada>
    options: --user root
  steps:
    - run: |
        <command from properties.command>
```

**How to distinguish karmada vs real SWR images:**
- `swr.cn-southwest-2.myhuaweicloud.com/modelfoundry/karmada:latest` → karmada (unified pool, discard)
- Any other SWR image (e.g., `demo_mindx:...`, `mindspore_python:...`, `ascend-mindx/...`) → real tool image (use as container)

**Important**: Commands often use `\r\n` line separators — convert to `\n`.

### Script Classification (CRITICAL — get this right!)

When analyzing shell commands in CodeArts jobs, you MUST determine which repository each script
comes from. **DO NOT assume scripts are from the CI repo without evidence.** Every build/UT job
clones the dev repo and does PR merge — that's expected. CI repo scripts are an ADDITIONAL dependency.

**Decision process for each job:**
1. Does the job download/clone a CI repo? (git clone *-CI.git, OR wget *_ci.tar.gz, OR obsutil cp from ci path)
   - **NO** → The job has NO CI scripts. All `bash script/xxx.sh` calls reference the dev repo.
     **Do NOT modify any script paths.** Do NOT move anything to scripts/. Keep original paths.
   - **YES** → Proceed to step 2.
2. Which specific scripts are called FROM the CI repo?
   - Only those scripts that are explicitly in the CI-cloned directory (e.g., `mindx_ci/...`, `ci/...`, extracted tarball path) are Category B.
   - Scripts called from the dev repo working directory (`cd ${servicename_1}` then `bash script/xxx.sh`) are Category A.

**Category A: Scripts in the TARGET code repository (dev repo)**
Scripts belonging to the repo being built/tested, available after `git clone` of dev repo.
- **No migration needed** — preserve original paths exactly
- Examples: `script/compile.sh`, `script/build_run.sh`, `script/test.sh`, `script/aura_ut.sh`, `run_presmoke.sh`
- These are called from within `${servicename_1}` directory
- **IMPORTANT: Preserve working directory from original script!** When converting:
  - `cd script/ && bash compile.sh` — after this, CWD is `script/`
  - `bash build_run.sh` on the NEXT line executes in `script/` directory TOO
  - Do NOT insert extra `cd` commands between script calls that change the working directory
  - Example (WRONG → RIGHT):
    ```bash
    # WRONG: incorrectly resets to repo root before build_run.sh
    cd ${servicename_1}
    cd script/ && bash compile.sh
    cd ${servicename_1}          # <-- DO NOT add this
    bash build_run.sh             # <-- this would run in repo root, not script/

    # RIGHT: both run in script/ directory
    cd ${servicename_1}/script
    bash compile.sh
    bash build_run.sh             # same working directory (script/)
    ```

**Category B: Scripts from the EXTERNAL CI repository**
Scripts from separately cloned CI repos (URLs like `*-CI.git`) or downloaded CI tarballs.
- Evidence: `git clone ...CI.git` followed by calls to that directory (e.g., `python3 mindx_ci/mindxdl/script/codesca.py`)
  OR wget/tar of `*_ci.tar.gz` followed by calls to extracted CI scripts
- If called by **multiple jobs** → migrate to `workflows/scripts/` directory
- If called by **only one job** → either migrate to scripts/ OR inline script content in the workflow

**Example (build job with NO CI scripts — original paths preserved):**
```bash
# CodeArts original (after removing CI wget/tar):
cd -
cd ../
cd script/ && bash compile.sh       # Category A: dev repo script
bash build_run.sh                    # Category A: dev repo script

# GitCode YAML (correct):
cd ${ATOMGIT_WORKSPACE}/${servicename_1}
cd script/ && bash compile.sh
bash build_run.sh

# GitCode YAML (WRONG — never do this without evidence):
cd .gitcode/workflows/scripts         # WRONG! compile.sh is not from CI repo
bash compile.sh
```

### CI Repository Download Elimination (CRITICAL)

CI repo download logic appears in CodeArts pipelines in two patterns. Both MUST be eliminated:

**Case 1: Per-job CI clone (static check / build / UT jobs each clone CI repo themselves)**
Identified by: within a job's shell script, there's a `git clone https://.../**-CI.git mindx_ci` or
similar line, followed by calls to scripts in that cloned directory (e.g., `python3 mindx_ci/mindxdl/script/codesca.py`).

Transformation:
1. **DELETE the `git clone` line** that clones the CI repo
2. **DELETE any `wget`/`unzip`/`cp` lines for API gateway SDK** that were only needed for CI scripts (unless the script itself is migrated and still needs them)
3. **Copy the referenced script file** into `.gitcode/workflows/scripts/` in the target repo.
   **Attempt to download the script from the CI repo first.** If the CI repo is private/inaccessible,
   create an empty placeholder file with the same name in `scripts/` — the user can populate it manually.
4. **Change the script invocation path** from `mindx_ci/mindxdl/script/codesca.py` to `.gitcode/workflows/scripts/codesca.py`
5. If the script has dependencies (like `apig_sdk`), copy those too or include them in scripts/

Example transformation:
```bash
# BEFORE (CodeArts):
git clone -b master https://AtlasAccount:${Atlas_password}@gitcode.com/Ascend/MindCluster-CI.git mindx_ci
wget https://.../ApiGateway-python-sdk-2.0.7.zip
unzip ApiGateway-python-sdk-2.0.7.zip
cp -rf ApiGateway-python-sdk-2.0.7/apig_sdk mindx_ci/mindxdl/script/
python3 mindx_ci/mindxdl/script/codesca.py --repository_name ${repo} ...

# AFTER (GitCode):
# (apig_sdk should be placed in scripts/apig_sdk/ alongside codesca.py)
python3 .gitcode/workflows/scripts/codesca.py --repository_name ${{ inputs.repo }} ...
```

**Case 2: Separate CI-clone-and-upload-to-OBS job + per-job OBS download**
Identified by:
- A job (typically named "Clone_Private_Repository", "Clone xxx", or similar in stage 0) that:
  1. Clones a CI repo via `git clone https://.../**-CI.git`
  2. Packages it as tar.gz
  3. Uploads to OBS (via "上传文件到OBS" step 20057, or `obsutil cp`)
- Downstream jobs then download via: `wget https://<bucket>.obs.<region>.myhuaweicloud.com/path/*_ci.tar.gz`
  and extract it to get CI scripts.

Transformation:
1. **DELETE the entire Clone CI repo job** (don't generate YAML for it at all)
2. **DELETE the `wget`/`tar` lines in downstream jobs** that download and extract the CI tarball from OBS
3. **ONLY copy CI scripts** (Category B, proven to come from the CI repo) into `.gitcode/workflows/scripts/`.
   Attempt to fetch each script from the CI repo; if the repo is private and inaccessible, create an
   empty placeholder file with the same filename.
4. **DO NOT move dev repo scripts** (Category A) — keep their original paths within the dev repo
5. **When deleting wget/tar, trace the working directory**: After removing CI download, adjust `cd` paths
   so dev repo scripts are called from correct location (typically `cd ${servicename_1}` first)
6. **Decision rule for CI script placement**:
   - If a CI script is called by **multiple jobs** → place as a file in `scripts/` (do NOT inline)
   - If called by **only one job** → either place in scripts/ OR inline content

Example transformation (where compile.sh is a Category A dev repo script, but CI tar provides other CI scripts):
```bash
# BEFORE (CodeArts):
git clone -b ${servicebranch_1} ... ${servicename_1}   # clone dev repo
cd ${servicename_1}
cd /workspace
wget ..._ci.tar.gz                                      # download CI repo
tar -zxvf ..._ci.tar.gz
mv ..._ci/* /workspace/ci/
cd /workspace
mkdir opensource && cd opensource && ...                 # setup
cd -
cd ../
cd script/ && bash compile.sh                            # THIS IS DEV REPO script
bash build_run.sh                                        # THIS IS DEV REPO script

# AFTER (GitCode):
servicename_1=$(echo "${{ atomgit.repository }}" | cut -d '/' -f 2)
git clone ... ${servicename_1}                           # clone dev repo
cd ${servicename_1}
# wget/tar/mv CI lines DELETED
# opensource setup still runs (it creates dependencies, not CI scripts)
mkdir -p ... && cd ...
cd ${ATOMGIT_WORKSPACE}/${servicename_1}                  # cd into dev repo
bash script/compile.sh                                   # Category A: dev repo path preserved
bash script/build_run.sh                                 # Category A: dev repo path preserved
```

**For both cases**: For non-default-branch PRs, add the fallback mechanism (clone default branch, copy `scripts/` directory)
to ensure CI scripts are available.

**Rule of thumb**: If the script path references a separately-cloned CI directory (`mindx_ci/`,
`ci/`, an extracted tarball like `*_ci/`, or an OBS-downloaded archive), it's Category B and must be migrated. If it's within the
`${servicename_1}` directory after cloning the target repo, it's Category A.

### 3. "上传文件到OBS" (module: 20057) — OBS Upload

Replace with the `obs-upload` action:

```yaml
- name: Upload to OBS
  uses: obs-upload
  with:
    endpoint: "obs.<region>.myhuaweicloud.com"
    bucket: "<bucket-name>"
    access-key: "${{ secrets.OBS_AK }}"
    secret-key: "${{ secrets.OBS_SK }}"
    artifact-path: "<path pattern>"
    object-prefix: "<prefix>/${{ inputs.pr_id }}/"
```

### 4. "下载文件管理的文件" (module: 20061) — File Download

These often download previously prepared files. In GitCode:
- If downloading from OBS: use `wget` or obsutil to fetch
- If downloading from another repo: use `git clone`
- If the download was for CI scripts from the CI repo: eliminate (scripts now in-repo under `scripts/`)
- Convert the specific download logic inline based on what it fetches

### 5. "制作镜像并推送到SWR" (module: 20004) — Docker Build & Push

Replace with appropriate Docker build steps or the `docker-build` action if available.
Most PR pipelines don't build images in the pipeline itself; these steps are typically disabled (enable:false)
in PR pipelines and can be skipped.

## Stage and Job Dependencies

CodeArts uses `depends_on` with job identifiers like `JOB_ZyKWQ`. In GitCode:
- Jobs are organized under `stages:` — jobs in earlier stages complete before later stages
- Within the same stage, jobs run in parallel by default
- For explicit dependencies within a stage, use `if:` conditions referencing job outputs
- The md_check job produces an `outputs.build_skip` that downstream jobs check with:
  ```yaml
  if: ${{ jobs.Only_doc_commit_check.outputs.build_skip == 'no' }}
  ```

## Handling the "Clone CI Repo" Task

CodeArts PR pipelines often have a first-stage job that clones a CI repo (e.g., `mindx_ci`, `CI`)
and uploads it to OBS for other jobs to download. **Eliminate this entirely.**

Instead:
1. CI scripts that multiple jobs call go under `.gitcode/workflows/scripts/` in the target repo
2. Scripts called only once can be "digested" inline in the sub-workflow
3. The sub-workflow's clone step also handles the non-default-branch fallback:

```yaml
- name: clone repo and prepare CI scripts
  run: |
    set -x
    servicename_1=$(echo "${{ atomgit.repository }}" | cut -d '/' -f 2)
    git clone --no-tags --single-branch -b ${{ inputs.TARGET_BRANCH }} ${{ inputs.REMOTE_URL }} ${servicename_1}
    cd ${servicename_1}
    git fetch --no-tags origin refs/merge-requests/${{ inputs.pr_id }}/head:pr_${{ inputs.pr_id }}
    git reset --hard "origin/${{ inputs.TARGET_BRANCH }}"
    git checkout -b new_${{ inputs.TARGET_BRANCH }}
    git merge --no-edit pr_${{ inputs.pr_id }}
    git diff-tree -r --name-only --no-commit-id origin/${{ inputs.TARGET_BRANCH }} HEAD > ${ATOMGIT_WORKSPACE}/change.txt

    # Handle non-default-branch PRs: copy scripts from default branch
    if [ "${{ env.ATOMGIT_BASE_REF }}" != "<default_branch>" ]; then
        workflow_path=${ATOMGIT_WORKSPACE}/${servicename_1}/.gitcode/workflows
        mkdir -p ${workflow_path}
        git clone --depth 1 -b <default_branch> ${{ inputs.REMOTE_URL }} ${ATOMGIT_WORKSPACE}/tempdir
        cp -fr ${ATOMGIT_WORKSPACE}/tempdir/.gitcode/workflows/scripts ${workflow_path}/ 2>/dev/null || true
        cp -fr ${ATOMGIT_WORKSPACE}/tempdir/.gitcode/workflows/config ${workflow_path}/ 2>/dev/null || true
        rm -fr ${ATOMGIT_WORKSPACE}/tempdir
    fi
```

## Disabled Tasks

- **Pipeline-level**: Steps/jobs in the pipeline definition with `enable: false` are skipped during fetch
- **Job-level**: Steps within a CodeCI job config with `enable: false` are skipped during transformation
- Do NOT generate YAML for disabled tasks — they represent intentionally removed functionality

## md_check Conversion

The CodeArts `md_check@0.0.7` plugin task converts to:

```yaml
Only_doc_commit_check:
  name: Only_doc_commit_check
  runs-on: [ dedicate-hosted, x64, large ]
  container:
    image: swr.<region>.myhuaweicloud.com/<org>/<image>
    options: --user root
  outputs:
    build_skip: ${{ steps.set-skip.outputs.build_skip }}
  steps:
    - name: checkout
      uses: checkout
      with:
        ref: ${{ atomgit.event.pull_request.merge_commit_sha || '' }}
    - name: only doc commit check
      id: only-doc-check
      uses: <owner>/<repo>/.gitcode/actions/only_doc_commit_check@<branch>
      with:
        pr_id: ${{ inputs.pr_id }}
        target_branch: ${{ atomgit.event.pull_request.base.ref }}
        remote_url: ${{ env.ATOMGIT_REPOSITORY_URL }}
    - name: set build skip flag
      id: set-skip
      run: |
        BUILD_SKIP=${{ steps.only-doc-check.outputs.is_only_doc }}
        echo "build_skip=${BUILD_SKIP}" >> "$ATOMGIT_OUTPUT"
        echo "Only Doc Commit Check result: ${BUILD_SKIP}"
```

The action `only_doc_commit_check` checks whether the PR only modifies `.md` files. If so,
`build_skip` is set to "yes" and downstream build/UT jobs are skipped.

## Secrets to Configure

After generating YAML, list all secrets the user must add in GitCode repo settings:

From CodeArts parameters with `sensitiveVar: true`:
- `OBS_AK` / `OBS_SK` — OBS access credentials
- `ATLAS_PASSWORD` — GitCode Atlas account password
- `SCAN_ACCESS_KEY` / `SCAN_SECRET_KEY` — SCA scan credentials
- `APPID_TASK_*` / `SECRETKEY_*` — Antipoison API credentials
- Any other sensitive parameters found in the job configs

Note: Parameter names from CodeArts use lower_snake_case (e.g., `gitcode_token`);
convert to UPPER_SNAKE_CASE for GitCode secrets (e.g., `GITCODE_TOKEN`).
