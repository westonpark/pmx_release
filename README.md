# pmx

**pmx is a native, Node-free process manager and a drop-in replacement for pm2**, with the
prodman monitoring agent built in. It is a single self-contained binary: no Node.js, npm or
Python is needed to run pmx itself — only by the applications it manages.

- **Drop-in for pm2.** Installs as `pmx` with `pm2`, `pm2-runtime`, `pm2-dev` and
  `pm2-docker` aliases. Same commands, same `~/.pm2` layout and file formats: your
  `dump.pm2`, ecosystem files, logs, log-rotation settings and prodman link carry over.
- **Node.js and Python apps.** Runs JavaScript and TypeScript apps on Node.js (fork and
  cluster mode) and Python apps (including multi-instance servers), with **automatic
  instrumentation** — metrics, errors, traces and profiling — injected at load time, with no
  code changes.
- **prodman agent included.** Link a host to a prodman server and it reports processes,
  metrics, logs and exceptions, takes remote actions and updates itself to new releases.
- **Takes over a running pm2.** The installer saves the process list of a running pm2 (or
  pm2_prodman) daemon, stops it and brings every app back under pmx, then points the
  boot-time service at pmx.

The binaries are free to download and use (see [Licence](#licence)). The source code is not
public; this repository holds the releases, this README, the licence and the installer.

## Contents

- [Supported platforms](#supported-platforms)
- [Quick install](#quick-install)
- [Installer options](#installer-options)
- [Manual install](#manual-install)
- [Upgrading from pm2 or pm2_prodman](#upgrading-from-pm2-or-pm2_prodman)
- [Verifying the install](#verifying-the-install)
- [Quick start](#quick-start)
- [Updating pmx](#updating-pmx)
- [Uninstall](#uninstall)
- [Licence](#licence)

## Supported platforms

| Platform | Release asset |
|---|---|
| Linux x86_64, glibc 2.17 or newer | `pmx-linux-x64` |
| Linux aarch64 (arm64), glibc 2.17 or newer | `pmx-linux-arm64` |
| Linux x86_64, musl (Alpine) | `pmx-linux-x64-musl` |
| Linux aarch64 (arm64), musl (Alpine) | `pmx-linux-arm64-musl` |
| Linux 32-bit ARM hard-float (armhf), glibc 2.17 or newer: Raspberry Pi with 32-bit Raspberry Pi OS (any model from the Pi 1 / Zero on), Debian / Ubuntu armhf | `pmx-linux-armhf` |
| macOS 11 or newer, Intel | `pmx-darwin-x64` |
| macOS 11 or newer, Apple silicon | `pmx-darwin-arm64` |

Every asset has a `<asset>.sha256` checksum file beside it. Windows is not supported, nor are
32-bit ARM soft-float (armel) and 32-bit ARM with musl.

**Raspberry Pi:** if `dpkg --print-architecture` prints `armhf` you need `pmx-linux-armhf`, even
when `uname -m` says `aarch64` (32-bit Raspberry Pi OS with the 64-bit kernel). If it prints
`arm64`, use `pmx-linux-arm64`. The installer works this out by itself;
`sh install.sh --print-platform` shows which asset it would pick.

## Quick install

```sh
curl -fsSL https://github.com/westonpark/pmx_release/releases/latest/download/install.sh | sh
```

The same installer is also on the `main` branch of this repository:

```sh
curl -fsSL https://raw.githubusercontent.com/westonpark/pmx_release/main/install.sh | sh
```

No GitHub account or token is needed. Run it as the user that runs your apps (not as root,
unless root runs them); it uses `sudo` only to install the systemd service and to remove a
pm2 installed system-wide. To see what it would do without changing anything:

```sh
curl -fsSL https://github.com/westonpark/pmx_release/releases/latest/download/install.sh | sh -s -- --dry-run
```

The installer:

1. picks the right binary for your OS, CPU and C library, downloads it with its `.sha256`
   file and verifies the checksum (a mismatch aborts the install);
2. installs `~/.local/bin/pmx` and the `pm2`, `pm2-runtime`, `pm2-dev`, `pm2-docker` aliases;
3. hands over from a running pm2 / pm2_prodman / older pmx daemon (save, stop, resurrect
   under pmx) — see [Upgrading](#upgrading-from-pm2-or-pm2_prodman);
4. on Linux with systemd, installs and enables the `pm2-<user>` service so your apps come back
   after a reboot;
5. links the host to prodman when you pass the link settings (below);
6. removes other pm2 installs (npm global installs under nvm, asdf, volta, fnm, `/usr`,
   `/usr/local`, Homebrew) so that `pm2` always means pmx;
7. prints a summary and any warnings.

Running it again is safe: it repairs whatever is missing and leaves a healthy host alone.

## Installer options

Options go after `sh -s --`; environment variables go before `sh` (or are exported).

| Option / variable | Default | Meaning |
|---|---|---|
| `--dry-run` | | show the plan, change nothing (the binary is still downloaded and verified in a temporary directory) |
| `--version <v>` / `PMX_VERSION` | latest | install a specific release, e.g. `9.0.0` |
| `--dir <dir>` / `PMX_INSTALL_DIR` | `~/.local/bin` | install directory |
| `--base-url <url>` / `PMX_BASE_URL` | this repository's releases | a mirror directory holding the assets and `.sha256` files |
| `--no-setup` / `PMX_SETUP=0` | | install the binary and aliases only: no hand-over, service, link or clean-up |
| `--uninstall` | | remove pmx (see [Uninstall](#uninstall)) |
| `-h`, `--help` | | show the installer's help |
| `PMX_PLATFORM` | detected | force an asset, e.g. `linux-x64-musl` on a glibc host, or `linux-armhf` |
| `PMX_REPO` | `westonpark/pmx_release` | GitHub repository to download releases from (for a mirror) |
| `PMX_GITHUB_TOKEN` | | token for a **private** mirror repository named by `PMX_REPO` (not needed for this repository) |
| `PRODMAN_URL`, `PM2_PUBLIC_KEY`, `PM2_SECRET_KEY` | | link the host to this prodman bucket (all three are needed) |
| `PM2_MACHINE_NAME` | host name | machine name shown in prodman |
| `PM2_RELINK=1` | | replace an existing link to a different bucket |
| `PM2_HOME` | `~/.pm2` | pmx home directory |
| `PM2_NODE` | `node` on the `PATH` | Node.js whose directory goes on the service's `PATH` |

Pin a version:

```sh
curl -fsSL https://github.com/westonpark/pmx_release/releases/download/v9.4.0/install.sh |
  PMX_VERSION=9.4.0 sh
```

Install somewhere else, binary only:

```sh
curl -fsSL https://github.com/westonpark/pmx_release/releases/latest/download/install.sh |
  sh -s -- --dir /opt/pmx/bin --no-setup
```

Install and link to prodman in one step (the keys are shown in your prodman bucket's
settings; they are passed only to `pmx link`, never exported to your apps):

```sh
curl -fsSL https://github.com/westonpark/pmx_release/releases/latest/download/install.sh |
  PRODMAN_URL=https://prodman.example.com PM2_PUBLIC_KEY=<public key> PM2_SECRET_KEY=<secret key> sh
```

## Manual install

Download the asset for your platform and its checksum file from the
[latest release](https://github.com/westonpark/pmx_release/releases/latest), verify it, and
put it on your `PATH` with the aliases.

Linux (replace the asset name to match your platform from the table above):

```sh
asset=pmx-linux-x64        # pmx-linux-arm64, pmx-linux-armhf, pmx-linux-x64-musl, pmx-linux-arm64-musl
base=https://github.com/westonpark/pmx_release/releases/latest/download
curl -fsSLO "$base/$asset" -O "$base/$asset.sha256"
sha256sum -c "$asset.sha256"              # must print: <asset>: OK
mkdir -p ~/.local/bin
install -m 755 "$asset" ~/.local/bin/pmx
for a in pm2 pm2-runtime pm2-dev pm2-docker; do ln -sf pmx ~/.local/bin/$a; done
```

On Alpine without `curl`, use `wget "$base/$asset" "$base/$asset.sha256"` instead.

macOS:

```sh
asset=pmx-darwin-arm64     # Intel Macs: pmx-darwin-x64
base=https://github.com/westonpark/pmx_release/releases/latest/download
curl -fsSLO "$base/$asset" -O "$base/$asset.sha256"
shasum -a 256 -c "$asset.sha256"          # must print: <asset>: OK
mkdir -p ~/.local/bin
install -m 755 "$asset" ~/.local/bin/pmx
for a in pm2 pm2-runtime pm2-dev pm2-docker; do ln -sf pmx ~/.local/bin/$a; done
```

The macOS binaries are not notarised. Downloads made with `curl` work as they are; if you
downloaded with a browser, clear the quarantine flag first:
`xattr -d com.apple.quarantine pmx-darwin-arm64`.

Make sure `~/.local/bin` comes before any other `pm2` on your `PATH` (`command -v pm2` should
print `~/.local/bin/pm2`). To start your apps at boot, run `pm2 startup` and the `sudo`
command it prints.

## Upgrading from pm2 or pm2_prodman

The installer does the whole hand-over for you: it saves the running daemon's process list to
`~/.pm2/dump.pm2`, stops the old daemon, starts pmx and resurrects every app, rewrites the
boot-time service to run pmx and removes the old pm2. If the list cannot be saved, the old
daemon is left running and you get a warning.

By hand, after a [manual install](#manual-install):

```sh
# with the old pm2 still first on your PATH:
pm2 save                     # writes ~/.pm2/dump.pm2
pm2 kill                     # stops the old daemon
npm uninstall -g pm2         # remove the old pm2 so it cannot be called by mistake
# now pm2 is pmx:
pm2 resurrect                # restarts every app from dump.pm2
pm2 startup                  # run the sudo command it prints
pm2 save
```

What carries over unchanged: `dump.pm2`, ecosystem files, logs, `module_conf.json` (including
the `pm2-logrotate` settings — log rotation is built in), and the prodman link: a linked host
reconnects with the same keys. Tools that `require('pm2')` keep working against the pmx daemon.

## Verifying the install

```sh
pmx -v            # 9.x.y
pm2 -v            # the same: pm2 is an alias of pmx
pm2 ls            # your processes, now managed by pmx
command -v pm2    # ~/.local/bin/pm2
```

On Linux with systemd: `systemctl status pm2-$USER`. If the host is linked, it appears in
prodman with runtime `pmx`.

## Quick start

```sh
pm2 start app.js --name api -i 4        # Node.js app in cluster mode, 4 instances
pm2 start server.ts --name web          # TypeScript
pm2 start worker.py --name worker       # Python (uses the app's virtualenv when it has one)
pm2 start ecosystem.config.js           # or an ecosystem file (JS, JSON or YAML)

pm2 ls                                  # list processes
pm2 logs api                            # tail logs
pm2 monit                               # terminal dashboard
pm2 reload api                          # zero-downtime reload
pm2 restart worker
pm2 stop web && pm2 delete web

pm2 save                                # remember the process list
pm2 startup                             # start it at boot (run the printed sudo command)

pm2 link <secret key> <public key>      # link this host to prodman
```

## Updating pmx

- Run the installer again — it upgrades the binary and restarts the daemon with your apps.
- Or, on a host linked to prodman, trigger an update from prodman: the agent downloads the
  latest release for its platform, verifies its checksum, replaces the binary and restarts.
  Set `PRODMAN_AUTO_UPDATE=off` in the daemon's environment to refuse remote updates.

## Uninstall

```sh
curl -fsSL https://github.com/westonpark/pmx_release/releases/latest/download/install.sh | sh -s -- --uninstall
```

This saves the process list, removes the `pm2-<user>` systemd service, stops the daemon and
removes `pmx` and its aliases. `~/.pm2` (logs, `dump.pm2`, the prodman link) is kept; delete it
yourself if you want it gone (`rm -rf ~/.pm2`).

## Licence

pmx is proprietary software, © 2026 Mike Warriner. All rights reserved. The binaries
published here may be downloaded and used free of charge, including commercially; they may
not be modified, reverse-engineered or redistributed in modified form. See
[LICENSE](LICENSE) for the full terms. The source code is not public.

The binaries include open-source components (Rust crates and the QuickJS JavaScript engine)
under MIT, Apache-2.0, BSD, ISC, Zlib, CC0, Unicode and similar permissive licences; those
components remain under their own licences, which the LICENSE terms above do not restrict.
Their copyright notices and licence texts are in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), which is also attached to each release and
installed next to the binary as `pmx-THIRD_PARTY_NOTICES.md`.

pm2 is a trademark of its respective owner; pmx is an independent implementation and is not
affiliated with or endorsed by the pm2 project.
