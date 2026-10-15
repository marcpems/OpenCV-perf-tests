# VS 2026 / latest Microsoft tools experiment

This compares the original VS 2022/MSBuild configuration with the released
VS 2026/MSBuild stack on the same Windows ARM64 machine. The original default is
preserved. The source, HOBL definitions and timing boundaries remain unchanged;
the compiler, build engine and CMake versions change together.

**SDK scope clarification:** this series retained SDK **10.0.26100.7705**, selected
as target **10.0.26100.0**, in both conditions. It updated the Microsoft compiler
and build engine, not every SDK component. The separate
[latest-SDK follow-up](WINDOWS_SDK_EXPERIMENT.md) compares old/new SDKs using the
same VS 2026 stack; do not pool those measurements with this earlier series.

## Results: no reliable build-time improvement established

Measured on **2026-10-15**, on the same 12-core Snapdragon X2 Elite, 63.48 GiB RAM,
Windows 11 Pro build 28000 machine, with its High performance power scheme unchanged.

| Sequence | Microsoft build stack | Clean Release build |
|---|---|---:|
| 1 | Original VS 2022 | 247.8424 s |
| 2 | VS 2026 | 230.1240 s |
| 3 | VS 2026 | 222.3236 s |
| 4 | Original VS 2022 | 205.5254 s |
| Median | Original VS 2022 | **226.6839 s** |
| Median | VS 2026 | **226.2238 s** |

The updated stack's median was **0.4601 s / 0.20% lower**. That difference is tiny
relative to the observed variation: the original stack ranged over **42.3170 s**.
VS 2026 won the first adjacent pair by 17.7184 s but lost the second by 16.7982 s.
There is **no reliable speedup established**, and these two observations per
condition do not prove population equivalence either.

Both generated solutions contain **37 projects and 1,015 compile-source entries**,
with identical normalized source-entry multisets. These are source items, not
1,015 separate MSBuild command invocations. The installed build information also
matched on enabled OpenCV modules, NEON baseline, NEON_DOTPROD/NEON_FP16 dispatch,
Concurrency parallel framework and normalized Release C++ flags, including
`/MP /O2 /Ob2 /DNDEBUG`.

Both variants completed clean/build/install, returned OpenCV **4.10.0** from native
ARM64 executables, and passed the untimed image/matrix smoke checks. The final
VS 2022 run demonstrates switching back to the original stack.

The VS 2026 compatibility pilot took **276.3678 s** and is deliberately excluded.
It also supplied the live-process module evidence below. There was no separate
matched discarded warm-up for VS 2022. The runs use warm OS caches, not cold-machine
conditions; background activity and temperature were not continuously controlled.

Cleaning took 0.8645-0.9355 s for VS 2022 and 1.6238-1.6986 s for VS 2026.
Installation took 1.9652-2.3262 s and 2.5405-2.5878 s respectively. These phases
are **excluded** from the build metric.

Evidence: [summary and raw runs](../results/2026-10-15-vs2026-comparison/summary.json),
[comparison/workload checks](../results/2026-10-15-vs2026-comparison/comparison.json),
and [functional validation](../results/2026-10-15-vs2026-comparison/validation.json).
Keep the original default: this experiment supports VS 2026 as a working,
reversible option, not a demonstrated build-throughput optimization.

## Released tools installed

