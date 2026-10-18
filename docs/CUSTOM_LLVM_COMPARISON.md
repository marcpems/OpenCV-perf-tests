# Custom LLVM build-time comparison on Minos

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
