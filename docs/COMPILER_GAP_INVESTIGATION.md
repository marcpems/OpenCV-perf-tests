# Is the MSVC/LLVM gap really compiler work?

**Yes: native compiler execution reproduces a large difference without a full
OpenCV build, linking or installation.** The evidence points principally to
optimization/code generation and sensitivity to large functions and repeated
inlined accesses, not emulation or a missing OpenCV module.

This investigation followed the **15 October 2026 device-change rerun**:
MSVC/Ninja **173.00 s / 1,779.71 CPU s**, LLVM/Ninja **99.37 s / 932.43 CPU s**.
LLVM takes **42.56% less wall time and 47.61% less CPU** in that full-build series.
The microbenchmarks below are new, separate measurements, not additional
full-build samples.

The subsequent [targeted runtime screen](RUNTIME_SCREENING.md) compares the
resulting baseline, shared-cap and LLVM libraries. Compiler throughput and
generated-code runtime performance are separate questions; the runtime screen
is not a full correctness or application-performance equivalence certification.

## 1. Native execution and workload checks

These checks use the actual compiler commands from the configured Ninja graphs,
not whichever `cl.exe` happens to be on `PATH`.

| Check | Result |
|---|---|
| `cl.exe` PE machine | **`0xAA64`: native ARM64** |
| Loaded MSVC `c1xx.dll` and `c2.dll` PE machines | **Both `0xAA64`** |
| Live compiler `IsWow64Process2` result | **Process machine `0x0000`, native machine `0xAA64`**: not running under WOW emulation |
| Live Clang process and compiler image | Native ARM64, same process/native-machine result |
| Compiler image version flags | MSVC frontend/backend and Clang are not marked as debug images |
| Matching compiled C/C++ units | **1,015**, with identical source-file bytes for every matched unit |
| Extra LLVM unit | Only libpng `arm/filter_neon.S` |
| `cvconfig.h` and `opencv_modules.hpp` | **Byte-identical** between the two configured trees |
| Release/library macros | Both `NDEBUG`, `_MSVC_LANG=201402L`, `_ITERATOR_DEBUG_LEVEL=0`, `_MSVC_STL_HARDENING=0`, `_DLL=1`, `_CPPUNWIND=1` |
| MSVC compatibility macro | Both report `_MSC_VER=1944` |
| Explicit debug-info or LTO flags in executed compile commands | None detected in either configuration |

The MSVC executable is under
`VS 2022\BuildTools\VC\Tools\MSVC\14.44.35207\bin\Hostarm64\arm64`.
The installation's `Program Files (x86)` parent directory does **not** mean its
compiler is x86. The operating system's live-process result and the loaded
frontend/backend images independently confirm native execution.

The versions remain **MSVC 19.44.35229** and **LLVM 23.1.3**, with the same
original Windows SDK/MSVC library setup as the full-build comparison. This is
not a claim about every MSVC or LLVM release.

**Equivalent application workload is not identical compiler semantics.**
The original commands use MSVC `/O2 /Ob2 /EHa /fp:precise` versus Clang `-O3`
and its default exception/FP behavior. Other compiler-generated flags and
preprocessor branches differ. Clang retains the existing
`-fno-delayed-template-parsing` compatibility fix. Feature-header/source checks
rule out missing modules, not every possible difference in generated code.

The [audit evidence](../results/compiler-gap-20261015/audit/workload.json)
records executable/module hashes, actual arguments, live execution results,
source-set checks, feature hashes and macro values.

## 2. Isolated real-source microbenchmarks

Eight source files were compiled one at a time with their actual Ninja flags.
Only object/PDB/dependency output paths were redirected to private directories.
There was one discarded warm-up per source/compiler, then **four observations
per compiler**, alternating forward/reverse compiler order.

These measurements have **no WPR or phase-timing instrumentation**. They count
the compiler command's descendant CPU with the same Windows job-accounting
mechanism as the full-build runs.

| Source | MSVC wall (s) | LLVM wall (s) | MSVC CPU (s) | LLVM CPU (s) |
|---|---:|---:|---:|---:|
| `calib3d/src/dls.cpp` | 4.233 | 1.894 | **5.984** | **1.875** |
| `dnn/src/onnx/onnx_importer.cpp` | 3.003 | 3.211 | **8.906** | **3.180** |
| `dnn/src/net_impl.cpp` | 2.591 | 2.400 | **6.656** | **2.383** |
| `dnn/src/tensorflow/tf_importer.cpp` | 2.539 | 2.904 | **7.125** | **2.891** |
| `core/src/arithm.cpp` | 0.798 | 0.913 | **1.609** | **0.891** |
| `imgproc/src/resize.cpp` | 1.335 | 2.134 | **4.250** | **2.125** |
| `features2d/src/orb.cpp` | 1.295 | 1.076 | **2.328** | **1.055** |
| `core/src/alloc.cpp` | 0.851 | 0.842 | **1.367** | **0.828** |

