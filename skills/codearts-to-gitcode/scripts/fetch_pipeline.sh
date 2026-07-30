#!/bin/bash
# fetch_pipeline.sh - Fetch CodeArts pipeline and job configurations
# Usage: ./fetch_pipeline.sh <pipeline_url> <cookie_string> [output_dir]

set -euo pipefail

PIPELINE_URL="$1"
COOKIE="$2"
OUTPUT_DIR="${3:-./pipeline_config}"

# Parse project_id from URL
PROJECT_ID=$(echo "$PIPELINE_URL" | grep -oP 'project/\K[0-9a-f]{32}')
if [ -z "$PROJECT_ID" ]; then
    echo "ERROR: Could not extract project_id from URL"
    exit 1
fi

# Parse pipeline_id from URL
PIPELINE_ID=$(echo "$PIPELINE_URL" | grep -oP 'pipeline/(?:history|detail)/\K[0-9a-f]{32}')
if [ -z "$PIPELINE_ID" ]; then
    echo "ERROR: Could not extract pipeline_id from URL"
    exit 1
fi

# Extract region from URL
REGION=$(echo "$PIPELINE_URL" | grep -oP 'devcloud\.\K[^.]+(?=\.huaweicloud\.com)')
if [ -z "$REGION" ]; then
    REGION=$(echo "$COOKIE" | grep -oP 'cfProjectName=\K[^;]+')
    REGION=${REGION:-cn-north-4}
fi

# Extract CFTK from cookie
CFTK=$(echo "$COOKIE" | grep -oP 'devclouddevuibjtcftk=\K[^;]+')
if [ -z "$CFTK" ]; then
    echo "ERROR: Could not extract devclouddevuibjtcftk from cookie"
    exit 1
fi

BASE="https://devcloud.${REGION}.huaweicloud.com"

echo "=== Pipeline Configuration Fetcher ==="
echo "Project ID: $PROJECT_ID"
echo "Pipeline ID: $PIPELINE_ID"
echo "Region: $REGION"
echo "Base URL: $BASE"
echo "Output: $OUTPUT_DIR"
echo ""

mkdir -p "$OUTPUT_DIR/jobs"

# Headers
HEADERS=(
    -H "Cookie: $COOKIE"
    -H "X-Requested-With: XMLHttpRequest"
    -H "cftk: $CFTK"
    -H "Accept: application/json"
    -H "language: zh-cn"
    -H "projectname: $REGION"
    -H "User-Agent: Mozilla/5.0"
)

# Step 1: Fetch pipeline
echo "Fetching pipeline definition..."
PIPELINE_JSON=$(curl -sk "${HEADERS[@]}" "$BASE/cicd/v5/internal/$PROJECT_ID/pipelines/$PIPELINE_ID")
echo "$PIPELINE_JSON" > "$OUTPUT_DIR/pipeline_raw.json"

PIPELINE_NAME=$(echo "$PIPELINE_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('name','UNKNOWN'))" 2>/dev/null || echo "UNKNOWN")
echo "Pipeline name: $PIPELINE_NAME"

# Parse definition and extract job IDs
echo "$PIPELINE_JSON" | python3 -c "
import sys, json

p = json.load(sys.stdin)
definition = json.loads(p.get('definition', '{}'))

# Save definition
with open('$OUTPUT_DIR/pipeline_definition.json', 'w') as f:
    json.dump(definition, f, indent=2, ensure_ascii=False)

# Save variables
if p.get('variables'):
    with open('$OUTPUT_DIR/pipeline_variables.json', 'w') as f:
        json.dump(p['variables'], f, indent=2, ensure_ascii=False)

