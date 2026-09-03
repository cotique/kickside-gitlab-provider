# Build notes — cotique/gitlab

Working notes from building this module. Generic Kickside/Wippy/tooling
knowledge only. Written in the same spirit as `cotique/eng-metrics`'
`docs/BUILD-NOTES.md` (a sibling module built alongside this one) — several
findings below independently reproduce entries from that file, which is
useful cross-confirmation, not coincidence.

## Hub components checked (per AGENTS.md "reuse before you build")

- **`wippy search gitlab`** and **`wippy search bitbucket`** — both empty,
  re-confirmed as the first step of this session (2026-09-02), matching the
  shared build brief's own note that this was last confirmed empty the same
  day. No existing GitLab or Bitbucket connector to reuse; building from
  scratch is correct.
- **`wippy search github`** — found `kickside/github` v0.1.8: OAuth-primary
  connection (with a documented stored-PAT fallback binding,
  `kickside.github.connection:github_connection`), a
  `kickside.github.source:repo_items` automation port pulling GitHub
  issues/PRs, agent-facing reader/writer/manager traits. Used as the
  reference shape throughout (see the shared build brief), never as a
  runtime dependency of this module.
- **`wippy search connection`** — confirmed `kickside/connection` v0.1.36
  (connection contracts + `base_connection` boilerplate) and
  `kickside/component` v0.1.36 (component service) as the platform layer
  this module binds into, per `docs/kickside-development/04-connections-and-integrations.md`.
- **`wippy search "kickside data"` / `sync`** — found `kickside/sync` v0.1.57
  ("Kickside Data Sync automation kind"). Did **not** end up depending on
  this — `kickside.data:pullable`/`:writable` resolve transitively via
  `kickside/component`/`kickside/connection`/`kickside/contract`, not
  `kickside/sync` and not `kickside/core` either (verified mechanically,
  see below), and nothing else in this module needed `kickside/sync`.
- No OAuth needed (GitLab uses personal/project access tokens only, per the
  provider brief) — `kickside/oauth` is deliberately not a dependency.

### Verifying which package owns `kickside.data:pullable` — corrected, an
earlier experiment here was wrong

Moved to the shared platform findings file
(`C:\claude\work\wippy\work-wippy\FINDINGS.md`) — see "The
`kickside.data:pullable` contract's real envelope, method surface, and
package ownership (verified against real unpacked source)" (the package-
ownership facts are platform-wide, not GitLab-specific).

**Local fix applied:** removed `dep.kickside.core` from `src/_index.yaml`
entirely. Re-verified: `wippy update` + `wippy registry list --ns
"kickside.data*"` still returns all 4 entries without it. `make verify`
re-run clean after the removal (37/37).

## Structure built

Mirrors `kickside/github`'s real registry shape (per the shared build
brief), namespace `cotique.gitlab`:

- `cotique.gitlab.connection:connection_lib` — resolves
  `component_id` from ambient `ctx`, delegates credential resolution to
  `client:transport`.
- `cotique.gitlab.connection:get_status` / `:delete` — thin
  delegates to `kickside.connection:base_connection` (see the open item
  below on the exact export shape).
- `cotique.gitlab.connection:test_connection` — real `GET /user`
  call.
- `cotique.gitlab.connection:discover_resources` — paginated
  `GET /projects?membership=true&...` listing.
- `cotique.gitlab.connection:gitlab_connection` — the
  `contract.binding` tying the above into `kickside.connection:connection` +
  `kickside.contract:component` + `kickside.contract:deletable`, per the
  Minimal Provider Example shape in `04-connections-and-integrations.md`.
- `cotique.gitlab.client:api` / `:transport` / `:types` /
  `:output` / `:data_error` — the low-level REST client layer. `api.lua` is
  **not** a metatable/class object (see "Wippy's type checker and
  metatables" below) — `client:api.new(...)` returns a plain table of
  closures, matching this codebase's own convention (`repo.lua` in the
  original template scaffold, `connection_lib.lua`, etc.).
- `cotique.gitlab.source:pull_core` — the real, tested pagination +
  fetch + normalize logic. No dependency on the guessed pullable envelope
  (see below).
- `cotique.gitlab.source:pull_items` / `:pull_keys` — thin wrappers
  around `pull_core`, per the unverified-envelope item below.
- `cotique.gitlab.source:project_mrs_source` — implements
  `kickside.data:pullable` (methods: `pull` only — see the correction
  below).
- `cotique.gitlab.source:project_mrs` — the
  `kickside.automation.port` registry entry.

### Deliberate deviation from the mirrored `kickside/github` shape:
`base_url` credential field

GitLab is very commonly self-managed, unlike GitHub (the reference
`kickside/github` binding only supports github.com). The credential schema
here adds an optional `base_url` field, defaulting to `https://gitlab.com`
in code (`client:types.DEFAULT_BASE_URL`, applied in `client:transport`) when
left blank. This is a justified improvement over the mirrored shape, not an
oversight — GitLab's own product supports self-managed instances as a
first-class deployment mode, and a connector that hardcodes gitlab.com would
be unusable for a large fraction of real GitLab users.

