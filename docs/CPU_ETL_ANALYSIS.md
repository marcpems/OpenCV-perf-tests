# LLVM versus original MSVC: wall time, CPU work and WPR evidence

Measured on **15 October 2026**, on the same native ARM64, 12-core Snapdragon X2
Elite machine. **LLVM is faster primarily because it performs much less CPU work,
not because it uses more cores.** The original MSBuild configuration also has a
large, independently observable serialization problem.

## Build-only measurements

Two clean builds per configuration, in **MSBuild / MSVC-Ninja / Clang-Ninja /
Clang-Ninja / MSVC-Ninja / MSBuild** order, with 30-second rests. These are new
matched measurements; do not pool them with earlier studies.

| Configuration | Wall samples (s) | Median wall (s) | Median CPU (core-seconds) | Median user / kernel CPU (s) | Mean occupied cores |
|---|---|---:|---:|---:|---:|
| Original VS 2022 MSVC + MSBuild | 210.110, 211.497 | **210.804** | **1,716.117** | 1,644.750 / 71.367 | 8.14 |
| Same MSVC + Ninja, 12 jobs | 169.799, 174.322 | **172.061** | **1,819.570** | 1,678.000 / 141.570 | 10.58 |
| LLVM + Ninja, 12 jobs | 95.878, 93.919 | **94.898** | **893.898** | 790.773 / 103.125 | 9.42 |

CPU time is the sum of scheduled user and kernel time across the build process
tree, including exited descendants. One second on each of 12 cores is 12 CPU
seconds. Occupied cores = CPU seconds / wall seconds; the table averages the two
observations. This is **not** Ninja command elapsed time, power consumption, or
OpenCV algorithm performance.

- Original MSBuild to LLVM: **54.98% less wall time and 47.91% less CPU time**.
- Holding Ninja and its 12-job limit constant: LLVM takes **44.85% less wall time
  and 50.87% less CPU time** than MSVC.
- MSBuild to Ninja with the same MSVC: **18.38% less wall time despite 6.03% more
  CPU time**. Scheduling improves elapsed time, rather than reducing the work.

The matched Ninja user-CPU reduction is particularly clear: **1,678.0 to 790.8 s**.
MSVC-Ninja's increased kernel time relative to MSBuild accompanies many more
process launches (1,097 versus 507 in the traced runs). That is consistent with
per-file rather than batched compiler invocation, but is not proof that process
startup alone accounts for all the extra CPU.

All three use CMake 4.1.1, SDK 26100.7705, pinned OpenCV 4.10.0 and the original
VS 2022 headers/runtime. The compiler comparison is MSVC **19.44.35229.0** versus
LLVM **23.1.3**, not VS 2026. MSBuild retains HOBL's command with no explicit `/m`;
OpenCV's existing compiler `/MP` is enabled. The Clang experiment still has
`/O2` versus `-O3`, different compiler-generated flags and one extra libpng ARM
assembly compilation: 1,015 versus 1,016 Ninja compile commands. See
[toolchain differences](CLANG_EXPERIMENT.md).

## WPR recordings: compilation, not linking or disk, dominates

Separate full-build captures used WPR's **CPU + DiskIO**, including CPU samples,
context switches and their stacks. WPR start/stop, cleaning and installation are
outside the timer. Analysis is clipped to the timed root command's process
lifetime, excluding trace rundown. All four ETLs, including the focused capture
below, have **zero lost events and buffers**.

| Traced configuration | Wall (s) | Job CPU (s) | ETL context-switch CPU (s) | Compiler CPU (s) | Linker CPU (s) |
|---|---:|---:|---:|---:|---:|
| Original MSBuild | 211.356 | 1,735.375 | 1,744.085 | 1,721.533 | 4.132 |
| MSVC-Ninja | 170.682 | 1,805.125 | 1,812.740 | 1,795.239 | 4.692 |
| LLVM-Ninja | 92.634 | 905.078 | 910.078 | 902.853 | 0.747 |

ETL and job-accounting CPU totals agree within **0.42-0.55%**, with identical
build-tree process counts. Differences include accounting resolution, endpoint
timing and ETW context-switch treatment; they are independent measurements,
not expected to be bit-identical. LLVM driver processes can also perform link
setup, so its compiler-executable category is not an exclusive phase measurement.

