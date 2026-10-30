#!/bin/sh
# Copyright (c) 2026 Mike Warriner. All rights reserved. Proprietary — see LICENSE.
#
# pmx installer: installs the `pmx` binary with its `pm2`, `pm2-runtime`, `pm2-dev` and
# `pm2-docker` aliases, hands over from a running pm2 / pm2_prodman / older pmx daemon
# (save its process list, stop it, resurrect it under pmx), installs and enables the
# systemd service (`pmx startup systemd`), links to prodman, and removes other pm2 installs.
# Re-running it is safe: a healthy host is left alone (idempotent repair).
#
#   curl -fsSL https://pmx.aidra.io/install.sh | sh
#   curl -fsSL …/install.sh | sh -s -- --dry-run
#
# Releases are public (02-decisions D-30): no token is needed to download them.
#
# Behaviour: docs/install.md; adapted from prodman/specs/09-client-pm2.md §9 for pmx
# (02-decisions D-01, D-13, D-16, D-30, D-31; 50-agent AG-801, AG-812…814).

set -eu
umask 022

PROG="pmx install"

# Release signing (02-decisions D-48, 96-modules SVM-048). The release public keys (base64
# lines of keys/*.pub, space-separated; checked against keys/ by CI) and, filled in by the
# release workflow for the release this copy belongs to, its version and the SHA-256 of each
# pmx binary ("<platform>=<sha256> …"). Empty in the repository copy. Check this script by
# hand with: minisign -Vm install.sh -P <key> (key: docs/install.md).
PMX_SIGNING_KEYS="RWRu5PCt5yCSpMbA05EfMQAiknfqoxtbIZwE0tSCw5iRhpJht/4gboqm"
PMX_RELEASE_VERSION="9.15.0"
PMX_RELEASE_SHA256S="linux-x64=6f3eceeb3ec1d823f81629b93cb898e65f1877edbe6905ad0da54eea7e390ccb linux-arm64=0898cc9377f950f0653d30af18c960fe0e89f02ade82bc8e8fa921506c08d978 linux-x64-musl=e904175674d62eacc3fc04f4999296509e0971aaa1844675c14b125471357eef linux-arm64-musl=0246ebf6a9f811129bb70ed62ddec9c93595399167856d83a58181f93cce6ff2 linux-armhf=8f850d8fd9de7ccb6cbd47206ce1ee3df977055f1cc87a00382d41492a2440ce darwin-x64=64b619390a0fc5db117a60cedf1a64bb56bb1baf6e5615ba3acec5ab4e7cb46a darwin-arm64=482879ccf4aa6cf398d3045ad5cf6faebc6b9fb5421949da94dcac37f1c303e1"

usage() {
    cat <<'EOF'
Usage: install.sh [options]          (or: curl -fsSL …/install.sh | sh -s -- [options])

Options:
  --dry-run          show what would be done; change nothing (the binary is still
                     downloaded and verified in a temporary directory)
  --version <v>      install release v<v> instead of the latest (env PMX_VERSION)
  --dir <dir>        install directory (env PMX_INSTALL_DIR, default ~/.local/bin)
  --base-url <url>   directory holding the assets and .sha256 files (env PMX_BASE_URL)
  --no-setup         install the binary and aliases only (env PMX_SETUP=0)
  --uninstall        stop pmx, remove its service, binary and aliases (keeps PM2_HOME)
  --print-platform   print the release asset this host needs (e.g. linux-armhf) and exit
  -h, --help         this help

Environment:
  PMX_INSTALL_DIR, PMX_VERSION, PMX_REPO (GitHub repository holding the releases,
  default westonpark/pmx_release, public: no token needed), PMX_BASE_URL, PMX_SETUP,
  PMX_PLATFORM (force an asset, e.g. linux-x64-musl or linux-armhf),
  PMX_GITHUB_TOKEN (download through the GitHub API, for a private mirror; GITHUB_TOKEN /
  GH_TOKEN are used too, but only when PMX_REPO names another repository),
  PRODMAN_URL + PM2_PUBLIC_KEY + PM2_SECRET_KEY [+ PM2_MACHINE_NAME] (link to a bucket;
  relinks when the host is linked to another bucket or URL), PM2_HOME (default ~/.pm2),
  PM2_NODE (node used for the service PATH).
EOF
}

# --------------------------------------------------------------------------- options

DRY_RUN=0
UNINSTALL=0
PRINT_PLATFORM=0
OPT_VERSION=""
OPT_DIR=""
OPT_BASE=""
OPT_SETUP=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run | -n) DRY_RUN=1 ;;
        --uninstall) UNINSTALL=1 ;;
        --print-platform) PRINT_PLATFORM=1 ;;
        --no-setup) OPT_SETUP=0 ;;
        --version) [ $# -ge 2 ] || { usage >&2; exit 2; }; OPT_VERSION=$2; shift ;;
        --version=*) OPT_VERSION=${1#*=} ;;
        --dir) [ $# -ge 2 ] || { usage >&2; exit 2; }; OPT_DIR=$2; shift ;;
        --dir=*) OPT_DIR=${1#*=} ;;
        --base-url) [ $# -ge 2 ] || { usage >&2; exit 2; }; OPT_BASE=$2; shift ;;
        --base-url=*) OPT_BASE=${1#*=} ;;
        -h | --help) usage; exit 0 ;;
        *) printf '%s: unknown option %s\n' "$PROG" "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

# --------------------------------------------------------------------------- helpers

WARNINGS=""
NL='
'

say() { printf '%s\n' "$*"; }
die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }
warn() {
    printf 'warning: %s\n' "$*" >&2
    WARNINGS="$WARNINGS$*$NL"
}
have() { command -v "$1" >/dev/null 2>&1; }
is_dry() { [ "$DRY_RUN" = 1 ]; }

# Runs a command, or prints it in dry-run mode.
run() {
    if is_dry; then
        printf '[dry-run] would run: %s\n' "$*"
        return 0
    fi
    "$@"
}

# Canonical path of a file (symlinks resolved); the input when it cannot be resolved.
resolve() {
    _r=""
    if _r=$(readlink -f -- "$1" 2>/dev/null) && [ -n "$_r" ]; then
        printf '%s\n' "$_r"
    elif have realpath && _r=$(realpath -- "$1" 2>/dev/null) && [ -n "$_r" ]; then
        printf '%s\n' "$_r"
    else
        printf '%s\n' "$1"
    fi
}

sha256_of() {
    if have sha256sum; then
        sha256sum -- "$1" | awk '{print $1}'
    elif have shasum; then
        shasum -a 256 -- "$1" | awk '{print $1}'
    elif have openssl; then
        openssl dgst -sha256 -r "$1" | awk '{print $1}'
    else
        die "no sha256sum, shasum or openssl to verify the download"
    fi
}

# --------------------------------------------------------------------------- settings

