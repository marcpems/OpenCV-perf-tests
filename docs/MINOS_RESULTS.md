# Minos build and runtime validation - 16 October 2026

**Minos baseline: 170.534 s; shared-cap MSBuild: 116.368 s; Ninja/LLVM:
64.949 s.** Shared-cap scheduling reduces build wall time by **31.8%**.
Ninja/MSVC is essentially tied with shared-cap MSBuild in this small sample.
LLVM reduces wall time by **61.9% versus the original baseline**.

The runtime screen finished, but **did not pass cleanly**: two descriptor
output checks failed out of 1,872 measured case executions. These failures
prevent an equivalence claim. LLVM improves many selected kernels, while the
single-thread depthwise regression also reproduces on Minos.

## Device and protocol

Runner **MARCPE-D4** reports NVIDIA RTX Spark N1X, 20 CPU cores, 31.7 GiB
usable memory, Windows 11 Pro build 28000, with the checkout/build trees on
D: ReFS. The owner identifies this as the HOBL lab hardware. It is **not** the
earlier 12-core Snapdragon/64 GB Surface Laptop.

OpenCV 4.10.0 / `71d3237a093b60a27601c20e9ee6c3e52154e8b1`; CMake 4.1.1;
native ARM64 MSVC **19.44.35229.0** (toolset directory 14.44.35207),
MSBuild 17.14.60.43110, LLVM 23.1.3, Windows SDK target 10.0.26100.0
(recorded servicing release 10.0.26100.8249). SDK/compiler hashes and actual
commands are in every result receipt. The missing native C++ workload was
installed before measurement; the resulting VS installation reported complete
and no reboot required.

All ten build receipts record **Ultimate Performance**; this workflow did not
change the power plan. Original MSBuild flags are unchanged. Optimized variants
use 20 jobs, versus 12 in the historical Surface study.

Ten clean Release builds, two per configuration, with 30-second rests:
original / MTT / shared / Ninja-MSVC / Ninja-LLVM, then reverse. Fresh runner
processes; build-only wall time excludes configuration, cleaning, installation,
validation and binary snapshots. CPU accounting enabled, no WPR trace.
Two observations and their ranges are not confidence intervals.

## Build results

| Configuration | First / second wall s | Median wall s | Median CPU s | Saving vs original |
|---|---:|---:|---:|---:|
| Original MSBuild | 165.496 / 175.573 | **170.534** | 1,866.445 | Reference |
| MSBuild MTT only | 123.677 / 130.086 | 126.881 | 1,903.664 | 43.653 s / 25.6% |
| MSBuild shared cap | 120.495 / 112.241 | **116.368** | 1,999.258 | 54.166 s / 31.8% |
| Ninja/MSVC | 120.680 / 110.705 | 115.692 | 2,022.633 | 54.842 s / 32.2% |
| Ninja/LLVM | 69.774 / 60.124 | **64.949** | 1,082.750 | 105.585 s / 61.9% |

The baseline median is **16.534 s / 10.74% slower than the supplied 154 s lab
reference**. Neither baseline observation reaches 154 s; it is outside the
observed 165.496-175.573 s range. The median is just outside a descriptive
10% band. Unknown lab variance and full software/power/driver configuration
prevent a statistical equivalence judgment.

With Ninja held constant, LLVM uses **43.86% less wall time and 46.47% less CPU
time than MSVC**, consistent with the earlier compiler-gap investigation.
Shared-cap scheduling increases aggregate CPU use while reducing waiting.
Ninja/MSVC saves only **0.676 s / 0.58%** over shared-cap here, far smaller than
the observed ranges: this is not evidence of an additional material Ninja gain.
These gains are alternatives, not additive.

The preliminary LLVM-first observation was **61.5596 s / 994.2656 CPU s**.
It remains separate and is not pooled into these medians.

## Runtime screen

The three retained DLLs came from `original_2`, `shared_2`, and `clang_2`.
One common MSVC-built upstream harness was used for all three. Its bytes,
loaded-library path, architecture, requested threads and affinity were audited.
No rebuild of the OpenCV libraries was needed for the runtime stage.

Windows reports two efficiency classes across two LLC groups. **CPU 5** is
the first CPU in the highest reported class, and was selected for single-thread
runs and the main thread. Parallel workers retained CPUs 0-19 after warm-up.
This is topology-specific, not a reuse of the Surface CPU-6 assumption.

52 cases, 1/20 threads, six balanced variant orders, alternating thread order,
20 samples per measured case, and a ten-sample baseline sanity pilot.
Runtime setup began **15:46:57 BST**; measurements finished **15:55:05 BST**
(approximately eight minutes including harness setup).

**1,872 measured case executions: 2 failures, 0 skips.** Analysis excludes each
failed case/thread group across *all* variants, leaving 102/104 valid comparison
groups. In particular, the 20-thread descriptor summary contains only 2/4 cases.
The original failed screen is preserved, not replaced by later diagnostics.

Time change versus baseline; negative is faster. Equal-case-weight geometric
means are not application-wide gains:

