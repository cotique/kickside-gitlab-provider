-- kickside.connection:connection.discover_resources
--
-- GET /api/v4/projects?membership=true&per_page=100&order_by=path&simple=true
-- per the provider brief. Paginates via the empirically-verified GitLab
-- mechanics (x-next-page header; see BUILD-NOTES.md) so a token with access
-- to more than 100 projects is never silently truncated.
local connection_lib = require("connection_lib")
local api = require("api")

-- Sanity bound against a runaway loop if GitLab ever returns a next-page
-- header pointing nowhere useful (a broken/adversarial server, not a real
-- account size) — hitting it is treated as a failure, never a silent
-- truncation of real results.
local MAX_PAGES = 1000

local function map_project(project)
    return {
        id = tostring(project.id),
        label = project.path_with_namespace,
        icon = "tabler:brand-gitlab",
        parent_id = nil,
        selectable = true,
        drillable = false,
    }
end

local function discover_resources()
    local client, err = connection_lib.get_client()
    if err or not client then
        return { success = false, error = tostring(err or "could not build a GitLab client") }
    end

    local resources = {}
    local page = 1

    for _ = 1, MAX_PAGES do
        local resp, rerr = client:get("/projects", {
            scope = "discovery",
            query = {
                membership = "true",
                per_page = "100",
                order_by = "path",
                simple = "true",
                page = tostring(page),
            },
        })
        if rerr then
            return { success = false, error = rerr.error.message }
        end

        local items = resp.body
        if type(items) ~= "table" then
            return { success = false, error = "GitLab /projects response was not a JSON array" }
        end
        for _, project in ipairs(items) do
            resources[#resources + 1] = map_project(project)
        end

        local next_page = api.get_header(resp.headers, "x-next-page")
        if type(next_page) ~= "string" or next_page == "" then
            return { success = true, resources = resources }
        end
        page = tonumber(next_page) or (page + 1)
    end

    return { success = false, error = "GitLab /projects pagination did not terminate within " .. MAX_PAGES .. " pages" }
end

return { discover_resources = discover_resources }