[ -n "${HOME:-}" ] || die "HOME is not set"
INSTALL_DIR=${OPT_DIR:-${PMX_INSTALL_DIR:-$HOME/.local/bin}}
VERSION_REQ=${OPT_VERSION:-${PMX_VERSION:-latest}}
VERSION_REQ=${VERSION_REQ#v}
DEFAULT_REPO=westonpark/pmx_release
REPO=${PMX_REPO:-$DEFAULT_REPO}
BASE_URL=${OPT_BASE:-${PMX_BASE_URL:-}}
BASE_URL=${BASE_URL%/}
SETUP=${OPT_SETUP:-${PMX_SETUP:-1}}
# The public release repository needs no token (D-30); an ambient GITHUB_TOKEN / GH_TOKEN
# (CI runners) is only used for another repository, e.g. a private mirror.
GH_TOKEN_VALUE=${PMX_GITHUB_TOKEN:-}
if [ -z "$GH_TOKEN_VALUE" ] && [ "$REPO" != "$DEFAULT_REPO" ]; then
    GH_TOKEN_VALUE=${GITHUB_TOKEN:-${GH_TOKEN:-}}
fi
PM2_HOME=${PM2_HOME:-$HOME/.pm2}
PM2_HOME=${PM2_HOME%/}
export PM2_HOME
BIN="$INSTALL_DIR/pmx"
# Licences of the third-party code in the binary (a release asset), installed next to it.
NOTICES_ASSET=THIRD_PARTY_NOTICES.md
NOTICES_FILE="$INSTALL_DIR/pmx-THIRD_PARTY_NOTICES.md"
ALIASES="pm2 pm2-runtime pm2-dev pm2-docker"
USER_NAME=$(id -un 2>/dev/null || printf '%s' "${USER:-}")
USER_ID=$(id -u)
UNIT="pm2-$USER_NAME"

# Keys never reach pmx's environment (09 PM2-163): script-local copies only, passed as
# `pmx link` arguments.
L_URL=${PRODMAN_URL:-}
L_PUBLIC=${PM2_PUBLIC_KEY:-}
L_SECRET=${PM2_SECRET_KEY:-}
L_MACHINE=${PM2_MACHINE_NAME:-}
# PM2_RELINK is no longer needed (any other bucket or URL relinks); still cleared
unset PRODMAN_URL PM2_PUBLIC_KEY PM2_SECRET_KEY PM2_MACHINE_NAME PM2_RELINK
if [ -n "$L_URL" ]; then
    # 09 open issue 6: a stray KEYMETRICS_NODE would override the URL given here.
    unset KEYMETRICS_NODE
fi

# Every pmx call: no inherited agent/CLI state (09 PM2-163).
pmx_cmd() {
    (
        unset PM2_AGENT_ONLINE PM2_INTERACTOR_PROCESSING PM2_STATUS PM2_USAGE PM2_SECRET_KEY \
            PM2_PUBLIC_KEY 2>/dev/null || true
        exec "$BIN" "$@"
    )
}

# --------------------------------------------------------------------------- platform

# ELF architecture of a userland binary (normally /bin/sh): arm32hf, arm32sf, arm64, other, or
# nothing when it cannot be read. Distinguishes a 32-bit userland on a 64-bit kernel (D-31).
elf_arch() {
    have od || return 0
    _h=$(od -An -v -t x1 -N 40 "$1" 2>/dev/null | tr -d ' \n') || return 0
    case "$_h" in 7f454c46*) ;; *) return 0 ;; esac
    # byte 4: class (01 = 32-bit, 02 = 64-bit); bytes 18-19: e_machine (little-endian);
    # byte 37: second byte of the 32-bit e_flags (0x04 = EF_ARM_ABI_FLOAT_HARD).
    _cls=$(printf '%s' "$_h" | cut -c9-10)
    _mach=$(printf '%s' "$_h" | cut -c37-40)
    case "$_cls:$_mach" in
        01:2800)
            _f=$(printf '%s' "$_h" | cut -c75-76)
            if [ -n "$_f" ] && [ $((0x$_f & 4)) -ne 0 ]; then echo arm32hf; else echo arm32sf; fi
            ;;
        02:b700) echo arm64 ;;
        *) echo other ;;
    esac
}

# platform_for <os> <uname -m> <dpkg arch or ""> <elf_arch of /bin/sh or ""> <musl 0|1>
# Prints the release platform for those host facts, or nothing when there is no asset
# (02-decisions D-13, D-16, D-31).
platform_for() {
    _pos=$1 _pm=$2 _pdpkg=$3 _psh=$4 _pmusl=$5
    case "$_pos" in
        Darwin)
            case "$_pm" in
                x86_64 | amd64) echo darwin-x64 ;;
                arm64 | aarch64) echo darwin-arm64 ;;
            esac
            return 0
            ;;
        Linux) ;;
        *) return 0 ;;
    esac
    _ps=""
    [ "$_pmusl" = 1 ] && _ps=-musl
    case "$_pm" in
        x86_64 | amd64) echo "linux-x64$_ps"; return 0 ;;
        aarch64 | arm64)
            # A 64-bit kernel may run a 32-bit userland (Raspberry Pi OS 32-bit with the 64-bit
            # kernel): the userland decides, by dpkg or else by the ELF class of /bin/sh.
            case "$_pdpkg:$_psh" in
                armhf:* | armel:* | :arm32hf | :arm32sf) ;;
                *) echo "linux-arm64$_ps"; return 0 ;;
            esac
            ;;
        armv6* | armv7* | armv8* | arm | armhf) ;;
        *) return 0 ;;
    esac
    # 32-bit ARM: hard-float glibc only (no armel, no armhf musl asset).
    [ "$_pmusl" = 1 ] && return 0
    case "$_pdpkg" in
        armel) return 0 ;;
        "") [ "$_psh" = arm32sf ] && return 0 ;;
    esac
    echo linux-armhf
}

detect_platform() {
    if [ -n "${PMX_PLATFORM:-}" ]; then
        PLATFORM=$PMX_PLATFORM
        return
    fi
    _os=$(uname -s)
    case "$_os" in
        Linux | Darwin) ;;
        *) die "unsupported OS $_os: pmx runs on Linux and macOS" ;;
    esac
    _m=$(uname -m)
    _dpkg="" _sh="" _musl=0
    if [ "$_os" = Linux ]; then
        if have dpkg; then _dpkg=$(dpkg --print-architecture 2>/dev/null || true); fi
        # PMX_TEST_SH_ELF: tests only — the file probed instead of /bin/sh.
        _sh=$(elf_arch "${PMX_TEST_SH_ELF:-/bin/sh}")
        if ls /lib/ld-musl-* >/dev/null 2>&1 || { have ldd && ldd --version 2>&1 | grep -qi musl; }; then
            _musl=1
        fi
    fi
    PLATFORM=$(platform_for "$_os" "$_m" "$_dpkg" "$_sh" "$_musl")
    if [ -z "$PLATFORM" ]; then
        _what=$_m
        [ -n "$_dpkg" ] && _what="$_m, userland $_dpkg"
        [ "$_musl" = 1 ] && _what="$_what, musl"
        die "no pmx binary for $_what (linux x64/arm64 glibc or musl, linux armhf glibc, macOS x64/arm64)"
    fi
}

# --------------------------------------------------------------------------- download

TMP=""
# (if, not &&: the trap's status must not become the exit status when TMP is unset)
cleanup() { if [ -n "$TMP" ]; then rm -rf "$TMP"; fi; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# fetch <url> <out> [accept header]
fetch() {
    _accept=${3:-}
    if have curl; then
        if [ -n "$GH_TOKEN_VALUE" ] && [ -n "$_accept" ]; then
            curl -fsSL --retry 3 -H "Authorization: Bearer $GH_TOKEN_VALUE" -H "Accept: $_accept" -o "$2" "$1"
        elif [ -n "$GH_TOKEN_VALUE" ]; then
            curl -fsSL --retry 3 -H "Authorization: Bearer $GH_TOKEN_VALUE" -o "$2" "$1"
        else
            curl -fsSL --retry 3 -o "$2" "$1"
        fi
    elif have wget; then
        if [ -n "$GH_TOKEN_VALUE" ]; then
            die "downloading from the GitHub API needs curl (wget forwards the token to the asset host)"
        fi
        wget -q -O "$2" "$1"
    else
        die "neither curl nor wget is installed"
    fi
}

# Download through the GitHub API (private mirrors, with a token): sets ASSET_URLS for the release.
API_JSON=""
api_asset_url() {
    _name=$1
    if [ -z "$API_JSON" ]; then
        if [ "$VERSION_REQ" = latest ]; then
            _rel="https://api.github.com/repos/$REPO/releases/latest"
        else
            _rel="https://api.github.com/repos/$REPO/releases/tags/v$VERSION_REQ"
        fi
        API_JSON="$TMP/release.json"
        fetch "$_rel" "$API_JSON" "application/vnd.github+json" ||
            die "cannot read release information from $_rel"
    fi
    # One key per line, then pair each asset's API url with its name.
    awk '{ gsub(/[,{}]/, "\n"); print }' "$API_JSON" | awk -v want="$_name" '
        /"url"[ ]*:[ ]*"https:\/\/api\.github\.com\/repos\/.*\/releases\/assets\/[0-9]+"/ {
            u = $0; sub(/.*"url"[ ]*:[ ]*"/, "", u); sub(/".*/, "", u)
        }
        /"name"[ ]*:[ ]*"/ {
            n = $0; sub(/.*"name"[ ]*:[ ]*"/, "", n); sub(/".*/, "", n)
            if (n == want && u != "") { print u; exit }
        }'
}

