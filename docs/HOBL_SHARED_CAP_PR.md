# HOBL PR preparation: shared-cap Windows OpenCV builds

**Publication:** patch and exact-patch evidence are ready; GitHub's
Microsoft-organization SSO enforcement still blocks opening the upstream
coordination issue and PR. No upstream issue or PR has been opened.

**Title:** Use shared-cap MSBuild scheduling for Windows OpenCV builds

**Upstream base:** `3baa2ab25837ac6a0f766f1c7401f1e74c5110ae`.
**Candidate commit:** `5e42dc8` on `perf/opencv-msbuild-shared-cap`.
**Patch:** [three-file upstream patch](../patches/hobl-opencv-shared-cap.patch).
The measurement harness and results belong to this evidence repository, not the
upstream PR.

## Proposed PR description

### Summary

Enable project parallelism and a shared compiler-process budget for the Windows
OpenCV build. Existing MSBuild scheduling serializes sources with distinct
metadata; merely adding project parallelism does not address that within-project
tail.

The budget follows `[Environment]::ProcessorCount`, rather than a device-specific
constant. The timed invocation becomes:

```powershell
cmake --build . --config Release --parallel $buildJobs -- `
    /p:MultiProcCL=true /p:MultiProcMaxCount=$buildJobs `
    /p:EnforceProcessCountAcrossBuilds=true /nr:false
```

Clean and install receive the same MSBuild properties. Worker-node reuse is
disabled. This caps compiler processes across workers, not all threads, linkers
or helper processes.

Only three upstream files change:

| File under `scenarios/windows/opencv_build/` | Change |
|---|---|
| `opencv_build_resources/opencv_build_run.ps1` | Set/log the budget; apply scheduler properties to clean/build/install and project parallelism to build. |
| `opencv_build.py` | Refresh only the run script when prep is cached, without reinstalling tools or replacing other resources. |
| `README.md` | Match the invocation and document scheduling/re-baselining. |

No source patch, compiler/generator change, CMake feature change, new scenario
parameter, dependency, prep-version bump or macOS change. The existing timer,
phase markers, error checks and CSV keys remain unchanged.

### Exact-patch validation

On **19 October 2026**, the exact baseline/candidate study on MARCPE-D4
completed successfully:

| Exact HOBL script | Measured builds, seconds | Median | Range |
|---|---|---:|---:|
| Unmodified baseline | 155.52, 155.94, 156.19, 155.39 | 155.730 s | 155.39-156.19 s |
| Three-file shared-cap patch | 108.04, 108.51, 108.37, 107.71 | 108.205 s | 107.71-108.51 s |

**47.525 seconds / 30.52% lower median build wall time.** Every measured
candidate build was faster than every measured baseline build. The baseline
is 1.12% above the supplied 154-second lab reference, not proof of statistical
equivalence. These four-observation ranges are not confidence intervals.

Runner: NVIDIA RTX Spark N1X, 20 logical processors, 31.7 GiB usable RAM,
Windows build 28000; native ARM64 MSVC 19.44.35229 / VS 2022 17.14.37710,
CMake 4.1.1, SDK target 10.0.26100.0 (servicing 26100.8249), OpenCV 4.10.0
at `71d3237a093b60a27601c20e9ee6c3e52154e8b1`. The existing Ultimate
Performance power plan remained unchanged. CPU time and energy were not measured.

Protocol: unchanged upstream prep CMake arguments; exact baseline and patched
run-script files; one excluded warm-up each; four measured clean builds each in
baseline/shared/shared/baseline/shared/baseline/baseline/shared order; 30-second
rests. The script's own CSV `build_time` is the primary measurement.

The dedicated ARM64 runner uses existing tools. A temporary drive alias isolates
HOBL's drive-relative paths. Both variants use the same process-local forwarding
function to select portable CMake after HOBL refreshes PATH; no machine/user PATH
or power-plan changes. The forwarding function records argument lists, exit codes
and native-command durations. It adds small common measurement overhead.

