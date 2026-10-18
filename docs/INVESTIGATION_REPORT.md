# OpenCV build and runtime investigation

**18 October 2026 — consolidated findings and delivery plan**

## Executive summary

- **Prioritize shared-budget MSBuild delivery.** Against the original command,
  it reduced median build wall time **12.8% on Surface and 31.8% on Minos**,
  without changing compiler/source options. This is implemented and measured in
  this benchmark, **not delivered to HOBL or a product pipeline**.
- **Compiler work is a separate, larger opportunity.** With Ninja fixed, stock
  LLVM used **42.56% / 43.86% less wall time** and **47.61% / 46.47% less CPU**
  than MSVC on Surface / Minos. Native-execution checks, direct compilations and
  source-shape experiments reproduce the gap. **No specific optimizer pass
  explains the whole gap on the available evidence.**
- **Custom LLVM is a further package-level improvement:** **56.4598 s versus
  fresh stock 62.8931 s**, saving **10.23% wall / 10.90% CPU** on Minos.
  Different LLVM versions and bundled tools prevent PGO/LTO-only attribution.
- **Do not approve a compiler migration on build speed alone.** Stock LLVM
  improves many selected runtime kernels, but depthwise/resize regressions and
  intermittent Minos descriptor output failures remain. Custom LLVM runtime
  and numerical correctness have **not** been tested.