download_verified() {
    ASSET="pmx-$PLATFORM"
    TMP=$(mktemp -d 2>/dev/null || mktemp -d -t pmxinstall)
    if [ -n "$BASE_URL" ]; then
        SRC="$BASE_URL"
    elif [ "$VERSION_REQ" = latest ]; then
        SRC="https://github.com/$REPO/releases/latest/download"
    else
        SRC="https://github.com/$REPO/releases/download/v$VERSION_REQ"
    fi
    if [ -n "$GH_TOKEN_VALUE" ] && [ -z "$BASE_URL" ]; then
        _a=$(api_asset_url "$ASSET")
        _s=$(api_asset_url "$ASSET.sha256")
        [ -n "$_a" ] || die "release has no asset $ASSET"
        [ -n "$_s" ] || die "release has no asset $ASSET.sha256"
        say "downloading $SRC/$ASSET"
        fetch "$_a" "$TMP/$ASSET" "application/octet-stream" || die "cannot download $SRC/$ASSET"
        fetch "$_s" "$TMP/$ASSET.sha256" "application/octet-stream" || die "cannot download $SRC/$ASSET.sha256"
    else
        say "downloading $SRC/$ASSET"
        fetch "$SRC/$ASSET" "$TMP/$ASSET" || die "cannot download $SRC/$ASSET"
        fetch "$SRC/$ASSET.sha256" "$TMP/$ASSET.sha256" || die "cannot download $SRC/$ASSET.sha256"
    fi
    _want=$(awk 'NR == 1 {print tolower($1); exit}' "$TMP/$ASSET.sha256")
    case "$_want" in
        *[!0-9a-f]* | "") die "$ASSET.sha256 holds no checksum" ;;
    esac
    [ ${#_want} -eq 64 ] || die "$ASSET.sha256 holds no checksum"
    _got=$(sha256_of "$TMP/$ASSET")
    [ "$_got" = "$_want" ] || die "checksum mismatch for $ASSET"
    NEW_SHA=$_got
    # D-48: verified before the new binary is ever run
    verify_signature
    chmod 755 "$TMP/$ASSET"
    if ! INFO=$("$TMP/$ASSET" --binary-info 2>/dev/null); then
        # A noexec temporary directory: verify it next to its destination instead.
        INFO=""
        if ! is_dry && mkdir -p "$INSTALL_DIR" 2>/dev/null && cp "$TMP/$ASSET" "$BIN.verify.$$" 2>/dev/null; then
            chmod 755 "$BIN.verify.$$"
            INFO=$("$BIN.verify.$$" --binary-info 2>/dev/null) || INFO=""
            rm -f "$BIN.verify.$$"
        fi
        [ -n "$INFO" ] || die "the downloaded binary does not run on this machine"
    fi
    VERSION=$(printf '%s\n' "$INFO" | sed -n 's/^{"version":"\([^"]*\)".*/\1/p')
    [ -n "$VERSION" ] || die "the downloaded binary does not run on this machine"
    if [ -n "$SIG_VERSION" ] && [ "$VERSION" != "$SIG_VERSION" ]; then
        die "$ASSET.minisig is for $ASSET v$SIG_VERSION"
    fi
    if [ -z "$SIG_VERSION" ] && signed_era "$VERSION"; then
        die "cannot download $SRC/$ASSET.minisig"
    fi
    download_notices
}

# D-48: releases from 9.5.0 on are signed; older ones are verified by SHA-256 only.
signed_era() {
    _sv=${1%%-*}
    _smaj=${_sv%%.*}
    _srest=${_sv#*.}
    _smin=${_srest%%.*}
    case "$_smaj$_smin" in *[!0-9]* | "") return 1 ;; esac
    [ "$_smaj" -gt 9 ] || { [ "$_smaj" -eq 9 ] && [ "$_smin" -ge 5 ]; }
}

# SVM-048: the asset's signature (with minisign when installed, else with the downloaded
# binary itself once its SHA-256 matched the value this script carries for its release).
verify_signature() {
    SIG_VERSION=""
    _sig="$TMP/$ASSET.minisig"
    if [ -n "$GH_TOKEN_VALUE" ] && [ -z "$BASE_URL" ]; then
        _m=$(api_asset_url "$ASSET.minisig")
        if [ -n "$_m" ]; then fetch "$_m" "$_sig" "application/octet-stream" || rm -f "$_sig"; fi
    else
        fetch "$SRC/$ASSET.minisig" "$_sig" 2>/dev/null || rm -f "$_sig"
    fi
    if [ ! -s "$_sig" ]; then
        # Whether a signature may be missing comes from what was asked for, never from the
        # download: only an explicitly pinned release older than 9.5.0, fetched from the
        # official release repository (no PMX_BASE_URL, no other PMX_REPO), is SHA-256 only.
        if [ "$VERSION_REQ" != latest ] && ! signed_era "$VERSION_REQ" \
            && [ -z "$BASE_URL" ] && [ "$REPO" = "$DEFAULT_REPO" ]; then
            say "pmx $VERSION_REQ predates signed releases: verified by SHA-256 only"
            return 0
        fi
        die "cannot download $SRC/$ASSET.minisig"
    fi
    _tc=$(sed -n 's/^trusted comment: //p' "$_sig" | head -n1)
    _tv=${_tc#pmx-release v}
    _tv=${_tv%% *}
    if [ "$_tc" != "pmx-release v$_tv $ASSET" ] || { [ "$VERSION_REQ" != latest ] && [ "$_tv" != "$VERSION_REQ" ]; }; then
        die "$ASSET.minisig is for ${_tc#pmx-release }"
    fi
    if have minisign; then
        _ok=0
        for _k in $PMX_SIGNING_KEYS; do
            if minisign -Vq -P "$_k" -m "$TMP/$ASSET" -x "$_sig" >/dev/null 2>&1; then _ok=1; fi
        done
        [ "$_ok" = 1 ] || die "bad signature on $ASSET"
        say "verified the signature of $ASSET (minisign)"
        SIG_VERSION=$_tv
        return 0
    fi
    # Without minisign the downloaded binary verifies itself, and it is run only when its
    # SHA-256 is the one this (signed) install.sh carries for its own release.
    _embedded=""
    if [ "$PMX_RELEASE_VERSION" = "$_tv" ]; then
        for _e in $PMX_RELEASE_SHA256S; do
            case "$_e" in "$PLATFORM="*) _embedded=${_e#*=} ;; esac
        done
    fi
    if [ -z "$_embedded" ]; then
        die "cannot verify the signature of pmx $_tv without minisign: install minisign, or use the install.sh of release v$_tv"
    fi
    [ "$_embedded" = "$NEW_SHA" ] || die "checksum mismatch for $ASSET (not the binary of this install.sh)"
    chmod 755 "$TMP/$ASSET"
    if ! _out=$("$TMP/$ASSET" verify-signature "$TMP/$ASSET" "$_sig" --asset "$ASSET" --version "$_tv" 2>&1); then
        die "${_out:-bad signature on $ASSET}"
    fi
    say "verified the signature of $ASSET"
    SIG_VERSION=$_tv
}

# The third-party notices: best effort (a release or mirror without them still installs).
NOTICES=""
download_notices() {
    _f="$TMP/$NOTICES_ASSET"
    if [ -n "$GH_TOKEN_VALUE" ] && [ -z "$BASE_URL" ]; then
        _u=$(api_asset_url "$NOTICES_ASSET")
        [ -n "$_u" ] || return 0
        fetch "$_u" "$_f" "application/octet-stream" 2>/dev/null || return 0
    else
        fetch "$SRC/$NOTICES_ASSET" "$_f" 2>/dev/null || return 0
    fi
    if grep -q 'Third-party notices' "$_f" 2>/dev/null; then
        NOTICES=$_f
    fi
    return 0
}

install_notices() {
    [ -n "$NOTICES" ] || return 0
    if [ -f "$NOTICES_FILE" ] && [ "$(sha256_of "$NOTICES_FILE")" = "$(sha256_of "$NOTICES")" ]; then
        return 0
    fi
    if is_dry; then
        say "[dry-run] would install $NOTICES_FILE"
    elif cp "$NOTICES" "$NOTICES_FILE.new.$$" && chmod 644 "$NOTICES_FILE.new.$$" &&
        mv -f "$NOTICES_FILE.new.$$" "$NOTICES_FILE"; then
        say "installed $NOTICES_FILE (third-party licences)"
    else
        rm -f "$NOTICES_FILE.new.$$"
        warn "could not write $NOTICES_FILE"
    fi
}

# --------------------------------------------------------------------------- install

# A short description of a file: "93.4 MB ELF executable", "1.2 KB script (#!/usr/bin/env node)",
# "symlink to <target>".
describe_file() {
    if [ -L "$1" ]; then
        printf 'symlink to %s' "$(readlink "$1")"
        return 0
    fi
    _sz=$(wc -c <"$1" 2>/dev/null | tr -d ' ') || _sz=0
    [ -n "$_sz" ] || _sz=0
    if [ "$_sz" -ge 1048576 ]; then
        _hs=$(awk -v b="$_sz" 'BEGIN { printf "%.1f MB", b / 1048576 }')
    elif [ "$_sz" -ge 1024 ]; then
        _hs=$(awk -v b="$_sz" 'BEGIN { printf "%.1f KB", b / 1024 }')
    else
        _hs="$_sz bytes"
    fi
    _magic=""
    if have od; then
        _magic=$(od -An -v -t x1 -N 4 "$1" 2>/dev/null | tr -d ' \n') || _magic=""
    fi
    case "$_magic" in
        7f454c46) _ty="ELF executable" ;;
        cffaedfe | cefaedfe | cafebabe) _ty="Mach-O executable" ;;
        2321*) _ty="script ($(head -n 1 "$1" 2>/dev/null | cut -c1-60))" ;;
        *) _ty="file" ;;
    esac
    printf '%s %s' "$_hs" "$_ty"
}

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
# Moves a foreign file at an alias path to <path>.replaced-<UTC timestamp>, with a warning.
set_aside() {
    _aside="$1.replaced-$STAMP"
    _desc=$(describe_file "$1")
    if is_dry; then
        say "[dry-run] would move $1 ($_desc, not the pmx alias) to $_aside"
        return 0
    fi
    if ! mv -f "$1" "$_aside"; then
        warn "$1 is $_desc, not the pmx alias, and could not be moved aside: alias not restored"
        return 1
    fi
    warn "$1 was $_desc, not the pmx alias (another pm2 installer?): moved it to $_aside and restored the alias"
}