### Deliberate scope decision: no agent-tool traits

`kickside.github.traits:*` (reader/writer/manager agent tools) has no
counterpart here. Out of explicit scope for this task per the shared build
brief — noted here so it reads as a decision, not an oversight.

## RESOLVED: `kickside.data:pullable`'s exact envelope

**2026-09-02, later the same session:** real, unpacked source for
`git.wippy.ai/kickside/providers` became available locally at
`providers-master/providers-master/` (the `kickside/github` and
`kickside/atlassian` monorepo this checkout previously could only see
packed). Read directly (not summarized secondhand):

- `providers-master/github/src/source/pull_core.lua` and
  `pull_core_test.lua`
- `providers-master/atlassian/src/jira/source/pull_core.lua` and
  `pull_core_test.lua` (a second independent real example — Jira, not
  GitHub — confirming the envelope is a platform-wide contract, not a
  GitHub idiosyncrasy)
- `providers-master/github/src/client/data_error.lua`
- `providers-master/github/src/source/_index.yaml` and
  `providers-master/atlassian/src/jira/source/_index.yaml`
- `providers-master/atlassian/test/pullable_conformance.lua` and
  `providers-master/atlassian/test/_index.yaml`

This section originally read "OPEN" and documented the envelope below as
INFERRED BY ANALOGY to `kickside.data:writable.write`. That inference was
**wrong in several concrete ways**, now corrected against real ground
truth:

