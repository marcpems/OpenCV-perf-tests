#Requires -Version 7.0
param(
    [string]$Repository = 'D:\copilot\opencv-perf-tests',
    [string]$Root = 'D:\opencv'
)
. "$Repository\scripts\common.ps1"
$results = "$Repository\results\local\vs2026-sdk-comparison"
$manifestPath = "$results\study.json"
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
if ($manifest.PSObject.Properties.Name -contains 'finished_at') { throw 'Study already finished.' }
$runs = @(Get-ChildItem "$results\*\metadata.json" | ForEach-Object {
    Get-Content $_.FullName -Raw | ConvertFrom-Json
} | Sort-Object { [datetimeoffset]$_.started_at })
if ($runs.Count -ne 6 -or $manifest.order.Count -ne 8) { throw 'Expected exactly six completed runs of eight.' }
for ($index = 0; $index -lt 6; $index++) {
    if ($runs[$index].status -ne 'succeeded' -or $runs[$index].toolchain -ne $manifest.order[$index] -or
        $runs[$index].validated_version -ne '4.10.0' -or $runs[$index].runner_sha256 -ne $manifest.runner_sha256) {
        throw 'Completed study prefix is invalid.'
    }
}
function Assert-FrozenStudy {
    if ((Get-FileHash "$Repository\scripts\run.ps1").Hash -ne $manifest.runner_sha256 -or
        (Get-FileHash "$Repository\scripts\common.ps1").Hash -ne $manifest.common_sha256) {
        throw 'Measured runner/helper changed.'
    }
    foreach ($file in $manifest.build_graph_sha256.PSObject.Properties) {
        if ((Get-FileHash -LiteralPath $file.Name).Hash -ne $file.Value) { throw "Study input changed: $($file.Name)" }
    }
}
Assert-FrozenStudy
Assert-NoPendingToolchainRestart
Assert-WindowsSDKRestart
$before = "$results\study-before-recovery.json"
if (Test-Path $before) { throw 'Recovery was already attempted; inspect the recorded state.' }
Copy-Item $manifestPath $before
$recovery = [pscustomobject]@{
    reason = 'Windows Application Hang event 1002 closed pwsh.exe between runs 6 and 7.'
    event_time = '2026-10-15T12:48:27.8021307+01:00'
    completed_prefix_runs = 6
    resumed_at = [datetimeoffset]::Now.ToString('o')
    script_sha256 = (Get-FileHash $PSCommandPath).Hash
    original_manifest_sha256 = (Get-FileHash $before).Hash
}
$manifest | Add-Member -NotePropertyName recovery -NotePropertyValue $recovery
$manifest | ConvertTo-Json -Depth 6 | Set-Content $manifestPath
$shell = (Get-Process -Id $PID).Path
foreach ($toolchain in @('MSVC2026', 'MSVC2026Latest')) {
    Assert-FrozenStudy
    Start-Sleep -Seconds $manifest.pause_seconds
    & $shell -NoProfile -File "$Repository\scripts\run.ps1" -Root $Root -ResultsDir $results `
        -Toolchain $toolchain -Parallel 0 -Label "$($toolchain.ToLowerInvariant())_4"
    if ($LASTEXITCODE -ne 0) { throw "Recovery build failed: $toolchain" }
    Assert-FrozenStudy
}
$completed = @(Get-ChildItem "$results\*\metadata.json" | ForEach-Object {
    Get-Content $_.FullName -Raw | ConvertFrom-Json
} | Sort-Object { [datetimeoffset]$_.started_at })
if ($completed.Count -ne 8 -or @($completed | Where-Object { $_.status -ne 'succeeded' }).Count -ne 0 -or
    ($completed.toolchain -join ',') -ne ($manifest.order -join ',')) {
    throw 'Recovered study did not complete the required sequence.'
}
$manifest | Add-Member -NotePropertyName finished_at -NotePropertyValue ([datetimeoffset]::Now.ToString('o'))
$manifest | ConvertTo-Json -Depth 6 | Set-Content $manifestPath
Write-Host 'Study completed with documented recovery after run 6; all frozen input hashes match.'
