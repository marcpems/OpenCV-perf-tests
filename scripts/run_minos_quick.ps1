#Requires -Version 7.0
. "$PSScriptRoot\common.ps1"
$shell = (Get-Process -Id $PID).Path
& $shell -NoProfile -File "$PSScriptRoot\prepare_minos_tools.ps1"
if ($LASTEXITCODE) { throw 'Minos tool preparation failed' }
$repo = [IO.Path]::GetFullPath("$PSScriptRoot\..")
$root = Join-Path $repo '.work\minos-source'
$local = Join-Path $repo ".work\minos-first-$env:GITHUB_RUN_ID"
$public = Join-Path $repo "results\minos-llvm-first-$env:GITHUB_RUN_ID"
if (Test-Path $local) { throw 'First-build destination exists; use a new workflow run.' }
$jobs = [int](Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
if ($jobs -ne 20) { throw "Expected the inventoried 20-core Minos runner, found $jobs" }
& $shell -NoProfile -File "$PSScriptRoot\setup.ps1" -Root $root -Toolchain Clang
if ($LASTEXITCODE) { throw 'LLVM configuration failed' }
Start-Sleep -Seconds 30
& $shell -NoProfile -File "$PSScriptRoot\run.ps1" -Root $root -ResultsDir $local `
    -Toolchain Clang -Parallel $jobs -MeasureCpu -Label llvm_first
if ($LASTEXITCODE) { throw 'First LLVM build failed' }
& python "$PSScriptRoot\export_results.py" $local $public
if ($LASTEXITCODE) { throw 'First-build export failed' }
$metadata = @(Get-ChildItem $local -Recurse -Filter metadata.json)
if ($metadata.Count -ne 1) { throw 'Expected one first-build result' }
$result = Get-Content $metadata[0].FullName -Raw | ConvertFrom-Json
$message = "Ninja/LLVM first clean build: **$($result.build_seconds) seconds**, $jobs jobs. Preliminary single observation; not pooled with the later balanced five-configuration study."
Write-Host $message
if ($env:GITHUB_STEP_SUMMARY) { $message | Add-Content $env:GITHUB_STEP_SUMMARY }