| Selected area | Shared 1t | Shared 20t | LLVM 1t | LLVM 20t |
|---|---:|---:|---:|---:|
| Core | -1.1% | -2.3% | -10.4% | -10.7% |
| Image processing | +0.2% | -0.8% | -23.3% | -18.1% |
| Pose / PnP | +0.6% | +0.8% | -10.6% | -9.6% |
| Descriptors (20t: 2 valid cases) | -0.5% | +2.7% | -1.1% | -4.3% |
| DNN convolution | -0.2% | +2.1% | -30.0% | -3.7% |

Baseline/shared executable `.text` sections are byte-identical. Of 102 valid
case/thread comparisons, 91 are within 5% and 97 within 10% for shared.
This supports near-baseline speed, **not a clean correctness pass**.

### Output mismatches requiring investigation

- LLVM, round 1, 20 threads:
  `Source_CrossCheck_batchDistance_L2.batchDistance_L2/3`.
  `dist` maximum was **FLT_MAX (3.402823466e38)** rather than the sanity
  reference **0.24995326995849609**.
- Shared cap, round 5, 20 threads:
  `Norm_CrossCheck_batchDistance_Dest_32S.batchDistance_Dest_32S/1`.
  `ndix` minimum was **-1** rather than the sanity reference **0**.

These are output-check failures, not noisy-timing warnings. Both cases enable
nearest-neighbor cross-checking. Upstream `batch_distance.cpp` initializes
distances to FLT_MAX and indices to -1; -1 also represents an unmatched
cross-check result. The observed values are therefore consistent with
unmatched/sentinel results, but **do not identify the root cause**.
The shared failure with byte-identical baseline code means compiler choice
alone is not an established explanation. Investigate test-input repeatability,
multithreaded execution and library behavior before approving equivalence.

**A separate bounded reproduction also failed with the original baseline.**
Using the same frozen DLL/harness bytes and original sanity references, ten
rounds of these two cases at 1/20 threads across all three libraries produced
120 additional case executions. Two checks failed, both baseline/20-thread:
Hamming cross-check index minimum -1 in round 2, and float L2 distance maximum
0.472514212 instead of 0.249953270 in round 8. Shared and LLVM happened to pass
this smaller diagnostic; that does not erase their original failures.
No single-thread check failed in either dataset.

Thus intermittent descriptor output mismatches have now been observed in
**all three variants**, including the unmodified reference. They are not
demonstrated LLVM-specific or shared-scheduler regressions. The evidence points
to a common multithreaded library/test path worth isolating, but does not yet
distinguish a library bug from a harness/input/reference issue.
This diagnostic finished at approximately **16:01:42 BST**, within 15 minutes
of the original runtime-stage start. Its data is not pooled into performance
medians, and no tolerance was loosened to obtain a pass.

### Performance leads

- CPU-5 single-thread depthwise case 3:
  **0.29710 -> 0.33065 ms, +11.29%**, LLVM slower in all six rounds.
  At 20 threads: +2.23%, five rounds slower. This corroborates the earlier
  Surface single-thread depthwise concern.
- Float nonexact resize case 17:
  **0.24945 -> 0.268605 ms, +7.68%** single-thread;
  **0.09053 -> 0.096955 ms, +7.10%** at 20 threads.
  All six rounds are slower in both modes. Below the 10% screening threshold,
  but directionally consistent with the prior resize concern.

Only **29/52 cases have baseline-derived sanity records**; none of the eight
DNN cases check outputs. No full-array numerical, real-model, importer/startup,
ORB, video/codec, GPU, power or tail-latency qualification was performed.
`SOLVEPNP_DLS` still falls back to EPnP; this does not exercise the internal DLS
compiler-hotspot rewrite.

## Next actions and evidence

Prioritize shared-cap delivery ([64678273](https://microsoft.visualstudio.com/OS/_workitems/edit/64678273))
for the large scheduling gain. Treat Ninja's incremental gain as unproven on
this device. Keep LLVM gated on runtime/correctness qualification
([64678276](https://microsoft.visualstudio.com/OS/_workitems/edit/64678276)),
including the newly observed descriptor mismatches. Existing depthwise
([64680945](https://microsoft.visualstudio.com/OS/_workitems/edit/64680945)),
resize ([64680947](https://microsoft.visualstudio.com/OS/_workitems/edit/64680947))
and real-model/accuracy ([64680949](https://microsoft.visualstudio.com/OS/_workitems/edit/64680949))
follow-ups remain relevant. These links identify existing work; no ADO state
change is implied by this report.

- [Balanced build evidence](../results/minos-builds-38914616842)
- [Original runtime evidence, including failed XML checks](../results/minos-runtime-38914616842)
- [Separate 120-case descriptor diagnostic](../results/minos-runtime-diagnostic-38920209565)
- [Preliminary LLVM-first result](../results/minos-llvm-first-38913335754)
- [Measurement workflow](https://github.com/marcpems/OpenCV-perf-tests/actions/runs/38914616842)
- [Export-only recovery](https://github.com/marcpems/OpenCV-perf-tests/actions/runs/38919819092):
  the first wrapper stopped before export on test failure; recovery exported
  the already completed dataset without rerunning or concealing failures.
- [Runner setup and reproduction](MINOS_RUNNER.md)