BIN_CHANGED=0
OLD_BIN_VERSION=""
install_binary() {
    if [ -f "$BIN" ] && [ "$(sha256_of "$BIN")" = "$NEW_SHA" ]; then
        say "pmx $VERSION is already installed at $BIN"
    else
        if [ -x "$BIN" ]; then
            OLD_BIN_VERSION=$("$BIN" --binary-info 2>/dev/null | sed -n 's/^{"version":"\([^"]*\)".*/\1/p') || true
        fi
        if is_dry; then
            say "[dry-run] would install $BIN ($VERSION${OLD_BIN_VERSION:+, replacing $OLD_BIN_VERSION})"
        else
            mkdir -p "$INSTALL_DIR" || die "cannot create $INSTALL_DIR"
            # Copy next to the target, then rename over it: a running pmx keeps its old inode.
            cp "$TMP/$ASSET" "$BIN.new.$$" || die "cannot write $BIN.new.$$"
            chmod 755 "$BIN.new.$$"
            mv -f "$BIN.new.$$" "$BIN" || { rm -f "$BIN.new.$$"; die "cannot replace $BIN"; }
            say "installed $BIN: $INFO"
        fi
        BIN_CHANGED=1
    fi
    for _n in $ALIASES; do
        _p="$INSTALL_DIR/$_n"
        if [ -L "$_p" ] && [ "$(readlink "$_p")" = pmx ]; then
            continue
        fi
        if [ -d "$_p" ] && [ ! -L "$_p" ]; then
            warn "$_p is a directory: alias not created"
            continue
        fi
        _what="linking $_p"
        if [ -L "$_p" ] && [ "$(resolve "$_p")" = "$(resolve "$BIN")" ]; then
            # A link to pmx by another path: just normalised.
            _what="replacing $_p"
        elif [ -e "$_p" ] || [ -L "$_p" ]; then
            # Another program took the alias's place (e.g. a pm2_prodman installer run after
            # pmx, D-36): keep it aside and restore the alias.
            set_aside "$_p" || continue
            _what="restoring $_p"
        fi
        if is_dry; then
            say "[dry-run] would link $_p -> pmx"
        else
            if ! { ln -s pmx "$_p.new.$$" && mv -f "$_p.new.$$" "$_p"; }; then
                rm -f "$_p.new.$$"
                die "cannot create $_p"
            fi
            say "$_what -> pmx"
        fi
    done
    install_notices
}

# The $PM2_HOME layout, created as this user so later root-run commands (pmx startup)
# never own it (10-cli CLI-003).
ensure_home() {
    if is_dry; then
        [ -d "$PM2_HOME" ] || say "[dry-run] would create $PM2_HOME"
        return
    fi
    mkdir -p "$PM2_HOME/logs" "$PM2_HOME/pids" "$PM2_HOME/modules" || die "cannot create $PM2_HOME"
    [ -f "$PM2_HOME/module_conf.json" ] || printf '{}' >"$PM2_HOME/module_conf.json"
}

# --------------------------------------------------------------------------- privilege

SUDO=""
CAN_ROOT=0
detect_privilege() {
    if [ "$USER_ID" = 0 ]; then
        SUDO=""
        CAN_ROOT=1
    elif have sudo && sudo -n true 2>/dev/null; then
        SUDO="sudo -n"
        CAN_ROOT=1
    elif have sudo && [ -r /dev/tty ] && (: </dev/tty) 2>/dev/null; then
        SUDO="sudo"
        CAN_ROOT=1
    else
        SUDO=""
        CAN_ROOT=0
    fi
}

as_root() {
    if [ "$CAN_ROOT" != 1 ]; then
        return 1
    fi
    if [ "$SUDO" = sudo ]; then
        run sudo "$@" </dev/tty
    elif [ -n "$SUDO" ]; then
        run sudo -n "$@"
    else
        run "$@"
    fi
}