All values are medians. The sums of these per-file CPU medians are **38.227 s
for MSVC and 15.227 s for LLVM: 2.51 times the CPU work**. The sums of isolated
wall medians are much closer, **16.644 versus 15.374 s**.

That apparent contradiction is important. **MSVC parallelizes optimization
inside an individual compilation.** For ONNX it finishes slightly earlier
while consuming almost three times the CPU. LLVM's CPU is close to its wall
time, indicating approximately one occupied core.

The earlier [WPR thread evidence](CPU_ETL_ANALYSIS.md) found seven materially
CPU-consuming MSVC threads over those focused compiler lifetimes, versus one
for LLVM. That is not a claim that seven threads are always active simultaneously.
The new CPU/wall measurements reproduce the same distinction.

A build already running 12 compiler processes cannot give every MSVC process
several otherwise idle cores. Its extra work becomes a throughput cost.
**Equal process limits do not imply equal total compiler-thread work.**

These are selected probes, including known hotspots and smaller controls, not
a statistically representative sample of all OpenCV files.

## 3. Compiler-only parallel throughput reproduces the scale

A separate Ninja graph compiled **three independent copies of each of those
eight sources: 24 commands, 12 workers**. Each command writes a new object.
There are no library links, installations, CMake regeneration or MSBuild tasks.
One warm-up batch per variant was discarded; four measured observations per
variant used forward/reverse ordering.
Ninja logs confirm exactly **24 compilation commands and a peak of 12
overlapping commands in every batch**, including the warm-ups.

| Compiler-only batch | Median wall (s) | Median CPU (s) |
|---|---:|---:|
| MSVC, unchanged flags | **17.625** | **168.523** |
| MSVC, `/cgthreads1` | **17.095** | **157.914** |
| LLVM, unchanged flags | **7.520** | **63.227** |
| LLVM, adding `-fasync-exceptions` | **7.965** | **71.086** |

LLVM takes **57.33% less wall time** in this selected compiler-only workload.
That is larger than the full-build 42.56% reduction, which is unsurprising
because this set includes several expensive DNN/DLS cases.

The experiment establishes that a difference of this scale exists **inside
compilation alone**. It does not estimate a universal 57% advantage or
substitute these files' weighting for the complete OpenCV workload.

Restricting MSVC's backend to one thread reduces median CPU by **6.30%**, but
changes median wall time by only **3.01%** here, with mixed paired winners.
It does not close the gap and is not yet a justified full-build default.

## 4. Flag and phase controls

A separate two-source diagnostic pilot used `/Bt+` for MSVC and `-ftime-trace`
for Clang, with one warm-up plus two measured observations per variant.
These timings are kept separate from the uninstrumented measurements above.

| Source / setting | MSVC median CPU (s) | LLVM median CPU (s) |
|---|---:|---:|
| DLS, original optimized flags | **5.414** | **1.805** |
| DLS, `/Od /Ob0` versus `-O0` | **0.719** | **0.633** |
| ONNX importer, original optimized flags | **8.898** | **3.117** |
| ONNX importer, `/Od /Ob0` versus `-O0` | **1.570** | **1.141** |

Removing optimization greatly shrinks the difference on both sources.
This is a diagnostic control, **not** a recommendation to ship unoptimized
OpenCV. It also does not make the two compilers' remaining frontend work identical.

Other tested hypotheses:

- **`/O2` versus `-O3`:** changing Clang to `-O2` did not remove the advantage.
  The header-free matched-level example below makes this especially clear.
- **Exception handling:** MSVC `/EHa` supports asynchronous exceptions and is
  not equivalent to ordinary synchronous C++ exceptions. Replacing it with
  `/EHsc` did not consistently reduce compiler CPU in the two-file pilot.
  Adding asynchronous exceptions to LLVM did increase work, but LLVM still
  took **54.81% less wall time than baseline MSVC in the compiler-only batch**.
  Exception-model differences contribute, but do not explain away the gap.
- **Strict aliasing:** adding `-fno-strict-aliasing` to Clang did not eliminate
  the DLS advantage. The measured source-pattern effect cannot simply be
  attributed to Clang having type-based alias analysis enabled.
- **Headers/debug iterators/hardening:** both have release iterator and
  hardening settings, and the header-free experiments below remove STL,
  OpenCV and SDK header parsing from the workload entirely.