# Extract job IDs and print structure (skip disabled jobs/steps)
job_ids = []
for stage in definition.get('stages', []):
    print(f\"Stage: {stage['name']} (seq: {stage.get('sequence', 0)})\")
    for job in stage.get('jobs', []):
        # Skip jobs with strategy.select_strategy == "never"
        strategy = job.get('strategy', {})
        if strategy and strategy.get('select_strategy') == 'never':
            print(f\"  Job: {job['name']} - SKIPPED (select_strategy=never)\")
            continue
        # Skip disabled jobs (all steps disabled)
        job_enabled = any(s.get('enable', True) for s in job.get('steps', []))
        if not job_enabled:
            print(f\"  Job: {job['name']} - SKIPPED (all steps disabled)\")
            continue
        depends = ','.join(job.get('depends_on', []))
        print(f\"  Job: {job['name']} (exec_type: {job.get('exec_type', '')}, depends: [{depends}])\")
        for step in job.get('steps', []):
            if step.get('enable') == False:
                print(f\"    Step: {step.get('name', '')} - SKIPPED (disabled)\")
                continue
            print(f\"    Step: {step.get('name', '')} [task={step.get('task', '')}]\")
            if step.get('task') == 'official_devcloud_cloudBuild':
                for inp in step.get('inputs', []):
                    if inp.get('key') == 'jobId' and inp.get('value'):
                        print(f\"      -> jobId: {inp['value']}\")
                        job_ids.append({
                            'stage': stage['name'],
                            'job_name': job['name'],
                            'step_name': step.get('name', ''),
                            'job_id': inp['value']
                        })

with open('$OUTPUT_DIR/job_mapping.json', 'w') as f:
    json.dump(job_ids, f, indent=2, ensure_ascii=False)

# Print variables
if p.get('variables'):
    print()
    print('=== Pipeline Variables ===')
    for v in p['variables']:
        secret = v.get('is_secret', False)
        print(f\"  {v['name']} = {v.get('default_value', '')} (secret: {secret})\")
"

# Step 2: Fetch each job config
echo ""
echo "=== Fetching Job Configurations ==="
python3 -c "
import json, subprocess, sys

with open('$OUTPUT_DIR/job_mapping.json') as f:
    jobs = json.load(f)

for j in jobs:
    jid = j['job_id']
    safe_name = ''.join(c if c.isalnum() or c in '-_' else '_' for c in j['job_name'])
    outpath = '$OUTPUT_DIR/jobs/{}_{}.json'.format(safe_name, jid)

    url = '$BASE/codeci/v1/job/{}/config?get_all_params=true'.format(jid)
    print(f\"Fetching: {j['job_name']} ({jid})...\")

    result = subprocess.run([
        'curl', '-sk',
        '-H', 'Cookie: $COOKIE',
        '-H', 'X-Requested-With: XMLHttpRequest',
        '-H', 'cftk: $CFTK',
        '-H', 'Accept: application/json',
        '-H', 'language: zh-cn',
        '-H', 'projectname: $REGION',
        '-H', 'User-Agent: Mozilla/5.0',
        url
    ], capture_output=True, text=True)

    with open(outpath, 'w') as f:
        f.write(result.stdout)

    try:
        jc = json.loads(result.stdout)
        r = jc.get('result', {})
        print(f\"  job_name: {r.get('job_name', '')}, arch: {r.get('arch', '')}, host_type: {r.get('host_type', '')}\")
        for step in r.get('steps', []):
            status = 'enabled' if step.get('enable', True) else 'DISABLED'
            print(f\"  step: {step.get('name', '')} [module={step.get('module_id', '')}, {status}]\")
            props = step.get('properties', {})
            if props.get('command'):
                print(f\"    command length: {len(props['command'])}\")
            if props.get('image'):
                print(f\"    image: {props['image']}\")
        if r.get('parameters'):
            print('  parameters:')
            for p in r['parameters']:
                for pp in p.get('params', []):
                    if pp.get('name') == 'name':
                        pname = pp.get('value', '')
                    if pp.get('name') == 'sensitiveVar':
                        sensitive = pp.get('value', '')
                print(f\"    {pname} (sensitive={sensitive})\")
    except Exception as e:
        print(f\"  WARNING: Could not parse job config: {e}\")
"

echo ""
echo "=== Done ==="
echo "Pipeline raw: $OUTPUT_DIR/pipeline_raw.json"
echo "Pipeline definition: $OUTPUT_DIR/pipeline_definition.json"
echo "Job mapping: $OUTPUT_DIR/job_mapping.json"
echo "Job configs: $OUTPUT_DIR/jobs/"