# --------------------------------------------------------------------------- daemon

pid_alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }

# A process run by a binfmt emulator (QEMU user mode, Rosetta: an emulated container, e.g.
# amd64 on an arm64 host) shows "<emulator> <binary> <argv0> <args>" in /proc/<pid>/cmdline;
# its title is the part from argv0 on.
strip_emulator() {
    case "$1" in
        */qemu-*" "*" "* | qemu-*" "*" "* | */rosetta" "*" "*)
            _se=${1#* }
            printf '%s' "${_se#* }"
            ;;
        *) printf '%s' "$1" ;;
    esac
}

cmdline_of() {
    if [ -r "/proc/$1/cmdline" ]; then
        strip_emulator "$(tr '\0' ' ' <"/proc/$1/cmdline" 2>/dev/null | sed 's/ *$//')"
    elif have ps; then
        strip_emulator "$(ps -o args= -p "$1" 2>/dev/null || true)"
    fi
}

# pid of an old-style titled daemon for this PM2_HOME ("PM2 v<v>: God Daemon (<home>)").
find_titled_daemon() {
    _title="God Daemon ($PM2_HOME)"
    if [ -d /proc/1 ]; then
        for _d in /proc/[0-9]*; do
            [ -r "$_d/cmdline" ] || continue
            _c=$(tr '\0' ' ' <"$_d/cmdline" 2>/dev/null) || continue
            _c=$(strip_emulator "$_c")
            case "$_c" in
                "PM2 v"*": $_title"*)
                    _o=$(stat -c %u "$_d" 2>/dev/null || echo "")
                    if [ -z "$_o" ] || [ "$_o" = "$USER_ID" ]; then
                        printf '%s\n' "${_d#/proc/}"
                        return 0
                    fi
                    ;;
            esac
        done
    elif have ps; then
        ps -axo pid=,uid=,args= 2>/dev/null | while read -r _p _u _a; do
            _a=$(strip_emulator "$_a")
            case "$_a" in
                "PM2 v"*": $_title"*)
                    if [ "$_u" = "$USER_ID" ]; then
                        printf '%s\n' "$_p"
                        return 0
                    fi
                    ;;
            esac
        done
    fi
    return 0
}

# Sets DPID (empty when none), DKIND (pmx|pm2|unknown), DVER (version or ?), DCURRENT (0|1).
detect_daemon() {
    DPID=""
    DKIND=""
    DVER="?"
    DCURRENT=0
    if [ -r "$PM2_HOME/pm2.pid" ]; then
        _p=$(tr -dc '0-9' <"$PM2_HOME/pm2.pid" 2>/dev/null || true)
        pid_alive "$_p" && DPID=$_p
    fi
    [ -n "$DPID" ] || DPID=$(find_titled_daemon)
    [ -n "$DPID" ] || return 0
    _cmd=$(cmdline_of "$DPID")
    _path=""
    case "$_cmd" in
        "PM2 v"*": God Daemon"*)
            # pm2 and pmx both title their daemon "PM2 v<version>: God Daemon (<home>)" (DMN-020).
            DVER=${_cmd#PM2 v}
            DVER=${DVER%%:*}
            case "$DVER" in
                [0-8].* | [0-8]) DKIND=pm2 ;;
                *) DKIND=pmx ;;
            esac
            ;;
        *" daemon" | *" daemon "*)
            # An untitled pmx daemon: "<path>/pmx daemon".
            _path=${_cmd%% *}
            case "$_path" in
                */pmx | pmx | */pm2 | pm2) DKIND=pmx ;;
                *) DKIND=unknown ;;
            esac
            ;;
        *pm2* | *PM2* | *pmx* | *Daemon.js*) DKIND=unknown ;;
        *)
            # A stale pm2.pid naming an unrelated process: no daemon.
            DPID=""
            return 0
            ;;
    esac
    [ "$DKIND" = pmx ] || return 0
    # Which file does it run? Linux: /proc/<pid>/exe (" (deleted)" once the binary was replaced).
    _stale=0
    _emulated=0
    if [ -L "/proc/$DPID/exe" ]; then
        _exe=$(readlink "/proc/$DPID/exe" 2>/dev/null || true)
        case "$_exe" in
            *" (deleted)") _stale=1 ;;
            */qemu-* | */rosetta)
                # binfmt emulation (see strip_emulator): exe is the emulator, the binary is the
                # next word of the raw command line
                _raw=$(tr '\0' ' ' <"/proc/$DPID/cmdline" 2>/dev/null || true)
                _raw=${_raw#* }
                _path=${_raw%% *}
                _emulated=1
                ;;
            ?*) _path=$_exe ;;
        esac
    fi
    _same=0
    if [ -n "$_path" ] && [ "$(resolve "$_path")" = "$(resolve "$BIN")" ]; then
        _same=1
    fi
    # emulated: no " (deleted)" to read; a binary just replaced at its path means it runs the old one
    if [ "$_emulated" = 1 ] && [ "$_same" = 1 ] && [ "$BIN_CHANGED" = 1 ]; then
        _stale=1
    fi
    if [ "$DVER" = "?" ] && [ "$_stale" = 0 ] && [ -n "$_path" ]; then
        if [ "$_same" = 1 ] && [ "$BIN_CHANGED" = 1 ]; then
            # The binary at its path was just replaced (no /proc to tell): it runs the old one.
            DVER=${OLD_BIN_VERSION:-?}
            [ "$DVER" = "$VERSION" ] && _stale=1
        elif [ -x "$_path" ]; then
            DVER=$("$_path" --binary-info 2>/dev/null | sed -n 's/^{"version":"\([^"]*\)".*/\1/p') || DVER=""
            [ -n "$DVER" ] || DVER="?"
        fi
    fi
    if [ "$DVER" = "$VERSION" ] && [ "$_stale" = 0 ]; then
        if [ -n "$_path" ] && [ "$_same" = 0 ]; then
            DVER="$DVER, another binary"
        else
            DCURRENT=1
        fi
    elif [ "$_stale" = 1 ] && [ "$DVER" = "$VERSION" ]; then
        DVER="$DVER, replaced binary"
    fi
}

daemon_label() {
    case "$DKIND" in
        pm2) printf 'pm2 %s' "$DVER" ;;
        pmx) printf 'pmx %s' "$DVER" ;;
        *) printf 'an unknown pm2 daemon' ;;
    esac
}

wait_gone() {
    _i=0
    while pid_alive "$1" && [ $_i -lt "$2" ]; do
        sleep 1
        _i=$((_i + 1))
    done
    ! pid_alive "$1"
}

# save: write dump.pm2 from the running daemon (pm2 or pmx: the RPC and dump format are shared).
save_list() {
    if is_dry; then
        say "[dry-run] would run: pmx save"
        return 0
    fi
    if ! pmx_cmd save >"$TMP/save.log" 2>&1; then
        cat "$TMP/save.log" >&2
        return 1
    fi
}

# stop_daemon: kill the running daemon (pid $DPID) outside any service.
stop_daemon() {
    if is_dry; then
        say "[dry-run] would run: pmx kill (pid $DPID)"
        return 0
    fi
    PM2_SERVICE_GUARD=off pmx_cmd kill >"$TMP/kill.log" 2>&1 || true
    if ! wait_gone "$DPID" 10; then
        kill -TERM "$DPID" 2>/dev/null || true
        if ! wait_gone "$DPID" 5; then
            kill -KILL "$DPID" 2>/dev/null || true
            wait_gone "$DPID" 3 || return 1
        fi
    fi
    return 0
}

