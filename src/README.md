# Cotique GitLab

Read-only GitLab connector for Kickside.

## Auth

One credential mode: a personal or project access token
(`PRIVATE-TOKEN` header), scoped to the narrowest available `read_api`
scope. GitLab is very commonly self-managed, so an optional `base_url`
field targets a self-managed instance — left blank, it defaults to
`https://gitlab.com`. Secrets live in the connection component's
`private_context`.

## Layout

- `client/` — low-level REST client (`api.lua`), auth + transport
  (`transport.lua`), shared types, safe output encoding (credential
  redaction), and the DataError mapping every failure path returns through.
- `connection/` — the `kickside.connection:connection` binding
  (`gitlab_connection`): `test_connection` (`GET /user`) and
  `discover_resources` (paginated `GET /projects`).
- `source/` — the merge-request source: `pull_core.lua` (pagination, item
  normalization — the tested, provider-specific logic) plus the
  `kickside.data:pullable` binding (`project_mrs_source`) and its
  `kickside.automation.port` (`project_mrs`).

## Planes

- **B — source flows**: `project_mrs` pulls a selected project's merge
  requests on a schedule through Kickside Data Sync. Cursor-based,
  continuous — each `pull()` call returns a resumable cursor even once
  exhausted, so the same port keeps picking up new activity indefinitely.
  Keys-only reconcile (for Data Sync's own drift detection) is wired through
  the port's `reconcile.pull_keys` field, not a second `kickside.data:
  pullable` method — that contract binds exactly one, `pull`.

Read-only, always: no create/comment/approve/merge method exists anywhere in
this module.
