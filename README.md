# OpenCV perf tests

Standalone Windows reproduction of Microsoft's **HOBL OpenCV build-time workload**,
with local measurements and build-cost analysis. This compiles **OpenCV 4.10.0** with
**CMake 4.1.1 / Visual Studio 2022**. HOBL intentionally sets
`BUILD_PERF_TESTS=OFF`; a separate, opt-in runtime screen compares the resulting
libraries without changing the build-time workload.

**Start here: [Combined investigation report — findings, exact MSBuild proposal,
MSVC follow-ups and runtime limits (18 October 2026)](docs/INVESTIGATION_REPORT.md).**

**[Timing results and recommendations](docs/ANALYSIS.md)** |
**[Matched 12 vs default 14 jobs study](docs/NINJA_PARALLELISM.md)** |
**[Native ARM64 Clang experiment](docs/CLANG_EXPERIMENT.md)** |
**[VS 2026 / latest Microsoft tools experiment](docs/VS2026_EXPERIMENT.md)** |
**[Latest Windows SDK comparison](docs/WINDOWS_SDK_EXPERIMENT.md)** |
**[LLVM vs MSVC: CPU time and WPR/ETL investigation](docs/CPU_ETL_ANALYSIS.md)** |
**[MSBuild serial-tail investigation and scheduler experiment](docs/MSBUILD_SERIAL_TAIL.md)** |
**[MSBuild project + shared-compiler parallelism](docs/MSBUILD_SHARED_PARALLELISM.md)** |
**[Fresh five-configuration rerun after device change](docs/FIVE_CONFIGURATION_RERUN.md)** |
**[Compiler gap: native execution, microbenchmarks and source patterns](docs/COMPILER_GAP_INVESTIGATION.md)** |
**[Targeted runtime comparison of the resulting OpenCV libraries](docs/RUNTIME_SCREENING.md)** |
**[Minos self-hosted runner validation](docs/MINOS_RUNNER.md)** |
**[Minos build and runtime results](docs/MINOS_RESULTS.md)** |
**[Custom LLVM comparison: 10.23% less build time](docs/CUSTOM_LLVM_COMPARISON.md)** |
**[HOBL survey, equivalence and measurement methodology](docs/METHODOLOGY.md)**

The baseline preserves HOBL's clean -> timed Release build -> install -> version-check
sequence and all 23 CMake definitions. `scenario_runtime` and `build_time` are the
build-only wall time in seconds; configuration, cleaning and installation are excluded.
The source revision and HOBL reference are pinned in [`benchmark.json`](benchmark.json).

The **latest five-configuration rerun** measured medians of **215.12 s** for
original MSBuild, **195.29 s** for compiler-only MultiToolTask, **187.67 s** for
shared-parallel MSBuild, **173.00 s** for MSVC/Ninja and **99.37 s** for LLVM/Ninja.
Each configuration ran twice after a reported device configuration change.
These are a separate snapshot; older results below remain historical.
See the [fresh comparison and reproduction command](docs/FIVE_CONFIGURATION_RERUN.md).

## Prerequisites

- Native PowerShell 7, Git, and Visual Studio **2022** C++ tools for the native
  architecture (ARM64 or x64), including a Windows SDK. The measured machine used
  native ARM64 MSVC 19.44.35229 and SDK target 10.0.26100.0
  (servicing release 10.0.26100.7705).
- CMake **4.1.1**. A newer system installation is left untouched; use a portable copy.
- Ninja for the optional alternative-generator experiments; Python 3.10+ for analysis.
  Neither is required by the MSBuild baseline itself.

Install a missing SDK through the Visual Studio Installer or, as used locally:

```powershell
winget install --id Microsoft.WindowsSDK.10.0.26100 --source winget
```

From the repository root, install portable CMake without replacing system tools:

