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
