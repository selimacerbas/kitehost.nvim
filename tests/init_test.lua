-- tests/init_test.lua
-- The setup() layer: the options it hands server.start and the URL it
-- opens and prints, a configured zone left out of it on a port with no
-- instance (Section 9). The pickers, the browser and vim.notify are
-- stubbed, so a start runs with no UI and the opened URL and the notices
-- are recorded.
-- SETUP_KEYS names the keys the module's source reads and no other
-- (Section 7b).
--
-- Run: nvim --headless -u NONE -l "$PWD/tests/init_test.lua"

local H = dofile(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "helpers.lua"))
H.isolate()
H.rtp()

local server = require("kitehost.server")
local util = require("kitehost.util")
local eq, ok = H.eq, H.ok
local is_win = vim.fn.has("win32") == 1

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
    package.loaded["kitehost"] = nil
    local ls = require("kitehost")
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
    package.loaded["kitehost"] = nil
    local ls = require("kitehost")
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
        ("kitehost: port %d started → %s at %s"):format(port, root, tostring(url)),
        "the start notice prints the opened URL"
    )
    ok(
        notes[1] ~= nil and notes[1]:find("/?t=abc", 1, true) ~= nil,
        "a token server's start notice holds ?t=: " .. tostring(notes[1])
    )

    -- A reopen hands the token only to a port this plugin serves: a server
    -- it did not start must not learn it.
    local ls = require("kitehost")
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
        ("kitehost: port %d started → %s at %s"):format(port, root, tostring(url)),
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
    local ls = require("kitehost")
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
        ("kitehost: port %d started → %s at %s"):format(port, root, tostring(url)),
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
            ("kitehost: port %d started → %s at %s"):format(port, root, tostring(url)),
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
        package.loaded["kitehost"] = nil
        local ls = require("kitehost")
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
        "kitehost: port 0 did not start: token must be a non-empty string",
        "a refused option is reported in the server's words, after what failed"
    )
    eq(note.level, vim.log.levels.ERROR, "as an error")
    -- TEST-NET-1 (RFC 5737) is assigned to no interface on any OS.
    note = refused_with({ host = "192.0.2.1" })
    ok(
        raised[1] ~= nil and note.msg == "kitehost: port 0 did not start: " .. raised[1],
        ("a failed bind is reported as the server raised it: %s (raised %s)"):format(
            tostring(note.msg),
            tostring(raised[1])
        )
    )
    -- notify = false silenced the refusal too, so a start on a taken port
    -- failed without a word; it silences the notices that report success.
    local held = assert(vim.uv.new_tcp())
    H.defer(function()
        held:close()
    end)
    assert(held:bind("127.0.0.1", 0))
    assert(held:listen(1, function() end))
    local held_port = assert(held:getsockname()).port
    H.defer(function()
        picked_port = 0
    end)
    picked_port = held_port
    note = refused_with({ notify = false })
    picked_port = 0
    ok(
        raised[1] ~= nil and note.msg == ("kitehost: port %d did not start: "):format(held_port) .. raised[1],
        ("with notify = false a start on a taken port still says it did not start: %s (raised %s)"):format(
            tostring(note.msg),
            tostring(raised[1])
        )
    )
    eq(note.level, vim.log.levels.ERROR, "as an error")
    note = refused_with({ notify = false })
    eq(raised[1], nil, "a start on a free port with notify = false starts")
    eq(#notes, 0, "and says nothing: " .. vim.inspect(notes, { newline = " ", indent = "" }))
    -- A warning is kept as an error is: a reload asked of a port no server
    -- holds said nothing under notify = false, and the user read it as done.
    local ls = require("kitehost")
    notes, picked_port = {}, 1
    ls.force_reload()
    picked_port = 0
    eq(
        notes[1] and notes[1].msg,
        "kitehost: no instance on that port.",
        "with notify = false a warning is still shown: " .. vim.inspect(notes, { newline = " ", indent = "" })
    )
    eq(notes[1] and notes[1].level, vim.log.levels.WARN, "as a warning")
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
        package.loaded["kitehost"] = nil
        local ls = require("kitehost")
        local set, err = pcall(ls.setup, { notify = false, [section] = value })
        eq(
            not set and tostring(err) or "setup took it",
            section .. " must be a table or a boolean",
            ("setup refuses %s = %s, naming it"):format(section, vim.inspect(value))
        )
    end
    package.loaded["kitehost"] = nil
    local ls = require("kitehost")
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
        { { live_reload = { enabled = 1 } }, "live_reload.enabled", "number" },
        { { live_reload = { inject_script = "yes" } }, "live_reload.inject_script", "string" },
        { { live_reload = { css_inject = 0 } }, "live_reload.css_inject", "number" },
        { { directory_listing = { enabled = 1 } }, "directory_listing.enabled", "number" },
        { { directory_listing = { show_hidden = "no" } }, "directory_listing.show_hidden", "string" },
        { { notify_on_reload = 1 }, "notify_on_reload", "number" },
        { { open_on_start = "no" }, "open_on_start", "string" },
        { { notify = 0 }, "notify", "number" },
        { { serve_dotfiles = "yes" }, "serve_dotfiles", "string" },
    }) do
        package.loaded["kitehost"] = nil
        local flagged = require("kitehost")
        local set, err = pcall(flagged.setup, vim.tbl_extend("force", { notify = false, default_port = 9000 }, c[1]))
        -- The wording start uses, where setup said "must be a boolean".
        eq(
            not set and tostring(err) or "setup took it",
            ("%s must be true or false, got %s"):format(c[2], c[3]),
            ("setup refuses %s = %s, naming it"):format(c[2], vim.inspect(c[1], { newline = " ", indent = "" }))
        )
        eq(flagged.opts.default_port, 8000, ("and a refused %s keeps every option it had"):format(c[2]))
    end
    -- setup reads auto_start's fields, so a number there, or in its
    -- filetypes, raised with a file position and no word of the option.
    for _, c in ipairs({
        { 5, "auto_start must be a table or false" },
        { "html", "auto_start must be a table or false" },
        { true, "auto_start must be a table or false" },
        { { filetypes = 5 }, "auto_start.filetypes must be a list of filetype names" },
        { { filetypes = "html" }, "auto_start.filetypes must be a list of filetype names" },
        { { filetypes = { 1 } }, "auto_start.filetypes must be a list of filetype names" },
    }) do
        local value = vim.inspect(c[1], { newline = " ", indent = "" })
        package.loaded["kitehost"] = nil
        local configured = require("kitehost")
        local set, err = pcall(configured.setup, { notify = false, default_port = 9000, auto_start = c[1] })
        eq(
            not set and tostring(err) or "setup took it",
            c[2],
            ("setup refuses auto_start = %s, naming it"):format(value)
        )
        eq(
            configured.opts.default_port,
            8000,
            ("and a refused auto_start = %s keeps every option it had"):format(value)
        )
    end
    -- The autocmd API reads an empty pattern as every filetype and a comma
    -- as two, and it refused a brace or a line break with a file position
    -- after the options were replaced and the earlier autocmd cleared. A
    -- pattern character armed every filetype or many; Neovim refuses a
    -- plus in 'filetype' (E474), so an entry holding one armed an autocmd
    -- no buffer could fire.
    for _, bad in ipairs({ "", "html,css", "{a", "a\nb", "*", "?", "h?ml", "c++" }) do
        local shown = vim.inspect(bad)
        pcall(vim.api.nvim_del_augroup_by_name, "KiteHostAutoStart")
        package.loaded["kitehost"] = nil
        local configured = require("kitehost")
        configured.setup({ notify = false, auto_start = { filetypes = { "keeptestft" } } })
        local set, err = pcall(configured.setup, {
            notify = false,
            default_port = 9002,
            auto_start = { filetypes = { "html", bad } },
        })
        eq(
            not set and tostring(err) or "setup took it",
            "auto_start.filetypes must be a list of filetype names",
            ("setup refuses the filetype %s, naming the option"):format(shown)
        )
        eq(configured.opts.default_port, 8000, ("and a refused filetype %s keeps every option it had"):format(shown))
        local found, cmds = pcall(vim.api.nvim_get_autocmds, { group = "KiteHostAutoStart", event = "FileType" })
        ok(
            found and #cmds == 1 and cmds[1].pattern == "keeptestft",
            ("and keeps the earlier FileType autocmd: %s"):format(
                vim.inspect(found and cmds or nil, { newline = " ", indent = "" })
            )
        )
    end
    pcall(vim.api.nvim_del_augroup_by_name, "KiteHostAutoStart")
    -- Names of the accepted shape are taken: Neovim ships bicep-params,
    -- lsp_markdown and 8th, and a dot joins a compound filetype
    -- (c.doxygen).
    package.loaded["kitehost"] = nil
    local named = require("kitehost")
    local took, took_err = pcall(named.setup, {
        notify = false,
        auto_start = { filetypes = { "html", "bicep-params", "lsp_markdown", "8th", "c.doxygen" } },
    })
    ok(took, "names of the accepted shape (letters, digits, _ . -) are taken: " .. tostring(took_err))
    pcall(vim.api.nvim_del_augroup_by_name, "KiteHostAutoStart")
    -- false is off, as for a section, and an empty list starts nothing:
    -- neither arms the FileType autocmd.
    for _, value in ipairs({ false, { filetypes = {} } }) do
        local shown = vim.inspect(value, { newline = " ", indent = "" })
        pcall(vim.api.nvim_del_augroup_by_name, "KiteHostAutoStart")
        package.loaded["kitehost"] = nil
        local configured = require("kitehost")
        local set, err = pcall(configured.setup, { notify = false, auto_start = value })
        ok(set, ("setup takes auto_start = %s: %s"):format(shown, tostring(err)))
        eq(
            vim.inspect(configured.opts.auto_start, { newline = " ", indent = "" }),
            shown,
            ("opts.auto_start is %s"):format(shown)
        )
        local listed, cmds = pcall(vim.api.nvim_get_autocmds, { group = "KiteHostAutoStart", event = "FileType" })
        ok(not listed or #cmds == 0, ("auto_start = %s arms no FileType autocmd"):format(shown))
    end
    -- The same probe sees one a listed filetype arms.
    package.loaded["kitehost"] = nil
    pcall(require("kitehost").setup, { notify = false, auto_start = { filetypes = { "livetestft" } } })
    local armed, cmds = pcall(vim.api.nvim_get_autocmds, { group = "KiteHostAutoStart", event = "FileType" })
    ok(armed and #cmds == 1, 'auto_start = { filetypes = { "livetestft" } } arms one FileType autocmd')
    pcall(vim.api.nvim_del_augroup_by_name, "KiteHostAutoStart")
    -- A later setup that arms nothing kept the earlier autocmd, which then
    -- started servers or raised on a false auto_start, so the group is not
    -- deleted between the two calls here: the sequence is what is checked.
    local function file_types()
        local found, list = pcall(vim.api.nvim_get_autocmds, { group = "KiteHostAutoStart", event = "FileType" })
        local patterns = {}
        for _, cmd in ipairs(found and list or {}) do
            table.insert(patterns, cmd.pattern)
        end
        table.sort(patterns)
        return table.concat(patterns, ",")
    end
    for _, c in ipairs({
        { false, "" },
        { { filetypes = {} }, "" },
        { { filetypes = { "othertestft" } }, "othertestft" },
    }) do
        local later = vim.inspect(c[1], { newline = " ", indent = "" })
        package.loaded["kitehost"] = nil
        local configured = require("kitehost")
        configured.setup({ notify = false, auto_start = { filetypes = { "livetestft" } } })
        eq(file_types(), "livetestft", "the first setup arms livetestft before auto_start = " .. later)
        local set, err = pcall(configured.setup, { notify = false, auto_start = c[1] })
        ok(set, ("a later setup takes auto_start = %s: %s"):format(later, tostring(err)))
        eq(file_types(), c[2], ("a later auto_start = %s leaves the FileType autocmds it arms, only"):format(later))
    end
    pcall(vim.api.nvim_del_augroup_by_name, "KiteHostAutoStart")
    package.loaded["kitehost"] = nil
    local flags = require("kitehost")
    local set, err = pcall(flags.setup, {
        notify = false,
        notify_on_reload = true,
        open_on_start = false,
        serve_dotfiles = true,
        auto_start = { filetypes = {} },
        live_reload = { enabled = false, inject_script = false, css_inject = false },
        directory_listing = { enabled = false, show_hidden = true },
    })
    ok(set, "every flag given as a boolean is taken: " .. tostring(err))
    -- A key setup does not read was merged and never read, so a misspelled
    -- token or protected_paths started every server with nothing gated.
    for _, c in ipairs({
        { { tokn = "abc" }, "tokn" },
        { { protected_path = { "^/secret" } }, "protected_path" },
        { { live_reload = { debounc = 50 } }, "live_reload.debounc" },
        { { directory_listing = { show_hiden = true } }, "directory_listing.show_hiden" },
        { { auto_start = { filetype = { "html" } } }, "auto_start.filetype" },
    }) do
        local shown = vim.inspect(c[1], { newline = " ", indent = "" })
        package.loaded["kitehost"] = nil
        local configured = require("kitehost")
        local refused, why = pcall(configured.setup, vim.tbl_extend("force", { default_port = 9000 }, c[1]))
        eq(
            not refused and tostring(why) or "setup took it",
            "setup does not read the key " .. c[2],
            ("setup refuses %s, naming the key"):format(shown)
        )
        eq(configured.opts.default_port, 8000, ("and a refused %s keeps every option it had"):format(shown))
    end
    pcall(vim.api.nvim_del_augroup_by_name, "KiteHostAutoStart")
    package.loaded["kitehost"] = nil
    local every = require("kitehost")
    set, err = pcall(every.setup, {
        default_port = 9000,
        host = "127.0.0.1",
        open_on_start = false,
        notify = false,
        notify_on_reload = false,
        headers = { ["X-Custom"] = "1" },
        cors = false,
        index_names = { "index.html" },
        auto_start = { filetypes = {}, port = 9001 },
        token = "abc",
        protected_paths = { "^/secret" },
        allowed_hosts = { "dev.test" },
        serve_dotfiles = false,
        live_reload = { enabled = true, inject_script = true, debounce = 50, css_inject = true },
        directory_listing = { enabled = true, show_hidden = false },
    })
    ok(set, "every key setup reads is taken: " .. tostring(err))
    pcall(vim.api.nvim_del_augroup_by_name, "KiteHostAutoStart")
end)

-- The refusal of a key setup does not read rests on SETUP_KEYS, a list
-- kept by hand: an entry nothing reads took that key without a word, and
-- a read with no entry refused a key setup reads. The keys setup reads
-- are the module's, read as the documentation suite reads them: each key
-- of the defaults table (one whose default is nil included) and each
-- field of a section default whose keys are all names, then every
-- M.opts.<key> and M.opts.<key>.<field> the source spells, with the
-- comments and the strings left out, so a word there is no read.
H.case("Section 7b: SETUP_KEYS names every key setup reads, and no other", function()
    local code = H.code_only(table.concat(vim.fn.readfile(H.root .. "/lua/kitehost/init.lua"), "\n") .. "\n")
    local function literal(name)
        local text = code:match("\nlocal " .. name .. " = (%b{})")
        ok(text ~= nil, ("init.lua holds %s"):format(name))
        return text or "{}", assert(loadstring("return " .. (text or "{}")))()
    end
    local listed = {}
    local function flatten(t, prefix)
        for k, v in pairs(t) do
            listed[prefix .. k] = true
            if type(v) == "table" then
                flatten(v, prefix .. k .. ".")
            end
        end
    end
    flatten(select(2, literal("SETUP_KEYS")), "")
    local read = {}
    local text, defaults = literal("defaults")
    for k in text:gmatch("\n    ([%a_][%w_]*) = ") do
        read[k] = true
    end
    for k, v in pairs(defaults) do
        local names = type(v) == "table" and not vim.islist(v) and next(v) ~= nil
        for f in pairs(type(v) == "table" and v or {}) do
            names = names and type(f) == "string" and f:find("^[%a_][%w_]*$") ~= nil
        end
        for f in pairs(names and v or {}) do
            read[k .. "." .. f] = true
        end
    end
    for k in code:gmatch("M%.opts%.([%a_][%w_]*)") do
        read[k] = true
    end
    for k, f in code:gmatch("M%.opts%.([%a_][%w_]*)%.([%a_][%w_]*)") do
        read[k .. "." .. f] = true
    end
    local unread, unlisted = {}, {}
    for key in pairs(listed) do
        if not read[key] then
            table.insert(unread, key)
        end
    end
    for key in pairs(read) do
        if not listed[key] then
            table.insert(unlisted, key)
        end
    end
    table.sort(unread)
    table.sort(unlisted)
    ok(read.auto_start and read["auto_start.port"] and read.notify, "the reads were found in the source")
    eq(table.concat(unread, ", "), "", "every SETUP_KEYS entry is a key setup reads")
    eq(table.concat(unlisted, ", "), "", "every key setup reads has a SETUP_KEYS entry")
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
    -- The suite's picker, not the real one, so a later section still runs.
    local suite_pick_path = util.pick_path
    H.defer(function()
        vim.notify, vim.uv.fs_realpath, util.pick_path, picked_port = suite_notify, real_realpath, suite_pick_path, 0
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
    local ls = require("kitehost")
    local called, err = pcall(ls.start_picker)
    vim.uv.fs_realpath = real_realpath
    ok(called, "a retarget the server refuses raises nothing to the caller: " .. tostring(err))
    eq(#notes, 1, "and prints one notice: " .. vim.inspect(notes, { newline = " ", indent = "" }))
    local note = notes[1] or {}
    eq(
        note.msg,
        ("kitehost: port %d could not retarget: update_target: root %s does not resolve (ENOENT)"):format(
            inst.port,
            unresolved
        ),
        "naming what failed, then the server's cause by its error's name"
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
    -- A retarget whose watcher could not start read as done, its live
    -- reload off unsaid, and a toggle that then failed said DISABLED alone.
    local real_new = vim.uv.new_fs_event
    H.defer(function()
        vim.uv.new_fs_event = real_new
    end)
    vim.uv.new_fs_event = function()
        return nil, "EMFILE: stubbed", "EMFILE"
    end
    -- A root named with ESC and U+202E reaches both notices marked. Windows
    -- refuses a name holding a byte 1 to 31 (E739, measured on the hosted
    -- runner), so there DEL stands for ESC: a name may hold it, and the
    -- notices mark it as they mark ESC.
    local control = is_win and "DEL" or "ESC"
    local third = H.tmpdir() .. (is_win and "/d\127[31m\226\128\174e" or "/d\27[31m\226\128\174e")
    assert(vim.fn.mkdir(third, "p") == 1)
    local shown = third:gsub("d[\27\127]%[31m\226\128\174e$", "d?[31m?e")
    notes, target = {}, third
    called, err = pcall(ls.start_picker)
    ok(called, "a retarget whose watcher cannot start raises nothing: " .. tostring(err))
    vim.wait(100)
    local said = notes[1] or {}
    eq(
        said.msg,
        ("kitehost: port %d retargeted to %s; live reload is off"):format(inst.port, shown),
        ("and says live reload is off, naming the port, the root marked (its %s and U+202E)"):format(control)
    )
    eq(said.level, vim.log.levels.WARN, "as a warning")
    local server_said = notes[2] or {}
    ok(
        #notes == 2 and server_said.msg:find("(EMFILE: stubbed); live reload is off", 1, true) ~= nil,
        "and the server's own warning, the one naming the cause, is the only other notice: "
            .. vim.inspect(notes, { newline = " ", indent = "" })
    )
    notes = {}
    called, err = pcall(ls.toggle_livereload)
    vim.uv.new_fs_event = real_new
    ok(called, "a toggle that cannot watch raises nothing: " .. tostring(err))
    vim.wait(100)
    said = notes[1] or {}
    eq(
        said.msg,
        ("kitehost: port %d live-reload DISABLED: could not watch %s (EMFILE: stubbed)"):format(inst.port, shown),
        "and its DISABLED line names the cause, the root marked"
    )
    eq(said.level, vim.log.levels.WARN, "as a warning")
    eq(#notes, 1, "and is the one notice")
end)

-- host = "::1" opened http://::1:<port>/, which no browser parses: the
-- colons read as the port.
H.case("Section 9: an IPv6 host is bracketed in the opened URL", function()
    -- open_existing reads the configured host, so these rows need no bind.
    H.defer(function()
        picked_port = 0
    end)
    for _, pair in ipairs({
        { "2001:db8::1", "http://[2001:db8::1]:8123/" },
        { "[::1]", "http://[::1]:8123/" },
        { "[2001:db8::1]", "http://[2001:db8::1]:8123/" },
        { "::ffff:127.0.0.1", "http://127.0.0.1:8123/" },
        { "::FFFF:10.0.0.7", "http://10.0.0.7:8123/" },
        -- A zone in a URL is a % that starts an escape, and an instance's
        -- host is the address it bound, the zone left out; a port with
        -- no instance is opened the same way.
        { "fe80::1%lo0", "http://[fe80::1]:8123/" },
        { "::1%1", "http://[::1]:8123/" },
        { "[fe80::1%lo0]", "http://[fe80::1]:8123/" },
    }) do
        package.loaded["kitehost"] = nil
        local ls = require("kitehost")
        ls.setup({ notify = false, host = pair[1] })
        opened, picked_port = {}, 8123
        ls.open_existing()
        picked_port = 0
        eq(opened[1], pair[2], ("a configured %s opens %s"):format(pair[1], pair[2]))
    end

    local probe = assert(vim.uv.new_tcp())
    local v6, v6_err = probe:bind("::1", 0)
    probe:close()
    if not v6 then
        H.skip("an IPv6 loopback bind opens http://[::1]:<port>/ (no IPv6 loopback here: " .. tostring(v6_err) .. ")")
        H.skip("an IPv6 wildcard bind opens http://[::1]:<port>/ (no IPv6 loopback here)")
        H.skip("the token follows the bracket (no IPv6 loopback here)")
        return
    end
    local _, url = start_with({ host = "::1" })
    ok(
        url ~= nil and url:match("^http://%[::1%]:%d+/$") ~= nil,
        "an IPv6 loopback bind opens http://[::1]:<port>/: " .. tostring(url)
    )
    _, url = start_with({ host = "::" })
    ok(
        url ~= nil and url:match("^http://%[::1%]:%d+/$") ~= nil,
        "an IPv6 wildcard bind opens http://[::1]:<port>/: " .. tostring(url)
    )
    _, url = start_with({ host = "::1", token = "a&b" })
    ok(
        url ~= nil and url:match("^http://%[::1%]:%d+/%?t=a%%26b$") ~= nil,
        "the token follows the bracket, encoded: " .. tostring(url)
    )
end)

-- The status list counted the instance's own client table, which the
-- documentation tells every caller to read through the public counter.
H.case("Section 10: the status list counts clients through the public counter", function()
    local _, _, inst = start_with({ notify = true })
    local real_count = server.connected_client_count
    H.defer(function()
        server.connected_client_count = real_count
    end)
    server.connected_client_count = function(s)
        return s == inst and 7 or real_count(s)
    end
    notices = {}
    require("kitehost").status()
    server.connected_client_count = real_count
    local shown = table.concat(notices, "\n")
    ok(shown:find("clients:7", 1, true) ~= nil, "the status list reads connected_client_count: " .. shown)
end)

-- The status command exists to print, and under notify = false it printed
-- nothing, whether a server ran or not: a user who asks for it gets it.
H.case("Section 11: :KiteHost status prints under notify = false", function()
    local _, _, inst = start_with({ notify = false })
    local ls = require("kitehost")
    notices = {}
    ls.status()
    local shown = table.concat(notices, "\n")
    ok(
        inst ~= nil and shown:find(("kitehost: status:\n  :%d "):format(inst.port), 1, true) ~= nil,
        "with a server running it lists the server: " .. shown
    )
    ls.stop_all()
    notices = {}
    ls.status()
    eq(table.concat(notices, "\n"), "kitehost: no running servers.", "with none it says so")
end)

-- The statusline names the plugin beside each port it serves, in order.
H.case("Section 11b: the statusline reads kitehost and each port", function()
    local _, _, inst = start_with({})
    local ls = require("kitehost")
    eq(ls.statusline(), ("[kitehost :%s]"):format(inst and inst.port), "one server: the name and its port")
    ls.start_picker()
    local ports = vim.tbl_keys(ls.state.servers)
    table.sort(ports)
    eq(#ports, 2, "a second start serves a second port")
    eq(ls.statusline(), "[kitehost :" .. table.concat(ports, ",:") .. "]", "two: each port, in order")
    ls.stop_all()
    eq(ls.statusline(), "", "none: an empty string")
end)

-- Every notice starts kitehost:, so :messages names the plugin that sent
-- it; these had no prefix before 2.0.0.
H.case("Section 11c: the toggle's and the pickers' notices read kitehost:", function()
    local _, _, inst = start_with({ notify = true })
    local ls = require("kitehost")
    H.defer(function()
        picked_port = 0
    end)
    picked_port = inst and inst.port or -1
    notices = {}
    ls.toggle_livereload()
    ls.toggle_livereload()
    eq(
        table.concat(notices, " | "),
        ("kitehost: port %d live-reload DISABLED | kitehost: port %d live-reload ENABLED"):format(
            picked_port,
            picked_port
        ),
        "a toggle off and on names the port"
    )
    -- The refusals are recorded here, apart from the suite's count of
    -- error notices, since one of them is an error by design.
    local notes = {}
    local suite_notify, real_select = vim.notify, vim.ui.select
    H.defer(function()
        vim.notify, vim.ui.select = suite_notify, real_select
    end)
    vim.notify = function(msg, level)
        table.insert(notes, ("%s (%s)"):format(msg, level))
    end
    local reached = false
    vim.ui.select = function(_, _, cb)
        cb("70000")
    end
    real_pick_port({ default = 8000 }, function()
        reached = true
    end)
    eq(
        table.concat(notes, " | "),
        ("kitehost: invalid port. (%d)"):format(vim.log.levels.ERROR),
        "a port out of range is refused"
    )
    ok(not reached, "and reaches no caller")
    vim.cmd("enew")
    vim.ui.select = function(_, _, cb)
        cb("Current file")
    end
    notes = {}
    real_pick_path(function()
        reached = true
    end)
    eq(
        table.concat(notes, " | "),
        ("kitehost: no current file. (%d)"):format(vim.log.levels.WARN),
        "the current file of a nameless buffer is refused"
    )
    ok(not reached, "and reaches no caller")
end)

-- A refused auto-start sent its error notice inside the FileType autocmd,
-- where Neovim raises one out of the :edit that fired it (Vim(append)): a
-- picker's or a plugin's vim.cmd.edit failed with a traceback, and the
-- buffer's later FileType autocmds never ran. The stub raises an error
-- notice sent while the edit runs, as Neovim does, and records the rest.
-- Each notice the auto-start can send is driven: a refused start (a port
-- held, a port start refuses), a file not yet on disk and a retarget the
-- server refuses (stubbed, since no real directory both resolves for the
-- autocmd and fails the retarget).
H.case("Section 12: no auto-start notice raises out of the edit", function()
    local held = assert(vim.uv.new_tcp())
    H.defer(function()
        held:close()
    end)
    assert(held:bind("127.0.0.1", 0))
    assert(held:listen(1, function() end))
    local held_port = assert(held:getsockname()).port
    vim.cmd("filetype on")
    vim.filetype.add({ extension = { lsautoft = "lsautoft" } })
    local suite_notify = vim.notify
    H.defer(function()
        vim.notify = suite_notify
        pcall(vim.api.nvim_del_augroup_by_name, "KiteHostAutoStart")
        pcall(vim.api.nvim_del_augroup_by_name, "KiteHostLaterFileType")
    end)
    local editing, during, after = false, {}, {}
    vim.notify = function(msg, level)
        if editing then
            table.insert(during, msg)
            if level == vim.log.levels.ERROR then
                error(msg, 0)
            end
            return
        end
        table.insert(after, { msg = msg, level = level })
    end
    local dir, other = H.tmpdir(), H.tmpdir()
    local real_update = server.update_target
    H.defer(function()
        server.update_target = real_update
    end)
    -- { what the edit meets, the port auto_start names, whether the file
    -- is written first, the notice's start with the port in place of %s }
    local shapes = {
        {
            "a refused start",
            function()
                return held_port
            end,
            true,
            "^kitehost: port %s did not start: ",
        },
        {
            "a file not yet on disk",
            function()
                return held_port
            end,
            false,
            "^kitehost: path not found: ",
        },
        -- setup leaves auto_start's port to start, so the notice names
        -- whatever the config gave.
        {
            "a port start refuses",
            function()
                return "x"
            end,
            true,
            "^kitehost: port %s did not start: port must be an integer",
        },
        {
            "a refused retarget",
            function(ls)
                local inst = server.start({ port = 0, root = other, live = { enabled = false } })
                H.defer(function()
                    server.stop(inst)
                end)
                ls.state.servers[inst.port] = inst
                server.update_target = function()
                    error("update_target: stubbed", 0)
                end
                return inst.port
            end,
            true,
            "^kitehost: port %s could not retarget: update_target: stubbed$",
        },
    }
    for i, shape in ipairs(shapes) do
        for _, notify in ipairs({ false, true }) do
            package.loaded["kitehost"] = nil
            local ls = require("kitehost")
            ls.setup({
                notify = notify,
                open_on_start = false,
                auto_start = { filetypes = { "lsautoft" }, port = 0 },
            })
            local port = shape[2](ls)
            ls.opts.auto_start.port = port
            local later = 0
            vim.api.nvim_create_autocmd("FileType", {
                group = vim.api.nvim_create_augroup("KiteHostLaterFileType", { clear = true }),
                pattern = "lsautoft",
                callback = function()
                    later = later + 1
                end,
            })
            local page = ("%s/page%d%s.lsautoft"):format(dir, i, notify and "on" or "off")
            if shape[3] then
                H.write_file(page, "x")
            end
            during, after = {}, {}
            editing = true
            local edited, edit_err = pcall(vim.cmd.edit, page)
            editing = false
            server.update_target = real_update
            local label = ("on %s under notify = %s"):format(shape[1], tostring(notify))
            ok(edited, ("the edit is left whole %s: %s"):format(label, tostring(edit_err):match("^[^\n]*")))
            eq(later, 1, "and the buffer's later FileType autocmd runs " .. label)
            eq(#during, 0, "no notice is sent while the edit runs " .. label .. ": " .. table.concat(during, " | "))
            H.wait_for(function()
                return #after > 0
            end, 1000)
            local note = after[1] or {}
            ok(
                note.msg ~= nil and note.msg:find(shape[4]:format(tostring(port))) ~= nil and #after == 1,
                ("the notice is sent once the edit is done %s: %s"):format(
                    label,
                    vim.inspect(after, { newline = " ", indent = "" })
                )
            )
            eq(note.level, vim.log.levels.ERROR, "as an error " .. label)
            vim.cmd("bwipeout!")
        end
    end
end)

-- A notifier may forward a notice to a terminal or a desktop, where a
-- control byte in a directory's name acts and a bidi control reorders
-- the line; the start, retarget and status notices sent the root raw, and
-- a refused start the server's text, which repeats the root raw.
H.case("Section 13: every notice naming a root shows its controls as ?", function()
    local base = H.tmpdir()
    -- Windows refuses a name holding a byte 1 to 31 (E739, measured on the
    -- hosted runner), so there DEL and U+009B stand for ESC and BEL: a name
    -- may hold both, and the notices mark them as they mark ESC and BEL.
    local controls = is_win and "DEL, U+009B" or "ESC, BEL"
    local named = base .. (is_win and "/d\127]0;x\194\155\226\128\174e" or "/d\27]0;x\7\226\128\174e")
    assert(vim.fn.mkdir(named, "p") == 1)
    local other = base .. (is_win and "/o\127\194\155\226\128\174p" or "/o\27\7\226\128\174p")
    assert(vim.fn.mkdir(other, "p") == 1)
    local shown = base .. "/d?]0;x??e"
    local other_shown = base .. "/o???p"
    local notes = {}
    local suite_notify, suite_pick_path = vim.notify, util.pick_path
    local real_realpath = vim.uv.fs_realpath
    H.defer(function()
        vim.notify, util.pick_path, picked_port = suite_notify, suite_pick_path, 0
        vim.uv.fs_realpath = real_realpath
    end)
    vim.notify = function(msg, level)
        table.insert(notes, { msg = msg, level = level })
    end
    local target = named
    util.pick_path = function(cb)
        cb(target)
    end
    package.loaded["kitehost"] = nil
    local ls = require("kitehost")
    ls.setup({ notify = true, open_on_start = false })
    H.defer(function()
        ls.stop_all()
    end)
    ls.start_picker()
    local port = next(ls.state.servers)
    local said = notes[1] and notes[1].msg or ""
    eq(
        said:match("^(.-) at "),
        ("kitehost: port %s started → %s"):format(tostring(port), shown),
        ("the start notice shows the root's controls (%s and U+202E) as ?"):format(controls)
    )
    notes, target, picked_port = {}, other, port or 0
    ls.start_picker()
    picked_port = 0
    eq(
        notes[1] and notes[1].msg,
        ("kitehost: port %s retargeted → %s"):format(tostring(port), other_shown),
        "the retarget notice shows them as ?"
    )
    notes = {}
    ls.status()
    local listed = notes[1] and notes[1].msg or ""
    ok(
        listed:find(("\n  :%s → %s  [live:"):format(tostring(port), other_shown), 1, true) ~= nil
            and not listed:find("[\1-\9\11-\31\127]")
            and not listed:find("\194[\128-\159]"),
        "the status list shows them as ?, its line breaks kept: " .. vim.inspect(listed)
    )
    ls.stop_all()
    -- The server refuses a root it cannot resolve, naming the root raw.
    vim.uv.fs_realpath = function(path, ...)
        if path == named then
            return nil, "ENOENT: stubbed", "ENOENT"
        end
        return real_realpath(path, ...)
    end
    notes, target = {}, named
    ls.start_picker()
    vim.uv.fs_realpath = real_realpath
    eq(
        notes[1] and notes[1].msg,
        ("kitehost: port 0 did not start: root %s does not resolve (ENOENT)"):format(shown),
        "a refused start shows the server's text with them as ?"
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
