#Requires -Version 7.0
param(
    [string]$Root = '',
    [ValidateSet('MSVC', 'Clang', 'MSVC2026')][string]$Toolchain = 'MSVC',
    [ValidateSet('MSBuild', 'Ninja')][string]$Generator = 'Ninja'
)
. "$PSScriptRoot\..\scripts\common.ps1"
$Root = Get-SourceRoot $Root
$Generator = Get-EffectiveGenerator $Generator $Toolchain ($PSBoundParameters.ContainsKey('Generator'))
$buildDir = Get-BuildDirectory $Root $Generator $Toolchain
$receipt = Get-Content "$buildDir\benchmark-setup.json" -Raw | ConvertFrom-Json
$cmake = Get-CMake $receipt.cmake (Get-ToolchainCMakeVersion $Toolchain)
Set-NativeToolchain $receipt.visual_studio
$output = [IO.Path]::GetFullPath("$PSScriptRoot\..\.work\smoke_${Toolchain}_$Generator")
New-Item -ItemType Directory -Force $output | Out-Null
$packages = @(Get-ChildItem "$buildDir\install" -Recurse -Filter OpenCVConfig.cmake |
    Where-Object { Test-Path "$($_.DirectoryName)\OpenCVModules.cmake" })
if ($packages.Count -ne 1) { throw ' ERROR - Concrete installed OpenCV CMake package is missing or ambiguous.' }
$argsList = @('-S', $PSScriptRoot, '-B', $output,
    '-DCMAKE_BUILD_TYPE=Release', "-DOpenCV_DIR=$($packages[0].DirectoryName)",
    '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL')
if ($Generator -eq 'MSBuild') {
    $vsGenerator = if ($Toolchain -eq 'MSVC2026') { 'Visual Studio 18 2026' } else { 'Visual Studio 17 2022' }
    $argsList += @('-G', $vsGenerator, "-DCMAKE_GENERATOR_INSTANCE=$($receipt.visual_studio.path)")
} else {
    $ninja = (Get-Command ninja -CommandType Application | Select-Object -First 1).Source
    $argsList += @('-G', 'Ninja', "-DCMAKE_CXX_COMPILER=$($receipt.compiler)", "-DCMAKE_MAKE_PROGRAM=$ninja")
}
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
$exe = if ($Generator -eq 'MSBuild') { "$output\Release\opencv_smoke.exe" } else { "$output\opencv_smoke.exe" }
Assert-NativeExecutable $exe $receipt.architecture
Invoke-Logged $exe @() "$output\smoke.log" | Out-Null
Get-Content "$output\smoke.log"
