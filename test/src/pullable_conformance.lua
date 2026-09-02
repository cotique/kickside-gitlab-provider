local registry = require("registry")
local json = require("json")

local M = {}

type Map = { [string]: any }
type Failure = { code: string, message: string }

local function as_map(v: any): Map
    return type(v) == "table" and (v :: Map) or {}
end

local function add(failures: { Failure }, code: string, message: string)
    failures[#failures + 1] = { code = code, message = message }
end

local function schema_methods(entry: any): any
    if type(entry) ~= "table" then return nil end
    if type((entry :: Map).methods) == "table" then return (entry :: Map).methods end
    local data = (entry :: Map).data
    if type(data) == "table" and type((data :: Map).methods) == "table" then return (data :: Map).methods end
    return nil
end

local function method_schema(entry: any, method_name: string, direction: string): (Map?, string?)
    local methods = schema_methods(entry)
    if type(methods) ~= "table" then return nil, "pullable contract has no methods" end
    for _, raw in ipairs(methods :: { any }) do
        local method = as_map(raw)
        if method.name == method_name then
            local schemas = method[direction .. "_schemas"]
            if type(schemas) ~= "table" or #schemas == 0 then return nil, "pullable." .. method_name .. " has no " .. direction .. " schema" end
            local def = as_map((schemas :: { any })[1]).definition
            if type(def) ~= "string" then return nil, "pullable." .. method_name .. " " .. direction .. " schema definition is missing" end
            local decoded, derr = json.decode(def)
            if derr then return nil, "decode pullable schema: " .. tostring(derr) end
            return as_map(decoded), nil
        end
    end
    return nil, "pullable." .. method_name .. " method not found"
end

local function pull_output_schema(): (Map?, string?)
    local entry, err = registry.get("kickside.data:pullable")
    if err or not entry then return nil, "registry.get(kickside.data:pullable): " .. tostring(err) end
    return method_schema(entry, "pull", "output")
end

local function type_name(v: any): string
    if type(v) == "table" then
        local max = 0
        local count = 0
        for k, _ in pairs(v :: Map) do
            count = count + 1
            if type(k) ~= "number" then return "object" end
            if k > max then max = k end
        end
        if count == 0 then return "empty_table" end
        return "array"
    end
    return type(v)
end

local function allowed_type(schema_type: any, actual: string): boolean
    local function matches(typ: any): boolean
        if actual == "empty_table" and (typ == "object" or typ == "array") then return true end
        return typ == actual
    end
    if type(schema_type) == "string" then return matches(schema_type) end
    if type(schema_type) == "table" then
        for _, typ in ipairs(schema_type :: { any }) do
            if matches(typ) then return true end
        end
    end
    return false
end

local function ref_schema(root: Map, ref: string): Map?
    local name = ref:match("^#/%$defs/(.+)$")
    if not name then return nil end
    local defs = as_map(root["$defs"])
    local target = defs[name]
    return type(target) == "table" and (target :: Map) or nil
end

local function validate_schema(root: Map, schema: Map, value: any, path: string, failures: { Failure })
    local ref = schema["$ref"]
    if type(ref) == "string" then
        local target = ref_schema(root, ref)
        if not target then add(failures, "schema.ref", path .. " unresolved ref " .. ref); return end
        validate_schema(root, target, value, path, failures)
        return
    end

    local stype = schema.type
    if stype ~= nil then
        local actual = type_name(value)
        if not allowed_type(stype, actual) then
            add(failures, "schema.type", path .. " must be " .. tostring(stype) .. ", got " .. actual)
            return
        end
    end

    if schema.enum ~= nil then
        local ok = false
        for _, option in ipairs(schema.enum :: { any }) do
            if value == option then ok = true; break end
        end
        if not ok then add(failures, "schema.enum", path .. " has undeclared value " .. tostring(value)) end
    end

    if type(value) == "string" and type(schema.minLength) == "number" and #value < schema.minLength then
        add(failures, "schema.minLength", path .. " is shorter than " .. tostring(schema.minLength))
    end
    if type(value) == "number" and type(schema.minimum) == "number" and value < schema.minimum then
        add(failures, "schema.minimum", path .. " is below " .. tostring(schema.minimum))
    end

    if type(value) == "table" and type(schema.properties) == "table" then
        local object = value :: Map
        local props = schema.properties :: Map
        if type(schema.required) == "table" then
            for _, key in ipairs(schema.required :: { any }) do
                if object[key] == nil then add(failures, "schema.required", path .. "." .. tostring(key) .. " is required") end
            end
        end
        if schema.additionalProperties == false then
            for key, _ in pairs(object) do
                if type(key) == "string" and props[key] == nil then
                    add(failures, "schema.additional", path .. "." .. key .. " is not declared")
                end
            end
        end
        for key, prop_schema in pairs(props) do
            if object[key] ~= nil and type(prop_schema) == "table" then
                validate_schema(root, prop_schema :: Map, object[key], path .. "." .. tostring(key), failures)
            end
        end
    end

    if type(value) == "table" and type(schema.items) == "table" then
        for i, item in ipairs(value :: { any }) do
            validate_schema(root, schema.items :: Map, item, path .. "[" .. tostring(i) .. "]", failures)
        end
    end
end

local function validate_item_semantics(page: Map, failures: { Failure })
    if page.success ~= true then return end
    local items = type(page.items) == "table" and (page.items :: { any }) or {}
    for i, raw in ipairs(items) do
        local item = as_map(raw)
        if item.op == "upsert" and item.payload == nil and item.ref == nil then
            add(failures, "item.upsert_content", "items[" .. tostring(i) .. "] upsert requires payload or ref")
        end
    end
    if page.has_more == true and #items == 0 and page.retry_after_ms == nil then
        add(failures, "empty_page.retry_after_ms", "has_more=true with no items requires retry_after_ms")
    end
end

local function call_pull(pull: any, request: Map): (Map?, string?)
    local ok, page, err = pcall(pull, request)
    if not ok then return nil, tostring(page) end
    if err ~= nil then return nil, tostring(err) end
    if type(page) ~= "table" then return nil, "pull returned non-table" end
    return page :: Map, nil
end

local function config_from(factory: any, name: string): Map
    if type(factory) == "function" then
        local ok, result = pcall(factory, name)
        if ok and type(result) == "table" then return result :: Map end
        return {}
    end
    if type(factory) == "table" then return factory :: Map end
    return {}
end

local function cursor_key(cursor: any): string
    if cursor == nil then return "null" end
    local encoded, err = json.encode(cursor)
    if err then return tostring(cursor) end
    return tostring(encoded)
end

local function item_time(item: Map): string?
    if type(item.occurred_at) == "string" then return item.occurred_at end
    if type(item.observed_at) == "string" then return item.observed_at end
    return nil
end

local function validate_page(schema: Map, page: Map, path: string, failures: { Failure })
    validate_schema(schema, schema, page, path, failures)
    if page.success == true then
        if page.items == nil then add(failures, "success.items", path .. ".items is required on success") end
        if page.next_cursor == nil then add(failures, "success.next_cursor", path .. ".next_cursor is required on success") end
        if type(page.has_more) ~= "boolean" then add(failures, "success.has_more", path .. ".has_more is required on success") end
        if page.error ~= nil then add(failures, "success.error", path .. ".error must be absent on success") end
    elseif page.success == false then
        if type(page.error) ~= "table" then add(failures, "error.shape", path .. ".error is required on failure") end
        if page.items ~= nil or page.next_cursor ~= nil or page.has_more ~= nil then
            add(failures, "error.fields", path .. " failure must not return items, next_cursor, or has_more")
        end
    end
    validate_item_semantics(page, failures)
end

local function validate_key_page(page: Map, path: string, failures: { Failure })
    if page.success ~= true then
        if type(page.error) ~= "table" then add(failures, "keys.error", path .. ".error is required on failure") end
        return
    end
    if type(page.keys) ~= "table" then add(failures, "keys.shape", path .. ".keys is required on success"); return end
    if page.next_cursor == nil then add(failures, "keys.cursor", path .. ".next_cursor is required on success") end
    if type(page.has_more) ~= "boolean" then add(failures, "keys.has_more", path .. ".has_more is required on success") end
    local keys = page.keys :: { any }
    for i, raw in ipairs(keys) do
        local key = as_map(raw)
        if type(key.item_key) ~= "string" or key.item_key == "" then add(failures, "keys.item_key", path .. ".keys[" .. tostring(i) .. "].item_key is required") end
        if type(key.dedup_key) ~= "string" or key.dedup_key == "" then add(failures, "keys.dedup_key", path .. ".keys[" .. tostring(i) .. "].dedup_key is required") end
    end
    if page.has_more == true and #keys == 0 and page.retry_after_ms == nil then
        add(failures, "keys.empty_page.retry_after_ms", path .. " has_more=true with no keys requires retry_after_ms")
    end
end

local function check_backfill(opts: Map, schema: Map, failures: { Failure })
    local backfill = as_map(opts.backfill_since)
    local mode = backfill.mode
    if mode == "ignored" then
        if type(backfill.reason) ~= "string" or backfill.reason == "" then
            add(failures, "backfill.reason", "backfill_since ignored declaration requires a reason")
        end
        return
    end
    if mode ~= "honored" then
        add(failures, "backfill.declaration", "declare backfill_since mode as honored or ignored")
        return
    end

    local since = type(backfill.value) == "string" and backfill.value or "2026-01-01T00:00:00Z"
    local cfg = config_from(opts.config, "backfill")
    cfg.backfill_since = since
    local page, err = call_pull(opts.pull, { cursor = nil, config = cfg, limit = tonumber(opts.limit) or 2 })
    if err or not page then add(failures, "backfill.pull", "backfill pull failed: " .. tostring(err)); return end
    validate_page(schema, page, "backfill", failures)
    if type(backfill.assert) == "function" then
        local ok, aerr = pcall(backfill.assert, page, since)
        if not ok then add(failures, "backfill.assert", tostring(aerr)) end
        return
    end
    for i, raw in ipairs(type(page.items) == "table" and (page.items :: { any }) or {}) do
        local t = item_time(as_map(raw))
        if t and t < since then
            add(failures, "backfill.honored", "items[" .. tostring(i) .. "] predates backfill_since")
        end
    end
end

function M.run(opts: any): Map
    local options = as_map(opts)
    local failures: { Failure } = {}
    if type(options.pull) ~= "function" then
        add(failures, "config.pull", "pull function is required")
        return { success = false, failures = failures }
    end

    local schema, serr = pull_output_schema()
    if serr or not schema then
        add(failures, "schema.load", tostring(serr))
        return { success = false, failures = failures }
    end

    local limit = tonumber(options.limit) or 2
    local cursor: any = nil
    local seen_cursors: { [string]: boolean } = {}
    local terminal = false
    for page_no = 1, tonumber(options.max_pages) or 5 do
        local page, perr = call_pull(options.pull, { cursor = cursor, config = config_from(options.config, "page"), limit = limit })
        if perr or not page then add(failures, "pull.call", "page " .. tostring(page_no) .. ": " .. tostring(perr)); break end
        validate_page(schema, page, "page" .. tostring(page_no), failures)
        if page.success ~= true then break end

        local next_cursor = page.next_cursor
        local next_key = cursor_key(next_cursor)
        if page.has_more == true then
            if seen_cursors[next_key] then add(failures, "cursor.progress", "cursor repeated while has_more=true: " .. next_key); break end
            seen_cursors[next_key] = true
            cursor = next_cursor
        else
            terminal = true
            break
        end
    end
    if not terminal then add(failures, "cursor.terminal", "source did not reach has_more=false within max_pages") end

    if type(options.failure_config) == "function" or type(options.failure_config) == "table" then
        local page, perr = call_pull(options.pull, { cursor = nil, config = config_from(options.failure_config, "failure"), limit = limit })
        if perr or not page then
            add(failures, "failure.call", "failure path raised instead of returning DataError: " .. tostring(perr))
        else
            validate_page(schema, page, "failure", failures)
        end
    else
        add(failures, "failure.missing", "provide failure_config so the DataError taxonomy is exercised")
    end

    check_backfill(options, schema, failures)
    if options.pull_keys ~= nil then
        if type(options.pull_keys) ~= "function" then
            add(failures, "config.pull_keys", "pull_keys must be a function when reconcile conformance is enabled")
        else
            local key_page, key_err = call_pull(options.pull_keys, { cursor = nil, config = config_from(options.config, "keys"), limit = limit })
            if key_err or not key_page then
                add(failures, "keys.call", "pull_keys failed: " .. tostring(key_err))
            else
                validate_key_page(key_page, "keys", failures)
            end
        end
    end
    return { success = #failures == 0, failures = failures }
end

function M.format_failures(result: any): string
    local failures = type(result) == "table" and (result :: Map).failures or nil
    if type(failures) ~= "table" or #failures == 0 then return "" end
    local parts: { string } = {}
    for _, raw in ipairs(failures :: { any }) do
        local f = as_map(raw)
        parts[#parts + 1] = tostring(f.code) .. ": " .. tostring(f.message)
    end
    return table.concat(parts, "; ")
end

return M
