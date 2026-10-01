-- tests/alias_test.lua
-- The module names before 2.0.0, kept through 2.x: each hands back the very
-- table its new name returns, so a server started through one name is
-- stopped through the other, and the first require of each warns once a
-- session, naming the plugin and the new module. The plugin's own modules
-- require the new names, so a start through them warns nothing. Below the
-- floor the former names are floor_guard_test's. A suite of its own, since
-- a warning shows once a session: no earlier require may have sent it.
--
-- Run: nvim --headless -u NONE -l "$PWD/tests/alias_test.lua"

local H = dofile(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "helpers.lua"))
H.isolate()
H.rtp()

local eq, ok = H.eq, H.ok

local notices = {}
local real_notify = vim.notify
H.defer(function()
    vim.notify = real_notify
end)
vim.notify = function(msg, level)
    table.insert(notices, { msg = msg, level = level })
end

-- vim.deprecate's text, the plugin named: the same on 0.10.0 and 0.12.5.
local function deprecation(old, new)
    return ("%s is deprecated, use %s instead.\nFeature will be removed in kitehost.nvim 3.0.0"):format(old, new)
end

local function former_loaded()
    local names = {}
    for name in pairs(package.loaded) do
        if name == "live_server" or vim.startswith(name, "live_server.") then
            table.insert(names, name)
        end
    end
    table.sort(names)
    return table.concat(names, ", ")
end

local root = H.tmpdir()
H.write_file(root .. "/index.html", "<html><body>ok</body></html>")
local kitehost = require("kitehost")
local util = require("kitehost.util")
local real_pick_path, real_pick_port, real_open = util.pick_path, util.pick_port, util.open_browser
H.defer(function()
    util.pick_path, util.pick_port, util.open_browser = real_pick_path, real_pick_port, real_open
    kitehost.stop_all()
end)
util.pick_path = function(cb)
    cb(root)
end
util.pick_port = function(_, cb)
    cb(0)
end
util.open_browser = function() end

-- The one server the entry module holds, and its count.
local function running(ls)
    local count, inst = 0, nil
    for _, s in pairs(ls.state.servers) do
        count, inst = count + 1, s
    end
    return count, inst
end

H.case("Section 1: the new names start a server and warn nothing", function()
    kitehost.setup({ notify = false, open_on_start = false })
    kitehost.start_picker()
    eq(running(kitehost), 1, 'a server started through require("kitehost")')
    kitehost.stop_all()
    eq(#notices, 0, "nothing was sent: " .. vim.inspect(notices))
    eq(former_loaded(), "", "no former name was loaded")
end)

H.case("Section 2: each former name is the very table, and warns once", function()
    for _, pair in ipairs({
        { "live_server", "kitehost", 'require("kitehost") from selimacerbas/kitehost.nvim' },
        { "live_server.server", "kitehost.server", 'require("kitehost.server")' },
        { "live_server.util", "kitehost.util", 'require("kitehost.util")' },
    }) do
        local old, new, alternative = pair[1], pair[2], pair[3]
        notices = {}
        local got = require(old)
        ok(rawequal(got, require(new)), ("require(%q) is require(%q)'s own table"):format(old, new))
        eq(#notices, 1, ("the first require(%q) sends one notice"):format(old))
        eq(
            notices[1] and notices[1].msg,
            deprecation(('require("%s")'):format(old), alternative),
            ("require(%q)'s notice names the plugin and the new module"):format(old)
        )
        eq(notices[1] and notices[1].level, vim.log.levels.WARN, ("require(%q)'s notice is a warning"):format(old))
        -- A cleared entry runs the alias again, which must not warn again.
        package.loaded[old] = nil
        ok(rawequal(require(old), require(new)), ("require(%q) again is the same table"):format(old))
        eq(#notices, 1, ("require(%q) warns once a session"):format(old))
    end
end)

H.case("Section 3: a server started through one name stops through the other", function()
    local former = require("live_server")
    notices = {}
    for _, way in ipairs({
        { former, kitehost, "live_server", "kitehost" },
        { kitehost, former, "kitehost", "live_server" },
    }) do
        local start_with, stop_with = way[1], way[2]
        start_with.setup({ notify = false, open_on_start = false })
        start_with.start_picker()
        local count, inst = running(stop_with)
        eq(count, 1, ("a server started through %s is in %s's registry"):format(way[3], way[4]))
        stop_with.stop_all()
        eq(running(start_with), 0, ("%s's stop_all empties %s's registry"):format(way[4], way[3]))
        ok(inst ~= nil and inst.handle:is_closing(), ("%s's stop_all closes the listener"):format(way[4]))
    end
    eq(#notices, 0, "a start and a stop through either name send nothing more")
end)

H.finish()