HANDOVER_FAILED=0
# Save the running daemon's list and stop it. Returns 1 (and leaves it running) on failure.
save_and_stop() {
    if ! save_list; then
        warn "could not save the process list of the running PM2 (pid $DPID): it was left running"
        HANDOVER_FAILED=1
        return 1
    fi
    if ! stop_daemon; then
        warn "could not stop the running PM2 (pid $DPID)"
        HANDOVER_FAILED=1
        return 1
    fi
}

resurrect_outside_service() {
    if is_dry; then
        say "[dry-run] would run: pmx resurrect"
        return 0
    fi
    if ! PM2_SERVICE_GUARD=off pmx_cmd resurrect >"$TMP/resurrect.log" 2>&1; then
        cat "$TMP/resurrect.log" >&2
        warn "pmx resurrect failed: your apps are listed in $PM2_HOME/dump.pm2 (run: pm2 resurrect)"
        return 1
    fi
}

# --------------------------------------------------------------------------- systemd

SYSTEMD=0
UNIT_FILE=""
UNIT_CHANGED=0
UNIT_OK=0
detect_systemd() {
    if [ "$(uname -s)" = Linux ] && [ -d /run/systemd/system ] && have systemctl; then
        SYSTEMD=1
    fi
}

unit_file_of() {
    _f=$(systemctl show -p FragmentPath "$UNIT" 2>/dev/null | sed -n 's/^FragmentPath=//p')
    if [ -n "$_f" ] && [ -f "$_f" ]; then
        printf '%s\n' "$_f"
    fi
}

unit_exec() {
    sed -n 's/^ExecStart=[-@!+:]*\([^ ]*\).*/\1/p' "$1" | head -n 1
}

# Escapes a replacement for sed's s|…|…|.
sed_repl() { printf '%s\n' "$1" | sed 's/[\\|&]/\\&/g'; }

ESC=$(printf '\033')
# The service PATH and Node.js directory pmx would use (`pmx startup` dry run, D-36): sets
# WANT_PATH, WANT_NODE (empty when no Node.js) and NODE_NOTE (what was found).
WANT_PATH=""
WANT_NODE=""
NODE_NOTE=""
startup_plan() {
    _plan=$(env "PATH=$PATH" "PM2_HOME=$PM2_HOME" "HOME=$HOME" PM2_DISCRETE_MODE=true NO_COLOR=1 \
        PMX_STARTUP_DRY_RUN=1 "$BIN" startup systemd -u "$USER_NAME" --hp "$HOME" 2>/dev/null |
        sed "s/$ESC\[[0-9;]*m//g") || _plan=""
    WANT_PATH=$(printf '%s\n' "$_plan" | sed -n 's/^\[PM2\] Service PATH: //p' | head -n 1)
    NODE_NOTE=$(printf '%s\n' "$_plan" | sed -n 's/^\[PM2\]\(\[WARN\]\)\{0,1\} Node\.js for the service: //p' | head -n 1)
    WANT_NODE=$(printf '%s\n' "$_plan" | sed -n 's/^\[PM2\] Node\.js for the service: \([^ ]*\) (.*/\1/p' | head -n 1)
}

# 0 when ExecStart/ExecReload/ExecStop all run pmx itself (not an alias or another binary).
unit_runs_pmx() {
    _real=$(resolve "$BIN")
    for _k in ExecStart ExecReload ExecStop; do
        _e=$(sed -n "s/^$_k=[-@!+:]*\([^ ]*\).*/\1/p" "$1" | head -n 1)
        if [ -z "$_e" ]; then
            [ "$_k" = ExecStart ] && return 1
            continue
        fi
        [ -L "$_e" ] && return 1
        [ "$(resolve "$_e")" = "$_real" ] || return 1
    done
    return 0
}

unit_path_of() {
    sed -n 's/^Environment="\{0,1\}PATH=\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p' "$1" | tail -n 1
}

