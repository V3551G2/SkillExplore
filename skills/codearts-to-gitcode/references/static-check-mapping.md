# Static Check Task Conversion Mapping

This reference describes how to convert each type of static analysis / code check job found in
CodeArts pipelines to GitCode equivalents.

## Decision Tree

1. Does a GitCode plugin exist for this check type? → **ALWAYS use the plugin** — this is mandatory, not optional. Plugins are maintained by GitCode and handle authentication, reporting, and PR status integration automatically.
2. No plugin available? → Run as a container step with the original script
3. Custom CodeArts plugin with no GitCode equivalent? → Reimplement as container + script

**Plugins available (MUST use these, NOT container+script):**
| Check | Plugin | Key Inputs |
|---|---|---|
| SCA | `sca-pr-scan` | scan-access-key, scan-secret-key, pr-id, repository-name |
| pre-commit | `openlibing-pre-commit-action` | (none — `gc_token` no longer required as of 2026-07) |
| CodeCheck (CodeArts) | `codecheck_gitcode_v2` | project_id, task_name, branch |

**No plugin available (use container+script):** Antipoison, SAST (AI-Check)

## Per-Check Mapping

### SCA (Software Composition Analysis)

**CodeArts pattern**: CloudBuild job running `python3 mindx_ci/mindxdl/script/codesca.py` with
scan access/secret keys.

**GitCode conversion**: Use the `sca-pr-scan` plugin.

```yaml
SCA:
  name: SCA
  runs-on: [ 'codearts-hosted', 'ubuntu-latest', 'x64', 'large' ]
  steps:
    - name: checkout
      uses: checkout
      with:
        ref: ${{ atomgit.event.pull_request.merge_commit_sha || '' }}
    - name: Run SCA PR Scan
      id: sca-pr-scan
      uses: sca-pr-scan
      with:
        scan-access-key: ${{ secrets.SCAN_ACCESS_KEY }}
        scan-secret-key: ${{ secrets.SCAN_SECRET_KEY }}
        pr-id: ${{ atomgit.event.pull_request.number }}
        repository-name: ${{ atomgit.repository }}
        project-name: <project_display_name>
```

**Secrets needed**: `SCAN_ACCESS_KEY`, `SCAN_SECRET_KEY`

**Troubleshooting — "当前扫描仓库不在openlibing中" error**:
If the SCA task fails with `当前扫描仓库不在openlibing中，请前往openlibing进行配置：
https://www.openlibing.com/helpCenter?id=136`, the fix is:
1. Check whether the repository has been registered in the openlibing platform.
2. If it is registered, verify that the `project-name` parameter value passed to `sca-pr-scan`
   exactly matches the project control name used when the repo was added in openlibing.
   A mismatch between these two names causes this error.

### pre-commit (Git hooks / linting)

**CodeArts pattern**: CloudBuild job in a Python container running pre-commit hooks, gitleaks, etc.

**GitCode conversion**: Use `openlibing-pre-commit-action` plugin.

**NOTE (verified 2026-07)**: The `openlibing-pre-commit-action` plugin no longer requires
the `gc_token` parameter. Do NOT pass it — passing it can cause plugin errors on newer
plugin versions. The plugin authenticates automatically via the workflow's built-in
context. Simply call it with no `with:` block, or an empty one.

```yaml
pre_commit:
  name: pre_commit
  runs-on: [ 'codearts-hosted', 'ubuntu-latest', 'x64', 'large' ]
  container:
    image: swr.<region>.myhuaweicloud.com/<org>/<python_image>
    options: --user root
  steps:
    - name: checkout
      uses: checkout
      with:
        ref: ${{ atomgit.event.pull_request.merge_commit_sha || '' }}
    - name: gitleaks install
      run: |
        wget -q --no-host-directories -c --no-check-certificate <gitleaks_url>
        chmod +x gitleaks
    - name: setup python
      run: |
        ln -sf /usr/local/bin/python3.<version> /usr/bin/python
        python --version
    - name: run pre-commit
      uses: openlibing-pre-commit-action
```

Adjust Python version symlink based on the container image's available Python.

### CodeCheck (CodeArts CodeCheck service)

**CodeArts pattern**: CloudBuild job invoking CodeArts CodeCheck service.

**GitCode conversion**: Use `codecheck_gitcode_v2` plugin with CodeArts login.

```yaml
CodeCheck:
  name: CodeCheck
  runs-on: [ 'codearts-hosted', 'ubuntu-latest', 'x64', 'large' ]
  steps:
    - name: Login to CodeArts
      uses: codearts-login
      with:
        region: cn-north-4
        name: "<hwstaff_account>"
        password: ${{ secrets.IAM_USER_PASSWORD }}
        domain-name: "<domain>"
    - name: codecheck
      uses: codecheck_gitcode_v2
      with:
        project_id: <codearts_project_id>
        task_name: <codecheck_task_name>
        branch: ${{ atomgit.event.pull_request.base.ref }}
```

