#Requires -Version 7.0
. "$PSScriptRoot\..\scripts\common.ps1"
$temp = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
New-Item -ItemType Directory "$temp\scripts" -Force | Out-Null
try {
    Copy-Item "$PSScriptRoot\..\scripts\common.ps1", "$PSScriptRoot\..\scripts\run_toolchain_study.ps1" "$temp\scripts"
    Copy-Item "$PSScriptRoot\..\benchmark.json" $temp
    New-Item -ItemType Directory "$temp\toolchains" | Out-Null
    Copy-Item "$PSScriptRoot\..\toolchains\vs2026.json", "$PSScriptRoot\..\toolchains\windows-sdk.json" "$temp\toolchains"
    @'
param($Root, $ResultsDir, $Generator, $Toolchain, [int]$Parallel, $Label)
@{ generator=$Generator; toolchain=$Toolchain; parallel=$Parallel; label=$Label } |
    ConvertTo-Json -Compress | Add-Content "$ResultsDir\calls.jsonl"
'@ | Set-Content "$temp\scripts\run.ps1"
    foreach ($candidate in @('Clang', 'MSVC2026', 'MSVC2026Latest')) {
        $generator = if ($candidate -eq 'Clang') { 'Ninja' } else { 'MSBuild' }
        $baseline = if ($candidate -eq 'MSVC2026Latest') { 'MSVC2026' } else { 'MSVC' }
        foreach ($toolchain in @($baseline, $candidate)) {
            $build = Get-BuildDirectory "$temp\source" $generator $toolchain
            New-Item -ItemType Directory $build -Force | Out-Null
            '{}' | Set-Content "$build\benchmark-setup.json"
            if ($generator -eq 'Ninja') {
                'fixture' | Set-Content "$build\build.ninja"
                # A harmless --version executable stands in for Ninja; no native build runs.
                "CMAKE_MAKE_PROGRAM:FILEPATH=$((Get-Process -Id $PID).Path)" | Set-Content "$build\CMakeCache.txt"
            } else {
                '<Project />' | Set-Content "$build\fixture.vcxproj"
                $extension = if ($toolchain -in @('MSVC2026', 'MSVC2026Latest')) { 'slnx' } else { 'sln' }
                'fixture solution' | Set-Content "$build\fixture.$extension"
            }
        }
        $results = "$temp\results_$candidate"
        $blocks = if ($candidate -eq 'MSVC2026Latest') { 2 } else { 1 }
        & "$temp\scripts\run_toolchain_study.ps1" -Root "$temp\source" -ResultsDir $results `
            -CandidateToolchain $candidate -Blocks $blocks -PauseSeconds 0
        $calls = @(Get-Content "$results\calls.jsonl" | ConvertFrom-Json)
        $expected = @($baseline, $candidate, $candidate, $baseline)
        if ($blocks -eq 2) { $expected += @($candidate, $baseline, $baseline, $candidate) }
        $jobs = if ($candidate -eq 'Clang') { [Environment]::ProcessorCount } else { 0 }
        if ($calls.Count -ne (4 * $blocks) -or ($calls.toolchain -join ',') -ne ($expected -join ',')) {
            throw ' ERROR - Toolchain study order changed.'
        }
        if (@($calls.label | Select-Object -Unique).Count -ne $calls.Count) {
            throw ' ERROR - Study labels must remain unique across blocks.'
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
    Write-Host 'PASS: three study protocols, ABBA/BAAB ordering, default worker options and overwrite protection (mock builds).'
} finally {
    Get-ChildItem -LiteralPath $temp -Recurse -File | ForEach-Object { Remove-Item -LiteralPath $_.FullName }
    Get-ChildItem -LiteralPath $temp -Recurse -Directory | Sort-Object { $_.FullName.Length } -Descending |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName }
    Remove-Item -LiteralPath $temp
}
