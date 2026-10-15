# Full-build MSBuild experiment: project parallelism with a shared compiler limit

Measured on **15 October 2026**, using the original VS 2022/MSVC ARM64 stack.
The new configuration reached **180.94 seconds median**, compared with
**176.75 seconds for a fresh MSVC/Ninja control** and **205.36 seconds for a fresh
compiler-only MultiToolTask control**.

It saves **24.42 seconds / 11.89%** versus compiler-only MultiToolTask in this
series. Its median is **4.19 seconds / 2.37% above Ninja**, with overlapping
ranges and a crossover between the two comparisons. This small sample does
**not establish a reliable winner between the new MSBuild configuration and Ninja**.
It does demonstrate similar observed full-build wall time with a verified shared
12-compiler limit.

## Configuration

The candidate keeps the existing compiler-only MultiToolTask setting and adds
project-level parallelism plus cross-node enforcement of the compiler limit:

```powershell
cmake --build . --config Release --parallel 12 -- `
    /p:MultiProcCL=true /p:MultiProcMaxCount=12 `
    /p:EnforceProcessCountAcrossBuilds=true /nr:false
```

CMake actually invokes MSBuild with **`/m:12`**. The executable, source, generated
projects, Release optimization settings and SDK remain unchanged.

| Setting | Purpose |
|---|---|
| `/m:12` | Allow multiple projects to build concurrently, up to 12 MSBuild nodes. |
| `MultiProcCL=true` | Schedule C/C++ sources individually, including files with distinct metadata. |
| `MultiProcMaxCount=12` | Set the compiler scheduler's process budget. |
| `EnforceProcessCountAcrossBuilds=true` | Share that budget across MSBuild processes, rather than allowing 12 compilers per project/node. |
| `/nr:false` | Disable worker-node reuse so each measured command owns its worker processes; avoid cross-run CPU attribution and lingering reusable workers. |

The limit is **12 compiler processes**, not 12 total processes or threads.
MSVC can use multiple backend threads inside each compiler process. Linkers,
tracking helpers and MSBuild workers are additional processes. This matches
Ninja's compilation concurrency more closely, but is not identical to Ninja's
12-command budget, which also covers other kinds of build commands.

This is an opt-in experiment. No global environment variable, generated project
or default benchmark command was changed.

## Fresh balanced comparison

Six full clean builds ran sequentially in:

**compiler-only MultiToolTask / MSVC-Ninja / shared-parallel MSBuild /
shared-parallel MSBuild / MSVC-Ninja / compiler-only MultiToolTask**.

All six used process-tree CPU accounting, but **no WPR or binary logger**.
There was a 30-second rest before each run, fresh runner processes, and checked
hashes for the runner, accounting code, setup receipts, generated projects,
Ninja graph/binary and benchmark configuration.

| Order | Configuration | Build wall (s) | CPU (core-seconds) |
|---|---|---:|---:|
| 1 | MultiToolTask, compiler-only | 201.376 | 1,631.969 |
| 2 | MSVC + Ninja, 12 jobs | 171.854 | 1,738.109 |
| 3 | **Shared-parallel MSBuild** | **187.051** | **1,781.656** |
| 4 | **Shared-parallel MSBuild** | **174.825** | **1,693.906** |
| 5 | MSVC + Ninja, 12 jobs | 181.644 | 1,848.391 |
| 6 | MultiToolTask, compiler-only | 209.334 | 1,905.766 |

| Configuration | Median wall (s) | Wall range (s) | Median CPU (s) | Mean occupied cores |
|---|---:|---:|---:|---:|
| MultiToolTask, compiler-only | **205.355** | 201.376-209.334 | 1,768.867 | 8.60 |
| **Shared-parallel MSBuild** | **180.938** | 174.825-187.051 | **1,737.781** | 9.61 |
| MSVC + Ninja, 12 jobs | **176.749** | 171.854-181.644 | 1,793.250 | 10.14 |

Occupied cores are process-tree CPU seconds divided by wall seconds, averaged
across the two runs. They are not counts of compiler processes.

The new MSBuild configuration uses **3.09% less median CPU time than Ninja** in
this sample, but occupies fewer cores on average and takes slightly more median
wall time. Its differences against the corresponding Ninja runs are **+15.20 s**
and **-6.82 s**. Thus a precise 2.37% enduring disadvantage is not established.

Configuration, cleaning and installation are outside the timer. Every build
installed and validated OpenCV 4.10.0. Candidate installs took **3.87-4.08 s**;
they did not perform another full compilation. The candidate diagnostic library
and both final MSVC build-tree libraries also passed the image/matrix smoke check.

## Where it fits alongside earlier results

These are **separate series**, not one pooled ranking or a controlled measurement
of every transition:

| Series | Configuration | Median wall (s) | Median CPU (s) |
|---|---|---:|---:|
| Earlier CPU/ETL comparison | Original MSVC + MSBuild | 210.80 | 1,716.12 |
| Earlier serial-tail comparison | Original MSVC + MSBuild | 201.52 | 1,593.00 |
| Earlier serial-tail comparison | MultiToolTask, compiler-only | 188.38 | 1,708.43 |
| **This fresh series** | MultiToolTask, compiler-only | **205.36** | **1,768.87** |
| **This fresh series** | **Shared-parallel MSBuild** | **180.94** | **1,737.78** |
| **This fresh series** | MSVC + Ninja, 12 jobs | **176.75** | **1,793.25** |
| Earlier CPU/ETL comparison | MSVC + Ninja, 12 jobs | 172.06 | 1,819.57 |
| Earlier CPU/ETL comparison | LLVM + Ninja, 12 jobs | 94.90 | 893.90 |

