#Requires -Version 7.0
param(
    [string]$Root = '',
    [string]$ResultsDir = "$PSScriptRoot\..\results\local\msbuild-shared-study",
    [ValidateRange(1, 256)][int]$Jobs = 12,
    [ValidateRange(0, 3600)][int]$PauseSeconds = 30,
    [switch]$AllConfigurations
)
. "$PSScriptRoot\common.ps1"
Assert-NoPendingToolchainRestart
Assert-WindowsSDKRestart
$Root = Get-SourceRoot $Root
$ResultsDir = [IO.Path]::GetFullPath($ResultsDir, (Get-Location).ProviderPath)
if (Test-Path $ResultsDir) { throw ' ERROR - Study directory already exists; choose a fresh -ResultsDir.' }
$frozen = @{}
foreach ($name in @('run.ps1', 'common.ps1', 'measure_build.ps1', 'BuildAccounting.cs',
        'run_msbuild_parallelism_study.ps1', '..\benchmark.json')) {
    $path = [IO.Path]::GetFullPath("$PSScriptRoot\$name")
    $frozen[$path] = (Get-FileHash $path).Hash
}
$buildConfigurations = @(
    @{ Generator = 'MSBuild'; Toolchain = 'MSVC' },
    @{ Generator = 'Ninja'; Toolchain = 'MSVC' }
)
if ($AllConfigurations) { $buildConfigurations += @{ Generator = 'Ninja'; Toolchain = 'Clang' } }
foreach ($configuration in $buildConfigurations) {
    $generator = $configuration.Generator
    $toolchain = $configuration.Toolchain
    $build = Get-BuildDirectory $Root $generator $toolchain
    if (-not (Test-Path "$build\benchmark-setup.json")) { throw " ERROR - Configure $toolchain/$generator first." }
    foreach ($name in @('benchmark-setup.json', 'CMakeCache.txt')) {
        $frozen["$build\$name"] = (Get-FileHash "$build\$name").Hash
    }
    if ($generator -eq 'MSBuild') {
        $projects = @(Get-ChildItem $build -Recurse -File -Include *.sln,*.vcxproj,*.props,*.targets)
        if (-not $projects.Count) { throw ' ERROR - No generated MSBuild projects found.' }
        foreach ($project in $projects) { $frozen[$project.FullName] = (Get-FileHash $project.FullName).Hash }
    } else {
        foreach ($name in @('build.ninja', 'CMakeFiles\rules.ninja')) {
            $frozen["$build\$name"] = (Get-FileHash "$build\$name").Hash
        }
        $entry = Select-String "$build\CMakeCache.txt" -Pattern '^CMAKE_MAKE_PROGRAM:[^=]+=(.+)$'
        if (-not $entry) { throw ' ERROR - Configured Ninja executable not found.' }
        $ninja = [IO.Path]::GetFullPath($entry.Matches[0].Groups[1].Value)
        $frozen[$ninja] = (Get-FileHash $ninja).Hash
    }
}
$variants = @{
    multitool = @('-Toolchain', 'MSVC', '-Generator', 'MSBuild',
        '-MSBuildScheduler', 'MultiToolTask', '-CompilerJobs', "$Jobs")
    ninja = @('-Toolchain', 'MSVC', '-Generator', 'Ninja', '-Parallel', "$Jobs")
    shared = @('-Toolchain', 'MSVC', '-Generator', 'MSBuild',
        '-MSBuildScheduler', 'MultiToolTask', '-CompilerJobs', "$Jobs",
        '-SharedCompilerLimit', '-Parallel', "$Jobs")
}
$order = @('multitool', 'ninja', 'shared', 'shared', 'ninja', 'multitool')
if ($AllConfigurations) {
    $variants.original = @('-Toolchain', 'MSVC', '-Generator', 'MSBuild')
    $variants.clang = @('-Toolchain', 'Clang', '-Generator', 'Ninja', '-Parallel', "$Jobs")
    $order = @('original', 'multitool', 'shared', 'ninja', 'clang',
        'clang', 'ninja', 'shared', 'multitool', 'original')
}
$manifest = [ordered]@{
    status = 'running'
    started_at = [datetimeoffset]::Now.ToString('o')
    order = $order
    jobs = $Jobs
    all_configurations = [bool]$AllConfigurations
    pause_seconds = $PauseSeconds
    variants = $variants
    frozen_sha256 = $frozen
    completed_labels = @()
}
New-Item -ItemType Directory $ResultsDir | Out-Null
$manifest | ConvertTo-Json -Depth 5 | Set-Content "$ResultsDir\study.json"
$shell = (Get-Process -Id $PID).Path
$counts = @{}
foreach ($variant in $variants.Keys) { $counts[$variant] = 0 }
try {
    foreach ($variant in $order) {
        foreach ($path in $frozen.Keys) {
            if ((Get-FileHash $path).Hash -ne $frozen[$path]) { throw " ERROR - Frozen input changed: $path" }
        }
        $counts[$variant]++
        $label = "$($variant)_$($counts[$variant])"
        Write-Host "MSBuild parallelism study: $label (pause ${PauseSeconds}s)"
        Start-Sleep -Seconds $PauseSeconds
        $options = $variants[$variant]
        & $shell -NoProfile -File "$PSScriptRoot\run.ps1" -Root $Root -ResultsDir $ResultsDir `
            -MeasureCpu -Label $label @options
        if ($LASTEXITCODE -ne 0) { throw " ERROR - Study stopped after failed run: $label" }
        foreach ($path in $frozen.Keys) {
            if ((Get-FileHash $path).Hash -ne $frozen[$path]) { throw " ERROR - Frozen input changed: $path" }
        }
        $manifest.completed_labels += $label
        $manifest | ConvertTo-Json -Depth 5 | Set-Content "$ResultsDir\study.json"
    }
    $manifest.status = 'succeeded'
    $manifest['finished_at'] = [datetimeoffset]::Now.ToString('o')
} catch {
    $manifest.status = 'failed'
    $manifest['error'] = $_.Exception.Message
    throw
} finally {
    $manifest | ConvertTo-Json -Depth 5 | Set-Content "$ResultsDir\study.json"
}
