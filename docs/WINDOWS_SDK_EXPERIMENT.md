# Latest Windows SDK / MSVC build-wall-time experiment

This follow-up completes the current Microsoft build stack with the latest
stable Windows SDK, while preserving the historical VS 2022 and VS 2026 profiles.
It holds VS 2026/MSVC/MSBuild/CMake constant and measures old versus latest SDK.
OpenCV remains 4.10.0 with all 23 HOBL CMake definitions and unchanged timing
boundaries. This is a build-time experiment, not OpenCV algorithm performance.

## Results: no build-time improvement

Measured on **2026-10-15**, on the 12-core Snapdragon X2 Elite with 63.48 GiB RAM
and the unchanged High performance power scheme.

| Sequence | SDK | Clean Release build |
|---|---|---:|
| 1 | Old 26100.7705 | 231.7380 s |
| 2 | Latest 28000.2957 | 234.6448 s |
| 3 | Latest 28000.2957 | 245.9327 s |
| 4 | Old 26100.7705 | 235.9412 s |
| 5 | Latest 28000.2957 | 236.2562 s |
| 6 | Old 26100.7705 | 244.3414 s |
| 7 | Old 26100.7705, after recovery | 229.7287 s |
| 8 | Latest 28000.2957 | 240.4646 s |
| Median | Old SDK | **233.8396 s** |
| Median | Latest SDK | **238.3604 s** |

The latest stack took **4.5208 s / 1.93% more median build time**, not less.
Its mean was 239.3246 s versus 235.4373 s, and it was slower in three of four
adjacent pairs. The observed ranges overlap: 229.7287-244.3414 s for the old SDK,
234.6448-245.9327 s for the new one. Sample standard deviations were 6.48 s and
5.04 s respectively.

**No compile-wall-time benefit was demonstrated.** This small, normal-use-machine
sample, including the interruption below, also does not establish a general
1.93% regression caused by the SDK. As a post-hoc sensitivity check, excluding
the recovered final pair gives medians 235.9412 s and 236.2562 s: only **0.13%
more time** for the new SDK. That six-run subset is not the complete balanced
design, but it reaches the same no-observed-speedup conclusion.

All eight builds installed successfully and returned OpenCV 4.10.0 from native
ARM64 executables. Both final libraries passed the image/matrix smoke checks.
Normalized installed build information matched across all eight runs after
excluding only the configuration timestamp and installation directory.
Clean/install phases remain outside the reported wall time.

Evidence: [summary and individual runs](../results/2026-10-15-vs2026-sdk-comparison/summary.json),
[verified comparison and pair differences](../results/2026-10-15-vs2026-sdk-comparison/comparison.json),
[component audit](../results/2026-10-15-vs2026-sdk-comparison/stack_audit.json),
and [functional/workload validation](../results/2026-10-15-vs2026-sdk-comparison/validation.json).

Keep the latest SDK available for current platform support, but do not recommend
this update as a measured build-throughput optimization. The existing analysis
still points to compiler/build scheduling and expensive translation units rather
than SDK freshness as the more useful performance investigations.

### Between-run interruption and recovery

After run 6 completed, Windows logged **Application Hang event 1002** at
12:48:27 local time: `pwsh.exe` stopped interacting with Windows and was closed.
No seventh build had started, and the six completed runs were successful.
The SDK/compiler binaries and all recorded runner, setup and generated-project
hashes still matched. The final pair was run in fresh processes with the same
frozen inputs and the planned order.

Consequently, the gap between run 6's finish and run 7's start was **132.11 s**,
not the planned 30 seconds. Other inter-run gaps were approximately 31-32 s.
This is **a recovered eight-run series, not an uninterrupted one**; the longer
rest could affect temperature/cache state, especially run 7. The underlying
reason Windows classified the PowerShell process as hung was not established.

The [Windows event](../results/2026-10-15-vs2026-sdk-comparison/interruption.json),
[original incomplete manifest](../results/2026-10-15-vs2026-sdk-comparison/study-before-recovery.json),
and [exact recovery script](../results/2026-10-15-vs2026-sdk-comparison/resume_study.ps1)
are retained. The completed manifest records the recovery and original hashes;
no failed build was converted into a successful observation.

## Component versions

Checked on **2026-10-15** against Microsoft's stable release channel, Windows SDK
download listing, signed VC redistributable, and installed Windows/.NET updates.

| Component | Control | Latest profile |
|---|---|---|
| VS 2026 Build Tools | 18.11.0 / 18.11.12306.390 | Same |
| Native ARM64 MSVC | 19.51.36260.0, toolset 14.51.36231 | Same |
| Linker / librarian / compiler-private runtime | 14.51.36260.0 | Same |
| Native ARM64 MSBuild | 18.11.0.47511 | Same |
| Native ARM64 CMake | 4.4.4 | Same |
| Windows SDK release | 10.0.26100.7705, February 2026 | 10.0.28000.2957, September 2026 |
| SDK/UCRT target directory | 10.0.26100.0 | 10.0.28000.0 |
| System VC redistributable | 14.51.36247.0 | Same |
| Windows 11 26H1 / system UCRT | 28000.3231, October update KB5127646 | Same |
| .NET Framework | 4.8.1, October update KB5127691 installed | Same |

