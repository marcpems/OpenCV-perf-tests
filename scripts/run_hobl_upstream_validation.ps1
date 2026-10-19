#Requires -Version 7.0
. "$PSScriptRoot\common.ps1"
if ($env:RUNNER_NAME -ine 'MARCPE-D4' -or (Get-NativeArchitecture) -ne 'arm64') {
    throw ' ERROR - Expected the dedicated native ARM64 validation runner.'
}
Assert-NoPendingToolchainRestart
Assert-WindowsSDKRestart
$repo = [IO.Path]::GetFullPath("$PSScriptRoot\..")
$work = Join-Path $repo ".work\hobl-upstream-$env:GITHUB_RUN_ID"
$public = Join-Path $repo "results\hobl-upstream-$env:GITHUB_RUN_ID"
$base = '3baa2ab25837ac6a0f766f1c7401f1e74c5110ae'
$patch = Join-Path $repo 'patches\hobl-opencv-shared-cap.patch'
if ((Test-Path $work) -or (Test-Path $public)) { throw ' ERROR - Use a fresh workflow run.' }
$active = @(Get-Process | Where-Object {
    $_.ProcessName -match '^(cl|clang|clang\+\+|link|lld-link|ninja|cmake|MSBuild|screen_.+)$'
})
if ($active.Count) { throw ' ERROR - Build/runtime tools are already active; no study started.' }
foreach ($name in @('CL','_CL_','CMAKE_BUILD_PARALLEL_LEVEL','CMAKE_GENERATOR',
        'CMAKE_GENERATOR_PLATFORM','CMAKE_GENERATOR_TOOLSET','MultiProcCL',
        'MultiProcMaxCount','EnforceProcessCountAcrossBuilds','MSBUILDDISABLENODEREUSE')) {
    if ([Environment]::GetEnvironmentVariable($name)) { throw " ERROR - Unexpected build override: $name" }
}
$cmake = Get-CMake ''
$vs = Get-VisualStudio
$sdk = Get-WindowsSDK
$shell = (Get-Process -Id $PID).Path
$seed = Join-Path $repo '.work\minos-source'
Assert-Source $seed
New-Item -ItemType Directory "$work\volume\hobl_bin", "$work\volume\hobl_data", "$work\runs" | Out-Null
$hobl = Join-Path $work 'hobl'
& git clone --quiet --filter=blob:none --no-checkout https://github.com/microsoft/HOBL.git $hobl
if ($LASTEXITCODE) { throw ' ERROR - HOBL clone failed.' }
& git -C $hobl sparse-checkout set scenarios/windows/opencv_build
if ($LASTEXITCODE) { throw ' ERROR - HOBL sparse checkout failed.' }
& git -C $hobl checkout --quiet --detach $base
if ($LASTEXITCODE) { throw ' ERROR - HOBL base checkout failed.' }
$resource = "$hobl\scenarios\windows\opencv_build\opencv_build_resources"
foreach ($variant in @('baseline','shared')) {
    New-Item -ItemType Directory "$work\volume\hobl_bin\$variant" | Out-Null
    if ($variant -eq 'shared') {
        & git -C $hobl apply --check $patch
        if ($LASTEXITCODE) { throw ' ERROR - Patch does not apply cleanly to the recorded upstream base.' }
        & git -C $hobl apply $patch
        if ($LASTEXITCODE) { throw ' ERROR - Patch application failed.' }
    }
    Copy-Item "$resource\opencv_build_run.ps1" "$work\volume\hobl_bin\$variant\opencv_build_run.ps1"
}
& python "$PSScriptRoot\validate_hobl_shared_cap.py" $hobl
if ($LASTEXITCODE) { throw ' ERROR - Host lifecycle validation failed.' }
& "$PSScriptRoot\test_hobl_command_arguments.ps1" -HoblRoot $hobl
& git -C $seed worktree add --detach "$work\volume\opencv" $script:Config.opencv_commit
if ($LASTEXITCODE) { throw ' ERROR - Isolated OpenCV worktree creation failed.' }
$occupied = @([IO.Directory]::GetLogicalDrives() | ForEach-Object { $_.Substring(0,1) })
$available = @('Z','Y','X','W','V','U','T','S','R' | Where-Object { $_ -notin $occupied })
if (-not $available.Count) { throw ' ERROR - No free temporary drive alias is available.' }
$drive = $available[0]
$volume = "${drive}:"
& subst.exe $volume "$work\volume"
if ($LASTEXITCODE) { throw ' ERROR - Temporary validation drive mapping failed.' }
$study = [ordered]@{
    status = 'running'; hobl_base = $base; github_run_id = $env:GITHUB_RUN_ID
    evidence_commit = $env:GITHUB_SHA; jobs = [Environment]::ProcessorCount
    order = @('baseline','shared','shared','baseline','shared','baseline','baseline','shared')
    warmups_per_variant = 1; warmups_excluded = $true; pause_seconds = 30
    completed_labels = @()
}
try {
    $build = "$volume\opencv\build_msvc"
    New-Item -ItemType Directory $build | Out-Null
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        "$resource\opencv_build_prep.ps1", [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ' ERROR - Upstream prep script did not parse.' }
    $assignment = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -eq '$cmakeArgs'
    }, $true))
    if ($assignment.Count -ne 1) { throw ' ERROR - Expected one upstream CMake argument definition.' }
    Invoke-Expression $assignment[0].Extent.Text
    $definitions = @($cmakeArgs | Where-Object { $_ -like '-D*' })
    if (($definitions -join "`n") -ne ($script:Config.cmake_flags -join "`n")) {
        throw ' ERROR - Upstream OpenCV configuration differs from the investigated definitions.'
    }
    Push-Location $build
    try { Invoke-Logged $cmake $cmakeArgs "$work\configure.log" | Out-Null }
    finally { Pop-Location }
    $compilerText = Get-Content "$build\CMakeFiles\4.1.1\CMakeCXXCompiler.cmake" -Raw
    if ($compilerText -notmatch 'set\(CMAKE_CXX_COMPILER "([^"]+)"\)') {
        throw ' ERROR - Missing compiler identity.'
    }
    $compiler = $Matches[1]
    Assert-NativeExecutable $compiler 'arm64'
    if ([IO.Path]::GetFullPath($compiler) -ne
        [IO.Path]::GetFullPath("$($vs.tools)\bin\Hostarm64\arm64\cl.exe")) {
        throw ' ERROR - Upstream configuration did not select native ARM64 MSVC.'
    }
    $power = (& powercfg /getactivescheme | Out-String).Trim()
    $frozen = @{}
    foreach ($file in @(Get-ChildItem $build -Recurse -File -Include *.vcxproj,*.props,*.targets,*.sln) +
            @(Get-Item "$build\CMakeCache.txt", "$build\cvconfig.h", "$build\opencv2\opencv_modules.hpp",
                $compiler, $cmake, $patch, "$PSScriptRoot\invoke_hobl_validation.ps1",
                "$PSScriptRoot\run_hobl_upstream_validation.ps1", "$PSScriptRoot\collect_hobl_validation.py",
                "$work\volume\hobl_bin\baseline\opencv_build_run.ps1",
                "$work\volume\hobl_bin\shared\opencv_build_run.ps1")) {
        $frozen[$file.FullName] = (Get-FileHash -LiteralPath $file.FullName).Hash
    }
    @{
        hobl_base = $base; patch_sha256 = (Get-FileHash $patch).Hash
        opencv_commit = $script:Config.opencv_commit; configure_arguments = $cmakeArgs
        compiler = $compiler; compiler_version = (Get-Item $compiler).VersionInfo.FileVersion
        visual_studio = $vs; windows_sdk = $sdk
        cmake = $cmake; power_scheme = $power
        os = Get-CimInstance Win32_OperatingSystem | Select-Object Version,BuildNumber,OSArchitecture
        cpu = Get-CimInstance Win32_Processor | Select-Object Name,NumberOfCores,NumberOfLogicalProcessors
        memory_gib = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 2)
        frozen_sha256 = $frozen
        scope = 'Exact upstream baseline/patched run scripts; configure arguments extracted unchanged from prep. Installer and RPC orchestration not executed.'
        resolver = 'Same process-local cmake forwarding function for both scripts; pinned portable CMake, no machine/user PATH change. Restores native -- consumed by PowerShell function binding. CMake arguments and native duration recorded; HOBL CSV remains the primary timing.'
    } | ConvertTo-Json -Depth 8 | Set-Content "$work\provenance.json"
    $labels = @('baseline_warmup','shared_warmup')
    $counts = @{ baseline = 0; shared = 0 }
    foreach ($variant in $study.order) {
        $counts[$variant]++
        $labels += "${variant}_$($counts[$variant])"
    }
    foreach ($label in $labels) {
        foreach ($path in $frozen.Keys) {
            if ((Get-FileHash -LiteralPath $path).Hash -ne $frozen[$path]) {
                throw " ERROR - Frozen input changed: $path"
            }
        }
        if ((& powercfg /getactivescheme | Out-String).Trim() -ne $power) {
            throw ' ERROR - Active power scheme changed.'
        }
        $variant = $label.Split('_')[0]
        $output = "$work\runs\$label"
        New-Item -ItemType Directory $output | Out-Null
        Write-Host "Exact HOBL script: $label; resting 30 seconds."
        Start-Sleep -Seconds 30
        Invoke-Logged $shell @('-NoProfile','-File',"$PSScriptRoot\invoke_hobl_validation.ps1",
            '-Script',"$volume\hobl_bin\$variant\opencv_build_run.ps1",
            '-CMake',$cmake,'-Build',$build,'-Output',$output) "$output\console.log" | Out-Null
        & python "$PSScriptRoot\collect_hobl_validation.py" snapshot $build $output
        if ($LASTEXITCODE) { throw " ERROR - Run evidence validation failed: $label" }
        foreach ($path in $frozen.Keys) {
            if ((Get-FileHash -LiteralPath $path).Hash -ne $frozen[$path]) {
                throw " ERROR - Frozen input changed during $label : $path"
            }
        }
        if ((& powercfg /getactivescheme | Out-String).Trim() -ne $power) {
            throw ' ERROR - Active power scheme changed during the run.'
        }
        $study.completed_labels += $label
        $study | ConvertTo-Json -Depth 5 | Set-Content "$work\study.json"
        New-Item -ItemType Directory "$work\binaries\$variant" -Force | Out-Null
        Copy-Item "$build\bin\Release\opencv_world4100.dll" "$work\binaries\$variant" -Force
        $record = Get-Content "$output\validation.json" -Raw | ConvertFrom-Json
        Write-Host "$label : $($record.build_seconds) seconds"
    }
    Set-NativeToolchain $vs $sdk
    $ninja = (Get-Command ninja -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $package = @(Get-ChildItem "$build\install" -Recurse -Filter OpenCVConfig.cmake -File |
        Where-Object { Test-Path "$($_.DirectoryName)\OpenCVModules.cmake" })
    if ($package.Count -ne 1) { throw ' ERROR - Expected one installed OpenCV package.' }
    $smoke = "$work\smoke"
    Invoke-Logged $cmake @('-S',"$repo\tests",'-B',$smoke,'-G','Ninja',
        "-DCMAKE_MAKE_PROGRAM=$ninja",'-DCMAKE_BUILD_TYPE=Release',
        "-DOpenCV_DIR=$($package[0].DirectoryName)",
        '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL') "$work\smoke-configure.log" | Out-Null
    Invoke-Logged $cmake @('--build',$smoke) "$work\smoke-build.log" | Out-Null
    foreach ($variant in @('baseline','shared')) {
        Copy-Item "$work\binaries\$variant\opencv_world4100.dll" $smoke -Force
        Invoke-Logged "$smoke\opencv_smoke.exe" @() "$work\smoke-$variant.log" | Out-Null
        "$variant : $(Get-Content "$work\smoke-$variant.log" -Raw)" | Add-Content "$work\smoke.log"
    }
    $study.status = 'succeeded'
    $study | ConvertTo-Json -Depth 5 | Set-Content "$work\study.json"
    & python "$PSScriptRoot\collect_hobl_validation.py" export $work $public
    if ($LASTEXITCODE) { throw ' ERROR - Evidence export or cross-run parity validation failed.' }
} catch {
    $study.status = 'failed'
    $study['error'] = $_.Exception.Message
    $study | ConvertTo-Json -Depth 5 | Set-Content "$work\study.json"
    Get-ChildItem "$work\runs" -Filter console.log -Recurse | ForEach-Object {
        Write-Host "Last output from $($_.Directory.Name)"
        Get-Content -LiteralPath $_.FullName -Tail 25
    }
    throw
} finally {
    Set-Location $repo
    & subst.exe $volume /D
    if ($LASTEXITCODE) { throw " ERROR - Could not release owned temporary drive $volume" }
}
