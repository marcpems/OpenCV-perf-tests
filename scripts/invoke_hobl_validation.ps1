#Requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$Script,
    [Parameter(Mandatory)][string]$CMake,
    [Parameter(Mandatory)][string]$Build,
    [Parameter(Mandatory)][string]$Output
)
$ErrorActionPreference = 'Stop'
$global:HoblCMake = $CMake
$global:HoblBuild = $Build
$global:HoblCalls = [Collections.Generic.List[object]]::new()
function global:Get-HoblBuildOutputs {
    $dll = Join-Path $global:HoblBuild 'bin\Release\opencv_world4100.dll'
    $objects = @(Get-ChildItem -LiteralPath $global:HoblBuild -Recurse -Filter *.obj -File |
        Sort-Object FullName | ForEach-Object { "$($_.FullName)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" })
    return @{
        dll_sha256 = (Get-FileHash -LiteralPath $dll).Hash
        objects_sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes(($objects -join "`n"))))
        objects = $objects.Count
    }
}
# HOBL refreshes PATH; resolve the pinned portable CMake without changing machine/user PATH.
function global:cmake {
    $arguments = @($args)
    # PowerShell consumes -- for functions; restore CMake's native-tool separator.
    $nativeStart = [Array]::IndexOf($arguments, '/p:MultiProcCL=true')
    if ($nativeStart -gt 0) {
        $arguments = @($arguments[0..($nativeStart - 1)]) + @('--') +
            @($arguments[$nativeStart..($arguments.Count - 1)])
    }
    $install = $arguments -contains 'INSTALL'
    $before = if ($install) { Get-HoblBuildOutputs } else { $null }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    & $global:HoblCMake @arguments
    $code = $LASTEXITCODE
    $clock.Stop()
    $after = if ($install -and $code -eq 0) { Get-HoblBuildOutputs } else { $null }
    $global:HoblCalls.Add(@{
        arguments = $arguments; exit_code = $code
        native_seconds = $clock.Elapsed.TotalSeconds
        before_install = $before; after_install = $after
    })
    $global:LASTEXITCODE = $code
}
try {
    & $Script -logFile "$Output\hobl.log"
    $code = $LASTEXITCODE
    if ($code -ne 0) { throw " ERROR - Exact HOBL script failed: $code" }
    if ($global:HoblCalls.Count -ne 3) { throw ' ERROR - Expected clean, build and install calls.' }
    $install = $global:HoblCalls[2]
    if ($install.before_install.dll_sha256 -ne $install.after_install.dll_sha256 -or
        $install.before_install.objects_sha256 -ne $install.after_install.objects_sha256) {
        throw ' ERROR - Untimed install rebuilt compilation outputs.'
    }
} finally {
    ConvertTo-Json -InputObject $global:HoblCalls.ToArray() -Depth 6 |
        Set-Content "$Output\cmake-calls.json"
}
