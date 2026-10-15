#Requires -Version 7.0
. "$PSScriptRoot\..\scripts\common.ps1"
$temp = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
New-Item -ItemType Directory "$temp\scripts" -Force | Out-Null
try {
    foreach ($name in @('common.ps1', 'measure_build.ps1', 'BuildAccounting.cs', 'run_msbuild_parallelism_study.ps1')) {
        Copy-Item "$PSScriptRoot\..\scripts\$name" "$temp\scripts"
    }
    Copy-Item "$PSScriptRoot\..\benchmark.json" $temp
    @'
param($Root, $ResultsDir, $Generator, $Toolchain, $Label, $MSBuildScheduler = 'Default',
    [int]$CompilerJobs = 12, [int]$Parallel, [switch]$SharedCompilerLimit, [switch]$MeasureCpu)
@{ generator=$Generator; toolchain=$Toolchain; label=$Label; scheduler=$MSBuildScheduler;
   compiler_jobs=$CompilerJobs; parallel=$Parallel; shared=[bool]$SharedCompilerLimit;
   cpu=[bool]$MeasureCpu } | ConvertTo-Json -Compress | Add-Content "$ResultsDir\calls.jsonl"
'@ | Set-Content "$temp\scripts\run.ps1"
    foreach ($configuration in @(
            @{ Generator = 'MSBuild'; Toolchain = 'MSVC' },
            @{ Generator = 'Ninja'; Toolchain = 'MSVC' },
            @{ Generator = 'Ninja'; Toolchain = 'Clang' })) {
        $build = Get-BuildDirectory "$temp\source" $configuration.Generator $configuration.Toolchain
        New-Item -ItemType Directory "$build\CMakeFiles" -Force | Out-Null
        '{}' | Set-Content "$build\benchmark-setup.json"
        "CMAKE_MAKE_PROGRAM:FILEPATH=$((Get-Process -Id $PID).Path)" | Set-Content "$build\CMakeCache.txt"
        'fixture' | Set-Content "$build\build.ninja", "$build\CMakeFiles\rules.ninja", "$build\fixture.vcxproj"
    }
    $results = "$temp\results"
    & "$temp\scripts\run_msbuild_parallelism_study.ps1" -Root "$temp\source" -ResultsDir $results -PauseSeconds 0
    $calls = @(Get-Content "$results\calls.jsonl" | ConvertFrom-Json)
    if (($calls.label -join ',') -ne 'multitool_1,ninja_1,shared_1,shared_2,ninja_2,multitool_2') {
        throw ' ERROR - Balanced three-condition study order changed.'
    }
    foreach ($call in $calls) {
        if (-not $call.cpu -or $call.toolchain -ne 'MSVC') { throw ' ERROR - Study must measure original MSVC CPU.' }
        if ($call.label -like 'shared_*') {
            if (-not $call.shared -or $call.parallel -ne 12 -or $call.compiler_jobs -ne 12 -or
                $call.scheduler -ne 'MultiToolTask') { throw ' ERROR - Shared compiler/project bounds were lost.' }
        } elseif ($call.label -like 'multitool_*') {
            if ($call.shared -or $call.parallel -ne 0 -or $call.scheduler -ne 'MultiToolTask') {
                throw ' ERROR - Earlier compiler-only control changed.'
            }
        } elseif ($call.generator -ne 'Ninja' -or $call.parallel -ne 12 -or $call.shared) {
            throw ' ERROR - Ninja control changed.'
        }
    }
    $manifest = Get-Content "$results\study.json" -Raw | ConvertFrom-Json
    if ($manifest.status -ne 'succeeded' -or $manifest.completed_labels.Count -ne 6 -or -not $manifest.finished_at) {
        throw ' ERROR - Study completion is not recorded.'
    }
    $failed = $false
    try { & "$temp\scripts\run_msbuild_parallelism_study.ps1" -Root "$temp\source" -ResultsDir $results -PauseSeconds 0 }
    catch {
        if ($_.Exception.Message -notmatch 'directory already exists') { throw }
        $failed = $true
    }
    if (-not $failed) { throw ' ERROR - Existing study could be overwritten.' }
    $allResults = "$temp\all-results"
    & "$temp\scripts\run_msbuild_parallelism_study.ps1" -Root "$temp\source" `
        -ResultsDir $allResults -PauseSeconds 0 -Jobs 7 -AllConfigurations
    $allCalls = @(Get-Content "$allResults\calls.jsonl" | ConvertFrom-Json)
    if (($allCalls.label -join ',') -ne
        'original_1,multitool_1,shared_1,ninja_1,clang_1,clang_2,ninja_2,shared_2,multitool_2,original_2') {
        throw ' ERROR - Balanced five-condition study order changed.'
    }
    foreach ($call in $allCalls) {
        $expectedToolchain = if ($call.label -like 'clang_*') { 'Clang' } else { 'MSVC' }
        if (-not $call.cpu -or $call.toolchain -ne $expectedToolchain) {
            throw ' ERROR - Full comparison lost CPU measurement or toolchain selection.'
        }
        if ($call.label -like 'original_*') {
            if ($call.generator -ne 'MSBuild' -or $call.parallel -ne 0 -or
                $call.scheduler -ne 'Default' -or $call.shared) {
                throw ' ERROR - Original MSBuild defaults changed.'
            }
        } elseif ($call.label -like 'multitool_*' -or $call.label -like 'shared_*') {
            $shared = $call.label -like 'shared_*'
            $expectedParallel = if ($shared) { 7 } else { 0 }
            if ($call.generator -ne 'MSBuild' -or $call.scheduler -ne 'MultiToolTask' -or
                $call.compiler_jobs -ne 7 -or $call.parallel -ne $expectedParallel -or $call.shared -ne $shared) {
                throw ' ERROR - Full comparison lost independent compiler/project bounds.'
            }
        } elseif ($call.generator -ne 'Ninja' -or $call.parallel -ne 7 -or
            $call.shared -or $call.scheduler -ne 'Default') {
            throw ' ERROR - Full comparison lost matched Ninja settings.'
        }
    }
    $allManifest = Get-Content "$allResults\study.json" -Raw | ConvertFrom-Json
    $clangBuild = Get-BuildDirectory "$temp\source" 'Ninja' 'Clang'
    if ($allManifest.status -ne 'succeeded' -or $allManifest.completed_labels.Count -ne 10 -or
        -not $allManifest.all_configurations -or -not $allManifest.finished_at -or
        "$clangBuild\build.ninja" -notin $allManifest.frozen_sha256.PSObject.Properties.Name) {
        throw ' ERROR - Full study completion or Clang graph freeze is missing.'
    }
    Write-Host 'PASS: three/five-condition study orders, project/compiler limits, toolchains, controls and overwrite guard.'
} finally {
    Get-ChildItem -LiteralPath $temp -Recurse -File | ForEach-Object { Remove-Item -LiteralPath $_.FullName }
    Get-ChildItem -LiteralPath $temp -Recurse -Directory | Sort-Object { $_.FullName.Length } -Descending |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName }
    Remove-Item -LiteralPath $temp
}
