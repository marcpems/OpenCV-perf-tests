#Requires -Version 7.0
param([string]$Root = '', [Parameter(Mandatory)][string]$ResultsDir)
. "$PSScriptRoot\common.ps1"
. "$PSScriptRoot\compiler_commands.ps1"
$Root = Get-SourceRoot $Root
Assert-Source $Root
$ResultsDir = [IO.Path]::GetFullPath($ResultsDir, (Get-Location).ProviderPath)
if (Test-Path $ResultsDir) { throw ' ERROR - Choose a fresh architecture-audit directory.' }
New-Item -ItemType Directory $ResultsDir | Out-Null
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class CompilerArchitectureProbe {
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool IsWow64Process2(IntPtr process, out ushort processMachine, out ushort nativeMachine);
}
'@
$rows = @()
$lock = [IO.File]::Open("$Root\.hobl-benchmark.lock", 'OpenOrCreate', 'ReadWrite', 'None')
try {
    foreach ($toolchain in @('MSVC', 'Clang')) {
        $compile = Get-CompilerCommand $Root 'calib3d/src/dls.cpp' $toolchain
        Set-NativeToolchain $compile.Receipt.visual_studio $compile.Receipt.windows_sdk
        $output = Join-Path $ResultsDir $toolchain
        New-Item -ItemType Directory $output | Out-Null
        $arguments = Set-CompilerOutputs $compile.Arguments $toolchain $output
        $process = [Diagnostics.Process]::new()
        try {
            $process.StartInfo = [Diagnostics.ProcessStartInfo]::new($compile.Executable, $arguments)
            $process.StartInfo.WorkingDirectory = $compile.Build
            $process.StartInfo.UseShellExecute = $false
            $process.StartInfo.RedirectStandardOutput = $true
            $process.StartInfo.RedirectStandardError = $true
            if (-not $process.Start()) { throw ' ERROR - Compiler architecture probe did not start.' }
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            [ushort]$processMachine = 0
            [ushort]$nativeMachine = 0
            if (-not [CompilerArchitectureProbe]::IsWow64Process2($process.Handle,
                    [ref]$processMachine, [ref]$nativeMachine)) {
                throw [ComponentModel.Win32Exception]::new()
            }
            $modules = @{}
            while (-not $process.HasExited) {
                $process.Refresh()
                foreach ($module in $process.Modules) {
                    if ($module.ModuleName -in @('cl.exe', 'clang++.exe', 'c1xx.dll', 'c2.dll')) {
                        $modules[$module.ModuleName] = $module.FileName
                    }
                }
                Start-Sleep -Milliseconds 100
            }
            $process.WaitForExit()
            ($stdout.Result + $stderr.Result) | Set-Content "$output\compile.log"
            if ($process.ExitCode -ne 0) { throw " ERROR - Architecture probe compilation failed: $toolchain" }
            if ($processMachine -ne 0 -or $nativeMachine -ne 0xAA64) {
                throw ' ERROR - Live compiler is not native ARM64.'
            }
            if ($toolchain -eq 'MSVC' -and
                (-not $modules.ContainsKey('c1xx.dll') -or -not $modules.ContainsKey('c2.dll'))) {
                throw ' ERROR - Frontend/backend loaded-module evidence is incomplete.'
            }
            $images = @()
            foreach ($name in $modules.Keys) {
                $path = $modules[$name]
                Assert-NativeExecutable $path 'arm64'
                $images += @{ name = $name; path = $path; machine = '0xAA64'; sha256 = (Get-FileHash $path).Hash }
            }
            Assert-Arm64Object "$output\unit.obj"
            $rows += @{
                toolchain = $toolchain; executable = $compile.Executable; arguments = $arguments
                process_machine = ('0x{0:X4}' -f $processMachine)
                native_machine = ('0x{0:X4}' -f $nativeMachine)
                loaded_images = $images; exit_code = $process.ExitCode
            }
        } finally { $process.Dispose() }
    }
} finally { $lock.Dispose() }
$rows | ConvertTo-Json -Depth 6 | Set-Content "$ResultsDir\architecture.json"
$rows | ConvertTo-Json -Depth 6