```powershell
$arch = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
$release = 'https://github.com/Kitware/CMake/releases/download/v4.1.1'
$name = "cmake-4.1.1-windows-$arch.zip"
New-Item -ItemType Directory -Force .tools | Out-Null
Invoke-WebRequest "$release/$name" -OutFile ".tools\$name"
Invoke-WebRequest "$release/cmake-4.1.1-SHA-256.txt" -OutFile .tools\SHA256.txt
$line = Get-Content .tools\SHA256.txt | Where-Object { $_ -match [regex]::Escape($name) + '$' }
$expected = ($line -split '\s+')[0]
if ((Get-FileHash ".tools\$name").Hash -ne $expected) { throw ' ERROR - CMake checksum mismatch.' }
Expand-Archive ".tools\$name" .tools
```

The measured ARM64 archive's SHA-256 is
`1d968879344bcdd29ddeaa3480ea6e7716db0de518b220743b82c7f1750b5c9b`.
The checksum file is fetched from the same official release, not an independent trust authority.

## Run the HOBL-equivalent baseline

```powershell
pwsh -NoProfile -File scripts\setup.ps1
pwsh -NoProfile -File scripts\run.ps1 -Label baseline_1
pwsh -NoProfile -File scripts\run.ps1 -Label baseline_2
```

Setup defaults to `<script-drive>\opencv` and creates `build_hobl_msvc` beneath it.
Pass `-Root <absolute-source-directory>` to **both** scripts to choose another source
location. An existing checkout must already match the pinned, unmodified tag; the
scripts will not reset user changes. Pass `-CMake <path-to-cmake.exe>` to setup to use
another copy of the pinned version.

Setup now explicitly pins SDK/UCRT target 10.0.26100.0 for all historical profiles,
rather than selecting whichever SDK was installed last. Run setup again after
updating these scripts: legacy receipts without SDK selection are rejected.
Setup uses CMake `--fresh` to regenerate the cache and compiler probes without
deleting the source or installed libraries. SDK servicing versions and selected
tool/header/library hashes are recorded; target 10.0.26100.0 alone does not pin
every servicing release within that SDK family.

The baseline's timed command is exactly:

```powershell
cmake --build . --config Release
```

It has no explicit MSBuild `/m` switch, but the generated projects already use
compiler `/MP`. **Do not describe this as a single-threaded baseline.**

## Diagnostic variants

Run these sequentially, not concurrently:

```powershell
# Extra project-level parallelism: a labeled departure from the baseline command.
pwsh -NoProfile -File scripts\run.ps1 -Label msbuild12_1 -Parallel 12

# Alternative build system, same source/options/native compiler, not an official HOBL score.
pwsh -NoProfile -File scripts\setup.ps1 -Generator Ninja
pwsh -NoProfile -File scripts\run.ps1 -Generator Ninja -Parallel 12 -Label ninja12_1

# Separate instrumented baseline, not pooled with uninstrumented samples.
pwsh -NoProfile -File scripts\run.ps1 -Label baseline_profile -Profile

# Optional process-tree CPU accounting; WPR capture requires an elevated shell.
pwsh -NoProfile -File scripts\run.ps1 -Label baseline_cpu -MeasureCpu
pwsh -NoProfile -File scripts\run.ps1 -Label baseline_etl -Trace
```

The [CPU/ETL investigation](docs/CPU_ETL_ANALYSIS.md) measured **210.80 s wall /
1,716.12 CPU s** for original MSBuild versus **94.90 s / 893.90 CPU s** for LLVM.
With Ninja held constant, LLVM used **50.87% less CPU time**. WPR exposed both a
45-second serialized MSBuild compilation tail and substantial MSVC backend cost.
Raw ETLs stay local; only sanitized build-specific evidence is published.
`-Trace` implies `-MeasureCpu`; neither can be combined with `-Profile`.