**About 99% of build-tree CPU is in compiler processes.** The build engines use
15.24 s (MSBuild), 11.12 s (MSVC's Ninja), and 4.92 s (LLVM's Ninja).
LLD is materially faster than Microsoft's linker, but saving a few seconds of
link work cannot explain the overall gap. In the untraced Ninja logs, the final
post-compilation tail is **4.19-4.28 s for MSVC** and **0.88-0.91 s for LLVM**.

The recorded physical disk's mean busy time during each build is only
**1.27%, 1.37%, and 1.79%** respectively; the highest one-second bins are below
6%. These are machine-wide device metrics, including trace writes, not
build-attributed logical I/O. Together with the compiler CPU evidence, they do
not support physical disk saturation as the dominant bottleneck in these
warm-cache builds. They do not rule out individual I/O waits, memory bandwidth
limits, or CPU overhead in filesystem/security filters.

## Why original MSBuild leaves so much wall time unused

ETL CPU restricted to the build tree, averaged over each equal-duration quarter:

| Configuration | First quarter | Second | Third | Last |
|---|---:|---:|---:|---:|
| MSBuild | 9.03 cores | 11.30 | 10.81 | **1.87** |
| MSVC-Ninja | 10.24 | 11.11 | 11.06 | **10.07** |
| LLVM-Ninja | 8.56 | 10.45 | 10.51 | **9.77** |

The original MSBuild trace has a large compiler batch at approximately
**24.5-156.5 s**. After it:

1. **34 separate `cl.exe` invocations run without overlap from 157.002 to
   202.376 s: a 45.374-second serial stretch.** Their process lifetimes sum to
   31.914 s; a further 13.460 s lies between those invocations. Those gaps are
   elapsed time, not an exclusive measurement of MSBuild CPU overhead.
2. The following major link runs at **202.735-206.138 s**, followed by short
   application compilations/links before the build ends at 211.36 s.
3. The generated `opencv_world.vcxproj` contains **513 compile items**:
   **479 have no per-file metadata**, and **34 have distinct Release metadata**.
   Of the 34, **32 override `ObjectFileName`**, principally for repeated filenames
   across modules, and the other two add per-file preprocessor definitions.
   The last 34 world-library filenames in `build.log` match this special-file
   order, including `parallel.cpp`, `tables.cpp`, DNN layer names and `main.cpp`.

This triangulates the scheduling problem: **per-file compiler settings split the
large `/MP` batch into individual invocations at the tail**. The project is
multi-process overall, but these single-file batches cannot exploit `/MP` across
other source files. Ninja schedules individual files across its queue instead.
The trace does not expose the complete temporary MSBuild response files, so
source attribution uses project metadata and build-log ordering alongside process
lifetimes, not an invented source filename from an ETL command line.

The 45-second serial region is large enough to explain the scale of the measured
38.74-second MSBuild-to-Ninja improvement. It is **not** a claim that eliminating
it would save all 45 seconds: its CPU work must still run, and scheduling,
launch overhead and resource contention change. Increasing project-level `/m`
alone does not necessarily fix batches inside the single `opencv_world` project.

## Where MSVC spends its CPU

Sampled **leaf-module** CPU inside `cl.exe`:

| Module / phase | MSBuild samples (CPU s) | MSVC-Ninja samples (CPU s) |
|---|---:|---:|
| `c2.dll`: optimizer / code generation | **1,076.813** | **1,097.426** |
| `c1xx.dll`: C++ frontend | 450.364 | 465.193 |
| `c1.dll`: C frontend | 12.346 | 13.302 |

The backend alone accounts for approximately **61-63% of compiler CPU**. Runtime,
allocator and kernel leaf samples are separate; without inclusive attribution
they cannot all be reassigned to a compiler phase.

The matching **public Microsoft `c2.pdb`** was loaded locally. Full MSVC-Ninja
backend leaf hotspots include:

| Public symbol | Sampled CPU seconds |
|---|---:|
| `SparseBitVectorBase::GetOrAddNode` | 26.021 |
| `SSAHelpers::GetInstruction` | 17.751 |
| `SymWalkTuplesHelper` | 14.465 |
| `SsaGoptRename` | 12.735 |
| `SsaTupIsUnaliasedScalar` | 12.259 |

