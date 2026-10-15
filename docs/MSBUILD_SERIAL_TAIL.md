# MSBuild's serial compilation tail: what blocks it, and what is recoverable?

**Next experiment:** [project parallelism with a shared compiler limit](MSBUILD_SHARED_PARALLELISM.md)
measured **180.94 s**, versus fresh controls of **205.36 s** for compiler-only
MultiToolTask and **176.75 s** for MSVC/Ninja. This is a separate series, not
an update to the measurements below.

Investigated on **15 October 2026**, using the original VS 2022/MSVC ARM64
configuration. **The tail is real, but it is not 45 seconds of removable idle
time.** It contains serial compiler execution plus repeatedly rebuilding
MSBuild dependency-tracking tables. An opt-in scheduler removes the serial task
structure, but its measured whole-build improvement is **13.15 seconds / 6.52%**,
not 45 seconds.

Even eliminating all 45 seconds from the previous 210.8-second baseline would
leave approximately **166 seconds**, versus LLVM's **94.9 seconds** in that
earlier comparison. Much of the compiler CPU gap would remain.

## The exact 44.79-second sequence

A fresh baseline captured **both WPR and an MSBuild binary log**, providing actual
task boundaries, full source metadata, compiler-command events and process
lifetimes on the same clock. It reproduces the previous approximately 45-second
region:

| Part of the 34 single-file CL tasks | Wall time |
|---|---:|
| Task entry to compiler process start | **7.554 s** |
| Compiler process lifetimes, with no overlap | **31.199 s** |
| Compiler exit to task completion | **6.038 s** |
| Gaps between successive MSBuild tasks | **0.002 s** |
| Total | **44.793 s** |

These intervals are mutually exclusive. The first and last include task
bookkeeping, tracking and launch/cleanup; they are not all pure process-startup
cost. The 31.199 seconds is compiler **elapsed time**, not CPU time.

Within the same interval, ETL records **72.929 CPU seconds in `cl.exe`** and
**12.566 CPU seconds in MSBuild**. The compiler uses internal parallelism while
MSBuild synchronously waits for each invocation. Then MSBuild does real CPU
work before/after launching the next file. Average build CPU use is only about
**1.93 of 12 cores** across this region.

There is no evidence here of one 45-second deadlock, a single slow link, or a
required source dependency chain. The bottleneck is the **serialized CL task
pipeline**, with repeated bookkeeping and no overlap between these files.

## Why precisely these files?

The generated world-library project has **513 C++ sources**:

- **479** share the same per-file compiler settings and form one `/MP` batch.
- **32** have distinct `ObjectFileName` metadata, needed to avoid collisions
  between filenames such as `parallel.cpp`, `tables.cpp`, `main.cpp`, `utils.cpp`,
  and DNN layer filenames in different directories.
- **Two more** have distinct preprocessor definitions: `core/src/alloc.cpp`
  (allocator feature macros) and `videoio/src/backend_plugin.cpp`
  (`DEBUG_POSTFIX`).

The binary log confirms **35 sequential CL tasks: one with 479 sources, then
34 with one source each**. This is now direct task evidence, not just an inference
from build-log order.

The installed `Microsoft.CppCommon.targets`, lines 787 onward, passes metadata
such as `%(ClCompile.ObjectFileName)` and
`%(ClCompile.PreprocessorDefinitions)` as CL task parameters. MSBuild's
metadata batching therefore separates the exceptional files. `/MP` is still
enabled, but cannot parallelize multiple source files within a task that receives
only **one** source.

**Do not remove those object-name overrides:** repeated names would collide.
Nor is increasing project-level `/m` alone a direct solution to batches within
this single project.

## What MSBuild is doing between compiler invocations

Resolved sampled CPU stacks from the **original unmodified full-build ETL** show:

| Inclusive function in MSBuild's tail CPU stacks | Share of MSBuild CPU samples |
|---|---:|
| `CanonicalTrackedInputFiles.ConstructDependencyTable()` | **59.28%** |
| `CanonicalTrackedInputFiles.SaveTlog(...)` | **13.01%** |
| `System.IO.StreamReader.ReadLine()` | 24.31% |
| `FileTracker.FileIsExcludedFromDependencies(...)` | 10.74% |
| `CanonicalTrackedOutputFiles.ConstructOutputTable()` | 1.45% |

