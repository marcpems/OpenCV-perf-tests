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
    Write-Host 'PASS: native exit codes, log capture, CMake discovery, script syntax and optional HOBL flag parity.'
} finally {
    Remove-Item -LiteralPath "$temp\success.log", "$temp\failure.log" -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $temp
}
