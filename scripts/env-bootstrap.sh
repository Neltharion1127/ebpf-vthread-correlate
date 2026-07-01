#!/usr/bin/env bash
# scripts/aws-bootstrap.sh — one-shot dependency bootstrap for running the
# ebpf-vthread-correlate benchmark matrix on a fresh AWS bare-metal instance.
#
# setup.sh downloads the JDK and checks only wget/mvn/bpftrace. This script fills
# in the rest of the toolchain that the other scripts silently assume is already
# installed — the JVMTI agent build needs gcc/make, Table A needs python3,
# gen-flamegraphs.sh needs perl + git (it clones FlameGraph, which is gitignored),
# and setup.sh itself needs wget/tar — and it fetches async-profiler, which is
# gitignored (*.so) so a fresh clone does not contain lib/libasyncProfiler.so.
#
# Targets Amazon Linux 2023 (dnf) and Ubuntu/Debian (apt). Idempotent: anything
# already present is skipped, so it is safe to re-run.
#
# Usage:
#   scripts/aws-bootstrap.sh                # install packages + fetch async-profiler + self-check
#   CHECK_ONLY=1 scripts/aws-bootstrap.sh   # self-check only (no sudo, no install, no download)
#   ASPROF_VERSION=4.4 scripts/aws-bootstrap.sh
#
# Fresh-box order:  scripts/aws-bootstrap.sh  ->  ./setup.sh  ->  scripts/profile-matrix.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

ASPROF_VERSION="${ASPROF_VERSION:-4.4}"   # matches README ("async-profiler 4.4")
LIB_DIR="$REPO_ROOT/lib"
ASPROF_SO="$LIB_DIR/libasyncProfiler.so"
CHECK_ONLY="${CHECK_ONLY:-0}"

# OS packages to install. Verified (2026-07) present under the SAME name in the
# default repos of both Amazon Linux 2023 (dnf) and Ubuntu (apt): `maven` and
# `bpftrace` are the two that needed checking; the rest are core packages.
# NOTE: on Ubuntu, bpftrace lives in the `universe` component (enabled by default
# on the stock cloud images). If apt cannot find it, enable universe by hand:
#   sudo add-apt-repository universe && sudo apt-get update
PKGS=(git wget maven gcc make python3 bpftrace perl tar)

# package -> the command it must put on PATH (used for the "already present" skip).
declare -A PKG_CMD=(
  [git]=git [wget]=wget [maven]=mvn [gcc]=gcc [make]=make
  [python3]=python3 [bpftrace]=bpftrace [perl]=perl [tar]=tar
)

# Commands the final self-check requires on PATH.
CHECK_CMDS=(git wget mvn gcc make python3 bpftrace perl tar)

say()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
ok()   { printf '  \033[32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m[!!]\033[0m %s\n' "$*"; }
die()  { printf '\n\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ---- distro / package-manager detection ----
detect_pm() {
  if command -v dnf     >/dev/null 2>&1; then echo dnf; return; fi
  if command -v apt-get >/dev/null 2>&1; then echo apt; return; fi
  echo unknown
}

pretty_distro() {
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    ( . /etc/os-release; printf '%s' "${PRETTY_NAME:-${ID:-unknown}}" )
  else
    printf 'unknown'
  fi
}

# ---- arch -> async-profiler asset tag (arm64 for Graviton, x64 for x86) ----
asprof_arch_tag() {
  case "$(uname -m)" in
    aarch64|arm64) echo arm64 ;;
    x86_64|amd64)  echo x64   ;;
    *) die "unsupported arch for async-profiler: $(uname -m)" ;;
  esac
}

install_packages() {
  local pm; pm="$(detect_pm)"
  say "install OS packages  (distro=$(pretty_distro), pm=$pm)"
  [ "$pm" = unknown ] && die "no supported package manager (need dnf or apt-get). Install by hand: ${PKGS[*]}"

  # Only hand sudo the packages that are actually missing (idempotent + fast).
  local missing=() p
  for p in "${PKGS[@]}"; do
    if command -v "${PKG_CMD[$p]}" >/dev/null 2>&1; then
      ok "$p already present (${PKG_CMD[$p]})"
    else
      missing+=("$p")
    fi
  done
  if [ "${#missing[@]}" -eq 0 ]; then
    ok "all packages already installed — nothing to install"
    return
  fi

  warn "installing: ${missing[*]}"
  case "$pm" in
    dnf) sudo dnf install -y "${missing[@]}" ;;
    apt) sudo apt-get update -y
         sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}" ;;
  esac
}

fetch_async_profiler() {
  say "async-profiler $ASPROF_VERSION  (arch=$(asprof_arch_tag))"
  if [ -f "$ASPROF_SO" ]; then
    ok "already present: $ASPROF_SO  (delete it to force a re-download)"
    return
  fi
  command -v wget >/dev/null 2>&1 || die "wget missing — needed to download async-profiler"

  local arch asset url tmp found
  arch="$(asprof_arch_tag)"
  asset="async-profiler-${ASPROF_VERSION}-linux-${arch}.tar.gz"
  # Verified release asset (v4.4): async-profiler-4.4-linux-arm64.tar.gz / -x64.tar.gz
  url="https://github.com/async-profiler/async-profiler/releases/download/v${ASPROF_VERSION}/${asset}"

  mkdir -p "$LIB_DIR"
  tmp="$(mktemp -d)"
  echo "  downloading $url"
  wget -q --show-progress "$url" -O "$tmp/$asset" || { rm -rf "$tmp"; die "download failed: $url"; }
  tar -xzf "$tmp/$asset" -C "$tmp"
  # The .so has lived at .../lib/libasyncProfiler.so since 3.0; find it rather than
  # hardcode the sub-path so a layout change does not silently break this.
  found="$(find "$tmp" -type f -name libasyncProfiler.so | head -1)"
  [ -n "$found" ] || { rm -rf "$tmp"; die "libasyncProfiler.so not found inside $asset (layout changed?)"; }
  cp "$found" "$ASPROF_SO"
  rm -rf "$tmp"
  ok "installed $ASPROF_SO"
  file "$ASPROF_SO" 2>/dev/null | sed 's/^/    /' || true
}

self_check() {
  say "self-check"
  local fail=0 c
  for c in "${CHECK_CMDS[@]}"; do
    if command -v "$c" >/dev/null 2>&1; then
      printf '  \033[32m[OK]     \033[0m %-10s %s\n' "$c" "$(command -v "$c")"
    else
      printf '  \033[31m[MISSING]\033[0m %-10s\n' "$c"
      fail=1
    fi
  done
  if [ -f "$ASPROF_SO" ]; then
    printf '  \033[32m[OK]     \033[0m %-10s %s\n' "libasyncProfiler.so" "$ASPROF_SO"
  else
    printf '  \033[31m[MISSING]\033[0m %-10s (expected at %s)\n' "libasyncProfiler.so" "$ASPROF_SO"
    fail=1
  fi
  echo
  if [ "$fail" -ne 0 ]; then
    warn "some dependencies are MISSING (see above) — fix them before running profile-matrix.sh"
    return 1
  fi
  ok "all dependencies present"
  echo "  next:  ./setup.sh   (downloads the JDK + writes config/env.sh)"
  echo "  then:  scripts/profile-matrix.sh"
  return 0
}

# ---- main ----
if [ "$CHECK_ONLY" = 1 ]; then
  self_check && exit 0 || exit 1
fi

install_packages
fetch_async_profiler
self_check && exit 0 || exit 1
