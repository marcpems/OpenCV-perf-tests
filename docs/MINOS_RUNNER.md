# Minos runner validation

The manual-only **Minos OpenCV validation** GitHub Actions workflow targets the
self-hosted `MARCPE-D4` runner using its dedicated `Marcpe-d4` label and checks
the actual runner name before executing benchmark code. It does not run on
pull requests or execute unreviewed fork code. Checkout credentials are not
persisted; the job has only repository-content read permission.

The initial inventory reports a **20-core NVIDIA RTX Spark N1X CPU, approximately
32 GB RAM, Windows 11 build 28000, and a ReFS D: volume**. This is not the earlier
12-core Snapdragon/64 GB machine. The owner identifies this device as the same
hardware as the HOBL lab, whose supplied reference is **154 seconds**, versus
**53 seconds on M5 Pro**. Those reference timings are not new measurements.

## Workflow phases

Use the repository's Actions page to dispatch:

| Phase | Work |
|---|---|
| `probe` | Read hardware, filesystem, power-plan and installed-tool inventory |
| `llvm` | Prepare missing tools, then perform one clean Ninja/LLVM build and immediately upload its timing evidence |
| `study` | Configure all three build trees, run the balanced ten-build comparison, upload build results, then run/upload the bounded runtime screen |

The first LLVM observation is explicitly **preliminary and separate** from the
balanced study. It is not silently pooled into the two-observation medians.
The study preserves the prior order: original / MultiToolTask / shared cap /
MSVC-Ninja / LLVM-Ninja, then reverse. Each run uses a fresh process and a clean
build, with 30-second rests; timing excludes configuration, cleaning,
installation and version verification. CPU accounting remains enabled, with
no WPR capture. Original MSBuild flags remain unchanged; the four optimized
variants use a **20-compiler/job limit**, matching this machine, rather than
reusing the laptop's 12-job setting.

Baseline comparison reports the difference from 154 seconds and the observed
two-run range. The supplied 5% and 10% proximity indicators are descriptive
bands, **not confidence intervals or proof of lab equivalence**. The lab's run
variance and complete software configuration have not been supplied.
Power-plan differences between measured builds cause the study to be rejected
for pooled comparison; these scripts do not change the machine's power plan.

## Prerequisites and preservation

The first attempted build found VS 2022 registered but without the required
native C++ toolchain. The workflow can add the missing C++ workload and ARM64
component to that existing BuildTools installation using a Microsoft-signed
installer. It never automatically restarts Windows and refuses measurements
if the installer reports a restart requirement that has not been satisfied.
Elevation may be required. The component, bootstrapper hash, previous tool
inventory and installer exit status are recorded locally.

CMake 4.1.1 and LLVM 23.1.3 are checksum-verified portable installations under
the checkout's ignored `.tools` directory. Existing Microsoft tools, selected
SDK servicing versions and configured Ninja are recorded in each setup
receipt; do not assume a matching lab software configuration merely from the
hardware name. Global compiler flags, PATH and power settings are not changed.

The OpenCV source and build trees live under `.work\minos-source` on the runner's
ReFS checkout volume. `clean: false` preserves these ignored, benchmark-owned
assets across manually dispatched jobs. Existing source hashes and benchmark
configuration guards still apply. A reused result directory is rejected.

The study's opt-in `-SnapshotRuntimeBinaries` copies the baseline, shared-cap
and LLVM DLL/import library immediately after each corresponding build and
records hashes and origin labels. Each observation has its own snapshot;
later MSBuild builds cannot overwrite the retained shared-cap library.
Snapshots remain private to the runner; published artifacts contain sanitized
text evidence, not binaries or whole-machine traces.

## Runtime comparison

The same 52-case upstream harness is compiled once with MSVC and used against
the three preserved Minos DLLs. The six balanced rounds and 20 measured
samples are retained, but thread modes are **1 and 20**.
`runtime_cpu_topology.py` reads Windows CPU-set topology and selects the lowest
logical CPU in the highest reported efficiency class. Single-thread runs use
that CPU; parallel processes allow CPUs 0-19 and pin the main thread only after
worker warm-up. The topology and selection rule are recorded, not assumed to
match the earlier CPU-6 laptop placement. Multiple/noncontiguous processor
groups are rejected rather than silently misconfigured.

Runtime setup plus measurement has a two-hour deadline; executable time is
capped at 30 minutes per library and 180 seconds per invocation. Existing
failure, exact-case, thread/affinity, loaded-library and frozen-hash guards
remain in force. Only 29/52 cases have baseline-derived sanity records, and
none of the eight synthetic DNN cases check outputs. No full numerical,
model-level or API equivalence claim follows from this screen.

Build artifacts are uploaded **before** runtime testing finishes so timings
can be reported promptly. Final per-case runtime analysis, traces of the
invoked test commands, provenance and caveats are uploaded separately.
