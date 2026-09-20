#!/usr/bin/env bash
set -euo pipefail

: "${CARGO_TARGET_DIR:?CARGO_TARGET_DIR must point to workspace storage}"

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
compatibility_patch="$project_root/patches/codex-i686-musl-openssl.patch"
compatibility_sources="$project_root/compat/codex-i686/code-mode"

git apply --check "$compatibility_patch"
git apply "$compatibility_patch"
install -m 0644 \
  "$compatibility_sources/service_unavailable.rs" \
  code-mode/src/service_unavailable.rs
install -m 0644 \
  "$compatibility_sources/v8_init_unavailable.rs" \
  code-mode/src/v8_init_unavailable.rs

# OpenSSL 3 probes 64-bit lock-free atomics on i386 through
# __atomic_is_lock_free, which Zig's musl runtime does not export. This
# upstream-supported guard selects OpenSSL's existing RWLock fallback instead.
export CFLAGS="${CFLAGS:+$CFLAGS }-DBROKEN_CLANG_ATOMICS"

# Keep the release binary suitable for iSH: the default Codex release profile
# currently carries DWARF debug information, which made the static i686 CLI
# exceed 1 GB. Cargo's profile environment overrides remove debug info and
# strip symbols without changing the dependency graph or lockfile.
export CARGO_PROFILE_RELEASE_DEBUG=0
export CARGO_PROFILE_RELEASE_STRIP=symbols

# rusty_v8 149.2.0 contains Chromium's vendored ICU4X sources, but its
# published crate is missing the build script for icu_calendar_data-v2.
# GN still generates a Ninja edge for that build script, so the source build
# fails before compiling V8 with "missing and no known rule to make it".
# Fetch the target dependencies first so Cargo unpacks rusty_v8 into CARGO_HOME.
# Then restore the exact 2.0.0 build script from the corresponding crates.io
# package. This does not alter Cargo's dependency graph or lockfile; it only
# repairs the incomplete vendored source shipped inside the pinned v8 crate.
cargo fetch --locked --target i686-unknown-linux-musl

v8_dir="$(find "$CARGO_HOME/registry/src" -maxdepth 2 -type d -name 'v8-149.2.0' -print -quit)"
if [[ -z "$v8_dir" ]]; then
  echo "error: could not locate the unpacked v8-149.2.0 crate" >&2
  exit 1
fi

icu_calendar_data_dir="$v8_dir/third_party/rust/chromium_crates_io/vendor/icu_calendar_data-v2"
if [[ ! -f "$icu_calendar_data_dir/build.rs" ]]; then
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  curl --fail --silent --show-error --location \
    https://crates.io/api/v1/crates/icu_calendar_data/2.0.0/download \
    | tar -xz -C "$tmp_dir"

  mkdir -p "$icu_calendar_data_dir"
  install -m 0644 \
    "$tmp_dir/icu_calendar_data-2.0.0/build.rs" \
    "$icu_calendar_data_dir/build.rs"
fi

cargo zigbuild \
  --locked \
  --release \
  --target i686-unknown-linux-musl \
  -p codex-app-server \
  --bin codex-app-server

# The actual terminal Codex CLI is the Rust codex binary, not the app-server.
# Build it for the same iSH target from the same patched workspace.
cargo zigbuild \
  --locked \
  --release \
  --target i686-unknown-linux-musl \
  -p codex-cli \
  --bin codex
