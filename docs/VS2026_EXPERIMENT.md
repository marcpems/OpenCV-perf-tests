# VS 2026 / latest Microsoft tools experiment

**Status, 2026-10-15: preparation complete; performance measurements blocked by
the installer's required Windows restart. No VS 2026 OpenCV build timings or
speedup claims are available yet.** A full build/install and new-library smoke
check remain to be performed after restart.

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
the new comparison therefore needs fresh control measurements after restart.

The installer exited **3010**, meaning installation succeeded but Windows must
restart to finish it. No automatic restart was attempted. A local installation
receipt records that requirement and the current boot timestamp; benchmark entry
points reject measurements until a subsequent boot. `vswhere` reported the
instance complete and did not flag a reboot, so the bootstrapper's explicit 3010
result is retained rather than silently ignored.

## Workload and planned measurement

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
rests. Runner/helper hashes, setup receipts and generated solution/project hashes
must remain unchanged. Compiler, linker, MSBuild and CMake hashes are checked by
the runner when recorded in the receipt. Output runs retain the same HOBL timing
semantics, install/version/native-PE checks and failure handling as other variants.

This is an **original-versus-updated Microsoft build-stack comparison**. CMake,
MSBuild, compiler and compiler-generated flags may all differ. It will not isolate
one component's causal effect, and previous-day Clang samples must not be treated
as a matched comparison against these new runs.

## Preparation checks and compatibility

Both MSBuild configurations generated successfully. CMake's untimed MSBuild
version probe matched the selected native build engine for each installation.
The PowerShell checks cover generator defaults/rejections, four-way build-tree
isolation, version pins, native PE checks and the restart guard; Python regression
tests passed. Existing MSVC/Ninja and Clang libraries still passed their untimed
functional smoke checks after the script changes.

OpenCV 4.10 emits a configuration warning that it does not recognize
`MSVC_VERSION 1951` and cannot assign its historical `OpenCV_RUNTIME` folder label.
It also emits newer-CMake developer warnings. Configuration succeeds, but a complete
new-toolchain build and runtime validation have **not** yet been established.
No OpenCV source patch or warning-suppression workaround was added. The smoke
script discovers the concrete installed CMake package instead of assuming a
`vc17`/`vc18` installation folder.

## Run after restarting Windows

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
