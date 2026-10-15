# Initial OpenCV build performance analysis

**CPU/ETL follow-up:** the [LLVM versus original MSVC investigation](CPU_ETL_ANALYSIS.md)
separates wall time from actual process-tree CPU. In a new matched series,
LLVM used **54.98% less wall time and 47.91% less CPU than original MSBuild**;
with Ninja fixed, it used **50.87% less CPU than MSVC**. WPR identifies a
**45-second serialized compilation tail** in MSBuild and substantial MSVC
optimizer/code-generation CPU. These are separate measurements from the
historical initial results below.

Measured locally on **14 October 2026**. The HOBL-equivalent baseline took
**230.34 seconds median (3 min 50 s)**. The fastest configuration in this initial MSVC-only series was
**Ninja with 12 jobs: 192.99 seconds median**, a **16.2% reduction** in this small
sample. It is an alternative-generator experiment, not the HOBL baseline score.

**Worker-count follow-up:** the later [matched 12 versus default 14 study](NINJA_PARALLELISM.md)
did **not establish a reliable advantage for 12 jobs**. This initial table compared
build-system configurations; it did not identify an optimal Ninja worker count.

**Toolchain follow-up:** the later [native ARM64 Clang experiment](CLANG_EXPERIMENT.md)
measured **103.02 s for Clang versus 172.75 s for MSVC**, both with Ninja and 12 jobs:
40.36% less median build time in that separate, matched series. Clang is opt-in;
do not compare its time directly with the older table below to isolate compiler effects.

**Latest Microsoft tools follow-up:** the [VS 2026/MSBuild study](VS2026_EXPERIMENT.md)
measured **226.22 s versus 226.68 s** for a fresh VS 2022 control. The 0.20%
median difference was overwhelmed by run variation; no reliable build-throughput
benefit was established. The original default remains unchanged.

**Latest SDK follow-up:** the [matched VS 2026 SDK comparison](WINDOWS_SDK_EXPERIMENT.md)
measured **238.36 s with SDK 28000.2957 versus 233.84 s with SDK 26100.7705**,
four observations each: **1.93% more median time**, not a speedup. Both conditions
used the same current compiler, MSBuild and CMake. Run variation overlapped; a
documented between-run PowerShell interruption lengthened the rest before the
final pair. This does not establish a general SDK-caused regression.

**Compilation dominates. DNN is the largest module cost; linking and installation
are comparatively small.** Prioritize build scheduling and expensive translation
units rather than linker replacement.

## Machine and workload

| Item | Measured configuration |
|---|---|
| CPU | Snapdragon X2 Elite @ 4.03 GHz; 12 cores / 12 logical processors |
| Memory | 63.48 GiB visible to Windows |
| OS | Windows 11 Pro ARM64, build 28000 |
| Power scheme | High performance; unchanged by the runner |
| Compiler | Native ARM64-host / ARM64-target MSVC 19.44.35229.0; toolset 14.44.35207 |
| Build tools | VS Build Tools 2022, installation version 17.14.37710.0; SDK 10.0.26100.0 |
| CMake / Ninja | CMake 4.1.1 ARM64; Ninja 1.12.0 for the alternative generator |
| Source | OpenCV 4.10.0, `71d3237a093b60a27601c20e9ee6c3e52154e8b1` |
| Workload | Release `opencv_world`, HOBL's full 23-definition configuration; tests/Python/OpenCL disabled |

Both generators used the same `cl.exe`, verified by SHA-256 in every run.
Both installed `opencv_version.exe` binaries were checked as PE machine `0xAA64`
(ARM64). OpenCV's install directory happens to be named `x64\vc17`; that directory
name is **not** the executable's architecture.

The setup/configuration work is not in the benchmark: the recorded MSBuild configure
took 41.62 seconds and Ninja configure 22.81 seconds, with source already present.
Those are not fresh-machine installation or download timings.

## Timings

All times below are clean **build-only wall-clock seconds**. Each iteration completed
installation and the installed executable returned `4.10.0`.

