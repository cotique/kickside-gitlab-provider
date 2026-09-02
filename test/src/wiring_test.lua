-- Registry-shape test for the connection binding, pull source, and HTTP/UI
-- surfaces. The harness does not call its router or gateway, so these are
-- verified as registry wiring: every entry exists and the cross-references
-- line up.
local test = require("test")
local registry = require("registry")

local CONNECTION_ID = "cotique.gitlab_provider.connection:gitlab_connection"
local GET_STATUS_ID = "cotique.gitlab_provider.connection:get_status"
local DELETE_ID = "cotique.gitlab_provider.connection:delete"
local TEST_CONNECTION_ID = "cotique.gitlab_provider.connection:test_connection"
local DISCOVER_ID = "cotique.gitlab_provider.connection:discover_resources"

local SOURCE_BINDING_ID = "cotique.gitlab_provider.source:project_mrs_source"
local PULL_ITEMS_ID = "cotique.gitlab_provider.source:pull_items"
local PULL_KEYS_ID = "cotique.gitlab_provider.source:pull_keys"
local PORT_ID = "cotique.gitlab_provider.source:project_mrs"

local HANDLER_ID = "cotique.gitlab_provider.api:get_status"
local ENDPOINT_ID = "cotique.gitlab_provider.api:get_status.endpoint"
local VIEW_ID = "cotique.gitlab_provider:gitlab_provider_view"
local NAV_ID = "cotique.gitlab_provider:nav_item"
local STATIC_ID = "cotique.gitlab_provider:ui_static"
local FS_ID = "cotique.gitlab_provider:ui_fs"
local POLICY_ID = "cotique.gitlab_provider.security:gitlab_provider_endpoint_access"

local function get(id)
    local entry, err = registry.get(id)
    test.is_nil(err)
    test.not_nil(entry, id .. " is missing")
    return entry
end

local function meta_of(entry)
    if type(entry.meta) == "table" then return entry.meta end
    if type(entry.data) == "table" and type(entry.data.meta) == "table" then return entry.data.meta end
    return {}
end

local function data_of(entry)
    if type(entry.data) == "table" then return entry.data end
    return entry
end

-- Entry references are written relative or namespace-qualified; compare fully
-- qualified.
local function qualify(ref, ns)
    if type(ref) ~= "string" then return ref end
    if ref:find(":", 1, true) then return ref end
    return ns .. ":" .. ref
end

