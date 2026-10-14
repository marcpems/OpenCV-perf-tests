# OpenCV perf tests

Standalone Windows reproduction of Microsoft's **HOBL OpenCV build-time workload**,
with local measurements and build-cost analysis. This compiles **OpenCV 4.10.0** with
**CMake 4.1.1 / Visual Studio 2022**. It does **not** benchmark image-processing algorithms:
HOBL intentionally sets `BUILD_PERF_TESTS=OFF`.

**[Timing results and recommendations](docs/ANALYSIS.md)** |
**[Matched 12 vs default 14 jobs study](docs/NINJA_PARALLELISM.md)** |
**[HOBL survey, equivalence and measurement methodology](docs/METHODOLOGY.md)**

The baseline preserves HOBL's clean -> timed Release build -> install -> version-check
sequence and all 23 CMake definitions. `scenario_runtime` and `build_time` are the
build-only wall time in seconds; configuration, cleaning and installation are excluded.
The source revision and HOBL reference are pinned in [`benchmark.json`](benchmark.json).

## Prerequisites

- Native PowerShell 7, Git, and Visual Studio **2022** C++ tools for the native
  architecture (ARM64 or x64), including a Windows SDK. The measured machine used
  native ARM64 MSVC 19.44.35229 and SDK 10.0.26100.0.
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
```

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

## Results and analysis

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
```

This is a local build benchmark, not full HOBL DUT preparation or battery/thermal
certification. It does not disable services, change power policy, add security
exclusions or run the unauthenticated remote-control service.

Configuration adapted from [Microsoft HOBL](https://github.com/microsoft/HOBL);
MIT attribution is preserved in [LICENSE](LICENSE). OpenCV and build tools are
downloaded separately and are not redistributed here.
