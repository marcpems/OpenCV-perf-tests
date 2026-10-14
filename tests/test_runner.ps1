#Requires -Version 7.0
param([string]$HoblRoot = '')
. "$PSScriptRoot\..\scripts\common.ps1"
$temp = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
New-Item -ItemType Directory $temp | Out-Null
try {
    $seconds = Invoke-Logged $env:ComSpec @('/d', '/c', 'echo success') "$temp\success.log"
    if ($seconds -lt 0 -or (Get-Content "$temp\success.log").Trim() -ne 'success') {
        throw ' ERROR - Native command success or log capture failed.'
    }
    $failed = $false
    try { Invoke-Logged $env:ComSpec @('/d', '/c', 'exit 7') "$temp\failure.log" }
    catch {
        if ($_.Exception.Message -notmatch 'exited 7') { throw }
        $failed = $true
    }
    if (-not $failed) { throw ' ERROR - Native failure was silently accepted.' }
    $cmake = Get-CMake ''
    if ($cmake -isnot [string] -or -not (Test-Path $cmake)) { throw ' ERROR - CMake discovery returned multiple paths.' }
    if ((Get-EffectiveGenerator 'MSBuild' 'MSVC' $false) -ne 'MSBuild' -or
        (Get-EffectiveGenerator 'MSBuild' 'Clang' $false) -ne 'Ninja') {
        throw ' ERROR - Toolchain generator defaults changed.'
    }
    $failed = $false
    try { Get-EffectiveGenerator 'MSBuild' 'Clang' $true | Out-Null }
    catch {
        if ($_.Exception.Message -notmatch 'requires the Ninja generator') { throw }
        $failed = $true
    }
    if (-not $failed) { throw ' ERROR - Unsupported generator was accepted for Clang.' }
    if ((Get-BuildDirectory $temp 'Ninja') -eq (Get-BuildDirectory $temp 'Ninja' 'Clang')) {
        throw ' ERROR - Clang and MSVC build directories overlap.'
    }
    Push-Location $temp
    try {
        if ((Get-SourceRoot 'relative-source') -ne (Join-Path $temp 'relative-source')) {
            throw ' ERROR - Relative paths must use the PowerShell location.'
        }
    } finally { Pop-Location }
    $arch = Get-NativeArchitecture
    $shell = (Get-Process -Id $PID).Path
    Assert-NativeExecutable $shell $arch
    $otherArch = if ($arch -eq 'arm64') { 'x64' } else { 'arm64' }
    $failed = $false
    try { Assert-NativeExecutable $shell $otherArch }
    catch {
        if ($_.Exception.Message -notmatch 'not native') { throw }
        $failed = $true
    }
    if (-not $failed) { throw ' ERROR - Native PE architecture guard failed.' }
    if ($HoblRoot) {
        $prep = Get-Content "$HoblRoot\scenarios\windows\opencv_build\opencv_build_resources\opencv_build_prep.ps1" -Raw
        $upstream = @([regex]::Matches($prep, '"(-D[^"\r\n]+)"') | ForEach-Object { $_.Groups[1].Value })
        if (@(Compare-Object $upstream @($script:Config.cmake_flags)).Count -ne 0) {
            throw ' ERROR - CMake flags differ from the HOBL prep script.'
        }
    }
    Get-ChildItem "$PSScriptRoot\..\scripts\*.ps1" | ForEach-Object {
        $tokens = $null
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors)
        if ($errors) { throw " ERROR - PowerShell syntax failure: $errors" }
    }
    Write-Host 'PASS: exit codes, paths, toolchain isolation, native PE guards, CMake discovery, syntax and optional HOBL flag parity.'
} finally {
    Remove-Item -LiteralPath "$temp\success.log", "$temp\failure.log" -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $temp
}
