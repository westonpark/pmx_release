# pmx GitHub Actions

Composite actions that build, publish and deploy pmx bundles from GitHub Actions. Linux and macOS
runners only (x64 and arm64); Windows is not supported.

| Action | Does |
|---|---|
| `westonpark/pmx_release/actions/setup@v1` | installs a verified pmx |
| `westonpark/pmx_release/actions/bundle@v1` | `pmx bundle create` (optionally signed) |
| `westonpark/pmx_release/actions/publish@v1` | `pmx bundle publish` to prodman, a GitHub release or a URL; optionally deploys and waits |
| `westonpark/pmx_release/actions/deploy@v1` | `pmx bundle rollout` / `pmx bundle status --wait` |

Example workflows are in [`examples/workflows`](../examples/workflows): `review-flow`, `automated-flow`,
`github-store`, `python-uv`, `signed-release`, `env-store-flow` (pmx 9.11: the env lives in prodman's env
store, so the workflow needs only `PRODMAN_TOKEN` — no `env`/`env-key` secrets).

## Versioning

`@v1` is a moving major tag; `actions-v1.<minor>.<patch>` tags are immutable. The `pmx.json` next to
these files pins the pmx release the actions install by default, so `@v1` follows new pmx releases;
`pmx-version` pins one. For production pipelines pin the action by commit SHA:
`uses: westonpark/pmx_release/actions/publish@<40-hex> # actions-v1.2.0`.

## setup

| Input | Default | |
|---|---|---|
| `pmx-version` | `pinned` | `pinned` (version in `pmx.json`), `latest`, or `x.y.z` |

Outputs: `version`, `path`. The pinned binary is checked against the SHA-256 in `pmx.json` (the trust
anchor is the commit of the action). Any other version is checked by the pinned pmx
(`verify-signature`, built-in release keys) and its `.sha256` file. A failure ends the step with
`::error::pmx <version> failed verification: <reason>`. No pmx daemon is started.

## bundle

Inputs: `working-directory` (`.`), `config`, `component`, `application`, `version`, `build` (`true`),
`out` (`dist/bundle`), `sign` (`false`), `vars` (one `name=value` per line, for config
placeholders; pmx 9.11), `pmx-version`. Secret inputs: `env` (environment file contents,
shipped encrypted), `env-key`, `signing-key` — all optional: with prodman's env store (pmx 9.11) leave
`env`/`env-key` out and keep the variables in prodman. Env variants (one env per server or
environment in one bundle) are configured with `env.variants` in `pmx-bundle.config.json5`.
Outputs: `file`, `name`, `version`, `sha256`, `size`, `content-sha256`, `meta`, `application`,
`component`, `platform`, `unchanged` (when one bundle was built), and `count`, `out`, `bundles`
(JSON). A config with a `matrix` builds one bundle per entry into `<out>/<component>/`; pass the
`out` output as the publish action's `file` to publish them all.

## publish

Inputs: `file` (required), `prodman-url` (required), `bucket` (required), `token` (required unless
`auth: oidc`), `auth` (`token` or `oidc`), `store` (`prodman`, `github`, `url`), `github-token`
(default `github.token`, for `store: github`), `keep` (`5`), `channel`, `notes`, `changelog`
(`auto`), `deploy-to`, `wait` (`false`), `wait-timeout` (`30m`), `skip-unchanged` (`false`),
`pmx-version`.
Outputs: `release-id`, `release-url`, `rollout-id`, `rollout-status`, `rollout-url`.

## deploy

Inputs: `prodman-url`, `bucket`, `token` / `auth`, `ref` (`<application>/<component>@<version>`),
`environment` or `servers`, `canary`, `batch`, `on-failure` (`pause`, `rollback`, `continue`), `note`,
`wait` (`true`), `wait-timeout` (`30m`), `rollout-id` (only wait for an existing rollout),
`pmx-version`.
Outputs: `rollout-id`, `rollout-status`, `rollout-url`.

## Exit codes

`publish` and `deploy` pass pmx's exit code through: 0 success, 1 failure (including a rollout that
failed or rolled back), 2 wait timeout, 3 as documented for `pmx bundle status`.

## Security

- Inputs reach scripts only through `env:`, never through `${{ inputs.x }}` inside `run:`.
- Secret inputs are masked (`::add-mask::`) and handed to pmx through environment variables, never
  argv.
- The actions talk only to GitHub releases (to download pmx) and to the prodman URL you give.
  No telemetry.
- Examples use minimal `permissions:` blocks and never `pull_request_target`. Add `contents: write`
  only for `store: github` and `id-token: write` only for OIDC. When a signing key protects
  production, sign in a separate job bound to an environment with required reviewers
  (`signed-release.yml`).

## Test-only variables

`PMX_ACTIONS_RELEASE_BASE` (release download base URL), `PMX_ACTIONS_PMX_JSON` (path of `pmx.json`)
and `RUNNER_TOOL_CACHE` are read by `_lib/install-pmx.sh` so the installer can be tested against a fake
release. Do not set them in workflows.
