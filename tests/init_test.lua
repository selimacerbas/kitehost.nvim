-- tests/init_test.lua
-- The setup() layer: the options it hands server.start and the URL it
-- opens and prints. The pickers, the browser and vim.notify are stubbed, so
-- a start runs with no UI and the opened URL and the notices are recorded.
--
-- Run: nvim --headless -u NONE -l "$PWD/tests/init_test.lua"

local H = dofile(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "helpers.lua"))
H.isolate()
H.rtp()

local server = require("live_server.server")
local util = require("live_server.util")
local eq, ok = H.eq, H.ok

local root = H.tmpdir()
H.write_file(root .. "/index.html", "<html><body>ok</body></html>")

local opened, started, servers, raised, notices = {}, {}, {}, {}, {}
local real_start, real_notify = server.start, vim.notify
local real_open, real_pick_path, real_pick_port = util.open_browser, util.pick_path, util.pick_port
-- Put back when H.finish drains, so no stub outlives the suite that set it.
H.defer(function()
    server.start, vim.notify = real_start, real_notify
    util.open_browser, util.pick_path, util.pick_port = real_open, real_pick_path, real_pick_port
end)
-- setup() calls server.start under a pcall and, with notify off, says
-- nothing when it raises, so a start that raised left every row green; the
-- spy records the raise for a row to read.
server.start = function(cfg)
    table.insert(started, cfg)
    local started_ok, res = pcall(real_start, cfg)
    if not started_ok then
        table.insert(raised, tostring(res))
        error(res, 0)
    end
    table.insert(servers, res)
    return res
end
util.open_browser = function(url)
    table.insert(opened, url)
end
util.pick_path = function(cb)
    cb(root)
end
-- 0 lets the OS choose a start's port; a row that reopens a server names
-- that server's port here.
local picked_port = 0
util.pick_port = function(_, cb)
    cb(picked_port)
end
-- The level is kept: an error notice would set v:errmsg and fail the
-- suite through the real function, so the last row reads it here instead.
local levels = {}
vim.notify = function(msg, level)
    table.insert(notices, msg)
    table.insert(levels, level or vim.log.levels.INFO)
end

-- A fresh module per start: setup() merges onto the options it holds, so a
-- start would inherit the last one's token.
local function start_with(opts)
    package.loaded["live_server"] = nil
    local ls = require("live_server")
    ls.setup(vim.tbl_extend("force", { notify = false, open_on_start = true }, opts))
    opened, started, servers, raised, notices = {}, {}, {}, {}, {}
    ls.start_picker()
    H.defer(function()
        ls.stop_all()
    end)
    eq(
        table.concat(raised, "; "),
        "",
        ("server.start raised nothing for %s"):format(vim.inspect(opts, { newline = " ", indent = "" }))
    )
    return started[1], opened[1], servers[1], notices
end

H.case("Section 1: setup hands the security options to the server", function()
    local cfg = start_with({})
    eq(cfg and cfg.allowed_hosts, nil, "allowed_hosts defaults to nil")
    eq(cfg and cfg.serve_dotfiles, false, "serve_dotfiles defaults to false")
    cfg = start_with({ allowed_hosts = { "my.name" }, serve_dotfiles = true })
    eq(cfg and cfg.allowed_hosts and cfg.allowed_hosts[1], "my.name", "allowed_hosts reaches server.start")
    eq(cfg and cfg.serve_dotfiles, true, "serve_dotfiles reaches server.start")
end)

