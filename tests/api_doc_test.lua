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
--   Section 4's gives is not recorded.
-- Sections 7 and 8: every setup() option, and each field of a section,
--   is in the README's Options block and has an entry in :help's
--   options. The keys come from the defaults table and every M.opts.<key>
--   the module's source spells, so a key read through an alias of M.opts
--   or rawget is not seen.
-- Section 9: every function of require("live_server") is named in the
--   README's "API (for lua configs)" and in :help's API section. Its
--   tables (opts, state) are the module's state and are not read.
-- Section 10: :help's server API names the surface the README does, and
--   SECURITY.md states the Host check the code holds.
-- Section 11: each SECURITY.md claim a request can check is checked
--   beside its sentence: the asset route's reach, list and sandbox, the
--   listing, a headers origin line, the started-on dot file, a pattern's
--   spelling and a hard link. A claim about what a program or a browser
--   does later (the start probe, where the token travels) has no row.
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
-- them. A map or an empty table is read through a proxy of its own, so
-- its keys are recorded too; a list is handed over as it is, since start
-- walks it with ipairs, which reads no proxy.
H.case("Section 4: every option start reads is documented", function()
    local root, assets = H.tmpdir(), H.tmpdir()
    local read = {}
    local function proxy(backing, prefix)
        return setmetatable({}, {
            __index = function(_, key)
                local value = backing[key]
                if type(value) == "table" and #value == 0 then
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
    for _, cfg in ipairs(configs) do
        local inst = server.start(proxy(cfg, ""))
        H.defer(function()
            server.stop(inst)
        end)
    end
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
    return keys, fields
end

H.case("Section 7: every setup() option is in README Options", function()
    local block = readme:match("\n## Options\n(.-)\n## ") or ""
    ok(block ~= "", "the README has the Options section")
    local keys, fields = setup_options()
    for _, k in ipairs(keys) do
        ok(block:find("\n  " .. k .. " ", 1, true) ~= nil, "setup option " .. k .. " is in README Options")
        local body = "\n" .. (block:match("\n  " .. vim.pesc(k) .. " = {\n(.-)\n  },") or "")
        for _, f in ipairs(fields[k]) do
            ok(
                body:find("\n    " .. f .. " ", 1, true) ~= nil,
                ("setup option %s.%s is in README Options"):format(k, f)
            )
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

-- SECURITY.md states only what the code holds, so each claim a request
-- can check is checked here beside its sentence: a change to either
-- reds the row, and the two are brought back together.
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
    states("`Content-Security-Policy: sandbox`", "the asset route's sandbox")
    states("script in the server's origin", "what the root route runs")

    -- The listing, on by default, names a file the token gates.
    local gated = server.start({ port = 0, root = root, token = "tok", protected_paths = { "^/secret%.txt$" } })
    H.defer(function()
        server.stop(gated)
    end)
    ok(get(gated.port, "/secret.txt").status == 401, "the protected file needs the token")
    ok(get(gated.port, "/").body:find("secret.txt", 1, true) ~= nil, "the listing names it without one")
    states("the files `protected_paths` gates included", "what the listing names")

    -- cors = false keeps an Access-Control-Allow-Origin passed in headers.
    local acao = server.start({ port = 0, root = root, headers = { ["Access-Control-Allow-Origin"] = "*" } })
    H.defer(function()
        server.stop(acao)
    end)
    local read = get(acao.port, "/secret.txt", "Origin: http://other.example\r\n")
    ok(read.headers["access-control-allow-origin"] == "*", "a headers origin line reaches the root route")
    states("With `cors = false`, an `Access-Control-Allow-Origin` you pass in `headers`", "the headers origin line")

    -- The file the user started on is served at / though it is a dot file.
    local draft = server.start({ port = 0, root = root, default_index = root .. "/.draft.html" })
    H.defer(function()
        server.stop(draft)
    end)
    ok(get(draft.port, "/").body == "DRAFT", "the started-on dot file is served at /")
    ok(get(draft.port, "/.draft.html").status == 404, "and by its own name is 404")
    states("even when it is a dot file", "the started-on file's exception")

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
end)

H.finish()
