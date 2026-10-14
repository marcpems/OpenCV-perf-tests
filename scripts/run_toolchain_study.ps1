#Requires -Version 7.0
param(
    [string]$Root = '',
    [string]$ResultsDir = "$PSScriptRoot\..\results\local\clang-comparison",
    [ValidateRange(1, 256)][int]$Parallel = [Environment]::ProcessorCount,
    [ValidateRange(0, 3600)][int]$PauseSeconds = 30
)
. "$PSScriptRoot\common.ps1"
$Root = Get-SourceRoot $Root
$ResultsDir = [IO.Path]::GetFullPath($ResultsDir, (Get-Location).ProviderPath)
if (Test-Path $ResultsDir) { throw ' ERROR - Study directory already exists; choose a fresh -ResultsDir.' }
$graphs = @{}
$ninjaPaths = @()
foreach ($toolchain in @('MSVC', 'Clang')) {
    $buildDir = Get-BuildDirectory $Root 'Ninja' $toolchain
    if (-not (Test-Path "$buildDir\benchmark-setup.json")) { throw " ERROR - Configure Ninja/$toolchain first." }
    $graphs["$buildDir\build.ninja"] = (Get-FileHash "$buildDir\build.ninja").Hash
    $entry = Select-String -Path "$buildDir\CMakeCache.txt" -Pattern '^CMAKE_MAKE_PROGRAM:[^=]+=(.+)$'
    if (-not $entry) { throw " ERROR - Configured Ninja executable not found for $toolchain." }
    $ninjaPaths += [IO.Path]::GetFullPath($entry.Matches[0].Groups[1].Value)
}
if ($ninjaPaths[0] -ne $ninjaPaths[1]) { throw ' ERROR - Both toolchains must use the same Ninja executable.' }
$ninja = $ninjaPaths[0]
$version = & $ninja --version
if ($LASTEXITCODE -ne 0) { throw ' ERROR - Ninja version lookup failed.' }
$order = @('MSVC', 'Clang', 'Clang', 'MSVC')
$manifest = [ordered]@{
    started_at = [datetimeoffset]::Now.ToString('o')
    order = $order
    generator = 'Ninja'
    parallel = $Parallel
    pause_seconds = $PauseSeconds
    ninja = $ninja
    ninja_version = "$version"
    ninja_sha256 = (Get-FileHash $ninja).Hash
    build_graph_sha256 = $graphs
    runner_sha256 = (Get-FileHash "$PSScriptRoot\run.ps1").Hash
}
New-Item -ItemType Directory $ResultsDir | Out-Null
$manifest | ConvertTo-Json -Depth 4 | Set-Content "$ResultsDir\study.json"
$shell = (Get-Process -Id $PID).Path
$counts = @{ MSVC = 0; Clang = 0 }
foreach ($toolchain in $order) {
    $counts[$toolchain]++
    $label = "$($toolchain.ToLowerInvariant())_$($counts[$toolchain])"
    Write-Host "Toolchain study: $label (pause ${PauseSeconds}s)"
    Start-Sleep -Seconds $PauseSeconds
    & $shell -NoProfile -File "$PSScriptRoot\run.ps1" -Root $Root -ResultsDir $ResultsDir `
        -Generator Ninja -Toolchain $toolchain -Parallel $Parallel -Label $label
    if ($LASTEXITCODE -ne 0) { throw " ERROR - Study stopped after failed run: $label" }
    if ((Get-FileHash $ninja).Hash -ne $manifest.ninja_sha256 -or
        (Get-FileHash "$PSScriptRoot\run.ps1").Hash -ne $manifest.runner_sha256) {
        throw ' ERROR - Tool or runner changed during study.'
    }
    foreach ($graph in $graphs.Keys) {
        if ((Get-FileHash $graph).Hash -ne $graphs[$graph]) { throw " ERROR - Build graph changed: $graph" }
    }
}
$manifest['finished_at'] = [datetimeoffset]::Now.ToString('o')
$manifest | ConvertTo-Json -Depth 4 | Set-Content "$ResultsDir\study.json"