The [Microsoft release notes](https://learn.microsoft.com/en-us/visualstudio/releases/2026/release-notes)
and stable release channel identify VS 2026 **18.11.0**, released October 13,
as the current stable release when checked on October 15. The winget package
listing was behind that release, so the signed official stable bootstrapper was
used instead.

| Component | Original control | New option |
|---|---|---|
| Visual Studio Build Tools | 2022, 17.14.37710.0 | 2026, 18.11.12306.390 |
| MSVC compiler | 19.44.35229.0 | 19.51.36260.0 |
| VC toolset directory | 14.44.35207 | 14.51.36231 |
| MSBuild | 17.14.60.43110 | 18.11.0.47511 |
| CMake | 4.1.1 | 4.4.4 |
| Generator | Visual Studio 17 2022 | Visual Studio 18 2026 |
| Windows SDK selected | 10.0.26100.0 | 10.0.26100.0 |
| Compiler host / target | Native ARM64 / ARM64 | Native ARM64 / ARM64 |

Visual Studio/MSBuild major version **18** is not the compiler's version number:
the new compiler identifies itself as **19.51**, with the **v145** platform toolset.
The actual versions, executable hashes, configure arguments and selected installation
are recorded in each setup receipt.

The [VS 2026 CMake generator](https://cmake.org/cmake/help/latest/generator/Visual%20Studio%2018%202026.html)
requires CMake 4.2 or later; the original 4.1.1 cannot generate these projects.
The latest stable [CMake release checked](https://github.com/Kitware/CMake/releases/tag/v4.4.4)
was 4.4.4. Its ARM64 zip and the VS bootstrapper are checksum-pinned in
[`toolchains/vs2026.json`](../toolchains/vs2026.json). The VS bootstrapper also
passed Microsoft Authenticode verification.

VS servicing channels are mutable: a pinned bootstrapper does not guarantee that
its future component downloads remain at the same release. Setup checks the
recorded VS/compiler/MSBuild versions and fails on a mismatch; deliberately update
the manifest and report before comparing another release.

## Isolation and reversibility

The new installation is at
`C:\Program Files\Microsoft Visual Studio\2026\BuildTools`.
VS 2022 remains at its original location, and its compiler SHA-256 was verified
unchanged after installation. Portable CMake 4.4.4 lives under the repository's
ignored `.tools` directory; CMake 4.1.1 remains available for existing experiments.
No persistent PATH switch is made.

The build tree is `build_hobl_msvc2026`, separate from all three existing trees.
`-Toolchain MSVC2026` requires MSBuild and rejects an explicit Ninja generator.
Omitting the option still selects VS 2022/MSBuild. The Microsoft installer may
update shared setup/runtime components even though the VS instances are separate;
the comparison therefore uses fresh control measurements rather than yesterday's
baseline numbers.

### Resolving the installer restart warning

The bootstrapper exited **3010**. Initially this was treated as a hard measurement
block, but the package logs established a more specific result:

- The x64 VC redistributable returned 3010, but Microsoft's own wrapper verified
  updated files and a consistent installation, then converted it to
  **862968 (`NS_S_REBOOT_RECOMMENDED`)**.
- That was the only nonzero package-success return code; the others were zero.
- `vswhere` reported the instance complete, with `isRebootRequired=false`.
- System `vcruntime140.dll`, `msvcp140.dll` and `concrt140.dll` were already
  **14.51.36247.0** on disk.
- During the pilot, actual native compiler processes loaded **cl/c1xx/c2
  19.51.36260.0** and the compiler's own **14.51.36260.0** runtime libraries
  from the new toolset directory. Native MSBuild identified as **18.11.0.47511**.

The snapshot includes a [redacted installer excerpt](../results/2026-10-15-vs2026-comparison/restart_installer_excerpt.log)
and [captured process/module versions](../results/2026-10-15-vs2026-comparison/active_process_modules.json).
MSBuild's CLR-specific runtime is separate from the compiler's bundled VC runtime;
no claim is made that every loaded system DLL has the VC redistributable's version.

Thus this was a verified **soft reboot recommendation**, not missing compiler
files or an incomplete VS instance. No reboot, process termination or system
restart-flag modification was performed. All measured builds start fresh child
processes; existing applications may still benefit from the recommended restart.
These are explicitly **pre-restart measurements**, not post-restart confirmation.

The runner retains a conservative default for unresolved 3010 requests. This
installation has a reviewed `verified-soft-reboot` assessment in its local receipt.
Before each run, it verifies the VS instance/version and the assessed runtime
hashes, warns explicitly, and records the assessment and reboot state in metadata.
Runtime drift or an incomplete/reboot-required VS instance invalidates that exception.
The assessment receipt is also frozen by the study's hash checks. There is no
unconditional "ignore reboot" switch or automatic assumption that every 3010 is soft.

## Workload and measurement

Keep the same pinned OpenCV 4.10.0 source and all 23 Windows HOBL definitions.
Do not upgrade OpenCV, remove modules, change optimization settings manually,
or switch to Ninja. Both conditions use:

```powershell
# Untimed clean:
cmake --build . --target clean --config Release
# Timed build:
cmake --build . --config Release
# Untimed install and installed-executable validation:
cmake --build . --target INSTALL --config Release
```

There is no explicit project-worker override. Generated OpenCV projects still
use `/MP`; neither condition should be described as single-threaded.

`run_toolchain_study.ps1 -CandidateToolchain MSVC2026` schedules
**VS 2022 / VS 2026 / VS 2026 / VS 2022**, in fresh child shells with 30-second
rests. Runner/helper hashes, setup receipts and generated project hashes
must remain unchanged. Compiler, linker, MSBuild and CMake hashes are checked by
the runner when recorded in the receipt. Output runs retain the same HOBL timing
semantics, install/version/native-PE checks and failure handling as other variants.

CMake 4.4.4 generates **`OpenCV.slnx`**, whereas the original generates `OpenCV.sln`.
The measured script hashed all generated C++ projects and the original `.sln`;
the `.slnx` solution and both source inventories were inspected separately after
the study. The current runner additionally hashes `.slnx` files, with regression
coverage for that format. The exact [measured study script](../results/2026-10-15-vs2026-comparison/measured_study.ps1)
is retained rather than retroactively claiming the extra guard was used.

This is an **original-versus-updated Microsoft build-stack comparison**. CMake,
MSBuild, compiler and compiler-generated flags may all differ. It will not isolate
one component's causal effect, and previous-day Clang samples must not be treated
as a matched comparison against these new runs.

## Preparation checks and compatibility

Both MSBuild configurations generated successfully. CMake's untimed MSBuild
version probe matched the selected native build engine for each installation.
The PowerShell checks cover generator defaults/rejections, four-way build-tree
isolation, version pins, native PE checks, unresolved-restart blocking and verified
soft-reboot/runtime-drift handling. Mock-build protocol tests exercise both study
orders and default job settings. Python regression tests passed. Existing
MSVC/Ninja and Clang libraries also passed their untimed functional smoke checks.

OpenCV 4.10 emits a configuration warning that it does not recognize
`MSVC_VERSION 1951` and cannot assign its historical `OpenCV_RUNTIME` folder label.
It also emits newer-CMake developer warnings. These did not prevent the full
build, installation, native version check or image/matrix smoke test. No OpenCV
source patch or warning-suppression workaround was added. The smoke script
discovers the concrete installed CMake package instead of assuming a `vc17`/`vc18`
installation folder.

## Reproduce

From the repository root:

```powershell
pwsh -NoProfile -File scripts\setup.ps1
pwsh -NoProfile -File scripts\setup.ps1 -Toolchain MSVC2026
pwsh -NoProfile -File scripts\run_toolchain_study.ps1 -CandidateToolchain MSVC2026
pwsh -NoProfile -File tests\smoke_opencv.ps1 -Toolchain MSVC -Generator MSBuild
pwsh -NoProfile -File tests\smoke_opencv.ps1 -Toolchain MSVC2026
python scripts\export_results.py results\local\vs2026-comparison results\<new-snapshot>
```

Use a fresh `-ResultsDir` for subsequent studies. Export only a completed study,
then report individual times, medians/ranges and the exact toolchain differences.
The final original-toolchain run also exercises switching back.
