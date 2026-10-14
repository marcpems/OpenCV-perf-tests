# Does matching 12 jobs to 12 cores beat Ninja's default 14?

**Not established by this test.** In eight matched clean builds, 12 jobs had a
**185.34 s median**, versus **186.44 s** for the default 14: only **1.10 s / 0.59%**
less build time. The run-to-run variation was substantially larger. This does not
verify a reliable performance advantage for matching worker count to core count.

The earlier generator comparison chose 12 jobs as an explicit experimental setting.
It did **not** show that 12 was optimal or that the Ninja default was inefficient.
This follow-up directly tests that hypothesis rather than comparing earlier runs
with different CMake versions or measurement conditions.

## What was matched and verified

Measured 14 October 2026, on the same 12-core Snapdragon X2 Elite machine:

- Same OpenCV 4.10.0 source, unmodified, with the full HOBL CMake definitions.
- Same CMake 4.1.1, Ninja 1.12.0 executable, native ARM64 MSVC compiler, and configured
  Ninja build directory. The generated build graph and Ninja binary hashes stayed
  unchanged throughout the study.
- Same runner and clean -> timed build -> install -> installed version-check sequence.
- Four runs per setting, in **12, 14, 14, 12, 14, 12, 12, 14** order, with 30 seconds
  between runs. The 14-job condition omitted the parallel option rather than passing
  an explicit `-j14`.
- Actual observed peak command concurrency was **12 in all four explicit runs**
  and **14 in all four default runs**, verified from fresh, deduplicated Ninja logs.
- Every run executed **1,039 unique commands, including 1,015 compile commands**,
  and installed/validated OpenCV 4.10.0. No incremental-build shortcut was compared.

These controls match the configuration and workload, not the full operating state
of a dedicated lab machine. Background activity, temperature and clock frequency
were not continuously monitored or controlled. There was no separately discarded
warm-up run. The study measures **wall-clock build time**, not CPU cycles, joules,
battery drain or performance per watt.

## All observations

| Sequence | Setting | Build time |
|---|---|---:|
| 1 | Explicit 12 | 163.96 s |
| 2 | Default 14 | 181.57 s |
| 3 | Default 14 | 186.10 s |
| 4 | Explicit 12 | 189.35 s |
| 5 | Default 14 | 193.96 s |
| 6 | Explicit 12 | 187.01 s |
| 7 | Explicit 12 | 183.67 s |
| 8 | Default 14 | 186.77 s |

| Statistic | Explicit 12 | Default 14 |
|---|---:|---:|
| Count | 4 | 4 |
| **Median** | **185.34 s** | **186.44 s** |
| Mean | 181.00 s | 187.10 s |
| Minimum | 163.96 s | 181.57 s |
| Maximum | 189.35 s | 193.96 s |
| Sample standard deviation | 11.59 s | 5.12 s |

The mean favors 12 by **6.10 s / 3.26%**, but the median favors it by only
**1.10 s / 0.59%**. The first 12-job run was unusually fast relative to the
subsequent runs, and materially affects the mean. It remains in all primary results:
there is no measured basis for discarding it as invalid.

The adjacent paired comparisons also show that the result is not uniform:

| Pair | Order | Default 14 minus explicit 12 |
|---|---|---:|
| 1 | 12 then 14 | +17.61 s |
| 2 | 14 then 12 | **-3.25 s** |
| 3 | 14 then 12 | +6.95 s |
| 4 | 12 then 14 | +3.10 s |

Positive means 12 was faster; negative means the default was faster. Thus 12 won
three pairs, while the default won one. The paired mean difference is +6.10 s.
These four pairs do not establish a statistically reliable small advantage.

As a **post-hoc sensitivity check only**, omitting the entire first pair gives
medians of 187.01 s for 12 and 186.77 s for 14: the ordering reverses, with 14 ahead
by about 0.13%. This is not a replacement result or a justification to remove data;
it illustrates how fragile the claimed worker-count advantage is in this sample.

## Interpretation and recommendation

**Do not claim that the default 14 is less efficient than 12 on the basis of these
results.** There is a small descriptive median advantage for 12, but it is not
robust enough to verify the proposed conclusion. Nor do these data prove the two
settings are equivalent or that 14 is optimal.

More runnable processes than CPU cores can incur scheduling/cache contention, but
extra jobs can also keep cores busy while other commands wait on I/O or dependencies.
Matching worker count to core count is a reasonable setting to test, **not a rule
that guarantees the fastest build**. The current measurements do not isolate either
mechanism.

Keep `-Parallel 12` when reproducing the published 12-job benchmark. For general
development, leaving Ninja at its default is also reasonable; there is no verified
reason here to mandate a 12-job cap. Establishing a small difference would require
more repetitions after a predefined warm-up and better thermal/background controls.
An energy-efficiency claim would additionally need power measurements.

## Evidence and reproduction

Public snapshot:
[`results/2026-10-14-ninja-parallelism`](../results/2026-10-14-ninja-parallelism).
The [`comparison.json`](../results/2026-10-14-ninja-parallelism/comparison.json)
contains exact timings, statistics, paired differences and observed concurrency.
[`study.json`](../results/2026-10-14-ninja-parallelism/study.json) records the planned
order and tool/build-graph hashes. Each run retains its logs and metadata.

```powershell
pwsh -NoProfile -File scripts\setup.ps1 -Generator Ninja
pwsh -NoProfile -File scripts\run_parallelism_study.ps1 -FixedJobs 12 `
  -ResultsDir results\local\ninja-job-study-new
python scripts\compare_parallelism.py results\local\ninja-job-study-new

# Recompute the published comparison without rebuilding:
python scripts\compare_parallelism.py results\2026-10-14-ninja-parallelism
```

Do not pool these measurements with the initial generator-comparison series.
