# Fresh five-configuration comparison after a device configuration change

**Follow-up:** the [compiler-gap investigation](COMPILER_GAP_INVESTIGATION.md)
checks native ARM64 execution and workload equivalence, then measures isolated
compilations, compiler-only parallel batches and source-pattern controls.

All five configurations were rerun on **15 October 2026, 18:23-18:58 BST**,
after the device owner reported a configuration change. This is a new,
self-contained comparison: **ten full clean builds, two per configuration**.
Earlier results are retained separately and are not pooled into these medians.

The specific device setting was not recorded, so these results describe the
current device state; they do not isolate the causal effect of that setting.
No compiler, SDK, OpenCV source, generated build graph or benchmark optimization
option was changed for the rerun.

## Current results

| Configuration | Run 1 wall (s) | Run 2 wall (s) | Median wall (s) | Median CPU (core-seconds) |
|---|---:|---:|---:|---:|
| Original MSVC + MSBuild | 204.883 | 225.351 | **215.117** | **1,658.711** |
| MSBuild, compiler-only MultiToolTask | 191.339 | 199.241 | **195.290** | **1,780.148** |
| MSBuild, project parallelism + shared compiler budget | 185.898 | 189.450 | **187.674** | **1,826.219** |
| MSVC + Ninja, 12 jobs | 170.291 | 175.719 | **173.005** | **1,779.711** |
| LLVM + Ninja, 12 jobs | 96.703 | 102.045 | **99.374** | **932.430** |

Wall time is the complete Release build only. Configuration, cleaning,
installation and installed-version validation are outside that timer.
CPU is user plus kernel time for the measured command's descendant process tree,
not machine-wide CPU or summed elapsed compiler-command time.

| Configuration | Mean occupied cores | Build-tree processes per run |
|---|---:|---:|
| Original MSBuild | 7.71 | 507 |
| Compiler-only MultiToolTask | 9.11 | 3,229 |
| Shared-parallel MSBuild | 9.73 | 3,247 |
| MSVC/Ninja | 10.29 | 1,097 |
| LLVM/Ninja | 9.39 | 1,092 |

Occupied cores are each run's CPU/wall ratio averaged over the two observations.
Process counts include build helpers and are not counts of simultaneous compilers.

## Interpretation of this rerun

- **Shared-parallel MSBuild saves 27.44 s / 12.76% versus original MSBuild.**
  It saves a further **7.62 s / 3.90%** over compiler-only MultiToolTask.
  Its median CPU cost is **10.10% higher than original MSBuild** despite taking
  less wall time.
- **MSVC/Ninja is faster than shared-parallel MSBuild in both halves of this
  series.** The shared configuration takes **14.67 s / 8.48% more median wall
  time than Ninja**. Their observed wall ranges do not overlap here.
  This replaces the earlier series' smaller 2.37% median gap as the current
  observation; it is not evidence of a universally fixed gap.
- **LLVM/Ninja remains the fastest:** **42.56% less median wall time and
  47.61% less median CPU than MSVC/Ninja**, with the build system and requested
  job count held constant. Against original MSBuild, its median wall reduction
  is **53.80%**.

All five configurations' second observation is slower than their first.
The original baseline spans **204.88-225.35 s**, showing appreciable within-series
variation. Forward/reverse ordering balances positions, but does not eliminate
thermal effects, frequency changes, background activity or nonlinear drift.
Two observations per condition are not a confidence interval or proof of an
enduring percentage advantage.

## Comparison with earlier measurements

For each configuration, the table uses its most recent published comparable
CPU-accounted series before this rerun. These historical references come from
different studies and are **not** a single matched before/after experiment.
Positive changes mean more wall time.

| Configuration | Historical series | Earlier median (s) | Current median (s) | Change |
|---|---|---:|---:|---:|
| Original MSBuild | Serial-tail study | 201.52 | 215.12 | +6.75% |
| Compiler-only MultiToolTask | Shared-parallelism study | 205.36 | 195.29 | -4.90% |
| Shared-parallel MSBuild | Shared-parallelism study | 180.94 | 187.67 | +3.72% |
| MSVC/Ninja | Shared-parallelism study | 176.75 | 173.00 | -2.12% |
| LLVM/Ninja | CPU/ETL study | 94.90 | 99.37 | +4.72% |

