#Requires -Version 7.0
param(
    [string]$Root = '',
    [string]$ResultsDir = "$PSScriptRoot\..\results\local\translation-unit-trace"
)
. "$PSScriptRoot\common.ps1"
. "$PSScriptRoot\compiler_commands.ps1"
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
            $compile = Get-CompilerCommand $Root $source $toolchain
            $build = $compile.Build
            $receipt = $compile.Receipt
            Set-NativeToolchain $receipt.visual_studio $receipt.windows_sdk
            $command = $compile.Command
            $executable = $compile.Executable
            $name = $source.Replace('/', '_').Replace('.cpp', '') + "_$toolchain"
            $output = Join-Path $ResultsDir $name
            New-Item -ItemType Directory $output | Out-Null
            $arguments = Set-CompilerOutputs $compile.Arguments $toolchain $output
            if ($toolchain -eq 'MSVC') {
                $arguments += ' /Bt+'
            } else {
                $arguments += " -ftime-trace=`"$output\clang-time.json`""
            }
            $result = [BuildAccounting]::Run($executable, $arguments, $build, "$output\compile.log")
            $row = @{
                source = $source; toolchain = $toolchain; original_command = $command
                executable = $executable; arguments = $arguments; accounting = $result
                compiler_sha256 = $receipt.compiler_sha256
                accounting_source_sha256 = (Get-FileHash "$PSScriptRoot\BuildAccounting.cs").Hash
                profiler_sha256 = (Get-FileHash $PSCommandPath).Hash
                command_helper_sha256 = (Get-FileHash "$PSScriptRoot\compiler_commands.ps1").Hash
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
