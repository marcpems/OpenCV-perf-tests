# Targeted OpenCV runtime comparison

**Shared-cap MSBuild showed no systematic runtime penalty; LLVM was often
faster, but was not uniformly equivalent or better.** A particular depthwise
convolution was consistently **13.2% slower** with LLVM on CPU 6. The result
supports keeping the scheduler improvement separate from a compiler migration,
and doing targeted runtime follow-up before adopting LLVM.

This is a **16 October 2026 Windows ARM64 screening study**, not a full OpenCV
correctness suite, application benchmark, or formal equivalence test.
The requested two-hour window began at **13:05:38 BST**; all runtime measurements
finished at **13:39:12 BST**, about **33 minutes 35 seconds** later, including
setup and two diagnostic passes. Reporting/publication followed separately.

## 1. What was compared

| Variant | Library used | Preparation |
|---|---|---|
| Baseline | Original HOBL-style MSVC 19.44.35229 / MSBuild Release DLL | Reused existing binary |
| Shared cap | Same MSVC/configuration; project parallelism and shared 12-compiler budget | Rebuilt only this library because its earlier output had been overwritten |
| LLVM | LLVM 23.1.3 `clang`/`clang++`, Ninja, Release DLL | Reused existing binary |

These are the configurations from the
[five-way build rerun](FIVE_CONFIGURATION_RERUN.md), not the separate VS 2026
experiment. All use OpenCV **4.10.0**, source commit
`71d3237a093b60a27601c20e9ee6c3e52154e8b1`, on the same Snapdragon X2 Elite
12-logical-processor machine. The LLVM experiment uses GNU-style Clang drivers,
**not `clang-cl`**, and retains its existing optimization/dispatch differences.

Baseline and shared-cap libraries have **byte-identical `.text` sections**:
23,636,992 bytes, SHA-256
`f5b6b345d14c3ad9e4e05258142c1013acba666e89b5010004105ebce3b6c797`.
Their full DLLs are not byte-identical. This is strong evidence that the
scheduler change did not change executable code, not a proof that every aspect
of the files or their behavior is identical.

The shared-cap rebuild took 183.5483 s, but overlapped harness compilation:
**do not add it to the earlier build-performance comparison**. Its scheduler
arguments and provenance are recorded in the
[final evidence](../results/runtime-screen-20261016/final-cpu6/provenance.json).
No library source or HOBL build defaults were changed for this screen.

### Reusing the actual libraries

HOBL sets `BUILD_PERF_TESTS=OFF`. Instead of rebuilding all three libraries with
tests enabled, a separate CMake project compiled selected **unaltered upstream
performance-test sources and `opencv_ts`**, linked against the preserved MSVC
import library. Exactly the same MSVC-built test executable bytes were then
used with all three DLLs. Consequently the comparison isolates library runtime
rather than changing the test harness compiler at the same time.

Every process audited the actual loaded DLL path, native ARM64 execution,
configured OpenCV thread count, and requested affinity. DLLs, import libraries
and harness executables were SHA-256 frozen. Tests execute in variant-specific
directories; no binary replacement or persistent PATH change is needed.

## 2. Final controlled results

The table reports the **change in elapsed operation time versus baseline**.
Negative is better. Each module summary is an **equal-case-weight geometric
mean of ratios**, not an application-wide speedup. Thread counts are configured
OpenCV limits; not every operation actually uses twelve threads.

Single-thread runs are pinned to **logical CPU 6**. Twelve-thread runs allow
workers on **CPUs 0-11**, with the main thread pinned to CPU 6 after worker
warm-up. These are controlled-placement results, not default-scheduler results.

| Selected area | Cases | Shared, 1 thread | LLVM, 1 thread | Shared, 12 threads | LLVM, 12 threads |
|---|---:|---:|---:|---:|---:|
| Core arithmetic, DFT, norm, phase, SVD | 19 | -1.5% | -9.1% | -3.5% | -13.6% |
| Image processing | 16 | +0.2% | -24.3% | -0.1% | -16.2% |
| Camera pose / PnP | 5 | approximately 0.0% | -11.6% | +1.0% | -12.3% |
| Descriptor distance | 4 | +1.0% | -1.4% | +0.3% | -0.1% |
| Synthetic DNN convolution | 8 | +0.1% | -18.9% | -2.9% | -4.4% |

