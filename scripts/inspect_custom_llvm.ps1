#Requires -Version 7.0
param([Parameter(Mandatory)][string]$InstallerPath)
$ErrorActionPreference = 'Stop'
if ($env:RUNNER_NAME -ine 'MARCPE-D4') { throw 'Expected MARCPE-D4' }
if (-not (Test-Path -LiteralPath $InstallerPath -PathType Leaf)) {
    Write-Host 'Custom LLVM installer is not present at the supplied path on MARCPE-D4.'
    exit 2
}
$item = Get-Item -LiteralPath $InstallerPath
$signature = Get-AuthenticodeSignature -LiteralPath $InstallerPath
[ordered]@{
    installer_name = $item.Name
    bytes = $item.Length
    sha256 = (Get-FileHash -LiteralPath $InstallerPath -Algorithm SHA256).Hash
    signature_status = [string]$signature.Status
} | ConvertTo-Json | Write-Host
