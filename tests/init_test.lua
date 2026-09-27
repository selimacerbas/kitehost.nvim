-- tests/init_test.lua
-- The setup() layer: the options it hands server.start and the URL it
-- opens. The pickers and the browser are stubbed, so a start runs with no
-- UI and the opened URL is recorded.
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

local opened, started, servers, raised = {}, {}, {}, {}
local real_start = server.start
local real_open, real_pick_path, real_pick_port = util.open_browser, util.pick_path, util.pick_port
-- Put back when H.finish drains, so no stub outlives the suite that set it.
H.defer(function()
    server.start = real_start
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
util.pick_port = function(_, cb)
    cb(0)
end

-- A fresh module per start: setup() merges onto the options it holds, so a
-- start would inherit the last one's token.
local function start_with(opts)
    package.loaded["live_server"] = nil
    local ls = require("live_server")
    ls.setup(vim.tbl_extend("force", { notify = false, open_on_start = true }, opts))
    opened, started, servers, raised = {}, {}, {}, {}
    ls.start_picker()
    H.defer(function()
        ls.stop_all()
    end)
    eq(
        table.concat(raised, "; "),
        "",
        ("server.start raised nothing for %s"):format(vim.inspect(opts, { newline = " ", indent = "" }))
    )
    return started[1], opened[1], servers[1]
end

H.case("Section 1: setup hands the security options to the server", function()
    local cfg = start_with({})
    eq(cfg and cfg.allowed_hosts, nil, "allowed_hosts defaults to nil")
    eq(cfg and cfg.serve_dotfiles, false, "serve_dotfiles defaults to false")
    cfg = start_with({ allowed_hosts = { "my.name" }, serve_dotfiles = true })
    eq(cfg and cfg.allowed_hosts and cfg.allowed_hosts[1], "my.name", "allowed_hosts reaches server.start")
    eq(cfg and cfg.serve_dotfiles, true, "serve_dotfiles reaches server.start")
end)

H.case("Section 2: setup opens the server it started", function()
    local _, url, inst = start_with({})
    eq(
        url,
        ("http://127.0.0.1:%d/"):format(inst and inst.port or -1),
        "the default start opens http://127.0.0.1:<port>/"
    )
end)

H.finish()
