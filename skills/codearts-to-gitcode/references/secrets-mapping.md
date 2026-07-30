# Secrets Mapping Reference

Maps CodeArts sensitive parameters to GitCode repository secrets that must be configured
in GitCode repo Settings > Secrets and variables.

## Common Secrets

| CodeArts Parameter | GitCode Secret | Purpose |
|---|---|---|
| `Atlas_password` | `ATLAS_PASSWORD` | GitCode Atlas account password for cloning private repos |
| `appId_task` | `APPID_TASK` | API Gateway app ID for task APIs |
| `secretKey_task` | `SECRETKEY_TASK` | API Gateway secret key for task APIs |
| `appId_status` | `APPID_STATUS` | API Gateway app ID for status APIs |
| `secretKey_status` | `SECRETKEY_STATUS` | API Gateway secret key for status APIs |
| `CMC_USERNAME` | (input, not secret) | Artifact repository username |
| `CMC_PASSWORD` | `CMC_PASSWORD` | Artifact repository password |
| (OBS credentials) | `OBS_AK` | OBS access key |
| (OBS credentials) | `OBS_SK` | OBS secret key |
| `SCAN_ACCESS_KEY` | `SCAN_ACCESS_KEY` | SCA scan access key |
| `SCAN_SECRET_KEY` | `SCAN_SECRET_KEY` | SCA scan secret key |
| (GitCode access token) | `ACCESS_QK` | GitCode personal access token (used by SAST/AI-Check; NOT needed for `openlibing-pre-commit-action` as of 2026-07 — `gc_token` input was removed from the plugin) |
| `access` / `access_token` | `ACCESS_TOKEN` | General API access token |

## Naming Convention

- Convert CodeArts lower_snake_case parameter names to UPPER_SNAKE_CASE for GitCode secrets
- Pipeline-level variables that are sensitive should also be mapped to secrets
- The `appId_task`/`secretKey_task`/`appId_status`/`secretKey_status` group may have suffixes
  for specific services (e.g., `_ANTI` for Antipoison):
  - `APPID_TASK_ANTI`, `SECRETKEY_TASK_ANTI`, `APPID_STATUS_ANTI`, `SECRETKEY_STATUS_ANTI`

## Extracting Secrets from Job Configs

When processing a CodeCI job config, scan `parameters[]` for entries where:
```json
{"name": "sensitiveVar", "value": "true"}
```

For each such parameter:
1. Get the `name` param (e.g., `Atlas_password`)
2. Convert to UPPER_SNAKE_CASE (e.g., `ATLAS_PASSWORD`)
3. Add to the secrets list for the output summary

Note: CodeArts encrypts parameter values, so you cannot read their values from the API.
The user must configure these separately in GitCode repo settings.

## Secret Configuration in GitCode

After generating YAML, provide the user with a complete list of secrets they need to add
to their GitCode repository settings, with descriptions of each.

Example summary output:
```
=== Required GitCode Repository Secrets ===
- ATLAS_PASSWORD: GitCode Atlas account password for private repo access
- OBS_AK: Huawei Cloud OBS access key
- OBS_SK: Huawei Cloud OBS secret key
- APPID_TASK: API Gateway app ID for code check tasks
- SECRETKEY_TASK: API Gateway secret key for code check tasks
- APPID_STATUS: API Gateway app ID for status queries
- SECRETKEY_STATUS: API Gateway secret key for status queries
- CMC_PASSWORD: Artifact repository (devrepo) password
- ACCESS_QK: GitCode personal access token
```
