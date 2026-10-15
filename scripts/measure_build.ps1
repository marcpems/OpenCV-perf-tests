function Invoke-MeasuredBuild([string]$Executable, [string[]]$Arguments, [string]$Directory,
    [string]$RunDirectory, [switch]$Trace) {
    if (-not ('BuildAccounting' -as [type])) { Add-Type -Path "$PSScriptRoot\BuildAccounting.cs" }
    $recording = $false
    $wpr = "$env:WINDIR\System32\wpr.exe"
    $instance = "OpenCV-$PID"
    $result = $null
    if ($Trace) {
        $status = & $wpr -status 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0 -or $status -notmatch 'WPR is not recording') {
            throw ' ERROR - WPR is already recording or its status is unknown; existing sessions are left untouched.'
        }
        & $wpr -start CPU -start DiskIO -filemode -recordtempto $RunDirectory -instancename $instance `
            *> "$RunDirectory\wpr-start.log"
        if ($LASTEXITCODE -ne 0) { throw " ERROR - WPR start failed; see $RunDirectory\wpr-start.log" }
        $recording = $true
    }
    try {
        $quotedArguments = @($Arguments | ForEach-Object {
            if ($_.Contains('"') -or $_ -match '[\r\n]') {
                throw ' ERROR - Embedded quotes/newlines are not supported in measured build arguments.'
            }
            '"' + $_ + '"'
        })
        $result = [BuildAccounting]::Run($Executable, ($quotedArguments -join ' '), $Directory, "$RunDirectory\build.log")
        $result | ConvertTo-Json | Set-Content "$RunDirectory\cpu-accounting.json"
    } finally {
        if ($recording) {
            & $wpr -stop "$RunDirectory\build.etl" -instancename $instance *> "$RunDirectory\wpr-stop.log"
            if ($LASTEXITCODE -ne 0) {
                throw " ERROR - WPR stop failed for owned instance $instance; inspect $RunDirectory\wpr-stop.log"
            }
        }
    }
    if ($result.ExitCode -ne 0) { throw " ERROR - Measured build exited $($result.ExitCode); see $RunDirectory\build.log" }
    return $result
}