The full envelope shape (item wrapping, table cursor, `next_cursor`
semantics), the method-surface correction (`pull` only — no `pull_keys`
method on the contract; keys-only reconcile is wired via the automation
port's `reconcile:` field instead), the `context_required`/component_id-
resolution-order disagreement between the two real references, and the
DataError taxonomy's real function surface are all platform-wide facts, not
GitLab-specific — moved to the shared platform findings file
(`C:\claude\work\wippy\work-wippy\FINDINGS.md`), see "The
`kickside.data:pullable` contract's real envelope, method surface, and
package ownership (verified against real unpacked source)".

**What changed in this module's own code to apply the correction:** the
failure envelope is now `{ success = false, error = { code, message,
retriable, scope }, retry_after_ms? }` (previously a *bare* `{ code,
message, retriable, scope }` table that callers wrapped themselves) —
every call site (`client/api.lua`, `source/pull_core.lua`,
`source/pull_items.lua`, `source/pull_keys.lua`,
`connection/test_connection.lua`, `connection/discover_resources.lua`) was
updated accordingly. This is the one place the fix touched files outside
`source/`, `client/data_error.lua`, and `source/_index.yaml`:
`client/api.lua`'s two `client:get()` failure branches now build their
DataError through `data_error.from_result`/`data_error.failure` instead of
the removed `from_http`/`from_transport`/`envelope` functions, and
`test_connection.lua`/`discover_resources.lua` read `rerr.error.message`
instead of `rerr.message` since the value they get back is now the full
wrapped envelope, not a bare error table. None of `client/api.lua`'s actual
HTTP/auth logic (headers, pagination header parsing, retry semantics)
changed — only its error-construction call sites, forced by the
data_error rewrite.

**What was NOT changed, confirmed still correct:** `connection/` (the
connection binding itself), `client/transport.lua`, `discover_resources`'s
and `test_connection`'s actual HTTP calls, and the `credential_schema` — all
independently confirmed correct against
`providers-master/github/src/connection/_index.yaml` and
`providers-master/github/src/client/transport.lua`.

**Verification — the pullable conformance kit, not just inspection.**
`providers-master/atlassian/test/pullable_conformance.lua` was copied
verbatim into `test/src/pullable_conformance.lua` and registered in
`test/src/_index.yaml` exactly as `providers-master/atlassian/test/_index.yaml`
registers it (`library.lua`, `modules: [registry, json]`). It works by
calling `registry.get("kickside.data:pullable")` **at test time** to load
the real, live JSON schema for `pull`'s output from this module's own real
`kickside/core` dependency, and validates actual `pull()`/`pull_keys()`
pages against it — the definitive check, not inspection-by-analogy.
`test/src/pull_core_test.lua`'s `"passes the pullable conformance kit
offline"` test runs it against a fake `client:api` + fake `transport`, no
real network call, and passes. `make verify` and `make test-pg` both pass
end to end (37/37 test cases each; see the bottom of this file for the
`make verify` tail and `test-pg` port note).

### Historical context (why this was open, kept for the record)

We did not originally have access to `kickside.data:pullable`'s real Lua
source or a working implementation of it. `kickside/github` (the reference
module) ships as a packed Hub module — `wippy registry show <id> --json`
returns `"data": null` for every entry in it; the Hub Structure/Bindings
tabs surface only the same declared `meta`, never method bodies; the source
repo `git.wippy.ai/kickside/providers` needed auth this checkout didn't
have. This was the exact same wall `cotique/eng-metrics` hit for
`kickside.atlassian.jira:api` (its own `docs/BUILD-NOTES.md` #3a/#3b).

**What is CONFIRMED** (via `wippy registry show kickside.data:pullable --json`
and the Hub's Bindings tab, per the shared build brief, plus one correction
found empirically during this build — see below):

- The contract id is `kickside.data:pullable`, comment: "Stateless cursored
  producer. Engine owns cursor, lease, schedule, dedup, id-map, and sink
  routing."
- `kickside/github`'s `kickside.github.source:repo_items_source` implements
  it; its `pull_items` entry's own comment is literally "kickside.data:
  pullable.pull for GitHub repository issues / pull requests" — confirming
  the method name is `pull`.
- The failure envelope `{ code, message, retriable, scope }` is confirmed
  generic — it is the exact shape of `kickside.data:writable.write`'s
  failure return (the ONLY real, unpacked, verified example of a
  `kickside.data:*` contract method's Lua calling convention available
  anywhere accessible to us: `src/sink/write.lua` in this module's own
  original template scaffold, before it was removed as part of this build —
  see the "What to remove" section of the shared build brief).
- **CORRECTION, found empirically during this build** (not part of the
  original brief's investigation): `kickside.data:pullable` binds **only**
  `pull`. It has **no** `pull_keys` method. This was discovered once
  `kickside/core` became a real, unpacked test-harness dependency (see "The
  standalone harness's real transitive dependency depth" below) — the
  platform's own contract-binding validator rejected the original binding
  at boot:
  ```
  Error: failed to load state: transaction rejected for registry.commit:
  bound method is not defined in contract definition:
  cotique.gitlab.source:project_mrs_source binds
  kickside.data:pullable.pull_keys
  ```
  A `pull_keys` method was originally inferred from a SEPARATE fact — that
  `kickside/github` ships its own `pull_keys` entry whose comment reads
  "Keys-only GitHub repository issue / pull request listing used by Data
  Sync reconcile" — and the (wrong) assumption that this was a second method
  on the same `kickside.data:pullable` contract. It is not. No second
  "keys"/"reconcile" contract exists anywhere in this module's full resolved
  dependency graph either (`wippy registry list --ns "kickside*" | grep
  contract.definition` — checked exhaustively, see below).

**What remains INFERRED, not confirmed:**

- `pull`'s request/response envelope: request `{ config, cursor }` (no
  `sink_op`/`idempotency_key`, those are write-specific); success response
  `{ success = true, items = {...}, next_cursor = "..."|nil, has_more =
  true|false }`. Inferred by direct analogy to the confirmed `write.lua`
  shape.
- How a keys-only reconcile hook (which clearly exists — `kickside/github`
  ships one) is actually wired, now that we know it is **not** a second
  method on `kickside.data:pullable`. Candidates not yet checked: a
  differently-named contract we don't have visibility into (the Hub only
  shows `meta` for packed modules, so an entirely separate contract id is
  plausible and would not show up in our dependency graph unless something
  we depend on also depends on it), a convention-based function id read
  directly off the automation port's registry entry, or something else
  entirely.
- Whether `kickside.data:pullable`'s `contract.binding` methods actually
  need `context_required: [component_id]` — inferred by analogy to the
  connection contract's own documented convention (a Data Sync automation
  is inherently tied to one connection component, mirroring the general
  "component-backed provider" pattern throughout this platform), but the
  pullable contract itself does not document this explicitly anywhere
  reachable from this checkout. This module's binding declares it; if wrong,
  it is a one-line change to `source/_index.yaml`.

**Where this is implemented:** `src/source/pull_items.lua` (the `pull`
wrapper) carries the full, unmissable version of this comment directly above
its exported function, per the shared build brief's instruction.
`src/source/pull_keys.lua` is kept — the underlying logic
(`pull_core.list_merge_request_keys`) is real and tested — but is not
currently bound to anything; its header explains the correction in full.

**What is genuinely engineering value regardless of how this resolves:**
`src/source/pull_core.lua` (pagination + fetch + normalize against the real,
verified GitLab REST API) has zero dependency on the guessed envelope and is
independently unit-tested (`test/src/pull_core_test.lua`, 9 cases, against a
plain Lua fake `client:api` — no real network call).

**What would resolve this:** real source/repo access to
`git.wippy.ai/kickside/providers`, or a working Keeper console against a
booted host with `kickside/github` installed unpacked (this session's
`kickside-host` sidecar could not get far enough to expose that — see
"Adjacent: bootstrapping a bare `kickside/kickside` host" below, for
completeness, though this was not pursued further given the alternate path
already worked). **This is what happened** — see the "RESOLVED" section
above.

## Secondary open item: `base_connection`'s exact export shape

Lower severity than the pullable envelope above, but the same category of
uncertainty. `docs/kickside-development/04-connections-and-integrations.md`
states plainly that a provider's `get_status`/`delete` "delegate to the base
library" and calls the pattern "a thin adapter," but nowhere documents
`kickside.connection:base_connection`'s actual exported function
name/signature. `kickside/connection` also ships packed
(`wippy registry show kickside.connection:base_connection --json` →
`"data": null`), and the Hub's own page fetch for this module (tried via
`https://hub.wippy.ai/kickside/connection/structure` and `/bindings`)
confirms the same visibility wall in its own words: "the actual binding
implementations and library function signatures... are not visible in this
registry page excerpt."

