-- tests/api_doc_test.lua
-- The documents a user and a plugin author read name what the code holds.
-- Each list is read from the code as it runs, never restated here, so a
-- new export, flag, option or route cannot ship undeclared.
--
-- Sections 1 to 6: the README's plugin-author section names every export
--   and capability flag of the server module, the two util functions,
--   every option start reads under several configurations, every
--   /__live/ route and, of the instance's fields, only the two it
--   promises. A route built by concatenation is no literal Section 6
--   reads, and an option start reads under a configuration none of
--   Section 4's gives is not recorded; a nested key is matched as a
--   whole name inside its own section's braces on its top-level key's
--   line. Section 4's table rows: the start-key table names each key
--   Section 4 records, once, and no other; what a row says of the
--   values is read, not checked.
-- Sections 7 and 8: every setup() option, and each field of a section,
--   is in the README's Options block and has an entry in :help's
--   options. The keys come from the defaults table and every M.opts.<key>
--   the module's source spells, and a section whose default is nil
--   (auto_start) takes its fields from every M.opts.<key>.<field>, so a
--   key or field read through an alias of M.opts or rawget is not seen.
-- Section 9: every function of require("live_server") is named in the
--   README's "API (for lua configs)" and in :help's API section. Its
--   tables (opts, state) are the module's state and are not read.
-- Section 10: :help's server API names the surface the README does, and
--   SECURITY.md states the Host check the code holds.
-- Section 11: these SECURITY.md claims are checked by a request beside a
--   phrase of their sentence: the asset route's reach, list and sandbox,
--   the root route sending no sandbox, the listing naming a gated file, a
--   headers origin line on the root route, no origin line on the event
--   stream or an asset, another Access-Control header on an asset and a
--   served file and not on the client, a 404 or the cors preflight, a
--   rebound page with the Host check off, /.well-known/, strict-origin
--   replacing a weaker policy, the started-on dot file, the reserved
--   __live entry (a link of that name into the root and a link elsewhere
--   into it refused, a hard link elsewhere served), a pattern's spelling
--   and a hard link; setup() refusing the two connection keys is checked
--   by a call. The other clauses are read, not checked: that header on a
--   listing or the event stream, a kept no-referrer, the inject
--   endpoint's rules (a page under an allowed_hosts name among them),
--   what a cors list admits, the event stream naming a changed file, the
--   connection pool's defaults and who holds its places, the plain HTTP,
--   a request spelling the entry's name in another case, the cost a
--   pattern spends on the editor's loop, what a program, a browser or a
--   DNS server does later (the start probe, a file swapped between the
--   check and the open, a directory put at the root's path or at
--   asset_root's or one of its parents', an allowed_hosts name's
--   records, the opener's arguments, the history) and what the editor
--   does (auto_start moving the root).
-- Section 12: the README's request order, where a request can check it:
--   the 400 for a first byte, a method, a header name and a value, the
--   414 for a target over 8 KiB (its query counted) before the Host check
--   and any pattern, the namespace's 404 before the method check, and the
--   404 for a method other than GET, a preflight included, through a link
--   into the reserved entry. The order of the other checks is read, not
--   checked.
-- Sections 10 to 12 hold phrase rows, labelled ":help says", ":help
--   names the", "SECURITY.md states" or "the README states", beside rows
--   that check the server: a reworded claim reds a phrase row, a reversed
--   one that keeps the phrase does not.
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

H.case("Section 1: every export of live_server.server is documented", function()
    ok(section ~= "", "the README has the plugin-author section")
    for _, name in ipairs(sorted_keys(server)) do
        ok(section:find(export_shown(name), 1, true) ~= nil, ("server.%s is documented"):format(name))
    end
    ok(section:find("SemVer", 1, true) ~= nil, "the section says SemVer covers it")
    ok(notices == 1, "the notices' paragraph is set outside the promise")
end)

H.case("Section 2: every capability flag is documented", function()
    ok(type(server.features) == "table" and next(server.features) ~= nil, "server.features holds flags")
    local flags = flags_paragraph(section)
    ok(flags ~= "", "the section has the flags' paragraph")
    for _, flag in ipairs(sorted_keys(server.features)) do
        ok(flags:find("`" .. flag .. "`", 1, true) ~= nil, ("features.%s is documented"):format(flag))
    end
end)

H.case("Section 3: the two util functions a plugin calls are documented", function()
    for _, name in ipairs(UTIL_NAMES) do
        ok(type(util[name]) == "function", ("util.%s exists"):format(name))
        ok(section:find("util." .. name .. "(", 1, true) ~= nil, ("util.%s is documented"):format(name))
    end
end)

-- The options are the keys start reads from its table, recorded through a
-- proxy, so a key start begins to read is a key this section must name.
-- start reads some keys only when another is set (a section's fields
-- when the section is a table), so the keys are the union over several
-- configurations: none but the two required, the sections given empty or
-- off, and every option set, a function asset_root and a cors list among
-- them. A section (a map keyed by Lua names, or an empty table) is read
-- through a proxy of its own, so its keys are recorded too; a list, and
-- a map with a key that is no Lua name (the headers map's X-Test), are
-- handed over as they are, since start walks them with ipairs or pairs,
-- which read no proxy.
local function names_only(t)
    for k in pairs(t) do
        if type(k) ~= "string" or not k:find("^[%a_][%w_]*$") then
            return false
        end
    end
    return true
end

-- The text after `<name> = ` at the top level of a table's inside, or nil:
-- a field inside a nested pair of braces is another table's, so
-- features.dirlist's enabled does not name a features.enabled.
local function field_value(inside, name)
    local depth = 0
    for i = 1, #inside do
        local c = inside:sub(i, i)
        if c == "{" then
            depth = depth + 1
        elseif c == "}" then
            depth = depth - 1
        elseif depth == 0 then
            local _, stop = inside:find("^%f[%w_]" .. vim.pesc(name) .. " = ", i)
            if stop then
                return inside:sub(stop + 1)
            end
        end
    end
end

-- Every key Section 4 records, for the start-key table's rows below.
local start_keys = {}

H.case("Section 4: every option start reads is documented", function()
    local root, assets = H.tmpdir(), H.tmpdir()
    H.write_file(root .. "/page.html", "PAGE")
    local read = {}
    local function proxy(backing, prefix)
        return setmetatable({}, {
            __index = function(_, key)
                local value = backing[key]
                if type(value) == "table" and #value == 0 and names_only(value) then
                    return proxy(value, prefix .. key .. ".")
                end
                read[prefix .. key] = true
                return value
            end,
        })
    end
    local configs = {
        { port = 0, root = root },
        { port = 0, root = root, live = {}, features = { dirlist = {} } },
        { port = 0, root = root, live = { enabled = false }, features = {} },
        {
            port = 0,
            root = root,
            host = "127.0.0.1",
            default_index = root .. "/page.html",
            index_names = { "main.html" },
            headers = { ["X-Test"] = "1" },
            cors = true,
            token = "tok",
            protected_paths = { "^/private/" },
            asset_root = assets,
            allowed_hosts = { "dev.test" },
            serve_dotfiles = true,
            notify_on_reload = false,
            header_timeout_ms = 5000,
            max_connections = 8,
            sse_heartbeat_ms = 1000,
            live = { enabled = true, inject_script = true, debounce = 50, css_inject = true },
            features = { dirlist = { enabled = true, show_hidden = true } },
        },
        {
            port = 0,
            root = root,
            cors = { "http://app.test" },
            token = "other",
            asset_root = function()
                return assets
            end,
            live = { enabled = true, inject_script = false, css_inject = false },
            features = { dirlist = { enabled = false } },
        },
    }
    local started = {}
    for _, cfg in ipairs(configs) do
        local inst = server.start(proxy(cfg, ""))
        table.insert(started, inst)
        H.defer(function()
            server.stop(inst)
        end)
    end
    -- The configuration with every option set sends its one header, so
    -- start walked the headers map rather than an empty proxy.
    local sent = H.response(H.raw_request(started[4].port, "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"))
    ok(sent.headers["x-test"] == "1", "start reads the headers map given: X-Test is sent")
    local keys = sorted_keys(read)
    ok(#keys > 0, "start reads its options through the table given")
    for _, key in ipairs(keys) do
        start_keys[key] = true
        -- A nested key is named on its top-level key's line of the example,
        -- as a whole name inside its own section's braces: inject_script
        -- and css_inject do not name inject, nor dirlist's enabled a
        -- features.enabled.
        local parts = vim.split(key, ".", { plain = true })
        local value = section:match("\n  " .. vim.pesc(parts[1]) .. " = ([^\n]*)")
        for i = 2, #parts do
            local braced = value and value:match("^%b{}")
            value = braced and field_value(braced:sub(2, -2), parts[i])
        end
        ok(value ~= nil, ("start's %s is documented"):format(key))
    end
end)

-- The table states each start key's values and refusals, so it names the
-- keys Section 4 records, each once, and no other.
H.case("Section 4, the table: the start-key table has a row for each key start reads", function()
    local tbl = section:match("\nEach key takes the values below[^\n]*\n\n(.-)\n\n") or ""
    ok(tbl ~= "", "the section has the start-key table")
    local rows = {}
    for line in (tbl .. "\n"):gmatch("([^\n]*)\n") do
        local cell = line:match("^| ([^|]+) |")
        for key in (cell or ""):gmatch("`([^`]+)`") do
            ok(not rows[key], ("the table names %s once"):format(key))
            rows[key] = true
            ok(start_keys[key], ("the table's %s is a key start reads"):format(key))
        end
    end
    for _, key in ipairs(sorted_keys(start_keys)) do
        ok(rows[key], ("start's %s has a table row"):format(key))
    end
end)

-- The instance table holds the server's own state; two fields are
-- promised, and naming any other as inst.<field> would promise it too,
-- whether or not a given instance carries it (token is set only with a
-- token), so every inst.<name> the section writes is read.
H.case("Section 5: the instance's two public fields, and no other, are documented", function()
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
H.case("Section 6: every /__live/ route the server answers is documented", function()
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
-- read. The keys come back sorted, each with its fields: a section's
-- fields are options too, the keys of a table default that are all names
-- (the headers table's keys are header names, and a list holds values).
local function setup_options()
    package.loaded["live_server"] = nil
    local opts = require("live_server").opts
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
    local fields = {}
    for _, k in ipairs(keys) do
        local v = opts[k]
        local names = type(v) == "table" and not vim.islist(v) and sorted_keys(v) or {}
        local is_section = #names > 0
        for _, f in ipairs(names) do
            is_section = is_section and type(f) == "string" and f:find("^[%a_][%w_]*$") ~= nil
        end
        fields[k] = is_section and names or {}
    end
    -- A section whose default is nil (auto_start) has no default table to
    -- name its fields, so every M.opts.<key>.<field> the source spells is
    -- a field too.
    for k, f in source:gmatch("M%.opts%.([%a_][%w_]*)%.([%a_][%w_]*)") do
        if fields[k] and not vim.tbl_contains(fields[k], f) then
            table.insert(fields[k], f)
            table.sort(fields[k])
        end
    end
    return keys, fields
end

H.case("Section 7: every setup() option is in README Options", function()
    local block = readme:match("\n## Options\n(.-)\n## ") or ""
    ok(block ~= "", "the README has the Options section")
    local keys, fields = setup_options()
    for _, k in ipairs(keys) do
        ok(block:find("\n  " .. k .. " ", 1, true) ~= nil, "setup option " .. k .. " is in README Options")
        local body = block:match("\n  " .. vim.pesc(k) .. " = {\n(.-)\n  },")
        -- A section shown as a table names each field on a line of its own;
        -- one whose default is nil names its fields on its example lines.
        local example = ""
        for line in block:gmatch("\n  [%-%s]*" .. vim.pesc(k) .. " = [^\n]*") do
            example = example .. line
        end
        for _, f in ipairs(fields[k]) do
            local named
            if body then
                named = ("\n" .. body):find("\n    " .. f .. " ", 1, true) ~= nil
            else
                named = example:find("%f[%w_]" .. vim.pesc(f) .. " = ") ~= nil
            end
            ok(named, ("setup option %s.%s is in README Options"):format(k, f))
        end
    end
end)

-- :help's option list is the other place a user reads the options, so
-- each one, and each field of a section, has its own entry there.
H.case("Section 8: every setup() option has an entry in :help's options", function()
    local help = table.concat(vim.fn.readfile(H.root .. "/doc/live-server.txt"), "\n")
    local block = help:match("%*live%-server%-options%*\n(.-)\n=====") or ""
    ok(block ~= "", "doc/live-server.txt has the live-server-options section")
    local keys, fields = setup_options()
    for _, k in ipairs(keys) do
        ok(block:find("\n`" .. k .. "` (", 1, true) ~= nil, ":help has an entry for setup option " .. k)
        for _, f in ipairs(fields[k]) do
            local entry = "\n`" .. k .. "." .. f .. "` ("
            ok(block:find(entry, 1, true) ~= nil, (":help has an entry for setup option %s.%s"):format(k, f))
        end
    end
end)

-- A user's config calls the functions require("live_server") returns,
-- and the README's "API (for lua configs)" and :help's API section are
-- where SemVer names them, so a function added to the module is named in
-- both. Its tables, opts and state, hold the module's state.
H.case("Section 9: every function of live_server is in README's and :help's API", function()
    package.loaded["live_server"] = nil
    local ls = require("live_server")
    local api = readme:match("\n## API %(for lua configs%)\n(.-)\n### ") or ""
    ok(api ~= "", "the README has the API (for lua configs) section")
    local help = table.concat(vim.fn.readfile(H.root .. "/doc/live-server.txt"), "\n")
    local help_api = help:match("%*live%-server%-api%*\n(.-)\n=====") or ""
    ok(help_api ~= "", "doc/live-server.txt has the live-server-api section")
    local names = 0
    for _, name in ipairs(sorted_keys(ls)) do
        if type(ls[name]) == "function" then
            names = names + 1
            ok(api:find("ls." .. name .. "(", 1, true) ~= nil, ("README's API names ls.%s()"):format(name))
            ok(
                help_api:find("live_server." .. name .. "(", 1, true) ~= nil,
                (":help's API names live_server.%s()"):format(name)
            )
        end
    end
    ok(names > 0, 'require("live_server") returns functions')
end)

-- :help is the other place a plugin author reads the API, so its section
-- holds the surface the README does. SECURITY.md's exposure section states
-- the Host check this release holds, so the flag must be on and each claim
-- has its own row, and dropping either reds.
H.case("Section 10: :help names the same surface, SECURITY.md the Host check", function()
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
    ok(api:find("Host: [::1]:", 1, true) ~= nil, ":help names the bracketed IPv6 Host a client sends")
    ok(
        api:find("unbracketed `Host: ::1:8421`", 1, true) ~= nil
            and api:find("is 400, and so is `Host: ::1`", 1, true) ~= nil,
        ":help says the unbracketed IPv6 Host is 400"
    )

    local security = table.concat(vim.fn.readfile(H.root .. "/SECURITY.md"), "\n")
    local exposes = security:match("\n## What the server exposes\n(.-)\n## ")
        or security:match("\n## What the server exposes\n(.*)$")
        or ""
    ok(exposes ~= "", "SECURITY.md has its exposure section")
    ok(server.features.host_check == true, "features.host_check is on")
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

-- SECURITY.md states only what the code holds, so each claim a request
-- can check is checked here beside a phrase of its sentence: a change to
-- the behaviour, or a rewording of the phrase, reds the row.
local function exposes()
    local security = table.concat(vim.fn.readfile(H.root .. "/SECURITY.md"), "\n")
    return security:match("\n## What the server exposes\n(.-)\n## ")
        or security:match("\n## What the server exposes\n(.*)$")
        or ""
end

local function get(port, path, extra)
    local data = H.raw_request(port, ("GET %s HTTP/1.1\r\nHost: 127.0.0.1\r\n%s\r\n"):format(path, extra or ""))
    return data and H.response(data) or { status = 0, headers = {}, body = "" }
end

local function states(claim, what)
    ok(exposes():find(claim, 1, true) ~= nil, ("SECURITY.md states %s: %s"):format(what, claim))
end

H.case("Section 11: SECURITY.md states what the server serves, as it serves it", function()
    local root, assets = H.tmpdir(), H.tmpdir()
    H.write_file(root .. "/secret.txt", "SECRET")
    H.write_file(root .. "/.draft.html", "DRAFT")
    H.write_file(root .. "/pic.svg", "<svg xmlns='http://www.w3.org/2000/svg'/>")
    H.write_file(assets .. "/.notes", "NOTES")
    H.write_file(assets .. "/.env", "KEY=1")
    H.write_file(assets .. "/pic.svg", "<svg xmlns='http://www.w3.org/2000/svg'/>")

    -- The asset route serves a dot file its list does not hold, refuses
    -- one it does, and sandboxes a document the root route does not.
    local inst = server.start({ port = 0, root = root, asset_root = assets })
    H.defer(function()
        server.stop(inst)
    end)
    local notes = get(inst.port, "/__live/asset?p=.notes")
    ok(notes.status == 200 and notes.body == "NOTES", "the asset route serves a dot file it does not list")
    ok(get(inst.port, "/__live/asset?p=.env").status == 404, "the asset route refuses a name on its list")
    states("dot files included", "the asset route's reach")
    states("that list is no guarantee", "the asset route's deny list")
    local sandboxed = get(inst.port, "/__live/asset?p=pic.svg").headers["content-security-policy"]
    ok(sandboxed == "sandbox", "the asset route sends an SVG with a sandbox")
    local plain = get(inst.port, "/pic.svg")
    ok(plain.status == 200 and plain.headers["content-security-policy"] == nil, "the root route sends none")
    local policed = server.start({
        port = 0,
        root = root,
        asset_root = assets,
        headers = { ["Content-Security-Policy"] = "default-src 'self'" },
    })
    H.defer(function()
        server.stop(policed)
    end)
    local joined = get(policed.port, "/__live/asset?p=pic.svg").headers["content-security-policy"]
    ok(joined == "default-src 'self', sandbox", "a policy set in headers comes first, the sandbox after it")
    states("a `sandbox` directive in `Content-Security-Policy`", "the asset route's sandbox")
    states("runs its script in the server's origin", "what the root route runs")

    -- The listing, on by default, names a file the token gates.
    local gated = server.start({ port = 0, root = root, token = "tok", protected_paths = { "^/secret%.txt$" } })
    H.defer(function()
        server.stop(gated)
    end)
    ok(get(gated.port, "/secret.txt").status == 401, "the protected file needs the token")
    ok(get(gated.port, "/").body:find("secret.txt", 1, true) ~= nil, "the listing names it without one")
    states("the files `protected_paths` gates included", "what the listing names")

    -- cors = false keeps an Access-Control-Allow-Origin set in headers.
    local acao = server.start({ port = 0, root = root, headers = { ["Access-Control-Allow-Origin"] = "*" } })
    H.defer(function()
        server.stop(acao)
    end)
    local read = get(acao.port, "/secret.txt", "Origin: http://other.example\r\n")
    ok(read.headers["access-control-allow-origin"] == "*", "a headers origin line reaches the root route")
    states("you set in `headers` is still sent on the root route", "the headers origin line")

    -- No /__live/ answer carries an origin line, from cors or from
    -- headers: the event stream's head and an asset alike.
    local live = server.start({
        port = 0,
        root = root,
        asset_root = assets,
        cors = true,
        headers = { ["Access-Control-Allow-Origin"] = "*" },
    })
    H.defer(function()
        server.stop(live)
    end)
    local origin = "Origin: http://other.example\r\n"
    local stream = assert(H.raw_connect(live.port))
    assert(stream:send("GET /__live/events HTTP/1.1\r\nHost: 127.0.0.1\r\n" .. origin .. "\r\n"))
    local head = stream:read(2000, function(bytes)
        return bytes:find("\r\n\r\n", 1, true) ~= nil
    end)
    stream:close()
    ok(head:find("text/event-stream", 1, true) ~= nil, "the event stream answers")
    ok(not head:lower():find("access-control-allow-origin", 1, true), "the event stream carries no origin line")
    local asset = get(live.port, "/__live/asset?p=pic.svg", origin)
    ok(asset.status == 200 and asset.headers["access-control-allow-origin"] == nil, "an asset carries none")
    ok(get(live.port, "/secret.txt", origin).headers["access-control-allow-origin"] == "*", "the root route does")
    states("no `/__live/` route carries an `Access-Control-Allow-Origin` header", "the live routes' origin line")

    -- Another Access-Control header set in headers reaches the answers
    -- that carry the caller's headers, and not the client or an error.
    local credentials = server.start({
        port = 0,
        root = root,
        asset_root = assets,
        headers = { ["Access-Control-Allow-Credentials"] = "true" },
    })
    H.defer(function()
        server.stop(credentials)
    end)
    local cred = get(credentials.port, "/__live/asset?p=pic.svg", origin)
    ok(
        cred.headers["access-control-allow-credentials"] == "true"
            and cred.headers["access-control-allow-origin"] == nil,
        "an asset carries a headers Access-Control-Allow-Credentials and no origin line"
    )
    local served = get(credentials.port, "/secret.txt")
    ok(served.headers["access-control-allow-credentials"] == "true", "a file the root route serves carries it")
    local client = get(credentials.port, "/__live/script.js")
    ok(client.status == 200 and client.headers["access-control-allow-credentials"] == nil, "the client does not")
    local missing = get(credentials.port, "/missing.txt")
    ok(missing.status == 404 and missing.headers["access-control-allow-credentials"] == nil, "nor does a 404")
    states(
        "reaches the files and listings the root route serves, the event stream and the asset route",
        "the other Access-Control headers"
    )
    -- The cors preflight answers with its own Access-Control fields alone.
    local preflighted = server.start({
        port = 0,
        root = root,
        cors = true,
        headers = { ["Access-Control-Allow-Credentials"] = "true" },
    })
    H.defer(function()
        server.stop(preflighted)
    end)
    local pre = H.raw_request(
        preflighted.port,
        "OPTIONS /secret.txt HTTP/1.1\r\nHost: 127.0.0.1\r\n" .. origin .. "Access-Control-Request-Method: GET\r\n\r\n"
    )
    pre = pre and H.response(pre) or { status = 0, headers = {} }
    ok(
        pre.status == 204
            and pre.headers["access-control-allow-origin"] == "*"
            and pre.headers["access-control-allow-credentials"] == nil,
        "the cors preflight carries an origin line and not the headers Access-Control-Allow-Credentials"
    )
    states("the `cors` preflight's answer", "what the other Access-Control headers do not reach")

    -- With the Host check off, a page under a name that rebinds to this
    -- machine is answered as the server's own origin; with it on, 421.
    local rebind = "Host: rebind.example\r\n"
    local function as_rebound(port, path)
        local data = H.raw_request(port, ("GET %s HTTP/1.1\r\n%s\r\n"):format(path, rebind))
        return data and H.response(data).status or 0
    end
    local checked = server.start({ port = 0, root = root, asset_root = assets })
    local open = server.start({ port = 0, root = root, asset_root = assets, allowed_hosts = true })
    H.defer(function()
        server.stop(checked)
        server.stop(open)
    end)
    ok(as_rebound(checked.port, "/secret.txt") == 421, "with the Host check on, a rebound name is 421")
    ok(as_rebound(open.port, "/secret.txt") == 200, "with it off, the root route answers a rebound name")
    ok(as_rebound(open.port, "/__live/asset?p=pic.svg") == 200, "and without the token the asset route does too")
    states("a page whose name rebinds to this machine", "a rebound page with the Host check off")

    -- /.well-known/ at the root is served under the dot rule, token or not.
    vim.fn.mkdir(root .. "/.well-known", "p")
    H.write_file(root .. "/.well-known/security.txt", "WELLKNOWN")
    local known = get(gated.port, "/.well-known/security.txt")
    ok(known.status == 200 and known.body == "WELLKNOWN", "/.well-known/ at the root is served without the token")
    states("`/.well-known/` at the root is served either way", "the dot rule's exception")

    -- Every response names strict-origin, a weaker policy set in headers
    -- replaced.
    local policy = server.start({ port = 0, root = root, headers = { ["Referrer-Policy"] = "unsafe-url" } })
    H.defer(function()
        server.stop(policy)
    end)
    ok(get(policy.port, "/secret.txt").headers["referrer-policy"] == "strict-origin", "unsafe-url is replaced")
    states("every response carries `Referrer-Policy: strict-origin`", "the referrer policy")

    -- The file the user started on is served at / though it is a dot file.
    local draft = server.start({ port = 0, root = root, default_index = root .. "/.draft.html" })
    H.defer(function()
        server.stop(draft)
    end)
    ok(get(draft.port, "/").body == "DRAFT", "the started-on dot file is served at /")
    ok(get(draft.port, "/.draft.html").status == 404, "and by its own name is 404")
    states("even when it is a dot file", "the started-on file's exception")

    -- An entry named __live at the root, in any letter case, is the
    -- server's: a directory's files and a file of that name are not
    -- served and the listing leaves the entry out; the file the server
    -- was started on is served at / from there, and the asset route
    -- serves such a directory under its asset_root.
    local reserved, named_file = H.tmpdir(), H.tmpdir()
    vim.fn.mkdir(reserved .. "/__Live", "p")
    H.write_file(reserved .. "/__Live/page.html", "LIVEPAGE")
    H.write_file(reserved .. "/__Live/x.txt", "RESERVED")
    H.write_file(reserved .. "/plain.txt", "PLAIN")
    H.write_file(named_file .. "/__LIVE", "NAMED")
    H.write_file(named_file .. "/plain.txt", "PLAIN")
    local held = server.start({ port = 0, root = reserved, asset_root = reserved })
    local filed = server.start({ port = 0, root = named_file })
    local own = server.start({ port = 0, root = reserved, default_index = reserved .. "/__Live/page.html" })
    H.defer(function()
        server.stop(held)
        server.stop(filed)
        server.stop(own)
    end)
    ok(get(held.port, "/__Live/x.txt").status == 404, "a file in <root>/__Live/ is not served")
    ok(get(filed.port, "/__LIVE").status == 404, "a file named __LIVE at the root is not served")
    local held_list, filed_list = get(held.port, "/").body, get(filed.port, "/").body
    ok(
        held_list:find("plain.txt", 1, true) and not held_list:lower():find("__live", 1, true),
        "the listing leaves the __Live directory out"
    )
    ok(filed_list:find("plain.txt", 1, true) and not filed_list:lower():find("__live", 1, true), "and the __LIVE file")
    states("an entry named `__live` at the root, in any letter case, file or directory", "the reserved entry")
    states("the `__live` entry excepted", "what the listing leaves out")
    ok(get(own.port, "/").body == "LIVEPAGE", "the started-on file in <root>/__Live/ is served at /")
    ok(get(own.port, "/__Live/page.html").status == 404, "and by its own name is 404")
    states("or sits in that directory", "the started-on file's exception")
    local reached = get(held.port, "/__live/asset?p=__Live/x.txt")
    ok(reached.status == 200 and reached.body == "RESERVED", "the asset route serves the directory")
    states("and a `__live` directory too", "the asset route's reach")
    -- A link of that name to a directory in the root and a link elsewhere
    -- into the entry are refused; a hard link elsewhere to a file in it is
    -- another name, which the rule cannot see, and is served.
    local aliased = H.tmpdir()
    vim.fn.mkdir(aliased .. "/pub", "p")
    H.write_file(aliased .. "/pub/page.txt", "PUB")
    local named_link = vim.uv.fs_symlink(aliased .. "/pub", aliased .. "/__Live")
    local into = vim.uv.fs_symlink(reserved .. "/__Live/x.txt", reserved .. "/into.txt")
    local hard, hard_err = vim.uv.fs_link(reserved .. "/__Live/x.txt", reserved .. "/hard.txt")
    if named_link and into then
        local alias = server.start({ port = 0, root = aliased })
        H.defer(function()
            server.stop(alias)
        end)
        ok(
            get(alias.port, "/__Live/page.txt").status == 404,
            "a link named __Live to a directory in the root is not served"
        )
        ok(get(alias.port, "/pub/page.txt").status == 200, "and that directory is served by its own name")
        ok(get(held.port, "/into.txt").status == 404, "a link elsewhere in the root into the entry is not served")
    else
        H.skip("no symbolic link could be made")
    end
    states("or a link of that name to anything", "the reserved entry's link")
    states("nor a file a link elsewhere in the root resolves into it", "a link elsewhere into the entry")
    if hard then
        local twin = get(held.port, "/hard.txt")
        ok(twin.status == 200 and twin.body == "RESERVED", "a hard link elsewhere to a file in the entry is served")
    else
        H.skip("no hard link could be made: " .. tostring(hard_err))
    end
    states(
        "a hard link elsewhere in the root to a file in it is a separate name, which it serves",
        "the hard link into the entry"
    )

    -- A pattern matches the name as the disk spells it; a hard link is
    -- another name.
    H.write_file(root .. "/content.md", "CONTENT")
    local linked, link_err = vim.uv.fs_link(root .. "/content.md", root .. "/alias.md")
    local cased = server.start({ port = 0, root = root, token = "tok", protected_paths = { "^/CONTENT%.MD$" } })
    H.defer(function()
        server.stop(cased)
    end)
    if vim.uv.fs_stat(root .. "/CONTENT.MD") then
        ok(get(cased.port, "/CONTENT.MD").status == 401, "the pattern's own spelling needs the token")
        ok(get(cased.port, "/content.md").status == 200, "the disk's spelling is served without it")
    else
        H.skip("this volume keeps case, so a pattern cased otherwise gates no file")
    end
    states("cased otherwise than the name on disk", "the pattern's spelling")
    if linked then
        local exact = server.start({ port = 0, root = root, token = "tok", protected_paths = { "^/content%.md$" } })
        H.defer(function()
            server.stop(exact)
        end)
        ok(get(exact.port, "/content.md").status == 401, "the protected name needs the token")
        ok(get(exact.port, "/alias.md").status == 200, "a hard link to it is served without")
    else
        H.skip("no hard link could be made: " .. tostring(link_err))
    end
    states("a hard link to a protected file under another name is not gated", "the hard link")

    -- setup() refuses the two connection keys, so every server the
    -- commands open runs with the defaults.
    local live_server = require("live_server")
    for _, key in ipairs({ "max_connections", "header_timeout_ms" }) do
        local took, why = pcall(live_server.setup, { [key] = 1 })
        ok(not took and tostring(why) == "setup does not read the key " .. key, ("setup() refuses %s"):format(key))
    end
    states("`setup()` refuses both keys", "the connection keys")
end)

-- The README's request order is part of the promise, so the checks a
-- request can make are made beside a phrase of their sentence.
H.case("Section 12: the README's request order holds as the server answers", function()
    local order = readme:match("\nThe HTTP surface is part of the same promise[^\n]*") or ""
    ok(order ~= "", "the README has the request-order paragraph")
    local function says(claim, what)
        ok(order:find(claim, 1, true) ~= nil, ("the README states %s: %s"):format(what, claim))
    end
    local root = H.tmpdir()
    H.write_file(root .. "/a.txt", "A")
    local inst = server.start({ port = 0, root = root, cors = true })
    H.defer(function()
        server.stop(inst)
    end)
    local function send(line, extra)
        local data = H.raw_request(inst.port, ("%s\r\nHost: 127.0.0.1\r\n%s\r\n"):format(line, extra or ""))
        return data and H.response(data) or { status = 0, headers = {} }
    end

    -- A head the server cannot read is 400 before any route is read. A
    -- first byte that is no upper-case letter is refused as it arrives,
    -- with no head after it; a method past that byte is read with the head.
    local early = assert(H.raw_connect(inst.port))
    assert(early:send("g"))
    local first = early:read(2000, function(bytes)
        return bytes:find("\r\n\r\n", 1, true) ~= nil
    end)
    early:close()
    ok(first:find("^HTTP/1%.1 400 ") ~= nil, "a lower-case first byte is 400 before the head arrives")
    ok(send("get /a.txt HTTP/1.1").status == 400, "a lower-case method is 400")
    says("whose first byte, after any empty lines, is no upper-case letter", "the 400 for a first byte")
    ok(send("GEt /a.txt HTTP/1.1").status == 400, "a method lower-case past its first letter is 400")
    ok(send("M-SEARCH /a.txt HTTP/1.1").status == 400, "a method holding a hyphen is 400")
    says("a method that is not upper-case letters alone", "the 400 for a method")
    ok(send("GET /a.txt HTTP/1.1", "X-A : 1\r\n").status == 400, "a header name holding a space is 400")
    says("a header name that is no token", "the 400 for a header name")
    ok(send("GET /a.txt HTTP/1.1", "X-A: a\rb\r\n").status == 400, "a bare CR in a value is 400")
    ok(send("GET /a.txt HTTP/1.1", "X-A: a\0b\r\n").status == 400, "a NUL in a value is 400")
    says("a CR or a NUL in a header value", "the 400 for a value")

    -- A target over 8 KiB, its query counted, is 414 once the request line
    -- is read, before any field: a Host the check refuses gets no 421 and
    -- no pattern runs. One byte less is read and gated as usual.
    local gated = server.start({ port = 0, root = root, token = "tok", protected_paths = { "^/a" } })
    H.defer(function()
        server.stop(gated)
    end)
    local real_find, runs = string.find, 0
    local function counted(target, host)
        string.find = function(s, pat, ...)
            runs = runs + (pat == "^/a" and 1 or 0)
            return real_find(s, pat, ...)
        end
        local sent, data =
            pcall(H.raw_request, gated.port, ("GET %s HTTP/1.1\r\nHost: %s\r\n\r\n"):format(target, host))
        string.find = real_find
        return sent and data and H.response(data) or { status = 0, headers = {}, body = "" }
    end
    local long = "/" .. ("a"):rep(8192)
    local over = counted(long, "127.0.0.1")
    ok(over.status == 414 and over.body == "URI Too Long", "an 8193-byte target is 414")
    ok(runs == 0, "and runs no pattern")
    ok(counted(long, "rebind.example").status == 414, "a Host the check refuses does not make it 421")
    local queried = counted("/" .. ("a"):rep(4096) .. "?" .. ("q"):rep(5000), "127.0.0.1")
    ok(queried.status == 414 and runs == 0, "a 4 KiB path with a 5 KiB query is 414")
    ok(counted(long:sub(1, 8192), "127.0.0.1").status == 401 and runs > 0, "an 8192-byte target is read and gated")
    says("a target longer than 8 KiB (8192 bytes), its query included, is 414", "the 414 for a long target")

    -- A method other than GET on a name in the namespace that is no route
    -- is 404 before the method check, so a preflight there gets no origin
    -- line; the root route's preflight still answers.
    local asked = "Origin: http://app.test\r\nAccess-Control-Request-Method: GET\r\n"
    for _, path in ipairs({ "/__live", "/__live/", "/__live/other.txt" }) do
        local r = send("OPTIONS " .. path .. " HTTP/1.1", asked)
        ok(
            r.status == 404 and r.headers["access-control-allow-origin"] == nil,
            ("a preflight on %s is 404 with no origin line"):format(path)
        )
    end
    ok(send("POST /__live/other.txt HTTP/1.1").status == 404, "a POST there is 404")
    ok(send("OPTIONS /__live/events HTTP/1.1", asked).status == 405, "a preflight on a route is 405")
    local root_pre = send("OPTIONS /a.txt HTTP/1.1", asked)
    ok(root_pre.status == 204 and root_pre.headers["access-control-allow-origin"] == "*", "the root route's is 204")
    says("is 404 before the method check", "the namespace's 404 for another method")

    -- So is a method other than GET on a path whose file resolves into the
    -- entry through a link elsewhere in the root, a preflight included,
    -- where any other path answers 405 or the preflight.
    vim.fn.mkdir(root .. "/__live", "p")
    H.write_file(root .. "/__live/other.txt", "OTHER")
    if vim.uv.fs_symlink(root .. "/__live/other.txt", root .. "/link.txt") then
        local through = send("OPTIONS /link.txt HTTP/1.1", asked)
        ok(
            through.status == 404 and through.headers["access-control-allow-origin"] == nil,
            "a preflight through a link into the entry is 404 with no origin line"
        )
        ok(send("POST /link.txt HTTP/1.1").status == 404, "a POST through it is 404")
        ok(send("POST /a.txt HTTP/1.1").status == 405, "and a POST elsewhere 405")
    else
        H.skip("no symbolic link could be made")
    end
    says(
        "or a path whose file resolves into an entry named `__live` at the root through a link elsewhere in the root",
        "the 404 for another method through a link"
    )
end)

H.finish()