These identify optimizer data-structure, SSA and intermediate-representation
work, rather than a dominant linker or file-reading hotspot. They are **exclusive
samples**, not inclusive pass durations: for example, 26.02 s in a bit-vector
helper is not the total cost of a named optimization pass. No single full-build
leaf function explains the entire gap.

LLVM's main compiler is one executable without a supplied matching PDB, so
module sampling alone cannot split its frontend and backend. The focused
`-ftime-trace` measurements below provide that phase evidence instead.

## Which source files explain the largest differences?

Matched Ninja logs identify where to investigate. These are **summed overlapping
command elapsed times**, averaged across the two runs, **not CPU time or wall-time
shares**:

| Component | MSVC (s) | LLVM (s) | Difference (s) |
|---|---:|---:|---:|
| DNN | 676.875 | 309.307 | **367.569** |
| Calibration / 3D | 174.591 | 87.614 | 86.976 |
| Core | 187.492 | 111.445 | 76.047 |
| Image processing | 180.245 | 105.410 | 74.835 |
| Object detection | 87.953 | 43.416 | 44.537 |

Four of the largest individual gaps were selected for replay under WPR, one
source at a time, preserving its actual Ninja compile options. Only output
locations and `/Bt+` or `-ftime-trace` instrumentation were changed.

| Source | Loaded-build command elapsed: MSVC / LLVM (s) | Isolated wall: MSVC / LLVM (s) | Isolated CPU: MSVC / LLVM (s) |
|---|---:|---:|---:|
| `calib3d/src/dls.cpp` | 16.503 / 3.337 | 3.618 / 1.829 | **5.000 / 1.766** |
| `dnn/src/onnx/onnx_importer.cpp` | 16.923 / 5.426 | 2.611 / 3.014 | **8.141 / 2.984** |
| `dnn/src/net_impl.cpp` | 13.942 / 4.248 | 2.270 / 2.537 | **5.969 / 2.500** |
| `dnn/src/tensorflow/tf_importer.cpp` | 13.591 / 4.165 | 2.215 / 2.661 | **6.375 / 2.609** |

**The three DNN files actually compile faster in isolated MSVC wall time, while
using approximately 2.4-2.7 times the CPU.** ETL thread accounting finds **seven
material CPU-consuming threads** in each MSVC compiler process, versus **one**
in each LLVM process. This verifies internal compiler parallelism; it is not
merely inferred from wall time. Seven threads with CPU over a process lifetime
does not mean seven were always running simultaneously.

Consequently, 12 simultaneous MSVC compiler commands are not the same CPU
workload as 12 effectively single-threaded LLVM compilations. The same command
limit does not equalize thread concurrency. This helps explain the large
loaded-versus-isolated elapsed differences, but **does not establish a measured
speedup from changing `/cgthreads`**: no such tuning comparison was run.

Frontend/backend phase evidence:

| Source | MSVC frontend / backend elapsed (s) | MSVC frontend / backend leaf CPU samples (s) | LLVM frontend / backend elapsed (s) |
|---|---:|---:|---:|
| `dls.cpp` | 0.465 / 3.086 | 0.403 / **4.213** | 0.465 / 1.288 |
| `onnx_importer.cpp` | 0.943 / 1.601 | 0.817 / **6.661** | 0.799 / 2.137 |
| `net_impl.cpp` | 0.787 / 1.421 | 0.694 / **4.840** | 0.688 / 1.774 |
| `tf_importer.cpp` | 0.983 / 1.178 | 0.834 / **5.026** | 0.801 / 1.778 |

The especially revealing case is **`dls.cpp`**: frontend elapsed time is essentially
the same, while MSVC's backend takes much longer and more CPU. The resolved
`c2.dll!SSAHelpers::FindInstructionBlock` alone has **1.042 s of leaf samples**
in this isolated compilation, approximately one quarter of its c2 samples.
That is a concrete compiler-hotspot reproducer, not evidence that the same
helper dominates all OpenCV files.

LLVM's backend accounts for roughly 69-73% of its isolated compiler elapsed time.
For `onnx_importer.cpp`, its backend comprises approximately **1.097 s of IR
optimization and 1.039 s of code-generation passes**. For `dls.cpp`, those
figures are **0.320 s and 0.966 s**. Clang time-trace totals are hierarchical:
do **not** add Backend, Optimizer, CodeGenPasses and all their nested totals
together. MSVC `/Bt+` durations are elapsed phase times, not per-phase CPU totals.

