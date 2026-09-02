-- Keys-only GitLab project merge request listing for Data Sync reconcile.
--
-- NOT bound to kickside.data:pullable — that contract binds only "pull"
-- (empirically confirmed at boot by the platform's own contract-binding
-- validator; see BUILD-NOTES.md). Instead this is wired through the
-- kickside.automation.port entry's own `reconcile: { pull_keys: ... }`
-- field, sibling to `binding:` — confirmed against the real reference
-- (providers-master/github/src/source/_index.yaml's `repo_items` entry and
-- providers-master/atlassian/src/jira/source/_index.yaml's `issues` entry,
-- both of which wire pull_keys this exact way). See source/_index.yaml and
-- BUILD-NOTES.md, "kickside.data:pullable's exact envelope — RESOLVED".
local data_error = require("data_error")
local pull_core = require("pull_core")

local function pull_keys(req)
    req = type(req) == "table" and req or {}
    local config = type(req.config) == "table" and req.config or {}

    local project_id = config.project_id
    if type(project_id) ~= "string" and type(project_id) ~= "number" then
        return data_error.invalid_config("pull_keys requires config.project_id")
    end
    project_id = tostring(project_id)

    local client, cerr = pull_core.resolve_client(config)
    if cerr then
        return cerr
    end

    return pull_core.list_merge_request_keys(client, project_id, req)
end

return { pull_keys = pull_keys }
