#Requires -Version 7.0
. "$PSScriptRoot\common.ps1"
if ($env:RUNNER_NAME -ine 'MARCPE-D4') { throw 'This prerequisite repair is scoped to MARCPE-D4.' }
$spec = Get-Content "$PSScriptRoot\..\toolchains\minos-prerequisites.json" -Raw | ConvertFrom-Json
$tools = [IO.Path]::GetFullPath("$PSScriptRoot\..\.tools")
$previous = "$tools\minos-msvc-installation.json"
if (Test-Path $previous) {
    $prior = Get-Content $previous -Raw | ConvertFrom-Json
    $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime()
    if ($prior.exit_code -eq 3010 -and [datetimeoffset]$prior.boot_time -eq [datetimeoffset]$boot) {
        throw 'Restart is still required after native ARM64 component installation.'
    }
}
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$instances = & $vswhere -version '[17.0,18.0)' -products '*' -format json | ConvertFrom-Json
if ($LASTEXITCODE) { throw 'Visual Studio inventory failed' }
$inventory = @()
foreach ($instance in $instances) {
    $default = "$($instance.installationPath)\VC\Auxiliary\Build\Microsoft.VCToolsVersion.default.txt"
    if (-not (Test-Path $default)) { continue }
    $toolset = (Get-Content $default -Raw).Trim()
    $native = "$($instance.installationPath)\VC\Tools\MSVC\$toolset\bin\Hostarm64\arm64\cl.exe"
    $inventory += [pscustomobject]@{
        path = $instance.installationPath
        version = $instance.installationVersion
        toolset = $toolset
        native_arm64_present = Test-Path $native
    }
}
$inventory | ConvertTo-Json | Write-Host
if (@($inventory | Where-Object native_arm64_present).Count) { exit 0 }
$selected = $inventory | Where-Object { $_.path -like '*\BuildTools' } |
    Sort-Object { [version]$_.version } -Descending | Select-Object -First 1
if (-not $selected) { throw 'No existing VS 2022 BuildTools instance to repair; review runner prerequisites.' }
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).
    IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { throw 'Native ARM64 C++ tools are missing. Add the VC.Tools.ARM64 component to VS 2022 BuildTools from an elevated installer.' }
New-Item -ItemType Directory -Force $tools | Out-Null
$installer = "$tools\vs2022-arm64-prerequisite.exe"
if (-not (Test-Path $installer)) { Invoke-WebRequest $spec.bootstrapper_url -OutFile $installer }
$signature = Get-AuthenticodeSignature $installer
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
    throw 'Expected a valid Microsoft-signed Visual Studio bootstrapper'
}
if ($selected.path.Contains('"')) { throw 'Unexpected quote in installed VS path' }
$arguments = "modify --quiet --wait --norestart --installPath `"$($selected.path)`" --add $($spec.component)"
$receipt = [ordered]@{
    before = $inventory
    component = $spec.component
    installer_sha256 = (Get-FileHash $installer).Hash
    boot_time = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
    started_at = [datetimeoffset]::Now.ToString('o')
}
Write-Host "Adding missing native ARM64 C++ component to $($selected.path); no automatic restart."
$process = Start-Process $installer -ArgumentList $arguments -Wait -PassThru
$receipt.exit_code = $process.ExitCode
$receipt.finished_at = [datetimeoffset]::Now.ToString('o')
$receipt | ConvertTo-Json -Depth 5 | Set-Content "$tools\minos-msvc-installation.json"
if ($process.ExitCode -eq 3010) { throw 'Component installation requires a Windows restart before benchmarking; no restart was performed.' }
if ($process.ExitCode -ne 0) { throw "ARM64 component installation failed: $($process.ExitCode)" }
Get-VisualStudio | Out-Null
