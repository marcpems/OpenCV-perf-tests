#Requires -Version 7.0
. "$PSScriptRoot\common.ps1"
$shell = (Get-Process -Id $PID).Path
& $shell -NoProfile -File "$PSScriptRoot\prepare_minos_tools.ps1"
if ($LASTEXITCODE) { throw 'Minos prerequisites are not ready' }
$repo = [IO.Path]::GetFullPath("$PSScriptRoot\..")
$root = Join-Path $repo '.work\minos-source'
$local = Join-Path $repo ".work\minos-study-$env:GITHUB_RUN_ID"
$public = Join-Path $repo "results\minos-builds-$env:GITHUB_RUN_ID"
if (Test-Path $local) { throw 'Study destination exists; dispatch a new workflow run.' }
$jobs = [int](Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
if ($jobs -ne 20) { throw "Expected the inventoried 20-core Minos runner, found $jobs" }
foreach ($configuration in @(
        @{ Toolchain = 'MSVC'; Generator = 'MSBuild' },
        @{ Toolchain = 'MSVC'; Generator = 'Ninja' },
        @{ Toolchain = 'Clang'; Generator = 'Ninja' })) {
    & $shell -NoProfile -File "$PSScriptRoot\setup.ps1" -Root $root `
        -Toolchain $configuration.Toolchain -Generator $configuration.Generator
    if ($LASTEXITCODE) { throw "Configuration failed: $($configuration.Toolchain)/$($configuration.Generator)" }
}
& $shell -NoProfile -File "$PSScriptRoot\run_msbuild_parallelism_study.ps1" `
    -Root $root -ResultsDir $local -Jobs $jobs -PauseSeconds 30 `
    -AllConfigurations -SnapshotRuntimeBinaries
if ($LASTEXITCODE) { throw 'Minos five-configuration study failed' }
$runs = @(Get-ChildItem $local -Directory | Where-Object Name -ne 'runtime-binaries' |
    ForEach-Object { Get-Content "$($_.FullName)\metadata.json" -Raw | ConvertFrom-Json })
if (@($runs.power_scheme | Select-Object -Unique).Count -ne 1) {
    throw 'Power plan changed between measurements; do not pool this study.'
}
& python "$PSScriptRoot\export_results.py" $local $public
if ($LASTEXITCODE) { throw 'Minos build export failed' }
$summary = Get-Content "$public\summary.json" -Raw | ConvertFrom-Json
$baseline = [double]$summary.original.median_seconds
$comparison = [ordered]@{
    reference_lab_seconds = 154
    minos_baseline_seconds = $baseline
    difference_seconds = $baseline - 154
    difference_percent = ($baseline / 154 - 1) * 100
    reference_inside_observed_range = ($summary.original.min_seconds -le 154 -and $summary.original.max_seconds -ge 154)
    within_five_percent = [math]::Abs($baseline / 154 - 1) -le 0.05
    within_ten_percent = [math]::Abs($baseline / 154 - 1) -le 0.10
    interpretation = 'Two measured builds per configuration. Five/ten-percent bands are descriptive, not statistical equivalence tests; lab variance and full lab software configuration are unavailable.'
    jobs = $jobs
    source_run_id = $env:GITHUB_RUN_ID
    source_commit = $env:GITHUB_SHA
}
$comparison | ConvertTo-Json | Set-Content "$public\lab-comparison.json"
if ($env:GITHUB_ENV) { "MINOS_STUDY_ROOT=$local" | Add-Content $env:GITHUB_ENV }
$lines = @(
    '## Minos: balanced clean-build comparison',
    '| Configuration | Median wall s | Observed range s | Saving vs base |',
    '|---|---:|---:|---:|'
)
foreach ($name in @('original','multitool','shared','ninja','clang')) {
    $row = $summary.$name
    $saving = (1 - $row.median_seconds / $baseline) * 100
    $lines += "| $name | $([math]::Round($row.median_seconds,3)) | $([math]::Round($row.min_seconds,3))-$([math]::Round($row.max_seconds,3)) | $([math]::Round($saving,1))% |"
}
$lines += "Baseline versus 154s lab reference: $([math]::Round($comparison.difference_percent,2))%. Two observations; no formal equivalence claim."
$lines | Write-Host
if ($env:GITHUB_STEP_SUMMARY) { $lines | Add-Content $env:GITHUB_STEP_SUMMARY }
