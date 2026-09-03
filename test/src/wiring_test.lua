-- Registry-shape test for the connection binding and pull source. This
-- module ships no web component, no custom HTTP endpoint, and no security
-- policy of its own — matches the real reference provider modules
-- (kickside/discord, kickside/slack, etc.; see BUILD-NOTES.md "structural
-- audit"). The harness does not call its router or gateway, so these are
-- verified as registry wiring: every entry exists and the cross-references
-- line up.
local test = require("test")
local registry = require("registry")
local json = require("json")

local CONNECTION_ID = "cotique.gitlab.connection:gitlab_connection"
local GET_STATUS_ID = "cotique.gitlab.connection:get_status"
local DELETE_ID = "cotique.gitlab.connection:delete"
local TEST_CONNECTION_ID = "cotique.gitlab.connection:test_connection"
local DISCOVER_ID = "cotique.gitlab.connection:discover_resources"

local SOURCE_BINDING_ID = "cotique.gitlab.source:project_mrs_source"
local PULL_ITEMS_ID = "cotique.gitlab.source:pull_items"
local PULL_KEYS_ID = "cotique.gitlab.source:pull_keys"
local PORT_ID = "cotique.gitlab.source:project_mrs"

local READER_TRAIT_ID = "cotique.gitlab.traits:reader"
local WRITER_TRAIT_ID = "cotique.gitlab.traits:writer"
local MANAGER_TRAIT_ID = "cotique.gitlab.traits:manager"
local READ_TOOL_ID = "cotique.gitlab.traits:read_tool"
local WRITE_TOOL_ID = "cotique.gitlab.traits:write_tool"
local READ_TOOL_LIB_ID = "cotique.gitlab.traits:read_tool_lib"
local WRITE_TOOL_LIB_ID = "cotique.gitlab.traits:write_tool_lib"

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

    -- v2 write-access agent-tool traits (src/traits/). Registry-shape only —
    -- handler behavior (validation, dispatch against a fake client) is
    -- covered separately in test/src/traits_test.lua, matching this
    -- module's own established split (pull_core_test.lua for logic,
    -- wiring_test.lua for registry wiring).
    test.describe("cotique.gitlab traits wiring", function()
        local function trait_meta(id)
            local meta = meta_of(get(id))
            test.eq(meta.type, "agent.trait")
            test.is_true(meta.public)
            test.eq(meta.web_component, "kickside-connection-trait-picker")
            test.eq(meta.provider, "gitlab")
            test.eq(meta.context_schema.type, "object")
            test.not_nil(meta.context_schema.properties.connection_id)
            test.eq(meta.context_schema.additionalProperties, false)
            return meta
        end

        test.it("declares reader/writer/manager as public context-configurable traits", function()
            trait_meta(READER_TRAIT_ID)
            trait_meta(WRITER_TRAIT_ID)
            trait_meta(MANAGER_TRAIT_ID)
        end)

        test.it("reader grants only the read tool; writer only the write tool", function()
            local reader = data_of(get(READER_TRAIT_ID))
            test.eq(#reader.tools, 1)
            test.eq(qualify(reader.tools[1], "cotique.gitlab.traits"), READ_TOOL_ID)

            local writer = data_of(get(WRITER_TRAIT_ID))
            test.eq(#writer.tools, 1)
            test.eq(qualify(writer.tools[1], "cotique.gitlab.traits"), WRITE_TOOL_ID)
        end)

        test.it("manager grants both read and write tools and states the same write restraint", function()
            local manager = data_of(get(MANAGER_TRAIT_ID))
            test.eq(qualify(manager.tools[1], "cotique.gitlab.traits"), READ_TOOL_ID)
            test.eq(qualify(manager.tools[2], "cotique.gitlab.traits"), WRITE_TOOL_ID)
            local prompt = tostring(manager.prompt or "")
            test.ok(prompt:find("Do not ask the user"))
            test.ok(prompt:find("Do not merge, approve, or delete"))
        end)

        test.it("writer/manager prompts state the write scope restriction explicitly", function()
            local writer_prompt = tostring(data_of(get(WRITER_TRAIT_ID)).prompt or "")
            test.ok(writer_prompt:find("never merges, approves, or deletes"))
            test.ok(writer_prompt:find("repository files, branches, releases, settings, collaborators"))
        end)

        test.it("read_tool declares state.read; write_tool declares state.read + state.write", function()
            local read_meta = meta_of(get(READ_TOOL_ID))
            test.eq(read_meta.type, "tool")
            test.not_nil(read_meta.mcp, "read_tool must declare meta.mcp")
            test.eq(#read_meta.mcp.required_scopes, 1)
            test.eq(read_meta.mcp.required_scopes[1], "state.read")

            local write_meta = meta_of(get(WRITE_TOOL_ID))
            test.eq(write_meta.type, "tool")
            test.not_nil(write_meta.mcp, "write_tool must declare meta.mcp")
            local scopes = write_meta.mcp.required_scopes
            local has_read, has_write = false, false
            for _, s in ipairs(scopes) do
                if s == "state.read" then has_read = true end
                if s == "state.write" then has_write = true end
            end
            test.is_true(has_read, "write_tool must require state.read")
            test.is_true(has_write, "write_tool must require state.write")
        end)

        test.it("read_tool/write_tool action enums cover every documented action, and never a merge action", function()
            local read_schema, rerr = json.decode(tostring(meta_of(get(READ_TOOL_ID)).input_schema or ""))
            test.is_nil(rerr)
            local write_schema, werr = json.decode(tostring(meta_of(get(WRITE_TOOL_ID)).input_schema or ""))
            test.is_nil(werr)

            local function contains(list, value)
                for _, v in ipairs(list or {}) do
                    if v == value then return true end
                end
                return false
            end

            for _, action in ipairs({ "list_merge_requests", "get_merge_request", "list_merge_request_notes" }) do
                test.is_true(contains(read_schema.properties.action.enum, action), "read_tool missing action " .. action)
            end
            for _, action in ipairs({ "create_merge_request", "update_merge_request", "create_note" }) do
                test.is_true(contains(write_schema.properties.action.enum, action), "write_tool missing action " .. action)
            end
            test.eq(#write_schema.properties.action.enum, 3, "write_tool must expose exactly the three documented actions")
            -- Never merge — this is the one operation explicitly and
            -- repeatedly out of scope per the shared build brief.
            test.is_true(contains(write_schema.properties.action.enum, "merge") == false, "write_tool must not expose a merge action")
        end)

        test.it("read_tool_lib/write_tool_lib backing library entries exist", function()
            get(READ_TOOL_LIB_ID)
            get(WRITE_TOOL_LIB_ID)
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return { run = function(options) return run_cases(options) end }