**These percentages overlap**: `ReadLine`, for example, executes underneath
dependency-table construction. Do not add them together. They describe MSBuild's
CPU samples, not percentages of the entire build or wall time.

The original trace has **12.502 seconds of MSBuild CPU** during its 45.374-second
compiler-tail interval. The fresh trace independently measures 12.566 seconds
over its task-bounded tail. Thus the roughly 13.6 seconds outside compiler
lifetimes is mostly consistent with active tracking/bookkeeping, not unexplained
scheduler inactivity.

After the restored baseline, the world project's `CL.read.1.tlog` is
**18,245,772 bytes / 103,966 lines**, representing dependencies across all 513
sources. Repeated construction of dependency tables and saving tracking logs is
expensive even with warm filesystem caches. This is a CPU/parsing/tracking issue;
the previous low physical disk utilization does not contradict it.

These stacks do not establish the exact number of full log scans or that every
millisecond before/after compilation is tracking. They do establish the dominant
MSBuild routines on the critical serial path. Disabling tracking is not the
recommended fix: it can break incremental-build/install behavior, and an earlier
`TrackFileAccess=false` experiment caused substantial rebuilding during installation.

## What actually runs: all 34 serialized files

Times below are from the new task/WPR-correlated baseline. Paths are relative to
OpenCV's `modules` directory. "Other" is task time outside the compiler process.

| Source | CL task (s) | Compiler elapsed (s) | Other (s) |
|---|---:|---:|---:|
| `core/src/alloc.cpp` | 1.094 | 0.677 | 0.417 |
| `core/src/parallel.cpp` | 1.339 | 0.913 | 0.426 |
| `core/src/parallel/parallel.cpp` | 1.541 | 1.146 | 0.395 |
| `core/src/tables.cpp` | 1.015 | 0.600 | 0.415 |
| `imgproc/src/main.cpp` | 0.936 | 0.549 | 0.387 |
| `imgproc/src/tables.cpp` | 0.920 | 0.554 | 0.366 |
| `imgproc/src/utils.cpp` | 0.980 | 0.562 | 0.418 |
| `dnn/src/backend.cpp` | 1.635 | 1.266 | 0.369 |
| `dnn/src/int8layers/batch_norm_layer.cpp` | 1.331 | 0.923 | 0.408 |
| `dnn/src/int8layers/convolution_layer.cpp` | 1.618 | 1.231 | 0.387 |
| `dnn/src/int8layers/elementwise_layers.cpp` | 1.320 | 0.903 | 0.417 |
| `dnn/src/int8layers/eltwise_layer.cpp` | 1.351 | 1.002 | 0.349 |
| `dnn/src/int8layers/fully_connected_layer.cpp` | 1.360 | 0.953 | 0.407 |
| `dnn/src/int8layers/pooling_layer.cpp` | 1.445 | 1.056 | 0.389 |
| `dnn/src/int8layers/scale_layer.cpp` | 1.395 | 0.985 | 0.410 |
| `dnn/src/int8layers/softmax_layer.cpp` | 1.339 | 0.936 | 0.403 |
| `dnn/src/layers/batch_norm_layer.cpp` | 1.312 | 0.943 | 0.369 |
| `dnn/src/layers/convolution_layer.cpp` | 1.504 | 1.072 | 0.432 |
| `dnn/src/layers/elementwise_layers.cpp` | 1.981 | 1.567 | 0.414 |
| `dnn/src/layers/eltwise_layer.cpp` | 1.470 | 1.060 | 0.410 |
| `dnn/src/layers/fully_connected_layer.cpp` | 1.407 | 1.015 | 0.392 |
| `dnn/src/layers/pooling_layer.cpp` | 1.550 | 1.146 | 0.404 |
| `dnn/src/layers/scale_layer.cpp` | 1.423 | 1.021 | 0.402 |
| `dnn/src/layers/softmax_layer.cpp` | 1.346 | 0.931 | 0.415 |
| `features2d/src/main.cpp` | 1.013 | 0.592 | 0.421 |
| `features2d/src/matchers.cpp` | 1.168 | 0.778 | 0.390 |
| `imgcodecs/src/utils.cpp` | 1.123 | 0.721 | 0.402 |
| `videoio/src/backend_plugin.cpp` | 1.437 | 1.021 | 0.416 |
| `calib3d/src/main.cpp` | 0.981 | 0.605 | 0.376 |
| `calib3d/src/usac/utils.cpp` | 1.311 | 0.907 | 0.404 |
| `highgui/src/backend.cpp` | 1.466 | 1.055 | 0.411 |
| `objdetect/src/barcode_decoder/common/utils.cpp` | 1.043 | 0.612 | 0.431 |
| `objdetect/src/main.cpp` | 0.951 | 0.599 | 0.352 |
| `stitching/src/matchers.cpp` | 1.688 | 1.298 | 0.390 |