`src/connection/get_status.lua` and `delete.lua` make the smallest possible
assumption: `base_connection` exports a table with `get_status`/`delete`
functions, called with varargs passthrough (no argument shape assumed
beyond "a function by that name exists"). If wrong, only those two files
need to change. Not otherwise blocking — this module's own harness boots
successfully with `kickside/connection` as a real dependency (see below),
which at least confirms `kickside.connection:base_connection` *exists* and
loads; it does not confirm the call signature, since nothing in this
module's test suite actually invokes `get_status`/`delete` against a live
component (the harness has no real security actor/scope, per
`13-testing.md`'s "Harness Limits" — the same limitation the docs describe
for any contract-open path that needs one).

## Empirically-verified REST API pagination shapes (live calls made
2026-09-02 — per the shared build brief, reused here without re-verifying
independently, since the brief's own investigation was already direct/live)

### GitLab (`https://gitlab.com/api/v4`, or a self-managed `base_url`)

- Offset pagination via `page`/`per_page` query params.
- `x-next-page` response header is empty string (not absent) when there is
  no next page; `Link` header also carries `rel="next"`.
- `X-Total`/`X-Total-Pages` headers are **not** present on list endpoints —
  `src/source/pull_core.lua` never depends on a total count to decide when
  to stop paginating, only on `x-next-page`.
- Auth: `PRIVATE-TOKEN: <token>` header.
- Real merge_request fields used by the normalizer: `id`, `iid`,
  `project_id`, `title`, `state`, `author` (object: `id`, `username`,
  `name`), `source_branch`, `target_branch`, `created_at`, `updated_at`,
  `merged_at`, `web_url`.

Implemented in `src/client/api.lua` (`get_header` does a case-insensitive
header lookup — Go's HTTP transport may canonicalize casing differently
than GitLab's own lowercase docs use it, and this was not independently
re-verified against a live response's actual header casing in this
session, only guarded against defensively).

## Practices/issues hit and how they were resolved

### 1. Whole-repo CRLF contamination (resolved — same root cause as
`cotique/eng-metrics` issue #1, wider blast radius)

