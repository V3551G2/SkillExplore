# fetch_pipeline.ps1 - Fetch CodeArts pipeline and job configurations
# Usage: powershell -File fetch_pipeline.ps1 -PipelineUrl "<url>" -Cookie "<cookie_string>" [-OutputDir "<dir>"]
param(
    [Parameter(Mandatory=$true)]
    [string]$PipelineUrl,

    [Parameter(Mandatory=$true)]
    [string]$Cookie,

    [string]$OutputDir = ".\pipeline_config"
)

# Parse URL
# Format: https://devcloud.<region>.huaweicloud.com/cicd/project/<project_id>/pipeline/history/<pipeline_id>?v=1
if ($PipelineUrl -match 'project/([0-9a-f]{32})') {
    $projectId = $Matches[1]
} else {
    Write-Error "Could not extract project_id from URL: $PipelineUrl"
    exit 1
}

if ($PipelineUrl -match 'pipeline/(?:history|detail)/([0-9a-f]{32})') {
    $pipelineId = $Matches[1]
} else {
    Write-Error "Could not extract pipeline_id from URL: $PipelineUrl"
    exit 1
}

# Extract region from URL
if ($PipelineUrl -match 'devcloud\.([^.]+)\.huaweicloud\.com') {
    $region = $Matches[1]
} else {
    # Try from cookie
    if ($Cookie -match 'cfProjectName=([^;]+)') {
        $region = $Matches[1]
    } else {
        $region = "cn-north-4"
    }
}

# Extract CFTK from cookie
if ($Cookie -match 'devclouddevuibjtcftk=([^;]+)') {
    $cftk = $Matches[1]
} else {
    Write-Error "Could not extract devclouddevuibjtcftk from cookie"
    exit 1
}

$base = "https://devcloud.${region}.huaweicloud.com"

Write-Host "=== Pipeline Configuration Fetcher ==="
Write-Host "Project ID: $projectId"
Write-Host "Pipeline ID: $pipelineId"
Write-Host "Region: $region"
Write-Host "CFTK: $cftk"
Write-Host "Base URL: $base"
Write-Host "Output: $OutputDir"
Write-Host ""