H.case("Section 2: setup opens and prints its server's URL, the token included", function()
    local _, url, inst = start_with({})
    eq(
        url,
        ("http://127.0.0.1:%d/"):format(inst and inst.port or -1),
        "the default start opens http://127.0.0.1:<port>/"
    )
    -- A token server gates its event stream, so a page opened without the
    -- token never reloads.
    _, url = start_with({ token = "abc" })
    ok(
        url ~= nil and url:match("^http://127%.0%.0%.1:%d+/%?t=abc$") ~= nil,
        "a token server opens with ?t=: " .. tostring(url)
    )
    _, url = start_with({})
    ok(
        url ~= nil and url:match("^http://127%.0%.0%.1:%d+/$") ~= nil,
        "a tokenless server opens with no query: " .. tostring(url)
    )
    _, url = start_with({ host = "0.0.0.0", token = "abc" })
    ok(
        url ~= nil and url:match("^http://127%.0%.0%.1:%d+/%?t=abc$") ~= nil,
        "a wildcard bind opens on loopback with the token: " .. tostring(url)
    )
    -- The start probes the address its URL names, so a rule of this layer's
    -- own could open an address no start checked. A stubbed server rule
    -- shows which one the URL reads. The URL is built by open_existing,
    -- with no start: the start would probe the stubbed address, which
    -- macOS has no interface for.
    package.loaded["live_server"] = nil
    local ls = require("live_server")
    ls.setup({ notify = false, host = "0.0.0.0" })
    local real_rule = server.wildcard_loopback
    H.defer(function()
        server.wildcard_loopback, picked_port = real_rule, 0
    end)
    server.wildcard_loopback = function(host)
        return host == "0.0.0.0" and "127.0.0.2" or nil
    end
    opened, picked_port = {}, 8123
    ls.open_existing()
    server.wildcard_loopback, picked_port = real_rule, 0
    eq(opened[1], "http://127.0.0.2:8123/", "a wildcard bind's URL names the address the server's rule gives")
    -- Unencoded, a & or a # ends the query early and the server reads a
    -- shorter token.
    _, url = start_with({ token = "a&b#c" })
    ok(url ~= nil and url:match("/%?t=a%%26b%%23c$") ~= nil, "the token rides URL-encoded: " .. tostring(url))

    -- The start notice prints the URL the browser was sent, so a page
    -- opened by hand from it carries the token too. notify = false prints
    -- no notice at all: that user silenced them, and a browser that fails
    -- to open still warns with the URL.
    local notes
    _, url, inst, notes = start_with({ notify = true, token = "abc" })
    local port = inst and inst.port or -1
    eq(
        notes[1],
        ("LiveServer %d started → %s at %s"):format(port, root, tostring(url)),
        "the start notice prints the opened URL"
    )
    ok(
        notes[1] ~= nil and notes[1]:find("/?t=abc", 1, true) ~= nil,
        "a token server's start notice holds ?t=: " .. tostring(notes[1])
    )

    -- A reopen hands the token only to a port this plugin serves: a server
    -- it did not start must not learn it.
    local ls = require("live_server")
    H.defer(function()
        picked_port = 0
    end)
    picked_port = port
    ls.open_existing()
    eq(opened[2], ("http://127.0.0.1:%d/?t=abc"):format(port), "a reopen of this plugin's server carries its token")
    picked_port = 1 -- below every OS's ephemeral range, so never a start's port
    ls.open_existing()
    eq(opened[3], "http://127.0.0.1:1/", "a reopen of a port this plugin does not serve carries no token")
    -- A later setup() may name another host; the server still listens on
    -- the address it bound, which the configured one would not reach.
    ls.setup({ host = "127.0.0.2" })
    picked_port = port
    ls.start_picker()
    eq(
        opened[4],
        ("http://127.0.0.1:%d/?t=abc"):format(port),
        "a retarget opens the bound address, not a host set since"
    )
    picked_port = 0

    _, url, inst, notes = start_with({ notify = true })
    port = inst and inst.port or -1
    eq(
        notes[1],
        ("LiveServer %d started → %s at %s"):format(port, root, tostring(url)),
        "a tokenless start notice prints its URL with no query"
    )
    ok(
        notes[1] ~= nil and notes[1]:find("?t=", 1, true) == nil,
        "a tokenless start notice holds no ?t=: " .. tostring(notes[1])
    )
end)