Note: If the original pipeline comments out CodeCheck or it's optional, consider commenting it
in the generated YAML too.

### Antipoison (Anti-poison / malicious code scan)

**CodeArts pattern**: CloudBuild job running `python3 mindx_ci/mindxdl/script/anti_poison.py`
with API gateway credentials. The `anti_poison.py` script actually comes from the CI repo.

**GitCode conversion**: NO PLUGIN available — run as container + script. Carry `anti_poison.py`
in the repo under `.gitcode/workflows/scripts/`.

**Script acquisition during conversion**: When generating output files, you must also produce
the script file itself in `.gitcode/workflows/scripts/anti_poison.py`. Process:

1. Construct the raw download URL from the CI repo clone URL found in the CodeArts job.
   For example, if the job clones `https://gitcode.com/Ascend/MindCluster-CI.git`, the raw URL
   is `https://gitcode.com/Ascend/MindCluster-CI/raw/branch/master/mindxdl/script/anti_poison.py`.
2. Try to `curl -sSL` or `wget -q` that URL (no credentials — this tests public accessibility).
3. If the download succeeds (HTTP 200, file has real content) → write the downloaded content
   to `scripts/anti_poison.py` in the output directory.
4. If the download fails (HTTP 404/403, timeout, private repo) → create an empty placeholder
   file at `scripts/anti_poison.py` (zero bytes or a comment line like `# PLACEHOLDER: download anti_poison.py from the CI repo manually`) and note in the summary that it is a placeholder.

This "try download, fall back to empty placeholder" pattern applies to ALL Category B scripts
from CI repos, not just anti_poison.py.

```yaml
Antipoison:
  name: Antipoison
  runs-on: [ 'codearts-hosted', 'ubuntu-latest', 'x64', 'large' ]
  container:
    image: swr.cn-north-4.myhuaweicloud.com/huawei-ascend/demo_mindx:mindxdl_20230912_1
    options: --user root
  steps:
    # (Optional) Add "git upgrade" step here ONLY if this image has old git (< 2.18).
    # See "When to add the git upgrade step" below. demo_mindx images need it; newer images do not.
    - name: git upgrade          # include this step ONLY for known-old images like demo_mindx:*
      run: |
        apt-get update
        apt-get install -y software-properties-common
        add-apt-repository ppa:git-core/ppa -y
        apt-get update
        apt-get install -y git
        git --version
    - name: checkout
      uses: checkout
      with:
        ref: ${{ atomgit.event.pull_request.merge_commit_sha || '' }}
    - name: Antipoison
      run: |
        set -ex
        pip3 install requests
        # apig_sdk (Huawei Cloud API Gateway signing SDK) is carried in-repo
        # under scripts/apig_sdk/ because Huawei Cloud containers cannot access
        # PyPI/GitHub (network restricted). Add scripts/ to PYTHONPATH.
        export PYTHONPATH="${ATOMGIT_WORKSPACE}/.gitcode/workflows/scripts:${PYTHONPATH}"
        python3 .gitcode/workflows/scripts/anti_poison.py \
          --repo ${{ env.REPO_NAME }} \
          --pr_id ${{ env.PR_ID }} \
          --appId_task ${{ secrets.APPID_TASK_ANTI }} \
          --secretKey_status ${{ secrets.SECRETKEY_STATUS_ANTI }} \
          --secretKey_task ${{ secrets.SECRETKEY_TASK_ANTI }} \
          --appId_status ${{ secrets.APPID_STATUS_ANTI }}
```

**Key points**:
- The `anti_poison.py` script must be placed in `.gitcode/workflows/scripts/` (NOT `build/`).
- **Carry `apig_sdk/` in-repo**: anti_poison.py imports `from apig_sdk import signer` for AK/SK
  request signing. Place the apig_sdk Python package at `.gitcode/workflows/scripts/apig_sdk/`
  with a correct `signer.py` (Huawei Cloud APIG HMAC-SHA256 signing). Pip install from PyPI/GitHub
  fails in Huawei Cloud containers due to network restrictions, so carrying it in-repo is the
  reliable approach. Use `export PYTHONPATH="${ATOMGIT_WORKSPACE}/.gitcode/workflows/scripts:${PYTHONPATH}"`
  before running the script.
- When generating the script file during conversion, attempt download from CI repo; create empty
  placeholder if inaccessible (private repo).
- **Do NOT blindly add the "git upgrade" step** to every job. It is a fix for a specific failure
  (checkout error: git 2.17 < 2.18 minimum). See the "When to add the git upgrade step" section
  below for when it is actually needed.