## Recommended next experiments

1. **For MSVC throughput, keep Ninja as the measured scheduling improvement.**
   If MSBuild is mandatory, investigate its per-file metadata batch splitting,
   especially the 32 collision-avoiding object filenames. Test a deliberately
   separate project-generation or task-scheduling variant; do not remove the
   unique output names and risk object collisions. Preserve the HOBL default.
2. **For the compiler gap, prioritize backend work, particularly DNN and `dls.cpp`.**
   The isolated commands and phase evidence make useful compiler-performance
   reproducers. SSA/data-structure samples give compiler engineers a concrete
   starting point; PCH/header tuning alone is unlikely to erase this gap.
3. **Test both levels of MSVC parallelism together**, such as bounded Ninja jobs
   with explicit `/cgthreads1`, `/cgthreads2`, and the unchanged default.
   Microsoft's [documentation](https://learn.microsoft.com/en-us/cpp/build/reference/cgthreads-code-generation-threads)
   distinguishes `/MP`, project parallelism and backend threads and warns about
   over-parallelization. Its documented default is not a count of every thread
   observed in this ARM64 compiler process. Measure balanced whole-build wall
   and CPU results before changing a default; this study does not prove that
   reducing backend threads is beneficial.
4. **LLVM remains the strongest measured build-throughput option.** Validate the
   required OpenCV correctness and runtime-performance workloads before adopting
   its generated binaries. Disabling unused DNN/model importers or lowering
   optimization could reduce work, but changes the workload and belongs in a
   separately labeled application-specific experiment.

A new linker, faster disk, or a blanket increase in worker count is not the
first priority indicated by these recordings.

## Reproduction, evidence and limitations

[`results/cpu-etl-20261015`](../results/cpu-etl-20261015) contains separate untraced
and traced benchmark exports. The [combined JSON](../results/cpu-etl-20261015/cpu-etl-summary.json)
contains per-run CPU, build-only ETL summaries, quarter utilization, module and
public-symbol samples, focused phase/thread data, generated-project metadata,
and SHA-256/size identities for the four local ETLs.

The raw recordings remain local under:

```text
results\local\wpr-comparison\20261015_141045_707_msvc_msbuild_etl\build.etl
results\local\wpr-comparison\20261015_141535_718_msvc_ninja_etl\build.etl
results\local\wpr-comparison\20261015_141934_098_clang_ninja_etl\build.etl
results\local\translation-unit-final\units.etl
```

They are approximately 2.18, 2.21, 1.40 and 0.41 GB. **Do not upload raw ETLs or
machine-wide xperf exports:** they contain unrelated process names, command
lines and user paths. Published summaries retain only build-specific evidence.

Use the already configured original MSBuild and two Ninja trees:

```powershell
pwsh -NoProfile -File scripts\run.ps1 -MeasureCpu -Label msvc_msbuild_1
pwsh -NoProfile -File scripts\run.ps1 -MeasureCpu -Generator Ninja -Parallel 12 -Label msvc_ninja_1
pwsh -NoProfile -File scripts\run.ps1 -MeasureCpu -Toolchain Clang -Parallel 12 -Label clang_ninja_1
# Repeat in reverse order, with rests, into a fresh study ResultsDir.

# Elevated shell; Windows Performance Toolkit/xperf required for export.
# Each run gets a new directory. Do not run concurrently.
pwsh -NoProfile -File scripts\run.ps1 -Trace -Label msvc_msbuild_etl
pwsh -NoProfile -File scripts\run.ps1 -Trace -Generator Ninja -Parallel 12 -Label msvc_ninja_etl
pwsh -NoProfile -File scripts\run.ps1 -Trace -Toolchain Clang -Parallel 12 -Label clang_ninja_etl
pwsh -NoProfile -File scripts\profile_translation_units.ps1 -ResultsDir results\local\fresh-units
```

The runner refuses to start if WPR is already recording or status is unknown.
It stops only its named recording instance, including on build failure.
`-Trace` implies `-MeasureCpu`; neither changes the default uninstrumented path.