DNN contributes **17 of the files / 24.787 seconds of task time**. No single file
dominates: the longest task is only 1.981 seconds. It is the sum of many serialized
tasks, each paying approximately **0.4 seconds outside its compiler process**.

## Tested remedy: compiler-only MultiToolTask

The installed `Microsoft.Cpp.Common.props`, lines 197-214, describes
`MultiToolTask` as bypassing MSBuild batching so tools with different command
lines can execute in parallel. `Microsoft.CppCommon.targets`, lines 617-640,
provides its compiler path.

The experiment passes only:

```text
/p:MultiProcCL=true /p:MultiProcMaxCount=12
```

This enables it for **C/C++ compilation only**, rather than using
`UseMultiToolTask=true` to change additional tool types. There is no project-level
`/m` override. Dependency tracking remains enabled, and no source, generated
project, optimization level, SDK or compiler is changed.

**The diagnosis is confirmed:** the new binary log has **one MultiToolTask with
all 513 world-library sources**, instead of 35 serial CL tasks. The standalone
34-task tail is gone.

However, in the two diagnostic captures:

| Metric | Default | MultiToolTask |
|---|---:|---:|
| Whole build wall time | 200.198 s | 187.205 s |
| World-library compiler tasks, start to finish | 164.034 s | 145.397 s |
| `cl.exe` process instances across the build | 211 | 1,015 |
| `tracker.exe` instances | 78 | 1,037 |
| `conhost.exe` instances | 105 | 1,064 |
| ETL CPU in `tracker.exe` + `conhost.exe` | 1.932 s | 26.620 s |

The efficient bulk `/MP` invocation is also replaced with individual compiler
launches. The new 145.4-second world compilation phase is substantially longer
than the original **119.2-second bulk phase alone**, though shorter than the old
bulk-plus-tail total. Other project work and orchestration remain.

Therefore **removing the tail's shape is not equivalent to removing its work**.
The measured world phase saves 18.64 seconds; the diagnostic whole build saves
12.99 seconds. The remaining difference is outside that world compilation phase.

## Balanced whole-build measurements

The diagnostic captures above are excluded from this table. Four additional
clean builds ran in **Default / MultiToolTask / MultiToolTask / Default** order,
with no WPR or binary logger, but the same process-tree CPU accounting:

| Order | Configuration | Wall (s) | CPU (s) |
|---|---|---:|---:|
| 1 | Default | 199.898 | 1,563.531 |
| 2 | MultiToolTask, 12 compiler jobs | 190.812 | 1,710.141 |
| 3 | MultiToolTask, 12 compiler jobs | 185.939 | 1,706.719 |
| 4 | Default | 203.145 | 1,622.469 |
| Median | **Default** | **201.522** | **1,593.000** |
| Median | **MultiToolTask** | **188.375** | **1,708.430** |

The candidate saves **13.146 seconds / 6.52% wall time**, while using **7.25% more
CPU**. The two adjacent comparisons save 9.086 and 17.206 seconds. Kernel CPU
increases from **73.844 to 153.234 seconds median**, consistent with the much
larger process-launch/tracking workload, although not an exclusive attribution
of all additional kernel CPU to startup.

All **1,015 Release source+project compiler command records in the tracking logs
are identical** between diagnostic configurations. Two CMake compiler-identification
probe records are excluded. These are tracked compilation options, not a claim
that scheduler wrappers or `/MP` invocation structure are identical. Generated
project hashes remained unchanged.

Every run completed installation and version validation; installation remained
approximately 2-4 seconds rather than performing another full build. The final
run restored the default scheduler, and the restored library passed the native
image/matrix smoke check.

Only two untraced observations per condition were collected. At least 30 seconds
of rest preceded each build; recorded gaps between completed iterations and the
next iteration start were **31.85, 58.52 and 31.81 seconds**. The longer midpoint
gap was between the two execution batches. Background activity and thermals were
not controlled. These numbers should not be pooled with the earlier 210.8-second
baseline or interpreted as a precise universal 6.52% improvement.

