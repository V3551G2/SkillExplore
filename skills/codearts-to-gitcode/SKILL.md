---
name: codearts-to-gitcode
description: |
  MUST USE when the user wants to convert/migrate/transform a Huawei Cloud CodeArts (流水线/pipeline) PR pipeline
  into GitCode Action YAML workflow files. Triggers on phrases like "转化流水线", "convert pipeline",
  "codearts转gitcode", "pipeline to yaml", "migrate codearts pipeline", "流水线转yml",
  "CodeArts pipeline to GitCode actions", or when given a CodeArts pipeline URL plus cookie and asked
  to produce GitCode workflow YAML. Given a pipeline URL and session cookie, fetches the full pipeline
  config via CodeArts REST APIs, analyzes each job, and generates a PR-pipeline_full.yml entry file plus
  reusable workflow_call sub-workflow files following established patterns.
---

# CodeArts Pipeline → GitCode Action YAML Converter

Convert a Huawei Cloud CodeArts PR pipeline into GitCode Action YAML workflow files. The process
fetches pipeline and job configuration via CodeArts REST APIs, then transforms each task into
GitCode workflow YAML following proven patterns.

## What the user must provide

1. **Pipeline URL** — e.g. `https://devcloud.cn-north-4.huaweicloud.com/cicd/project/<project_id>/pipeline/history/<pipeline_id>?v=1`
2. **Session cookie** — raw cookie string from a logged-in browser session on `devcloud.<region>.huaweicloud.com`

## Output deliverable

A single directory of YAML files (typically written to a user-specified output dir or a temp dir):

```
.gitcode/workflows/
├── PR-pipeline_<option>.yml  # Entry workflow (see naming rules below)
├── .build_job.yml            # Reusable build sub-workflow (workflow_call)
├── .ut_python.yml            # Reusable UT python sub-workflow
├── .ut_cpp.yml               # Reusable UT cpp sub-workflow (if needed)
├── .<job_name>.yml           # One sub-workflow per unique job type
└── scripts/                  # CI scripts migrated from CI repo (carried in-repo)
    ├── ci_build.sh
    ├── build_package.sh
    ├── anti_poison.py
    └── ...
```

### Naming conventions

**Entry YAML file** — determined by the pipeline type:
| Pipeline type | Entry file name pattern | How to identify |
|---|---|---|
| PR pipeline | `PR-pipeline_<option>.yml` (e.g. `PR-pipeline_full.yml`) | CodeArts pipeline name starts with `PR-` or uses `pull_request_target` triggers |
| Nightly/Version pipeline | `Nightly-Version_<option>.yml` | CodeArts pipeline name contains `Nightly` or `Version` |

CodeArts pipelines already follow this naming convention, so the pipeline name from the API (`pipeline.name`) is the most reliable signal — use its prefix to determine the entry filename.

**Stage naming** — each stage has both an `id` (sequence number) and a `name` (category label).
The `name` is a `&`-joined combination of task categories present in that stage:

| Category | Includes |
|---|---|
| `CodeCheck` | Antipoison, SCA, CodeCheck, pre-commit, lint, SAST, md_check |
| `Build` | Build_x86, Build_arm, compilation jobs |
| `Test` | UT/test jobs, PreSmoke, integration tests |

Examples:
- Stage containing only SCA + pre-commit → name: `CodeCheck`
- Stage containing pre-commit + Build_x86 + PreSmoke → name: `CodeCheck_Build_Test`
- Stage containing only Build_arm → name: `Build`

The stage key/id stays `stage_<n>` (sequential), only the `name` field uses this convention.

## Workflow

### Phase 1: Fetch Pipeline Configuration via API

Read `references/api-reference.md` for full API details. The steps:

1. **Parse the URL and cookie** — extract `project_id`, `pipeline_id`, `region`, `cftk` token.
   - `project_id`: hex string after `/project/` in the URL
   - `pipeline_id`: hex string after `/pipeline/history/` (or `/pipeline/detail/`)
   - `cftk`: extract from cookie field `devclouddevuibjtcftk=<value>`
   - `region`: extract from cookie field `*_cfProjectName=<region>` (usually `cn-north-4`)

2. **Fetch pipeline definition** — `GET /cicd/v5/internal/<project_id>/pipelines/<pipeline_id>`
   - Returns `definition` (JSON string of stages/jobs/steps), `variables`, `triggers`, `sources`
   - Parse `definition` to enumerate all stages, jobs, and their steps
   - **Filter disabled jobs at THREE levels** (see conversion-rules.md for details):
     a. `strategy.select_strategy == "never"` → job is deselected by default → SKIP entire job
     b. Pipeline step `enable: false` → skip that step
     c. Job config step `enable == false` → skip that step
   - Collect all `jobId` values from enabled steps with `task=official_devcloud_cloudBuild`
   - Do NOT fetch job configs for disabled jobs
   - Save the raw JSON for reference

