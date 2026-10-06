#!/usr/bin/env bash
# Builds quinn's upstream perf tool twice from a pinned commit:
#   quinn-perf         unmodified upstream
#   quinn-perf-gsocap  adds QUINN_MAX_TRANSMIT_SEGMENTS / QUINN_MAX_TRANSMIT_DATAGRAMS
#                      environment overrides for quinn's per-send GSO batch caps
set -euo pipefail

COMMIT=7616e6b2782722f3ce4a1b181ef08817d7f545e4
PREFIX=/opt/quinn-perf
WORK=/var/tmp/quinn-build
FINGERPRINT=$(sha256sum "$0" | cut -d' ' -f1)

if [ -x "$PREFIX/bin/quinn-perf" ] && [ -x "$PREFIX/bin/quinn-perf-gsocap" ] &&
   [ "$(cat "$PREFIX/fingerprint" 2>/dev/null)" = "$FINGERPRINT" ]; then
  echo "quinn-perf already built for $COMMIT"
  exit 0
fi

for tool in cargo rustc cc git python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    tdnf install -y rust cargo gcc git python3
    break
  fi
done

rm -rf "$WORK"
mkdir -p "$WORK/src"
cd "$WORK/src"
git init -q
git remote add origin https://github.com/quinn-rs/quinn.git
git fetch -q --depth 1 origin "$COMMIT"
git checkout -q FETCH_HEAD

export CARGO_HOME="$WORK/cargo-home"
export CARGO_TARGET_DIR="$WORK/target"
export CARGO_BUILD_JOBS=2
export CARGO_PROFILE_RELEASE_LTO=thin
export CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1
export CARGO_PROFILE_RELEASE_DEBUG=0
export RUSTFLAGS='-C target-cpu=native'
build() { cargo build --release -p perf --no-default-features --features json-output; }

install -d "$PREFIX/bin"
build
install -m 755 "$CARGO_TARGET_DIR/release/quinn-perf" "$PREFIX/bin/quinn-perf"

python3 - <<'PY'
import pathlib
p = pathlib.Path('quinn/src/connection.rs')
s = p.read_text()
for old, new in (
    ('.min(MAX_TRANSMIT_SEGMENTS);',
     '.min(env_cap("QUINN_MAX_TRANSMIT_SEGMENTS", MAX_TRANSMIT_SEGMENTS));'),
    ('if transmits >= MAX_TRANSMIT_DATAGRAMS {',
     'if transmits >= env_cap("QUINN_MAX_TRANSMIT_DATAGRAMS", MAX_TRANSMIT_DATAGRAMS) {'),
):
    if s.count(old) != 1:
        raise SystemExit(f'patch anchor not found exactly once: {old}')
    s = s.replace(old, new)
s += '''
fn env_cap(name: &'static str, default: usize) -> usize {
    use std::sync::OnceLock;
    static SEGMENTS: OnceLock<usize> = OnceLock::new();
    static DATAGRAMS: OnceLock<usize> = OnceLock::new();
    let cell = if name == "QUINN_MAX_TRANSMIT_SEGMENTS" { &SEGMENTS } else { &DATAGRAMS };
    *cell.get_or_init(|| std::env::var(name).ok().and_then(|v| v.parse().ok()).unwrap_or(default))
}
'''
p.write_text(s)
PY
build
install -m 755 "$CARGO_TARGET_DIR/release/quinn-perf" "$PREFIX/bin/quinn-perf-gsocap"

printf '{"repository":"https://github.com/quinn-rs/quinn","commit":"%s","rustc":"%s"}\n' \
  "$COMMIT" "$(rustc --version)" >"$PREFIX/source.json"
echo "$FINGERPRINT" >"$PREFIX/fingerprint"
cd /
rm -rf "$WORK"
ls -l "$PREFIX/bin"
