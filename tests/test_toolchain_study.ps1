#Requires -Version 7.0
. "$PSScriptRoot\..\scripts\common.ps1"
$temp = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
New-Item -ItemType Directory "$temp\scripts" -Force | Out-Null
try {
    Copy-Item "$PSScriptRoot\..\scripts\common.ps1", "$PSScriptRoot\..\scripts\run_toolchain_study.ps1" "$temp\scripts"
    Copy-Item "$PSScriptRoot\..\benchmark.json" $temp
    @'
param($Root, $ResultsDir, $Generator, $Toolchain, [int]$Parallel, $Label)
@{ generator=$Generator; toolchain=$Toolchain; parallel=$Parallel; label=$Label } |
    ConvertTo-Json -Compress | Add-Content "$ResultsDir\calls.jsonl"
'@ | Set-Content "$temp\scripts\run.ps1"
    foreach ($candidate in @('Clang', 'MSVC2026')) {
        $generator = if ($candidate -eq 'Clang') { 'Ninja' } else { 'MSBuild' }
        foreach ($toolchain in @('MSVC', $candidate)) {
            $build = Get-BuildDirectory "$temp\source" $generator $toolchain
            New-Item -ItemType Directory $build -Force | Out-Null
            '{}' | Set-Content "$build\benchmark-setup.json"
            if ($generator -eq 'Ninja') {
                'fixture' | Set-Content "$build\build.ninja"
                # A harmless --version executable stands in for Ninja; no native build runs.
                "CMAKE_MAKE_PROGRAM:FILEPATH=$((Get-Process -Id $PID).Path)" | Set-Content "$build\CMakeCache.txt"
            } else {
                '<Project />' | Set-Content "$build\fixture.vcxproj"
                $extension = if ($toolchain -eq 'MSVC2026') { 'slnx' } else { 'sln' }
                'fixture solution' | Set-Content "$build\fixture.$extension"
            }
        }
        $results = "$temp\results_$candidate"
        & "$temp\scripts\run_toolchain_study.ps1" -Root "$temp\source" -ResultsDir $results `
            -CandidateToolchain $candidate -PauseSeconds 0
        $calls = @(Get-Content "$results\calls.jsonl" | ConvertFrom-Json)
        $expected = @('MSVC', $candidate, $candidate, 'MSVC')
        $jobs = if ($candidate -eq 'Clang') { [Environment]::ProcessorCount } else { 0 }
        if ($calls.Count -ne 4 -or ($calls.toolchain -join ',') -ne ($expected -join ',')) {
            throw ' ERROR - Toolchain study order changed.'
        }
        foreach ($call in $calls) {
            if ($call.generator -ne $generator -or $call.parallel -ne $jobs) {
                throw ' ERROR - Toolchain study generator or default parallelism changed.'
            }
        }
        $manifest = Get-Content "$results\study.json" -Raw | ConvertFrom-Json
        if (-not $manifest.finished_at -or $manifest.generator -ne $generator) {
            throw ' ERROR - Completed study manifest is incorrect.'
        }
        if ($generator -eq 'MSBuild' -and
            -not ($manifest.build_graph_sha256.PSObject.Properties.Name -match '\.slnx$')) {
            throw ' ERROR - VS 2026 SLNX solution hash is missing.'
        }
        $failed = $false
        try {
            & "$temp\scripts\run_toolchain_study.ps1" -Root "$temp\source" -ResultsDir $results `
                -CandidateToolchain $candidate -PauseSeconds 0
        } catch {
            if ($_.Exception.Message -notmatch 'directory already exists') { throw }
            $failed = $true
        }
        if (-not $failed) { throw ' ERROR - Existing study could be overwritten.' }
    }
    Write-Host 'PASS: both study protocols, ABBA ordering, default worker options and overwrite protection (mock builds).'
} finally {
    Get-ChildItem -LiteralPath $temp -Recurse -File | ForEach-Object { Remove-Item -LiteralPath $_.FullName }
    Get-ChildItem -LiteralPath $temp -Recurse -Directory | Sort-Object { $_.FullName.Length } -Descending |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName }
    Remove-Item -LiteralPath $temp
}
