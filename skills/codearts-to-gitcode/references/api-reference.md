# CodeArts API Reference for Pipeline Conversion

All API calls use `curl` (or `curl.exe` on Windows) with session cookie authentication.

## Base URLs

| Service | Base URL |
|---|---|
| CodeArts Pipeline | `https://devcloud.{region}.huaweicloud.com/cicd/` |
| CodeCI (Build Jobs) | `https://devcloud.{region}.huaweicloud.com/codeci/` |

Region is typically `cn-north-4`. Extract from cookie: search for `*_cfProjectName=<region>`.

## Required Headers

Every API call MUST include these headers. Without them you get SPA HTML instead of JSON.

```bash
COOKIES="<full cookie string from user>"
CFTK=$(echo "$COOKIES" | grep -oP 'devclouddevuibjtcftk=\K[^;]+')
REGION=$(echo "$COOKIES" | grep -oP 'cfProjectName=\K[^;]+')
BASE="https://devcloud.${REGION}.huaweicloud.com"
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
```

### PowerShell equivalent

```powershell
$cookies = "<full cookie string>"
if ($cookies -match 'devclouddevuibjtcftk=([^;]+)') { $cftk = $Matches[1] }
if ($cookies -match 'cfProjectName=([^;]+)') { $region = $Matches[1] } else { $region = 'cn-north-4' }
$base = "https://devcloud.${region}.huaweicloud.com"
$headers = @{
    'Cookie' = $cookies
    'X-Requested-With' = 'XMLHttpRequest'
    'cftk' = $cftk
    'Accept' = 'application/json'
    'language' = 'zh-cn'
    'projectname' = $region
    'User-Agent' = 'Mozilla/5.0'
}
# Use curl.exe (not Invoke-RestMethod, which has TLS/cert issues on some systems)
```

### Common header mistakes

| Wrong | Correct | Why |
|---|---|---|
| `x-cftk: <token>` | `cftk: <token>` | Header name is `cftk`, not `x-cftk` |
| Missing `X-Requested-With` | `X-Requested-With: XMLHttpRequest` | Without it, returns SPA HTML |
| Missing `cftk` header | Include `cftk` | POST fails with csrf error |

## URL Parsing

Given a pipeline URL like:
```
https://devcloud.cn-north-4.huaweicloud.com/cicd/project/609138a9ed7049aa975c6b857c7234fc/pipeline/history/a2b7cd2199c14d0c97389ece5a6258d1?v=1
```

Extract:
- `project_id`: `609138a9ed7049aa975c6b857c7234fc` (hex after `/project/`)
- `pipeline_id`: `a2b7cd2199c14d0c97389ece5a6258d1` (hex after `/pipeline/history/` or `/pipeline/detail/`)

Regex patterns:
- `/project/([0-9a-f]{32})` → project_id
- `/pipeline/(?:history|detail)/([0-9a-f]{32})` → pipeline_id

## API Endpoints for Pipeline Conversion

### 1. Get Pipeline Detail

```bash
GET /cicd/v5/internal/<project_id>/pipelines/<pipeline_id>
```

Returns the full pipeline object:
```json
{
  "id": "<pipeline_id>",
  "name": "PR-pipeline_AgentSDK",
  "definition": "<JSON string — see below>",
  "sources": [...],
  "variables": [
    {"name": "repo", "default_value": "...", "is_secret": false},
    {"name": "pr_id", "default_value": "...", "is_secret": false}
  ],
  "triggers": [...]
}
```

**CRITICAL**: The `definition` field is a JSON-encoded STRING, not a nested object. Parse it again:
```python
import json
pipeline = json.loads(response_text)
definition = json.loads(pipeline['definition'])
```

```powershell
$pipeline = $response | ConvertFrom-Json
$definition = $pipeline.definition | ConvertFrom-Json
```

#### Definition structure

```json
{
  "stages": [
    {
      "name": "prepare",
      "sequence": 0,
      "jobs": [
        {
          "name": "md_check",
          "exec_type": "OCTOPUS_JOB",
          "depends_on": [],
          "steps": [
            {
              "task": "md_check@0.0.7",
              "name": "md_check",
              "inputs": [
                {"key": "some_key", "value": "some_value"}
              ],
              "enable": true
            }
          ]
        }
      ]
    }
  ]
}
```

