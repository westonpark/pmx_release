#!/bin/sh
# Copyright (c) 2026 Mike Warriner. All rights reserved. Proprietary — see LICENSE.
#
# pmx installer: installs the `pmx` binary with its `pm2`, `pm2-runtime`, `pm2-dev` and
# `pm2-docker` aliases, hands over from a running pm2 / pm2_prodman / older pmx daemon
# (save its process list, stop it, resurrect it under pmx), installs and enables the
# systemd service (`pmx startup systemd`), links to prodman, and removes other pm2 installs.
# Re-running it is safe: a healthy host is left alone (idempotent repair).
#
#   curl -fsSL https://github.com/westonpark/pmx_release/releases/latest/download/install.sh | sh
#   curl -fsSL …/install.sh | sh -s -- --dry-run
#
# Releases are public (02-decisions D-30): no token is needed to download them.
#
# Behaviour: docs/install.md; adapted from prodman/specs/09-client-pm2.md §9 for pmx
# (02-decisions D-01, D-13, D-16, D-30; 50-agent AG-801, AG-812…814).

set -eu
umask 022

PROG="pmx install"

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
  -h, --help         this help

Environment:
  PMX_INSTALL_DIR, PMX_VERSION, PMX_REPO (GitHub repository holding the releases,
  default westonpark/pmx_release, public: no token needed), PMX_BASE_URL, PMX_SETUP,
  PMX_PLATFORM (force an asset, e.g. linux-x64-musl),
  PMX_GITHUB_TOKEN (download through the GitHub API, for a private mirror; GITHUB_TOKEN /
  GH_TOKEN are used too, but only when PMX_REPO names another repository),
  PRODMAN_URL + PM2_PUBLIC_KEY + PM2_SECRET_KEY [+ PM2_MACHINE_NAME] (link to a bucket),
  PM2_RELINK=1 (replace a link to another bucket), PM2_HOME (default ~/.pm2),
  PM2_NODE (node used for the service PATH).
EOF
}

# --------------------------------------------------------------------------- options

DRY_RUN=0
UNINSTALL=0
OPT_VERSION=""
OPT_DIR=""
OPT_BASE=""
OPT_SETUP=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run | -n) DRY_RUN=1 ;;
        --uninstall) UNINSTALL=1 ;;
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
L_RELINK=${PM2_RELINK:-}
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

detect_platform() {
    if [ -n "${PMX_PLATFORM:-}" ]; then
        PLATFORM=$PMX_PLATFORM
        return
    fi
    _os=$(uname -s)
    case "$_os" in
        Linux) _os=linux ;;
        Darwin) _os=darwin ;;
        *) die "unsupported OS $_os: pmx runs on Linux and macOS" ;;
    esac
    _m=$(uname -m)
    case "$_m" in
        x86_64 | amd64) _arch=x64 ;;
        aarch64 | arm64) _arch=arm64 ;;
        *) die "no pmx binary for $_m (x64 and arm64 only)" ;;
    esac
    # A 64-bit kernel with a 32-bit userland, or Rosetta: trust the kernel's answer.
    _suffix=""
    if [ "$_os" = linux ]; then
        if ls /lib/ld-musl-* >/dev/null 2>&1 || { have ldd && ldd --version 2>&1 | grep -qi musl; }; then
            _suffix=-musl
        fi
    fi
    PLATFORM="$_os-$_arch$_suffix"
}

# --------------------------------------------------------------------------- download

TMP=""
cleanup() { [ -n "$TMP" ] && rm -rf "$TMP"; }
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
    NEW_SHA=$_got
}

# --------------------------------------------------------------------------- install

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
        if [ -e "$_p" ] || [ -L "$_p" ]; then
            _what="replacing $_p"
        else
            _what="linking $_p"
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

cmdline_of() {
    if [ -r "/proc/$1/cmdline" ]; then
        tr '\0' ' ' <"/proc/$1/cmdline" 2>/dev/null | sed 's/ *$//'
    elif have ps; then
        ps -o args= -p "$1" 2>/dev/null || true
    fi
}