The compiler/build engine, CMake and applicable OS/runtime updates were already
current. The SDK was the missing update. The older VS 2022 installation remains
17.14.41 deliberately: it is the pinned historical control, not the latest-profile
compiler. Its available 17.14.42 servicing update was not installed. Neither
OpenCV nor unrelated applications were upgraded.

The [SDK manifest](../toolchains/windows-sdk.json) pins the official installer URL,
SHA-256 and release. Its Microsoft Authenticode signature and product version
were verified. Installation of `OptionId.DesktopCPParm64` completed with exit
**0**, with `/norestart`; no reboot was requested by this SDK installation.
All **5,464** checked files in the old SDK's include tree, ARM64 UM/UCRT libraries
and native ARM64 tools matched their pre-install SHA-256 values.

The previous VS installation's documented soft-reboot recommendation still
applies. Fresh-process measurements use the existing runtime-hash verification;
no reboot or security/power-policy change was performed.

## SDK isolation and protocol

The profiles are:

- `MSVC2026`: `build_hobl_msvc2026`, old SDK.
- `MSVC2026Latest`: `build_hobl_msvc2026_latest`, latest SDK.

CMake explicitly selects the generator platform's SDK version and sets
`UCRTVersion` in project globals. Setup checks generated build projects and
evaluated MSBuild SDK, UCRT, include and library properties. A newer SDK is not
allowed to leak into the old-SDK control through automatic discovery. Ninja
environment setup and functional smoke clients also use the selected profile.
Legacy setup receipts must be regenerated before running.

Both generated solutions contain **37 projects and 1,015 compile-source entries**.
The normalized source-entry multiset and per-project Release compiler settings
match. Source entries are not separate MSBuild command invocations. All source
files and HOBL feature definitions remain unchanged.

One clean build plus functional smoke check per SDK warms each condition and
checks compatibility; both warm-ups are excluded from the comparison. The
warm-ups took 247.4555 s (old SDK) and 237.8422 s (latest SDK), but other untimed
preparation checks overlapped them, so their difference is not performance evidence.
All such preparation finished before the matched series started. The
measured order is **old/new/new/old, new/old/old/new**, four samples each, with
30-second rests and fresh child shells. The timed command remains:

```powershell
cmake --build . --config Release
```

Cleaning, installation, version validation and smoke checks are outside the
timer. There is no explicit `/m` override; generated `/MP` still enables compiler
parallelism. Runner/helper/manifest/setup/generated-project hashes are checked
throughout the study, including both `.slnx` solution files.

Normal background activity and thermal conditions are not continuously controlled.
Balanced order reduces simple ordering bias but does not remove all noise.
Do not compare these absolute times directly with the earlier Clang or VS
2022-versus-2026 series as if they were matched observations.

## Reproduce

From the repository root, after installing the two SDKs and current VS 2026 tools:

```powershell
pwsh -NoProfile -File scripts\setup.ps1 -Toolchain MSVC2026
pwsh -NoProfile -File scripts\setup.ps1 -Toolchain MSVC2026Latest
pwsh -NoProfile -File scripts\run.ps1 -Toolchain MSVC2026 -ResultsDir results\local\sdk-warmups -Label old_warmup
pwsh -NoProfile -File tests\smoke_opencv.ps1 -Toolchain MSVC2026
pwsh -NoProfile -File scripts\run.ps1 -Toolchain MSVC2026Latest -ResultsDir results\local\sdk-warmups -Label latest_warmup
pwsh -NoProfile -File tests\smoke_opencv.ps1 -Toolchain MSVC2026Latest
pwsh -NoProfile -File scripts\run_toolchain_study.ps1 -CandidateToolchain MSVC2026Latest -Blocks 2
python scripts\compare_sdk.py results\local\vs2026-sdk-comparison --source-root D:\opencv
python scripts\export_results.py results\local\vs2026-sdk-comparison results\<new-snapshot>
```

Use a fresh `-ResultsDir` for repeats. `compare_sdk.py` verifies run order,
success/version checks, unprofiled default-worker arguments, non-overlap, stable
per-condition setup and identical non-SDK tools. With `--source-root`, it also
checks the current solution source inventories and Release compiler settings.

Sources: [SDK downloads](https://learn.microsoft.com/en-us/windows/apps/windows-sdk/downloads),
[VS stable channel](https://aka.ms/vs/stable/channel),
[VC redistributable](https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist),
[October .NET update](https://learn.microsoft.com/en-us/dotnet/framework/release-notes/2026/10-13-october-cumulative-update).