`git config core.autocrlf` was `true` at the time this repo was originally
checked out (before `core.autocrlf false` + `.gitattributes` were applied
locally, per this task's setup) — so every file materialized with CRLF line
endings, and `.gitattributes`'/`core.autocrlf=false`'s effect on *already
checked-out* files is nothing; they only govern new checkouts/normalizations
going forward. Unlike the `eng-metrics` precedent (which hit this through
one specific script's `\n`-only line splitting), this session hit it through
a much more consequential path — see finding #2 below — and on inspection
the contamination turned out to affect essentially the **entire** repository
(every `.md`, `.yaml`, `.lua`, `.ts`, `.vue`, the root `Makefile`, etc. — 60+
files), not just one script.

**Fix:** stripped trailing `\r` from every affected text file in place
(scanned via `file <path> | grep CRLF`, confirmed zero remain afterward).
`.gitattributes` (`* text=auto eol=lf`) will keep this from recurring for
anyone who clones fresh from this point on.

### 2. `wippy update`'s workspace-replacement handling is broken on a
brand-new lock, on the locally-installed CLI (v0.3.33a) — fixed upstream in
the CLI version CI actually uses (RESOLVED, but genuinely surprising —
documented in full because the workaround required is non-obvious)

Setting up the standalone harness hit a `wippy update` bootstrap bug: on the
locally-installed CLI (`v0.3.33a`), `wippy update` only reads
`workspace.replacements` when a `wippy.lock` already exists for that
directory — on a from-scratch resolve it silently falls through to Hub
lookup for the locally-replaced module and fails with `module not found`.
Confirmed fixed in `v0.3.35a` (the same "latest" CI resolves). Moved to the
shared platform findings file (`C:\claude\work\wippy\work-wippy\FINDINGS.md`)
— see the addendum on "CI: a raw `.wippy.yaml` override targeting a
workspace-replaced module's entry stopped resolving in wippy runtime
v0.3.35a" (point 1) — this is a platform CLI bug, not GitLab-specific, and
reproduces identically against a known-working sibling module's harness.

**Superseded:** the one-time local bootstrap workaround used to get
`make verify` green under the older CLI (temporarily removing the harness's
own `gitlab_provider_harness.dep.module` entry, running `wippy update`
once, restoring it, running `wippy update` again) is no longer needed —
see "Follow-up" below, where that same `ns.dependency` entry was later
removed from the harness entirely.

### 3. Wippy Luau-style type checker does not follow `setmetatable`-based
method dispatch (resolved — changed the API client's shape, not the type
checker)

Moved to the shared platform findings file
(`C:\claude\work\wippy\work-wippy\FINDINGS.md`) — see "More Luau/`wippy
lint` type-checker gotchas: metatable method dispatch, paired `(value,
err)` narrowing, and untyped table parameters" (item 1) — this is a
`wippy lint`/Luau type-checker behavior, not specific to this module's own
code shape.

**Practice adopted in this codebase:** prefer "a function that returns a
table of closures" over "a function that returns a metatable-tagged
object" for anything that needs per-instance state (`client:api.new`
rewritten this way; matches `repo.lua`/`connection_lib.lua`/
`transport.lua`'s existing convention) — the type checker resolves this
shape fine, because it sees the method as a literal field on the table
rather than something reached through `__index`.

### 4. `cannot call method on optional value without nil check` — the type
checker does not narrow `T?` just from checking the paired `err` return
(resolved)

Moved to the shared platform findings file
(`C:\claude\work\wippy\work-wippy\FINDINGS.md`) — see "More Luau/`wippy
lint` type-checker gotchas: metatable method dispatch, paired `(value,
err)` narrowing, and untyped table parameters" (item 2) — a `wippy lint`
type-checker behavior, not specific to this module.

**Practice adopted in this codebase:** always guard both halves of a
`(value, err)` return explicitly (`if err or not client then ... end`)
before using `value`, even where the convention "obviously" implies
exactly one of them is set. Fixed everywhere this pattern appears
(`discover_resources.lua`, `test_connection.lua`, `pull_items.lua`,
`pull_keys.lua`).

### 5. The standalone harness's real transitive dependency depth (resolved
— this module's own dependencies pull in a much larger graph than the
module conceptually needs)

`kickside/core` alone resolves to **16 total modules** once its own
transitive graph is included: `kickside/component`, `kickside/connection`,
`kickside/contract`, `kickside/core`, `kickside/doc2md`, `kickside/jobs`,
`kickside/uploads`, `wippy/agent`, `wippy/bootloader`, `wippy/llm`,
`wippy/migration`, `wippy/security`, `wippy/session`, `wippy/terminal`,
`wippy/test`, `wippy/views`. None of `kickside/uploads`, `wippy/session`, or
`wippy/views` are things this module needs conceptually — they came along
because `kickside/core` bundles its full engine (threads, events,
projections, jobs, lifecycle, retention, scheduler) as one package, and a
standalone harness has to boot the **entire** resolved registry graph before
any test can run (per `13-testing.md`'s "Harness Limits": "every
`ns.requirement` of every transitive kickside dependency must be wired
through bootloader `parameters`").

Discovered iteratively, exactly per `13-testing.md`'s documented procedure
("run `wippy test`, wire the slot behind each 'parameter not found' or link
error, repeat until boot passes") — each failure named one specific missing
resource:

1. `kickside.connection:ui_static` — needed `ui_server`/`api_router` wired
   (same category as `eng-metrics`' BUILD-NOTES #14 finding for
   `kickside/settings`).
2. `kickside.uploads:ui_static` — a transitive dependency of `kickside/core`
   pulled in `kickside/uploads` wholesale; needed `api_router`, `ui_server`,
   `database_resource`, `env_storage`, and `storage_id` (wired to a new
   `store.memory` harness entry) all wired, purely to satisfy boot.
3. `wippy.session.env:checkpoint_function_id` — traced to `wippy/session`'s
   own `env_storage` requirement not being wired yet (the function-id
   env.variable's underlying storage reference was malformed without it);
   wiring `wippy.session:api_router`/`database_resource`/`env_storage`/
   `default_host` resolved it. The `*_function_id`/`*_func_id` requirements
   themselves were deliberately left unwired — their own `meta.description`
   text says the corresponding feature is "enabled when set," i.e. they are
   optional hooks with a safe default of "disabled," not things a harness
   that never touches sessions needs to supply.
4. `wippy.views:public_api_url` — same shape; wiring `wippy.views:api_router`
   /`env_storage`/`server` resolved it.
5. `kickside.core:target_db` plus every `kickside.core.jobs`/`.lifecycle`/
   `.projections`/`.retention`/`.scheduler`/`.security`/`.threads`/
   `.threads.hydration` sub-namespace requirement (discovered via
   `wippy registry list --ns "kickside.core*" | grep requirement` once
   `kickside/core` was a real dependency, rather than guessing names blind)
   — wired to `app:db`/`app:api`/`app:processes`/`app:env_storage`/`app:user`
   as appropriate; `kickside.core.jobs:temp_fs` needed a new `fs.directory`
   harness entry (`app:temp_fs`).

None of this is exercised by this module's own test suites (`pull_core_test`
tests pure Lua logic against a fake client; `wiring_test` only reads static
registry entries) — it is purely the cost of getting a large, real
dependency's registry graph to boot at all in isolation. `wippy/agent`,
`wippy/llm`, and `wippy/terminal` resolved with no additional wiring needed
(either genuinely optional or defaulted cleanly).

### 6. `wippy lint` (unscoped) surfaces a real, pre-existing upstream bug in
`kickside/core` — independently reproduces `eng-metrics` BUILD-NOTES #7

Bare `wippy lint` (no `--ns` filter) checks the entire resolved graph — once
`kickside/core` (and its own 15 transitive modules) became real
dependencies, entry count jumped from ~20 to 400, and lint failed with two
genuine type errors inside `kickside.core.projections.persist:catchup`:

```
error[E0000]: argument 1: expected sql.Transaction, got any
  --> kickside.core.projections.persist:catchup:1191:57
error[E0000]: cannot assign unknown to string
  --> kickside.core.projections.persist:catchup:1795:23
error[E0022]: no method message
  --> kickside.core.projections.persist:catchup:1795:23
```

This is the **exact same file and same category of finding** as
`eng-metrics`' BUILD-NOTES #7 (a different consuming module, same upstream
`kickside/core` release, same broken function) — strong independent
confirmation this is a real upstream defect in `kickside/core` as currently
published, not something introduced by either consuming module.

**Fix:** scoped `Makefile`'s `lint` target to
`wippy lint --ns "cotique.gitlab.*"`, matching the established
practice from the `eng-metrics` precedent.

### 7. Same type-checker strictness as #3/#4, hit again rewriting
`source/pull_core.lua` for the corrected pullable envelope (resolved)

Moved to the shared platform findings file
(`C:\claude\work\wippy\work-wippy\FINDINGS.md`) — see "More Luau/`wippy
lint` type-checker gotchas: metatable method dispatch, paired `(value,
err)` narrowing, and untyped table parameters" (item 3) — an inferred-
parameter-shape/`any` typing behavior of the checker itself, not specific
to this module.

**Fix applied here:** added explicit Luau type annotations (`: any`,
`: any?` for the optional `deps` parameter) to `decode_cursor`, `walk`,
`config_value`, and `resolve_client` in `source/pull_core.lua` — matching
the real reference implementations' own convention. `wippy lint --ns
"cotique.gitlab.*"` passes clean after.

## Deliverable checklist status

- [x] `wippy.yaml` — `description` rewritten; `repository:` fixed (was
      `github.com/cotique/gitlab`, the module-name-derived default
      from `make init`; the real repo is `kickside-gitlab-provider` — caught
      exactly because the shared build brief flagged this as a thing
      `make init` gets wrong, not because it was independently noticed).
- [x] `src/` implements the structure above.
- [x] `test/` — colocated-in-harness tests (per finding below on why they
      live in `test/src/`, not `src/*/`) + wiring suite + the pullable
      conformance kit, 37/37 cases passing on both SQLite (`make verify`'s
      `test` target) and Postgres. **`make test-pg` update (2026-09-02, the
      pullable-envelope-correction session):** the literal `make test-pg`
      (no override, `compose.test.yaml`'s own port 5433) passed 37/37
      cleanly this run — the module's own test suites never touch
      persistence directly (`pull_core_test` uses a fake `client:api`;
      `wiring_test` only reads static registry entries), so nothing in this
      pass actually exercises whichever Postgres `app:db` resolves to at
      boot closely enough to distinguish "connected to the right database"
      from "connected to some Postgres." `make postgres-up` itself still
      fails on this machine with port 5433 already bound by an unrelated
      project's container (`job-search-ai-postgres-1`) — same situation as
      `eng-metrics` BUILD-NOTES #9 — so this was cross-checked by also
      running `wippy test --profile postgres --set vars.pg_port=5432`
      against the shared local `wippy-postgres` instance (which does have a
      real `cotique_test_gitlab_provider` / `kickside` database from prior
      sessions): also 37/37, identical output. Both ways green; the
      Makefile/compose port itself was not changed (CI presumably has 5433
      free, this is purely a local-machine conflict).
- [x] `BUILD-NOTES.md` at the repo root (this file) — the
      `kickside.data:pullable` envelope open item and the `pull_keys`
      wiring open item are marked RESOLVED, citing the real source files by
      local path (see the "RESOLVED" section above).
- [ ] `git add` + local commit — done as the last step of this session, no
      push.

### Why the colocated unit tests live in `test/src/`, not in `src/*/`

The first draft put `pull_core_test.lua`, `output_test.lua`, and
`data_error_test.lua` directly in `src/source/` and `src/client/` next to
the code they test, per `13-testing.md`'s literal wording ("Unit tests
colocate as `<file>_test.lua` next to the source they prove"). Once the
harness could boot, `wippy test` reported "1 tests in 1 suites" — only the
harness's own `wiring_test.lua` ran; the three colocated `src/`-level test
entries never appeared in `wippy registry list --ns
"cotique.gitlab*"` **at all**, even though nothing in the module's
own `wippy.yaml` should exclude them from a workspace-replacement load
(`exclude_meta: type: [test]` is documented as a publish-time packing
filter). Empirically, it also filters them out when the module is loaded
through a `test/.wippy.yaml` workspace replacement — not just at publish
time.

Checked against the actual precedent rather than fighting the framework:
neither the original template scaffold nor `cotique/eng-metrics` has a
single `*_test.lua` file anywhere under its own `src/` tree — every test
entry in both lives under `test/src/`. `13-testing.md`'s own reference
example (`core/contract/test/contract_smoke_test.lua`) is itself inside a
`test/` subdirectory alongside `src/`, at the module root — i.e. "colocate
with the source" in practice means "in this module's own `test/` directory,
which sits next to `src/`," which for a standalone module **is** the
harness. Moved all three test files into `test/src/` accordingly (imports
unchanged — they still `require` the module's registry entries by their
full ids, e.g. `cotique.gitlab.client:output`), and they now run:
29/29 cases across `data_error_test`, `output_test`, `pull_core_test`, and
`wiring_test`.

## Best practices worth carrying into future Kickside module work

- Verify pagination shape with a real API call before writing a paging
  loop, and verify which package genuinely owns a contract via mechanical
  dependency resolution (`wippy registry list --ns "..."`) rather than
  trusting a plausible-sounding package name — `kickside/sync`'s name
  suggested it might own `kickside.data:pullable`; it does not (or at least
  is not needed to make it resolve). Confirmed, not assumed.
- A packed Hub module's `wippy registry show --json` visibility wall
  (`"data": null`) is real and consistent across every module tried in this
  session (`kickside/connection`, `kickside/github`, `kickside/core`) — plan
  for it rather than re-discovering it each time. The one crack in that
  wall: the platform's own **contract-binding validator**, once the real
  contract is an unpacked dependency, checks a binding's declared methods
  against the real definition at boot time and errors loudly on a mismatch
  — this caught the `pull_keys` mistake above for free, essentially a
  free, authoritative partial spec of the contract's method surface.
- When a `wippy update`/`wippy test` failure doesn't match what the docs or
  a working sibling project's identical config produce, reproduce it
  side-by-side against the known-working project first (same machine, same
  binary, copy its exact file over) before assuming the local module's
  content is at fault — this is what surfaced finding #2 above as a CLI
  bug rather than a config mistake, in a fraction of the time random
  guessing would have taken.

## Structural audit against the real reference modules (2026-09-02)

With `providers-master\providers-master\atlassian` and `...\github` available
locally, did a full file-by-file structural comparison beyond just the
`kickside.data:pullable` envelope (already covered above). Checked and
confirmed fine, no change needed:

- `client/site.lua`-style base-URL/tenant resolution (Atlassian-specific
  "site"/cloudId indirection) — not applicable, neither GitLab nor Bitbucket
  needs an equivalent.
- Agent-tool traits (`jira/traits`, `confluence/traits`, `github/traits`) —
  confirmed still correctly out of scope (see "Deliberate scope decisions"
  above).
- `kickside.data:writable` sinks (`jira/sink`, `confluence/sink` — real
  Atlassian can also *write* issues/pages via Data Sync) — confirmed
  correctly absent; this module is read-only per eng-metrics SPEC.md
  decision B0, not an oversight.
- Test harness env-storage wiring (`test/env/_index.yaml` in the real
  reference) — matches this module's own equivalent pattern already.
- Empty `src/migrations/_index.yaml` namespace stub in real Atlassian —
  vestigial (zero entries); not needed here since neither module owns SQL.

Found and fixed:

- **`wippy.yaml` was missing the top-level `type: plugin` field.** Added.
  The underlying convention (undocumented but universal across all 20
  real provider modules checked) is platform-wide, not GitLab-specific —
  moved to the shared platform findings file
  (`C:\claude\work\wippy\work-wippy\FINDINGS.md`), see "`wippy.yaml`'s
  top-level `type: plugin` field is an undocumented but universal
  convention across every real provider module".
- **The unnecessary `kickside/core` dependency** — see the corrected section
  above.

Flagged, not changed (a real decision, not a technical correctness issue):

- **License.** Every real provider module in the reference monorepo uses
  `BUSL-1.1`; this module still has the template's default `MIT`. Left
  as-is — which license this repo ships under is the user's call, not
  something to silently match to Wippy's own platform-module convention.

## RESOLVED: removed the UI/api/security apparatus (2026-09-02, later the same session)

Moved to the shared platform findings file
(`C:\claude\work\wippy\work-wippy\FINDINGS.md`) — see "A credential-only,
no-picker connection provider needs no `ui/`, `api/`, or `security/`
folder, no `embed:`, and no `kickside/core` dependency". (This heading's
full content was lost without a pointer during an earlier documentation
pass on this file; restored here from the identical finding independently
confirmed and preserved on the sibling `kickside-bitbucket-provider` repo.)

## Renamed module identity: cotique/gitlab-provider -> cotique/gitlab (2026-09-03)

Matching the real reference convention: `kickside/github`, `kickside/atlassian`,
`kickside/discord` etc. don't carry a `-provider`/`-connector` suffix on the
module name itself — only this repo's own GitHub repo name
(`kickside-gitlab-provider`) does, which is unrelated and unchanged. Renamed
throughout: `wippy.yaml` (`module:`, keywords), `.kickside-module.json`
identity, the root namespace (`cotique.gitlab_provider` -> `cotique.gitlab`),
the web-component tag (`cotique-gitlab-provider` -> `cotique-gitlab`), the
route, every registry entry id under the old namespace, the test harness's
workspace replacement target and Postgres database name
(`cotique_test_gitlab_provider` -> `cotique_test_gitlab`), and the CI
workflow. The GitHub repository URL in `wippy.yaml` (`repository:
https://github.com/cotique/kickside-gitlab-provider`) is deliberately
untouched — that identifier is independent of the Wippy module identity and
was never meant to match it.

Done by a scripted, compound-token-first pass (mirroring
`scripts/init-module.mjs`'s own replacement strategy: longest/most specific
tokens first, e.g. `cotique.gitlab_provider` before any bare `gitlab-provider`)
followed by a manual pass for the remaining bare occurrences, specifically
to avoid corrupting `kickside-gitlab-provider` (the real GitHub repo name,
which contains `gitlab-provider` as a substring) with a blind global
replace.

## Follow-up: the removal above also fixed a real fresh-checkout bootstrap deadlock

While finishing the `cotique/gitlab-provider` -> `cotique/gitlab` rename, a
from-scratch `test/` bootstrap (no lock, no vendor cache) hard-failed:
`wippy update` — bare, then again with `--config .wippy.yaml` — both failed
identically with `cotique/gitlab@*: list versions: module not found`.

Root cause, confirmed by direct comparison and a control test: this
module's harness declared the module-under-test itself as an explicit root
`ns.dependency` (`gitlab_harness.dep.module`, wired purely so its own
`user_security_scope` requirement could be routed through `parameters:`
instead of a raw `.wippy.yaml` `override:` path — the exact fix documented
in the shared platform findings file's "CI: a raw `.wippy.yaml` override
..." entry). This is a genuine, distinct follow-on discovery — that same
fix causes a *new* problem on a fresh checkout — moved to the shared
platform findings file (`C:\claude\work\wippy\work-wippy\FINDINGS.md`) as
an addendum to that entry (point 2). Confirmed not specific to this module:
reproduces identically against a sibling connector module's real, merged
`main`, and against a third module's own `main` (read-only check, no
lasting effect). A control test against a harness shape with no such
explicit dependency (relying purely on `test/.wippy.yaml`'s
`workspace.replacements`) bootstraps cleanly from scratch every time.

Since `src/security/` (and the `user_security_scope` requirement it
declared) is now gone entirely per the removal above, `gitlab_harness.dep.
module` had no remaining purpose and was deleted outright — the module now
surfaces purely through the workspace replacement, matching the
proven-clean shape. `make verify` re-verified from a genuinely fresh state
(`test/.wippy/vendor`, `test/wippy.lock`, and the root `wippy.lock` all
deleted first): 33/33 tests on both SQLite and Postgres, lint clean.

## RESOLVED: CI red — a real `wippy test` regression in v0.3.35a, not our fix

After pushing the rename/UI-removal/README work, CI failed at the `test`
step with `node with ID {cotique.gitlab.source pull_core cotique.gitlab.
source:pull_core} not found` — a workspace-replaced module's own entries
not resolving during `wippy test`, even though `wippy update`/`wippy lint`
resolved the identical graph fine moments earlier in the same job.

Isolated directly, not assumed (full reproduction steps, cross-repo
confirmation, and its relationship to the other two `v0.3.35a+`
workspace-replacement regressions moved to the shared platform findings
file — see below): downloaded the actual `latest` CLI release (`v0.3.35a`)
and ran it against this exact checkout from a genuinely fresh state —
`wippy update`/`wippy lint` resolve the graph fine, `wippy test` fails with
`node with ID {...pull_core...} not found`. The identical sequence on the
locally-installed `v0.3.33a` passes clean, 33/33.

This is a platform-wide `wippy test` regression, not specific to this
module — moved to the shared platform findings file
(`C:\claude\work\wippy\work-wippy\FINDINGS.md`) — see "`wippy test`
(v0.3.35a+) fails to find a workspace-replaced module's own entries during
state-loading, even though `wippy update`/`wippy lint` resolve the identical
graph moments earlier".

**Fix:** pinned `WIPPY_VERSION: v0.3.33a` in `.github/workflows/verify.yml`
instead of `latest`, per that file's own stated policy ("set an exact tag
only to bisect a runtime regression" — this is exactly that case). Not a
permanent fix — revert to `latest` once a release without this regression
ships, or re-pin/bisect again if it recurs.
