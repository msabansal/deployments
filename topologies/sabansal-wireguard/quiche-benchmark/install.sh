#!/usr/bin/env bash
set -euo pipefail
SOURCE_COMMIT=be47c5011215b9f13bad06bd7627d3ae49888a19
HARNESS=$(cd "$(dirname "$0")" && pwd)
PREFIX=/opt/quiche-benchmark
install -d "$PREFIX/bin"
FINGERPRINT=$(cat "$HARNESS/instrument.py" "$HARNESS/bench.rs" "$HARNESS/Cargo.lock" "$HARNESS/install.sh" | sha256sum | cut -d' ' -f1)
if [ -x "$PREFIX/bin/quiche-server" ] && [ -x "$PREFIX/bin/quiche-client" ] &&
   [ -s "$PREFIX/source.json" ] && grep -q "$FINGERPRINT" "$PREFIX/source.json"; then
  echo QUICHE_INSTALLED
  exit 0
fi
missing=0
for tool in cargo rustc cc c++ cmake clang git python3 openssl; do
  command -v "$tool" >/dev/null 2>&1 || missing=1
done
if [ "$missing" = 1 ]; then
  if command -v tdnf >/dev/null 2>&1; then
    tdnf install -y rust cargo cmake clang clang-devel gcc-c++ ninja-build perl git python3 openssl-devel pkgconf
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y rust cargo cmake clang clang-devel gcc-c++ ninja-build perl git python3 openssl-devel pkgconf
  else
    echo "Missing compiler dependencies and no supported package manager" >&2
    exit 1
  fi
fi
SOURCE="$PREFIX/source-$FINGERPRINT"
if [ ! -d "$SOURCE/.git" ]; then
  git init -q "$SOURCE"
  git -C "$SOURCE" remote add origin https://github.com/cloudflare/quiche.git
  git -C "$SOURCE" fetch -q --depth 1 origin "$SOURCE_COMMIT"
  git -C "$SOURCE" checkout -q --detach FETCH_HEAD
fi
test "$(git -C "$SOURCE" rev-parse HEAD)" = "$SOURCE_COMMIT"
if [ ! -f "$SOURCE/.benchmark-instrumented" ]; then
  python3 "$HARNESS/instrument.py" "$SOURCE"
  touch "$SOURCE/.benchmark-instrumented"
fi
cp "$HARNESS/Cargo.lock" "$SOURCE/Cargo.lock"
export CARGO_BUILD_JOBS=2
export RUSTFLAGS='-C target-cpu=native'
export CFLAGS='-O3 -march=native'
export CXXFLAGS='-O3 -march=native'
export CARGO_PROFILE_RELEASE_LTO=thin
export CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1
export CARGO_PROFILE_RELEASE_DEBUG=0
cd "$SOURCE"
cargo build --locked --release -p quiche_apps --no-default-features \
  --bin quiche-client --bin quiche-server
install -m 755 target/release/quiche-client target/release/quiche-server "$PREFIX/bin/"
cp COPYING "$PREFIX/UPSTREAM-COPYING"
export FINGERPRINT SOURCE_COMMIT
python3 - <<'PY'
import json, os, pathlib, subprocess
prefix = pathlib.Path("/opt/quiche-benchmark")
data = {
    "quiche_version": "0.30.0",
    "source_commit": os.environ["SOURCE_COMMIT"],
    "source_url": "https://github.com/cloudflare/quiche",
    "release_url": "https://github.com/cloudflare/quiche/releases/tag/0.30.0",
    "instrumentation_sha256": os.environ["FINGERPRINT"],
    "rustc": subprocess.check_output(["rustc", "--version"], text=True).strip(),
    "cargo": subprocess.check_output(["cargo", "--version"], text=True).strip(),
    "rustflags": os.environ["RUSTFLAGS"],
    "cflags": os.environ["CFLAGS"],
    "release_lto": "thin",
    "codegen_units": 1,
    "crypto_backend": "BoringSSL (boring crate, Cargo.lock)",
    "cpu_model": next(line.split(":", 1)[1].strip() for line in pathlib.Path("/proc/cpuinfo").read_text().splitlines() if line.startswith("model name")),
}
(prefix / "source.json").write_text(json.dumps(data))
PY
cargo clean --release
echo QUICHE_INSTALLED
