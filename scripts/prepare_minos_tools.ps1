#Requires -Version 7.0
. "$PSScriptRoot\common.ps1"
if ($env:RUNNER_NAME -ine 'MARCPE-D4') { throw 'This workflow is scoped to MARCPE-D4.' }
if ((Get-NativeArchitecture) -ne 'arm64') { throw 'Native ARM64 PowerShell is required.' }
# Check installed Microsoft prerequisites before downloading the isolated portable tools.
$vs = Get-VisualStudio
$sdk = Get-WindowsSDK
Set-NativeToolchain $vs $sdk
foreach ($name in @('git','ninja','7z','python')) {
    Get-Command $name -CommandType Application -ErrorAction Stop | Out-Null
}
Write-Host "Ninja version: $(& ninja --version)"
$tools = [IO.Path]::GetFullPath("$PSScriptRoot\..\.tools")
New-Item -ItemType Directory -Force $tools | Out-Null
$cmake = "$tools\cmake-4.1.1-windows-arm64\bin\cmake.exe"
if (-not (Test-Path $cmake)) {
    $archive = "$tools\cmake-4.1.1-windows-arm64.zip"
    if (-not (Test-Path $archive)) {
        Invoke-WebRequest 'https://github.com/Kitware/CMake/releases/download/v4.1.1/cmake-4.1.1-windows-arm64.zip' -OutFile $archive
    }
    if ((Get-FileHash $archive).Hash -ne '1d968879344bcdd29ddeaa3480ea6e7716db0de518b220743b82c7f1750b5c9b') {
        throw 'Pinned CMake archive checksum mismatch'
    }
    Expand-Archive $archive $tools
}
Get-CMake $cmake | Out-Null
$spec = Get-Content "$PSScriptRoot\..\toolchains\clang-arm64.json" -Raw | ConvertFrom-Json
if (-not (Test-Path "$tools\$($spec.directory)\bin\clang.exe")) {
    & (Get-Process -Id $PID).Path -NoProfile -File "$PSScriptRoot\install_clang.ps1"
    if ($LASTEXITCODE) { throw 'Portable LLVM installation failed' }
}
Get-ClangToolchain '' | Out-Null
