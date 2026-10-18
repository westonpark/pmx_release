#!/usr/bin/env bash
# Copyright (c) 2026 Mike Warriner. Licensed for use with pmx; see https://github.com/westonpark/pmx_release.
# Shared helpers for the pmx actions (sourced, not executed). Bash on Linux/macOS runners only.

# gha_error <message>: workflow error annotation.
gha_error() { printf '::error::%s\n' "$*"; }

# die <message>: annotate and exit 1.
die() { gha_error "$*"; exit 1; }

# require_unix_runner: refuse Windows runners (GHA-001).
require_unix_runner() {
  case "$(uname -s)" in
    Linux | Darwin) ;;
    *) die "pmx actions need a Linux or macOS runner" ;;
  esac
}

# mask_value <value>: register every non-empty line of a secret with the runner log masker.
mask_value() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] && printf '::add-mask::%s\n' "$line"
  done <<<"$1"
  return 0
}

# set_output <name> <value>: single-line step output (no-op outside Actions).
set_output() {
  [ -n "${GITHUB_OUTPUT:-}" ] || return 0
  printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"
}

# require_value <name> <value>: fail with a clear message for a missing required input.
require_value() {
  [ -n "$2" ] || die "input '$1' is required"
}

# require_one_of <name> <value> <allowed...>: enum check for an input.
require_one_of() {
  local name=$1 value=$2 a
  shift 2
  for a in "$@"; do [ "$value" = "$a" ] && return 0; done
  die "input '$name' must be one of: $* (got '$value')"
}

# is_true <value>: true/false inputs.
is_true() { [ "$1" = "true" ]; }

# sha256_of <file>: lowercase hex digest.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# pmx_env: the environment every pmx call from an action runs with.
pmx_env() {
  export PMX_FIRST_RUN=0
  export PMX_NO_BANNER=1
}