Original MSBuild also measured **210.80 s** in the earlier CPU/ETL study; that
number is retained in its report rather than substituted for the later
201.52 s baseline. The mixed historical changes do not identify a uniform
device-wide speedup or slowdown, nor establish the effect of the reported
configuration change.

Sources: [serial-tail study](MSBUILD_SERIAL_TAIL.md),
[shared-parallelism study](MSBUILD_SHARED_PARALLELISM.md), and
[CPU/ETL study](CPU_ETL_ANALYSIS.md).

## Fixed settings and protocol

The current run retains:

- OpenCV **4.10.0**, commit `71d3237a093b60a27601c20e9ee6c3e52154e8b1`,
  with the same Windows HOBL definitions and Release build workload.
- Native ARM64 **VS 2022/MSVC 19.44.35229**, toolset **14.44.35207**,
  CMake **4.1.1**, and SDK target **10.0.26100.0**, servicing **10.0.26100.7705**.
  These are the original toolchain profiles, not VS 2026.
- The previously configured native ARM64 **LLVM 23.1.3** tools, including LLD,
  and the existing Clang-only compatibility flag.
- **Ninja 1.12.0**, the 12-core ARM64 device, and the reported **High performance**
  power scheme throughout all ten runs.

| Condition | Timed build settings |
|---|---|
| Original | `cmake --build . --config Release`; no explicit project parallelism; existing compiler `/MP` retained |
| MultiToolTask | Original plus `/p:MultiProcCL=true /p:MultiProcMaxCount=12` |
| Shared | MultiToolTask plus `--parallel 12`, `/p:EnforceProcessCountAcrossBuilds=true` and `/nr:false` |
| MSVC/Ninja | Original compiler with Ninja and `--parallel 12` |
| LLVM/Ninja | Existing Clang/LLD toolchain with Ninja and `--parallel 12` |

Execution order was:

**original / MultiToolTask / shared / MSVC-Ninja / LLVM-Ninja /
LLVM-Ninja / MSVC-Ninja / shared / MultiToolTask / original**.

There was a **30-second pause before every run**. Each run used a fresh runner
process and cleaned its build tree before timing. No additional warm-up build
or filesystem-cache purge was inserted. The machine already had the previous
benchmark artifacts and caches.

The runner checked hashes of the benchmark scripts, CPU-accounting code,
configuration, setup receipts, all three CMake caches/build graphs and configured
Ninja executable before and after every run. Each individual run also verified
the configured compiler/toolchain and SDK identities. All frozen hashes still
matched at completion, and tracked OpenCV source files remained unmodified.

All ten builds used **CPU accounting without WPR, binary logging or MSBuild
PerformanceSummary instrumentation**. No other test or analysis workload was
launched by the benchmark operator during the measurement sequence. The existing
shared-cap ETL evidence remains in the earlier report; a new trace was not
captured in this rerun.

All ten installed builds validated as native OpenCV 4.10.0. After timing was
complete, the final libraries from each of the three build trees passed the
untimed image/matrix smoke checks. The three MSBuild scheduler conditions share
one build tree, so its final smoke check covers the final original-MSBuild
output, not three separately retained installed copies.

## Reproduction and evidence

With the original MSBuild, MSVC/Ninja and Clang/Ninja trees configured:

```powershell
pwsh -NoProfile -File scripts\run_msbuild_parallelism_study.ps1 `
    -AllConfigurations -Jobs 12 -PauseSeconds 30 `
    -ResultsDir results\local\fresh-five-config-study

python scripts\export_results.py `
    results\local\fresh-five-config-study results\fresh-five-config-study
```

Use a new destination for each study; existing study directories are rejected.
Without `-AllConfigurations`, the runner retains its original three-condition
protocol. The ordinary HOBL-equivalent runner defaults are unchanged.

The [public snapshot](../results/five-config-rerun-20261015) contains all ten
sanitized runs, per-run wall/CPU accounting, successful version outputs,
[group summaries](../results/five-config-rerun-20261015/summary.json), and the
[ordered study manifest with frozen hashes](../results/five-config-rerun-20261015/study.json).