-- The rows above print on the default host with notify on, where the bound
-- address and the configured one agree, so a notice built apart from the
-- opened URL, one printed on a retarget or one that ignored notify = false
-- all passed. The notice carries the token into :messages, which is why
-- notify = false must silence it.
H.case("Section 3: the start notice is silenced, printed once, and is the opened URL", function()
    local _, _, _, notes = start_with({ notify = false, token = "abc" })
    eq(#notes, 0, "notify = false prints no start notice: " .. table.concat(notes, " | "))

    local url, inst
    _, url, inst, notes = start_with({ notify = true, token = "abc" })
    local port = inst and inst.port or -1
    local before = #notes
    local ls = require("live_server")
    H.defer(function()
        picked_port = 0
    end)
    picked_port = port
    ls.start_picker()
    picked_port = 0
    local later = vim.list_slice(notes, before + 1)
    ok(#later > 0 and later[1]:find("retargeted", 1, true) ~= nil, "a retarget says so: " .. table.concat(later, " | "))
    ok(
        not table.concat(later, " | "):find("started", 1, true),
        "and prints no started notice: " .. table.concat(later, " | ")
    )

    -- A wildcard bind is opened on loopback, and the notice must name that
    -- address, not the one configured.
    _, url, inst, notes = start_with({ notify = true, host = "0.0.0.0", token = "abc" })
    port = inst and inst.port or -1
    eq(url, ("http://127.0.0.1:%d/?t=abc"):format(port), "a wildcard bind opens its loopback URL")
    eq(
        notes[1],
        ("LiveServer %d started → %s at %s"):format(port, root, tostring(url)),
        "and its start notice prints that URL byte for byte"
    )

    -- 0.0.0.0 reads as 127.0.0.1 from either table, so the row above also
    -- passed a notice built from the configured host. Only a host the bind
    -- spells otherwise tells the two apart: 0:0:0:0:0:0:0:1 is bound as ::1.
    local probe = assert(vim.uv.new_tcp())
    local v6, v6_err = probe:bind("::1", 0)
    probe:close()
    if v6 then
        _, url, inst, notes = start_with({ notify = true, host = "0:0:0:0:0:0:0:1", token = "abc" })
        port = inst and inst.port or -1
        eq(
            notes[1],
            ("LiveServer %d started → %s at %s"):format(port, root, tostring(url)),
            "a host the bind spells otherwise prints the opened URL byte for byte"
        )
    else
        H.skip("a host the bind spells otherwise (no IPv6 loopback here: " .. tostring(v6_err) .. ")")
    end
end)

-- setup() deep-extended a caller's headers onto its default, so a
-- ["cache-control"] sat beside the default's Cache-Control and both went
-- out: a cache read "no-cache, max-age=60" and the caller's value did
-- nothing. Start refuses two spellings of one name, so setup folds them.
H.case("Section 4: a caller's header replaces a default under any spelling", function()
    local cfg = start_with({ headers = { ["cache-control"] = "max-age=60" } })
    local spelled = {}
    for k, v in pairs(cfg and cfg.headers or {}) do
        if k:lower() == "cache-control" then
            table.insert(spelled, ("%s = %s"):format(k, v))
        end
    end
    eq(
        table.concat(spelled, ", "),
        "cache-control = max-age=60",
        "one Cache-Control key, the caller's spelling and value"
    )
    cfg = start_with({ headers = { ["X-Frame-Options"] = "DENY" } })
    eq(
        vim.inspect(cfg and cfg.headers, { newline = " ", indent = "" }),
        vim.inspect({ ["Cache-Control"] = "no-cache", ["X-Frame-Options"] = "DENY" }, { newline = " ", indent = "" }),
        "a caller's other header joins the default"
    )
end)

-- A refused start was reported as "Failed to bind port N:" and then the
-- server's message, so a refused option read as a busy port and a failed
-- bind named the bind twice. The server's raise names its cause, and the
-- notice names what failed before it: :messages shows no title. Captured
-- here, where the suite's own notify would count the error notice against
-- the last row.
H.case("Section 5: a refused start says it did not start, then the server's cause", function()
    local notes = {}
    local suite_notify = vim.notify
    vim.notify = function(msg, level)
        table.insert(notes, { msg = msg, level = level })
    end
    H.defer(function()
        vim.notify = suite_notify
    end)
    local function refused_with(opts)
        package.loaded["live_server"] = nil
        local ls = require("live_server")
        ls.setup(vim.tbl_extend("force", { notify = true, open_on_start = false }, opts))
        notes, raised = {}, {}
        ls.start_picker()
        H.defer(function()
            ls.stop_all()
        end)
        return notes[1] or {}
    end
    local note = refused_with({ token = "" })
    eq(
        note.msg,
        "LiveServer did not start: token must be a non-empty string",
        "a refused option is reported in the server's words, after what failed"
    )
    eq(note.level, vim.log.levels.ERROR, "as an error")
    -- TEST-NET-1 (RFC 5737) is assigned to no interface on any OS.
    note = refused_with({ host = "192.0.2.1" })
    ok(
        raised[1] ~= nil and note.msg == "LiveServer did not start: " .. raised[1],
        ("a failed bind is reported as the server raised it: %s (raised %s)"):format(
            tostring(note.msg),
            tostring(raised[1])
        )
    )
end)

-- A section given as a boolean replaced the table every start reads its
-- fields from, so each start raised indexing it, outside the start's
-- pcall: a Lua error, and no server started. false turns the section
-- off and true on, its other fields kept.
H.case("Section 6: a section given as false or true turns it off or on", function()
    local function section_of(cfg, section)
        if section == "live_reload" then
            return cfg and cfg.live
        end
        return cfg and cfg.features and cfg.features.dirlist
    end
    for _, c in ipairs({
        { "live_reload", false },
        { "live_reload", true },
        { "directory_listing", false },
        { "directory_listing", true },
    }) do
        local section, on = c[1], c[2]
        local ran, cfg = pcall(start_with, { [section] = on })
        local got = ran and section_of(cfg, section) or nil
        ok(
            ran and got ~= nil and got.enabled == on,
            ("%s = %s starts with the section %s: %s"):format(
                section,
                tostring(on),
                on and "on" or "off",
                ran and vim.inspect(got, { newline = " ", indent = "" }) or tostring(cfg)
            )
        )
    end
    local ran, cfg = pcall(start_with, { live_reload = false })
    local live = ran and section_of(cfg, "live_reload") or {}
    eq(live.debounce, 120, "and live_reload = false keeps the section's other fields")
end)

-- A section that is neither a table nor a boolean took the table's place
-- too: a number raised indexing it at every start, outside the start's
-- pcall, and a string read as the section with every field unset, so
-- live_reload = "off" served with live reload on, without a word. setup
-- reads the section, so setup refuses it, before any option of the call
-- is kept.
H.case("Section 7: setup refuses a section that is neither a table nor a boolean", function()
    for _, c in ipairs({
        { "live_reload", 1 },
        { "live_reload", "off" },
        { "directory_listing", 0 },
        { "directory_listing", "off" },
    }) do
        local section, value = c[1], c[2]
        package.loaded["live_server"] = nil
        local ls = require("live_server")
        local set, err = pcall(ls.setup, { notify = false, [section] = value })
        eq(
            not set and tostring(err) or "setup took it",
            section .. " must be a table or a boolean",
            ("setup refuses %s = %s, naming it"):format(section, vim.inspect(value))
        )
    end
    package.loaded["live_server"] = nil
    local ls = require("live_server")
    pcall(ls.setup, { default_port = 9000, live_reload = 1 })
    ok(
        ls.opts.default_port == 8000 and type(ls.opts.live_reload) == "table",
        ("and a refused setup keeps every option it had (default_port %s, live_reload %s)"):format(
            tostring(ls.opts.default_port),
            vim.inspect(ls.opts.live_reload, { newline = " ", indent = "" })
        )
    )
    -- Every start refuses a flag that is no boolean, so setup took one and
    -- each start then failed, far from the config that held it; setup
    -- refuses it, keeping what it had.
    for _, c in ipairs({
        { { live_reload = { enabled = 1 } }, "live_reload.enabled" },
        { { live_reload = { inject_script = "yes" } }, "live_reload.inject_script" },
        { { live_reload = { css_inject = 0 } }, "live_reload.css_inject" },
        { { directory_listing = { enabled = 1 } }, "directory_listing.enabled" },
        { { directory_listing = { show_hidden = "no" } }, "directory_listing.show_hidden" },
        { { notify_on_reload = 1 }, "notify_on_reload" },
    }) do
        package.loaded["live_server"] = nil
        local flagged = require("live_server")
        local set, err = pcall(flagged.setup, vim.tbl_extend("force", { notify = false, default_port = 9000 }, c[1]))
        eq(
            not set and tostring(err) or "setup took it",
            c[2] .. " must be a boolean",
            ("setup refuses %s = %s, naming it"):format(c[2], vim.inspect(c[1], { newline = " ", indent = "" }))
        )
        eq(flagged.opts.default_port, 8000, ("and a refused %s keeps every option it had"):format(c[2]))
    end
    package.loaded["live_server"] = nil
    local flags = require("live_server")
    local set, err = pcall(flags.setup, {
        notify = false,
        notify_on_reload = true,
        live_reload = { enabled = false, inject_script = false, css_inject = false },
        directory_listing = { enabled = false, show_hidden = true },
    })
    ok(set, "every flag given as a boolean is taken: " .. tostring(err))
end)

-- update_target raises on a root it cannot serve, and the retarget called
-- it bare, so the raise reached the user as a Lua error with a position
-- and no word of what failed. It is a notice now, in the shape of a
-- refused start's, and the server keeps serving its root. realpath is
-- stubbed for one directory that stats: no real directory both stats and
-- fails to resolve on demand.
H.case("Section 8: a retarget the server refuses is a notice, not a raise", function()
    local _, _, inst = start_with({ notify = true })
    assert(inst, "a server started to retarget")
    local served = inst.root
    local notes = {}
    local suite_notify = vim.notify
    local real_realpath = vim.uv.fs_realpath
    H.defer(function()
        vim.notify, vim.uv.fs_realpath, util.pick_path, picked_port = suite_notify, real_realpath, real_pick_path, 0
    end)
    vim.notify = function(msg, level)
        table.insert(notes, { msg = msg, level = level })
    end
    local unresolved, other = H.tmpdir(), H.tmpdir()
    vim.uv.fs_realpath = function(path, ...)
        if path == unresolved then
            return nil, "ENOENT: stubbed", "ENOENT"
        end
        return real_realpath(path, ...)
    end
    local target = unresolved
    util.pick_path = function(cb)
        cb(target)
    end
    picked_port = inst.port
    local ls = require("live_server")
    local called, err = pcall(ls.start_picker)
    vim.uv.fs_realpath = real_realpath
    ok(called, "a retarget the server refuses raises nothing to the caller: " .. tostring(err))
    eq(#notes, 1, "and prints one notice: " .. vim.inspect(notes, { newline = " ", indent = "" }))
    local note = notes[1] or {}
    eq(
        note.msg,
        ("LiveServer could not retarget: update_target: root %s does not resolve (ENOENT: stubbed)"):format(unresolved),
        "naming what failed, then the server's cause"
    )
    eq(note.level, vim.log.levels.ERROR, "as an error")
    eq(inst.root, served, "and the server keeps its root")
    notes, target = {}, other
    called, err = pcall(ls.start_picker)
    ok(called, "a retarget to a real directory raises nothing: " .. tostring(err))
    eq(inst.root, other, "and moves the root")
    ok(
        notes[1] ~= nil and notes[1].msg:find("retargeted", 1, true) ~= nil,
        "and says so: " .. vim.inspect(notes, { newline = " ", indent = "" })
    )
end)

local errors = 0
for _, level in ipairs(levels) do
    if level >= vim.log.levels.ERROR then
        errors = errors + 1
    end
end
eq(errors, 0, "no start in this suite raised an error notice")

H.finish()
