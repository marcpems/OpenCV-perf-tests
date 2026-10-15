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
    foreach ($generator in @('MSBuild', 'Ninja')) {
        $build = Get-BuildDirectory "$temp\source" $generator 'MSVC'
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
    Write-Host 'PASS: full-parallelism study order, project/compiler limits, controls and overwrite guard.'
} finally {
    Get-ChildItem -LiteralPath $temp -Recurse -File | ForEach-Object { Remove-Item -LiteralPath $_.FullName }
    Get-ChildItem -LiteralPath $temp -Recurse -Directory | Sort-Object { $_.FullName.Length } -Descending |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName }
    Remove-Item -LiteralPath $temp
}