**For cloud build jobs**, the step looks like:
```json
{
  "task": "official_devcloud_cloudBuild",
  "name": "Build_arm",
  "inputs": [
    {"key": "__sameProject__", "value": "true"},
    {"key": "__projectId__", "value": ""},
    {"key": "jobId", "value": "2e52a0a5f56349188416c1fdeffd92a4"},
    {"key": "__repository__", "value": "<repo_name>"},
    {"key": "artifactIdentifier", "value": ""}
  ],
  "enable": true
}
```

The `jobId` input value is the CodeCI job ID to fetch in step 2.

**For custom plugin tasks** (like md_check):
```json
{
  "task": "md_check@0.0.7",
  "name": "md_check",
  "inputs": [...],
  "enable": true
}
```

**For shell plugin tasks**:
```json
{
  "task": "official_shell_plugin",
  "name": "执行Shell",
  "inputs": [...],
  "enable": true
}
```

### 2. Get CodeCI Job Config

```bash
GET /codeci/v1/job/<job_id>/config?get_all_params=true
```

Returns:
```json
{
  "result": {
    "job_id": "<job_id>",
    "job_name": "Pooling_AgentSDK_Build_arm",
    "arch": "x86-64",
    "host_type": "devcloud",
    "build_environment_type": "docker",
    "build_config_type": "ACTION",
    "steps": [
      {
        "module_id": "devcloud2018.codeci_action_20017.action",
        "name": "执行shell命令",
        "enable": true,
        "properties": {
          "image": "shell4.2.46-git1.8.3-zip6.00",
          "command": "cat > shell.sh <<- 'EOF'\n...\nEOF",
          "preCondition": "SUCCESS"
        }
      },
      {
        "module_id": "devcloud2018.codeci_action_20028.action",
        "name": "使用SWR公共镜像",
        "enable": true,
        "properties": {
          "image": "swr.cn-north-4.myhuaweicloud.com/modelfoundry/karmada:latest",
          "command": "/workspace/workflowtool/entrypoint.sh\n...",
          "preCondition": "SUCCESS"
        }
      }
    ],
    "parameters": [
      {
        "name": "hudson.model.StringParameterDefinition",
        "params": [
          {"name": "name", "value": "gitcode_token"},
          {"name": "type", "value": "normalparam"},
          {"name": "defaultValue", "value": "<encrypted>"},
          {"name": "sensitiveVar", "value": "true"}
        ]
      }
    ],
    "cluster_selected": {
      "id": "<cluster_uuid>",
      "name": "<cluster_name>",
      "resource_type": "self-hosted"
    }
  }
}
```

#### Step module_id reference

| module_id | Chinese Name | Purpose |
|---|---|---|
| `devcloud2018.codeci_action_20017.action` | 执行shell命令 | Execute shell commands (host-level shell) |
| `devcloud2018.codeci_action_20028.action` | 使用SWR公共镜像 | Run commands inside a Docker container from SWR |
| `devcloud2018.codeci_action_20004.action` | 制作镜像并推送到SWR仓库 | Build and push Docker image to SWR |
| `devcloud2018.codeci_action_20057.action` | 上传文件到OBS | Upload files to OBS |
| `devcloud2018.codeci_action_20061.action` | 下载文件管理的文件 | Download files from file management |
| `devcloud2018.codeci_action_20018.action` | 上传软件包到软件发布库 | Upload to release repo |
| `devcloud2018.codeci_action_20035.action` | 执行Docker命令 | Execute Docker commands |
| `devcloud2018.codeci_action_20005.action` | CMake构建 | CMake build |

## Cookie Parsing Reference

```bash
# Extract CFTK (CSRF token)
CFTK=$(echo "$COOKIES" | grep -oP 'devclouddevuibjtcftk=\K[^;]+')

# Extract domain_tag (domain ID)
DOMAIN_ID=$(echo "$COOKIES" | grep -oP 'domain_tag=\K[^;]+')

# Extract region from cfProjectName cookie
REGION=$(echo "$COOKIES" | grep -oP 'cfProjectName=\K[^;]+')
```

## PowerShell: Complete Fetch Pipeline

```powershell
# Setup
$cookies = "<from user>"
$cftk = [regex]::Match($cookies, 'devclouddevuibjtcftk=([^;]+)').Groups[1].Value
$region = if ($cookies -match 'cfProjectName=([^;]+)') { $Matches[1] } else { 'cn-north-4' }
$base = "https://devcloud.${region}.huaweicloud.com"
$projectId = "<from URL>"
$pipelineId = "<from URL>"

# 1. Fetch pipeline
$pipelineJson = & curl.exe -sk -H "Cookie: $cookies" -H "X-Requested-With: XMLHttpRequest" `
    -H "cftk: $cftk" -H "Accept: application/json" -H "language: zh-cn" `
    -H "projectname: $region" -H "User-Agent: Mozilla/5.0" `
    "$base/cicd/v5/internal/$projectId/pipelines/$pipelineId"
