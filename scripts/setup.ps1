#Requires -Version 7.0
param(
    [string]$Root = '',
    [ValidateSet('MSBuild', 'Ninja')][string]$Generator = 'MSBuild',
    [string]$CMake = ''
)
. "$PSScriptRoot\common.ps1"
$Root = Get-SourceRoot $Root
$cmakeExe = Get-CMake $CMake
$vs = Get-VisualStudio
$arch = Get-NativeArchitecture
if (-not (Test-Path $Root)) {
    & git clone --depth 1 --branch $script:Config.opencv_tag https://github.com/opencv/opencv.git $Root
    if ($LASTEXITCODE -ne 0) { throw ' ERROR - OpenCV clone failed.' }
}
Assert-Source $Root
$buildDir = Get-BuildDirectory $Root $Generator
New-Item -ItemType Directory -Force $buildDir | Out-Null
$argsList = @('-S', $Root, '-B', $buildDir) + @($script:Config.cmake_flags)
if ($Generator -eq 'MSBuild') {
    $argsList += @('-G', 'Visual Studio 17 2022', "-DCMAKE_GENERATOR_INSTANCE=$($vs.path)")
} else {
    Set-NativeToolchain $vs
    $ninja = (Get-Command ninja -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $argsList += @('-G', 'Ninja', '-DCMAKE_C_COMPILER=cl', '-DCMAKE_CXX_COMPILER=cl',
        "-DCMAKE_MAKE_PROGRAM=$ninja")
}
$configureTime = Invoke-Logged $cmakeExe $argsList "$buildDir\configure.log"
$compilerFile = "$buildDir\CMakeFiles\$($script:Config.cmake_version)\CMakeCXXCompiler.cmake"
$compilerInfo = Get-Content $compilerFile -Raw
if ($compilerInfo -notmatch 'set\(CMAKE_CXX_COMPILER "([^"]+)"\)') { throw ' ERROR - Cannot determine configured C++ compiler.' }
$compiler = $Matches[1]
if ($compiler -notmatch "Host$arch/$arch/cl.exe") { throw " ERROR - Expected native compiler; got $compiler" }
$compilerHash = (Get-FileHash $compiler -Algorithm SHA256).Hash
$receipt = [ordered]@{
    hobl_commit = $script:Config.hobl_commit
    opencv_commit = $script:Config.opencv_commit
    cmake_version = $script:Config.cmake_version
    cmake = $cmakeExe
    generator = $Generator
    architecture = $arch
    configure_seconds = $configureTime
    configure_arguments = $argsList
    compiler = $compiler
    compiler_sha256 = $compilerHash
    visual_studio = $vs
    config_sha256 = (Get-FileHash "$PSScriptRoot\..\benchmark.json").Hash
}
$receipt | ConvertTo-Json -Depth 6 | Set-Content "$buildDir\benchmark-setup.json"
Write-Host "Configured $buildDir in ${configureTime}s (excluded from benchmark)."