| Configuration | Run 1 | Run 2 | Median | Median time reduction vs baseline |
|---|---:|---:|---:|---:|
| HOBL command: MSBuild, no explicit `--parallel` | 230.04 | 230.65 | **230.34** | Reference |
| MSBuild `--parallel 12` | 226.88 | 211.60 | **219.24** | **4.8%** |
| Ninja `--parallel 12` | 201.29 | 184.70 | **192.99** | **16.2%** |

The baseline already has compiler `/MP`. The MSBuild variant adds project-level
parallelism; it does not turn a single-core build into a 12-core one.

Cleaning took 0.84-0.92 seconds for MSBuild and 0.12-0.26 seconds for Ninja.
Installation took 1.94-2.05 seconds for the uninstrumented MSBuild runs and
0.30-0.82 seconds for Ninja. These phases are excluded from HOBL's `build_time`.

**These are two observations per configuration, not a statistically established
speedup.** Variant ranges were appreciable: 211.60-226.88 seconds for parallel
MSBuild, and 184.70-201.29 for Ninja. Normal background activity, cache state,
thermal/frequency behavior and run order were not controlled as in a dedicated lab.
AC state and temperature were not continuously logged. The baseline was measured
before and after the variants; it differed by 0.61 seconds.

Raw timings and per-run evidence:
[`results/2026-10-14-snapdragon-x2/summary.json`](../results/2026-10-14-snapdragon-x2/summary.json).

## Where time goes

### Baseline task-level diagnostic

A **separate instrumented baseline** using MSBuild PerformanceSummary took
**327.30 seconds**. It is deliberately not pooled with the uninstrumented baseline.
The instrumentation/run conditions materially changed the observed result; these
measurements do not isolate logging overhead from other system effects.

| MSBuild task | Aggregate task elapsed time |
|---|---:|
| `CL` compilation, 56 invocations | **316.06 s** |
| `Link`, 7 invocations | **6.45 s** |
| `CustomBuild`, 25 invocations | **2.05 s** |
| `LIB` static archives, 14 invocations | **1.24 s** |

This strongly identifies compilation as the main area to investigate. These are
task aggregates, not measured CPU seconds or a fully exclusive wall-time partition.
The reported `MSBuild`/`ResolveProjectReferences` times include nested dependency
work; adding them to compilation would double count.

Source:
[`baseline_profile/build.log`](../results/2026-10-14-snapdragon-x2/20261014_180643_788_baseline_profile/build.log),
under `Task Performance Summary`.

### Module-level diagnostic from Ninja

Each Ninja run completed **1,039 unique commands**, including **1,015 compile commands**.
Compilation accounted for **99.45% of summed command elapsed time** across the two
runs. This percentage is **not 99.45% of baseline wall time or CPU usage**.

The table averages each module's summed command durations across the two Ninja runs.
Commands overlap; the sum is much larger than the approximately 193-second build.
Shares use the combined summed durations from both runs.

| Component | Mean summed command elapsed | Share of summed elapsed |
|---|---:|---:|
| **DNN** | **753.80 s** | **33.64%** |
| Core | 232.50 s | 10.38% |
| Image processing (`imgproc`) | 213.75 s | 9.54% |
| Calibration / 3D (`calib3d`) | 197.89 s | 8.83% |
| Object detection | 100.24 s | 4.47% |
| Stitching | 96.37 s | 4.30% |
| Features2D | 81.05 s | 3.62% |
| Video | 75.90 s | 3.39% |
| OpenEXR dependency | 67.49 s | 3.01% |
| Image codecs | 65.24 s | 2.91% |
| Protobuf dependency | 47.99 s | 2.14% |

The first four modules account for **62.4%** of this summed elapsed measure.
DNN includes model-format importers and generated serialization code as well as
inference implementations; it is the most promising component for deeper profiling.

Individual expensive files include:

| Translation unit | Run 1 elapsed | Run 2 elapsed |
|---|---:|---:|
| `calib3d/src/dls.cpp` | 23.69 s | 14.84 s |
| `dnn/src/onnx/onnx_importer.cpp` | 14.49 s | 16.84 s |
| `dnn/src/tensorflow/tf_importer.cpp` | 14.48 s | 16.19 s |
| `imgproc/src/connectedcomponents.cpp` | 13.74 s | 15.07 s |

