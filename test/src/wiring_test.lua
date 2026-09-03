-- Registry-shape test for the connection binding and pull source. This
-- module ships no web component, no custom HTTP endpoint, and no security
-- policy of its own — matches the real reference provider modules
-- (kickside/discord, kickside/slack, etc.; see BUILD-NOTES.md "structural
-- audit"). The harness does not call its router or gateway, so these are
-- verified as registry wiring: every entry exists and the cross-references
-- line up.
local test = require("test")
local registry = require("registry")

local CONNECTION_ID = "cotique.gitlab.connection:gitlab_connection"
local GET_STATUS_ID = "cotique.gitlab.connection:get_status"
local DELETE_ID = "cotique.gitlab.connection:delete"
local TEST_CONNECTION_ID = "cotique.gitlab.connection:test_connection"
local DISCOVER_ID = "cotique.gitlab.connection:discover_resources"

local SOURCE_BINDING_ID = "cotique.gitlab.source:project_mrs_source"
local PULL_ITEMS_ID = "cotique.gitlab.source:pull_items"
local PULL_KEYS_ID = "cotique.gitlab.source:pull_keys"
local PORT_ID = "cotique.gitlab.source:project_mrs"

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
    test.describe("cotique.gitlab surface wiring", function()
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
            test.eq(qualify(component_contract.methods.get_status, "cotique.gitlab.connection"), GET_STATUS_ID)

            local connection_contract = seen["kickside.connection:connection"]
            test.not_nil(connection_contract, "must implement kickside.connection:connection")
            test.not_nil(connection_contract.context_required, "connection contract methods require context_required: [component_id]")
            test.eq(connection_contract.context_required[1], "component_id")
            test.eq(qualify(connection_contract.methods.get_status, "cotique.gitlab.connection"), GET_STATUS_ID)
            test.eq(qualify(connection_contract.methods.test_connection, "cotique.gitlab.connection"), TEST_CONNECTION_ID)
            test.eq(qualify(connection_contract.methods.discover_resources, "cotique.gitlab.connection"), DISCOVER_ID)

            local deletable_contract = seen["kickside.contract:deletable"]
            test.not_nil(deletable_contract, "must implement kickside.contract:deletable")
            test.eq(deletable_contract.context_required[1], "component_id")
            test.eq(qualify(deletable_contract.methods.delete, "cotique.gitlab.connection"), DELETE_ID)
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
            test.eq(qualify(pullable.methods.pull, "cotique.gitlab.source"), PULL_ITEMS_ID)
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
            test.eq(qualify(decl.binding, "cotique.gitlab.source"), SOURCE_BINDING_ID)
            test.not_nil(decl.config_schema, "port must declare config_schema")
            test.not_nil(decl.config_schema.project_id, "config_schema must let the caller select a project")
            test.not_nil(decl.output_schema, "port must declare output_schema for the normalized item shape")
            test.not_nil(decl.operations, "port must declare operations")
            test.not_nil(decl.operations.pull, "port must declare a pull operation")

            -- reconcile.pull_keys is how Data Sync reconcile actually wires
            -- a keys-only listing — sibling to binding:, NOT a second method
            -- on the kickside.data:pullable contract.binding. Confirmed
            -- against the real reference (kickside/github's repo_items
            -- entry, kickside/atlassian's issues entry) — see
            -- BUILD-NOTES.md, "kickside.data:pullable's exact envelope —
            -- RESOLVED".
            test.not_nil(decl.reconcile, "port must declare reconcile for Data Sync's keys-only reconcile hook")
            test.eq(qualify(decl.reconcile.pull_keys, "cotique.gitlab.source"), PULL_KEYS_ID)

            -- connection_id is an explicit config_schema field, confirmed
            -- against the real reference's identical shape (picker:
            -- kickside-connection-trait-picker, role: primary, required:
            -- true, provider: <slug>).
            local connection_id_field = decl.config_schema.connection_id
            test.not_nil(connection_id_field, "config_schema must declare an explicit connection_id field")
            test.eq(connection_id_field.picker, "kickside-connection-trait-picker")
            test.eq(connection_id_field.role, "primary")
            test.eq(connection_id_field.required, true)
            test.eq(connection_id_field.provider, "gitlab")
        end)

    end)
end

local run_cases = test.run_cases(define_tests)
return { run = function(options) return run_cases(options) end }
