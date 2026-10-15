#Requires -Version 7.0
. "$PSScriptRoot\..\scripts\common.ps1"
$temp = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
$directories = @($temp, "$temp\install", "$temp\install\current", "$temp\install\stale")
$files = @(
    "$temp\install_manifest.txt",
    "$temp\install\current\opencv_version.exe", "$temp\install\stale\opencv_version.exe",
    "$temp\install\OpenCVConfig.cmake", "$temp\install\current\OpenCVConfig.cmake",
    "$temp\install\current\OpenCVModules.cmake", "$temp\outside.exe"
)
try {
    $directories | ForEach-Object { New-Item -ItemType Directory $_ | Out-Null }
    $files | ForEach-Object { Set-Content $_ '' }
    @($files[1], $files[3], $files[4], $files[5]) | Set-Content $files[0]
    if ((Get-InstalledOpenCVFile $temp 'opencv_version.exe').FullName -ne $files[1]) {
        throw ' ERROR - Stale executable selected instead of current manifest.'
    }
    if ((Get-InstalledOpenCVFile $temp 'OpenCVConfig.cmake').FullName -ne $files[4]) {
        throw ' ERROR - Selected dispatcher instead of concrete package.'
    }
    foreach ($case in @(
        @{ entries = @($files[1], $files[2]); name = 'opencv_version.exe'; error = 'found 2' },
        @{ entries = @($files[6]); name = 'outside.exe'; error = 'outside the benchmark' },
        @{ entries = @(); name = 'opencv_version.exe'; error = 'found 0' }
    )) {
        Set-Content $files[0] -Value $case.entries
        $failed = $false
        try { Get-InstalledOpenCVFile $temp $case.name | Out-Null }
        catch {
            if ($_.Exception.Message -notmatch $case.error) { throw }
            $failed = $true
        }
        if (-not $failed) { throw ' ERROR - Invalid manifest was accepted.' }
    }
    Write-Host 'PASS: current install selection, concrete package, ambiguity and path guards.'
} finally {
    foreach ($file in $files) {
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file }
    }
    [array]::Reverse($directories)
    foreach ($directory in $directories) {
        if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory }
    }
}