`/EHsc` changes behavior and must not be silently substituted into the HOBL
configuration. Microsoft's [exception-model documentation](https://learn.microsoft.com/en-us/cpp/build/reference/eh-exception-handling-model)
also cautions against mixing exception models within a module. The altered
objects in these diagnostic experiments were never installed into OpenCV.

## 5. A concrete OpenCV source pattern: 1,968 explicit matrix assignments

The principal DLS hotspot is
[`cv::dls::cayley_LS_M`](https://github.com/opencv/opencv/blob/71d3237a093b60a27601c20e9ee6c3e52154e8b1/modules/calib3d/src/dls.cpp#L410).
It creates a 120-by-120 matrix and has **1,968 explicit assignments**, repeatedly
calling inline `Mat::at<double>` and `std::vector<double>::operator[]`.

MSVC's undocumented diagnostic `/d2cgsummary` identified this function as its dominant DLS
outlier: **3.059 s** in one diagnostic compilation. The ONNX importer is
different: its report has **4,289 functions** and many smaller outliers, such
as `parseQEltwise` and `buildDispatchMap_ONNX_AI`, rather than one comparable
multi-second function.

To test the DLS access pattern, a **local source copy** changes only that
function to cache the matrix pointer/row stride and the four input-vector
pointers before performing the same assignments in the same order. The
OpenCV checkout is not edited.

A balanced **original / cached / cached / original** study provides four
observations per source/compiler condition, excluding block warm-ups:

| DLS translation unit | MSVC wall (s) | MSVC CPU (s) | LLVM wall (s) | LLVM CPU (s) |
|---|---:|---:|---:|---:|
| Original accessors | **3.877** | **5.523** | 2.234 | 2.180 |
| Cached pointers/stride | **2.597** | **4.094** | 2.043 | 2.023 |

For MSVC that is **33.01% less compilation wall time and 25.88% less CPU** for
this entire source file. Its median backend phase falls from **3.292 to
2.025 s**, while frontend time does not improve.

The isolated function's emitted COFF code section shrinks from **48,420 to
17,316 bytes** under MSVC. LLVM's corresponding section shrinks from
**56,568 to 17,168 bytes**. Those are code-section bytes, potentially including
alignment/literal data, not retired runtime instructions.

**Metric correction:** `/d2cgsummary` prints an `instrs` field. It should not
be presented as a verified intermediate-representation instruction count.
The byte counts above were independently read from the object-file sections.

The original and cached functions produced identical complete matrices for
16 input sets. That supports this particular transformation, not a claim that
the full OpenCV correctness suite or runtime performance has been established.
The candidate remains an experiment, not a production source change.

## 6. Header-free synthetic tests: source shape matters

Original generated probes contain no includes, STL, OpenCV or conditional
compiler-specific source. Both compilers receive exactly the same source bytes.
They fill the same strided matrix using:

- Many explicit stores through inline matrix/vector-like accessors.
- The same explicit stores after caching data pointers and stride.
- A static index table and a small loop performing the same stores.

There are 512, 2,048 and 4,096 stores. Each case has one warm-up plus four
measured observations per compiler; these rows have no phase instrumentation.

| Pattern / stores | MSVC median wall (s) | LLVM median wall (s) |
|---|---:|---:|
| Cached pointers, 512 | **0.186** | 0.315 |
| Cached pointers, 2,048 | 1.564 | **0.816** |
| Cached pointers, 4,096 | 5.925 | **1.907** |
| Inline accessors, 512 | 0.737 | **0.281** |
| Inline accessors, 2,048 | 2.454 | **1.606** |
| Inline accessors, 4,096 | **2.746** | 5.011 |
| Table loop, 4,096 | 0.095 | 0.070 |

**Neither compiler is universally faster.** There are crossover points.
The cached-pointer MSVC case grows from 0.186 to 5.925 s for eight times the
source statements, while LLVM also has an unfavorable large inline-accessor
case. These observations demonstrate nonlinear, source-shape-sensitive
optimizer/code-generation costs, not a proof of a particular asymptotic
complexity or a specific internal heuristic threshold.

A separate phase-instrumented control at **4,096 cached-pointer stores** gives:

| Setting | Median wall (s) | Frontend elapsed (s) | Backend elapsed (s) |
|---|---:|---:|---:|
| MSVC `/O2` | **6.883** | **0.057** | **6.777** |
| LLVM `-O2` | **2.214** | **0.027** | **2.112** |
| LLVM `-O3` | **2.406** | **0.027** | **2.305** |

This is a **3.11x compilation wall-time difference even with both nominally
at O2**, without header/template parsing as a plausible main cause.
The levels still select different implementation-specific optimization pipelines.

The table-loop form compiles quickly for both because thousands of operations
are represented as data plus a small loop rather than a huge straight-line
function. It is not necessarily faster at runtime.

Objects from all nine synthetic cases, under both compilers and the Clang
no-strict-aliasing control, produced the same reference results for four input
sets, including unchanged padding between matrix rows.

## 7. What is established, and what is still unknown

**Established:** the compilers are native; the main application workload is
matched; selected direct compilations and a compiler-only parallel batch
reproduce a large CPU/throughput difference; optimization/backend work accounts
for the dominant difference in controlled examples; and a specific large
OpenCV function is materially improved by changing its access pattern.

This agrees with the earlier WPR evidence: roughly **61-63% of MSVC compiler
leaf-module samples were in `c2.dll`**, with SSA/IR/data-structure helpers among
the hotspots. The DLS trace specifically identified
`SSAHelpers::FindInstructionBlock`. Those are **earlier recordings**, not new
traces of this rerun. The new phase and source-variant measurements provide
independent evidence consistent with them.

**Not established:** one particular MSVC pass or bug explains the entire
42.56% full-build difference; disabling a single option will recover it;
the selected microbenchmark weighting represents all OpenCV sources; or LLVM's
resulting application binaries are universally faster. Public symbols and
elapsed phase diagnostics do not expose enough of MSVC's optimizer to make
those claims.

The practical next targets are compiler-performance reproducers for **large
straight-line accessor-heavy functions** and **DNN's many string/container-heavy
functions**, not PCH tuning or linker substitution as explanations for most of
the gap. Any source rewrite or compiler-option change needs separately measured
runtime/correctness tradeoffs before adoption.

## Reproduction and evidence

The default build configurations remain unchanged. Configure the existing
MSVC/Ninja and Clang/Ninja trees first, then use fresh output directories:

```powershell
pwsh -NoProfile -File scripts\audit_compiler_architecture.ps1 `
    -ResultsDir results\local\fresh-architecture

pwsh -NoProfile -File scripts\run_compiler_microbench.ps1 `
    -ResultsDir results\local\fresh-isolated -Repetitions 4

pwsh -NoProfile -File scripts\run_compiler_batch.ps1 `
    -BaselineStudy results\local\fresh-isolated `
    -ResultsDir results\local\fresh-batch -Jobs 12 -Copies 3 -Repetitions 4

python scripts\prepare_compiler_patterns.py D:\opencv .work\fresh-patterns

pwsh -NoProfile -File scripts\run_dls_access_study.ps1 `
    -CachedSource .work\fresh-patterns\dls_cached.cpp `
    -ResultsDir results\local\fresh-dls-abba

# Run in a PowerShell session for array-valued parameters.
& scripts\run_compiler_microbench.ps1 `
    -Sources @('calib3d/src/dls.cpp', 'dnn/src/onnx/onnx_importer.cpp') `
    -Variants @('msvc', 'msvc_cg1', 'msvc_ehsc', 'msvc_Od',
                'clang', 'clang_O2', 'clang_async', 'clang_O0') `
    -PhaseTiming -Repetitions 2 -ResultsDir results\local\fresh-flags

& scripts\run_compiler_microbench.ps1 `
    -Sources @('calib3d/src/dls.cpp') `
    -SourceOverride .work\fresh-patterns\cached_4096.cpp `
    -Variants @('msvc', 'clang_O2', 'clang') `
    -PhaseTiming -Repetitions 4 -ResultsDir results\local\fresh-pattern

python scripts\analyze_compiler_microbench.py `
    results\local\fresh-isolated results\fresh-isolated-export
```

`-SourceOverride` borrows the named translation unit's compiler options but
compiles the supplied local file instead; it does not compile DLS a second time
or change the configured source tree. For the synthetic suite, iterate over
the nine generated `view_*`, `cached_*` and `table_*` files. Link their measured
objects with `tests\compiler_patterns_check.cpp` for output equivalence.
The generator also writes `validate_dls.cpp` for comparison of the original
and cached matrix functions against the installed OpenCV core library.

Per-study frozen hashes, warm-ups, individual observations, actual commands,
phase summaries and validations are in
[the public evidence snapshot](../results/compiler-gap-20261015).
Generated OpenCV source copies, object/executable files and full Clang time
traces remain local. The only persisted benchmark-runner change outside the
new tools is sharing command extraction/output redirection with the existing
translation-unit profiler.

The machine remained in normal use: no thermal/frequency control, cache purge
or background-service suppression was introduced. Short cases near 0.1 s have
substantial startup/accounting granularity relative to their duration.
Diagnostic phases are elapsed times, not phase CPU totals, and nested Clang
phase totals must not be added together.
