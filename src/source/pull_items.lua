-- kickside.data:pullable.pull for GitLab project merge requests.
--
-- Envelope CONFIRMED against the real, unpacked reference implementations
-- (previously this file carried a long "UNVERIFIED" comment documenting the
-- envelope as inferred by analogy — see BUILD-NOTES.md,
-- "kickside.data:pullable's exact envelope — RESOLVED", for the full
-- correction and cited sources):
--   providers-master/github/src/source/pull_items.lua
--   providers-master/atlassian/src/jira/source/pull_issues.lua
-- Both are thin one-line wrappers around their module's own pull_core; this
-- file mirrors that shape. All real logic — client resolution, pagination,
-- normalization, envelope construction — lives in pull_core.lua.
local data_error = require("data_error")
local pull_core = require("pull_core")

local function pull(req)
    req = type(req) == "table" and req or {}
    local config = type(req.config) == "table" and req.config or {}

    local project_id = config.project_id
    if type(project_id) ~= "string" and type(project_id) ~= "number" then
        return data_error.invalid_config("pull requires config.project_id")
    end
    project_id = tostring(project_id)

    local client, cerr = pull_core.resolve_client(config)
    if cerr then
        return cerr
    end

    return pull_core.list_merge_requests(client, project_id, req)
end

return { pull = pull }
