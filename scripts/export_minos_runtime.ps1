#Requires -Version 7.0
param([Parameter(Mandatory)][ValidatePattern('^\d+$')][string]$SourceRunId)
. "$PSScriptRoot\common.ps1"
if ($env:RUNNER_NAME -ine 'MARCPE-D4') { throw 'Expected Minos runner' }
$repo = [IO.Path]::GetFullPath("$PSScriptRoot\..")
$root = Join-Path $repo ".work\minos-runtime-$SourceRunId"
$public = Join-Path $repo "results\minos-runtime-$SourceRunId"
& python "$PSScriptRoot\analyze_runtime_screen.py" $root --export $public
if ($LASTEXITCODE) { throw 'Runtime analysis/export failed' }
$summary = Get-Content "$public\summary.json" -Raw | ConvertFrom-Json
Write-Host "Exported original measurement status: $($summary.status); failures: $($summary.failed_case_runs)"
if ($env:GITHUB_ENV) { "MINOS_RUNTIME_EXPORT=$public" | Add-Content $env:GITHUB_ENV }
if ($env:GITHUB_STEP_SUMMARY) {
    "Recovered runtime evidence from run ${SourceRunId}: **$($summary.status)**; $($summary.failed_case_runs) failed case executions. Export success is not a measurement pass." |
        Add-Content $env:GITHUB_STEP_SUMMARY
}
