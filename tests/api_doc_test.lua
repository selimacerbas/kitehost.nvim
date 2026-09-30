-- tests/api_doc_test.lua
-- The README's plugin-author section is the public API SemVer covers:
-- every export and capability flag of the server module, every option
-- start reads and every /__live/ route the server answers is named there,
-- and of the instance's fields only the two it promises, so a new one
-- cannot ship undeclared. Each list is read from the code as it runs,
-- never restated here.
--
-- Run: nvim --headless -u NONE -l "$PWD/tests/api_doc_test.lua"

local H = dofile(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "helpers.lua"))
H.isolate()
H.rtp()

local server = require("live_server.server")
local util = require("live_server.util")
local ok = H.ok

local readme = table.concat(vim.fn.readfile(H.root .. "/README.md"), "\n")
local section = readme:match("\n### Server%-level API %(for plugin authors%)\n(.-)\n### ") or ""
-- The notices' paragraph describes them for a person and says it stands
-- outside the promise, so nothing it names is read as promised.
local notices
section, notices = section:gsub("\nOutside the promise,[^\n]*", "")

local function sorted_keys(t)
    local keys = vim.tbl_keys(t)
    table.sort(keys)
    return keys
end

-- The README and :help hold the same surface, so its rules are written
-- once: an export as a caller writes it, the flags' own paragraph (where a
-- flag named like an option would otherwise match on that option's line),
-- the two util functions a plugin calls, the two promised instance fields
-- and any other inst.<field> a text names, which would promise it too.
local UTIL_NAMES = { "random_token", "secure_compare" }
local INST_FIELDS = { "host", "port" }

local function export_shown(name)
    return type(server[name]) == "function" and ("server." .. name .. "(") or ("server." .. name)
end

local function flags_paragraph(text)
    return text:match("\n(`server%.features` holds.-)\n\n") or ""
end

local function names_inst(text, field)
    return text:find("inst%." .. field .. "%f[^%w_]") ~= nil
end

local function other_inst_fields(text)
    local promised = {}
    for _, field in ipairs(INST_FIELDS) do
        promised[field] = true
    end
    local named, seen = {}, {}
    for field in text:gmatch("inst%.([%a_][%w_]*)") do
        if not promised[field] and not seen[field] then
            seen[field] = true
            table.insert(named, field)
        end
    end
    table.sort(named)
    return named
end

H.case("every export of live_server.server is documented", function()
    ok(section ~= "", "the README has the plugin-author section")
    for _, name in ipairs(sorted_keys(server)) do
        ok(section:find(export_shown(name), 1, true) ~= nil, ("server.%s is documented"):format(name))
    end
    ok(section:find("SemVer", 1, true) ~= nil, "the section says SemVer covers it")
    ok(notices == 1, "the notices' paragraph is set outside the promise")
end)

H.case("every capability flag is documented", function()
    ok(type(server.features) == "table" and next(server.features) ~= nil, "server.features holds flags")
    local flags = flags_paragraph(section)
    ok(flags ~= "", "the section has the flags' paragraph")
    for _, flag in ipairs(sorted_keys(server.features)) do
        ok(flags:find("`" .. flag .. "`", 1, true) ~= nil, ("features.%s is documented"):format(flag))
    end
end)

H.case("the two util functions a plugin calls are documented", function()
    for _, name in ipairs(UTIL_NAMES) do
        ok(type(util[name]) == "function", ("util.%s exists"):format(name))
        ok(section:find("util." .. name .. "(", 1, true) ~= nil, ("util.%s is documented"):format(name))
    end
end)

