#Requires -Version 7.0
param(
    [string]$Root = '',
    [string]$ResultsDir = '',
    [ValidateSet('Clang', 'MSVC2026')][string]$CandidateToolchain = 'Clang',
    [ValidateRange(0, 256)][int]$Parallel = 0,
    [ValidateRange(0, 3600)][int]$PauseSeconds = 30
)
. "$PSScriptRoot\common.ps1"
Assert-NoPendingToolchainRestart
$Root = Get-SourceRoot $Root
$generator = if ($CandidateToolchain -eq 'Clang') { 'Ninja' } else { 'MSBuild' }
if (-not $ResultsDir) {
    $name = if ($CandidateToolchain -eq 'Clang') { 'clang-comparison' } else { 'vs2026-comparison' }
    $ResultsDir = "$PSScriptRoot\..\results\local\$name"
}
if (-not $PSBoundParameters.ContainsKey('Parallel') -and $CandidateToolchain -eq 'Clang') {
    $Parallel = [Environment]::ProcessorCount
}
$ResultsDir = [IO.Path]::GetFullPath($ResultsDir, (Get-Location).ProviderPath)
if (Test-Path $ResultsDir) { throw ' ERROR - Study directory already exists; choose a fresh -ResultsDir.' }
$graphs = @{}
$installationReceipt = "$PSScriptRoot\..\.tools\vs2026-installation.json"
if (Test-Path $installationReceipt) {
    $graphs[$installationReceipt] = (Get-FileHash $installationReceipt).Hash
}
$ninjaPaths = @()
foreach ($toolchain in @('MSVC', $CandidateToolchain)) {
    $buildDir = Get-BuildDirectory $Root $generator $toolchain
    if (-not (Test-Path "$buildDir\benchmark-setup.json")) { throw " ERROR - Configure $generator/$toolchain first." }
    if ($generator -eq 'Ninja') {
        $graphs["$buildDir\build.ninja"] = (Get-FileHash "$buildDir\build.ninja").Hash
        $entry = Select-String -Path "$buildDir\CMakeCache.txt" -Pattern '^CMAKE_MAKE_PROGRAM:[^=]+=(.+)$'
        if (-not $entry) { throw " ERROR - Configured Ninja executable not found for $toolchain." }
        $ninjaPaths += [IO.Path]::GetFullPath($entry.Matches[0].Groups[1].Value)
    } else {
        $projects = @(Get-ChildItem $buildDir -Recurse -File -Include *.sln,*.vcxproj,*.props,*.targets)
        if (-not $projects.Count) { throw " ERROR - No generated MSBuild projects found for $toolchain." }
        foreach ($project in $projects) { $graphs[$project.FullName] = (Get-FileHash $project.FullName).Hash }
    }
    $graphs["$buildDir\benchmark-setup.json"] = (Get-FileHash "$buildDir\benchmark-setup.json").Hash
}
$order = @('MSVC', $CandidateToolchain, $CandidateToolchain, 'MSVC')
$manifest = [ordered]@{
    started_at = [datetimeoffset]::Now.ToString('o')
    order = $order
    generator = $generator
    parallel = $Parallel
    pause_seconds = $PauseSeconds
    build_graph_sha256 = $graphs
    runner_sha256 = (Get-FileHash "$PSScriptRoot\run.ps1").Hash
    common_sha256 = (Get-FileHash "$PSScriptRoot\common.ps1").Hash
}
if ($generator -eq 'Ninja') {
    if ($ninjaPaths[0] -ne $ninjaPaths[1]) { throw ' ERROR - Both toolchains must use the same Ninja executable.' }
    $ninja = $ninjaPaths[0]
    $version = & $ninja --version
    if ($LASTEXITCODE -ne 0) { throw ' ERROR - Ninja version lookup failed.' }
    $manifest['ninja'] = $ninja
    $manifest['ninja_version'] = "$version"
    $manifest['ninja_sha256'] = (Get-FileHash $ninja).Hash
}
New-Item -ItemType Directory $ResultsDir | Out-Null
$manifest | ConvertTo-Json -Depth 4 | Set-Content "$ResultsDir\study.json"
$shell = (Get-Process -Id $PID).Path
$counts = @{ MSVC = 0 }
$counts[$CandidateToolchain] = 0
foreach ($toolchain in $order) {
    $counts[$toolchain]++
    $label = "$($toolchain.ToLowerInvariant())_$($counts[$toolchain])"
    Write-Host "Toolchain study: $label (pause ${PauseSeconds}s)"
    Start-Sleep -Seconds $PauseSeconds
    & $shell -NoProfile -File "$PSScriptRoot\run.ps1" -Root $Root -ResultsDir $ResultsDir `
        -Generator $generator -Toolchain $toolchain -Parallel $Parallel -Label $label
    if ($LASTEXITCODE -ne 0) { throw " ERROR - Study stopped after failed run: $label" }
    if ((Get-FileHash "$PSScriptRoot\run.ps1").Hash -ne $manifest.runner_sha256 -or
        (Get-FileHash "$PSScriptRoot\common.ps1").Hash -ne $manifest.common_sha256) {
        throw ' ERROR - Tool or runner changed during study.'
    }
    if ($generator -eq 'Ninja' -and (Get-FileHash $ninja).Hash -ne $manifest.ninja_sha256) {
        throw ' ERROR - Ninja changed during study.'
    }
    foreach ($graph in $graphs.Keys) {
        if ((Get-FileHash $graph).Hash -ne $graphs[$graph]) { throw " ERROR - Build graph changed: $graph" }
    }
}
$manifest['finished_at'] = [datetimeoffset]::Now.ToString('o')
$manifest | ConvertTo-Json -Depth 4 | Set-Content "$ResultsDir\study.json"
