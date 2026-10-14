# Copyright (c) Microsoft Corporation. HOBL configuration adapted under the MIT license.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Config = Get-Content (Join-Path $PSScriptRoot '..\benchmark.json') -Raw | ConvertFrom-Json

function Get-SourceRoot([string]$Root) {
    if (-not $Root) { $Root = Join-Path (Split-Path -Qualifier $PSScriptRoot) 'opencv' }
    return [IO.Path]::GetFullPath($Root)
}

function Get-NativeArchitecture {
    $arch = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
    if ($arch -notin @('arm64', 'x64')) { throw " ERROR - Unsupported architecture: $arch" }
    if ([Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToLowerInvariant() -ne $arch) {
        throw ' ERROR - Run native PowerShell 7 for this OS, not an emulated shell.'
    }
    return $arch
}

function Get-CMake([string]$CMake) {
    if (-not $CMake) {
        $portable = Join-Path $PSScriptRoot "..\.tools\cmake-$($script:Config.cmake_version)-windows-$(Get-NativeArchitecture)\bin\cmake.exe"
        $CMake = if (Test-Path $portable) { $portable } else { 'cmake' }
    }
    $exe = (Get-Command $CMake -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $version = & $exe --version
    if ($LASTEXITCODE -ne 0 -or $version[0] -ne "cmake version $($script:Config.cmake_version)") {
        throw " ERROR - CMake $($script:Config.cmake_version) required; found $($version[0]). Supply -CMake or install the pinned portable release."
    }
    Write-Host "CMake: $exe"
    return $exe
}

function Get-VisualStudio {
    $command = Get-Command vswhere.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    $vswhere = if ($command) { $command.Source } else {
        Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    }
    if (-not (Test-Path $vswhere)) { throw ' ERROR - vswhere.exe not found; install Visual Studio 2022 C++ tools.' }
    $instances = & $vswhere -version '[17.0,18.0)' -products '*' -format json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw ' ERROR - vswhere failed.' }
    $arch = Get-NativeArchitecture
    foreach ($instance in $instances) {
        $versionFile = Join-Path $instance.installationPath 'VC\Auxiliary\Build\Microsoft.VCToolsVersion.default.txt'
        if (-not (Test-Path $versionFile)) { continue }
        $toolset = (Get-Content $versionFile -Raw).Trim()
        $tools = Join-Path $instance.installationPath "VC\Tools\MSVC\$toolset"
        if (Test-Path "$tools\bin\Host$arch\$arch\cl.exe") {
            Write-Host "Visual Studio: $($instance.installationPath); MSVC: $toolset"
            return [pscustomobject]@{
                path = $instance.installationPath
                version = $instance.installationVersion
                tools = $tools
                toolset = $toolset
            }
        }
    }
    throw " ERROR - VS 2022 with native $arch C++ tools was not found."
}

function Set-NativeToolchain($VisualStudio) {
    $arch = Get-NativeArchitecture
    # Read the SDK registration explicitly in the 32-bit registry view used by the SDK installer.
    $key = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry32)
    try {
        $roots = $key.OpenSubKey('SOFTWARE\Microsoft\Windows Kits\Installed Roots')
        if (-not $roots) { throw ' ERROR - Windows SDK is not registered.' }
        try { $sdk = $roots.GetValue('KitsRoot10') } finally { $roots.Dispose() }
    } finally { $key.Dispose() }
    if (-not $sdk -or -not (Test-Path "$sdk\Include")) { throw ' ERROR - Windows SDK includes not found.' }
    $sdkVersion = Get-ChildItem "$sdk\Include" -Directory |
        Where-Object { Test-Path "$sdk\Lib\$($_.Name)\um\$arch\kernel32.lib" } |
        Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1 -ExpandProperty Name
    if (-not $sdkVersion) { throw " ERROR - Windows SDK libraries for $arch not found." }
    $tools = $VisualStudio.tools
    $env:PATH = "$tools\bin\Host$arch\$arch;$sdk\bin\$sdkVersion\$arch;$env:PATH"
    $env:INCLUDE = "$tools\include;$sdk\Include\$sdkVersion\ucrt;$sdk\Include\$sdkVersion\um;$sdk\Include\$sdkVersion\shared"
    $env:LIB = "$tools\lib\$arch;$sdk\Lib\$sdkVersion\ucrt\$arch;$sdk\Lib\$sdkVersion\um\$arch"
    Write-Host "Windows SDK: $sdk ($sdkVersion); compiler host/target: $arch/$arch"
}

function Get-BuildDirectory([string]$Root, [string]$Generator) {
    $suffix = if ($Generator -eq 'Ninja') { 'ninja' } else { 'msvc' }
    return Join-Path $Root "build_hobl_$suffix"
}

function Invoke-Logged([string]$Executable, [string[]]$Arguments, [string]$Log) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    & $Executable @Arguments *> $Log
    $code = $LASTEXITCODE
    $watch.Stop()
    if ($code -ne 0) { throw " ERROR - $Executable exited $code; see $Log" }
    return [math]::Round($watch.Elapsed.TotalSeconds, 4)
}

function Assert-Source([string]$Root) {
    $commit = & git -C $Root rev-parse HEAD
    if ($LASTEXITCODE -ne 0 -or $commit -ne $script:Config.opencv_commit) {
        throw " ERROR - OpenCV checkout must be $($script:Config.opencv_commit). Run setup first."
    }
    $dirty = & git -C $Root status --porcelain --untracked-files=no
    if ($LASTEXITCODE -ne 0 -or $dirty) { throw ' ERROR - Tracked OpenCV source modifications invalidate this benchmark.' }
}