3. **Fetch each CodeCI job config** — `GET /codeci/v1/job/<job_id>/config?get_all_params=true`
   - One call per unique `jobId` from ENABLED jobs only
   - Returns: `job_name`, `arch`, `host_type`, `steps[]`, `parameters[]`, `scms[]`, cluster config
   - **Skip all disabled steps** (`step.enable == false`) — do NOT generate YAML for them
   - Parse each enabled step: extract `module_id`, `name`, `properties.command`, `properties.image`
   - Collect all `parameters` (these map to secrets in GitCode)
   - Save each job config as JSON for reference

4. **Classify each job** into a type based on its name, task type, and content. First determine
   whether the job uses a **unified resource pool** (identifiable by these signatures):
   - Step sequence: `执行shell命令` → `下载文件管理的文件` → `使用SWR公共镜像`
   - The SWR step image is `swr.cn-southwest-2.myhuaweicloud.com/modelfoundry/karmada:latest` (or similar karmada wrapper)
   - The SWR step command is `/workspace/workflowtool/entrypoint.sh`
   - Job parameters include `CP_docker_image` and `CP_runs_on`

   For **unified resource pool jobs**, the transformation is:
   - **Discard** step 2 (`下载文件管理的文件`) entirely — this is CodeArts infrastructure (kubeconfig)
   - **Discard** step 3 (SWR/karmada container) entirely — it's just a wrapper
   - Extract the script from step 1's heredoc (`cat > shell.sh <<- 'EOF' ... EOF`), strip the heredoc wrapper, and use that as the `run:` body
   - Use `CP_docker_image` parameter value as the GitCode container image
   - Map `CP_runs_on` to `runs-on` (amd64→x64, arm64*→arm64)
   - Do NOT use the SWR step's image (karmada wrapper) — always use `CP_docker_image`

   Job type classification:
   - **official_shell_plugin step**: inline shell directly in the pipeline definition (not a CloudBuild job). Extract script from `inputs[key=OFFICIAL_SHELL_SCRIPT_INPUT].value` → *convert to inline job with run: step*
   - **Clone/CI-repo task** (task=`official_devcloud_cloudBuild`, job clones CI repo and uploads tar.gz to OBS): clones an external CI repo → *ELIMINATE this job entirely*. CI scripts are migrated to `.gitcode/workflows/scripts/` and downstream jobs no longer download from OBS. Do NOT generate YAML for this job.
   - **md_check** (task=`md_check@*`): custom CodeArts plugin checking if PR only modifies .md files → *convert to inline job with only_doc_commit_check action*
   - **SCA**: Software Composition Analysis → **MUST use `sca-pr-scan` plugin** (do NOT convert to container+script). This is a built-in GitCode action.
   - **pre-commit**: Git hooks/linting → **MUST use `openlibing-pre-commit-action` plugin**
   - **Antipoison**: No built-in plugin → convert to container+script. Carry `anti_poison.py` in `.gitcode/workflows/scripts/` — try downloading it from the CI repo first; if the CI repo is private and inaccessible, create an empty placeholder file with the same name.
   - **SAST**: No built-in plugin → convert to container+script
   - **CodeCheck**: CodeArts-specific code check → convert to container+script or `codecheck_gitcode_v2` plugin
   - **Build** (x86/arm): compiles code → *create reusable `.build_job.yml` workflow_call; for unified pool jobs extract commands from heredoc, use CP_docker_image as image*
   - **UT** (python/cpp/go): runs unit tests → *create reusable `.ut_<lang>.yml` workflow_call; for unified pool jobs extract commands from heredoc, use CP_docker_image as image*
   - **PreSmoke**: deploys build artifacts and runs smoke tests → *create reusable `.presmoke.yml` workflow_call*

### Phase 2: Transform to GitCode YAML

Read `references/conversion-rules.md` for detailed mapping rules. Key principles:

#### File structure
- **`PR-pipeline_full.yml`** is the entry point. It contains:
  - `on:` triggers (`pull_request_target`, `pull_request_comment` for `/compile`, `workflow_dispatch`)
  - `inputs:` with defaults from `atomgit` context
  - `env:` block for shared environment variables (image names, etc.)
  - `stages:` with jobs that either run inline steps or `uses:` to call sub-workflows
- **Sub-workflow files** (`.build_job.yml`, `.ut_python.yml`, etc.) use `on: workflow_call:` with
  `inputs:` and `secrets:`, define their own runner/container/steps.

#### Runner mapping
| CodeArts arch | GitCode runs-on |
|---|---|
| x86-64 | `[ dedicate-hosted, x64, large ]` |
| arm64 / aarch64 | `[ dedicate-hosted, arm64, large ]` |
| default hosted | `[ 'codearts-hosted', 'ubuntu-latest', 'x64', 'large' ]` |

#### Trigger configuration
```yaml
on:
  pull_request_target:
    branches: [ <list target branches from pipeline triggers> ]
    types: [open, update, reopen, merge]
  pull_request_comment:
    types: [created]
    branches: [ '*' ]
    comments: [ '^(?:\/)?compile*' ]
  workflow_dispatch:
```