# pid of an old-style titled daemon for this PM2_HOME ("PM2 v<v>: God Daemon (<home>)").
find_titled_daemon() {
    _title="God Daemon ($PM2_HOME)"
    if [ -d /proc/1 ]; then
        for _d in /proc/[0-9]*; do
            [ -r "$_d/cmdline" ] || continue
            _c=$(tr '\0' ' ' <"$_d/cmdline" 2>/dev/null) || continue
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
    if [ -L "/proc/$DPID/exe" ]; then
        _exe=$(readlink "/proc/$DPID/exe" 2>/dev/null || true)
        case "$_exe" in
            *" (deleted)") _stale=1 ;;
            ?*) _path=$_exe ;;
        esac
    fi
    _same=0
    if [ -n "$_path" ] && [ "$(resolve "$_path")" = "$(resolve "$BIN")" ]; then
        _same=1
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

node_dir() {
    if [ -x "$HOME/.pm2-current/bin/node" ]; then
        printf '%s\n' "$HOME/.pm2-current/bin"
    elif [ -n "${PM2_NODE:-}" ]; then
        dirname -- "$PM2_NODE"
    elif have node; then
        dirname -- "$(command -v node)"
    fi
}

setup_unit() {
    UNIT_FILE=$(unit_file_of)
    if [ -n "$UNIT_FILE" ]; then
        _exec=$(unit_exec "$UNIT_FILE")
        if [ -n "$_exec" ] && [ "$(resolve "$_exec")" = "$(resolve "$BIN")" ]; then
            UNIT_OK=1
            return 0
        fi
        say "updating $UNIT_FILE to run $BIN"
        _staged="$PM2_HOME/$UNIT.service.new"
        _r=$(sed_repl "$BIN")
        if is_dry; then
            say "[dry-run] would rewrite ExecStart/ExecReload/ExecStop of $UNIT_FILE to $BIN"
            UNIT_OK=1
            UNIT_CHANGED=1
            return 0
        fi
        sed -e "s|^\(ExecStart=[-@!+:]*\)[^ ]*|\1$_r|" \
            -e "s|^\(ExecReload=[-@!+:]*\)[^ ]*|\1$_r|" \
            -e "s|^\(ExecStop=[-@!+:]*\)[^ ]*|\1$_r|" "$UNIT_FILE" >"$_staged"
        if as_root install -m 644 "$_staged" "$UNIT_FILE" && as_root systemctl daemon-reload &&
            as_root systemctl enable "$UNIT" >/dev/null 2>&1; then
            rm -f "$_staged"
            UNIT_OK=1
            UNIT_CHANGED=1
        else
            warn "could not install the systemd service $UNIT (needs sudo); run: sudo install -m 644 $_staged $UNIT_FILE && sudo systemctl daemon-reload && sudo systemctl enable $UNIT, then re-run this script"
        fi
        return 0
    fi
    # No unit: pmx's own generator (60-extras §6, D-20).
    _nd=$(node_dir)
    _path=$PATH
    if [ -n "$_nd" ]; then
        case ":$_path:" in
            *":$_nd:"*) ;;
            *) _path="$_nd:$_path" ;;
        esac
    fi
    say "installing /etc/systemd/system/$UNIT.service to run $BIN (pmx startup systemd)"
    _cmd="env PATH=$_path PM2_HOME=$PM2_HOME $BIN startup systemd -u $USER_NAME"
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
    if as_root env "PATH=$_path" "PM2_HOME=$PM2_HOME" "HOME=$HOME" PM2_DISCRETE_MODE=true \
        "$BIN" startup systemd -u "$USER_NAME" >"$TMP/startup.log" 2>&1 &&
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
    if [ -f "$PM2_HOME/agent.json5" ] &&
        grep -q "\"public_key\"[[:space:]]*:[[:space:]]*\"$L_PUBLIC\"" "$PM2_HOME/agent.json5" 2>/dev/null; then
        say "already linked to this bucket"
        LINKED=1
        return 0
    fi
    if [ -f "$PM2_HOME/agent.json5" ] && grep -q '"public_key"' "$PM2_HOME/agent.json5" 2>/dev/null &&
        [ "$L_RELINK" != 1 ]; then
        warn "already linked to another bucket, so not relinked (set PM2_RELINK=1 to link to this one)"
        LINKED=1
        return 0
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
            say "not linked to prodman: re-run with PRODMAN_URL, PM2_PUBLIC_KEY and PM2_SECRET_KEY, or run pm2 link <secret> <public>"
        fi
        if [ "$SYSTEMD" != 1 ] && [ "$(uname -s)" = Darwin ]; then
            say "to start pmx at login, run: pm2 startup (and the command it prints)"
        fi
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