The source commit was pinned; generated configuration, selected tools and script
hashes stayed unchanged. All ten builds (including warm-ups) had **1,015 identical
compilation-command records and identical DLL `.text` sections**, native ARM64
output, successful install/version checks and unchanged compilation outputs
across untimed INSTALL. Whole DLL hashes differ; no whole-file identity is claimed.
The common image/matrix smoke executable passed with both final libraries.

Six host-side tests cover cached/fresh prep, repeated setup, upload/prep failures,
loop count and timeout without RPC or installers. Argument checks cover budgets
1, 12 and 20; seven local evidence/adapter tests cover invalid/incomplete results,
native argument forwarding (including `--`) and error propagation.

[Successful workflow](https://github.com/marcpems/OpenCV-perf-tests/actions/runs/39278104684)
| [Raw timings, commands, logs, hashes and provenance](https://github.com/marcpems/OpenCV-perf-tests/tree/main/results/hobl-upstream-39278104684)
| [Reproduction workflow at the tested revision](https://github.com/marcpems/OpenCV-perf-tests/blob/271371aa96271a4c49ff36b626c5956bb15f072d/.github/workflows/hobl-upstream-validation.yml).
The manual workflow targets the dedicated runner and requires its existing
toolchain/source checkout; it is not a clean-machine installer.

The downloaded artifact's SHA-256 was verified:
`a00230fe985f3a477b8870a16c56476361b390385114385f1a2f914835686d77`.
The tested upstream patch's SHA-256 is
`45fa29f5a9bcc0e16bee4f8643df7243fbfd960ea8ecb832eba20827ac091e82`.
The superseded, cancelled run `39277358942` contributes no accepted measurements.

### Supporting investigation, not exact-patch results

| Earlier matched study | Original MSBuild | Shared cap | Wall saving |
|---|---:|---:|---:|
| Surface / 12-job budget | 215.117 s | 187.674 s | 12.8% |
| Minos / 20-job budget | 170.534 s | 116.368 s | 31.8% |

Two observations per condition/device; do not pool with the new study.
[Published evidence](https://github.com/marcpems/OpenCV-perf-tests/blob/main/docs/INVESTIGATION_REPORT.md#matched-five-way-studies--do-not-pool-devices).
A separate [WPR/binlog investigation](https://github.com/marcpems/OpenCV-perf-tests/blob/main/docs/MSBUILD_SHARED_PARALLELISM.md#verifying-that-parallelism-actually-changed)
verified a shared peak of 12 compiler processes, one 513-source world compilation
task, and unchanged 1,015 source/project command records.

### Compatibility, rollout and limits

- This intentionally changes the Windows benchmark scheduling baseline. Coordinate
  release/re-baselining with HOBL maintainers, including their policy for
  power-impacting changes; lower wall time is not an energy measurement.
- Existing prepared DUTs receive the changed run script without re-prep. Reverting
  the commit restores the previous command; verify the deployed script on rollback.
- No new Windows x64 hardware validation, full HOBL host/RPC execution, installer
  execution, cancellation testing or full OpenCV runtime qualification is claimed.
- Historical threaded runtime mismatches also reproduced in baseline binaries;
  this PR does not resolve them or claim complete numerical equivalence.
- This does not establish Windows/macOS workload parity or predict a percentage
  improvement in OpenCV's own CI. OpenCV CI requires a separate change and study.

## Coordination issue text

**Title:** Improve Windows OpenCV build scheduling with a shared MSBuild compiler cap

The Windows OpenCV workload currently invokes `cmake --build . --config Release`
without an explicit project budget. Our investigation found a serial source-task
tail and measured lower wall time with compiler-only MultiToolTask scheduling,
project parallelism and a shared compiler cap. The proposed patch changes only
Windows scheduling and refreshes the run script on cached-prep DUTs.

An exact-script Minos study measured 155.730 s baseline versus 108.205 s shared-cap
medians (four clean builds each; 30.52% saving), with unchanged compilation
commands and DLL code sections.
[Patch, data and validation limits](https://github.com/marcpems/OpenCV-perf-tests/blob/main/docs/HOBL_SHARED_CAP_PR.md).
Please confirm the intended rollout/re-baselining release for this measurement
change. No compiler switch, OpenCV source change or Windows/macOS parity claim
is proposed.
