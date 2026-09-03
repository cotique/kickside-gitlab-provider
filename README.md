# GitLab Connector

Read-only Kickside connector for GitLab — a personal/project access token
connection provider plus a merge-request pull source for Kickside Data
Sync. Never creates, updates, merges, comments on, approves, or labels
anything.

See [`src/README.md`](src/README.md) for the module's own auth/layout/planes
summary (the same content the Wippy Hub's "Read Me" tab shows) and
[`BUILD-NOTES.md`](BUILD-NOTES.md) for build-time findings — including what's
confirmed vs. inferred about the `kickside.data:pullable` contract's exact
envelope, and the real reference source this module was built against.

## What this module provides

- `cotique.gitlab.connection:gitlab_connection` — a credential-only
  `contract.binding` (personal/project access token, optional self-managed
  `base_url`) implementing `kickside.connection:connection` +
  `kickside.contract:component` + `kickside.contract:deletable`.
- `cotique.gitlab.connection:test_connection` / `:discover_resources` —
  real, live GitLab API calls (`GET /user`, paginated `GET /projects`).
- `cotique.gitlab.client:api` / `:transport` / `:types` / `:output` /
  `:data_error` — the low-level REST client layer, empirically-verified
  pagination/auth mechanics, independently unit-tested.
- `cotique.gitlab.source:pull_core` — the real, tested merge-request
  pagination + normalize logic; `:pull_items` is the thin
  `kickside.data:pullable.pull` wrapper around it.
- `cotique.gitlab.source:project_mrs_source` implements
  `kickside.data:pullable`; `cotique.gitlab.source:project_mrs` is the
  `kickside.automation.port` entry exposing it to Data Sync.
- `test/` — an isolated standalone harness plus behavioral/wiring suites.

This module owns no persistence of its own — Kickside Data Sync's own engine
owns cursor/lease/schedule/dedup/id-map/sink routing. It ships no web
component and no custom HTTP endpoint — matches the real reference
connection providers (`kickside/discord`, `kickside/slack`, etc.) that need
no custom Connect/picker UI for a credential-only connection; see
`BUILD-NOTES.md`'s structural audit for what that comparison covered.

Package identity (`organization/module`), registry namespace
(`namespace:name`), and component instance IDs are different identities. Do
not derive one from another — the root `ns.definition` (`cotique.gitlab:
definition`) declares the namespace.

## Development

Install the current Wippy CLI from [Wippy releases](https://hub.wippy.ai/releases)
and Node.js 22 or newer:

```bash
wippy version
node --version
```

```bash
make verify        # resolves deps, lints, runs the standalone test suite on SQLite
make postgres-up
make test-pg        # same suite against PostgreSQL
make postgres-down
```

CI pins an exact Wippy CLI version (`WIPPY_VERSION` in
`.github/workflows/verify.yml`) rather than tracking `latest` — see
`BUILD-NOTES.md` for the confirmed regression that forced that pin.

## Publish to the Wippy Hub

Publishing requires a Wippy account with access to the `cotique` organization:

```bash
wippy auth login
wippy auth status
make release-check
make publish
```

`make publish` creates a private plugin by default. To publish publicly:

```bash
make publish VIS=public
```

The source manifest does not pin a release version — the publisher selects
the next valid version on the Hub; published releases remain immutable.

## Mount in a Kickside host

Bootstrap Kickside in a separate directory (first boot runs clean, without
the overlay, so the resolved graph and admin account exist):

```bash
mkdir ../kickside-host
cd ../kickside-host
wippy run kickside/kickside -c \
  --profile bootstrap_admin --profile local --profile sqlite \
  --set vars.local_port=8090 \
  --set vars.local_public_api_url=http://localhost:8090 \
  --set vars.bootstrap_admin_email=admin@example.com \
  --set vars.bootstrap_admin_password=change-me
```

Stop it once it settles, then create the untracked
`../kickside-host/.wippy.workspace.yaml`:

```yaml
version: "1.0"
workspace:
  replacements:
    cotique/gitlab: ../kickside-gitlab-provider
override:
  "app.env:defaults:values.GOV_MANAGED_NAMESPACES": "cotique.gitlab"
```

Restart the host from its directory with the overlay (bare `wippy run` reads
the locked graph; keep the same profiles and vars):

```bash
wippy run --config .wippy.workspace.yaml -c \
  --profile bootstrap_admin --profile local --profile sqlite \
  --set vars.local_port=8090 \
  --set vars.local_public_api_url=http://localhost:8090 \
  --set vars.bootstrap_admin_email=admin@example.com \
  --set vars.bootstrap_admin_password=change-me
```

The full loop, including Keeper-driven reactive development, is documented in
[The Dev Loop](docs/kickside-development/14-dev-loop.md).

The host stays source-free: its lock and vendor packs belong to the
deployment; your module checkout is the only local source. Never add local
replacements to `wippy.lock` and never point Keeper's application filesystem
sync at a conventional module `src/` tree.

## Repository map

```text
AGENTS.md                     development instructions
.kickside-module.json         initializer state and module identity
scripts/                      initializer and deterministic validation
wippy.yaml                    publish manifest; no fixed release version
src/                          registry declarations and Lua implementation
test/                         standalone Wippy harness; lock generated by setup
compose.test.yaml             disposable PostgreSQL matrix
docs/kickside-development/    Kickside developer Wiki snapshot
.github/workflows/verify.yml  Linux SQLite + PostgreSQL CI
```

Start with [AGENTS.md](AGENTS.md), even when you are not using an agent. The
handbook begins at
[Developer Handbook](docs/kickside-development/developer-handbook.md).

## Rules

- Never commit credentials, `.env`, `.wippy/`, a root `wippy.lock`, module
  packs, `node_modules`, or source maps.
- Never put an exact resolved version in an `ns.dependency`; exact versions
  belong in lock files.
- Never infer a registry namespace from a package name. Read `ns.definition`.
- Never add compatibility fallbacks or duplicate ownership to hide a broken
  contract.
- Never manufacture actor scope. Execution inherits the calling actor.
- Never synchronously drive thread projections from a read endpoint.
- A change is complete only after SQLite, PostgreSQL, and secret checks pass
  in proportion to what changed.

## Documentation provenance

The bundled handbook (`docs/kickside-development/`) is a public,
offline-readable snapshot of the published
[Kickside Wiki](https://hub.wippy.ai/kickside/kickside/wiki/docs/kickside-development/developer-handbook.md).
