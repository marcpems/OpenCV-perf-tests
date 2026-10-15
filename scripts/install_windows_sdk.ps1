#Requires -Version 7.0
. "$PSScriptRoot\common.ps1"
$spec = Get-Content "$PSScriptRoot\..\toolchains\windows-sdk.json" -Raw | ConvertFrom-Json
if ((Get-NativeArchitecture) -ne 'arm64') { throw ' ERROR - This installer pins ARM64 Windows SDK components.' }
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).
    IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { throw ' ERROR - Run this installer from elevated native PowerShell.' }
$tools = [IO.Path]::GetFullPath("$PSScriptRoot\..\.tools")
New-Item -ItemType Directory -Force $tools | Out-Null
$installer = "$tools\winsdksetup-28000.2957.exe"
if (-not (Test-Path $installer)) { Invoke-WebRequest $spec.installer_url -OutFile $installer }
if ((Get-FileHash $installer).Hash -ne $spec.installer_sha256) { throw ' ERROR - SDK installer checksum mismatch.' }
$signature = Get-AuthenticodeSignature $installer
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
    throw ' ERROR - SDK installer must have a valid Microsoft signature.'
}
if ((Get-Item $installer).VersionInfo.ProductVersion -ne $spec.installer_version) {
    throw ' ERROR - SDK installer version mismatch.'
}
$receiptPath = "$tools\windows-sdk-installation.json"
if (-not (Test-Path $receiptPath)) {
    $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
    $log = "$tools\windows-sdk-installation.log"
    $arguments = "/features OptionId.DesktopCPParm64 /quiet /norestart /ceip off /log `"$log`""
    $process = Start-Process $installer -ArgumentList $arguments -Wait -PassThru
    @{
        exit_code = $process.ExitCode
        boot_time = $boot
        finished_at = [datetimeoffset]::Now.ToString('o')
        arguments = $arguments
        installer_sha256 = (Get-FileHash $installer).Hash
        release_version = $spec.latest_release_version
    } | ConvertTo-Json | Set-Content $receiptPath
}
Assert-WindowsSDKRestart
$sdk = Get-WindowsSDK 'MSVC2026Latest'
Write-Host "Windows SDK $($sdk.release_version) ready alongside the original SDK."