These are elapsed durations while other compilation was running, not isolated
per-file CPU timings. In particular, the variation in `dls.cpp` argues against
claiming a fixed intrinsic cost from one run.

The `opencv_world4100.dll` link took **4.79 / 4.14 seconds**. The end-of-build interval
after the final compile finished was **4.63 / 4.15 seconds**. Replacing or tuning the
linker has limited headroom relative to the roughly three-minute Ninja build.
DLL and import-library output rows are counted as one link command.

Per-run details:
[Ninja run 1 analysis](../results/2026-10-14-snapdragon-x2/20261014_174618_755_ninja12_1/analysis.json) /
[Ninja run 2 analysis](../results/2026-10-14-snapdragon-x2/20261014_175841_121_ninja12_2/analysis.json).

## Recommended improvements

These recommendations describe the initial MSVC-only series. The subsequent
[Clang report](CLANG_EXPERIMENT.md#where-the-build-time-goes) adds a faster measured
toolchain candidate and updated cost breakdown, without replacing the HOBL baseline.

| Priority | Recommendation | Evidence and qualification |
|---|---|---|
| 1 | **Use Ninja for day-to-day clean builds**, without assuming 12 jobs is optimal. | Largest measured reduction: 37.35 s / 16.2% median here. Keep the original MSBuild command as the HOBL reference; do not silently substitute this score. The later [12-vs-default-14 comparison](NINJA_PARALLELISM.md) did not establish a reliable worker-count advantage; use 12 to reproduce this table, not as a universal tuning rule. |
| 2 | If VS/MSBuild must remain, try **`--parallel 12`**. | 11.10 s / 4.8% median reduction, with substantial run variation. Avoid assuming more workers always help: `/m` and compiler `/MP` are separate concurrency layers and can oversubscribe resources. |
| 3 | Profile **DNN importers/generated code, core/imgproc, and the large solver translation units** using MSVC Build Insights/compiler timing. | They dominate the detailed command timings. Determine frontend/header parsing versus optimizer/backend cost before changing source. The current data does not distinguish those causes. |
| 4 | Investigate shared-header/precompiled-header improvements in a separate source branch. | The configured build reports precompiled headers **OFF**. A modern PCH experiment may reduce repeated parsing, but simply assuming an old CMake toggle enables it is unsafe. Measure clean and incremental builds and validate binary behavior. No PCH improvement was measured here. |
| 5 | For an application-specific OpenCV build, reduce the module/dependency set only if the application genuinely does not need it. | DNN is the largest candidate; codecs also pull dependencies such as OpenEXR. `BUILD_LIST`/feature changes alter the workload and **invalidate HOBL equivalence**. Never present their smaller-build time as an unchanged benchmark improvement. |
| 6 | Use incremental builds/cache reuse for developer iteration, not for this clean-build score. | Avoids recompiling unchanged files, but changes what is measured. Compiler-cache policy and hit rate must be reported separately. |

Do **not** prioritize disabling Defender, changing security exclusions, reducing
optimization, or removing workload modules to manufacture a faster baseline.
No such system changes were made.

## Exploratory runs and exclusions

Earlier experiments used the already-installed CMake 4.4.3. They are not combined
with the pinned 4.1.1 series:

- The first instrumented build was 425.10 s; a later uninstrumented baseline was
  243.56 s. The cause of that difference was not isolated.
- A Ninja-default run was 183.72 s, but its worker count differed from the explicitly
  bounded 12-job experiments.
- `UseMultiToolTask=true` with `TrackFileAccess=false` built in 208.34 s but then
  spent **246.68 s installing/rebuilding**. It is not a demonstrated end-to-end win.
- Failed/interrupted setup and build attempts are not successful samples.
- Early CPU-utility samples covered clean/build/install together and are not valid
  build-only utilization. Early Ninja analysis also double-counted multi-output links;
  the published analyzer and pinned-series reports correct that.

Local exploratory artifacts remain under `results\local\exploratory`; only the
validated pinned series is exported publicly. See
[methodology](METHODOLOGY.md) for the HOBL survey, exact timing boundary, adaptations,
provenance and limitations.