# Create output directory
if (!(Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}
$jobsDir = Join-Path $OutputDir "jobs"
if (!(Test-Path $jobsDir)) {
    New-Item -ItemType Directory -Path $jobsDir -Force | Out-Null
}

# Headers for curl
$h_cookie = "Cookie: $Cookie"
$h_xrw = "X-Requested-With: XMLHttpRequest"
$h_cftk = "cftk: $cftk"
$h_accept = "Accept: application/json"
$h_lang = "language: zh-cn"
$h_proj = "projectname: $region"
$h_ua = "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"

# Step 1: Fetch pipeline
Write-Host "Fetching pipeline definition..."
$pipelineJson = & curl.exe -sk -H $h_cookie -H $h_xrw -H $h_cftk -H $h_accept -H $h_lang -H $h_proj -H $h_ua `
    "$base/cicd/v5/internal/$projectId/pipelines/$pipelineId"

$pipelineJson | Out-File -FilePath (Join-Path $OutputDir "pipeline_raw.json") -Encoding utf8

try {
    $pipeline = $pipelineJson | ConvertFrom-Json
} catch {
    Write-Error "Failed to parse pipeline JSON. Response:"
    Write-Host $pipelineJson.Substring(0, [Math]::Min(1000, $pipelineJson.Length))
    exit 1
}

Write-Host "Pipeline name: $($pipeline.name)"

# Parse definition
if ($pipeline.definition) {
    $definition = $pipeline.definition | ConvertFrom-Json
} else {
    Write-Error "Pipeline has no definition field"
    exit 1
}

# Save parsed definition
$definition | ConvertTo-Json -Depth 10 | Out-File -FilePath (Join-Path $OutputDir "pipeline_definition.json") -Encoding utf8

# Step 2: Collect job IDs (skip disabled steps/jobs)
Write-Host "`n=== Pipeline Structure ==="
$jobIds = @()
foreach ($stage in $definition.stages) {
    Write-Host "Stage: $($stage.name) (seq: $($stage.sequence))"
    foreach ($job in $stage.jobs) {
        # Check strategy.select_strategy == "never" (job disabled by default)
        $strategyNever = $false
        if ($job.strategy -and $job.strategy.select_strategy -eq "never") {
            $strategyNever = $true
        }
        if ($strategyNever) {
            Write-Host "  Job: $($job.name) - SKIPPED (select_strategy=never)"
            continue
        }
        # Check if all steps disabled
        $jobDisabled = $true
        foreach ($step in $job.steps) {
            if ($step.enable -ne $false) { $jobDisabled = $false; break }
        }
        if ($jobDisabled) {
            Write-Host "  Job: $($job.name) - SKIPPED (all steps disabled)"
            continue
        }
        Write-Host "  Job: $($job.name) (exec_type: $($job.exec_type), depends_on: [$($job.depends_on -join ',')])"
        foreach ($step in $job.steps) {
            if ($step.enable -eq $false) {
                Write-Host "    Step: $($step.name) - SKIPPED (disabled)"
                continue
            }
            Write-Host "    Step: $($step.name) [task=$($step.task)]"
            if ($step.task -eq "official_devcloud_cloudBuild") {
                foreach ($inp in $step.inputs) {
                    if ($inp.key -eq "jobId" -and $inp.value) {
                        Write-Host "      -> jobId: $($inp.value)"
                        $jobIds += @{
                            stage = $stage.name
                            job_name = $job.name
                            step_name = $step.name
                            job_id = $inp.value
                        }
                    }
                }
            }
        }
    }
}

# Save variables
if ($pipeline.variables) {
    Write-Host "`n=== Pipeline Variables ==="
    foreach ($v in $pipeline.variables) {
        Write-Host "  $($v.name) = $($v.default_value) (secret: $($v.is_secret))"
    }
    $pipeline.variables | ConvertTo-Json -Depth 5 | Out-File -FilePath (Join-Path $OutputDir "pipeline_variables.json") -Encoding utf8
}

# Save job mapping
$jobIds | ConvertTo-Json -Depth 5 | Out-File -FilePath (Join-Path $OutputDir "job_mapping.json") -Encoding utf8

# Step 3: Fetch each job config
Write-Host "`n=== Fetching Job Configurations ==="
foreach ($j in $jobIds) {
    $jobUrl = "$base/codeci/v1/job/$($j.job_id)/config?get_all_params=true"
    Write-Host "Fetching: $($j.job_name) ($($j.job_id))..."

    $jobJson = & curl.exe -sk -H $h_cookie -H $h_xrw -H $h_cftk -H $h_accept -H $h_lang -H $h_proj -H $h_ua $jobUrl

    $safeName = $j.job_name -replace '[<>:"/\\|?*\s]', '_'
    $jobJson | Out-File -FilePath (Join-Path $jobsDir "${safeName}_$($j.job_id).json") -Encoding utf8

    try {
        $jobConfig = $jobJson | ConvertFrom-Json
        if ($jobConfig.result) {
            $r = $jobConfig.result
            Write-Host "  job_name: $($r.job_name), arch: $($r.arch), host_type: $($r.host_type)"
            foreach ($step in $r.steps) {
                $status = if ($step.enable -ne $false) { "enabled" } else { "DISABLED" }
                Write-Host "  step: $($step.name) [module=$($step.module_id), $status]"
                if ($step.properties -and $step.properties.command) {
                    $cmdLen = $step.properties.command.Length
                    Write-Host "    command length: $cmdLen"
                }
                if ($step.properties -and $step.properties.image) {
                    Write-Host "    image: $($step.properties.image)"
                }
            }
            # Save parameters
            if ($r.parameters) {
                Write-Host "  parameters:"
                foreach ($param in $r.parameters) {
                    if ($param.params) {
                        $pname = ($param.params | Where-Object { $_.name -eq "name" }).value
                        $ptype = ($param.params | Where-Object { $_.name -eq "type" }).value
                        $sensitive = ($param.params | Where-Object { $_.name -eq "sensitiveVar" }).value
                        Write-Host "    $pname (type=$ptype, sensitive=$sensitive)"
                    }
                }
            }
        }
    } catch {
        Write-Host "  WARNING: Could not parse job config JSON: $_"
    }
}

Write-Host "`n=== Done ==="
Write-Host "Pipeline raw: $(Join-Path $OutputDir 'pipeline_raw.json')"
Write-Host "Pipeline definition: $(Join-Path $OutputDir 'pipeline_definition.json')"
Write-Host "Job mapping: $(Join-Path $OutputDir 'job_mapping.json')"
Write-Host "Job configs: $jobsDir\"
