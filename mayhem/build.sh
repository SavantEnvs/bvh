#!/usr/bin/env bash
#
# mayhem/build.sh — build this repo's cargo-fuzz target(s) as sanitized libFuzzer
# binaries (OSS-Fuzz Rust path: cargo-fuzz + ASan via RUSTFLAGS). EDIT per repo.
#
# Runs inside the commit image (RUST mayhem/Dockerfile) as `mayhem` in /mayhem.
# The Rust toolchain + cargo registry live at $CARGO_HOME=/opt/toolchains/rust/cargo
# (pinned by the Dockerfile ENV — absolute, $HOME-independent).
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE.
#   - This FIRST build (in CI, online) populates the cargo registry under $CARGO_HOME.
#   - The PATCH re-run resolves crates from that cache. The rlenv runtime exports
#     CARGO_NET_OFFLINE=true for the re-run so cargo won't try to refresh the
#     crates.io index over the (absent) network — so do NOT hard-code `--offline`
#     here (it would break this first, online build).
#   - For a FULLY self-contained image (no runtime flag needed) instead vendor:
#       cargo vendor --versioned-dirs vendor   # commit vendor/ + a .cargo/config.toml
#     with [source.crates-io] replace-with = "vendored-sources".
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

cd "$SRC"

# OSS-Fuzz Rust libFuzzer+ASan flags. cargo-fuzz sets the ASan flag itself, but we
# pin it explicitly. --cfg fuzzing matches libfuzzer-sys; force-frame-pointers aids
# ASan backtraces. The rlenv PATCH tier prepends `-C debuginfo=2`; we don't fight it.
# We HONOR $SANITIZER_FLAGS: cargo-fuzz builds ASan by default; if the image's
# $SANITIZER_FLAGS opts out ("empty" build), skip ASan.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all}"
RUST_SAN="-Zsanitizer=address"
if [ -z "${SANITIZER_FLAGS}" ]; then
  echo "SANITIZER_FLAGS empty — building WITHOUT sanitizers"
  RUST_SAN=""
fi

# --- Debug-info contract (SPEC §6.2 item 10): DWARF < 4 -----------------------
# Mayhem's triage can't read DWARF >= 4; rustc defaults to DWARF-5. Thread
# $RUST_DEBUG_FLAGS through RUSTFLAGS so OUR code carries DWARF-3. std is rebuilt from
# source under the same flags (BUILD_STD_FLAGS below), so the precompiled DWARF-5
# std/core rlibs never reach the link — only rustc's prebuilt ASan runtime does, and
# that one is C++ compiler-rt we cannot recompile: strip its debug sections (its frames
# are toolchain code, never a bvh frame).
: "${RUST_DEBUG_FLAGS=-Cdebuginfo=2 -Zdwarf-version=3}"

SYSROOT="$(rustc --print sysroot)"
LIBDIR="$SYSROOT/lib/rustlib/x86_64-unknown-linux-gnu/lib"
echo "=== stripping DWARF-5 debug info from the prebuilt ASan runtime archive ==="
for a in "$LIBDIR"/librustc-*_rt.asan.a; do
  [ -e "$a" ] || continue
  objcopy --strip-debug "$a" 2>/dev/null || echo "warn: could not strip $a"
done

