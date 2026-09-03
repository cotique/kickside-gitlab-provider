# GitLab Connector

GitLab connector for Kickside: a read-only Data Sync pull source, plus
agent-tool traits an LLM agent can call interactively to read and to
create/update merge requests and notes.

## Auth

One credential mode: a personal or project access token
(`PRIVATE-TOKEN` header). GitLab is very commonly self-managed, so an
optional `base_url` field targets a self-managed instance — left blank, it
defaults to `https://gitlab.com`. Secrets live in the connection
component's `private_context`. The `read_api` scope is enough for
read-only use (the pull source, the Reader trait); the Writer/Manager
traits need the broader `api` scope on the same token field — nothing in
this module checks or enforces scope up front, a write call against an
under-scoped token simply fails with a real 403 from GitLab.

## Layout

- `client/` — low-level REST client (`api.lua`: `get`, plus `post`/`put`
  for write), auth + transport (`transport.lua`), shared types, safe
  output encoding (credential redaction), and the DataError mapping every
  failure path returns through.
- `connection/` — the `kickside.connection:connection` binding
  (`gitlab_connection`): `test_connection` (`GET /user`) and
  `discover_resources` (paginated `GET /projects`).
- `source/` — the merge-request source: `pull_core.lua` (pagination, item
  normalization — the tested, provider-specific logic) plus the
  `kickside.data:pullable` binding (`project_mrs_source`) and its
  `kickside.automation.port` (`project_mrs`).
- `traits/` — agent-tool traits (`reader`/`writer`/`manager`, each an
  `agent.trait` registry entry) plus their `read_tool`/`write_tool`
  `function.lua` entries and `read_tool_lib`/`write_tool_lib`
  `library.lua` implementations. An LLM agent picks a connection for one
  of these traits and calls the tool interactively ("list open MRs for
  this project", "create this MR", "comment on this MR") — this is not
  part of Data Sync and does not share the pull source's cursor/schedule
  machinery.

## Planes

- **B — source flows**: `project_mrs` pulls a selected project's merge
  requests on a schedule through Kickside Data Sync. Cursor-based,
  continuous — each `pull()` call returns a resumable cursor even once
  exhausted, so the same port keeps picking up new activity indefinitely.
  Keys-only reconcile (for Data Sync's own drift detection) is wired through
  the port's `reconcile.pull_keys` field, not a second `kickside.data:
  pullable` method — that contract binds exactly one, `pull`.
- **Agent tools**: `traits/reader` (`list_merge_requests`,
  `get_merge_request`, `list_merge_request_notes`), `traits/writer`
  (`create_merge_request`, `update_merge_request`, `create_note`), and
  `traits/manager` (both). The write tool never merges, approves, or
  deletes anything, and never touches repository files, branches,
  releases, settings, collaborators, or CI/CD pipelines — only
  merge-request-workflow mutations, matching the scope discipline of the
  real `kickside/github` writer/manager traits this was mirrored from.

The Data Sync pull source stays read-only, as it always was: no
create/comment/approve/merge method exists on it. Write capability exists
only through the `traits/writer`/`traits/manager` agent tools above.