Across the **104 case/thread combinations**, shared-cap was within 5% of
baseline in **93**, and within 10% in **98**. Some short arithmetic and
multithreaded DNN cases still have wide overlapping ranges. Apparent shared-cap
gains on those cases are not established code-generation improvements, given
the identical code sections. No positive shared-cap regression met the screen's
10%/five-of-six directional follow-up heuristic.

### Concrete signals worth following

Times below are milliseconds, using the median of six per-process medians.
All listed **single-thread** LLVM differences have the same direction in all
six balanced blocks. These selected examples are not a replacement for the
[complete per-case results](../results/runtime-screen-20261016/final-cpu6/summary.json).

| Operation | Threads | Baseline ms | Shared ms | LLVM ms | LLVM time change |
|---|---:|---:|---:|---:|---:|
| BGR to gray, 1920x1080 | 1 | 0.6742 | 0.6794 | 0.2530 | **-62.5%** |
| BGR to gray, 1920x1080 | 12 | 0.1654 | 0.1645 | 0.0707 | **-57.3%** |
| Exact linear resize, 8UC3, 640x480 to 1280x720 | 1 | 3.4595 | 3.4548 | 1.6034 | **-53.7%** |
| Same exact resize | 12 | 0.8770 | 0.8781 | 0.6949 | **-20.8%** |
| Double-precision phase, 1,048,576 elements | 1 | 0.9610 | 0.9546 | 0.6451 | **-32.9%** |
| DFT, 800x600, 32FC1 | 1 | 1.8048 | 1.7983 | 1.6004 | **-11.3%** |
| 3x3 convolution, Winograd disabled, case 1 | 1 | 20.1268 | 20.0971 | 13.2330 | **-34.3%** |
| Depthwise convolution, case 3 | 1 | 0.3195 | 0.3193 | 0.3617 | **+13.2%** |
| Nonexact linear resize, 32FC1, 640x480 to 1280x720 | 12 | 0.1031 | 0.0990 | 0.1113 | **+7.9%** |

The depthwise regression is particularly clean: baseline's six medians span
**0.3190-0.3208 ms**, shared **0.3186-0.3197 ms**, and LLVM
**0.3609-0.3623 ms**. It is upstream `Conv_Depthwise.conv/3`:
3x3, input `{1,336,46,46}`, 336 output channels/groups, padding 1, bias,
OpenCV CPU backend. At twelve threads its +5.7% median difference has overlapping
ranges and mixed paired directions: do not extrapolate the single-core result.

The floating-point resize is upstream
`MatInfo_SizePair_resizeUpLinearNonExact.resizeUpLinearNonExact/17`.
Its +7.9% twelve-thread change is below the automated 10% flag threshold, but all
six paired blocks are slower, so it is a useful lower-priority follow-up.

## 3. CPU placement materially changes interpretation

Windows `GetSystemCpuSetInformation` reports **two efficiency classes**:
CPUs 0-5 are class 0 / LLC 0, and CPUs 6-11 class 1 / LLC 6, all in group 0.
The [topology record](../results/runtime-screen-20261016/final-cpu6/cpu-topology.json)
is the OS report; we did not measure per-core clock frequencies or power.

The first pass, with normal scheduling, produced implausible baseline/shared
differences despite identical executable code. For example, the same MSVC
320x480 DFT appeared around **0.512 ms or 1.207 ms**, and small L2 norm around
**0.0404 ms or 0.0915 ms**. This is consistent with cross-class placement, but
the initial per-sample processor placement was not recorded.

Three separate datasets are preserved rather than pooled:

| Stage | Elapsed study wall | Placement | Interpretation |
|---|---:|---|---|
| [Initial](../results/runtime-screen-20261016/initial-uncontrolled/summary.json) | 4m 45s | Default scheduling, no added CPU warm-up | Diagnostic only; large shared differences are confounded |
| [CPU 0 control](../results/runtime-screen-20261016/cpu0-process-affinity/summary.json) | 8m 52s | 1 thread on CPU 0; 12 threads allowed all CPUs; 1 s warm-up | Single-thread class-0 comparison useful; serial work in 12-thread mode can still migrate |
| [Final CPU 6 control](../results/runtime-screen-20261016/final-cpu6/summary.json) | 7m 42s | 1 thread on CPU 6; all-core workers plus fixed CPU-6 main thread; 1 s warm-up | Primary results above |