# --- CRASH-SIGNATURE FIDELITY (panic-site attribution + unwind tables) --------
# Every bug this target reproduces is the SAME Rust assertion — `assert!(!child_l_aabb
# .is_empty())` at src/bvh/bvh_impl.rs:352 — reached at a DIFFERENT depth of the
# `BVHNode::build` recursion. That recursion shape is the ONLY thing separating the
# original run's three defects (mayhemheroes/bvh/bvh-fuzz/7 — 2744824/2744825/2744826
# are depth 1, depth 2 and depth >= 3 of the same assert).
#
# Mayhem buckets a run's crashes by a defect hash of the CWE plus frames 4, 7 and 10 of
# the crash stack (every third frame below the sanitizer/libFuzzer signal handler). A
# plain Rust panic puts 13 frames of panic machinery between the abort and the code that
# panicked — panic_fmt -> rust_begin_unwind -> rust_panic_with_hook -> libfuzzer-sys'
# hook -> process::abort -> abort -> raise -> __pthread_kill — so frames 4/7/10 are
# always the abort path, identical for all 18 crashers. Runs 1-6 of
# bvh-fuzz-buggy-mhh-run-7 each folded all 18 into ONE defect, hashed on exactly that:
#   20 / __pthread_kill_implementation / std::sys::pal::unix::abort_internal / Box::call
#
# Building std with `panic_immediate_abort` aborts AT the assertion instead, so frame 6
# is `BVHNode::build` at bvh_impl.rs:352 and frames 7 and 10 are that input's OWN
# recursion — each depth gets its own hash again. Same fix as savantenvs/pdb's
# repro-65c5b6d. The trade is the pretty-printed "thread panicked at ..." line; the
# location stays in DWARF and in the (unchanged) source.
#
#   -Cpanic=abort                  required by panic_immediate_abort
#   -Zbuild-std=std,panic_abort    without panic_abort: E0152 (two panic runtimes linked);
#                                  it also rebuilds std under OUR -Zdwarf-version=3
#                                  -Cdebuginfo=2, which is how the panic-machinery frames
#                                  symbolize at all (stripping the precompiled rlibs, what
#                                  this script used to do, left them mis-attributed — one
#                                  read as `abort_internal at FuzzerTracePC.cpp`).
#   -Cforce-unwind-tables=yes      -Cpanic=abort drops .eh_frame for Rust code, and ASan's
#                                  __sanitizer_print_stack_trace unwinds with CFI by
#                                  default (fast_unwind_on_fatal=0) — without this the
#                                  stack STOPS at the first bvh frame and takes the
#                                  recursion depth with it.
#   -Zmerge-functions=disabled     keeps LLVM from folding the cold panic helpers of the
#                                  recursion's two call sites into one mislabelled symbol
#   --strip-dead-code              drops cargo-fuzz's -Clink-dead-code, which under
#                                  -Zbuild-std makes compiler_builtins fail to compile
#                                  ("cannot call functions through upstream monomorphizations")
export RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing ${RUST_SAN} -Cforce-frame-pointers ${RUST_DEBUG_FLAGS} -Cpanic=abort -Cforce-unwind-tables=yes -Zmerge-functions=disabled"
BUILD_STD_FLAGS=(--strip-dead-code -Z build-std=std,panic_abort -Z build-std-features=panic_immediate_abort)
# The libFuzzer runtime inside libfuzzer-sys is C++ compiled by the cc crate —
# keep its debug info at DWARF-3 too (clang-19's plain -g emits DWARF-5).
export CFLAGS="${CFLAGS:-} -gdwarf-3"
export CXXFLAGS="${CXXFLAGS:-} -gdwarf-3"

# EDIT: the cargo-fuzz crate directory. Use upstream's own fuzz/ when it builds on
# the pinned nightly; otherwise add an ADDITIVE mayhem/fuzz/ crate (leaves upstream
# untouched) and point --fuzz-dir at it.
FUZZ_DIR="mayhem/fuzz"
TRIPLE="x86_64-unknown-linux-gnu"

# Discover every target from the crate's fuzz_targets/ dir (one binary per target).
FUZZ_TARGETS=()
for f in "$FUZZ_DIR"/fuzz_targets/*.rs; do
  FUZZ_TARGETS+=("$(basename "${f%.*}")")
done
[ "${#FUZZ_TARGETS[@]}" -gt 0 ] || { echo "ERROR: no fuzz targets under $FUZZ_DIR/fuzz_targets/" >&2; exit 1; }

echo "=== cargo fuzz build (image nightly, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"
echo "targets: ${FUZZ_TARGETS[*]}"

# Use the image's DEFAULT toolchain (the Dockerfile pinned it). A `+toolchain`
# override would make rustup try to install another channel into the locked /opt/rust.
# Clean the fuzz target tree so every crate is recompiled with our DWARF-3 flags
# (a cached artifact would keep DWARF-5); harmless & fast on the offline re-run.
rm -rf "$FUZZ_DIR/target"

for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  cargo fuzz build --fuzz-dir "$FUZZ_DIR" -O --debug-assertions "${BUILD_STD_FLAGS[@]}" "$t"
  bin="$SRC/$FUZZ_DIR/target/$TRIPLE/release/$t"
  [ -x "$bin" ] || { echo "ERROR: expected fuzz binary not found at $bin" >&2; exit 1; }
  cp "$bin" "/mayhem/$t"     # EDIT the output path/name to match your Mayhemfile target:
  echo "built /mayhem/$t"
done

# Build the project's TEST suite too — with the project's NORMAL flags (a clean,
# non-sanitized build) — so mayhem/test.sh only RUNS it (cargo re-uses this cache).
echo "=== cargo test --no-run (project's own suite, normal flags) ==="
env -u RUSTFLAGS cargo test --no-run 2>&1 | tail -5

echo "build.sh complete"
