#Requires -Version 7.0
param([string]$InstallPath = 'C:\Program Files\Microsoft Visual Studio\2026\BuildTools')
. "$PSScriptRoot\common.ps1"
$spec = Get-Content "$PSScriptRoot\..\toolchains\vs2026.json" -Raw | ConvertFrom-Json
if ((Get-NativeArchitecture) -ne 'arm64') { throw ' ERROR - This installer pins native ARM64 Windows tools.' }
$tools = [IO.Path]::GetFullPath("$PSScriptRoot\..\.tools")
New-Item -ItemType Directory -Force $tools | Out-Null
$archive = "$tools\cmake-$($spec.cmake_version)-windows-arm64.zip"
if (-not (Test-Path $archive)) { Invoke-WebRequest $spec.cmake_url -OutFile $archive }
if ((Get-FileHash $archive).Hash -ne $spec.cmake_sha256) { throw ' ERROR - CMake archive checksum mismatch.' }
$cmakeDir = "$tools\cmake-$($spec.cmake_version)-windows-arm64"
if (-not (Test-Path $cmakeDir)) { Expand-Archive $archive $tools }
$cmake = Get-CMake "$cmakeDir\bin\cmake.exe" $spec.cmake_version
Assert-NativeExecutable $cmake 'arm64'
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vswhere)) { throw ' ERROR - The original VS 2022 baseline prerequisites must be installed first.' }
$instances = @(& $vswhere -version '[18.0,19.0)' -products '*' -format json | ConvertFrom-Json)
if ($LASTEXITCODE -ne 0) { throw ' ERROR - vswhere failed.' }
if (-not $instances.Count) {
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).
        IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $admin) { throw ' ERROR - Run this installer from an elevated native PowerShell window.' }
    $bootstrapper = "$tools\vs2026_BuildTools.exe"
    if (-not (Test-Path $bootstrapper)) { Invoke-WebRequest $spec.bootstrapper_url -OutFile $bootstrapper }
    if ((Get-FileHash $bootstrapper).Hash -ne $spec.bootstrapper_sha256) { throw ' ERROR - VS bootstrapper checksum mismatch.' }
    $signature = Get-AuthenticodeSignature $bootstrapper
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
        throw ' ERROR - VS bootstrapper must have a valid Microsoft signature.'
    }
    if ($InstallPath.Contains('"')) { throw ' ERROR - InstallPath cannot contain a double quote.' }
    $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
    $arguments = "--quiet --wait --norestart --installPath `"$InstallPath`" --add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.VC.Tools.ARM64"
    $process = Start-Process $bootstrapper -ArgumentList $arguments -Wait -PassThru
    @{
        exit_code = $process.ExitCode
        boot_time = $boot
        finished_at = [datetimeoffset]::Now.ToString('o')
        bootstrapper_sha256 = (Get-FileHash $bootstrapper).Hash
    } | ConvertTo-Json | Set-Content "$tools\vs2026-installation.json"
    if ($process.ExitCode -notin @(0, 3010)) { throw " ERROR - VS installation failed with code $($process.ExitCode)." }
}
$vs = Get-VisualStudio 18
if ($vs.version -ne $spec.visual_studio_build) {
    throw " ERROR - Expected VS $($spec.visual_studio_build), found $($vs.version). Review and update release pins before measuring another release."
}
Assert-NoPendingToolchainRestart
Write-Host "VS $($vs.version) and CMake $($spec.cmake_version) are ready; the VS 2022 installation was not replaced."