local function define_tests()
    test.describe("cotique.gitlab_provider surface wiring", function()
        test.it("declares the connection binding with the canonical credential-only shape", function()
            local binding = get(CONNECTION_ID)
            local meta = meta_of(binding)
            test.eq(meta.provider, "gitlab")
            test.not_nil(meta.class, "connection binding must declare meta.class")
            local is_connection = false
            for _, c in ipairs(meta.class) do
                if c == "connection" then is_connection = true end
            end
            test.is_true(is_connection, "meta.class must include connection")

            test.not_nil(meta.credential_schema, "connection binding must declare credential_schema")
            local fields = meta.credential_schema.fields
            test.not_nil(fields, "credential_schema must declare fields")
            local has_token, has_base_url = false, false
            for _, f in ipairs(fields) do
                if f.key == "token" then has_token = true; test.eq(f.required, true) end
                if f.key == "base_url" then has_base_url = true end
            end
            test.is_true(has_token, "credential_schema must declare a required token field")
            test.is_true(has_base_url, "credential_schema must declare a base_url field (self-managed GitLab support)")

            local decl = data_of(binding)
            test.not_nil(decl.contracts, "connection binding must declare contracts")

            local seen = {}
            for _, c in ipairs(decl.contracts) do
                seen[c.contract] = c
            end

            local component_contract = seen["kickside.contract:component"]
            test.not_nil(component_contract, "must implement kickside.contract:component")
            test.eq(qualify(component_contract.methods.get_status, "cotique.gitlab_provider.connection"), GET_STATUS_ID)

            local connection_contract = seen["kickside.connection:connection"]
            test.not_nil(connection_contract, "must implement kickside.connection:connection")
            test.not_nil(connection_contract.context_required, "connection contract methods require context_required: [component_id]")
            test.eq(connection_contract.context_required[1], "component_id")
            test.eq(qualify(connection_contract.methods.get_status, "cotique.gitlab_provider.connection"), GET_STATUS_ID)
            test.eq(qualify(connection_contract.methods.test_connection, "cotique.gitlab_provider.connection"), TEST_CONNECTION_ID)
            test.eq(qualify(connection_contract.methods.discover_resources, "cotique.gitlab_provider.connection"), DISCOVER_ID)

            local deletable_contract = seen["kickside.contract:deletable"]
            test.not_nil(deletable_contract, "must implement kickside.contract:deletable")
            test.eq(deletable_contract.context_required[1], "component_id")
            test.eq(qualify(deletable_contract.methods.delete, "cotique.gitlab_provider.connection"), DELETE_ID)
        end)

        test.it("get_status and delete are backed by real function entries", function()
            get(GET_STATUS_ID)
            get(DELETE_ID)
            get(TEST_CONNECTION_ID)
            get(DISCOVER_ID)
        end)

        test.it("declares the pull source binding implementing kickside.data:pullable", function()
            local binding = get(SOURCE_BINDING_ID)
            local decl = data_of(binding)
            local seen = {}
            for _, c in ipairs(decl.contracts) do
                seen[c.contract] = c
            end
            local pullable = seen["kickside.data:pullable"]
            test.not_nil(pullable, "must implement kickside.data:pullable")
            test.eq(qualify(pullable.methods.pull, "cotique.gitlab_provider.source"), PULL_ITEMS_ID)
            -- kickside.data:pullable binds ONLY "pull" — empirically
            -- confirmed by the platform's own contract-binding validator
            -- (see BUILD-NOTES.md "OPEN: kickside.data:pullable's exact
            -- envelope"). pull_keys is intentionally NOT part of this
            -- contract's methods map.
            test.is_nil(pullable.methods.pull_keys, "kickside.data:pullable has no pull_keys method")

            get(PULL_ITEMS_ID)
            -- pull_keys still exists as a standalone entry, just unbound.
            get(PULL_KEYS_ID)
        end)

        test.it("publishes the merge-request pull source as an automation port", function()
            local port = get(PORT_ID)
            local meta = meta_of(port)
            test.eq(meta.type, "kickside.automation.port")

            local decl = data_of(port)
            test.eq(qualify(decl.binding, "cotique.gitlab_provider.source"), SOURCE_BINDING_ID)
            test.not_nil(decl.config_schema, "port must declare config_schema")
            test.not_nil(decl.config_schema.project_id, "config_schema must let the caller select a project")
            test.not_nil(decl.output_schema, "port must declare output_schema for the normalized item shape")
            test.not_nil(decl.operations, "port must declare operations")
            test.not_nil(decl.operations.pull, "port must declare a pull operation")
        end)

        test.it("pairs the status endpoint with its handler on the router token", function()
            get(HANDLER_ID)
            local ep = data_of(get(ENDPOINT_ID))
            test.eq(qualify(ep.func, "cotique.gitlab_provider.api"), HANDLER_ID)
            test.eq(ep.method, "GET")
            test.eq(ep.path, "/gitlab-provider/status")
            test.eq(meta_of(get(ENDPOINT_ID)).router, "app:api")
        end)

        test.it("declares a view served by the module's own static mount", function()
            local view = meta_of(get(VIEW_ID))
            test.eq(view.type, "view.component")
            test.eq(view.tag_name, "cotique-gitlab-provider")
            test.eq(view.entry_point, "index.js")
            test.eq(view.announced, true)
            test.eq(view.auto_register, true)

            local static = get(STATIC_ID)
            test.eq(data_of(static).path, "/" .. view.base_path)
            test.eq(qualify(data_of(static).fs, "cotique.gitlab_provider"), FS_ID)
            get(FS_ID)
        end)

        test.it("mounts the view in the app nav by tag", function()
            local nav = meta_of(get(NAV_ID))
            test.eq(nav.type, "ui.nav_item")
            test.eq(nav.path, "/gitlab-provider")
            test.eq(nav.render, "component")
            test.eq(nav.component_tag, meta_of(get(VIEW_ID)).tag_name)
        end)

        test.it("gates the api namespace behind the injectable access policy", function()
            local policy = data_of(get(POLICY_ID))
            local resources = policy.policy and policy.policy.resources
            test.not_nil(resources, "policy must list resources")
            if type(resources) == "string" then resources = { resources } end
            local covered = false
            for _, r in ipairs(resources) do
                if r == "cotique.gitlab_provider.api:*" then covered = true end
            end
            test.is_true(covered, "policy must cover cotique.gitlab_provider.api:*")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return { run = function(options) return run_cases(options) end }
