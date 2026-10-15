#Requires -Version 7.0
param([string]$HoblRoot = '', [switch]$VerifyVS2026, [switch]$VerifyLatestSDK)
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
    if ((Get-ToolchainCMakeVersion 'MSVC') -ne $script:Config.cmake_version -or
        (Get-ToolchainCMakeVersion 'Clang') -ne $script:Config.cmake_version -or
        (Get-ToolchainCMakeVersion 'MSVC2026') -ne '4.4.4' -or
        (Get-ToolchainCMakeVersion 'MSVC2026Latest') -ne '4.4.4') {
        throw ' ERROR - Per-toolchain CMake pins changed unexpectedly.'
    }
    $failed = $false
    try { Get-CMake $cmake '0.0.0' | Out-Null }
    catch {
        if ($_.Exception.Message -notmatch 'CMake 0.0.0 required') { throw }
        $failed = $true
    }
    if (-not $failed) { throw ' ERROR - Explicit CMake version guard failed.' }
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
    if ((Get-EffectiveGenerator 'Ninja' 'MSVC2026' $false) -ne 'MSBuild') {
        throw ' ERROR - VS 2026 must default to MSBuild.'
    }
    $failed = $false
    try { Get-EffectiveGenerator 'Ninja' 'MSVC2026' $true | Out-Null }
    catch {
        if ($_.Exception.Message -notmatch 'requires the MSBuild generator') { throw }
        $failed = $true
    }
    if (-not $failed) { throw ' ERROR - Unsupported generator was accepted for VS 2026.' }
    if ((Get-EffectiveGenerator 'Ninja' 'MSVC2026Latest' $false) -ne 'MSBuild') {
        throw ' ERROR - Latest Microsoft stack must default to MSBuild.'
    }
    $failed = $false
    try { Get-EffectiveGenerator 'Ninja' 'MSVC2026Latest' $true | Out-Null }
    catch {
        if ($_.Exception.Message -notmatch 'requires the MSBuild generator') { throw }
        $failed = $true
    }
    if (-not $failed) { throw ' ERROR - Latest Microsoft stack accepted Ninja.' }
    $directories = @(
        Get-BuildDirectory $temp 'MSBuild' 'MSVC'
        Get-BuildDirectory $temp 'Ninja' 'MSVC'
        Get-BuildDirectory $temp 'Ninja' 'Clang'
        Get-BuildDirectory $temp 'MSBuild' 'MSVC2026'
        Get-BuildDirectory $temp 'MSBuild' 'MSVC2026Latest'
    )
    if (@($directories | Select-Object -Unique).Count -ne 5) { throw ' ERROR - Toolchain build trees overlap.' }
    $sdk = Get-WindowsSDK
    if ($sdk.target_version -ne '10.0.26100.0') { throw ' ERROR - Baseline SDK selection changed.' }
    $sdkReceipt = [pscustomobject]@{ windows_sdk = $sdk }
    Assert-WindowsSDK $sdkReceipt 'MSVC'
    @($sdk.files_sha256.PSObject.Properties)[0].Value = '0' * 64
    $failed = $false
    try { Assert-WindowsSDK $sdkReceipt 'MSVC' }
    catch {
        if ($_.Exception.Message -notmatch 'Windows SDK file changed') { throw }
        $failed = $true
    }
    if (-not $failed) { throw ' ERROR - SDK file drift was ignored.' }
    $failed = $false
    try { Assert-WindowsSDK ([pscustomobject]@{}) 'MSVC' }
    catch {
        if ($_.Exception.Message -notmatch 'no explicit Windows SDK selection') { throw }
        $failed = $true
    }
    if (-not $failed) { throw ' ERROR - Unpinned legacy SDK receipt was accepted.' }
    if ($VerifyLatestSDK) {
        $latestSDK = Get-WindowsSDK 'MSVC2026Latest'
        if ($latestSDK.target_version -ne '10.0.28000.0' -or $latestSDK.release_version -ne '10.0.28000.2957') {
            throw ' ERROR - Latest SDK version pin failed.'
        }
        $failed = $false
        try { Assert-WindowsSDK ([pscustomobject]@{ windows_sdk = $latestSDK }) 'MSVC2026' }
        catch {
            if ($_.Exception.Message -notmatch 'SDK selection changed') { throw }
            $failed = $true
        }
        if (-not $failed) { throw ' ERROR - Wrong SDK profile was accepted.' }
    }
    $restart = "$temp\restart.json"
    Assert-NoPendingToolchainRestart $restart
    if ($VerifyVS2026) {
        $vs = Get-VisualStudio 18
        $runtime = "$env:SystemRoot\System32\vcruntime140.dll"
        $assessment = @{
            exit_code = 3010
            boot_time = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
            restart_assessment = @{
                kind = 'verified-soft-reboot'
                visual_studio_build = $vs.version
                runtime_files = @(@{ path = $runtime; sha256 = (Get-FileHash $runtime).Hash })
            }
        }
        $assessment | ConvertTo-Json -Depth 6 | Set-Content $restart
        Assert-NoPendingToolchainRestart $restart
        $assessment.restart_assessment.runtime_files[0].sha256 = '0' * 64
        $assessment | ConvertTo-Json -Depth 6 | Set-Content $restart
        $failed = $false
        try { Assert-NoPendingToolchainRestart $restart }
        catch {
            if ($_.Exception.Message -notmatch 'Runtime changed after soft-reboot verification') { throw }
            $failed = $true
        }
        if (-not $failed) { throw ' ERROR - Soft-reboot runtime drift was ignored.' }
    }
    @{
        exit_code = 3010
        boot_time = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
    } | ConvertTo-Json | Set-Content $restart
    $failed = $false
    try { Assert-NoPendingToolchainRestart $restart }
    catch {
        if ($_.Exception.Message -notmatch 'Restart Windows') { throw }
        $failed = $true
    }
    if (-not $failed) { throw ' ERROR - Pending installation restart was ignored.' }
    $failed = $false
    try { Assert-WindowsSDKRestart $restart }
    catch {
        if ($_.Exception.Message -notmatch 'Restart Windows') { throw }
        $failed = $true
    }
    if (-not $failed) { throw ' ERROR - Pending SDK restart was ignored.' }
    @{ exit_code = 3010; boot_time = '2000-01-01T00:00:00.0000000Z' } |
        ConvertTo-Json | Set-Content $restart
    Assert-NoPendingToolchainRestart $restart
    Assert-WindowsSDKRestart $restart
    @{ exit_code = 1603; boot_time = '2000-01-01T00:00:00.0000000Z' } |
        ConvertTo-Json | Set-Content $restart
    $failed = $false
    try { Assert-WindowsSDKRestart $restart }
    catch {
        if ($_.Exception.Message -notmatch 'installation failed') { throw }
        $failed = $true
    }
    if (-not $failed) { throw ' ERROR - Failed SDK installation was ignored.' }
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
    Get-ChildItem "$PSScriptRoot\..\scripts\*.ps1", "$PSScriptRoot\*.ps1" | ForEach-Object {
        $tokens = $null
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors)
        if ($errors) { throw " ERROR - PowerShell syntax failure: $errors" }
    }
    & "$PSScriptRoot\test_toolchain_study.ps1"
    Write-Host 'PASS: exit codes, paths, toolchain isolation, native PE/restart/version guards, syntax and optional HOBL flag parity.'
} finally {
    Remove-Item -LiteralPath "$temp\success.log", "$temp\failure.log", "$temp\restart.json" -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $temp
}
