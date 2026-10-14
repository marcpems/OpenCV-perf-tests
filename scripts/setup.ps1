#Requires -Version 7.0
param(
    [string]$Root = '',
    [ValidateSet('MSBuild', 'Ninja')][string]$Generator = 'MSBuild',
    [ValidateSet('MSVC', 'Clang')][string]$Toolchain = 'MSVC',
    [string]$LLVMRoot = '',
    [string]$CMake = ''
)
. "$PSScriptRoot\common.ps1"
$Root = Get-SourceRoot $Root
$Generator = Get-EffectiveGenerator $Generator $Toolchain ($PSBoundParameters.ContainsKey('Generator'))
if ($LLVMRoot -and $Toolchain -ne 'Clang') { throw ' ERROR - LLVMRoot is only valid with -Toolchain Clang.' }
$cmakeExe = Get-CMake $CMake
$vs = Get-VisualStudio
$arch = Get-NativeArchitecture
if (-not (Test-Path $Root)) {
    & git clone --depth 1 --branch $script:Config.opencv_tag https://github.com/opencv/opencv.git $Root
    if ($LASTEXITCODE -ne 0) { throw ' ERROR - OpenCV clone failed.' }
}
Assert-Source $Root
$buildDir = Get-BuildDirectory $Root $Generator $Toolchain
$llvm = if ($Toolchain -eq 'Clang') { Get-ClangToolchain $LLVMRoot } else { $null }
New-Item -ItemType Directory -Force $buildDir | Out-Null
$argsList = @('-S', $Root, '-B', $buildDir) + @($script:Config.cmake_flags)
if ($Generator -eq 'MSBuild') {
    $argsList += @('-G', 'Visual Studio 17 2022', "-DCMAKE_GENERATOR_INSTANCE=$($vs.path)")
} else {
    Set-NativeToolchain $vs
    $ninja = (Get-Command ninja -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $argsList += @('-G', 'Ninja', "-DCMAKE_MAKE_PROGRAM=$ninja")
    if ($llvm) {
        $env:PATH = "$($llvm.root)\bin;$env:PATH"
        # Standard lookup avoids cv::float32_t shadowing Clang's NEON typedef inside delayed templates.
        $argsList += @("-DCMAKE_C_COMPILER=$($llvm.c)", "-DCMAKE_CXX_COMPILER=$($llvm.cxx)",
            "-DCMAKE_LINKER=$($llvm.linker)", '-DCMAKE_LINKER_TYPE=LLD',
            "-DCMAKE_AR=$($llvm.ar)", "-DCMAKE_RANLIB=$($llvm.ranlib)",
            '-DCMAKE_CXX_FLAGS=-fno-delayed-template-parsing')
    } else {
        $argsList += @('-DCMAKE_C_COMPILER=cl', '-DCMAKE_CXX_COMPILER=cl')
    }
}
$configureTime = Invoke-Logged $cmakeExe $argsList "$buildDir\configure.log"
$compilerFile = "$buildDir\CMakeFiles\$($script:Config.cmake_version)\CMakeCXXCompiler.cmake"
$compilerInfo = Get-Content $compilerFile -Raw
if ($compilerInfo -notmatch 'set\(CMAKE_CXX_COMPILER "([^"]+)"\)') { throw ' ERROR - Cannot determine configured C++ compiler.' }
$compiler = $Matches[1]
$compilerFacts = @{}
foreach ($key in @('ID', 'VERSION', 'FRONTEND_VARIANT')) {
    if ($compilerInfo -notmatch ('set\(CMAKE_CXX_COMPILER_' + $key + ' "([^"]*)"\)')) {
        throw " ERROR - Cannot read CMake compiler $key."
    }
    $compilerFacts[$key] = $Matches[1]
}
if ($llvm -and ($compilerFacts.ID -ne 'Clang' -or $compilerFacts.FRONTEND_VARIANT -ne 'GNU')) {
    throw ' ERROR - Expected Clang with the GNU-style frontend.'
}
if ($Toolchain -eq 'MSVC' -and $compiler -notmatch "Host$arch/$arch/cl.exe") {
    throw " ERROR - Expected native MSVC compiler; got $compiler"
}
if ($llvm -and [IO.Path]::GetFullPath($compiler) -ne [IO.Path]::GetFullPath($llvm.cxx)) {
    throw " ERROR - CMake selected a different Clang executable: $compiler"
}
Assert-NativeExecutable $compiler $arch
$compilerHash = (Get-FileHash $compiler -Algorithm SHA256).Hash
$receipt = [ordered]@{
    hobl_commit = $script:Config.hobl_commit
    opencv_commit = $script:Config.opencv_commit
    cmake_version = $script:Config.cmake_version
    cmake = $cmakeExe
    generator = $Generator
    toolchain = $Toolchain
    llvm = $llvm
    architecture = $arch
    configure_seconds = $configureTime
    configure_arguments = $argsList
    compiler = $compiler
    compiler_id = $compilerFacts.ID
    compiler_version = $compilerFacts.VERSION
    compiler_frontend = $compilerFacts.FRONTEND_VARIANT
    compiler_sha256 = $compilerHash
    visual_studio = $vs
    config_sha256 = (Get-FileHash "$PSScriptRoot\..\benchmark.json").Hash
}
$receipt | ConvertTo-Json -Depth 6 | Set-Content "$buildDir\benchmark-setup.json"
Write-Host "Configured $buildDir in ${configureTime}s (excluded from benchmark)."