$pipeline = $pipelineJson | ConvertFrom-Json
$definition = $pipeline.definition | ConvertFrom-Json

# 2. Collect job IDs
$jobIds = @()
foreach ($stage in $definition.stages) {
    foreach ($job in $stage.jobs) {
        foreach ($step in $job.steps) {
            if ($step.task -eq "official_devcloud_cloudBuild") {
                foreach ($inp in $step.inputs) {
                    if ($inp.key -eq "jobId" -and $inp.value) {
                        $jobIds += @{name=$job.name; id=$inp.value}
                    }
                }
            }
        }
    }
}

# 3. Fetch each job config
foreach ($j in $jobIds) {
    $jobJson = & curl.exe -sk -H "Cookie: $cookies" -H "X-Requested-With: XMLHttpRequest" `
        -H "cftk: $cftk" -H "Accept: application/json" -H "language: zh-cn" `
        -H "projectname: $region" -H "User-Agent: Mozilla/5.0" `
        "$base/codeci/v1/job/$($j.id)/config?get_all_params=true"
    $jobConfig = $jobJson | ConvertFrom-Json
    # Process jobConfig.result...
}
```

## Bash: Complete Fetch Pipeline

```bash
#!/bin/bash
COOKIES="<from user>"
CFTK=$(echo "$COOKIES" | grep -oP 'devclouddevuibjtcftk=\K[^;]+')
REGION=$(echo "$COOKIES" | grep -oP 'cfProjectName=\K[^;]+')
BASE="https://devcloud.${REGION}.huaweicloud.com"
PROJECT_ID="<from URL>"
PIPELINE_ID="<from URL>"

HEADERS=(
    -H "Cookie: $COOKIES"
    -H "X-Requested-With: XMLHttpRequest"
    -H "cftk: $CFTK"
    -H "Accept: application/json"
    -H "language: zh-cn"
    -H "projectname: $REGION"
    -H "User-Agent: Mozilla/5.0"
)

# 1. Fetch pipeline
PIPELINE_JSON=$(curl -sk "${HEADERS[@]}" "$BASE/cicd/v5/internal/$PROJECT_ID/pipelines/$PIPELINE_ID")
echo "$PIPELINE_JSON" | python3 -c "
import sys, json
p = json.load(sys.stdin)
d = json.loads(p['definition'])
for stage in d['stages']:
    for job in stage['jobs']:
        for step in job['steps']:
            if step.get('task') == 'official_devcloud_cloudBuild':
                for inp in step['inputs']:
                    if inp['key'] == 'jobId' and inp['value']:
                        print(f\"{job['name']}|{inp['value']}\")
" > /tmp/job_ids.txt

# 2. Fetch each job config
while IFS='|' read -r name jid; do
    echo "Fetching job: $name ($jid)"
    curl -sk "${HEADERS[@]}" "$BASE/codeci/v1/job/$jid/config?get_all_params=true" > "/tmp/job_${name}.json"
done < /tmp/job_ids.txt
```

## GitCode Actions API (for Phase 4 monitoring)

When running the closed-loop monitor-and-fix phase, use these GitCode REST endpoints.

**IMPORTANT: The API hostname is `api.gitcode.com`, NOT `gitcode.com`.** Using `gitcode.com`
returns `{"error_code":404,"error_code_name":"NOT_PATH","error_message":"No handler found for GET ..."}`
because the routes are registered on the API subdomain only.

Base URL: `https://api.gitcode.com/api/v8`
Auth header: `PRIVATE-TOKEN: <gitcode_token>`

Official docs: https://docs.gitcode.com/docs/apis/get-api-v-8-repos-owner-repo-actions-runs

### Authentication

All GitCode API calls require a personal access token passed as a header:
```
PRIVATE-TOKEN: <gitcode_token>
Accept: application/json
User-Agent: Mozilla/5.0 (or any browser UA — avoids WAF blocking)
```

The token needs `repo` scope. Obtain it from GitCode → Settings → Access Tokens.

Use `-L` (follow redirects) with curl, as the API may redirect. Without proper User-Agent and
Accept headers, CloudWAF intercepts the request with a 418 error.

### List recent workflow runs

```
GET https://api.gitcode.com/api/v8/repos/{owner}/{repo}/actions/runs?per_page=5
```

Response shape:
```json
{
  "total_count": 8,
  "workflow_runs": [
    {
      "workflow_run_id": "cbb5214d4c7f4fcbb8c4ef77fa80ffb7",
      "workflow_id": "2faa3513e59b4c3382b21202dbfb40bb",
      "workflow_name": "PR-pipeline_full",
      "file_path": ".gitcode/workflows/PR-pipeline_full.yml",
      "title": "PR-pipeline_full",
      "status": "RUNNING",
      "event": "Note",
      "run_number": 8,
      "head_branch": "master_test2",
      "head_sha": "2529ce2f5ad6...",
      "pull_request_id": "2",
      "actor": {"login": "qinkeke", "name": "qinkeke"},
      "start_time": 1785478613000,
      "end_time": 0
    }
  ]
}
```

Key field differences from GitHub Actions:
- Run ID field is `workflow_run_id` (not `id`)
- Status values are UPPERCASE strings: `PENDING`, `RUNNING`, `COMPLETED`, `FAILED` (not `success`/`failure`)
- Event types include `MR` (merge request/PR) and `Note` (comment trigger like `/compile`)
- Timestamps are Unix epoch **milliseconds** (not ISO 8601 strings)

### Get run details

```
GET https://api.gitcode.com/api/v8/repos/{owner}/{repo}/actions/runs/{workflow_run_id}
```

Returns the full run object including a `stages` array with nested jobs and steps:
```json
{
  "workflow_run_id": "...",
  "status": "RUNNING",
  "stages": [
    {
      "id": "...", "name": "CodeCheck", "identifier": "stage_0",
      "status": "COMPLETED",
      "jobs": [
        {
          "id": "...", "name": "Only_doc_commit_check",
          "status": "COMPLETED",
          "steps": [
            {"name": "checkout", "task": "checkout", "status": "COMPLETED", "sequence": 0, ...}
          ]
        }
      ]
    }
  ]
}
```

This single call gives you all stages, jobs, AND steps in one response — often more convenient
than calling `/jobs` separately.

### List jobs in a run

```
GET https://api.gitcode.com/api/v8/repos/{owner}/{repo}/actions/runs/{workflow_run_id}/jobs
```

Response:
```json
{
  "total_count": 11,
  "jobs": [
    {
      "id": "41001e1bcea84e548d22b12e80b99b35",
      "name": "Only_doc_commit_check",
      "identifier": "Only_doc_commit_check",
      "status": "COMPLETED",
      "start_time": 1785478626000,
      "end_time": 1785478635000,
      "execute_cost_time": 9000,
      "steps": [ ... ]
    }
  ]
}
```

- Job `id` is a hex UUID string (not numeric)
- `status` values: `PENDING`, `RUNNING`, `COMPLETED`, `FAILED`, `CANCELLED`
- Each job includes a `steps` array with per-step name, task, status, sequence, identifier, timing

### Get job details

```
GET https://api.gitcode.com/api/v8/repos/{owner}/{repo}/actions/runs/{workflow_run_id}/jobs/{job_id}
```

Returns a single job object with full step details.

### Query step-level logs (paginated text)

```
POST https://api.gitcode.com/api/v8/repos/{owner}/{repo}/actions/runs/{workflow_run_id}/jobs/{job_id}/logs
```

Returns JSON with paginated log text:
```json
{
  "has_more": true,
  "start_offset": 0,
  "end_offset": 2499,
  "log": "[2026/07/31 14:17:17.558 GMT+08:00] [INFO] Job(...) ...\n..."
}
```

Paginate by passing offset. This returns ALL steps' logs concatenated (not per-step).
Request body can be empty `{}` or include pagination params.

### Download full job log (ZIP)

```
GET https://api.gitcode.com/api/v8/repos/{owner}/{repo}/actions/runs/{workflow_run_id}/jobs/{job_id}/download_log
```

Returns a **ZIP file** (not plain text!) containing one `.log` file per step, named like:
- `0_checkout.log`
- `1_Run SCA PR Scan.log`
- `2_set build skip flag.log`

Save curl output to a `.zip` file, then `unzip` it and read the individual step logs:
```bash
curl -sk -L -H "PRIVATE-TOKEN: $TOKEN" -o logs.zip \
  "https://api.gitcode.com/api/v8/repos/$OWNER/$REPO/actions/runs/$RUN_ID/jobs/$JOB_ID/download_log"
unzip -o logs.zip
tail -50 "1_<step name>.log"
```

This is the most reliable way to get complete, structured logs for failure diagnosis.

### Re-trigger a run via /compile comment

Post a comment on the PR using the **v5** API:
```
POST https://gitcode.com/api/v5/repos/{owner}/{repo}/pulls/{pr_number}/comments
Body: {"body": "/compile <optional message>"}
```

Example:
```bash
curl -sk -X POST \
  -H "PRIVATE-TOKEN: $TOKEN" -H "Content-Type: application/json" \
  -d '{"body": "/compile re-run after fixes"}' \
  "https://gitcode.com/api/v5/repos/$OWNER/$REPO/pulls/$PR_NUMBER/comments"
```

This triggers a new `Note` event run. Push to the PR branch also triggers an `MR` event run.

### Polling loop (Bash example)

```bash
TOKEN="<gitcode_token>"
OWNER="ComputingActionTest"
REPO="<fork_name>"
BASE="https://api.gitcode.com/api/v8"  # NOTE: api.gitcode.com, NOT gitcode.com!

found=false; polls=0
while [ "$found" = false ] && [ $polls -lt 60 ]; do
    run=$(curl -sk -L -H "PRIVATE-TOKEN: $TOKEN" -H "Accept: application/json" \
        -H "User-Agent: Mozilla/5.0" \
        "$BASE/repos/$OWNER/$REPO/actions/runs?per_page=5" | \
        python3 -c "
import sys, json
data = json.load(sys.stdin)
items = data.get('workflow_runs', [])
if items:
    r = items[0]
    # Field names: workflow_run_id (not id), status is UPPERCASE (RUNNING/COMPLETED/FAILED)
    print(f\"{r['workflow_run_id']}|{r['status']}\")
")
    echo "poll $polls : $run"
    run_id=$(echo "$run" | cut -d'|' -f1)
    status=$(echo "$run" | cut -d'|' -f2)
    if [ "$status" = "COMPLETED" ] || [ "$status" = "FAILED" ]; then found=true; else sleep 60; polls=$((polls+1)); fi
done
echo "Run $run_id finished with status $status"

# List failed jobs
curl -sk -L -H "PRIVATE-TOKEN: $TOKEN" -H "Accept: application/json" \
    -H "User-Agent: Mozilla/5.0" \
    "$BASE/repos/$OWNER/$REPO/actions/runs/$run_id/jobs" | \
    python3 -c "
import sys, json
data = json.load(sys.stdin)
for j in data.get('jobs', []):
    if j['status'] == 'FAILED':
        print(f\"FAILED: {j['name']} (id={j['id']})\")
"

# Download logs for a failed job (ZIP file with per-step .log files)
JOB_ID="<failed_job_id>"
curl -sk -L -H "PRIVATE-TOKEN: $TOKEN" \
    "$BASE/repos/$OWNER/$REPO/actions/runs/$run_id/jobs/$JOB_ID/download_log" \
    -o /tmp/job_logs.zip
cd /tmp && unzip -o job_logs.zip
tail -50 /tmp/*<step_keyword>*.log
```

### Polling loop (PowerShell example)

```powershell
$token = "<gitcode_token>"
$owner = "ComputingActionTest"; $repo = "<fork_name>"
$headers = @{ "PRIVATE-TOKEN" = $token; "Accept" = "application/json"; "User-Agent" = "Mozilla/5.0" }
$base = "https://api.gitcode.com/api/v8"  # NOTE: api.gitcode.com!
$found = $false; $polls = 0; $runId = ""
while (-not $found -and $polls -lt 60) {
    $resp = Invoke-RestMethod -Headers $headers "$base/repos/$owner/$repo/actions/runs?per_page=5"
    $r = $resp.workflow_runs[0]
    Write-Host "poll $polls : id=$($r.workflow_run_id) status=$($r.status)"
    if ($r.status -eq "COMPLETED" -or $r.status -eq "FAILED") { $found = $true; $runId = $r.workflow_run_id }
    else { Start-Sleep -Seconds 60; $polls++ }
}
Write-Host "Run $runId finished with status $($r.status)"

# List failed jobs
$jobs = Invoke-RestMethod -Headers $headers "$base/repos/$owner/$repo/actions/runs/$runId/jobs"
foreach ($j in $jobs.jobs) {
    if ($j.status -eq "FAILED") {
        Write-Host "FAILED: $($j.name) (id=$($j.id))"
    }
}
```