#### Key transformation rules

1. **Eliminate CI-repo download logic ONLY when CI scripts are actually used.**
   Every build/UT job clones the dev repo and merges the PR — that's expected and stays.
   CI repo download logic is only present in jobs that ALSO clone/download a separate CI repo.
   Check each job: does it have `git clone *-CI.git` or `wget *_ci.tar.gz`?
   - **NO CI download** → All script calls are dev repo scripts. PRESERVE original paths. Do NOT move anything into `scripts/`. Do NOT change `cd script/` → `cd .gitcode/workflows/scripts/`.
   - **YES CI download** → Eliminate the CI download. For scripts that came from CI repo:
     - Called by multiple jobs → migrate to `scripts/` directory
     - Called by one job → inline or migrate to `scripts/`
     Dev repo scripts stay in their original paths.

   Two CI download patterns (see conversion-rules.md for details):
   - **Case 1 (per-job clone):** Jobs contain `git clone https://.../**-CI.git mindx_ci` followed by calls to scripts in that directory.
   - **Case 2 (separate clone+OBS job):** A dedicated job clones CI, uploads tar to OBS; downstream jobs wget/tar it.

2. **md_check → inline job with action plugin.** Use the pattern from the reference:
   ```yaml
   Only_doc_commit_check:
     runs-on: [ dedicate-hosted, x64, large ]
     container:
       image: swr.cn-north-4.myhuaweicloud.com/pytorch_images_x86/pytorchx86:v_03
       options: --user root
     outputs:
       build_skip: ${{ steps.set-skip.outputs.build_skip }}
     steps:
       - uses: checkout
         with:
           ref: ${{ atomgit.event.pull_request.merge_commit_sha || '' }}
       - id: only-doc-check
         uses: ComputingActionTest/mind-cluster/.gitcode/actions/only_doc_commit_check@master
         with:
           pr_id: ${{ inputs.pr_id }}
           target_branch: ${{ atomgit.event.pull_request.base.ref }}
           remote_url: ${{ env.ATOMGIT_REPOSITORY_URL }}
       - id: set-skip
         run: |
           BUILD_SKIP=${{ steps.only-doc-check.outputs.is_only_doc }}
           echo "build_skip=${BUILD_SKIP}" >> "$ATOMGIT_OUTPUT"
   ```
   Add `if: ${{ jobs.Only_doc_commit_check.outputs.build_skip == 'no' }}` on downstream build/UT jobs.

3. **Static checks → plugins or container+script.** Consult `references/static-check-mapping.md` for
   the specific plugin to use per check type. SCA uses `sca-pr-scan` plugin; pre-commit uses
   `openlibing-pre-commit-action` (do NOT pass `gc_token` — it is no longer required as of 2026-07);
   Antipoison has no plugin and must run as container + python script; CodeCheck uses `codecheck_gitcode_v2`;
   SAST runs as container+script.

