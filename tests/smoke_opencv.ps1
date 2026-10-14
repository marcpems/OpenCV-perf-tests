#Requires -Version 7.0
param(
    [string]$Root = '',
    [ValidateSet('MSVC', 'Clang')][string]$Toolchain = 'MSVC'
)
. "$PSScriptRoot\..\scripts\common.ps1"
$Root = Get-SourceRoot $Root
$buildDir = Get-BuildDirectory $Root 'Ninja' $Toolchain
$receipt = Get-Content "$buildDir\benchmark-setup.json" -Raw | ConvertFrom-Json
$cmake = Get-CMake $receipt.cmake
Set-NativeToolchain $receipt.visual_studio
$output = [IO.Path]::GetFullPath("$PSScriptRoot\..\.work\smoke_$Toolchain")
New-Item -ItemType Directory -Force $output | Out-Null
$ninja = (Get-Command ninja -CommandType Application | Select-Object -First 1).Source
$packages = @(Get-ChildItem "$buildDir\install" -Recurse -Filter OpenCVConfig.cmake |
    Where-Object { Test-Path "$($_.DirectoryName)\OpenCVModules.cmake" })
if ($packages.Count -ne 1) { throw ' ERROR - Concrete installed OpenCV CMake package is missing or ambiguous.' }
$argsList = @('-S', $PSScriptRoot, '-B', $output, '-G', 'Ninja',
    '-DCMAKE_BUILD_TYPE=Release', "-DOpenCV_DIR=$($packages[0].DirectoryName)",
    "-DCMAKE_CXX_COMPILER=$($receipt.compiler)", "-DCMAKE_MAKE_PROGRAM=$ninja",
    '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL')
if ($Toolchain -eq 'Clang') {
    $env:PATH = "$($receipt.llvm.root)\bin;$env:PATH"
    $argsList += @("-DCMAKE_LINKER=$($receipt.llvm.linker)", '-DCMAKE_LINKER_TYPE=LLD',
        '-DCMAKE_CXX_FLAGS=-fno-delayed-template-parsing')
}
Invoke-Logged $cmake $argsList "$output\configure.log" | Out-Null
Invoke-Logged $cmake @('--build', $output, '--config', 'Release') "$output\build.log" | Out-Null
$versions = @(Get-ChildItem "$buildDir\install" -Recurse -Filter opencv_version.exe)
if ($versions.Count -ne 1) { throw ' ERROR - Installed OpenCV version executable is missing or ambiguous.' }
$env:PATH = "$($versions[0].DirectoryName);$env:PATH"
$exe = "$output\opencv_smoke.exe"
Assert-NativeExecutable $exe $receipt.architecture
Invoke-Logged $exe @() "$output\smoke.log" | Out-Null
Get-Content "$output\smoke.log"
