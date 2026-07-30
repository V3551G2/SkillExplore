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
   `openlibing-pre-commit-action`; Antipoison has no plugin and must run as container + python script;
   CodeCheck uses `codecheck_gitcode_v2`; SAST runs as container+script.

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

7. **Images:** Use `CP_docker_image` parameter value (the REAL container image), NOT the SWR step's
   `properties.image` which is often the CodeArts karmada wrapper. Extract image tag for `IMAGE_FLAG`.
   Define images as `env` variables in the entry workflow for easy maintenance.

   **CRITICAL — Script classification:** When converting shell commands, distinguish two script types
   (see `references/conversion-rules.md` for details):
   - **Category A** — Scripts in the target repo (e.g., `script/test.sh`, `run_presmoke.sh`): available after `git clone`, no migration needed
   - **Category B** — Scripts from the external CI repo (e.g., `compile.sh`, `codesca.py`, `anti_poison.py`, `ci_build.sh`): MUST be migrated to `.gitcode/workflows/scripts/`. Eliminate OBS download steps for CI scripts; reference them from the in-repo scripts/ directory. When fetching CI script content, try downloading from the CI repo first; if the repo is private/inaccessible, create an empty placeholder file with the same name in scripts/ so the YAML path is valid and the user can populate it manually.

8. **Artifact upload:** Replace CodeArts OBS upload steps with GitCode's `obs-upload` action.
   Replace CodeArts "下载文件管理的文件" (file download) steps with appropriate fetch logic.

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

### Phase 4 (Optional): Push to GitCode, Verify, Fix (closed loop)

If the user provides:
- A **test organization** (e.g., `https://gitcode.com/ComputingActionTest`)
- A **GitCode access token** with repo creation/push permissions

Then proceed with the following optional closed-loop steps. Reference: https://gitcode.com/gitcode-cli/skills

**Step 4a — Push YAML to fork repository:**
1. Create a fork repo in the test organization with the same name as the pipeline's source repo
   (from `sources.git_url`, e.g., `Ascend/AgentSDK` → create `AgentSDK` in test org).
2. Sync the default branch code from `sources.git_url` to the fork repo's default branch.
3. Commit generated `.gitcode/workflows/*.yml` and `.gitcode/workflows/scripts/*` to the fork default branch.
4. Remind the user to perform these post-push setup steps in the fork repo:

   a. **Configure required secrets** in repo Settings → Secrets and variables → Actions.
   b. **Enable Actions**: Project Settings → Enable Actions → Save.
   c. **Enable PR pre-merge**: Project Settings → Repository Management / Repository Settings → select "Merge Request PR Pre-Merge" (合并请求PR预合并) → Save.
      This is required for `pull_request_target` triggers and PR pre-merge behavior to work correctly.

**Step 4b — Verify / Validate:**
1. Create a test branch `<default_branch>_test` from default branch.
2. Simulate file changes (add a file or modify comments in existing files) to trigger all jobs.
3. Create a PR (`<default_branch>_test` → default branch).
4. Monitor pipeline execution. Re-trigger by pushing updates or adding `/compile` PR comment.
5. Check results for each job.

**Step 4c — Fix Issues:**
1. Determine if error is from generated YAML or environment/secrets.
2. If YAML bug: fix YAML, push fix, re-run test PR. Update this skill with the lesson.
3. If environment issue: report to user with guidance.

**Common error patterns and fixes:** See `references/faq.md` for the full, regularly-updated list of
known errors and their fixes (API gateway errors, OBS auth, input/env mistakes, git version issues,
openlibing configuration, git committer identity, etc.). Consult that file when diagnosing test-run
failures rather than re-deriving fixes from scratch.

After fixing an error, summarize the root cause and add it to `references/faq.md` so future conversions benefit.

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