For a full-build trace, first export process lifetimes and trace quality:

```powershell
# Set $dir to one local trace-run directory.
xperf -i "$dir\build.etl" -a process -withcmdline -ao "$dir\processes.csv" `
    -a tracestats -ao "$dir\trace-stats.txt"
```

Use `cpu-accounting.json`'s `ProcessId` to find the root `cmd.exe` containing the
build invocation; its start/end fields give `$start` and `$end` in microseconds.
Then export:

```powershell
xperf -i "$dir\build.etl" `
    -a cswitch -process -range $start $end -ao "$dir\cpu-precise.csv" `
    -a profile -detail -range $start $end -ao "$dir\cpu-sampled.csv" `
    -a cswitch -util -range $start $end -ao "$dir\cpu-timeline.csv" `
    -a diskio -range $start $end -ao "$dir\disk-build.csv"
python scripts\analyze_build_etl.py $dir
for ($i = 0; $i -lt 4; $i++) {
    $lo = [long]($start + ($end - $start) * $i / 4)
    $hi = [long]($start + ($end - $start) * ($i + 1) / 4)
    xperf -i "$dir\build.etl" -a cswitch -process -range $lo $hi -ao "$dir\cpu-quarter-$i.csv"
}
```

For `units.etl`, export `processes.csv`, `trace-stats.txt`, `cpu-sampled.csv` and
`cpu-threads.csv` with the same actions, using `-a cswitch -thread` and no range.
For symbolized `cpu-functions.csv`, use `xperf -symbols -a profile -detail`
with a **local matching c2 PDB directory** in `_NT_SYMBOL_PATH` and a local
`_NT_SYMCACHE_PATH`. Use the build range for the full MSVC-Ninja recording;
the focused capture can use its complete interval. These environment changes
should be confined to a disposable analysis shell.

The measured compiler's c2 PDB identity is
`C4CA971F7E844CA7909D9D0FF23CDBB91`; Microsoft's public symbol endpoint is
`https://msdl.microsoft.com/download/symbols/c2.pdb/C4CA971F7E844CA7909D9D0FF23CDBB91/c2.pdb`.
Use the matching identity for a different compiler; never force a mismatched PDB.
An initial broad online-symbol pass was stopped; final c2 analysis used the
matching cached PDB and completed offline.

With those exports present, regenerate the report without including raw data:

```powershell
python scripts\analyze_cpu_study.py `
    results\local\cpu-final results\local\wpr-comparison results\local\translation-unit-final `
    results\new-cpu-summary.json `
    --msbuild-project D:\opencv\build_hobl_msvc\modules\world\opencv_world.vcxproj
python -m unittest discover -s tests -p "test_*.py"
pwsh -NoProfile -File tests\test_runner.ps1
```

The analyzer qualifies process identity by kernel address, PID **and lifetime**:
both PIDs and addresses were reused in these traces. It rejects ambiguous CPU
aggregation, missing quality counters and lost events. Focused process labels
must not be reused across that export. Compiler process lifetime concurrency is
not scheduled-thread concurrency; Clang drivers can remain alive during linking.

CPU measurement uses a Windows job object assigned before resuming the root
command, then samples accounting when that command exits. It does not wait for
persistent compiler/conhost helpers. A small `cmd.exe` wrapper is included;
WPR setup/rundown is not. Job logical I/O byte counters are not disk traffic.
Two accounting/install-validation pilots and an initially failed focused-command
selection were excluded, not added to the six valid samples.

Installation validation now uses **the current `install_manifest.txt`**, rather
than recursively discovering old installations. Explicit ARM64 SDK selection
had changed MSBuild's install layout, leaving stale `x64\vc17` files beside the
current `ARM64\vc17` files. The current-manifest selector avoids validating the
wrong executable or package without deleting historical installations.

There are only **two untraced runs per configuration, one full trace per
configuration, and one diagnostic compilation per file/toolchain**. Focused
replays are warm, serial, instrumented and MSVC-first, not another whole-build
benchmark. Background activity was not disabled: machine-wide CPU exceeded
build-tree CPU, and thermal/frequency effects were not controlled. CPU seconds
are not cycle counts or energy. The magnitude and mechanism are supported by
these observations, but precise percentages are not universal performance claims.
