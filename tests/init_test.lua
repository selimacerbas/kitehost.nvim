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
vim.notify = function(msg)
    table.insert(notices, msg)
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
        "a tokenless start notice keeps its shape: the port, the root, the opened URL"
    )
    ok(
        notes[1] ~= nil and notes[1]:find("?t=", 1, true) == nil,
        "a tokenless start notice holds no ?t=: " .. tostring(notes[1])
    )
end)

H.finish()
