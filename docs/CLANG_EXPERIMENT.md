# Native ARM64 Clang experiment

This is a **Windows toolchain-configuration comparison**, not an official HOBL
score, a compiler-only isolation experiment, or a Windows-versus-Mac comparison.
The default remains MSVC + MSBuild; Clang is opt-in and uses its own build tree.

## Toolchain and workload

Measured on the same Snapdragon X2 Elite system: 12 cores/logical processors,
63.48 GiB RAM, Windows 11 Pro build 28000, unchanged High performance power scheme.
Both matched configurations use OpenCV 4.10.0 at the pinned revision, CMake 4.1.1,
Ninja 1.12.0, all 23 Windows HOBL definitions, and **12 explicit workers**.
The job count is a matched experimental setting, not a claimed optimum.

| Property | MSVC control | Clang experiment |
|---|---|---|
| Native host and target | ARM64 Windows | ARM64 Windows |
| C++ compiler | MSVC 19.44.35229.0 | LLVM Clang 23.1.3 |
| Driver | `cl.exe` | `clang++.exe`, GNU frontend, not clang-cl |
| Linker | Microsoft linker | LLVM LLD (`lld-link.exe`) |
| Release optimization | `/O2` | `-O3` |
| SDK / C++ library / ABI | Windows SDK 10.0.26100.0 / MSVC / Windows | Same Windows SDK, MSVC library and ABI |
| Additional detected dispatch | NEON_DOTPROD, NEON_FP16 | Also NEON_BF16 |
| Build directory | `build_hobl_ninja` | `build_hobl_clang_ninja` |