# Why the unit's PATH is wrong (D-36), or nothing: no PATH, Node.js directory missing, a
# directory in another user's home, or a home directory that does not exist.
unit_path_problem() {
    _up=$(unit_path_of "$1")
    if [ -z "$_up" ]; then
        echo "it sets no PATH"
        return 0
    fi
    if [ -n "$WANT_NODE" ]; then
        case ":$_up:" in
            *":$WANT_NODE:"*) ;;
            *)
                echo "its PATH lacks the Node.js directory $WANT_NODE"
                return 0
                ;;
        esac
    fi
    _ifs=$IFS
    IFS=:
    for _d in $_up; do
        case "$_d" in
            /home/* | /Users/* | /root | /root/* | /var/home/*) ;;
            *) continue ;;
        esac
        case "$_d/" in
            "$HOME"/*)
                if [ ! -d "$_d" ]; then
                    IFS=$_ifs
                    echo "its PATH has $_d, which does not exist"
                    return 0
                fi
                ;;
            *)
                IFS=$_ifs
                echo "its PATH has $_d, in another user's home"
                return 0
                ;;
        esac
    done
    IFS=$_ifs
}

# Installs a staged unit file over $UNIT_FILE (sudo), reloads and enables it.
install_unit_file() {
    if as_root install -m 644 "$1" "$UNIT_FILE" && as_root systemctl daemon-reload &&
        as_root systemctl enable "$UNIT" >/dev/null 2>&1; then
        rm -f "$1"
        UNIT_OK=1
        UNIT_CHANGED=1
    else
        warn "could not install the systemd service $UNIT (needs sudo); run: sudo install -m 644 $1 $UNIT_FILE && sudo systemctl daemon-reload && sudo systemctl enable $UNIT, then re-run this script"
    fi
}

setup_unit() {
    startup_plan
    if [ -n "$NODE_NOTE" ]; then
        say "Node.js for $UNIT: $NODE_NOTE"
    fi
    UNIT_FILE=$(unit_file_of)
    if [ -n "$UNIT_FILE" ]; then
        _fix_exec=0
        unit_runs_pmx "$UNIT_FILE" || _fix_exec=1
        _why=""
        [ -n "$WANT_PATH" ] && _why=$(unit_path_problem "$UNIT_FILE")
        if [ "$_fix_exec" = 0 ] && [ -z "$_why" ]; then
            UNIT_OK=1
            return 0
        fi
        _real=$(resolve "$BIN")
        [ "$_fix_exec" = 1 ] && say "updating $UNIT_FILE to run $_real"
        [ -n "$_why" ] && say "updating the PATH of $UNIT_FILE ($_why): $WANT_PATH"
        if is_dry; then
            say "[dry-run] would rewrite $UNIT_FILE and run systemctl daemon-reload"
            UNIT_OK=1
            UNIT_CHANGED=1
            return 0
        fi
        _staged="$PM2_HOME/$UNIT.service.new"
        cp "$UNIT_FILE" "$_staged.tmp" || { warn "cannot read $UNIT_FILE"; return 0; }
        if [ "$_fix_exec" = 1 ]; then
            # Only the first word of each Exec line changes; the rest of the unit is kept.
            _r=$(sed_repl "$_real")
            sed -e "s|^\(ExecStart=[-@!+:]*\)[^ ]*|\1$_r|" \
                -e "s|^\(ExecReload=[-@!+:]*\)[^ ]*|\1$_r|" \
                -e "s|^\(ExecStop=[-@!+:]*\)[^ ]*|\1$_r|" "$_staged.tmp" >"$_staged"
            mv -f "$_staged" "$_staged.tmp"
        fi
        if [ -n "$_why" ]; then
            # Replace the PATH line (or add one to [Service]) with the PATH pmx computes.
            WP=$WANT_PATH awk '
                /^Environment="?PATH=/ { if (!done) print "Environment=\"PATH=" ENVIRON["WP"] "\""; done = 1; next }
                { print }' "$_staged.tmp" >"$_staged"
            if ! grep -q '^Environment="\{0,1\}PATH=' "$_staged"; then
                WP=$WANT_PATH awk '
                    { print }
                    /^\[Service\]/ && !done { print "Environment=\"PATH=" ENVIRON["WP"] "\""; done = 1 }' \
                    "$_staged.tmp" >"$_staged"
            fi
        else
            mv -f "$_staged.tmp" "$_staged"
        fi
        rm -f "$_staged.tmp"
        install_unit_file "$_staged"
        return 0
    fi
    # No unit: pmx's own generator (60-extras §6, D-20, D-36: pmx finds Node.js itself).
    say "installing /etc/systemd/system/$UNIT.service to run $BIN (pmx startup systemd)"
    _cmd="env PATH=\$PATH PM2_HOME=$PM2_HOME $BIN startup systemd -u $USER_NAME --hp $HOME"
    if [ "$CAN_ROOT" != 1 ]; then
        warn "could not install the systemd service $UNIT (needs sudo); run: sudo $_cmd, then re-run this script"
        return 0
    fi
    if is_dry; then
        say "[dry-run] would run: ${SUDO:+$SUDO }$_cmd"
        UNIT_OK=1
        UNIT_CHANGED=1
        return 0
    fi
    if as_root env "PATH=$PATH" "PM2_HOME=$PM2_HOME" "HOME=$HOME" PM2_DISCRETE_MODE=true \
        ${PM2_NODE:+"PM2_NODE=$PM2_NODE"} ${NVM_DIR:+"NVM_DIR=$NVM_DIR"} \
        ${BUN_INSTALL:+"BUN_INSTALL=$BUN_INSTALL"} \
        "$BIN" startup systemd -u "$USER_NAME" --hp "$HOME" >"$TMP/startup.log" 2>&1 &&
        as_root systemctl daemon-reload; then
        UNIT_FILE=$(unit_file_of)
        UNIT_OK=1
        UNIT_CHANGED=1
    else
        cat "$TMP/startup.log" >&2
        warn "could not install the systemd service $UNIT; run: sudo $_cmd, then re-run this script"
    fi
}

unit_active() { [ "$(systemctl is-active "$UNIT" 2>/dev/null || true)" = active ]; }

# Puts the daemon under the unit, running this binary (09 PM2-167, 50 AG-814).
run_under_unit() {
    if unit_active; then
        if [ -n "$DPID" ] && [ "$DCURRENT" = 1 ] && [ "$UNIT_CHANGED" = 0 ]; then
            return 0
        fi
        if [ -z "$DPID" ] && [ "$UNIT_CHANGED" = 0 ]; then
            return 0
        fi
        say "restarting $UNIT (running $(daemon_label), installed pmx $VERSION)"
        if [ -n "$DPID" ] && ! save_list; then
            warn "could not save the process list of the running PM2 (pid $DPID): $UNIT not restarted"
            HANDOVER_FAILED=1
            return 0
        fi
        if ! as_root systemctl restart "$UNIT"; then
            warn "systemctl restart $UNIT failed (see: systemctl status $UNIT)"
        fi
        return 0
    fi
    _killed=0
    if [ -n "$DPID" ]; then
        say "moving the running PM2 ($(daemon_label), pid $DPID) into $UNIT"
        save_and_stop || return 0
        _killed=1
    fi
    if systemctl is-failed --quiet "$UNIT" 2>/dev/null; then
        # A unit that kept failing (e.g. its binary was replaced) may have hit its start limit.
        as_root systemctl reset-failed "$UNIT" || true
    fi
    say "starting $UNIT"
    if ! as_root systemctl start "$UNIT"; then
        warn "systemctl start $UNIT failed (see: systemctl status $UNIT)"
        if [ "$_killed" = 1 ]; then
            warn "PM2 restarted outside systemd"
            resurrect_outside_service || true
        fi
    fi
}

# --------------------------------------------------------------------------- prodman link

# A prodman URL as pmx stores it (50 AG-200): https:// added to a bare host (http:// for
# localhost or an IP), trailing slashes removed.
root_url() {
    _u=$1
    case "$_u" in
        "") ;;
        *://*) ;;
        localhost* | \[* | [0-9]*.[0-9]*) _u="http://$_u" ;;
        *) _u="https://$_u" ;;
    esac
    while [ "${_u%/}" != "$_u" ]; do _u=${_u%/}; done
    printf '%s' "$_u"
}

LINKED=0
link_prodman() {
    if [ -z "$L_PUBLIC" ] && [ -z "$L_SECRET" ]; then
        [ -f "$PM2_HOME/agent.json5" ] && LINKED=1
        return 0
    fi
    if [ -z "$L_URL" ] || [ -z "$L_PUBLIC" ] || [ -z "$L_SECRET" ]; then
        warn "not linked: set PRODMAN_URL, PM2_PUBLIC_KEY and PM2_SECRET_KEY together"
        [ -f "$PM2_HOME/agent.json5" ] && LINKED=1
        return 0
    fi
    # same bucket and same server → nothing; another bucket or server → relink (D-69)
    _cur_url=$(sed -n 's/.*"info_node"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$PM2_HOME/agent.json5" 2>/dev/null | head -n 1)
    if [ -f "$PM2_HOME/agent.json5" ] &&
        grep -q "\"public_key\"[[:space:]]*:[[:space:]]*\"$L_PUBLIC\"" "$PM2_HOME/agent.json5" 2>/dev/null; then
        if [ "$(root_url "$_cur_url")" = "$(root_url "$L_URL")" ]; then
            say "already linked to this bucket"
            LINKED=1
            return 0
        fi
        say "linked to this bucket at ${_cur_url:-the default server}: relinking to $L_URL"
    elif [ -f "$PM2_HOME/agent.json5" ] && grep -q '"public_key"' "$PM2_HOME/agent.json5" 2>/dev/null; then
        say "linked to another bucket: relinking"
    fi
    say "linking to $L_URL"
    _rc=0
    if is_dry; then
        say "[dry-run] would run: pmx link <secret> $L_PUBLIC${L_MACHINE:+ $L_MACHINE} --info-node $L_URL"
        LINKED=1
        return 0
    fi
    if [ -n "$L_MACHINE" ]; then
        pmx_cmd link "$L_SECRET" "$L_PUBLIC" "$L_MACHINE" --info-node "$L_URL" >/dev/null 2>&1 || _rc=$?
    else
        pmx_cmd link "$L_SECRET" "$L_PUBLIC" --info-node "$L_URL" >/dev/null 2>&1 || _rc=$?
    fi
    if [ "${_rc:-0}" != 0 ]; then
        warn "pmx link failed (see $PM2_HOME/agent.log)"
    fi
    [ -f "$PM2_HOME/agent.json5" ] && LINKED=1
    return 0
}

AGENT_RUNNING=0
agent_running() { pmx_cmd link info >/dev/null 2>&1; }

check_agent() {
    [ -f "$PM2_HOME/agent.json5" ] || return 0
    detect_daemon
    [ -n "$DPID" ] || return 0
    if is_dry; then
        return 0
    fi
    _i=0
    while [ $_i -lt 10 ]; do
        if agent_running; then
            AGENT_RUNNING=1
            return 0
        fi
        sleep 1
        _i=$((_i + 1))
    done
    say "starting the prodman agent"
    if pmx_cmd link >/dev/null 2>&1 && agent_running; then
        AGENT_RUNNING=1
    else
        warn "could not start the prodman agent (see $PM2_HOME/agent.log)"
    fi
}

# --------------------------------------------------------------------------- other installs

remove_other_installs() {
    _bin_real=$(resolve "$BIN")
    for _p in "$HOME"/.nvm/versions/node/* "$HOME"/.asdf/installs/nodejs/* \
        "$HOME"/.volta/tools/image/node/* "$HOME"/.local/share/fnm/node-versions/*/installation \
        /usr /usr/local /opt/homebrew; do
        [ -d "$_p/lib/node_modules/pm2" ] || continue
        say "removing the pm2 installed under $_p"
        _targets="$_p/lib/node_modules/pm2"
        for _b in pm2 pm2-dev pm2-docker pm2-runtime; do
            _f="$_p/bin/$_b"
            if [ -e "$_f" ] || [ -L "$_f" ]; then
                [ "$(resolve "$_f")" = "$_bin_real" ] && continue
                _targets="$_targets $_f"
            fi
        done
        if [ -w "$_p/lib/node_modules" ]; then
            # shellcheck disable=SC2086 # word splitting of the target list is intended
            run rm -rf $_targets || warn "could not remove the pm2 under $_p"
        else
            # shellcheck disable=SC2086
            as_root rm -rf $_targets || warn "could not remove the pm2 under $_p"
        fi
    done
    for _f in "$INSTALL_DIR"/pm2.new.* "$INSTALL_DIR"/pmx.new.*; do
        [ -e "$_f" ] || [ -L "$_f" ] || continue
        run rm -f "$_f"
    done
}

