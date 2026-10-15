#Requires -Version 7.0
. "$PSScriptRoot\..\scripts\common.ps1"
. "$PSScriptRoot\..\scripts\measure_build.ps1"
Add-Type -Path "$PSScriptRoot\..\scripts\BuildAccounting.cs"
$temp = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
New-Item -ItemType Directory $temp | Out-Null
try {
    $shell = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
    @'
$watch = [Diagnostics.Stopwatch]::StartNew()
while ($watch.Elapsed.TotalSeconds -lt 1) { [math]::Sqrt(12345) | Out-Null }
Write-Output "child CPU: $((Get-Process -Id $PID).TotalProcessorTime.TotalSeconds)"
Write-Output 'child-completed'
exit 0
'@ | Set-Content "$temp\child.ps1"
    $result = [BuildAccounting]::Run($shell, "-NoProfile -File `"$temp\child.ps1`"", $temp, "$temp\build.log")
    $result | ConvertTo-Json
    Get-Content "$temp\build.log"
    if ($result.ExitCode -ne 0 -or $result.TotalProcesses -lt 2 -or $result.CpuSeconds -lt 0.5 -or
        $result.WallSeconds -lt 1 -or (Get-Content "$temp\build.log") -notcontains 'child-completed') {
        throw ' ERROR - Descendant CPU accounting or stdout capture failed.'
    }
    $failure = [BuildAccounting]::Run($env:ComSpec, '/d /c exit 7', $temp, "$temp\failure.log")
    if ($failure.ExitCode -ne 7) { throw ' ERROR - Accounting lost the failed process exit code.' }
    @'
Write-Output $args[0]
exit 0
'@ | Set-Content "$temp\arguments with spaces.ps1"
    Invoke-MeasuredBuild $shell @('-NoProfile', '-File', "$temp\arguments with spaces.ps1",
        'spaces and ; semicolon') $temp $temp | Out-Null
    if ((Get-Content "$temp\build.log").Trim() -ne 'spaces and ; semicolon') {
        throw ' ERROR - Measurement changed native argument boundaries.'
    }
    Write-Host 'PASS: job accounting includes child CPU, captures output and preserves exit codes.'
} finally {
    foreach ($name in @('child.ps1', 'build.log', 'failure.log', 'arguments with spaces.ps1', 'cpu-accounting.json')) {
        if (Test-Path "$temp\$name") { Remove-Item -LiteralPath "$temp\$name" }
    }
    Remove-Item -LiteralPath $temp
}