The final harness warms the worker pool **before** pinning the main thread.
A [live thread-mask audit](../results/runtime-screen-20261016/final-cpu6/thread-affinity-audit.json)
observed mask 64 for the pinned thread and mask 4095 for other threads in
twelve-thread processes. The workers were not accidentally restricted to one
CPU. This audit samples allowed placement, not actual per-operation utilization.

The class-0 comparison also matters: floating-point nonexact resize was
**12.2% slower with LLVM** on CPU 0, versus only **1.2%** on CPU 6; depthwise
case 3 was **1.8% faster** on CPU 0 versus **13.2% slower** on CPU 6.
Single-thread DNN's equal-case aggregate was -0.8% on CPU 0 versus -18.9% on
CPU 6. Thus the compiler/runtime tradeoff is **operation- and core-class-specific**.
Affinity removes a major confound, not every source of cache, thermal or
background-load variation.

## 4. Coverage, budget and limitations

Each stage uses the same **52 fixed cases**, two thread modes, three variants,
and six balanced variant orders, with **20 samples per case/process**.
This produces **1,872 measured case executions per stage**, **5,616** across all
three stages. All completed with **zero reported failures or skips**; every
measured XML case records 20 samples. The stages are separate experiments.

The balanced orders are baseline/shared/LLVM, shared/LLVM/baseline,
LLVM/baseline/shared, LLVM/shared/baseline, baseline/LLVM/shared, and
shared/baseline/LLVM. Thread order alternates between blocks. Five-second rests
separate variants. There is a 180-second executable timeout, a 1,800-second
cumulative executable-wall cap per variant per stage, and the original absolute
deadline of **15:05:38 BST**. No additional runs were needed to use up the budget.

| Variant | Final-stage executable wall, including pilot/warm-ups | Across all three stages |
|---|---:|---:|
| Baseline | 129.8 s | 322.6 s |
| Shared cap | 123.8 s | 305.7 s |
| LLVM | 110.1 s | 278.2 s |

These are harness-process wall totals, **not comparable application speedups**:
they include startup, test setup and deliberate warm-up, but not wrapper/hash
work or rests. Adding the 90 seconds of scheduled rests per variant across all
stages still leaves each below seven minutes of process-plus-rest time. Setup,
all measurements, and investigation fit well inside the requested two-hour
overall allocation.

The selected test families cover arithmetic, DFT, norm, phase, small SVD, resize,
Gaussian filtering, grayscale/HSV conversion, erosion, iterative/EPnP/P3P pose,
Hamming/L2 descriptor distances, and synthetic CPU convolution/depthwise cases.
They require no downloaded images or models.

**Only 29 of the 52 cases have baseline-derived output sanity records**:
core 8, imgproc 12, calib3d 5, features2d 4. The other **23** do not check outputs,
including **all eight DNN cases**. The generated records are a differential
screen against this baseline, not an independent mathematical reference or
complete element-by-element accuracy test.

No claim is made about full OpenCV API coverage, production-model accuracy,
model import/startup, ORB extraction, codecs/video I/O, GPU backends, sustained
throughput, energy, or latency tails. DNN uses synthetic upstream networks and
warm forward calls, not a downloaded end-to-end model.
In OpenCV 4.10, `SOLVEPNP_DLS` falls back to EPnP, so those labels were excluded;
**the compiler-hot internal DLS implementation is not exercised here**.

The analyzer flags changes of at least 10% with five-of-six paired directional
agreement, and marks baseline latencies below 0.05 ms as tiny cases. This is a
triage heuristic, **not a statistical significance test, multiple-comparison
correction, or equivalence margin**. Do not combine the module means into a
single claimed OpenCV application speedup.

## 5. Recommended next actions

