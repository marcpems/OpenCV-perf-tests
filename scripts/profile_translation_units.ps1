#Requires -Version 7.0
param(
    [string]$Root = '',
    [string]$ResultsDir = "$PSScriptRoot\..\results\local\translation-unit-trace"
)
. "$PSScriptRoot\common.ps1"
Assert-NoPendingToolchainRestart
Assert-WindowsSDKRestart
$Root = Get-SourceRoot $Root
Assert-Source $Root
$ResultsDir = [IO.Path]::GetFullPath($ResultsDir, (Get-Location).ProviderPath)
if (Test-Path $ResultsDir) { throw ' ERROR - Choose a fresh profiling directory.' }
New-Item -ItemType Directory $ResultsDir | Out-Null
if (-not ('BuildAccounting' -as [type])) { Add-Type -Path "$PSScriptRoot\BuildAccounting.cs" }
foreach ($name in @('CL', '_CL_', 'CFLAGS', 'CXXFLAGS')) {
    if ([Environment]::GetEnvironmentVariable($name)) { throw " ERROR - Unset $name before profiling." }
}
$ninja = (Get-Command ninja -CommandType Application | Select-Object -First 1).Source
$cases = @(
    'calib3d/src/dls.cpp',
    'dnn/src/onnx/onnx_importer.cpp',
    'dnn/src/net_impl.cpp',
    'dnn/src/tensorflow/tf_importer.cpp'
)
$wpr = "$env:WINDIR\System32\wpr.exe"
$status = & $wpr -status 2>&1 | Out-String
if ($LASTEXITCODE -ne 0 -or $status -notmatch 'WPR is not recording') { throw ' ERROR - WPR is already recording or status unknown.' }
$instance = "OpenCVTU-$PID"
$lock = [IO.File]::Open("$Root\.hobl-benchmark.lock", 'OpenOrCreate', 'ReadWrite', 'None')
$recording = $false
$rows = @()
try {
    & $wpr -start CPU -start DiskIO -filemode -recordtempto $ResultsDir -instancename $instance *> "$ResultsDir\wpr-start.log"
    if ($LASTEXITCODE -ne 0) { throw ' ERROR - Translation-unit WPR start failed.' }
    $recording = $true
    foreach ($source in $cases) {
        foreach ($toolchain in @('MSVC', 'Clang')) {
            $build = Get-BuildDirectory $Root 'Ninja' $toolchain
            $receipt = Get-Content "$build\benchmark-setup.json" -Raw | ConvertFrom-Json
            Assert-WindowsSDK $receipt $toolchain
            if ((Get-FileHash $receipt.compiler).Hash -ne $receipt.compiler_sha256) { throw ' ERROR - Compiler changed.' }
            Set-NativeToolchain $receipt.visual_studio $receipt.windows_sdk
            $target = "modules/world/CMakeFiles/opencv_world.dir/__/$source.obj"
            $commands = @(& $ninja -C $build -t commands $target)
            if ($LASTEXITCODE -ne 0) { throw " ERROR - Cannot retrieve compile command: $source" }
            $sourcePath = "$Root/modules/$source".Replace('\', '/')
            $commands = @($commands | Where-Object {
                $_ -match '(?: -c | /c )' -and $_.Replace('\', '/').Contains($sourcePath)
            })
            if ($commands.Count -ne 1) { throw " ERROR - Expected one compile command for $source." }
            $command = $commands[0]
            if ($command -notmatch '^(?:"([^"]+)"|(\S+))\s+(.+)$') { throw ' ERROR - Cannot parse compiler command.' }
            $executable = if ($Matches[1]) { $Matches[1] } else { $Matches[2] }
            $arguments = $Matches[3]
            if ((Get-FileHash $executable).Hash -ne $receipt.compiler_sha256) { throw ' ERROR - Ninja command selects another compiler.' }
            $name = $source.Replace('/', '_').Replace('.cpp', '') + "_$toolchain"
            $output = Join-Path $ResultsDir $name
            New-Item -ItemType Directory $output | Out-Null
            if ($toolchain -eq 'MSVC') {
                if ($arguments -notmatch '/Fo\S+' -or $arguments -notmatch '/Fd\S+') { throw ' ERROR - Missing MSVC output flags.' }
                $arguments = $arguments -replace '/Fo(?:"[^"]+"|\S+)', "/Fo`"$output\unit.obj`""
                $arguments = $arguments -replace '/Fd(?:"[^"]+"|\S+)', "/Fd`"$output\unit.pdb`""
                $arguments += ' /Bt+'
            } else {
                if ($arguments -notmatch ' -o \S+' -or $arguments -notmatch ' -MF \S+') { throw ' ERROR - Missing Clang output flags.' }
                $arguments = $arguments -replace ' -o (?:"[^"]+"|\S+)', " -o `"$output\unit.obj`""
                $arguments = $arguments -replace ' -MF (?:"[^"]+"|\S+)', " -MF `"$output\unit.d`""
                $arguments += " -ftime-trace=`"$output\clang-time.json`""
            }
            $result = [BuildAccounting]::Run($executable, $arguments, $build, "$output\compile.log")
            $row = @{
                source = $source; toolchain = $toolchain; original_command = $command
                executable = $executable; arguments = $arguments; accounting = $result
                compiler_sha256 = $receipt.compiler_sha256
                accounting_source_sha256 = (Get-FileHash "$PSScriptRoot\BuildAccounting.cs").Hash
                profiler_sha256 = (Get-FileHash $PSCommandPath).Hash
            }
            $row | ConvertTo-Json -Depth 6 | Set-Content "$output\metadata.json"
            if ($result.ExitCode -ne 0) { throw " ERROR - Diagnostic compilation failed: $output" }
            $rows += $row
            Write-Host "$name : wall=$($result.WallSeconds), CPU=$($result.CpuSeconds)"
        }
    }
} finally {
    try {
        if ($recording) {
            & $wpr -stop "$ResultsDir\units.etl" -instancename $instance *> "$ResultsDir\wpr-stop.log"
            if ($LASTEXITCODE -ne 0) { throw " ERROR - Stop WPR failed for owned instance $instance." }
        }
    } finally { $lock.Dispose() }
}
$rows | ConvertTo-Json -Depth 6 | Set-Content "$ResultsDir\summary.json"