-- The options are the keys start reads from its table, recorded through a
-- proxy, so a key start begins to read is a key this section must name. The
-- two nested tables are given so their own keys are read too.
H.case("every option start reads is documented", function()
    local root = H.tmpdir()
    local read = {}
    local function proxy(backing, prefix)
        return setmetatable({}, {
            __index = function(_, key)
                local value = backing[key]
                if type(value) == "table" then
                    return proxy(value, prefix .. key .. ".")
                end
                read[prefix .. key] = true
                return value
            end,
        })
    end
    local inst = server.start(proxy({
        port = 0,
        root = root,
        live = { enabled = false },
        features = { dirlist = {} },
    }, ""))
    H.defer(function()
        server.stop(inst)
    end)
    local keys = sorted_keys(read)
    ok(#keys > 0, "start reads its options through the table given")
    for _, key in ipairs(keys) do
        -- A nested key is named on its top-level key's line of the example.
        local parts = vim.split(key, ".", { plain = true })
        local line = section:match("\n  " .. vim.pesc(parts[1]) .. " = [^\n]*")
        local named = line ~= nil
        for i = 2, #parts do
            named = named and line:find(parts[i] .. " = ", 1, true) ~= nil
        end
        ok(named, ("start's %s is documented"):format(key))
    end
end)

-- The instance table holds the server's own state; two fields are
-- promised, and naming any other as inst.<field> would promise it too,
-- whether or not a given instance carries it (token is set only with a
-- token), so every inst.<name> the section writes is read.
H.case("the instance's two public fields, and no other, are documented", function()
    local inst = server.start({ port = 0, root = H.tmpdir() })
    H.defer(function()
        server.stop(inst)
    end)
    for _, field in ipairs(INST_FIELDS) do
        ok(inst[field] ~= nil, ("a started instance holds %s"):format(field))
        ok(names_inst(section, field), ("inst.%s is documented"):format(field))
    end
    local named = other_inst_fields(section)
    ok(#named == 0, "no other field is named: " .. table.concat(named, ", "))
end)

-- The routes are the /__live/ literals in the server's source, so a route
-- added there reds this row until the section names it.
H.case("every /__live/ route the server answers is documented", function()
    local source = table.concat(vim.fn.readfile(H.root .. "/lua/live_server/server.lua"), "\n")
    local seen, routes = {}, {}
    for found in source:gmatch("/__live/[%w._-]+") do
        -- A comment's sentence ends a literal with its full stop.
        local route = found:gsub("%.+$", "")
        if not seen[route] then
            seen[route] = true
            table.insert(routes, route)
        end
    end
    table.sort(routes)
    ok(#routes > 0, "the server's source names its routes")
    for _, route in ipairs(routes) do
        ok(section:find(vim.pesc(route) .. "%f[^%w_-]") ~= nil, route .. " is documented")
    end
end)

-- setup() takes the keys of its defaults table and every key the module
-- reads from M.opts. A key whose default is nil is no key of opts at run
-- time, so both are read from the module's source; each run-time key
-- found in the table, and a key found there that opts lacks, prove that
-- read.
H.case("Section 2: every setup() option is in README Options", function()
    package.loaded["live_server"] = nil
    local opts = require("live_server").opts
    local block = readme:match("\n## Options\n(.-)\n## ") or ""
    ok(block ~= "", "the README has the Options section")
    local source = table.concat(vim.fn.readfile(H.root .. "/lua/live_server/init.lua"), "\n")
    local defaults = "\n" .. (source:match("\nlocal defaults = {\n(.-)\n}\n") or "")
    local declared, seen, keys = {}, {}, {}
    local function add(k)
        if not seen[k] then
            seen[k] = true
            table.insert(keys, k)
        end
    end
    local unset = 0
    for k in defaults:gmatch("\n    ([%a_][%w_]*) = ") do
        declared[k] = true
        unset = unset + (opts[k] == nil and 1 or 0)
        add(k)
    end
    ok(unset > 0, "the defaults table read names a key opts lacks, a nil default")
    for k in pairs(opts) do
        ok(declared[k], ("opts.%s is read from the defaults table"):format(k))
        add(k)
    end
    -- An option forwarded to the server with no default is one too.
    for k in source:gmatch("M%.opts%.([%a_][%w_]*)") do
        add(k)
    end
    table.sort(keys)
    for _, k in ipairs(keys) do
        ok(block:find("\n  " .. k .. " ", 1, true) ~= nil, "setup option " .. k .. " is in README Options")
        -- A section's fields are options too; the headers table's keys are
        -- header names, and a list holds values.
        local v = opts[k]
        local fields = type(v) == "table" and not vim.islist(v) and sorted_keys(v) or {}
        local is_section = #fields > 0
        for _, f in ipairs(fields) do
            is_section = is_section and type(f) == "string" and f:find("^[%a_][%w_]*$") ~= nil
        end
        if is_section then
            local body = "\n" .. (block:match("\n  " .. vim.pesc(k) .. " = {\n(.-)\n  },") or "")
            for _, f in ipairs(fields) do
                ok(
                    body:find("\n    " .. f .. " ", 1, true) ~= nil,
                    ("setup option %s.%s is in README Options"):format(k, f)
                )
            end
        end
    end
end)

-- :help is the other place a plugin author reads the API, so its section
-- holds the surface the README does. SECURITY.md's exposure section states
-- the Host check this release holds, so the flag must be on and each claim
-- has its own row, and dropping either reds.
H.case("Section 3: :help names the same surface, SECURITY.md the Host check", function()
    local help = table.concat(vim.fn.readfile(H.root .. "/doc/live-server.txt"), "\n")
    local api = help:match("%*live%-server%-server%-api%*\n(.-)\n=====") or ""
    ok(api ~= "", "doc/live-server.txt has the live-server-server-api section")
    for _, name in ipairs(sorted_keys(server)) do
        ok(api:find(export_shown(name), 1, true) ~= nil, (":help names server.%s"):format(name))
    end
    local flags = flags_paragraph(api)
    ok(flags ~= "", ":help has the flags' paragraph")
    for _, flag in ipairs(sorted_keys(server.features)) do
        ok(flags:find("`" .. flag .. "`", 1, true) ~= nil, (":help names features.%s"):format(flag))
    end
    for _, name in ipairs(UTIL_NAMES) do
        ok(api:find("util." .. name .. "(", 1, true) ~= nil, (":help names util.%s"):format(name))
    end
    for _, field in ipairs(INST_FIELDS) do
        ok(names_inst(api, field), (":help names inst.%s"):format(field))
    end
    local named = other_inst_fields(api)
    ok(#named == 0, ":help names no other field: " .. table.concat(named, ", "))
    ok(api:find("SemVer", 1, true) ~= nil, ":help says SemVer covers it")

    local security = table.concat(vim.fn.readfile(H.root .. "/SECURITY.md"), "\n")
    local exposes = security:match("\n## What the server exposes\n(.-)\n## ")
        or security:match("\n## What the server exposes\n(.*)$")
        or ""
    ok(exposes ~= "", "SECURITY.md has its exposure section")
    ok(server.features.host_check == true, "features.host_check is on, as SECURITY.md states")
    for _, claim in ipairs({
        "421",
        "`*.localhost`",
        "`allowed_hosts`",
        "`allowed_hosts = true`",
        "`0.0.0.0` included, has none",
    }) do
        ok(exposes:find(claim, 1, true) ~= nil, "SECURITY.md states the Host check: " .. claim)
    end
end)

H.finish()