The [serial-tail follow-up](docs/MSBUILD_SERIAL_TAIL.md) identifies 34 single-file
CL tasks plus repeated dependency-table construction. Opt-in
`-MSBuildScheduler MultiToolTask -CompilerJobs 12` removes that serial task
structure, but saves **13.15 s / 6.52%** in balanced whole-build measurements,
not the entire 45-second tail. It costs **7.25% more CPU** through a different
process/scheduling model. Omit the option to retain the HOBL default.
`-BinaryLog` captures local-only MSBuild task/command evidence and is independent
of `-Trace`; do not publish raw binlogs.

The [full-parallelism follow-up](docs/MSBUILD_SHARED_PARALLELISM.md) adds
`-SharedCompilerLimit -Parallel 12` to MultiToolTask's `-CompilerJobs 12`.
It measured **180.94 s**, versus **176.75 s for a fresh MSVC/Ninja control** and
**205.36 s for fresh compiler-only MultiToolTask**. The 2.37% median gap to Ninja
had overlapping ranges and mixed pair results; no reliable winner is established.
WPR verified a peak of **12 compiler processes across all MSBuild workers**.
Run `scripts\run_msbuild_parallelism_study.ps1` for the balanced six-build comparison.

Ninja uses its own `build_hobl_ninja` tree. Both generators clean outside the timer,
build, install and validate the installed executable. The default `-Parallel 0`
means **do not pass a parallelism argument**, not zero workers.

### Compare an explicit job count with Ninja's default

On the measured 12-core machine, Ninja 1.12.0 defaults to **14 jobs**, not 12.
Choosing 12 for the initial generator comparison did not establish it as optimal.
The [matched follow-up](docs/NINJA_PARALLELISM.md) found only a 0.59% median advantage
for 12, with much larger run variation: **no reliable advantage over 14 was established**.
Run a matched comparison without changing the source, compiler or build tree:

```powershell
pwsh -NoProfile -File scripts\run_parallelism_study.ps1 -FixedJobs 12
python scripts\compare_parallelism.py results\local\ninja-job-study
```

The study runs four clean builds per setting in balanced **12/default/default/12,
default/12/12/default** order, with 30 seconds between builds. It records the actual
Ninja default and verifies that the executable and generated build graph stay
unchanged. The comparison checks run arguments, setup equality, compile counts,
and observed command concurrency. This measures **wall time**, not power or energy.
Use a new `-ResultsDir` for another study; existing data is never overwritten.

## Optional native ARM64 Clang toolchain

This is a reversible Windows experiment, **not an official HOBL score or a macOS
build**. It uses the GNU-style `clang` / `clang++` drivers, CMake + Ninja, and LLVM
LLD instead of MSVC/MSBuild. The Windows SDK and MSVC headers/runtime are still
required. The default remains MSVC + MSBuild.

With the prerequisites above plus `7z` (7-Zip) on PATH:

```powershell
# Portable LLVM 23.1.3, latest stable when checked on 2026-10-14.
pwsh -NoProfile -File scripts\install_clang.ps1
pwsh -NoProfile -File scripts\setup.ps1 -Toolchain Clang
pwsh -NoProfile -File scripts\run.ps1 -Toolchain Clang -Parallel 12

# Switch back: no toolchain flag means the original MSVC + MSBuild setup.
pwsh -NoProfile -File scripts\setup.ps1
pwsh -NoProfile -File scripts\run.ps1 -Label baseline_restored
```

Clang automatically selects Ninja; explicitly combining it with MSBuild is rejected.
Its isolated `build_hobl_clang_ninja` directory does not overwrite either MSVC build
tree. The checksum-pinned LLVM distribution lives under `.tools`; neither the global
LLVM installation nor the persistent PATH is changed. To deliberately use another
native Windows LLVM distribution, pass `-LLVMRoot <directory>` to Clang setup.

The [experiment report](docs/CLANG_EXPERIMENT.md) explains the Clang-only
`-fno-delayed-template-parsing` compatibility flag, optimization/CPU-dispatch
differences, and why this is not an Apple Clang comparison.