[Build results](#build-results) · [Runtime results](#runtime-results) ·
[Decisions and limits](#decisions-and-limits) ·
[Exact MSBuild proposal](#msbuild-what-to-change) ·
[MSVC investigations and bugs](#msvc-investigations-and-existing-bug-follow-ups) ·
[Next actions](#delivery-and-next-actions)

## Scope and measurement contract

OpenCV **4.10.0**, commit
[`71d3237a093b60a27601c20e9ee6c3e52154e8b1`](https://github.com/opencv/opencv/tree/71d3237a093b60a27601c20e9ee6c3e52154e8b1),
reproduces all **23 Windows HOBL CMake definitions** in
[`benchmark.json`](../benchmark.json). The sequence is **clean → timed Release
build → untimed install/version validation**. Setup, cleaning and installation
are not build wall time. CPU seconds are measured descendant user+kernel time,
not machine-wide utilization or summed Ninja command durations.

| Device / series | Hardware and fixed controls |
|---|---|
| Surface, 14–16 October | Surface Laptop 8 for Business; Snapdragon X2 Elite, 12 cores, 64 GB installed (63.48 GiB visible), 1 TB SSD/ReFS. Windows 11 build 28000; High performance plan. |
| Minos, 16–18 October | NVIDIA RTX Spark N1X, 20 cores, 31.7 GiB usable, Windows 11 build 28000, build volume D: ReFS; Ultimate Performance plan. **Different hardware**, not another Surface run. |
| Original Microsoft stack | Native ARM64 MSVC **19.44.35229.0**, toolset directory **14.44.35207**, MSBuild **17.14.60.43110**, CMake **4.1.1**. SDK target **10.0.26100.0**; servicing **26100.7705** on Surface versus **26100.8249** on Minos. |
| Stock LLVM | Native ARM64 **23.1.3**, GNU-style `clang`/`clang++` plus LLD/Ninja; **not `clang-cl`**. Windows SDK and MSVC headers/runtime remain required. |

Scripts did not change power plans. Tool/version/hash receipts, adaptations
from official HOBL, and timing rules are in the [methodology](METHODOLOGY.md).
The owner-supplied lab reference is **154 s Minos versus 53 s M5 Pro (~2.9×)**.
No Mac measurement was performed here: this is **not a measured Mac-equivalence
claim**, even where a Windows time approaches 53 s.

## Build results

### Matched five-way studies — do not pool devices

Each study has **two clean builds per configuration**, forward/reverse order,
30-second rests, CPU accounting, and no WPR/binlog instrumentation. Savings use
the **original MSBuild median on the same device** as denominator.
MTT = compiler-only MultiToolTask; shared = MTT + project parallelism +
cross-node compiler cap. Original MSBuild already uses compiler `/MP`; it is
**not single-threaded**.

| Configuration | Surface wall s | Surface CPU s | Wall saved | Minos wall s | Minos CPU s | Wall saved |
|---|---:|---:|---:|---:|---:|---:|
| Original MSBuild | 215.117 | 1,658.711 | Reference | 170.534 | 1,866.445 | Reference |
| MSBuild MTT | 195.290 | 1,780.148 | 9.2% | 126.881 | 1,903.664 | 25.6% |
| MSBuild shared cap | 187.674 | 1,826.219 | 12.8% | 116.368 | 1,999.258 | 31.8% |
| Ninja/MSVC | 173.005 | 1,779.711 | 19.6% | 115.692 | 2,022.633 | 32.2% |
| Ninja/LLVM | 99.374 | 932.430 | 53.8% | 64.949 | 1,082.750 | 61.9% |

Optimized budgets are **12 on Surface / 20 on Minos**; the baseline has no
explicit project-worker setting. Surface's reported device-setting change
before this rerun was not specified, and every second observation was slower.
Baseline ranges: **204.883–225.351 s** Surface, **165.496–175.573 s** Minos.

On Minos, Ninja/MSVC is only **0.676 s / 0.58%** faster than shared MSBuild,
smaller than observed variation: an additional material Ninja gain is
**unproven there**. Minos's baseline median is **10.74% above 154 s**; the
reference lies outside its observed range, and the median is just outside a
descriptive ±10% band. Neither is a statistical equivalence test.

Sources: [Surface report](FIVE_CONFIGURATION_RERUN.md) /
[data](../results/five-config-rerun-20261015/summary.json);
[Minos report](MINOS_RESULTS.md) /
[data](../results/minos-builds-38914616842/summary.json) /
[measurement run 38914616842](https://github.com/marcpems/OpenCV-perf-tests/actions/runs/38914616842).
The [61.5596 s preliminary Minos LLVM run](../results/minos-llvm-first-38913335754)
is separate, not a third observation.

### Custom LLVM — fresh same-session control, 18 October

| Package | Measured builds | Median wall s | Wall range s | Median CPU s |
|---|---:|---:|---:|---:|
| Stock LLVM 23.1.3 | 4 | 62.8931 | 62.4138–63.9064 | 1,015.0469 |
| Custom LLVM 24.0.0git PGO/LTO | 4 | **56.4598** | **55.9250–56.9982** | **904.3750** |

One excluded warm-up per package; **ABBA–BAAB**, 20 jobs, 30-second rests.
Every custom observation beat every stock observation: **6.4334 s / 10.23%**
median wall saving. The historical **64.9488 s** is **not** this control.
Matched feature headers and normalized commands cover **1,018 generated
compilation entries**; each measured build executed **1,016 compilation
steps**. These counts describe different things.

The gain is predominantly compilation. Overlapping Ninja step sums are not
wall or CPU savings. Both compilers are native ARM64 and report rpmalloc;
compiler version/revision and bundled tools also differ. A **matched LLVM 24
build without PGO/LTO** is needed to isolate compiler-build optimization.
No OpenCV PGO/LTO flags were enabled.

The first preflight failed **before timing** because LLVM 24's probe added
`-Wno-stringop-overread`. Both configurations then used the same explicit
initial-cache values `HAVE_C_WNO_STRINGOP_OVERREAD=0` and
`HAVE_CXX_WNO_STRINGOP_OVERREAD=0`; parity was checked again, not bypassed.
The private package was administratively extracted, not globally installed or
substituted on persistent PATH. Public artifacts contain text, not binaries.

[Report and controls](CUSTOM_LLVM_COMPARISON.md) /
[data](../results/minos-custom-llvm-39129486630/summary.json) /
[successful run 39129486630](https://github.com/marcpems/OpenCV-perf-tests/actions/runs/39129486630).

### Historical controls — each row is its own series

All values below are median build wall seconds; **do not compute a single
cross-row ranking or compound the gains**. Reports link the individual runs.

| Investigation | Matched observations | Finding |
|---|---|---|
| [Initial generator study, 14 Oct](ANALYSIS.md) | Original 230.34; `/m:12` 219.24; Ninja/12 192.99; **2 each** | Project parallelism alone was modest; Ninja saved 16.2% versus that original. |
| [Ninja worker count](NINJA_PARALLELISM.md) | Explicit 12: 185.34; implicit default **14**: 186.44; **4 each** | 0.59% difference, large variation; **12 was not established as optimal**. |
| [Initial native LLVM](CLANG_EXPERIMENT.md) | MSVC/Ninja 172.75; LLVM/Ninja 103.02; **2 each** | 40.36% less wall with Ninja/12 fixed; separate compiler configurations. |
| [VS 2026 stack](VS2026_EXPERIMENT.md) | VS 2022 226.6839; VS 2026 226.2238; **2 each** | 0.20% difference, mixed pairs: no reliable gain. MSVC 19.51.36260, MSBuild 18.11.0.47511 and CMake 4.4.4 change together, old SDK retained. |
| [Latest SDK on VS 2026](WINDOWS_SDK_EXPERIMENT.md) | SDK 26100.7705: 233.8396; 28000.2957: 238.3604; **4 each** | +1.93%, overlapping ranges: no demonstrated speedup or established general regression. |
| [CPU/WPR study](CPU_ETL_ANALYSIS.md) | Original 210.804; MSVC/Ninja 172.061; LLVM/Ninja 94.898; **2 untraced each** | CPU medians 1,716.117 / 1,819.570 / 893.898 s. Scheduling and compiler-work effects are distinct. |
| [Serial-tail remedy](MSBUILD_SERIAL_TAIL.md) | Original 201.522; compiler-only MTT 188.376; **2 untraced each** | 6.52% less wall, **7.25% more CPU**; not recovery of the entire ~45 s tail. |
| [Shared-cap follow-up](MSBUILD_SHARED_PARALLELISM.md) | MTT 205.355; shared 180.939; Ninja/MSVC 176.749; **2 untraced each** | Shared saved 11.89% versus fresh MTT; 2.37% above Ninja with mixed pairs/overlapping ranges. |

The VS 2026 installation's 3010 was investigated as a **verified soft reboot
recommendation**; fresh-process measurements were pre-restart, not post-reboot
confirmation. Its compatibility pilot is excluded. The SDK study recovered a
between-run PowerShell hang: the final pair followed **132.11 s**, not 30 s,
with frozen inputs verified. All eight observations remain; the six-run
sensitivity analysis is not the primary result.

Other exclusions remain exclusions: initial CMake 4.4.3 runs, heavily
instrumented timings, failed/interrupted builds, and the early
`UseMultiToolTask=true` / `TrackFileAccess=false` experiment that rebuilt during
installation. [Initial exclusions](ANALYSIS.md#exploratory-runs-and-exclusions).

## Runtime results

One common **MSVC-built harness**, using unaltered upstream test sources,
loads the three retained DLLs: original, shared-cap and **stock** LLVM.
Same EXE bytes across variants; library paths, native architecture, affinity
and thread settings were audited. **52 cases**: core 19, imgproc 16, calib3d 5,
features2d 4, DNN 8; six balanced rounds, 20 samples per measured case.

The following are **equal-case-weight geometric mean time changes versus each
device's baseline**; negative is faster. `P` means 12 threads on Surface,
20 on Minos; not every operation uses the entire configured pool.

| Area | Surface shared 1t / P | Surface LLVM 1t / P | Minos shared 1t / P | Minos LLVM 1t / P |
|---|---:|---:|---:|---:|
| Core | −1.5% / −3.5% | −9.1% / −13.6% | −1.1% / −2.3% | −10.4% / −10.7% |
| Image processing | +0.2% / −0.1% | −24.3% / −16.2% | +0.2% / −0.8% | −23.3% / −18.1% |
| Pose/PnP | ~0.0% / +1.0% | −11.6% / −12.3% | +0.6% / +0.8% | −10.6% / −9.6% |
| Descriptor distance | +1.0% / +0.3% | −1.4% / −0.1% | −0.5% / +2.7% | −1.1% / −4.3% |
| DNN convolution | +0.1% / −2.9% | −18.9% / −4.4% | −0.2% / +2.1% | −30.0% / −3.7% |

**Minos parallel descriptors include only 2/4 cases** after failure exclusions.
These are selected-kernel summaries, not whole-application speedups.

| Screen | Coverage and outcome |
|---|---|
| [Surface final CPU 6](../results/runtime-screen-20261016/final-cpu6/summary.json) | 1/12 threads; **1,872 executions, 0 reported failures/skips**. Baseline/shared `.text` identical; **93/104** case/thread comparisons within 5%. |
| [Surface placement investigation](RUNTIME_SCREENING.md#3-cpu-placement-materially-changes-interpretation) | Initial default scheduling, CPU-0 control and final CPU-6 control are separate datasets: **5,616 executions total**, no reported failures/skips. Initial differences despite identical MSVC code were confounded by placement; no pooling. |
| [Minos CPU 5](../results/minos-runtime-38914616842/summary.json) | 1/20 threads; **1,872 executions, 2 output failures, 0 skips**. Failed case/thread groups excluded across **all variants**, leaving **102/104** valid groups. Baseline/shared `.text` identical; **91/102** within 5%. |

CPU 6 and CPU 5 were selected from each machine's own reported topology.
Parallel workers retained all-core affinity after warm-up; the main thread
was pinned. Do not transfer CPU numbers between machines.

**Runtime leads, not migration approval:**

- Depthwise `Conv_Depthwise.conv/3`: LLVM **+13.23%** at Surface CPU-6/1t and
  **+11.29%** at Minos CPU-5/1t, slower in all six rounds on both. The Surface
  CPU-0 result was different; investigate core class and kernel selection.
- Float nonexact resize case 17: Surface **+12.19% CPU-0/1t**, **+1.19%
  CPU-6/1t**, **+7.91% at 12t**; Minos **+7.68% at 1t / +7.10% at 20t**.
- Only **29/52 cases** have baseline-derived sanity references; **all eight
  DNN cases are unchecked**. Passing reported checks is not full-array
  numerical equivalence or real-model qualification. `SOLVEPNP_DLS` falls
  back to EPnP and does not exercise the internal DLS source rewrite.

### Preserve the Minos correctness failures

Original screen: LLVM round 1/20t
`Source_CrossCheck_batchDistance_L2.batchDistance_L2/3` returned maximum
**FLT_MAX instead of 0.24995327**; shared round 5/20t
`Norm_CrossCheck_batchDistance_Dest_32S.batchDistance_Dest_32S/1` returned
minimum index **−1 instead of 0**. These are output-check failures, not timing
noise. Sentinel/unmatched values are compatible with the source's initialization
but do not prove a cause.

A [separate ten-round diagnostic](../results/minos-runtime-diagnostic-38920209565)
ran those two cases across three DLLs at 1/20 threads (**120 executions**).
The **original baseline** failed twice at 20t: Hamming round 2 (−1 versus 0),
L2 round 8 (**0.472514212 versus 0.249953270**). No 1t checks failed.
Thus failures have occurred in **all three variants**; neither LLVM nor shared
scheduling is established as the cause. Library threading, harness, input
repeatability and reference generation remain unresolved.

[Diagnostic run 38920209565](https://github.com/marcpems/OpenCV-perf-tests/actions/runs/38920209565)
is separate from performance medians.
[Export-only recovery 38919819092](https://github.com/marcpems/OpenCV-perf-tests/actions/runs/38919819092)
preserved the original failed screen; it did **not** convert it into a pass.
Full interpretation: [Surface](RUNTIME_SCREENING.md), [Minos](MINOS_RESULTS.md).

## Decisions and limits

1. **Keep the original HOBL-score path.** Offer shared-cap as a labeled,
   reversible option; keep normal integration/correctness gates. Do not add
   savings from alternative configurations together.
2. **Do not mandate Ninja or a universal core-count cap.** Ninja is useful on
   Surface, but its incremental Minos advantage over shared MSBuild is unproven.
   A compiler-process cap is not a total-thread cap.
3. **Keep LLVM adoption gated.** GNU-style Clang is measured; `clang-cl` is a
   proposed separate experiment. Compiler semantics differ: MSVC
   `/O2 /Ob2 /EHa /fp:precise` versus Clang `-O3`, plus compiler-specific
   preprocessor/dispatch paths and `-fno-delayed-template-parsing`.
4. **No causal shortcuts:** no proven specific optimizer-pass explanation,
   PGO/LTO-only benefit, Mac equivalence, application-wide runtime gain,
   energy saving, or universal compiler winner.
5. These are warm-cache, normal-use-machine studies, not thermal/frequency-
   controlled trials. Small-sample ranges are not confidence intervals.
   Runtime coverage excludes full OpenCV tests, real models, import/startup,
   full ORB/video/GPU qualification, power and latency tails.

## MSBuild: what to change

### Diagnosis and implemented benchmark option

[WPR + binlog correlation](MSBUILD_SERIAL_TAIL.md) found a **44.793 s** serial
region: **31.199 s compiler lifetimes**, **7.554 s before launches**,
**6.038 s after exits**, **0.002 s between tasks**. The world project had one
479-source `/MP` batch followed by **34 one-source CL tasks**: 32 unique
object-name overrides and two definition overrides. Dependency-table
construction accounted for **59.28% of MSBuild tail CPU samples** (inclusive,
not full-build wall time). Do not remove collision-preventing object names or
disable dependency tracking.

**Already implemented here:** [`scripts\run.ps1`](../scripts/run.ps1) exposes
`-MSBuildScheduler MultiToolTask -CompilerJobs N -SharedCompilerLimit -Parallel N`.
[`scripts\run_msbuild_parallelism_study.ps1`](../scripts/run_msbuild_parallelism_study.ps1)
provides balanced comparisons; [`scripts\setup.ps1`](../scripts/setup.ps1)
retains the same MSBuild tree/source/features. Example for Minos:

```powershell
pwsh -NoProfile -File scripts\run.ps1 -MeasureCpu `
  -MSBuildScheduler MultiToolTask -CompilerJobs 20 `
  -SharedCompilerLimit -Parallel 20 -Label shared20
```

Actual timed command (use 12 for the Surface study):

```powershell
cmake --build . --config Release --parallel 20 -- `
  /p:MultiProcCL=true /p:MultiProcMaxCount=20 `
  /p:EnforceProcessCountAcrossBuilds=true /nr:false
```

| Option | Exact meaning / constraint |
|---|---|
| `--parallel N` | CMake passes MSBuild `/m:N`: project/node parallelism. Alone, it does not repair the single-project metadata batches. |
| `MultiProcCL=true` | Compiler-only MultiToolTask, not blanket `UseMultiToolTask=true`. |
| `MultiProcMaxCount=N` + `EnforceProcessCountAcrossBuilds=true` | Shared **compiler-process** budget across MSBuild workers, not N per project or N total threads. Linkers/helpers/backend threads are additional. |
| `/nr:false` | No reusable worker nodes surviving the measured invocation; supports clean CPU attribution. |
| Benchmark defaults | `MSBuildScheduler=Default`, `Parallel=0` (**omit argument**), `CompilerJobs=12` (**unused by default**), shared limit off. Explicit `CompilerJobs` with Default is rejected. |
| Compatibility | Scheduler requires MSBuild; shared limit requires MultiToolTask. Proven on VS 2022/MSVC 19.44 native ARM64. Other hosts/toolsets need validation; the VS 2026 experiment did not validate this scheduler combination. Ninja/Clang must not receive MSBuild properties. |

The benchmark applies scheduler properties to clean/install too, but project
parallelism only to the timed build. A separate diagnostic verified **one
513-source world MultiToolTask**, **1,015 unchanged Release source/project
command records**, and **peak 12 compilers across all workers**.
[Shared-cap trace evidence](../results/msbuild-shared-20261015/comparison.json).
Changing scheduling preserves work, not process structure or aggregate CPU.

### Proposed upstream HOBL patch — not applied

Paths below were checked against HOBL
[`05896ef511054a705d2216ffe8cf67f66cea3fe0`](https://github.com/microsoft/HOBL/tree/05896ef511054a705d2216ffe8cf67f66cea3fe0).
This is a concrete delivery proposal, **not an existing upstream interface**.
Keep both original and candidate labels in the lab.

**1. Edit**
[`scenarios\windows\opencv_build\opencv_build_resources\opencv_build_run.ps1`](https://github.com/microsoft/HOBL/blob/05896ef511054a705d2216ffe8cf67f66cea3fe0/scenarios/windows/opencv_build/opencv_build_resources/opencv_build_run.ps1).
Add opt-in parameters; build argument arrays before the untimed clean.
Preserve the existing `Measure-Command`, phase markers, redirects, exit checks
and `scenario_runtime = build_time` calculation:

```diff
 param(
     [string]$logFile = "",
-    [string]$startTime = (Get-Date).ToString("o")
+    [string]$startTime = (Get-Date).ToString("o"),
+    [ValidateSet('Default', 'Shared')][string]$MSBuildScheduler = 'Default',
+    [ValidateRange(1, 256)][int]$Jobs = 12
 )
```

```powershell
# Proposed setup before clean; outside Measure-Command.
$schedulerArgs = @()
$projectArgs = @()
if ($MSBuildScheduler -eq 'Shared') {
    $schedulerArgs = @('--', '/p:MultiProcCL=true',
        "/p:MultiProcMaxCount=$Jobs",
        '/p:EnforceProcessCountAcrossBuilds=true', '/nr:false')
    $projectArgs = @('--parallel', "$Jobs")
}
```

```diff
-cmake --build . --target clean --config Release *> $cleanLog
+cmake --build . --target clean --config Release @schedulerArgs *> $cleanLog
 ...
 $buildDuration = Measure-Command {
-    cmake --build . --config Release *> $buildLog
+    cmake --build . --config Release @projectArgs @schedulerArgs *> $buildLog
 }
 ...
-cmake --build . --target INSTALL --config Release *> $installLog
+cmake --build . --target INSTALL --config Release @schedulerArgs *> $installLog
```

With `Default`, both arrays are empty: the original commands remain.
The proposed `Jobs=12` default only applies when Shared is selected; explicitly
use **`-MSBuildScheduler Shared -Jobs 20` on Minos**. This small upstream
interface deliberately sets project and compiler limits together; the benchmark
retains independent knobs. Log selected mode/budget and resolved tools outside
the timer; fail if the configured generator/toolset is unsupported. Do not set
global parallelism variables or edit generated `.vcxproj` files.

**2. Wire**
[`scenarios\windows\opencv_build\opencv_build.py`](https://github.com/microsoft/HOBL/blob/05896ef511054a705d2216ffe8cf67f66cea3fe0/scenarios/windows/opencv_build/opencv_build.py).
Add `Params.setDefault(module, 'msbuild_scheduler', 'Default')` and
`Params.setDefault(module, 'jobs', '12')`; read them in `setUp`, allow only
`Default`/`Shared`, convert jobs to integer and reject values outside 1–256.
Append `-MSBuildScheduler {self.msbuild_scheduler} -Jobs {self.jobs}` to the
existing `runTest` `_call` script argument. Keep `-startTime`, loop count and
3,600-second timeout unchanged. Lab candidate configuration sets
`msbuild_scheduler=Shared`, `jobs=20`; rollback selects `Default`.

**Deployment trap:** the pinned `setUp` uploads resources **only inside the
cached-prep conditional** (`prep_version="7"`). Updating the host checkout alone
may leave the old run script on prepared DUTs. For this run-only change, move
the existing `_upload(...)` call immediately before that conditional, after
`self.target` is assigned, so resources refresh without forcing toolchain
reinstallation. Verify the deployed run-script hash. If delivery instead
requires re-prep, explicitly version/invalidate that preparation and document
the rollout cost; do not silently assume resources were refreshed.

**3. No scheduler-related edit is needed in**
[`scenarios\windows\opencv_build\opencv_build_resources\opencv_build_prep.ps1`](https://github.com/microsoft/HOBL/blob/05896ef511054a705d2216ffe8cf67f66cea3fe0/scenarios/windows/opencv_build/opencv_build_resources/opencv_build_prep.ps1).
Keep `-G "Visual Studio 17 2022"`, the existing build tree and all 23 definitions.
Update the scenario's
[`README.md`](https://github.com/microsoft/HOBL/blob/05896ef511054a705d2216ffe8cf67f66cea3fe0/scenarios/windows/opencv_build/README.md)
with the opt-in/default distinction, budget and rollback. Provision/verify
native compiler, SDK and compatible CMake separately; discover installations,
do not copy a private machine's absolute paths.

**Acceptance before upstream/product delivery:** review the PR; verify default
command parity and unchanged source/features/flags; repeat balanced clean
builds on target hardware; separately trace task structure/shared cap; validate
install/version, incremental rebuild/install behavior, runtime checks and
rollback. No such upstream PR, merge or rollout is claimed by this report.

## MSVC investigations and existing bug follow-ups

### What was tested

The [full compiler report](COMPILER_GAP_INVESTIGATION.md) and
[public audit](../results/compiler-gap-20261015/audit/workload.json) establish
native ARM64 `cl.exe`, loaded `c1xx.dll`/`c2.dll`, and Clang with PE/live-process
checks. **1,015 C/C++ units have matching source bytes**, feature headers match,
release iterator/hardening settings match, and executed commands have no
explicit debug-info/LTO flags. LLVM alone adds libpng `arm/filter_neon.S`.
These checks exclude emulation and missing modules, **not semantic differences**.

Eight actual Ninja source commands were replayed separately, with only output
paths redirected: one warm-up and **four uninstrumented measurements per
source/compiler**, alternating order. All numbers below are medians in seconds.

| Source (under `modules`) | MSVC wall / CPU | LLVM wall / CPU |
|---|---:|---:|
| `calib3d/src/dls.cpp` | 4.233 / 5.984 | 1.894 / 1.875 |
| `dnn/src/onnx/onnx_importer.cpp` | 3.003 / 8.906 | 3.211 / 3.180 |
| `dnn/src/net_impl.cpp` | 2.591 / 6.656 | 2.400 / 2.383 |
| `dnn/src/tensorflow/tf_importer.cpp` | 2.539 / 7.125 | 2.904 / 2.891 |
| `core/src/arithm.cpp` | 0.798 / 1.609 | 0.913 / 0.891 |
| `imgproc/src/resize.cpp` | 1.335 / 4.250 | 2.134 / 2.125 |
| `features2d/src/orb.cpp` | 1.295 / 2.328 | 1.076 / 1.055 |
| `core/src/alloc.cpp` | 0.851 / 1.367 | 0.842 / 0.828 |

[Isolated data](../results/compiler-gap-20261015/isolated/summary.json).
MSVC can win isolated wall time while spending much more CPU. Earlier WPR
found seven materially CPU-consuming MSVC threads over focused compiler
lifetimes versus one for LLVM—not seven continuously active cores.

A **24-command / 12-worker compiler-only batch** (three copies of each source;
no links, installs or MSBuild) reproduced the throughput gap. One excluded
warm-up and four measurements per variant:

| Variant | Wall s | CPU s | What it tests |
|---|---:|---:|---|
| MSVC original | 17.625 | 168.523 | Reference |
| MSVC `/cgthreads1` | 17.095 | 157.914 | 3.01% less wall / 6.30% less CPU, mixed paired winners; no justified full-build default |
| LLVM original | 7.520 | 63.227 | 57.33% less wall in this **selected**, hotspot-weighted batch |
| LLVM `-fasync-exceptions` | 7.965 | 71.086 | Still 54.81% less wall than original MSVC; exception differences do not explain away the gap |

[Batch data](../results/compiler-gap-20261015/batch/summary.json).
Equal compiler-process budgets do not equalize internal compiler-thread work.

Separate `/Bt+` / `-ftime-trace` pilots (one warm-up, two observations per
variant) found:

- Removing optimization (`/Od /Ob0` versus `-O0`) reduced DLS CPU from
  **5.414 / 1.805 s** (MSVC/LLVM) to **0.719 / 0.633 s**; ONNX from
  **8.898 / 3.117 s** to **1.570 / 1.141 s**.
- LLVM `-O2`, `-fno-strict-aliasing` and asynchronous-exception controls did not
  remove the advantage. Replacing MSVC `/EHa` with `/EHsc` did not consistently
  reduce CPU and changes behavior; altered objects were not installed.
- Earlier WPR puts **61–63% of MSVC compiler leaf-module samples in `c2.dll`**,
  including SSA/IR/data-structure helpers. About **99% of build-tree CPU**
  belonged to compiler processes; low physical-disk busy time did not support
  disk saturation as the dominant bottleneck. Linking/PCH speculation cannot
  explain the controlled header-free backend examples.

[Flag pilot](../results/compiler-gap-20261015/flag_pilot/summary.json) /
[WPR analysis and sanitized evidence links](CPU_ETL_ANALYSIS.md).
Phase elapsed times, sampled CPU and overlapping Ninja durations are different
metrics; inclusive samples/nested Clang phases must not be summed.

### Existing DLS issue: 64678278

[Compiler-performance follow-up 64678278](https://microsoft.visualstudio.com/OS/_workitems/edit/64678278)
targets
[`cv::dls::cayley_LS_M`](https://github.com/opencv/opencv/blob/71d3237a093b60a27601c20e9ee6c3e52154e8b1/modules/calib3d/src/dls.cpp#L410):
a 120×120 matrix with **1,968 explicit assignments** using inline `Mat::at`
and vector accessors. `/d2cgsummary` identified a **3.059 s** function outlier;
WPR identified `SSAHelpers::FindInstructionBlock`. Neither identifies a
responsible optimization pass conclusively.

A **local-copy** rewrite cached matrix pointer/stride and four vector pointers,
preserving assignment order. Balanced original/cached/cached/original blocks,
four phase-instrumented observations per compiler/source, measured:

| DLS translation unit | Original | Cached | Conclusion |
|---|---:|---:|---|
| MSVC wall s | 3.877 | 2.597 | **33.01% less TU compilation time**, not full-build/runtime gain |
| MSVC CPU s | 5.523 | 4.094 | 25.88% less CPU |
| MSVC backend elapsed s | 3.292 | 2.025 | Improvement localized mainly to backend; frontend did not improve |
| LLVM wall s | 2.234 | 2.043 | Smaller source-shape effect |

[DLS comparison data](../results/compiler-gap-20261015/dls_abba/summary.json).
MSVC's isolated function COFF section shrank **48,420 → 17,316 bytes**; LLVM
**56,568 → 17,168 bytes**. These are code-section bytes, not retired
instructions. Undocumented `/d2cgsummary`'s `instrs` field is **not verified
IR instruction count**. Complete matrices matched for **16 input sets**;
full DLS/OpenCV correctness and runtime speed remain unqualified.

**Next investigation/fix:** reproduce both source shapes on the pinned and
current compiler separately; obtain compiler-owner pass-level profiles around
accessor inlining, alias/SSA analysis and instruction/block lookup; reduce
while retaining the measured cost. Evaluate compiler-side caching/data-structure
or scaling fixes only after locating the cause. Treat pointer caching as an
OpenCV source candidate requiring broader numerical/runtime validation, not
an already shipped compiler or OpenCV fix.

### Existing standalone scaling issue: 64678280

[Compiler-performance follow-up 64678280](https://microsoft.visualstudio.com/OS/_workitems/edit/64678280)
removes OpenCV/STL/SDK headers entirely. Same-byte generated functions compare
inline accessors, cached pointers and table loops at **512 / 2,048 / 4,096
stores**, one warm-up plus four observations each.

Uninstrumented cached-pointer wall times grow **0.186 → 1.564 → 5.925 s**
for MSVC, versus **0.315 → 0.816 → 1.907 s** for LLVM. A separate
phase-instrumented cached-4,096 control gives:

| Compiler / level | Wall s | Frontend elapsed s | Backend elapsed s |
|---|---:|---:|---:|
| MSVC `/O2` | 6.883 | 0.057 | 6.777 |
| LLVM `-O2` | 2.214 | 0.027 | 2.112 |
| LLVM `-O3` | 2.406 | 0.027 | 2.305 |

[Nominal-O2 data](../results/compiler-gap-20261015/synthetic_o2/summary.json) /
[all source shapes](../results/compiler-gap-20261015/synthetic).
The **3.11× nominal-O2 difference is backend-dominated**, but O2 does not mean
identical pipelines. Counterexamples matter: MSVC wins cached-512 and
inline-accessor-4,096 (**2.746 versus 5.011 s**). Table-4,096 compiles in
**0.095 versus 0.070 s**; it is not proven faster at runtime. All nine cases,
both compilers and LLVM's no-strict-aliasing control matched four reference
input sets, including row padding.

**Next investigation/fix:** bisect function size and retained source structure,
collect compiler-owner pass/algorithm scaling data, and build a compile-time
regression test retaining both favorable and unfavorable cases. Few sizes do
not prove asymptotic complexity or a specific heuristic threshold. A loop
rewrite is a diagnostic alternative, not an unconditional production fix.

### Existing DNN CPU-amplification issue: 64678283

[Compiler-performance follow-up 64678283](https://microsoft.visualstudio.com/OS/_workitems/edit/64678283)
covers ONNX/TensorFlow importers and `net_impl.cpp`, not a single DLS-like
outlier. ONNX's diagnostic reports **4,289 functions**, with smaller outliers
such as `parseQEltwise` and dispatch-map construction. The isolated table
above demonstrates the distinction: **3.003 versus 3.211 s wall**, but
**8.906 versus 3.180 CPU s** for ONNX. The eight-source CPU-median sum is
**38.227 versus 15.227 s**, while wall-median sums are **16.644 versus 15.374 s**.
These are selected-source sums, not full-build totals.

**Next investigation/fix:** use actual importer TUs plus reduced string/
container-heavy functions, profile aggregate CPU as well as elapsed time,
and identify distributed backend costs. Sweep compiler-process limits and
backend-thread settings together on supported hardware; `/cgthreads1`'s small
batch benefit does not establish a full-build fix. Compare latest MSVC with
the same Ninja workload rather than interpreting the mixed VS 2026 stack
comparison as a compiler-only verdict. Require clean-build, output and
generated-code-runtime validation before adopting any option or compiler fix.

### Reproduction references for compiler owners

These are **existing tools, not new benchmarks run for this report**. Preserve
the pinned compiler/SDK and configured MSVC/Clang Ninja trees; use fresh output
directories. Exact commands, including array-valued variants and
`-SourceOverride`, are in the
[reproduction section](COMPILER_GAP_INVESTIGATION.md#reproduction-and-evidence).

| Reproducer | Source / execution / evidence |
|---|---|
| Real OpenCV TUs and flag controls | [`run_compiler_microbench.ps1`](../scripts/run_compiler_microbench.ps1), [`compiler_commands.ps1`](../scripts/compiler_commands.ps1); [isolated](../results/compiler-gap-20261015/isolated), [flag pilot](../results/compiler-gap-20261015/flag_pilot) |
| Saturated compiler-only throughput | [`run_compiler_batch.ps1`](../scripts/run_compiler_batch.ps1); [batch measurements/manifest](../results/compiler-gap-20261015/batch) |
| Local DLS rewrite and header-free generator | [`prepare_compiler_patterns.py`](../scripts/prepare_compiler_patterns.py) generates `dls_cached.cpp`, `validate_dls.cpp`, and nine `view_*` / `cached_*` / `table_*` probes without modifying OpenCV |
| Balanced DLS source comparison | [`run_dls_access_study.ps1`](../scripts/run_dls_access_study.ps1); [DLS study](../results/compiler-gap-20261015/dls_abba) |
| Synthetic correctness | [`compiler_patterns_check.cpp`](../tests/compiler_patterns_check.cpp); [validation evidence](../results/compiler-gap-20261015/audit) |
| Native/process/phase evidence | [`audit_compiler_architecture.ps1`](../scripts/audit_compiler_architecture.ps1), [`profile_translation_units.ps1`](../scripts/profile_translation_units.ps1); [compiler audit](../results/compiler-gap-20261015/audit), [WPR report](CPU_ETL_ANALYSIS.md) |

The three linked ADO items are **existing investigation/bug follow-ups**, not
confirmed optimizer defects or delivered fixes. No new Minos/custom-LLVM bugs
were created for this report, and no current ADO state transition is implied.

## Delivery and next actions

Parent: [63731940](https://microsoft.visualstudio.com/OS/_workitems/edit/63731940).
The earlier recorded work identifies
[64678272](https://microsoft.visualstudio.com/OS/_workitems/edit/64678272) as
completed build/compiler investigation and
[64680944](https://microsoft.visualstudio.com/OS/_workitems/edit/64680944) as
completed Surface runtime screening—not completion of production qualification.
ADO links may require organizational access; the supporting reports/data here
are public. This report does not query or update their live status.

| Priority | Existing work item | Required next outcome |
|---|---|---|
| 1 | [64678273 — shared-cap delivery](https://microsoft.visualstudio.com/OS/_workitems/edit/64678273) | Implement/review the explicit HOBL option above; verify deployment on prepared DUTs, commands/concurrency, runtime gates and rollback. |
| 1 | [64678276 — runtime/correctness](https://microsoft.visualstudio.com/OS/_workitems/edit/64678276) | Isolate the preserved Minos descriptor failures across baseline/shared/LLVM without loosening tolerances or assuming compiler causation. |
| 1 | [64678278 — DLS](https://microsoft.visualstudio.com/OS/_workitems/edit/64678278), [64678280 — straight-line scaling](https://microsoft.visualstudio.com/OS/_workitems/edit/64678280), [64678283 — DNN CPU](https://microsoft.visualstudio.com/OS/_workitems/edit/64678283) | Route the public real-source/isolated reproducers to compiler owners; identify causes, test candidate fixes and guard regressions. |
| 2 | [64680945 — depthwise](https://microsoft.visualstudio.com/OS/_workitems/edit/64680945), [64680947 — float resize](https://microsoft.visualstudio.com/OS/_workitems/edit/64680947) | Profile nearby shapes and CPU classes; add explicit output checks and inspect selected kernels/assembly before assigning optimizer blame. |
| 2 | [64680949 — real-model/accuracy](https://microsoft.visualstudio.com/OS/_workitems/edit/64680949) | Independent numerical checks plus representative models, import/startup and steady-state runtime, including the custom LLVM binaries before adoption. |
| 2 | [64678274 — Ninja evaluation](https://microsoft.visualstudio.com/OS/_workitems/edit/64678274), [64678275 — Clang/clang-cl exploration](https://microsoft.visualstudio.com/OS/_workitems/edit/64678275) | Validate incremental benefit against tuned MSBuild; keep driver-specific profiles and semantic differences explicit. Add matched LLVM 24 non-PGO/LTO control for attribution. |
| Delivery gate | [64678277 — PR/integration/rollout](https://microsoft.visualstudio.com/OS/_workitems/edit/64678277) | Reviewed PRs, approved merge, consuming-pipeline rollout, lab validation and rollback—not merely publication of this experiment repository. |

No new benchmark, benchmark-code change, presentation change, ADO creation or
ADO update was performed to produce this consolidation.
