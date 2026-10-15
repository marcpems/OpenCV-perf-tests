#Requires -Version 7.0
param(
    [string]$Root = '',
    [Parameter(Mandatory)][string]$BaselineStudy,
    [Parameter(Mandatory)][string]$ResultsDir,
    [ValidateRange(1, 20)][int]$Copies = 3,
    [ValidateRange(1, 256)][int]$Jobs = 12,
    [ValidateRange(2, 10)][int]$Repetitions = 2
)
. "$PSScriptRoot\common.ps1"
. "$PSScriptRoot\compiler_commands.ps1"
$Root = Get-SourceRoot $Root
Assert-Source $Root
$baseline = Get-Content "$BaselineStudy\study.json" -Raw | ConvertFrom-Json
if ($baseline.status -ne 'succeeded' -or $baseline.phase_timing -or $baseline.source_override) {
    throw ' ERROR - Expected a successful unmodified, uninstrumented source study.'
}
$ResultsDir = [IO.Path]::GetFullPath($ResultsDir, (Get-Location).ProviderPath)
if (Test-Path $ResultsDir) { throw ' ERROR - Choose a fresh batch directory.' }
foreach ($entry in $baseline.frozen_sha256.PSObject.Properties) {
    if ((Get-FileHash $entry.Name).Hash -ne $entry.Value) { throw " ERROR - Baseline input changed: $($entry.Name)" }
}
New-Item -ItemType Directory $ResultsDir | Out-Null
Add-Type -Path "$PSScriptRoot\BuildAccounting.cs"
$variants = @('msvc', 'msvc_cg1', 'clang', 'clang_async')
$configurations = @{}
$frozen = @{}
foreach ($source in $baseline.sources) {
    foreach ($toolchain in @('MSVC', 'Clang')) {
        $configurations["$source|$toolchain"] = Get-CompilerCommand $Root $source $toolchain
    }
}
foreach ($name in @('run_compiler_batch.ps1', 'compiler_commands.ps1', 'BuildAccounting.cs')) {
    $path = "$PSScriptRoot\$name"
    $frozen[$path] = (Get-FileHash $path).Hash
}
$manifest = [ordered]@{
    status = 'running'; started_at = [datetimeoffset]::Now.ToString('o')
    source_study = [IO.Path]::GetFullPath($BaselineStudy, (Get-Location).ProviderPath)
    sources = $baseline.sources; copies = $Copies; jobs = $Jobs
    variants = $variants; repetitions = $Repetitions; warmups_per_variant = 1
    frozen_sha256 = $frozen; runs = @()
}
$lock = [IO.File]::Open("$Root\.hobl-benchmark.lock", 'OpenOrCreate', 'ReadWrite', 'None')
try {
    for ($repeat = 0; $repeat -le $Repetitions; $repeat++) {
        $order = @($variants)
        if ($repeat -gt 0 -and $repeat % 2 -eq 0) { [array]::Reverse($order) }
        foreach ($variant in $order) {
            $toolchain = if ($variant.StartsWith('msvc')) { 'MSVC' } else { 'Clang' }
            $label = "${variant}_$repeat"
            $output = Join-Path $ResultsDir $label
            New-Item -ItemType Directory $output | Out-Null
            $graph = @()
            $objects = @()
            $commands = @()
            $index = 0
            foreach ($source in $baseline.sources) {
                $compile = $configurations["$source|$toolchain"]
                for ($copy = 0; $copy -lt $Copies; $copy++) {
                    $directory = "$output\unit$index"
                    New-Item -ItemType Directory $directory | Out-Null
                    $arguments = Set-CompilerOutputs $compile.Arguments $toolchain $directory
                    if ($variant -eq 'msvc_cg1') { $arguments += ' /cgthreads1' }
                    if ($variant -eq 'clang_async') { $arguments += ' -fasync-exceptions' }
                    if ($toolchain -eq 'Clang') {
                        $arguments = $arguments -replace ' -MT (?:"[^"]+"|\S+)', " -MT unit$index/unit.obj"
                    }
                    $command = "`"$($compile.Executable)`" $arguments"
                    $graph += "rule cc$index"
                    $graph += '  command = ' + $command.Replace('$', '$$')
                    if ($toolchain -eq 'MSVC') { $graph += '  deps = msvc' }
                    else { $graph += @('  deps = gcc', "  depfile = unit$index/unit.d") }
                    $graph += "build unit$index/unit.obj: cc$index"
                    $objects += "$directory\unit.obj"
                    $commands += @{ source = $source; command = $command }
                    $index++
                }
            }
            $graph | Set-Content "$output\build.ninja"
            $commands | ConvertTo-Json -Depth 4 | Set-Content "$output\commands.json"
            Set-NativeToolchain $compile.Receipt.visual_studio $compile.Receipt.windows_sdk
            $entry = Select-String "$($compile.Build)\CMakeCache.txt" -Pattern '^CMAKE_MAKE_PROGRAM:[^=]+=(.+)$'
            $ninja = $entry.Matches[0].Groups[1].Value
            $ninjaHash = (Get-FileHash $ninja).Hash
            if ($frozen.ContainsKey($ninja) -and $frozen[$ninja] -ne $ninjaHash) {
                throw ' ERROR - Ninja changed between batch runs.'
            }
            $frozen[$ninja] = $ninjaHash
            $accounting = [BuildAccounting]::Run($ninja, "-j $Jobs", $output, "$output\build.log")
            $row = @{
                label = $label; variant = $variant; repetition = $repeat; warmup = ($repeat -eq 0)
                compile_count = $index; accounting = $accounting
            }
            $row | ConvertTo-Json -Depth 5 | Set-Content "$output\metadata.json"
            if ($accounting.ExitCode -ne 0) { throw " ERROR - Compiler batch failed: $label" }
            foreach ($object in $objects) { Assert-Arm64Object $object }
            Copy-Item "$output\.ninja_log" "$output\ninja_log.txt"
            $manifest.runs += $label
            $manifest | ConvertTo-Json -Depth 6 | Set-Content "$ResultsDir\study.json"
            Write-Host "$label : wall=$($accounting.WallSeconds), CPU=$($accounting.CpuSeconds), commands=$index"
        }
    }
    foreach ($path in $frozen.Keys) {
        if ((Get-FileHash $path).Hash -ne $frozen[$path]) { throw " ERROR - Batch input changed: $path" }
    }
    foreach ($entry in $baseline.frozen_sha256.PSObject.Properties) {
        if ((Get-FileHash $entry.Name).Hash -ne $entry.Value) { throw " ERROR - Baseline input changed: $($entry.Name)" }
    }
    Assert-Source $Root
    $manifest.status = 'succeeded'
    $manifest['finished_at'] = [datetimeoffset]::Now.ToString('o')
} catch {
    $manifest.status = 'failed'
    $manifest['error'] = $_.Exception.Message
    throw
} finally {
    $lock.Dispose()
    $manifest | ConvertTo-Json -Depth 6 | Set-Content "$ResultsDir\study.json"
}