For a balanced comparison against MSVC using the **same Ninja and job limit**:

```powershell
pwsh -NoProfile -File scripts\setup.ps1 -Generator Ninja
pwsh -NoProfile -File scripts\setup.ps1 -Toolchain Clang
pwsh -NoProfile -File scripts\run_toolchain_study.ps1 -Parallel 12
python scripts\export_results.py results\local\clang-comparison results\<new-snapshot>
```

The study uses MSVC/Clang/Clang/MSVC order, fresh child shells, and 30-second rests.
Choose a fresh `-ResultsDir` for each repeat. Do not pool its timings with the earlier
generator or worker-count studies.

After successful installation, these small functional checks compile a native client
with CMake and exercise image conversion, filtering, resizing and matrix multiplication.
They are outside all benchmark timers and are not the full OpenCV test suite:

```powershell
pwsh -NoProfile -File tests\smoke_opencv.ps1 -Toolchain Clang
pwsh -NoProfile -File tests\smoke_opencv.ps1 -Toolchain MSVC
```

Both checks use the corresponding **Ninja** build's installed package.

## Optional VS 2026 / latest Microsoft build tools

`-Toolchain MSVC2026` selects **MSVC + MSBuild**, not Ninja or Clang, in an isolated
`build_hobl_msvc2026` tree. The release pins checked on 2026-10-15 are VS 2026
18.11.0, MSVC 19.51.36260.0 (toolset 14.51.36231), MSBuild 18.11.0.47511, and
native ARM64 CMake 4.4.4. The baseline remains VS 2022 with CMake 4.1.1.

The matched local series measured **226.22 s median for VS 2026 versus 226.68 s
for VS 2022**. The 0.20% difference was much smaller than run variation, so
**no reliable build-time improvement was established**. Both variants built,
installed and passed functional smoke checks.

The installer returned 3010, but investigation showed Microsoft's runtime wrapper
had classified this as a **soft reboot recommendation**, with updated files and
a consistent installation. VS reported no required reboot. Fresh-process builds
were therefore allowed after recording and checking that evidence; see the
[report](docs/VS2026_EXPERIMENT.md) for the measured machine state and results.
Unverified restart requests still block measurement. The scripts never restart
the computer automatically.

```powershell
# Elevated native ARM64 PowerShell; preserves the separate VS 2022 installation.
pwsh -NoProfile -File scripts\install_vs2026.ps1
# Resolve any required restart before benchmarking, then:
pwsh -NoProfile -File scripts\setup.ps1
pwsh -NoProfile -File scripts\setup.ps1 -Toolchain MSVC2026
pwsh -NoProfile -File scripts\run_toolchain_study.ps1 -CandidateToolchain MSVC2026
pwsh -NoProfile -File tests\smoke_opencv.ps1 -Toolchain MSVC -Generator MSBuild
pwsh -NoProfile -File tests\smoke_opencv.ps1 -Toolchain MSVC2026
```

The study uses original/2026/2026/original order and 30-second rests. Neither
condition passes an explicit parallelism option by default, matching HOBL's command;
OpenCV's generated `/MP` still enables compiler parallelism. A new CMake is required
for the VS 2026 generator, so this compares **build stacks**, not the compiler alone.
Use a fresh `-ResultsDir` for a repeat. The Clang study retains its previous
Ninja/explicit-job defaults.

Run only the new variant with `run.ps1 -Toolchain MSVC2026`.
Omit the toolchain option to return to the original VS 2022/MSBuild baseline.
See [release provenance, compatibility caveats and status](docs/VS2026_EXPERIMENT.md).

### Latest SDK with the current Microsoft compiler

`-Toolchain MSVC2026Latest` uses the same released VS 2026/MSVC/MSBuild/CMake
versions, but selects **Windows SDK 10.0.28000.2957** instead of the historical
**10.0.26100.7705** SDK. Its separate tree is `build_hobl_msvc2026_latest`.
The SDK installer installs native ARM64 desktop C++ components side-by-side,
checks its SHA-256/Microsoft signature, disables automatic restart, and records
the exit code. An unresolved SDK restart request blocks measurement.