4. **Build & UT jobs → reusable sub-workflows.** These have long call chains (clone repo, fetch PR refs,
   merge, set up build tools, run build scripts, upload artifacts). Encapsulate them in workflow_call files.
   Read `templates/build_job.yml` and `templates/ut_job.yml` for the starting scaffold.

   **CRITICAL — CWD (working directory) tracking when splitting scripts into steps:**
   The extracted heredoc is a single shell script where `cd` persists across lines. In GitCode, each
   `run:` block starts FRESH at `${ATOMGIT_WORKSPACE}` — `cd` from one step does NOT carry to the next.
   When you split one contiguous script into multiple named steps, you MUST trace the CWD line-by-line
   through the original script and prepend an explicit `cd <abs-path>` at the start of each new step.
   Starting a step in the wrong directory silently creates paths at the wrong level (e.g. `mkdir opensource`
   at workspace root instead of inside the cloned repo). See `references/conversion-rules.md` ("CWD tracking
   when splitting into steps") for a worked example. When in doubt, prefer fewer, larger `run:` blocks
   over many small ones — incorrect splits are worse than longer steps.

5. **CI scripts → carry in-repo under `scripts/` (NOT `build/`).** Scripts that were in the external CI
   repo (e.g. `ci_build.sh`, `build_package.sh`, `anti_poison.py`, `codesca.py`) must be migrated to
   `.gitcode/workflows/scripts/` in the target repo. The workflow references them directly.

   **When fetching CI scripts (e.g. anti_poison.py, codesca.py)**: CI repos may be private. First
   attempt to download the file from the CI repo URL. If download fails (no access / private repo),
   create an empty placeholder file with the same name in `scripts/` so the repo structure is valid
   and the user knows to populate it manually. See `references/static-check-mapping.md` for the
   download-and-fallback pattern.

   If the target branch is not the default branch and these scripts are missing, clone the default
   branch and copy them over:
   ```yaml
   - name: Ensure CI scripts exist for non-default branches
     run: |
       if [ "${{ env.ATOMGIT_BASE_REF }}" != "<default_branch>" ]; then
         git clone --depth 1 -b <default_branch> ${{ inputs.REMOTE_URL }} /tmp/default_branch
         cp -fr /tmp/default_branch/.gitcode/workflows/scripts ./.gitcode/workflows/
         rm -rf /tmp/default_branch
       fi
   ```

6. **Parameter mapping:**
   - CodeArts `${WORKSPACE}` → GitCode `${ATOMGIT_WORKSPACE}` (or `$GITHUB_WORKSPACE` equivalent)
   - CodeArts `${param_name}` for secrets → GitCode `${{ secrets.PARAM_NAME }}`
   - Prefer `atomgit` context for system-defined values over `env` vars:
     - PR number: `${{ atomgit.event.pull_request.number }}`
     - Target branch: `${{ atomgit.event.pull_request.base.ref }}`
     - Merge commit: `${{ atomgit.event.pull_request.merge_commit_sha }}`
     - Repo name: `${{ atomgit.event.repository.name }}`
     - Repo URL: `${{ atomgit.repositoryurl }}`
     - Full repo (`owner/name`): `${{ atomgit.repository }}`
   - Sensitive parameters from CodeArts `parameters[]` → map to `${{ secrets.XXX }}` (user configures these in GitCode repo settings)
   - **Sub-workflow `with:` block (entry workflow calling sub-workflows):** Only pass inputs that are
     `required: true` in the sub-workflow (typically `IMAGE_FLAG`, `runs_on_arch`). Do NOT re-pass inputs
     the sub-workflow already defaults via `default: ${{ atomgit... }}` (e.g. `REMOTE_URL`, `pr_id`,
     `TARGET_BRANCH`, `DEFAULT_BRANCH`) — doing so triggers a **"bad substitution"** runtime error
     because the atomgit expression gets evaluated in the entry workflow's context before being
     forwarded. The sub-workflow resolves its own atomgit defaults correctly. See
     `references/conversion-rules.md` and FAQ entry #11 for details and the WRONG/RIGHT example.

7. **Images:** Use `CP_docker_image` parameter value (the REAL container image), NOT the SWR step's
   `properties.image` which is often the CodeArts karmada wrapper. Extract image tag for `IMAGE_FLAG`.
   Define images as `env` variables in the entry workflow for easy maintenance.

   **CRITICAL — Script classification:** When converting shell commands, distinguish two script types
   (see `references/conversion-rules.md` for details):
   - **Category A** — Scripts in the target repo (e.g., `script/test.sh`, `run_presmoke.sh`): available after `git clone`, no migration needed
   - **Category B** — Scripts from the external CI repo (e.g., `compile.sh`, `codesca.py`, `anti_poison.py`, `ci_build.sh`): MUST be migrated to `.gitcode/workflows/scripts/`. Eliminate OBS download steps for CI scripts; reference them from the in-repo scripts/ directory. When fetching CI script content, try downloading from the CI repo first; if the repo is private/inaccessible, create an empty placeholder file with the same name in scripts/ so the YAML path is valid and the user can populate it manually.

8. **Artifact upload:** Replace CodeArts OBS upload steps with GitCode's `obs-upload` action.
   Replace CodeArts "下载文件管理的文件" (file download) steps with appropriate fetch logic.

8a. **obsutil cp → wget for OBS dependency downloads:** When a job script uses `obsutil cp` to
    download dependency tarballs/packages from OBS (separate from CI-repo elimination — these
    are build dependencies like toolchains, third-party packages), convert to an equivalent
    `wget` from the OBS public HTTP endpoint. The `obsutil` binary may not be available in
    GitCode containers, and wget is universally present.

    Pattern:
    ```
    obsutil cp obs://<bucket>/<path>/<file>.tar.gz  <local>/<file>.tar.gz
    ```
    Converts to:
    ```
    wget -O <local>/<file>.tar.gz https://<bucket>.obs.<region>.myhuaweicloud.com/<path>/<file>.tar.gz
    ```

    - `<region>` defaults to `cn-north-4`. Extract the actual region from the pipeline URL
      (e.g., `devcloud.cn-north-4.huaweicloud.com`) or from cookie `cfProjectName=<region>`.
    - Preserve any `-f`/overwrite semantics by adding `rm -f <target>` before wget if needed.
    - Do NOT convert obsutil lines that download CI-repo content — those are eliminated entirely
      per rule #1 (CI scripts migrate to `.gitcode/workflows/scripts/`). This rule is only for
      third-party/toolchain dependencies that remain OBS-hosted.
    - Preserve commented-out obsutil config lines (e.g., `# obsutil config -i=...`) as-is.

    See `references/conversion-rules.md` "obsutil cp → wget conversion" for details.

9. **PR merge logic in build/UT jobs:** The sub-workflow must check out the target branch, fetch the PR
   head ref, and merge. Before `git merge`, set the committer identity to avoid "Committer identity unknown"
   errors in fresh containers (see `references/faq.md` "Git merge: committer identity unknown"):
   ```bash
   servicename_1=$(echo "${{ atomgit.repository }}" | cut -d '/' -f 2)
   git clone --no-tags --single-branch -b ${{ inputs.TARGET_BRANCH }} ${{ inputs.REMOTE_URL }} ${servicename_1}
   cd ${servicename_1}
   git fetch --no-tags origin refs/merge-requests/${{ inputs.pr_id }}/head:pr_${{ inputs.pr_id }}
   git reset --hard "origin/${{ inputs.TARGET_BRANCH }}"
   git checkout -b new_${{ inputs.TARGET_BRANCH }}
   git config --global user.name AtlasAccount
   git config --global user.email AtlasAccount@noreply.gitcode.com
   git merge --no-edit pr_${{ inputs.pr_id }}
   ```

10. **Preserve the fidelity of the original script.** When adapting shell commands from CodeArts,
    do NOT uncomment lines that were commented out in the original (e.g., `# obsutil config -i=...`
    should stay commented), and do NOT comment out lines that were active. Commented lines in the
    CodeArts script are intentionally disabled — respect that. Substitute variables (WORKSPACE→ATOMGIT_WORKSPACE,
    secret params→secrets.XXX, etc.) and eliminate CI-repo download logic as instructed, but do not
    change the active/commented status of unrelated lines.

11. **Strip debug-only echo/print steps.** When generating YAML steps (whether from templates or
    from CodeArts script analysis), do NOT include steps that only print environment variables or
    echo diagnostic information (e.g., `echo "pr_id=..."`, `echo "IMAGE_FLAG=..."`, `pwd`, `env | sort`).
    These are leftover debugging aids and add noise to CI logs without functional value. The build
    step's own `set -ex` already provides sufficient trace output. Remove any such step from both
    templates AND converted job YAML. The only "print" steps to keep are ones that output actual
    build artifacts (like `cat ${ATOMGIT_WORKSPACE}/change.txt` which shows changed files).

### Phase 3: Output and Validate

1. Write all YAML files to `<output_dir>/workflows/` directory.
2. **Write CI scripts to `<output_dir>/workflows/scripts/` directory.** For each Category B script
   (from CI repos), you MUST:
   - Create the `scripts/` directory under the workflows output directory
   - Try to fetch the script content from the CI repo (via raw URL / git clone / API)
   - If fetch succeeds → write the real script content to `scripts/<filename>`
   - If fetch fails (private repo, permission denied) → create an empty placeholder file
     `scripts/<filename>` so the path referenced by the YAML exists, and note in the summary
     that it needs manual population
   - List these files in the summary, noting which were fetched and which are placeholders
3. Validate YAML syntax (parse with a YAML parser if available, or at minimum check indentation).
4. Present a summary to the user:
   - List of all generated files (YAML files in workflows/ and scripts in workflows/scripts/)
   - Job mapping table (CodeArts job → GitCode job/sub-workflow)
   - Secrets the user needs to configure in GitCode repo settings
   - **CI scripts placed in scripts/**: List Category B scripts — mark each as "fetched from CI repo"
     or "PLACEHOLDER (CI repo may be private — populate manually)"
   - **In-repo scripts (Category A)**: List scripts that reference the dev repo's own paths
     (e.g., `script/compile.sh`, `script/test.sh`) and do not need migration — confirm these are
     in the target repo already
   - **WARNING for any uncertain scripts**: If you cannot determine whether a script is Category A
     or B, PRESERVE the original path and flag it for user review
   - Any tasks that could not be automatically converted and need manual attention

### Phase 4: Push to GitCode, Verify, Fix (CLOSED LOOP — do NOT stop at link handoff)

If the user provides:
- A **test organization** (e.g., `https://gitcode.com/ComputingActionTest`)
- A **GitCode access token** with repo creation/push permissions

Then run the full closed loop. This is NOT optional when both org and token are supplied.
The goal is to proactively drive every job to either **success** or **documented human-action-required**,
not to hand back a link and walk away. Reference: https://gitcode.com/gitcode-cli/skills

**Step 4a — Push YAML to fork repository:**
1. Create a fork repo in the test organization with the same name as the pipeline's source repo
   (from `sources.git_url`, e.g., `Ascend/AgentSDK` → create `AgentSDK` in test org).
2. Sync the default branch code from `sources.git_url` to the fork repo's default branch.
3. Commit generated `.gitcode/workflows/*.yml` and `.gitcode/workflows/scripts/*` to the fork default branch.
4. Remind the user to perform these post-push setup steps in the fork repo:

   a. **Configure required secrets** in repo Settings → Secrets and variables → Actions
      (list them from secrets-mapping.md and the actual parameters encountered).
   b. **Enable Actions**: Project Settings → Enable Actions → Save.
   c. **Enable PR pre-merge**: Project Settings → Repository Management → "Merge Request PR Pre-Merge"
      (合并请求PR预合并) → Save. Required for `pull_request_target` triggers.

   Wait for the user to confirm steps a–c are done before proceeding. Do not create the test PR
   until they confirm; otherwise the first pipeline run will hit avoidable secret/config errors.

**Step 4b — Create test PR:**
1. From default branch, create a test branch named `<default_branch>_test`.
2. Make TWO commits to exercise both paths of md_check:
   - First commit: add a `.md` file (e.g. `CI_TEST_TRIGGER.md`) — lets you confirm the doc-only skip works.
   - Second commit (on same branch): add a non-`.md` file (e.g. `pipeline_test_trigger.txt`) — triggers the full pipeline.
3. Push and create a PR (`<default_branch>_test` → default branch).
4. Record the PR number and share the PR URL with the user.

**Step 4c — Proactive monitor-and-fix loop (THE CORE OF THIS PHASE):**

After the PR is created, **do NOT just hand back the link and stop**. Drive the pipeline to
resolution using the following polling + diagnosis + fix loop.

**If NO run appears at all after opening the PR or posting a comment:** This is a trigger
problem, not a job failure. Consult `references/faq.md` #17 ("No reaction after opening a test
PR or posting a comment"): verify the entry workflow's `on:` block declares the matching event
(`pull_request_target`/`pull_request` for PR open/update; `pull_request_comment` for comments,
not `issue_comment`) and correct branches/regex, confirm the YAML is on the default/target
branch (not only the PR branch), and if all that is correct, ask the user to confirm the GitCode
account/org is whitelisted for Actions. Do not start editing job YAML until a run is actually
being created.

**Polling:** Use `ScheduleWakeup` to wake every 60–120 seconds and re-check the pipeline status
via the GitCode API (base URL `https://api.gitcode.com/api/v8` — **hostname is `api.gitcode.com`,
NOT `gitcode.com`**; auth header `PRIVATE-TOKEN: <token>`). Between checks you are idle. Continue
until all jobs reach a terminal state (`COMPLETED`, `FAILED`, or `CANCELLED`). Official API docs:
https://docs.gitcode.com/docs/apis/get-api-v-8-repos-owner-repo-actions-runs

Use these v8 endpoints (all on `https://api.gitcode.com`):
```
GET  /api/v8/repos/<owner>/<repo>/actions/runs?per_page=5                  # list recent runs
GET  /api/v8/repos/<owner>/<repo>/actions/runs/<workflow_run_id>            # get run details (includes stages→jobs→steps)
GET  /api/v8/repos/<owner>/<repo>/actions/runs/<workflow_run_id>/jobs       # list jobs in a run
GET  /api/v8/repos/<owner>/<repo>/actions/runs/<workflow_run_id>/jobs/<job_id>  # get job details
POST /api/v8/repos/<owner>/<repo>/actions/runs/<workflow_run_id>/jobs/<job_id>/logs  # paginated log text (JSON)
GET  /api/v8/repos/<owner>/<repo>/actions/runs/<workflow_run_id>/jobs/<job_id>/download_log  # full job log (ZIP of per-step .log files)
```

**Key response field differences from GitHub Actions:**
- Run ID is `workflow_run_id` (not `id`), job ID is `id` (hex UUID string)
- Status values are UPPERCASE: `PENDING`, `RUNNING`, `COMPLETED`, `FAILED`, `CANCELLED`
- Timestamps are Unix epoch **milliseconds** (not ISO 8601)
- `download_log` returns a **ZIP file** containing one `.log` file per step (e.g., `0_checkout.log`, `1_Run SCA PR Scan.log`) — save to file, `unzip`, then read individual step logs
- The run details endpoint (`GET .../runs/<id>`) returns nested `stages[].jobs[].steps[]` in one call

To re-run after a YAML fix, push to master (for `pull_request_target` YAML changes) then trigger
via `/compile` PR comment using v5 API: `POST https://gitcode.com/api/v5/repos/<owner>/<repo>/pulls/<pr_number>/comments`
with body `{"body": "/compile"}`.

See `references/api-reference.md` for full Bash/PShell polling examples and response schemas.

For each failed job, run the **failure-handling decision tree** below. Track per-job state in a
small dict: `{job_name, status, fix_attempts, resolution, notes}`. A job is *resolved* when it is
either `success`, or `needs_human` (see below), or `known_limit` after 3 fix attempts.

**Failure-handling decision tree (per failed job):**

1. **Fetch the full job log** via the v8 API on `api.gitcode.com`:
   - `GET .../actions/runs/<workflow_run_id>/jobs/<job_id>/download_log` returns a **ZIP file**
     with per-step `.log` files. Save to disk, `unzip`, then `tail -n 200` the relevant step log.
   - If ZIP download fails, try the paginated text endpoint:
     `POST .../actions/runs/<workflow_run_id>/jobs/<job_id>/logs` returns JSON with
     `{"has_more": bool, "start_offset": N, "end_offset": N, "log": "..."}`.
   - Only ask the user to paste the error from the browser UI as a last resort if both fail.

2. **Classify the error** by scanning the log tail for these categories:

   | Category | Signals in log | Action |
   |---|---|---|
   | **Needs human (static-check infra)** | `APIG.0303` / auth errors from `sca-pr-scan`, `openlibing`, `anti_poison`; "当前扫描仓库不在openlibing中"; credential/secret "not found"; "permission denied" on external services | Mark `needs_human`. Tell user exactly which secret/registration/quota is missing, referencing the FAQ entry. Do NOT attempt YAML fixes here — these are environment issues. |
   | **Resource allocation ("申请资源" stuck / no runner)** | Job stuck in "申请资源"/PENDING, "no available runner", label not matched, resource allocation error | FIRST verify `runs-on` labels (x64 vs arm64, exact spelling) — a wrong label is a YAML fix. If labels are correct, see faq.md #2: check resource pool quota/capacity and whether the org is on the **dedicate-hosted** whitelist (paid, whitelisted) vs **codearts-hosted** (free, no whitelist). Temporarily switching to `codearts-hosted` (x64) distinguishes a YAML problem from a whitelist/quota problem. Whitelist/quota → `needs_human`. |
   | **Bad substitution / input errors** | `bad substitution`, `Input required and not supplied`, `unrecognized input` | 95% of the time caused by entry workflow passing atomgit-defaulted inputs in `with:` (see conversion-rules.md §"do NOT re-pass parameters that already have atomgit defaults"). Fix the entry YAML, push, re-run. |
   | **Path / file not found** | `No such file or directory`, `script not found`, `command not found` for a script you referenced | FIRST check your own conversion: is a Category A script incorrectly moved to `scripts/`? Did a step split mis-place a `cd` (CWD bug — conversion-rules.md §"CWD tracking")? If yes, fix YAML. If the path is genuinely correct but file missing, check if it's a placeholder script — user needs to populate it. |
   | **Git / checkout errors** | `git version 2.17, minimum required is 2.18`; `Committer identity unknown`; merge conflicts | Apply known fixes from faq.md (git upgrade step; `git config user.name/email`). Fix YAML, push, re-run. |
   | **Container / image errors** | image pull backoff, `manifest unknown`, runner label not matched | Verify image string is literal in entry workflow (conversion-rules.md §"Container images must be literal strings"); verify `runs-on` labels. Fix YAML. |
   | **OBS / obsutil errors** | `AK/SK authentication failed`, `NoSuchBucket`, `obsutil: command not found` | Check secret names (`OBS_AK`/`OBS_SK`); check if `obsutil` is preinstalled in the image (it usually is in `mindx_arm:*` images — if not, add a download step). For auth failures, mark `needs_human` with guidance. |
   | **Other / unexpected** | Anything else | Attempt up to **3 fixes** (see below). |

3. **Fix-attempt budget**: For any one failing job, try at most **3 substantially different fixes**.
   "Substantially different" means changing different YAML, not retrying the same edit. If all 3
   fail, mark `known_limit` and capture the residual error verbatim so the user has a precise report.

4. **Apply the fix (CRITICAL — push to DEFAULT branch, not the test PR branch)**:

   **`pull_request_target` reads workflow YAML from the TARGET (default) branch, NOT from the PR
   source branch.** This is a deliberate security design in GitCode/GitHub Actions: it prevents
   untrusted PR code from modifying workflows that run with repo secrets. Therefore:

   - ❌ **Do NOT push YAML fixes only to the test PR branch** — the `pull_request_target` trigger
     will NOT see them; it will keep running the old YAML from the default branch.
   - ✅ **Push YAML fixes to the DEFAULT branch** (e.g., `master`). After the fix lands on
     default branch, re-trigger the pipeline by either:
     a. Pushing a new (trivial) commit to the test PR branch, or
     b. Posting a `/compile` comment on the PR (if `pull_request_comment` trigger is configured).
   - **Sub-workflow files** (`.build_job.yml`, `.ut_*.yml`, etc.) called via `uses: .gitcode/workflows/.xxx.yml`
     are also resolved from the default branch when triggered by `pull_request_target`, so they
     must also be fixed on the default branch.
   - **Scripts** in `.gitcode/workflows/scripts/` are checked out at runtime from the merged code,
     so script fixes DO take effect from the PR branch — only YAML workflow definitions are
     read from the target branch.

   Practical workflow:
   ```bash
   # Fix YAML on default branch
   git checkout master
   # ... edit the broken .yml file(s) ...
   git add .gitcode/workflows/
   git commit -m "fix(build): <describe the fix>"
   git push origin master

   # Re-trigger the pipeline by pushing to the PR branch
   git checkout master_test
   git commit --allow-empty -m "retrigger after fix"
   git push origin master_test
   ```

   Record each fix attempt in the per-job state with the commit SHA (on master) and a one-line
   rationale.

5. **After a fix**, wait for the next run (back to polling). If the job now passes, move to next job.
   If it fails differently, analyze the new error — this counts as the next attempt.

**Keep the user informed, but do not pause for permission on YAML fixes.** For each fix, send a
short progress line:
> `Build_arm failed with "No such file: build_merge.sh" — root cause: step split placed cd at workspace root instead of inside repo. Fixed in <sha>, re-running.`

Only pause and ask the user when:
- A job is marked `needs_human` (infra/secret/registration issues)
- The 3-attempt budget is exhausted for a job
- You need information the code/logs cannot provide (e.g. which branch the CI repo uses, an OBS bucket name you cannot infer)

**Step 4d — Final summary and skill feedback loop:**

When every job is resolved (success / needs_human / known_limit), produce a structured summary:

```
=== Test Run Summary for <repo> PR #<n> ===
Successful jobs:
  - Only_doc_commit_check ✅
  - SCA ✅
  - Antipoison ✅ (after 1 fix: added git upgrade step)
  - Build_arm ✅ (after 1 fix: corrected CWD in compile step)
  - UT_cpp ✅
Jobs requiring human action:
  - PreSmoke ⚠️  needs NPU runner not available in this org — see below
Known limits / unfixed after 3 attempts:
  - (none)

Fixes applied during this run (and already back-ported to the skill where appropriate):
  1. <short description> → added to references/faq.md
  2. ...

Next actions for you:
  - <action 1>
```

**Skill feedback loop — this is mandatory, not optional:**
For every fix that succeeded (i.e. the YAML change made a real job pass), ask yourself:
- Is this failure mode already documented in `references/faq.md`? If not, ADD IT with the exact
  error string, root cause, and the working fix.
- Is there a template (`templates/*.yml`) that produced the buggy pattern? UPDATE the template
  so future conversions generate correct YAML on the first try.
- Is a conversion rule in `references/conversion-rules.md` or `SKILL.md` missing or misleading?
  UPDATE IT.
- If a static-check plugin API changed (e.g. `gc_token` removed from `openlibing-pre-commit-action`),
  update `references/static-check-mapping.md`.

The goal is that the same failure never has to be diagnosed twice across conversions. Every
successful fix makes the next pipeline faster to convert and more likely to pass on the first run.

**Common error patterns and fixes:** See `references/faq.md` for the full, regularly-updated list of
known errors and their fixes (API gateway errors, OBS auth, input/env mistakes, git version issues,
openlibing configuration, git committer identity, bad substitution, stage-name special characters,
pre-commit plugin token deprecation, etc.). Consult that file FIRST when diagnosing test-run
failures — if the error is already there, apply the documented fix immediately instead of
re-deriving it.

## Reference Files

- `references/api-reference.md` — CodeArts API endpoints, headers, curl patterns
- `references/conversion-rules.md` — Detailed CodeArts→GitCode field mapping and patterns
- `references/static-check-mapping.md` — How to convert each type of static check task
- `references/secrets-mapping.md` — How CodeArts sensitive parameters map to GitCode secrets
- `references/faq.md` — Common error patterns, causes, and fixes (consult when debugging test runs)
- `templates/build_job.yml` — Scaffold for build sub-workflow
- `templates/ut_job.yml` — Scaffold for UT sub-workflow
- `templates/presmoke_job.yml` — Scaffold for presmoke sub-workflow
- `templates/clone_ci.yml` — (DEPRECATED) Historical scaffold for CI-repo clone pattern, which is now eliminated
- `templates/entry_pipeline.yml` — Scaffold for PR-pipeline_full.yml entry file

## Important Context from Real-World Conversion Experience

These lessons come from converting actual production pipelines:

1. **Always base templates on real examples** — the reference conversion at
   `https://gitcode.com/ComputingActionTest/mind-cluster/tree/master/.gitcode/workflows` is the
   canonical pattern. Study it before generating YAML.
2. **Clone-CI-repo tasks are eliminated** — CI scripts move into the repo under `.gitcode/workflows/scripts/`.
3. **md_check is always needed** — preserves the "skip build for doc-only PRs" optimization.
4. **Static checks use plugins where available** — avoids reimplementing complex analysis in scripts.
5. **Build/UT jobs become reusable sub-workflows** — keeps the entry file clean and enables reuse.
6. **CI scripts co-located in the repo** — shared scripts go under `scripts/`, first-call scripts get "digested" inline. When a CI repo is private and the script cannot be fetched, place an empty placeholder file so the YAML path is valid.
7. **Non-default-branch PRs need the scripts fallback** — clone default branch and copy `scripts/` dir.
8. **Parameters: atomgit context first, secrets for credentials** — never hardcode tokens; use `${{ secrets.XXX }}`.
9. **CWD does not persist across run steps** — each `run:` block starts at workspace root. When splitting a single heredoc into named steps, trace the original CWD line-by-line and start each step with an explicit `cd` to the correct absolute path. A path bug introduced by careless splitting (e.g. `mkdir opensource` at workspace root instead of inside the dev repo clone) is a silent failure that corrupts the build.
