# Custom LLVM build-time comparison on Minos

## Result: 10.23% less build wall time

The owner's custom LLVM 24.0.0git PGO/LTO package built OpenCV in
**56.4598 seconds**, versus **62.8931 seconds** with a fresh stock LLVM 23.1.3
control on MARCPE-D4: **6.4334 seconds / 10.23% saved**.
Aggregate CPU time decreased **10.90%**. Four clean measured builds per
package followed one excluded warm-up each.

| LLVM package | Median wall s | Observed wall range s | Median CPU s |
|---|---:|---:|---:|
| Stock 23.1.3 | 62.8931 | 62.4138-63.9064 | 1,015.0469 |
| Custom 24.0.0git PGO/LTO | **56.4598** | **55.9250-56.9982** | **904.3750** |

Every custom observation was faster than every stock observation in this
sample. Adjacent stock/custom pairs improved by **9.45%, 10.55%, 9.14% and
12.49%**. This is a consistent observed gain, not a formal confidence interval
or a guarantee for other workloads.

| Observation pair | Stock wall s | Custom wall s |
|---|---:|---:|
| 1 | 62.9485 | 56.9982 |
| 2 | 62.8377 | 56.2093 |
| 3 | 62.4138 | 56.7102 |
| 4 | 63.9064 | 55.9250 |

Pairs are adjacent in the balanced order below; the custom observation comes
first in pairs 2 and 3. Warm-ups were 65.2407s stock and 58.4284s custom, retained
separately and excluded from the measured statistics.

### Where the gain appears

All eight measured builds executed **1,016 compile steps**. Generated compilation
databases matched in all **1,018 source-compilation entries**. Generated-command
counts and executed-step counts are different metrics. Both generated feature
headers matched exactly.

| Ninja step category | Stock median summed elapsed s | Custom median summed elapsed s |
|---|---:|---:|
| Compilation | 1,175.0080 | 1,054.5515 |
| Link/archive | 3.1325 | 3.0115 |

The benefit is predominantly in compilation, not removal of a long link tail.
The median final log tail after compilation was only 0.6575s stock and 0.6430s custom.
Ninja step elapsed times overlap across jobs: these sums are **not wall time
or measured CPU time**, and their difference must not be presented as seconds
saved from the build wall clock. The separately measured CPU reduction supports
a reduction in total processing work rather than merely greater concurrency.

The source/package identities reported by the compilers were:

- Stock: LLVM 23.1.3, revision
  `0d261d1ca552c95a8f007e061c787ac7132fbcbc`.
- Custom: LLVM 24.0.0git, revision
  `d32de3d7996815fc47a94d264bf42f1fad76d9df`.
- Both report native `aarch64-pc-windows-msvc`, POSIX thread model and
  `+alloc:rpmalloc`.

Every measured receipt records 20 jobs, Windows 11 build 28000, SDK servicing
release 10.0.26100.8249 and the same Ultimate Performance power-scheme GUID.
The scripts did not change the machine's power plan.
All builds installed successfully and reported OpenCV 4.10.0.
**Runtime performance and numerical correctness of the custom-built OpenCV
were not tested in this experiment.**

The historical 16 October stock median of 64.9488s is not the control for this
claim. The gain above uses only the fresh, same-session 62.8931s control.
It is also **not an isolated measurement of PGO/LTO**: LLVM version/revision
and the bundled tools differ. A matched LLVM 24 build without PGO/LTO is needed
to separate those contributions.

[Complete measured and warm-up evidence](../results/minos-custom-llvm-39129486630)
| [Successful run, 18 October 2026](https://github.com/marcpems/OpenCV-perf-tests/actions/runs/39129486630)

## Reproduction and controls

The manual `llvm-custom` phase compares the installed portable LLVM 23.1.3
control with the owner's runner-local LLVM 24.0.0 PGO/LTO package. Supply
`installer_path` and its SHA-256 as workflow inputs. `llvm-custom-probe`
checks availability without installing or uploading the package.

The supplied package fingerprint is
`D02E9DE11B93324340851191F758DB182C8ACEE5235C820AFCE7A66B30CAFF36`.
It is an unsigned custom MSI, identified by its owner and pinned by hash.
The MSI remains on the private runner; only text benchmark evidence is uploaded.
An administrative image extracts it into a fresh ignored `.tools` directory,
without replacing stock LLVM, registering a product, or changing global PATH.
Every selected compiler/linker/archive tool must be native ARM64 and is hashed.

Two fresh worktrees of the same OpenCV 4.10.0 commit are configured with the
existing HOBL definitions, CMake 4.1.1 and the same Ninja executable. Only the
LLVM root changes. Generated feature headers and normalized source compile
commands must match before measurements proceed. Source trees, generated
graphs, tool receipts, compiler hashes, Ninja and scripts are checked for
changes. Existing timing/source/SDK guards remain in use.

The first preflight stopped before any benchmark build: OpenCV auto-added
`-Wno-stringop-overread` for LLVM 24, but not the stock compiler. The comparison
therefore supplies the same explicit CMake initial-cache policy to both:
`HAVE_C_WNO_STRINGOP_OVERREAD=0` and `HAVE_CXX_WNO_STRINGOP_OVERREAD=0`.
This keeps the requested warning flags equal without ignoring differences in
the parity check or altering optimization/code-generation flags. The cache
file is hashed and recorded through setup's opt-in `-InitialCache` parameter;
ordinary benchmark setup is unchanged.

Each package gets one clean warm-up build, retained as separate evidence but
excluded from medians. Four clean builds per package follow, in order:
stock / custom / custom / stock / custom / stock / stock / custom.
Each uses 20 jobs, a fresh measuring process, CPU accounting and a 30-second
rest. Build timing excludes extraction, configuration, cleaning, installation
and version validation. The active power scheme must remain unchanged.
No OpenCV runtime qualification or OpenCV PGO/LTO flags are added.

Report wall/CPU medians, ranges and paired observations against the **fresh**
stock control. Historical 16 October Minos numbers are context, not pooled
controls. This compares complete LLVM packages: compiler version, source
revision, compiler-build optimization and bundled linker/library tools may
all differ. **It cannot attribute a gain to PGO/LTO alone**; that requires
matched LLVM 24 source/configuration with and without those optimizations.