The four-runs-per-condition comparison measured **238.36 s median with the
latest SDK versus 233.84 s with the old SDK**: **1.93% more time**, with overlapping
run variation and no demonstrated speedup. A between-run PowerShell hang required
recovery before the final pair; the longer rest and sensitivity analysis are
disclosed in the [report](docs/WINDOWS_SDK_EXPERIMENT.md).

```powershell
# Elevated native ARM64 PowerShell; install the missing latest components.
pwsh -NoProfile -File scripts\install_vs2026.ps1
pwsh -NoProfile -File scripts\install_windows_sdk.ps1
pwsh -NoProfile -File scripts\setup.ps1 -Toolchain MSVC2026
pwsh -NoProfile -File scripts\setup.ps1 -Toolchain MSVC2026Latest

# Single latest-stack run:
pwsh -NoProfile -File scripts\run.ps1 -Toolchain MSVC2026Latest

# Matched SDK comparison: four clean builds per condition, ABBA BAAB.
pwsh -NoProfile -File scripts\run_toolchain_study.ps1 -CandidateToolchain MSVC2026Latest -Blocks 2
python scripts\compare_sdk.py results\local\vs2026-sdk-comparison --source-root D:\opencv
pwsh -NoProfile -File tests\smoke_opencv.ps1 -Toolchain MSVC2026Latest
```

Both SDK and UCRT selection are checked in evaluated MSBuild properties. Ninja
and smoke clients also use their profile's SDK rather than the newest installed
one. The existing `MSVC2026` option retains the old SDK; no toolchain option still
means the original VS 2022 baseline. The [SDK report](docs/WINDOWS_SDK_EXPERIMENT.md)
documents the discarded warm-ups, measured results and limitations.

## Result artifacts

Raw local outputs go to `results\local\<timestamp>_<label>` (ignored by Git).
Each completed run contains:

- HOBL-style `opencv_build_results.csv` and `.trace`, plus separate clean/build/install logs.
- `metadata.json`: success/failure, precise timings, revisions, native compiler hash,
  configuration, CPU/RAM/OS and power scheme.
- `CMakeCache.txt`, configuration log, installed OpenCV version and verbose build information.
- For Ninja, a fresh `ninja_log.txt` with per-command timings.

```powershell
python scripts\analyze_ninja_log.py results\local\<ninja-run>\ninja_log.txt
python scripts\export_results.py results\local results\<new-public-snapshot>
```

Export includes only successful, version-validated runs, redacts user-profile paths,
and creates per-run analysis plus `summary.json`. Keep diagnostic labels separate
from baseline labels; numeric suffixes such as `_1` / `_2` group repeats.

Ninja's summed step durations are **elapsed times with overlap**, not CPU time.
The analyzer deduplicates multi-output link commands and rejects historical/reordered
logs. See the methodology before interpreting module percentages or concurrency.

## Runner checks

```powershell
python -m unittest discover -s tests -v
pwsh -NoProfile -File tests\test_runner.ps1
# Optional comparison against a checkout of the pinned HOBL revision:
pwsh -NoProfile -File tests\test_runner.ps1 -HoblRoot <HOBL-checkout>
# After installing the optional VS 2026 / latest SDK profiles:
pwsh -NoProfile -File tests\test_runner.ps1 -VerifyVS2026 -VerifyLatestSDK
```

This is a local build benchmark, not full HOBL DUT preparation or battery/thermal
certification. It does not disable services, change power policy, add security
exclusions or run the unauthenticated remote-control service.

Configuration adapted from [Microsoft HOBL](https://github.com/microsoft/HOBL);
MIT attribution is preserved in [LICENSE](LICENSE). OpenCV and build tools are
downloaded separately and are not redistributed here.
