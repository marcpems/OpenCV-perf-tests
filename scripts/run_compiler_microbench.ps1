#Requires -Version 7.0
param(
    [string]$Root = '',
    [Parameter(Mandatory)][string]$ResultsDir,
    [string[]]$Sources = @('calib3d/src/dls.cpp', 'dnn/src/onnx/onnx_importer.cpp',
        'dnn/src/net_impl.cpp', 'dnn/src/tensorflow/tf_importer.cpp',
        'core/src/arithm.cpp', 'imgproc/src/resize.cpp', 'features2d/src/orb.cpp', 'core/src/alloc.cpp'),
    [ValidateSet('msvc', 'msvc_cg1', 'msvc_ehsc', 'msvc_Od', 'clang', 'clang_O2', 'clang_async', 'clang_O0',
        'clang_noalias')]
    [string[]]$Variants = @('msvc', 'clang'),
    [ValidateRange(1, 20)][int]$Repetitions = 4,
    [switch]$PhaseTiming,
    [string]$SourceOverride = ''
)
. "$PSScriptRoot\common.ps1"
. "$PSScriptRoot\compiler_commands.ps1"
Assert-NoPendingToolchainRestart
Assert-WindowsSDKRestart
$Root = Get-SourceRoot $Root
Assert-Source $Root
$ResultsDir = [IO.Path]::GetFullPath($ResultsDir, (Get-Location).ProviderPath)
if (Test-Path $ResultsDir) { throw ' ERROR - Choose a fresh microbenchmark directory.' }
foreach ($name in @('CL', '_CL_', 'CFLAGS', 'CXXFLAGS')) {
    if ([Environment]::GetEnvironmentVariable($name)) { throw " ERROR - Unset $name before benchmarking." }
}
if (@($Sources | Select-Object -Unique).Count -ne $Sources.Count -or
    @($Variants | Select-Object -Unique).Count -ne $Variants.Count) {
    throw ' ERROR - Duplicate sources or variants would overwrite measurements.'
}
if ($SourceOverride) {
    if ($Sources.Count -ne 1) { throw ' ERROR - A source override requires exactly one original source.' }
    $SourceOverride = (Resolve-Path -LiteralPath $SourceOverride).ProviderPath
}
if (-not ('BuildAccounting' -as [type])) { Add-Type -Path "$PSScriptRoot\BuildAccounting.cs" }
$commands = @{}
$frozen = @{}
if ($SourceOverride) { $frozen[$SourceOverride] = (Get-FileHash $SourceOverride).Hash }
foreach ($name in @('run_compiler_microbench.ps1', 'compiler_commands.ps1', 'common.ps1',
        'BuildAccounting.cs', '..\benchmark.json')) {
    $path = [IO.Path]::GetFullPath("$PSScriptRoot\$name")
    $frozen[$path] = (Get-FileHash $path).Hash
}
foreach ($source in $Sources) {
    $path = [IO.Path]::GetFullPath("$Root\modules\$source")
    $frozen[$path] = (Get-FileHash $path).Hash
    foreach ($toolchain in @('MSVC', 'Clang')) {
        $compile = Get-CompilerCommand $Root $source $toolchain
        $commands["$source|$toolchain"] = $compile
        foreach ($name in @('benchmark-setup.json', 'CMakeCache.txt', 'build.ninja', 'CMakeFiles\rules.ninja')) {
            $path = "$($compile.Build)\$name"
            $frozen[$path] = (Get-FileHash $path).Hash
        }
        $frozen[$compile.Receipt.compiler] = $compile.Receipt.compiler_sha256
    }
}
New-Item -ItemType Directory $ResultsDir | Out-Null
$manifest = [ordered]@{
    status = 'running'; started_at = [datetimeoffset]::Now.ToString('o')
    sources = $Sources; variants = $Variants; repetitions = $Repetitions
    source_override = $SourceOverride
    warmups_per_source_variant = 1; phase_timing = [bool]$PhaseTiming
    frozen_sha256 = $frozen; runs = @()
}
$manifest | ConvertTo-Json -Depth 7 | Set-Content "$ResultsDir\study.json"
$lock = [IO.File]::Open("$Root\.hobl-benchmark.lock", 'OpenOrCreate', 'ReadWrite', 'None')
try {
    foreach ($source in $Sources) {
        for ($repeat = 0; $repeat -le $Repetitions; $repeat++) {
            $order = @($Variants)
            if ($repeat % 2 -eq 0 -and $repeat -gt 0) { [array]::Reverse($order) }
            foreach ($variant in $order) {
                $toolchain = if ($variant.StartsWith('msvc')) { 'MSVC' } else { 'Clang' }
                $compile = $commands["$source|$toolchain"]
                Set-NativeToolchain $compile.Receipt.visual_studio $compile.Receipt.windows_sdk
                $label = "$($source.Replace('/', '_').Replace('\', '_'))_${variant}_$repeat"
                $output = Join-Path $ResultsDir $label
                New-Item -ItemType Directory $output | Out-Null
                $arguments = Set-CompilerOutputs $compile.Arguments $toolchain $output
                if ($SourceOverride) {
                    $sourcePath = "$Root\modules\$source"
                    $pattern = [regex]::Escape($sourcePath.Replace('\', '/')).Replace('/', '[\\/]')
                    if ($arguments -notmatch $pattern) { throw ' ERROR - Original source argument not found.' }
                    $arguments = $arguments -replace "(?:`"$pattern`"|$pattern)(?=\s|$)", "`"$SourceOverride`""
                    $arguments += " -I`"$([IO.Path]::GetDirectoryName($sourcePath))`""
                }
                switch ($variant) {
                    'msvc_cg1' { $arguments += ' /cgthreads1' }
                    'msvc_ehsc' {
                        if ($arguments -notmatch ' /EHa(?:\s|$)') { throw ' ERROR - Expected /EHa baseline.' }
                        $arguments = $arguments -replace ' /EHa(?=\s|$)', ' /EHsc'
                    }
                    'msvc_Od' {
                        if ($arguments -notmatch ' /O2(?:\s|$)') { throw ' ERROR - Expected /O2 baseline.' }
                        $arguments = $arguments -replace ' /O2(?=\s|$)', ' /Od'
                        $arguments = $arguments -replace ' /Ob2(?=\s|$)', ' /Ob0'
                    }
                    'clang_O2' {
                        if ($arguments -notmatch ' -O3(?:\s|$)') { throw ' ERROR - Expected -O3 baseline.' }
                        $arguments = $arguments -replace ' -O3(?=\s|$)', ' -O2'
                    }
                    'clang_async' { $arguments += ' -fasync-exceptions' }
                    'clang_noalias' { $arguments += ' -fno-strict-aliasing' }
                    'clang_O0' {
                        if ($arguments -notmatch ' -O3(?:\s|$)') { throw ' ERROR - Expected -O3 baseline.' }
                        $arguments = $arguments -replace ' -O3(?=\s|$)', ' -O0'
                    }
                }
                if ($PhaseTiming) {
                    $arguments += if ($toolchain -eq 'MSVC') { ' /Bt+' }
                        else { " -ftime-trace=`"$output\clang-time.json`"" }
                }
                $accounting = [BuildAccounting]::Run($compile.Executable, $arguments,
                    $compile.Build, "$output\compile.log")
                $row = [ordered]@{
                    label = $label; source = $source; variant = $variant; repetition = $repeat
                    source_override = $SourceOverride
                    warmup = ($repeat -eq 0); phase_timing = [bool]$PhaseTiming
                    original_command = $compile.Command; executable = $compile.Executable
                    arguments = $arguments; accounting = $accounting
                }
                $row | ConvertTo-Json -Depth 5 | Set-Content "$output\metadata.json"
                if ($accounting.ExitCode -ne 0) { throw " ERROR - Compilation failed: $output" }
                $object = "$output\unit.obj"
                if (-not (Test-Path $object)) { throw " ERROR - Compiler produced no object: $output" }
                Assert-Arm64Object $object
                $row['object_bytes'] = (Get-Item $object).Length
                $row['object_sha256'] = (Get-FileHash $object).Hash
                $row | ConvertTo-Json -Depth 5 | Set-Content "$output\metadata.json"
                $manifest.runs += $label
                $manifest | ConvertTo-Json -Depth 7 | Set-Content "$ResultsDir\study.json"
                Write-Host "$label : wall=$($accounting.WallSeconds), CPU=$($accounting.CpuSeconds)"
            }
        }
    }
    foreach ($path in $frozen.Keys) {
        if ((Get-FileHash $path).Hash -ne $frozen[$path]) { throw " ERROR - Frozen input changed: $path" }
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
    $manifest | ConvertTo-Json -Depth 7 | Set-Content "$ResultsDir\study.json"
}