## Recommendation

Keep the HOBL-equivalent default unchanged. The opt-in MultiToolTask setting is a
measured, modest MSBuild improvement, **not** a way to approach LLVM's current
build time.

The more targeted next optimization would preserve efficient bulk compilation
while allowing exceptional per-file settings to be scheduled concurrently,
and avoid reconstructing the same dependency tables for each exception.
That requires a deliberate CMake/MSBuild scheduling or task-level change;
its benefit has **not** been measured here. Do not discard unique object paths
or disable tracking to make the chart look faster.

For the larger gap, the earlier [CPU investigation](CPU_ETL_ANALYSIS.md) still
applies: LLVM uses roughly half the CPU work in the matched Ninja comparison.
Serial-tail scheduling cannot remove that optimizer/code-generation difference.

## Reproduce or switch back

```powershell
# Original MSVC/MSBuild tree must already be configured.
pwsh -NoProfile -File scripts\run.ps1 -MeasureCpu -Label default_1
pwsh -NoProfile -File scripts\run.ps1 -MeasureCpu `
    -MSBuildScheduler MultiToolTask -CompilerJobs 12 -Label multitool_1

# Omit the option to return to unchanged default scheduling.
pwsh -NoProfile -File scripts\run.ps1 -MeasureCpu -Label default_restored

# Separate diagnostic capture; elevated shell, WPR/WPT required.
pwsh -NoProfile -File scripts\run.ps1 -Trace -BinaryLog `
    -MSBuildScheduler MultiToolTask -CompilerJobs 12 -Label multitool_diagnostic
```

Scheduler properties are applied consistently to clean, build and install.
`-CompilerJobs` controls this compiler scheduler, not project-level
`-Parallel`. Specifying it with the default scheduler is rejected.
`-BinaryLog` and `-MSBuildScheduler` are rejected for Ninja.

**Raw binlogs also remain local**, like ETLs: they can contain environment values,
paths and command lines even when project imports are disabled. The public
exporter uses an allowlist and refuses to pool binary-logged and unlogged runs.

To extract local MSBuild events, use Windows PowerShell with the installed
.NET Framework MSBuild assemblies:

```powershell
# Set $dir to the absolute path of one diagnostic run.
$msbuild = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin'
& "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile `
    -File scripts\extract_msbuild_binlog.ps1 -BinLog "$dir\build.binlog" `
    -Output "$dir\msbuild-events.jsonl" -MSBuildDirectory $msbuild

xperf -i "$dir\build.etl" -a process -withcmdline -ao "$dir\processes.csv" `
    -a tracestats -ao "$dir\trace-stats.txt"
python scripts\analyze_msbuild_tail.py $dir results\fresh-tail-analysis.json
```

The analyzer converts MSBuild UTC-offset timestamps to the ETL clock, verifies
compiler lifetimes fall within task boundaries, and exports source-relative
names and timings. Optional `cpu-precise.csv`/`cpu-tail.csv` exports add CPU totals.
The MultiToolTask trace reused three `conhost.exe` PIDs across build/nonbuild
ownership: aggregate CPU rows were rejected and replaced by precise exports
for each owned process lifetime. Missing lifetime-specific exports fail rather
than attributing other applications' CPU to the build.

For tracking CPU stacks, use locally resolved symbols and:

```powershell
# Values below identify the original MSBuild recording, not a new run.
xperf -i "$originalDir\build.etl" -symbols -a stack -pid 30816 `
    -event Profile -range 157189115 202563136 -butterfly 30 `
    -ao "$originalDir\msbuild-tail-profile-stacks.html"
```

`-event Profile` is important: mixing context-switch/wait stacks with CPU samples
would give misleading CPU percentages. The original recording supplies the
reported tracking stack shares; the new WPR/binlog pair supplies the task-time
breakdown. A concurrent offline export briefly overlapped the start of the
diagnostic baseline only; no such analysis ran alongside the four primary
measurements.

Public evidence: [matched and diagnostic run exports](../results/msbuild-tail-20261015)
and [per-file timings, tracking stacks, workload checks and ETL/binlog hashes](../results/msbuild-tail-20261015/tail-summary.json).
Both new ETLs have zero lost events/buffers. Raw recordings and binlog event dumps
remain under `results\local\msbuild-tail-diagnostic`.
