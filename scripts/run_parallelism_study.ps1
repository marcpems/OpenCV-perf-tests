#Requires -Version 7.0
param(
    [string]$Root = '',
    [string]$ResultsDir = "$PSScriptRoot\..\results\local\ninja-job-study",
    [ValidateRange(1, 256)][int]$FixedJobs = [Environment]::ProcessorCount,
    [ValidateRange(0, 3600)][int]$PauseSeconds = 30
)
. "$PSScriptRoot\common.ps1"
$Root = Get-SourceRoot $Root
$ResultsDir = [IO.Path]::GetFullPath($ResultsDir, (Get-Location).ProviderPath)
if (Test-Path $ResultsDir) { throw ' ERROR - Study directory already exists; choose a fresh -ResultsDir.' }
$buildDir = Get-BuildDirectory $Root 'Ninja'
if (-not (Test-Path "$buildDir\benchmark-setup.json")) { throw ' ERROR - Configure the Ninja variant first.' }
$entry = Select-String -Path "$buildDir\CMakeCache.txt" -Pattern '^CMAKE_MAKE_PROGRAM:[^=]+=(.+)$'
if (-not $entry) { throw ' ERROR - Configured Ninja executable not found.' }
$ninja = $entry.Matches[0].Groups[1].Value
$help = (& $ninja --help 2>&1 | Out-String)
if ($help -notmatch '\[default=(\d+) on this system\]') { throw ' ERROR - Cannot verify Ninja default parallelism.' }
$defaultJobs = [int]$Matches[1]
if ($FixedJobs -eq $defaultJobs) { throw ' ERROR - Fixed and default worker counts must differ.' }
$version = & $ninja --version
if ($LASTEXITCODE -ne 0) { throw ' ERROR - Ninja version lookup failed.' }
$order = @('fixed', 'default', 'default', 'fixed', 'default', 'fixed', 'fixed', 'default')
$manifest = [ordered]@{
    started_at = [datetimeoffset]::Now.ToString('o')
    fixed_jobs = $FixedJobs
    default_jobs = $defaultJobs
    order = $order
    pause_seconds = $PauseSeconds
    ninja = $ninja
    ninja_version = "$version"
    ninja_sha256 = (Get-FileHash $ninja).Hash
    build_graph_sha256 = (Get-FileHash "$buildDir\build.ninja").Hash
    runner_sha256 = (Get-FileHash "$PSScriptRoot\run.ps1").Hash
}
New-Item -ItemType Directory $ResultsDir | Out-Null
$manifest | ConvertTo-Json -Depth 4 | Set-Content "$ResultsDir\study.json"
$shell = (Get-Process -Id $PID).Path
$counts = @{ fixed = 0; default = 0 }
$index = 0
foreach ($condition in $order) {
    $index++
    $counts[$condition]++
    $jobs = if ($condition -eq 'fixed') { $FixedJobs } else { 0 }
    $label = if ($condition -eq 'fixed') { "jobs${FixedJobs}_$($counts[$condition])" } else {
        "default${defaultJobs}_$($counts[$condition])"
    }
    Write-Host "Study run $index/8: $label (pause ${PauseSeconds}s)"
    Start-Sleep -Seconds $PauseSeconds
    & $shell -NoProfile -File "$PSScriptRoot\run.ps1" -Root $Root -ResultsDir $ResultsDir `
        -Generator Ninja -Parallel $jobs -Label $label
    if ($LASTEXITCODE -ne 0) { throw " ERROR - Study stopped after failed run: $label" }
    if ((Get-FileHash $ninja).Hash -ne $manifest.ninja_sha256 -or
        (Get-FileHash "$buildDir\build.ninja").Hash -ne $manifest.build_graph_sha256) {
        throw ' ERROR - Tool or build graph changed during study.'
    }
}
$manifest['finished_at'] = [datetimeoffset]::Now.ToString('o')
$manifest | ConvertTo-Json -Depth 4 | Set-Content "$ResultsDir\study.json"
