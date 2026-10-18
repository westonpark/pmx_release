#!/usr/bin/env bash
# Copyright (c) 2026 Mike Warriner. Licensed for use with pmx; see https://github.com/westonpark/pmx_release.
# Installs a verified pmx for the actions (GHA-010).
#
# Env:
#   PMX_VERSION_INPUT           pinned (default) | latest | <x.y.z>
#   RUNNER_TOOL_CACHE           tool cache root (default ${TMPDIR:-/tmp}/pmx-tool-cache)
#   PMX_ACTIONS_PMX_JSON        path of pmx.json (TEST ONLY; default ../pmx.json)
#   PMX_ACTIONS_RELEASE_BASE    release download base URL (TEST ONLY)
#
# The trust anchor for the default (pinned) version is the sha256 in pmx.json, i.e. the commit of
# the action itself. Any other version is verified by the pinned pmx (minisign, built-in release
# keys) plus its .sha256 file.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
. "$here/common.sh"

require_unix_runner

want=${PMX_VERSION_INPUT:-pinned}
pmx_json=${PMX_ACTIONS_PMX_JSON:-$here/../pmx.json}
base=${PMX_ACTIONS_RELEASE_BASE:-https://github.com/westonpark/pmx_release/releases/download}
cache_root=${RUNNER_TOOL_CACHE:-${TMPDIR:-/tmp}/pmx-tool-cache}

version_re='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$'

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) platform=linux-x64 ;;
  Linux-aarch64 | Linux-arm64) platform=linux-arm64 ;;
  Darwin-arm64) platform=darwin-arm64 ;;
  Darwin-x86_64) platform=darwin-x64 ;;
  *) die "pmx has no build for $(uname -s) $(uname -m)" ;;
esac
asset=pmx-$platform

command -v jq >/dev/null 2>&1 || die "jq is required on the runner"
command -v curl >/dev/null 2>&1 || die "curl is required on the runner"

[ -f "$pmx_json" ] || die "pmx.json not found: $pmx_json"
pinned_ver=$(jq -r '.version // empty' "$pmx_json")
pinned_sha=$(jq -r --arg p "$platform" '.assets[$p].sha256 // empty' "$pmx_json")
if [ -z "$pinned_ver" ] || [ "$pinned_ver" = "0.0.0" ] || [ -z "$pinned_sha" ]; then
  die "this ref of the pmx actions pins no pmx release for $platform (pmx.json); set pmx-version to a release"
fi
[[ $pinned_ver =~ $version_re ]] || die "invalid pinned version in pmx.json: $pinned_ver"

fail() { # fail <version> <message>
  gha_error "pmx $1 failed verification: $2"
  exit 1
}

download() { # download <url> <dest>
  curl -fsSL --retry 3 -o "$2" "$1"
}

bin_dir() { printf '%s/pmx/%s/%s' "$cache_root" "$1" "$platform"; }

# install_pinned: downloads (unless cached and still matching) and checks the pinned binary.
install_pinned() {
  local dir tmp got
  dir=$(bin_dir "$pinned_ver")
  if [ -x "$dir/pmx" ] && [ "$(sha256_of "$dir/pmx")" = "$pinned_sha" ]; then
    return 0
  fi
  mkdir -p "$dir"
  tmp=$(mktemp "$dir/pmx.XXXXXX")
  if ! download "$base/v$pinned_ver/$asset" "$tmp"; then
    rm -f "$tmp"
    fail "$pinned_ver" "download of $asset failed"
  fi
  got=$(sha256_of "$tmp")
  if [ "$got" != "$pinned_sha" ]; then
    rm -f "$tmp"
    fail "$pinned_ver" "sha256 of $asset is $got, expected $pinned_sha (pmx.json)"
  fi
  chmod 0755 "$tmp"
  mv -f "$tmp" "$dir/pmx"
}

# install_other <version>: another release, verified through the pinned pmx.
install_other() {
  local ver=$1 dir work out expected got
  dir=$(bin_dir "$ver")
  work=$(mktemp -d)
  trap 'rm -rf "$work"' RETURN
  download "$base/v$ver/$asset" "$work/$asset" || fail "$ver" "download of $asset failed"
  download "$base/v$ver/$asset.minisig" "$work/$asset.minisig" || fail "$ver" "download of $asset.minisig failed"
  download "$base/v$ver/$asset.sha256" "$work/$asset.sha256" || fail "$ver" "download of $asset.sha256 failed"
  if ! out=$(PMX_FIRST_RUN=0 PMX_NO_BANNER=1 "$(bin_dir "$pinned_ver")/pmx" verify-signature \
    "$work/$asset" "$work/$asset.minisig" --asset "$asset" --version "$ver" 2>&1); then
    fail "$ver" "$(printf '%s' "$out" | tr '\n' ' ')"
  fi
  expected=$(cut -d' ' -f1 <"$work/$asset.sha256" | head -n1)
  got=$(sha256_of "$work/$asset")
  [ "$got" = "$expected" ] || fail "$ver" "sha256 of $asset is $got, expected $expected ($asset.sha256)"
  mkdir -p "$dir"
  chmod 0755 "$work/$asset"
  mv -f "$work/$asset" "$dir/pmx"
}

install_pinned
version=$pinned_ver
case "$want" in
  pinned | "") ;;
  latest)
    url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/westonpark/pmx_release/releases/latest) ||
      die "could not resolve the latest pmx release"
    version=${url##*/v}
    [[ $version =~ $version_re ]] || die "could not parse the latest pmx release from $url"
    ;;
  *)
    version=${want#v}
    [[ $version =~ $version_re ]] || die "invalid pmx-version '$want' (use pinned, latest or x.y.z)"
    ;;
esac
[ "$version" = "$pinned_ver" ] || install_other "$version"

bin=$(bin_dir "$version")/pmx
pmx_env
echo "pmx $version ($platform) at $bin"
"$bin" --version

if [ -n "${GITHUB_PATH:-}" ]; then dirname "$bin" >>"$GITHUB_PATH"; fi
if [ -n "${GITHUB_ENV:-}" ]; then
  {
    echo "PMX_FIRST_RUN=0"
    echo "PMX_NO_BANNER=1"
  } >>"$GITHUB_ENV"
fi
set_output version "$version"
set_output path "$bin"