**Secrets needed**: `APPID_TASK_ANTI`, `SECRETKEY_STATUS_ANTI`, `SECRETKEY_TASK_ANTI`,
`APPID_STATUS_ANTI` (note: `ATLAS_PASSWORD` is no longer needed since we no longer clone the CI repo at runtime).
If Antipoison fails with `APIG.0303: verify signature fail`, it means the APIG credentials are
missing or incorrect in repo Settings → Secrets — this is a `needs_human` configuration issue,
not a YAML bug.

### SAST (Static Application Security Testing / AI-Check)

**CodeArts pattern**: CloudBuild job cloning AI-Check repo and running `bash check.sh`.

**GitCode conversion**: No plugin — run as container + script.

```yaml
SAST:
  name: PR-SAST-check
  runs-on: [ 'codearts-hosted', 'ubuntu-latest', 'x64', 'large' ]
  container:
    image: swr.<region>.myhuaweicloud.com/<org>/<sast_image>
    options: --user root
  steps:
    - name: checkout
      uses: checkout
      with:
        ref: ${{ atomgit.event.pull_request.merge_commit_sha || '' }}
    - name: checkout AI-Check
      run: |
        set -x
        git clone -b main https://gitcode.com/TuBee/AI-Check.git AI-Check
    - name: run check
      run: |
        set -x
        export ACCESS_TOKEN="${{ secrets.ACCESS_QK }}"
        export __repository__="${{ inputs.REMOTE_URL }}"
        cd ${ATOMGIT_WORKSPACE}/AI-Check
        bash check.sh
```

### CodeCheck_pre-commit (CodeArts CodeCheck with pre-commit)

This is often a CodeArts-specific CodeCheck task. It may use the same CodeArts CodeCheck service.
If the CodeArts job name contains "codecheck" or "pre-commit" and runs in a Docker container,
examine the script to determine whether it:
1. Calls CodeArts CodeCheck API → map to `codecheck_gitcode_v2` plugin
2. Runs local pre-commit hooks → map to `openlibing-pre-commit-action` plugin
3. Runs custom scripts → convert to container + script

## When to add the "git upgrade" step

The `checkout` action requires git ≥ 2.18. Some older SWR container images ship with git 2.17
(ancient Ubuntu base). When checkout runs on such an image it fails with:

> `git version 2.17.1, minimum required is 2.18`

**This is an image-specific issue, NOT something to add to every job.** Default behavior: **do NOT
add the git upgrade step.** Only add it when BOTH are true:

1. The job uses a `container:` with an image that is known or suspected to ship git < 2.18.
2. There is no host-level checkout (i.e. the checkout runs INSIDE the container, not on the runner).

**Known images that need git upgrade** (based on real-world failures):
- `swr.*.myhuaweicloud.com/huawei-ascend/demo_mindx:*` — old Ubuntu, git 2.17
- `swr.*.myhuaweicloud.com/ascend-mindx/mindx_x86:mindxdl_*` — most older tags have git 2.17

**Known images that do NOT need it** (do NOT add):
- `swr.*.myhuaweicloud.com/mindspore/mindspore_python*` — Python 3.11 image, recent git
- `swr.*.myhuaweicloud.com/pytorch_images_x86/pytorchx86:*` — recent git
- `swr.cn-southwest-2.myhuaweicloud.com/modelfoundry/karmada:latest` — discarded entirely (unified pool)
- Any image dated 2024 or later, or images based on Ubuntu 20.04+ / Debian 11+

When in doubt, omit the step. If the user later reports the `git version 2.17.1` error on a
specific job, add the step then. The snippet to add (immediately before `checkout`):

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

This adds ~30-60 seconds to the job, which is why it should be conditional rather than universal.

## General Pattern for Container + Script Checks

When no plugin exists:

```yaml
<JobName>:
  name: <DisplayName>
  runs-on: [ 'codearts-hosted', 'ubuntu-latest', 'x64', 'large' ]
  container:
    image: <image from CodeArts job properties.image>
    options: --user root
  steps:
    - name: checkout
      uses: checkout
      with:
        ref: ${{ atomgit.event.pull_request.merge_commit_sha || '' }}
    - name: <step name>
      run: |
        <adapted command from CodeArts properties.command>
```

Key adaptations when converting the command:
1. Replace `${WORKSPACE}` with `${ATOMGIT_WORKSPACE}`
2. Replace `${pr_id}` with `${{ inputs.pr_id }}` or `${{ atomgit.event.pull_request.number }}`
3. Replace sensitive parameter references with `${{ secrets.PARAM_NAME }}`
4. Replace CI repo clones (`git clone ... mindx_ci`) with references to the in-repo `scripts/` directory
5. Remove wget/download steps for CI scripts (they're now in the repo under `.gitcode/workflows/scripts/`)
6. Keep any wget for external dependencies (SDKs, tools)
