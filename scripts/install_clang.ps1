#Requires -Version 7.0
. "$PSScriptRoot\common.ps1"
$spec = Get-Content "$PSScriptRoot\..\toolchains\clang-arm64.json" -Raw | ConvertFrom-Json
if ((Get-NativeArchitecture) -ne $spec.architecture) { throw ' ERROR - This portable release is for native ARM64 Windows.' }
$cmake = Get-CMake ''
$sevenZip = (Get-Command 7z -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$tools = [IO.Path]::GetFullPath("$PSScriptRoot\..\.tools")
New-Item -ItemType Directory -Force $tools | Out-Null
$archive = Join-Path $tools $spec.archive
if (-not (Test-Path $archive)) { Invoke-WebRequest $spec.url -OutFile $archive }
if ((Get-FileHash $archive).Hash -ne $spec.sha256) { throw ' ERROR - LLVM archive checksum mismatch.' }
$destination = Join-Path $tools $spec.directory
if (Test-Path $destination) {
    Get-ClangToolchain '' | Out-Null
    Write-Host "Pinned native Clang is already available at $destination"
    exit 0
}
Push-Location $tools
try {
    # The release uses a large Zstandard window that CMake's archive reader rejects.
    & $sevenZip x $spec.archive -y -bso0 -bsp0
    if ($LASTEXITCODE -ne 0) { throw ' ERROR - LLVM Zstandard decompression failed.' }
    $tar = $spec.archive -replace '\.zst$', ''
    & $cmake -E tar xf $tar
    if ($LASTEXITCODE -ne 0) { throw ' ERROR - LLVM tar extraction failed.' }
    Get-ClangToolchain '' | Out-Null
    Remove-Item -LiteralPath (Join-Path $tools $tar)
} finally { Pop-Location }
Write-Host "Installed portable Clang at $destination; machine-wide LLVM was not changed."