1. Keep the [shared-cap delivery task 64678273](https://microsoft.visualstudio.com/OS/_workitems/edit/64678273)
   moving independently. This screen found no systematic runtime penalty, and
   the executable-code hash matched. Retain normal integration/correctness gates.
2. Under [runtime task 64678276](https://microsoft.visualstudio.com/OS/_workitems/edit/64678276),
   isolate `Conv_Depthwise.conv/3` and float resize case 17 on both CPU classes.
   Add explicit output comparisons, nearby shapes, longer steady-state samples,
   and inspect selected kernels/assembly before attributing the cause to a
   particular compiler optimization.
3. Validate the strong LLVM gray/resize/convolution leads with representative
   application inputs and real-model accuracy/latency, including startup.
   [Clang exploration 64678275](https://microsoft.visualstudio.com/OS/_workitems/edit/64678275)
   should not treat the build-time gain as sufficient migration evidence.
   No new issues or ADO state changes were made for this screen.

## 6. Reproduce without rebuilding every library

The harness is [tests/runtime_screen](../tests/runtime_screen/CMakeLists.txt);
the driver is [run_runtime_screen.py](../scripts/run_runtime_screen.py).
Use the pinned OpenCV source and existing generated configuration matching the
libraries. Prepare a **fresh private directory** with this layout:

```text
.work\runtime-new\
  baseline\opencv_world4100.dll, opencv_world4100.lib, benchmark-setup.json, version.txt
  shared\opencv_world4100.dll, opencv_world4100.lib, benchmark-setup.json, version.txt
  llvm\opencv_world4100.dll, opencv_world4100.lib, benchmark-setup.json, version.txt
  harness\
```

Copy the Release DLL/import library and setup receipt from each preserved
build; `version.txt` is that build's `opencv_version --verbose` output.
**Snapshot baseline before a shared-cap rebuild:** these two configurations
normally use the same build tree. If only shared-cap is missing, the existing
runner reconstructs it with:

```powershell
pwsh -NoProfile -File scripts\run.ps1 -Parallel 12 `
  -MSBuildScheduler MultiToolTask -CompilerJobs 12 -SharedCompilerLimit `
  -Label runtime_shared
```

Compile the harness once in a native ARM64 MSVC environment. The measured
configuration used the existing MSVC/Ninja generated headers; it did not
regenerate or rebuild that OpenCV library:

```powershell
$root = Join-Path (Get-Location) '.work\runtime-new'
$cmake = Join-Path (Get-Location) '.tools\cmake-4.1.1-windows-arm64\bin\cmake.exe'
. .\scripts\common.ps1
$receipt = Get-Content "$root\baseline\benchmark-setup.json" -Raw | ConvertFrom-Json
Set-NativeToolchain $receipt.visual_studio $receipt.windows_sdk
& $cmake -S tests\runtime_screen -B "$root\harness" -G Ninja `
  -DCMAKE_BUILD_TYPE=Release -DOPENCV_SOURCE=D:\opencv `
  -DOPENCV_CONFIG=D:\opencv\build_hobl_ninja `
  "-DOPENCV_IMPORT_LIBRARY=$root\baseline\opencv_world4100.lib"
if ($LASTEXITCODE) { throw 'Harness configure failed' }
& $cmake --build "$root\harness" --parallel 4
if ($LASTEXITCODE) { throw 'Harness build failed' }
Copy-Item "$root\baseline\opencv_world4100.dll" "$root\harness"
foreach ($module in 'core','imgproc','calib3d','features2d','dnn') {
  & "$root\harness\screen_$module.exe" --gtest_list_tests |
    Set-Content "$root\list_$module.txt"
  if ($LASTEXITCODE) { throw "Catalog failed: $module" }
}
```

Set the absolute deadline from the **start of the allotted session**, including
setup, not two hours from the first test. Adjust CPU selection only after
checking the machine's topology; this protocol assumes group 0 with CPUs 0-11.
The historical deadline below must be replaced for a new run:

```powershell
$deadline = '2026-10-16T15:05:38+01:00'
python scripts\run_runtime_screen.py $root prepare --deadline $deadline `
  --affinity --single-cpu 6 --pin-main
if ($LASTEXITCODE) { throw 'Preparation failed' }
python scripts\run_runtime_screen.py $root pilot
if ($LASTEXITCODE) { throw 'Sanity pilot failed' }
python scripts\run_runtime_screen.py $root run
if ($LASTEXITCODE) { throw 'Runtime screen failed' }
python scripts\analyze_runtime_screen.py $root --export results\runtime-new
if ($LASTEXITCODE) { throw 'Analysis/export failed' }
```

The pilot creates baseline sanity records using ten samples; measurement uses
twenty and verifies that references and binaries remain frozen. Use a fresh
directory for every new experiment. Analysis runs against the private binary
snapshot; the public export contains sanitized **text evidence only**, not DLLs,
test executables, upstream source copies, or machine-wide traces.
The final export also preserves `measured-runner.py`, the exact driver used for
the observations. The current driver adds stricter case-identity/failure guards
and deadline-bounded rests; no measurement parameters changed.