LLVM 23.1.3 was the latest stable upstream release when checked on **2026-10-14**.
The [official ARM64 Windows release](https://github.com/llvm/llvm-project/releases/tag/llvmorg-23.1.3)
is pinned in [the toolchain manifest](../toolchains/clang-arm64.json), including its
archive SHA-256. Compiler output reports source commit
`0d261d1ca552c95a8f007e061c787ac7132fbcbc` and target
`aarch64-pc-windows-msvc`. LLVM executables have native ARM64 PE headers.
Compiler, linker and LLVM archive tools are hash-checked against setup receipts.
The existing machine-wide LLVM 23.1.2 installation was not replaced.

The archive is portable and installed under `.tools`. Its Zstandard window exceeds
the pinned CMake archive reader's limit, so installation uses 7-Zip to decompress
Zstandard and CMake to extract the resulting tar. Downloads and extraction are
outside the benchmark.

## Why this is closer to Mac, but not the Mac test

HOBL's macOS scenario normally detects Apple Clang and uses CMake + **Make** with
one worker per logical CPU. This experiment adopts native LLVM and GNU-style Clang
drivers, but deliberately keeps Ninja on both Windows configurations to avoid a
simultaneous build-system change. CMake remains pinned for HOBL reproducibility.

It does not use Apple Clang, Apple's SDK/linker, libc++, or Mach-O binaries. The
Windows SDK, MSVC headers/CRT, Windows ABI, and COFF/PE outputs remain. HOBL's Mac
scenario also has different OpenCV options, including examples enabled and no
explicit world-library option. No Mac hardware was measured.

## OpenCV 4.10 compatibility

The first Clang attempt failed compiling `modules/core/src/softfloat.cpp`.
Windows Clang enables delayed template parsing by default. OpenCV later defines
`cv::float32_t` / `cv::float64_t` software-float aliases; with delayed parsing these
can shadow the scalar typedefs referenced by modern Clang's NEON macros inside
previously declared intrinsic templates. The diagnostic was an invalid
`__builtin_bit_cast` to a non-trivially-copyable destination.

Clang setup adds **`-fno-delayed-template-parsing`**, restoring standard lookup,
as used by non-Windows Clang. This fixes the failing translation unit and full
build without patching OpenCV, disabling SIMD, or affecting MSVC.

OpenCV 4.10's installed Windows-package dispatcher also does not identify this
GNU-style Windows compiler layout. Consumers should point `OpenCV_DIR` at the
concrete installed package, `build_hobl_clang_ninja\install\lib`, rather than the
installation root. The smoke script discovers that package directly.

## Measurement protocol

The matched series uses **MSVC / Clang / Clang / MSVC** order, with 30-second rests
before each run. Each runs in a fresh native PowerShell process, cleans outside
the timer, times only the Release build, then installs and requires a native
`opencv_version.exe` reporting 4.10.0. Runner, Ninja, and each configuration's
build-graph hashes must stay unchanged.

The clean-build metric excludes configuration, cleaning, installation, tool
downloads and smoke checks. OS file caches remain warm; there is no reboot,
cache purge, background-service suppression or thermal control. There are only
two measured runs per configuration, so results are local observations rather
than a population confidence interval.

The successful **94.6168 s pilot** is excluded from this comparison, as is the
separate default-MSBuild return-to-MSVC run. Both libraries are also exercised by
an untimed native CMake-built client covering image conversion, blur, resize and
matrix multiplication. This is a functional smoke check, not the full OpenCV
correctness suite or an algorithm-speed benchmark.
The [functional-check evidence](../results/2026-10-14-clang-comparison/validation.json)
records the client source and executable/library hashes; the snapshot includes
the smoke configuration, build and execution logs.

## Results

**Clang used 40.36% less median build time in this matched local series**:
103.0243 s versus 172.7529 s, a 1.68x ratio of MSVC time to Clang time.

| Sequence | Configuration | Build time |
|---|---|---:|
| 1 | MSVC + Ninja, 12 jobs | 162.2078 s |
| 2 | Clang + Ninja, 12 jobs | 105.3804 s |
| 3 | Clang + Ninja, 12 jobs | 100.6682 s |
| 4 | MSVC + Ninja, 12 jobs | 183.2980 s |
| Median | MSVC | **172.7529 s** |
| Median | Clang | **103.0243 s** |

Both Clang observations were faster than both MSVC observations, unlike the small,
inconsistent worker-count difference in the earlier study. Nevertheless, the MSVC
samples themselves differed by 21.09 s; more balanced repetitions and thermal
control are needed to estimate a stable effect size. This does not establish
40.36% as a universal Clang speedup or imply faster generated application code.

Every log reached **12 concurrent commands**. MSVC executed 1,039 commands including
1,015 compilations; Clang executed 1,040 including 1,016 compilations. Counts and
compiled output sets were stable within each toolchain. Clang's extra compilation
is **libpng's `arm/filter_neon.S`**, not a BF16 translation unit. Clang's additional
NEON_BF16 capability is detected, but OpenCV reports **0 dispatched BF16 files**.
These differences, `/O2` versus `-O3`, and compiler-generated flags prevent treating
this as a perfectly identical binary workload.

The [summary](../results/2026-10-14-clang-comparison/summary.json),
[comparison and command counts](../results/2026-10-14-clang-comparison/comparison.json),
and per-run logs/receipts/Ninja analyses contain the underlying evidence.
Keep this series separate from earlier generator/parallelism studies.

## Where the build time goes

Compilation accounts for about **99.45% of summed command elapsed time** under both
toolchains. These durations overlap and include waiting: they are **not CPU seconds
or percentages of wall time**. Below are per-run means across each toolchain's two
samples; the share denominator includes all commands.

| Component | MSVC summed elapsed | Clang summed elapsed | Share of Clang summed elapsed |
|---|---:|---:|---:|
| DNN | 653.70 s | 354.37 s | 29.59% |
| Image processing | 185.09 s | 131.46 s | 10.98% |
| Core | 196.55 s | 120.81 s | 10.09% |
| Calibration / 3D | 177.75 s | 88.11 s | 7.36% |

The main world-DLL link took **3.976-4.738 s with Microsoft link** and
**0.779-0.806 s with LLD**. LLD improves that step substantially, but the roughly
3.6-second mean link difference cannot explain the roughly 69.7-second median
build difference by itself. The primary observed improvement is across compilation.
The Clang post-compilation tail was only 0.78-0.91 s.

For further work, retain this optional Clang configuration as the measured
build-throughput candidate, but run the full relevant correctness/runtime benchmarks
before adopting its binaries in production. Profile **DNN first**, then image
processing and core; a separate instrumented Clang `-ftime-trace` run can distinguish
header/template parsing from optimizer/code-generation costs. Do not mix such an
instrumented run into these timings.

If the goal is an application rather than HOBL equivalence, disabling unused DNN,
model importers or other modules may remove substantial work. That changes the
workload and must be a separately labeled experiment. Likewise, do not enable a
compiler cache and call its warm-cache result the HOBL clean-build score. Nothing
here establishes that 12 workers is better than Ninja's default 14.

## Reproduce or switch back

See the [README commands](../README.md#optional-native-arm64-clang-toolchain).
`setup.ps1 -Toolchain Clang` and `run.ps1 -Toolchain Clang` select the experiment.
Omit `-Toolchain` and `-Generator` to return to the original MSVC/MSBuild path.
Use `-Toolchain MSVC -Generator Ninja` for the matched compiler control.
There is no global compiler switch to undo, and all three build trees are separate.

After the matched series, omitting both options successfully rebuilt, installed
and version-checked the original MSVC/MSBuild configuration in **223.4481 s**.
That [separate return-to-default result](../results/2026-10-14-clang-rollback/summary.json)
is a reversibility check, not another matched compiler-comparison sample.