The earlier MultiToolTask median of 188.38 s versus the fresh 205.36 s illustrates
why a contemporary control matters. Comparing the new 180.94 s only against
188.38 s would suggest a different improvement from the **11.89% measured with
the fresh control**. Neither historical baseline establishes a controlled
default-MSBuild-to-new-setting speedup in this latest series.

The new scheduling configuration is now near **MSVC/Ninja**, not LLVM. LLVM's
earlier CPU result was approximately half MSVC's; changing MSBuild scheduling
does not eliminate that compiler-work difference. LLVM was not rerun in this
experiment.

Earlier reports: [CPU/ETL comparison](CPU_ETL_ANALYSIS.md) and
[serial-tail investigation](MSBUILD_SERIAL_TAIL.md).

## Verifying that parallelism actually changed

Before the primary series, a separate **WPR + MSBuild binary-log** full build
completed in **171.126 s**, with **1,666.219 job-accounted CPU seconds**.
It is diagnostic evidence only and is excluded from the medians above.

The recording establishes:

- The actual MSBuild command contains **`/m:12`**, `MultiProcCL=true`,
  `MultiProcMaxCount=12`, `EnforceProcessCountAcrossBuilds=true`, and `/nr:false`.
- **10 MSBuild process instances** participated, and **six project-level
  MultiToolTask compilation tasks overlapped** at peak. The requested 12-node
  maximum is not a claim that all 12 nodes were always useful or active.
- Across all descendants, **1,015 `cl.exe` processes** were recorded and the
  **peak live compiler count was exactly 12**, not 12 per worker.
- The world library uses **one MultiToolTask containing all 513 sources**,
  rather than the old 479-source batch followed by 34 serial tasks.
- All **1,015 Release source/project command records** match the original
  MSBuild tracking-log records. CMake compiler-identification probes are excluded.
- WPR reports **zero lost events and buffers**. ETL and job accounting identify
  the same **3,248 build-tree process instances**. ETL build CPU is 1,678.977 s,
  within **0.76%** of the job-accounting total.

Average live compiler-process count in that trace is **8.64**, despite the peak
of 12. Live-process count is not CPU utilization or runnable-thread count.
Enabling a maximum does not guarantee a full queue at every instant: project
dependencies, tracking/launch work and the final link can still limit overlap.

The diagnostic trace uses 1,015 compiler processes plus tracking/conhost
processes and multiple MSBuild workers. This retains substantially more process
machinery than Ninja. The evidence supports the scheduling settings and observed
wall-time convergence, not identical execution graphs or identical overhead.

## Reproduction

Configure the original MSBuild and MSVC-Ninja trees first, if not already done:

```powershell
pwsh -NoProfile -File scripts\setup.ps1
pwsh -NoProfile -File scripts\setup.ps1 -Generator Ninja

# Candidate alone: original MSVC/MSBuild, shared 12-compiler budget.
pwsh -NoProfile -File scripts\run.ps1 -MeasureCpu `
    -MSBuildScheduler MultiToolTask -CompilerJobs 12 `
    -SharedCompilerLimit -Parallel 12 -Label shared12

# The complete six-build comparison; use a fresh directory.
pwsh -NoProfile -File scripts\run_msbuild_parallelism_study.ps1 `
    -ResultsDir results\local\fresh-shared-study -Jobs 12
python scripts\export_results.py results\local\fresh-shared-study results\fresh-shared-export

# Return to the unchanged original HOBL-equivalent command.
pwsh -NoProfile -File scripts\run.ps1 -Label original_default
```

`-SharedCompilerLimit` requires `-MSBuildScheduler MultiToolTask`.
`-Parallel` is the project-level setting; `-CompilerJobs` is the shared compiler
budget. They are deliberately separate. Scheduler properties and disabled node
reuse also apply to cleaning and installation, but project-level parallelism
is only needed on the timed build command.

For a diagnostic repeat, add `-Trace -BinaryLog` in an elevated shell. Extract
process lifetimes, precise/sample CPU and binary-log events as described in the
[CPU report](CPU_ETL_ANALYSIS.md) and [tail report](MSBUILD_SERIAL_TAIL.md).
Do not pool instrumented runs into the untraced study.

Public evidence: [six-run export and study manifest](../results/msbuild-shared-20261015/matched),
[separate diagnostic export](../results/msbuild-shared-20261015/diagnostic), and
[comparison/concurrency/source-equivalence evidence](../results/msbuild-shared-20261015/comparison.json).
Raw ETLs, binary logs, full process exports and command-tracking logs remain
local under `results\local\msbuild-shared-diagnostic`; they can contain unrelated
activity, paths or environment values.

## Limits

This remains a warm-cache, normal-use-machine experiment with **two untraced
observations per configuration** and one diagnostic capture. Thermal state,
frequency and background work were not controlled. No analysis commands ran
concurrently with the primary measurement series.

The fresh sequence balances configuration position but does not eliminate
carryover or nonlinear drift. The comparison changes project parallelism,
shared-budget enforcement and worker-node reuse together; it does not isolate
the individual contribution of each switch. All results concern clean-build
throughput, not energy use or runtime speed of the resulting OpenCV library.
