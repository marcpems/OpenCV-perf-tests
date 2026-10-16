#Requires -Version 7.0
param([Parameter(Mandatory)][string]$StudyRoot)
. "$PSScriptRoot\common.ps1"
if ($env:RUNNER_NAME -ine 'MARCPE-D4') { throw 'Expected Minos runner' }
$repo = [IO.Path]::GetFullPath("$PSScriptRoot\..")
$study = Get-Content "$StudyRoot\study.json" -Raw | ConvertFrom-Json
if ($study.status -ne 'succeeded' -or $study.jobs -ne 20) { throw 'Expected a completed 20-job study' }
$root = Join-Path $repo ".work\minos-runtime-$env:GITHUB_RUN_ID"
if (Test-Path $root) { throw 'Runtime destination exists; do not overwrite evidence.' }
$deadline = [datetimeoffset]::Now.AddHours(2).ToString('o')
New-Item -ItemType Directory "$root\harness" -Force | Out-Null
$origins = @{}
foreach ($variant in @('baseline','shared','llvm')) {
    $snapshot = $study.runtime_snapshots.$variant
    $source = [IO.Path]::GetFullPath((Join-Path $StudyRoot $snapshot.path))
    $allowed = [IO.Path]::GetFullPath("$StudyRoot\runtime-binaries").TrimEnd('\') + '\'
    if (-not $source.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) { throw 'Snapshot path escaped study' }
    foreach ($property in $snapshot.sha256.PSObject.Properties) {
        if ((Get-FileHash "$source\$($property.Name)").Hash -ne $property.Value) { throw "Frozen snapshot changed: $variant" }
    }
    New-Item -ItemType Directory "$root\$variant" | Out-Null
    foreach ($name in @('opencv_world4100.dll','opencv_world4100.lib','benchmark-setup.json','version.txt')) {
        Copy-Item "$source\$name" "$root\$variant\$name"
    }
    $origins[$variant] = @{ label = $snapshot.label; snapshot_sha256 = $snapshot.sha256 }
}
$cpuOutput = & python "$PSScriptRoot\runtime_cpu_topology.py" "$root\cpu-topology.json" --cpus 20
if ($LASTEXITCODE) { throw 'CPU topology query failed' }
$cpu = [int]$cpuOutput
Write-Host "Main benchmark CPU: $cpu; parallel process allows CPUs 0-19."
$receipt = Get-Content "$root\baseline\benchmark-setup.json" -Raw | ConvertFrom-Json
Set-NativeToolchain $receipt.visual_studio $receipt.windows_sdk
$cmake = Get-CMake ''
Copy-Item "$root\baseline\opencv_world4100.dll" "$root\harness"
& $cmake -S "$repo\tests\runtime_screen" -B "$root\harness" -G Ninja -DCMAKE_BUILD_TYPE=Release `
    "-DOPENCV_SOURCE=$repo\.work\minos-source" "-DOPENCV_CONFIG=$repo\.work\minos-source\build_hobl_ninja" `
    "-DOPENCV_IMPORT_LIBRARY=$root\baseline\opencv_world4100.lib" *> "$root\harness-configure.log"
if ($LASTEXITCODE) { Get-Content "$root\harness-configure.log" -Tail 40; throw 'Runtime harness configuration failed' }
& $cmake --build "$root\harness" --parallel 4 *> "$root\harness-build.log"
if ($LASTEXITCODE) { Get-Content "$root\harness-build.log" -Tail 40; throw 'Runtime harness build failed' }
foreach ($module in @('core','imgproc','calib3d','features2d','dnn')) {
    & "$root\harness\screen_$module.exe" --gtest_list_tests *> "$root\list_$module.txt"
    if ($LASTEXITCODE) { throw "Runtime catalog failed: $module" }
}
@{
    source_study = Split-Path $StudyRoot -Leaf
    github_run_id = $env:GITHUB_RUN_ID
    github_commit = $env:GITHUB_SHA
    origins = $origins
    main_cpu_selection = 'Lowest logical CPU in the highest Windows efficiency class'
    source_sha256 = @{
        runner = (Get-FileHash "$PSScriptRoot\run_runtime_screen.py").Hash
        harness = (Get-FileHash "$repo\tests\runtime_screen\main.cpp").Hash
    }
} | ConvertTo-Json -Depth 8 | Set-Content "$root\provenance.json"
Copy-Item "$PSScriptRoot\run_runtime_screen.py" "$root\measured-runner.py"
& python "$PSScriptRoot\run_runtime_screen.py" $root prepare --deadline $deadline `
    --affinity --single-cpu $cpu --parallel-threads 20 --pin-main
if ($LASTEXITCODE) { throw 'Runtime preparation failed' }
& python "$PSScriptRoot\run_runtime_screen.py" $root pilot
if ($LASTEXITCODE) { throw 'Runtime pilot failed' }
& python "$PSScriptRoot\run_runtime_screen.py" $root run
$measurementExit = $LASTEXITCODE
& "$PSScriptRoot\export_minos_runtime.ps1" -SourceRunId $env:GITHUB_RUN_ID
if ($measurementExit) { throw 'Runtime measurement failed; completed-study evidence was exported without treating failures as passes.' }
if ($env:GITHUB_STEP_SUMMARY) {
    "Runtime screen complete: 52 cases, three libraries, 1/20 threads, six balanced rounds. Main CPU $cpu. Results include output-check limitations and per-case ranges." |
        Add-Content $env:GITHUB_STEP_SUMMARY
}
