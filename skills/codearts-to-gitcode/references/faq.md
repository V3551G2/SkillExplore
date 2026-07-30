# FAQ — Common Issues and Fixes

This file collects common errors encountered when running converted GitCode workflows and their fixes.
Reference this file from SKILL.md and other references instead of duplicating error tables.

## Table of Contents

1. [API Gateway authentication errors](#api-gateway-authentication-errors)
2. [Resource allocation / pending jobs](#resource-allocation--pending-jobs)
3. [OBS AK/SK authentication failures](#obs-aksk-authentication-failures)
4. [Input required and not supplied](#input-required-and-not-supplied)
5. [Script not found after cd chain](#script-not-found-after-cd-chain)
6. [SCA/pre-commit plugin auth errors](#scapre-commit-plugin-auth-errors)
7. [Git version too old for checkout](#git-version-too-old-for-checkout)
8. [Container image resolution failure in entry workflow](#container-image-resolution-failure-in-entry-workflow)
9. [SCA: repo not in openlibing](#sca-repo-not-in-openlibing)
10. [Git merge: committer identity unknown](#git-merge-committer-identity-unknown)

---

## API Gateway authentication errors

**Error message:**
`APIG.0303: Incorrect app authentication information: Access or Credential is empty in Authorization`

**Cause:** API Gateway credentials (APPID/SECRETKEY) are missing or wrong in repo Settings.

**Fix:** Verify these secrets are configured in GitCode repo Settings → Secrets:
- `APPID_TASK_ANTI`, `SECRETKEY_TASK_ANTI`, `APPID_STATUS_ANTI`, `SECRETKEY_STATUS_ANTI` for Antipoison
- Other API-gateway-protected jobs may have different suffixes

---

## Resource allocation / pending jobs

**Error message:** Task stuck in "申请资源" (requesting resources) / pending state indefinitely.

**Cause:** `runs-on` label is wrong, or the resource pool has no available runners.

**Fix:**
- Verify `runs-on` labels match available runners: `dedicate-hosted`, `codearts-hosted`, `x64`, `arm64`, `large`, `npu`
- Check resource pool quota and runner availability

---

## OBS AK/SK authentication failures

**Error message:** `AK/SK authentication failed (HTTP 403, Code: InvalidAccessKeyId)`

**Cause:** OBS credentials are wrong, missing, or the key lacks access to the target bucket.

**Fix:** Check `OBS_AK` / `OBS_SK` secrets are correct and have permission on the `mindx-package` bucket
(or the bucket used in `obs-upload` steps).

---

## Input required and not supplied

**Error message:** `Input required and not supplied: xxx`

**Cause:** In the entry workflow (`PR-pipeline_full.yml`), system context values are defined under
`inputs:` with `${{ atomgit... }}` defaults. For PR-triggered workflows, GitCode does NOT populate
`inputs` from context — inputs are treated as caller-supplied parameters.

**Fix:** Define atomgit-derived values in the entry workflow's `env:` block, not `inputs:`. Reference
them as `${{ env.XXX }}` in jobs. Sub-workflows (`.build_job.yml`, etc.) CAN use `inputs:` because
they are called via `uses:` / `with:` which passes values explicitly.

---

## Script not found after cd chain

**Error message:** `Script not found (No such file or directory)` or bash: `.../script.sh: No such file or directory`

**Cause:** CWD (working directory) drifted during a sequence of `cd` commands, or the conversion
incorrectly moved a Category A script path.

**Fix:**
- Trace original `cd` paths carefully through the CodeArts command
- Category A scripts (in the dev repo, e.g. `script/compile.sh`) stay in their original paths —
  do NOT move them to `scripts/`
- When splitting a single heredoc into multiple `run:` steps, each step starts fresh at
  `${ATOMGIT_WORKSPACE}`. Always start a step with an explicit `cd <absolute-path>` to the correct
  directory (see conversion-rules.md "CWD tracking when splitting into steps").

---

## SCA/pre-commit plugin auth errors

**Error message:** Authentication failures from `sca-pr-scan` or `openlibing-pre-commit-action` plugins.

**Cause:** Plugin secrets not configured in repo Settings.

**Fix:**
- For SCA: add `SCAN_ACCESS_KEY`, `SCAN_SECRET_KEY`
- For pre-commit: add `ACCESS_QK`

---

## Git version too old for checkout

**Error message:**
`git version 2.17.1, minimum required is 2.18` (during checkout action)

**Cause:** Some older SWR container images ship with git 2.17, below the `checkout` action's
minimum of 2.18. Not all images have this problem — only specific older ones.

**Fix:** Add the "git upgrade" step **before** checkout, but ONLY for jobs whose container image
is known to ship old git. This is a conditional fix, NOT a universal step:

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

**Images that need it:**
- `swr.*.myhuaweicloud.com/huawei-ascend/demo_mindx:*` — old Ubuntu base, git 2.17
- `swr.*.myhuaweicloud.com/ascend-mindx/mindx_x86:mindxdl_*` (older tags, pre-2024)

**Images that do NOT need it (do NOT add):**
- `*/mindspore/mindspore_python*` — recent Python images
- `*/pytorch_images_x86/*` — recent git
- `*/modelfoundry/karmada:*` — discarded (unified resource pool pattern)
- Any image dated 2024+ or based on Ubuntu 20.04+ / Debian 11+

When in doubt, omit the step — the user will report the error on a specific job if it occurs. The
step adds 30-60 seconds, so adding it universally wastes time.

---

## Container image resolution failure in entry workflow

**Error message:** Container image fails to resolve / pull, or workflow errors on `${{ env.xxx }}` in `image:` field.

**Cause:** In the **entry workflow**, `container: image:` must be a literal string URL, not an
`${{ env.XXX }}` reference. Container image resolution happens before env vars are fully evaluated.

**Fix:** Use literal image URLs directly in the entry workflow:

```yaml
# WRONG:
env:
  img_anti: "swr..../demo_mindx:..."
jobs:
  Antipoison:
    container:
      image: ${{ env.img_anti }}     # FAILS

# RIGHT:
jobs:
  Antipoison:
    container:
      image: "swr.cn-north-4.myhuaweicloud.com/huawei-ascend/demo_mindx:mindxdl_20230912_1"
```

Sub-workflows (`.build_job.yml` etc.) can use `${{ inputs.IMAGE_FLAG }}` because their image is
passed by the caller via `with:`.

---

## SCA: repo not in openlibing

**Error message:**
`当前扫描仓库不在openlibing中，请前往openlibing进行配置：https://www.openlibing.com/helpCenter?id=136`

**Cause (one of):**
1. The repository has not been registered in the openlibing platform.
2. The `project-name` input passed to the `sca-pr-scan` plugin does not match the project control
   name used when the repo was added to openlibing.

**Fix:**
1. Check whether the repository is registered on https://www.openlibing.com/.
2. If it is, verify that the `project-name` parameter to `sca-pr-scan` matches the project control
   name from openlibing exactly (case-sensitive, whitespace-sensitive).

```yaml
- name: Run SCA PR Scan
  uses: sca-pr-scan
  with:
    project-name: <exact project control name from openlibing>   # NOT an arbitrary display name
```

---

## Git merge: committer identity unknown

**Error message:**
```
Committer identity unknown
*** Please tell me who you are.
Run:
  git config --global user.email "you@example.com"
  git config --global user.name "Your Name"
to set your account's default identity.
```

**Cause:** When running `git merge` to apply the PR to the target branch, git requires a configured
user identity. Fresh containers have no global gitconfig.

**Fix:** Before the `git merge` command, configure the identity:

```bash
git config --global user.name AtlasAccount
git config --global user.email AtlasAccount@noreply.gitcode.com
git merge --no-edit pr_${{ inputs.pr_id }}
```

Include these `git config` lines in the clone/merge step of all build/UT/presmoke sub-workflows,
immediately after `git checkout -b new_${TARGET_BRANCH}` and before `git merge`.
