#Requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$InstallerPath,
    [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$InstallerSha256
)
. "$PSScriptRoot\common.ps1"
if ($env:RUNNER_NAME -ine 'MARCPE-D4' -or (Get-NativeArchitecture) -ne 'arm64') { throw 'Expected native MARCPE-D4' }
if ([int](Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors -ne 20) { throw 'Expected 20 CPUs' }
if ((Get-FileHash -LiteralPath $InstallerPath).Hash -ne $InstallerSha256) { throw 'MSI differs from the supplied fingerprint' }
Assert-NoPendingToolchainRestart
Assert-WindowsSDKRestart
$repo = [IO.Path]::GetFullPath("$PSScriptRoot\..")
$shell = (Get-Process -Id $PID).Path
$work = Join-Path $repo ".work\llvm-custom-$env:GITHUB_RUN_ID"
$extract = Join-Path $repo ".tools\llvm-custom-$env:GITHUB_RUN_ID"
$results = Join-Path $work 'measurements'
$public = Join-Path $repo "results\minos-custom-llvm-$env:GITHUB_RUN_ID"
if ((Test-Path $work) -or (Test-Path $extract) -or (Test-Path $public)) { throw 'Use a fresh run ID; existing evidence is preserved.' }
New-Item -ItemType Directory $work | Out-Null
$stock = Get-ClangToolchain ''
Get-VisualStudio | Out-Null
Get-WindowsSDK | Out-Null
foreach ($path in @($InstallerPath, $extract, $work)) {
    if ($path.Contains('"')) { throw 'Unexpected quote in path' }
}
Write-Host 'Extracting MSI administrative image; no product installation or global PATH change.'
$msiArgs = "/a `"$InstallerPath`" /qn /norestart TARGETDIR=`"$extract`" /L*v `"$work\msi-extract.log`""
$process = Start-Process "$env:WINDIR\System32\msiexec.exe" -ArgumentList $msiArgs -Wait -PassThru
if ($process.ExitCode -ne 0) { throw "MSI administrative extraction failed: $($process.ExitCode). Inspect private extraction log." }
$compilers = @(Get-ChildItem $extract -Recurse -Filter clang.exe -File)
if ($compilers.Count -ne 1) { throw 'Expected exactly one extracted clang.exe' }
$custom = Get-ClangToolchain $compilers[0].Directory.Parent.FullName
if ($custom.version -notmatch '^24\.0\.0(?:\D|$)') { throw "Expected custom LLVM 24.0.0, found $($custom.version)" }
$signature = Get-AuthenticodeSignature -LiteralPath $InstallerPath
$origin = [ordered]@{
    installer_name = [IO.Path]::GetFileName($InstallerPath)
    installer_sha256 = $InstallerSha256
    signature_status = [string]$signature.Status
    extraction = 'Windows Installer administrative image; product not installed'
    stock = $stock
    custom = $custom
    github_run_id = $env:GITHUB_RUN_ID
    github_commit = $env:GITHUB_SHA
    attribution = 'Comparison of LLVM packages/versions. PGO/LTO-only attribution requires a matched LLVM 24 source/build without those optimizations.'
}
$origin | ConvertTo-Json -Depth 6 | Set-Content "$work\compiler-origin.json"
$seed = Join-Path $repo '.work\minos-source'
Assert-Source $seed
$roots = @{ stock = "$work\stock-source"; custom = "$work\custom-source" }
$toolRoots = @{ stock = $stock.root; custom = $custom.root }
$frozen = @{}
$ninja = $null
foreach ($variant in @('stock','custom')) {
    $root = $roots[$variant]
    & git -C $seed worktree add --detach $root $script:Config.opencv_commit
    if ($LASTEXITCODE) { throw "Worktree creation failed: $variant" }
    & $shell -NoProfile -File "$PSScriptRoot\setup.ps1" -Root $root -Toolchain Clang -LLVMRoot $toolRoots[$variant]
    if ($LASTEXITCODE) { throw "Configuration failed: $variant" }
    $build = Get-BuildDirectory $root Ninja Clang
    $entry = Select-String "$build\CMakeCache.txt" -Pattern '^CMAKE_MAKE_PROGRAM:[^=]+=(.+)$'
    if (-not $entry) { throw 'Configured Ninja not found' }
    $currentNinja = [IO.Path]::GetFullPath($entry.Matches[0].Groups[1].Value)
    if ($ninja -and $currentNinja -ne $ninja) { throw 'Ninja selection differs between configurations' }
    $ninja = $currentNinja
    & $ninja -C $build -t compdb | Set-Content "$build\comparison-commands.json"
    if ($LASTEXITCODE) { throw 'Ninja compilation database failed' }
    foreach ($name in @('benchmark-setup.json','CMakeCache.txt','build.ninja','CMakeFiles\rules.ninja',
                        'cvconfig.h','opencv2\opencv_modules.hpp')) {
        $frozen["$build\$name"] = (Get-FileHash "$build\$name").Hash
    }
}
& python "$PSScriptRoot\compare_clang_inputs.py" $roots.stock $roots.custom "$work\input-parity.json"
if ($LASTEXITCODE) { throw 'Workload parity check failed; do not compare mismatched builds.' }
$frozen[$ninja] = (Get-FileHash $ninja).Hash
foreach ($name in @('run.ps1','setup.ps1','common.ps1','measure_build.ps1','BuildAccounting.cs',
                    'run_custom_llvm_study.ps1','compare_clang_inputs.py','..\benchmark.json')) {
    $path = [IO.Path]::GetFullPath("$PSScriptRoot\$name")
    $frozen[$path] = (Get-FileHash $path).Hash
}
function Assert-FrozenInputs {
    foreach ($path in $frozen.Keys) {
        if ((Get-FileHash $path).Hash -ne $frozen[$path]) { throw "Frozen input changed: $path" }
    }
}
$power = (& powercfg /getactivescheme | Out-String).Trim()
foreach ($variant in @('stock','custom')) {
    Assert-FrozenInputs
    Write-Host "Warm-up clean build: $variant (excluded from measured medians)"
    Start-Sleep -Seconds 30
    & $shell -NoProfile -File "$PSScriptRoot\run.ps1" -Root $roots[$variant] -Toolchain Clang `
        -Parallel 20 -MeasureCpu -ResultsDir "$work\warmups" -Label "${variant}_warmup"
    if ($LASTEXITCODE) { throw "Warm-up failed: $variant" }
    Assert-FrozenInputs
}
$order = @('stock','custom','custom','stock','custom','stock','stock','custom')
$manifest = [ordered]@{
    status = 'running'
    started_at = [datetimeoffset]::Now.ToString('o')
    order = $order
    jobs = 20
    pause_seconds = 30
    warmups_per_variant = 1
    warmups_excluded = $true
    completed_labels = @()
    frozen_sha256 = $frozen
    power_scheme = $power
}
New-Item -ItemType Directory $results | Out-Null
$manifest | ConvertTo-Json -Depth 6 | Set-Content "$results\study.json"
$counts = @{ stock = 0; custom = 0 }
try {
    foreach ($variant in $order) {
        Assert-FrozenInputs
        if ((& powercfg /getactivescheme | Out-String).Trim() -ne $power) { throw 'Power scheme changed during the study' }
        $counts[$variant]++
        $label = "${variant}_$($counts[$variant])"
        Write-Host "Measured clean build: $label (30-second rest)"
        Start-Sleep -Seconds 30
        & $shell -NoProfile -File "$PSScriptRoot\run.ps1" -Root $roots[$variant] -Toolchain Clang `
            -Parallel 20 -MeasureCpu -ResultsDir $results -Label $label
        if ($LASTEXITCODE) { throw "Measured build failed: $label" }
        Assert-FrozenInputs
        $manifest.completed_labels += $label
        $manifest | ConvertTo-Json -Depth 6 | Set-Content "$results\study.json"
    }
    if ((& powercfg /getactivescheme | Out-String).Trim() -ne $power) { throw 'Power scheme changed at study completion' }
    $manifest.status = 'succeeded'
    $manifest['finished_at'] = [datetimeoffset]::Now.ToString('o')
} catch {
    $manifest.status = 'failed'
    $manifest['error'] = $_.Exception.Message
    throw
} finally {
    $manifest | ConvertTo-Json -Depth 6 | Set-Content "$results\study.json"
}
& python "$PSScriptRoot\export_results.py" $results $public
if ($LASTEXITCODE) { throw 'Measured-results export failed' }
& python "$PSScriptRoot\export_results.py" "$work\warmups" "$public\warmups"
if ($LASTEXITCODE) { throw 'Warm-up evidence export failed' }
foreach ($name in @('compiler-origin.json','input-parity.json')) {
    Copy-Item "$work\$name" "$public\$name"
}
$summary = Get-Content "$public\summary.json" -Raw | ConvertFrom-Json
$saving = (1 - $summary.custom.median_seconds / $summary.stock.median_seconds) * 100
$message = "Stock LLVM: $($summary.stock.median_seconds)s; custom LLVM: $($summary.custom.median_seconds)s; wall saving: $([math]::Round($saving,2))%. Four measured clean builds each; separate warm-ups. This compares packages, not PGO/LTO alone."
Write-Host $message
if ($env:GITHUB_STEP_SUMMARY) { $message | Add-Content $env:GITHUB_STEP_SUMMARY }