# --------------------------------------------------------------------------- uninstall

do_uninstall() {
    detect_privilege
    detect_systemd
    [ -x "$BIN" ] || die "pmx is not installed in $INSTALL_DIR"
    TMP=$(mktemp -d 2>/dev/null || mktemp -d -t pmxinstall)
    VERSION=$("$BIN" --binary-info 2>/dev/null | sed -n 's/^{"version":"\([^"]*\)".*/\1/p') || VERSION=""
    detect_daemon
    if [ -n "$DPID" ]; then
        say "saving the process list to $PM2_HOME/dump.pm2 and stopping pmx (pid $DPID)"
        save_list || warn "could not save the process list"
    fi
    if [ "$SYSTEMD" = 1 ] && [ -n "$(unit_file_of)" ]; then
        _e=$(unit_exec "$(unit_file_of)")
        if [ "$(resolve "$_e")" = "$(resolve "$BIN")" ]; then
            say "removing the systemd service $UNIT"
            as_root env PM2_HOME="$PM2_HOME" "$BIN" unstartup systemd -u "$USER_NAME" >/dev/null 2>&1 ||
                warn "could not remove $UNIT; run: sudo $BIN unstartup systemd -u $USER_NAME"
        fi
    fi
    detect_daemon
    if [ -n "$DPID" ]; then
        stop_daemon || warn "could not stop pmx (pid $DPID)"
    fi
    for _n in $ALIASES; do
        if [ -L "$INSTALL_DIR/$_n" ] && [ "$(readlink "$INSTALL_DIR/$_n")" = pmx ]; then
            run rm -f "$INSTALL_DIR/$_n"
        fi
    done
    run rm -f "$BIN"
    if [ -e "$NOTICES_FILE" ]; then
        run rm -f "$NOTICES_FILE"
    fi
    say "removed pmx${VERSION:+ $VERSION} from $INSTALL_DIR; $PM2_HOME (logs, dump.pm2, agent.json5) was kept"
    print_warnings
}

print_warnings() {
    if [ -n "$WARNINGS" ]; then
        say "warnings:"
        printf '%s' "$WARNINGS" | while IFS= read -r _w; do
            [ -n "$_w" ] && printf '  - %s\n' "$_w"
        done
    fi
    return 0
}

# --------------------------------------------------------------------------- summary

summary() {
    say ""
    if is_dry; then
        say "dry run: nothing was changed"
    fi
    if [ "$SETUP" = 0 ]; then
        say "pmx $VERSION is installed at $BIN (setup skipped)"
    else
        detect_daemon
        if [ -n "$DPID" ]; then
            _m="pmx $VERSION is running"
            if [ "$SYSTEMD" = 1 ] && [ "$UNIT_OK" = 1 ] && unit_active; then
                _m="$_m as the systemd service $UNIT"
            fi
            [ "$AGENT_RUNNING" = 1 ] && _m="$_m, prodman agent running"
            if is_dry; then
                _m="running now: $(daemon_label) (pid $DPID)"
            elif [ "$DCURRENT" != 1 ]; then
                _m="PM2 is running ($(daemon_label), pid $DPID), not pmx $VERSION"
            fi
            say "$_m"
        elif is_dry; then
            say "no daemon is running now"
        else
            say "pmx $VERSION is installed; no daemon is running yet (pm2 start <app>)"
        fi
        if [ "$LINKED" != 1 ]; then
            say "not linked to prodman: run pm2 link to sign in and pick a bucket, or re-run with PRODMAN_URL, PM2_PUBLIC_KEY and PM2_SECRET_KEY (or run pm2 link <secret> <public>)"
        fi
        if [ "$SYSTEMD" != 1 ] && [ "$(uname -s)" = Darwin ]; then
            say "to start pmx at login, run: pm2 startup (and the command it prints)"
        fi
    fi
    # The pm2_prodman binary unpacks its Bun runtime under $PM2_HOME/runtime (D-36).
    if [ -d "$PM2_HOME/runtime" ] && [ -n "$(ls -A "$PM2_HOME/runtime" 2>/dev/null)" ]; then
        _mb=$(du -sk "$PM2_HOME/runtime" 2>/dev/null | awk '{ printf "%.0f MB", $1 / 1024 }')
        say "note: $PM2_HOME/runtime holds the pm2_prodman Bun runtime (${_mb:-size unknown}); pmx does not use it, so it can be removed: rm -rf $PM2_HOME/runtime"
    fi
    _bin_real=$(resolve "$BIN")
    for _n in pmx pm2; do
        _found=$(command -v "$_n" 2>/dev/null || true)
        if [ -z "$_found" ]; then
            say "note: add $INSTALL_DIR to your PATH (export PATH=\"$INSTALL_DIR:\$PATH\")"
            break
        elif [ "$(resolve "$_found")" != "$_bin_real" ]; then
            warn "'$_n' on your PATH is $_found: put $INSTALL_DIR first"
        fi
    done
    print_warnings
}

# --------------------------------------------------------------------------- main

main() {
    if [ "$PRINT_PLATFORM" = 1 ]; then
        detect_platform
        say "$PLATFORM"
        return 0
    fi
    if [ "$UNINSTALL" = 1 ]; then
        do_uninstall
        return 0
    fi
    is_dry && say "dry run: no changes will be made"
    detect_platform
    download_verified
    install_binary
    if [ "$SETUP" = 0 ]; then
        summary
        return 0
    fi
    ensure_home
    detect_privilege
    detect_systemd
    detect_daemon

    if [ "$SYSTEMD" = 1 ]; then
        setup_unit
    fi
    if [ "$SYSTEMD" = 1 ] && [ "$UNIT_OK" = 1 ] && [ "$CAN_ROOT" = 1 ]; then
        run_under_unit
    else
        if [ -n "$DPID" ] && [ "$DCURRENT" != 1 ]; then
            say "restarting PM2 (running $(daemon_label), installed pmx $VERSION)"
            if save_and_stop; then
                resurrect_outside_service || true
            fi
        fi
        if [ "$SYSTEMD" = 1 ]; then
            detect_daemon
            if [ -n "$DPID" ]; then
                warn "PM2 is not running as a systemd service: nothing restarts it after a crash or reboot"
            fi
        fi
    fi

    link_prodman
    check_agent
    if [ "$HANDOVER_FAILED" = 1 ]; then
        warn "other pm2 installs were kept because the running PM2 could not be handed over"
    else
        remove_other_installs
    fi
    summary
}

main
