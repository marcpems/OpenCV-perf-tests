# Relationship to HOBL

Reference: Microsoft HOBL commit
[`05896ef511054a705d2216ffe8cf67f66cea3fe0`](https://github.com/microsoft/HOBL/tree/05896ef511054a705d2216ffe8cf67f66cea3fe0).
Source paths below refer to that revision. The standalone scripts do not import or run
the HOBL host, remote-control service, prep scenarios, or proprietary utilities.

## Survey of the performance scenarios

These are distinct workloads, not interchangeable performance scores:

| Scenario | Process and timed work |
|---|---|
| Windows OpenCV build | Prep clones OpenCV 4.10.0 and generates a VS 2022 project. Each iteration cleans, times a Release build, installs, and runs the version executable. Only the build is the primary metric. |
| macOS OpenCV build | Separately prepared CMake/Make tree, `make clean`, then `/usr/bin/time -p make -j$CORES`. Reports wall time plus user/system CPU time. The Windows runner does not collect those CPU-time metrics. |
| LLVM | Pinned LLVM source; Ninja clean followed by a timed direct Ninja invocation. Toolchain setup is outside the timed region. Its Ninja concurrency is not evidence that the Windows OpenCV scenario uses Ninja. |
| Node.js | Pinned Node.js source and native `vcbuild.bat`; untimed clean then timed Release build, using `openssl-no-asm`. Python and toolchain preparation are prerequisites. |
| .NET Aspire | `dotnet clean` followed by a separately timed build, with `scenario_runtime` and `build_time` in the results. Different compiler/runtime from OpenCV. |
| MLPerf Client | Inference rather than compilation. Runs a prepared MLPerf client/configuration, reads benchmark duration from the client's output, and reports inference-related results. |
| Blender benchmark | Uses generated action JSON through the same setup/run/teardown framework rather than the OpenCV shell build script. |
| Battery rundown / stress workloads | Test plans combine preparation, charging/idle waits, repeated application scenarios and measurement tools; a battery rundown is not a build-time test. |

Sources: `scenarios/windows/{opencv_build,llvm,nodejs,net_aspire,mlperf}` README,
scenario classes and `*_resources/*_run.ps1`; the macOS OpenCV run script;
`scenarios/windows/blender_benchmark/blender_benchmark.py`; root `README.md`.

The common pattern is **prepare once, execute repeated workload iterations, validate
outputs, write scenario-specific metrics, collect results**. HOBL's outer measurement
window may include activities beyond the metric's build-only interval.

## Exact Windows OpenCV contract

`scenarios/windows/opencv_build/opencv_build.py` has `prep_version = "7"`,
one loop by default, and a 3,600-second remote-call timeout per loop.

Prep uses OpenCV tag `4.10.0`, commit
`71d3237a093b60a27601c20e9ee6c3e52154e8b1`, CMake **4.1.1** and the
**Visual Studio 17 2022** generator. All 23 `-D` arguments are in `benchmark.json`.
The flag parity test compares them directly with the pinned upstream prep script.
The monolithic `opencv_world` library includes the default enabled modules.
`BUILD_TESTS=OFF` and `BUILD_PERF_TESTS=OFF` are intentional: this is **not**
OpenCV's algorithm performance-test suite.

From the configured build directory:

```powershell
# Excluded from build_time:
cmake --build . --target clean --config Release

# The primary HOBL metric:
cmake --build . --config Release

# Excluded from build_time:
cmake --build . --target INSTALL --config Release
# Run the installed opencv_version.exe; require 4.10.0.
```

`scenario_runtime == build_time` in seconds, rounded to two decimal places in the
key/value CSV. The trace uses `Timestamp,opencv_build_time`, with the timestamp being
elapsed seconds since this standalone iteration began. Metadata retains higher
precision timings and separately records clean/install costs.

**No explicit MSBuild `/m` is passed by the baseline.** OpenCV still enables `/MP`
within compiler tasks, so this is not a single-core compilation benchmark.

## Intentional local adaptations

- Use existing VS 2022 Build Tools, discovered with `vswhere`, instead of installing
  Community edition on ARM64. Native compiler host and target are verified.
- Install pinned CMake side-by-side, not by replacing the system CMake.
- Use separate `build_hobl_msvc` / `build_hobl_ninja` directories to avoid disturbing
  the initial exploratory trees. Source root defaults to the script's drive plus
  `\opencv`, and can be overridden.
- Validate the installed version executable by discovery rather than HOBL's
  hard-coded `install/x64/vc17` path.
- Preserve individual logs and metadata per iteration; stop on native command failure.
  A per-source exclusive lock prevents these runners from overlapping one another.
- No SimpleRemote, full DUT setup, process/service termination, security exclusions,
  battery rundown, power-state change, or unrelated machine cleanup.
- No optional ETW phase-marker provider or DAQ capture. Local build timings are not
  official HOBL power/battery-life measurements or a dedicated-lab certification.
- PowerShell, source, toolchain and CMake are prerequisites; this is not a
  system-wide tool installer. The machine's missing SDK 26100 was installed separately.

## Experiment design and interpretation

The pinned series compares the baseline against two explicitly labeled variants:
MSBuild with `--parallel 12`, and Ninja with `--parallel 12`. They use the same source,
CMake definitions, compiler binary and Release settings. Generator-specific generated
flags differ (e.g. MSBuild `/MP` versus Ninja's per-file scheduling and `/FS`), so Ninja
is a build-system experiment, **not an official equivalent HOBL score**.

Each run cleans its build outputs; the OS file cache and downloaded dependencies
remain warm. No memory-cache purge or reboot is performed. Runs are sequential with
30 seconds between experiments. Normal user/background activity is not disabled;
this initial sample is not thermally controlled, and run order can influence results.

The uninstrumented sequence is baseline, Ninja, parallel MSBuild, parallel MSBuild,
Ninja, baseline. A separate MSBuild PerformanceSummary run follows. Report the two
uninstrumented observations per configuration individually and their median/range,
not a statistically established population speedup. Keep the diagnostic run separate.

MSBuild target/task durations may overlap or include dependency work.
`ResolveProjectReferences`, `MSBuild`, project durations and compile durations must
**not** be added together as if they were exclusive costs.

Ninja logs contain one row per **output**, not per command. DLL/import-library/PDB
outputs from one link invocation must be counted once. The analysis groups rows by
start/end/command hash; the runner removes the previous log after cleaning.
Summed command elapsed times overlap and include waiting. They are **not CPU seconds**;
mean concurrent steps is **not CPU utilization**. Module shares describe the Ninja
diagnostic workload and are not exact baseline wall-time shares.

Only successful runs with a validated installed executable are exported. Public
logs redact user-profile paths; `original_sha256.json` records hashes of the unchanged
local artifacts, not hashes of redacted copies. Local raw data is ignored by Git.

The initial CMake 4.4.3 experiments are retained locally but excluded from pinned-series
statistics. Their CPU-utility samples mixed build/clean/install and are not used as
build-only utilization. An experimental `TrackFileAccess=false` run triggered a large
rebuild during installation; it is not recommended as a measured end-to-end improvement.

## Matched Ninja worker-count follow-up

The initial generator comparison used 12 jobs as one explicit setting, not as a proven
optimum. A subsequent study compares that setting with **no parallel option**. The
configured Ninja 1.12.0 executable reports a default of **14 jobs** on this machine.

`run_parallelism_study.ps1` uses one configured Ninja tree and the unchanged measured
`run.ps1`. It records the Ninja binary/build-graph hashes and checks that neither
changes between runs. It uses four repetitions of each condition in **ABBA BAAB**
order (A = explicit 12, B = implicit default 14), always with 30 seconds of rest before
each run. Adjacent pairs therefore have AB, BA, BA, AB ordering; both conditions have
the same mean position in the sequence. This balances simple time/order trends but
does not eliminate thermal or cache carryover.
There was no separately discarded warm-up run or continuous thermal measurement;
the first sample remains part of the primary results.

The report gives both group mean/median/range/standard deviation and adjacent paired
time differences. Negative `default_minus_fixed_seconds` means the default was faster.
Ninja log interval overlap checks the observed peak command concurrency; it is not a
CPU-utilization measurement. The toolchain, definitions, runner hash, command count
and actual command-line arguments are verified for every successful run.

Keep this series separate from the earlier generator comparison. The hypothesis is
that 12 jobs takes less wall time than the default 14; it is not an assumption or a
claim about energy use. With four observations per condition and an uncontrolled
normal-use machine, conclusions remain workload- and machine-specific.

## Optional native Clang experiment

`-Toolchain Clang` selects a separate CMake/Ninja tree with native Windows ARM64
LLVM tools and GNU-style compiler drivers. It retains the pinned source, all 23
Windows HOBL definitions, and the same clean/build/install timing boundaries.
The default MSVC/MSBuild path is unchanged. Compiler/linker/archiver executable
architectures and hashes are checked, and installed executables must be native.

The toolchain study runs **MSVC/Clang/Clang/MSVC**, both with Ninja and 12 explicit
jobs on the measured machine, and 30-second rests. Runner, Ninja and per-toolchain
build-graph hashes must remain stable. The two configured build graphs need not be
identical: Clang's detected instruction support and generated flags differ from
MSVC's. This compares toolchain configurations, not just compiler executables.
The pilot and the separate return-to-default MSBuild run are excluded from the
matched comparison. These are warm-cache clean builds, not cold-machine tests.

Clang uses LLVM LLD and standard template parsing, but still targets the Windows
MSVC ABI, SDK, headers and runtime. HOBL's macOS scenario uses Make and normally
Apple Clang, and has different OpenCV options. No macOS hardware or Apple SDK is
used here. See [the experiment report](CLANG_EXPERIMENT.md) for results and limits.

## Latest Microsoft toolchain experiment

The optional `MSVC2026` profile retains the original MSBuild-based workload but
uses VS 2026/MSBuild 18 and its released native MSVC compiler. CMake must also
change because 4.1.1 lacks the VS 2026 generator; both CMake versions remain
installed side-by-side. Thus this is a complete build-stack variant, not an
isolated compiler-version test or an equivalent official HOBL score.

The shared toolchain-study runner preserves the Clang study's Ninja defaults,
while `-CandidateToolchain MSVC2026` selects MSBuild and no explicit parallelism
option. It balances original/new/new/original order and checks generated project
hashes and setup receipts. See [the experiment report](VS2026_EXPERIMENT.md),
including the verified soft-reboot investigation and explicit pre-restart state.
