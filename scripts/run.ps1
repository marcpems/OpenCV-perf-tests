#Requires -Version 7.0
param(
    [string]$Root = '',
    [string]$ResultsDir = "$PSScriptRoot\..\results\local",
    [ValidatePattern('^[A-Za-z0-9_-]+$')][string]$Label = 'hobl_baseline',
    [ValidateSet('MSBuild', 'Ninja')][string]$Generator = 'MSBuild',
    [ValidateSet('MSVC', 'Clang', 'MSVC2026')][string]$Toolchain = 'MSVC',
    [ValidateRange(0, 256)][int]$Parallel = 0,
    [switch]$Profile
)
. "$PSScriptRoot\common.ps1"
Assert-NoPendingToolchainRestart
if ($Toolchain -eq 'Clang' -and -not $PSBoundParameters.ContainsKey('Label')) { $Label = 'clang_experiment' }
if ($Toolchain -eq 'MSVC2026' -and -not $PSBoundParameters.ContainsKey('Label')) { $Label = 'vs2026_experiment' }
$Root = Get-SourceRoot $Root
$Generator = Get-EffectiveGenerator $Generator $Toolchain ($PSBoundParameters.ContainsKey('Generator'))
Assert-Source $Root
$buildDir = Get-BuildDirectory $Root $Generator $Toolchain
if (-not (Test-Path "$buildDir\benchmark-setup.json")) { throw ' ERROR - Run setup.ps1 for this generator first.' }
$receipt = Get-Content "$buildDir\benchmark-setup.json" -Raw | ConvertFrom-Json
$receiptToolchain = if ($receipt.PSObject.Properties.Name -contains 'toolchain') { $receipt.toolchain } else { 'MSVC' }
if ($receiptToolchain -ne $Toolchain) { throw ' ERROR - Toolchain does not match the configured build directory.' }
if ($receipt.config_sha256 -ne (Get-FileHash "$PSScriptRoot\..\benchmark.json").Hash) {
    throw ' ERROR - Benchmark configuration changed; rerun setup.'
}
if ($receipt.compiler_sha256 -ne (Get-FileHash $receipt.compiler).Hash) {
    throw ' ERROR - Compiler changed since setup; rerun setup.'
}
if ($Generator -eq 'MSBuild') {
    $vsMajor = if ($Toolchain -eq 'MSVC2026') { 18 } else { 17 }
    $currentVS = Get-VisualStudio $vsMajor
    foreach ($field in @('path', 'version', 'tools', 'toolset')) {
        if ($currentVS.$field -ne $receipt.visual_studio.$field) {
            throw ' ERROR - Visual Studio instance or default toolset changed since setup; rerun setup.'
        }
    }
}
foreach ($name in @('CL', '_CL_', 'CMAKE_BUILD_PARALLEL_LEVEL', 'CMAKE_GENERATOR', 'CXXFLAGS', 'CFLAGS')) {
    if ([Environment]::GetEnvironmentVariable($name)) { throw " ERROR - Unset $name before benchmarking." }
}
$cmakeExe = Get-CMake $receipt.cmake (Get-ToolchainCMakeVersion $Toolchain)
if ($receipt.PSObject.Properties.Name -contains 'cmake_sha256' -and
    (Get-FileHash $cmakeExe).Hash -ne $receipt.cmake_sha256) {
    throw ' ERROR - CMake changed since setup; rerun setup.'
}
if ($receipt.PSObject.Properties.Name -contains 'build_engine' -and $receipt.build_engine) {
    if ((Get-FileHash $receipt.build_engine.path).Hash -ne $receipt.build_engine.sha256 -or
        (Get-FileHash $receipt.build_engine.linker).Hash -ne $receipt.build_engine.linker_sha256) {
        throw ' ERROR - MSBuild or linker changed since setup; rerun setup.'
    }
}
if ($Generator -eq 'Ninja') {
    if ($Profile) { throw ' ERROR - Profile uses MSBuild PerformanceSummary; Ninja already records per-step timings.' }
    Set-NativeToolchain $receipt.visual_studio
    if ($Toolchain -eq 'Clang') {
        foreach ($name in @('c', 'cxx', 'linker', 'ar', 'ranlib')) {
            Assert-NativeExecutable $receipt.llvm.$name $receipt.architecture
            if ((Get-FileHash $receipt.llvm.$name).Hash -ne $receipt.llvm."${name}_sha256") {
                throw " ERROR - Clang tool changed since setup: $name"
            }
        }
        $env:PATH = "$($receipt.llvm.root)\bin;$env:PATH"
    }
}
$ResultsDir = [IO.Path]::GetFullPath($ResultsDir, (Get-Location).ProviderPath)
$runDir = Join-Path $ResultsDir ("{0}_{1}" -f (Get-Date -Format 'yyyyMMdd_HHmmss_fff'), $Label)
New-Item -ItemType Directory -Force $runDir | Out-Null
$metadata = [ordered]@{
    status = 'running'
    label = $Label
    started_at = (Get-Date).ToString('o')
    generator = $Generator
    toolchain = $Toolchain
    parallel = $Parallel
    profile = [bool]$Profile
    setup = $receipt
    cpu = (Get-CimInstance Win32_Processor | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors)
    memory_gib = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 2)
    os = (Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber, OSArchitecture)
    power_scheme = (& powercfg /getactivescheme | Out-String).Trim()
    runner_sha256 = (Get-FileHash $PSCommandPath).Hash
}
$installationReceipt = "$PSScriptRoot\..\.tools\vs2026-installation.json"
if (Test-Path $installationReceipt) {
    $metadata['tool_installation'] = Get-Content $installationReceipt -Raw | ConvertFrom-Json
    $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime()
    $metadata['rebooted_since_tool_installation'] =
        [datetimeoffset]$boot -ne [datetimeoffset]$metadata.tool_installation.boot_time
}
$metadata | ConvertTo-Json -Depth 8 | Set-Content "$runDir\metadata.json"
$lock = $null
try {
    # Exclusive per-source lock prevents our MSBuild and Ninja experiments overlapping.
    $lock = [IO.File]::Open("$Root\.hobl-benchmark.lock", 'OpenOrCreate', 'ReadWrite', 'None')
    Push-Location $buildDir
    try {
        $clean = Invoke-Logged $cmakeExe @('--build', '.', '--target', 'clean', '--config', 'Release') "$runDir\clean.log"
        if ($Generator -eq 'Ninja' -and (Test-Path "$buildDir\.ninja_log")) {
            # Ninja clean preserves historical log entries. Each run must have an isolated log.
            Remove-Item -LiteralPath "$buildDir\.ninja_log"
        }
        $argsList = @('--build', '.', '--config', 'Release')
        if ($Parallel -gt 0) { $argsList += @('--parallel', "$Parallel") }
        if ($Profile) { $argsList += @('--', '/clp:PerformanceSummary;Summary', '/v:minimal') }
        $metadata['build_arguments'] = $argsList
        $build = Invoke-Logged $cmakeExe $argsList "$runDir\build.log"
        if ($Generator -eq 'Ninja') { Copy-Item "$buildDir\.ninja_log" "$runDir\ninja_log.txt" }
        $installTarget = if ($Generator -eq 'MSBuild') { 'INSTALL' } else { 'install' }
        $install = Invoke-Logged $cmakeExe @('--build', '.', '--target', $installTarget, '--config', 'Release') "$runDir\install.log"
        $versions = @(Get-ChildItem "$buildDir\install" -Recurse -Filter opencv_version.exe)
        if ($versions.Count -ne 1) { throw " ERROR - Expected one installed opencv_version.exe; found $($versions.Count)." }
        Assert-NativeExecutable $versions[0].FullName $receipt.architecture
        $version = & $versions[0].FullName
        if ($LASTEXITCODE -ne 0 -or "$version".Trim() -ne $script:Config.opencv_tag) {
            throw " ERROR - Installed executable validation failed: $version"
        }
        $version | Set-Content "$runDir\opencv_version.txt"
        & $versions[0].FullName --verbose *> "$runDir\opencv_build_info.txt"
        if ($LASTEXITCODE -ne 0) { throw ' ERROR - opencv_version --verbose failed.' }
        Copy-Item "$buildDir\CMakeCache.txt", "$buildDir\configure.log" $runDir
        $format = [Globalization.CultureInfo]::InvariantCulture
        $elapsed = ([datetimeoffset]::Now - [datetimeoffset]$metadata.started_at).TotalSeconds
        @(
            "scenario_runtime,$($build.ToString('F2', $format))"
            "build_time,$($build.ToString('F2', $format))"
            "architecture,$($receipt.architecture.ToUpperInvariant())"
            "clean_time,$($clean.ToString('F2', $format))"
            "install_time,$($install.ToString('F2', $format))"
        ) | Set-Content "$runDir\opencv_build_results.csv"
        @('Timestamp,opencv_build_time', "$($elapsed.ToString('F2', $format)),$($build.ToString('F2', $format))") |
            Set-Content "$runDir\opencv_build_results.trace"
        $metadata['status'] = 'succeeded'
        $metadata['build_seconds'] = $build
        $metadata['clean_seconds'] = $clean
        $metadata['install_seconds'] = $install
        $metadata['validated_version'] = "$version".Trim()
        Write-Host "scenario_runtime = build_time = ${build}s; clean = ${clean}s; install = ${install}s"
        Write-Host "Results: $runDir"
    } finally { Pop-Location }
} catch {
    $metadata['status'] = 'failed'
    $metadata['error'] = $_.Exception.Message
    throw
} finally {
    if ($lock) { $lock.Dispose() }
    $metadata['finished_at'] = (Get-Date).ToString('o')
    $metadata | ConvertTo-Json -Depth 8 | Set-Content "$runDir\metadata.json"
}
