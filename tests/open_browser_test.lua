-- tests/open_browser_test.lua
-- util.open_browser against a vim.ui.open that finds no opener: it answers
-- nil and a message without raising, which the fallback must read, and
-- whose notice shows the URL without the token's value. The platform
-- opener and the notifier are stubbed, so no browser starts.
--
-- Run: nvim --headless -u NONE -l "$PWD/tests/open_browser_test.lua"

local H = dofile(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "helpers.lua"))
H.isolate()
H.rtp()

local util = require("kitehost.util")
local eq, ok = H.eq, H.ok

local URL = "http://127.0.0.1:8123/"
local opener = vim.fn.has("win32") == 1 and "cmd.exe" or (vim.fn.has("mac") == 1 and "open" or "xdg-open")
local real_open, real_jobstart, real_notify = vim.ui.open, vim.fn.jobstart, vim.notify

-- One call of open_browser with vim.ui.open answering ui_result (a table of
-- its return values) and jobstart answering job (a string raises it, as the
-- real jobstart raises E475 for an opener that is not executable, and when
-- exit is set on_exit is called with it); returns the jobstart calls and the
-- notices. run opens the browser, util.open_browser(URL) unless given.
local function attempt(ui_result, job, exit, run)
    local calls, notices = {}, {}
    vim.ui.open = function()
        return unpack(ui_result)
    end
    vim.fn.jobstart = function(argv, opts)
        calls[#calls + 1] = argv
        if type(job) == "string" then
            error(job)
        end
        if exit ~= nil and job > 0 then
            opts.on_exit(job, exit)
        end
        return job
    end
    vim.notify = function(msg, level)
        notices[#notices + 1] = { msg = msg, level = level }
    end
    if run then
        run()
    else
        util.open_browser(URL)
    end
    vim.wait(200, function()
        return #calls > 0 and (exit == nil or #notices > 0 or exit == 0)
    end)
    vim.wait(20, function()
        return false
    end)
    vim.ui.open, vim.fn.jobstart, vim.notify = real_open, real_jobstart, real_notify
    return calls, notices
end

H.section("Section 1: no opener found, the platform's opener starts")
local calls, notices = attempt({ nil, "vim.ui.open: no handler found" }, 7, 0)
eq(#calls, 1, "the fallback starts one job")
ok(
    calls[1] ~= nil and calls[1][1] == opener and calls[1][#calls[1]] == URL,
    ("the job is %s with the URL: %s"):format(opener, vim.inspect(calls[1]))
)
eq(#notices, 0, "a fallback that starts and exits 0 shows no notice")

H.section("Section 2: the fallback fails, the URL is shown")
calls, notices = attempt({ nil, "vim.ui.open: no handler found" }, -1)
eq(#calls, 1, "the fallback was tried")
ok(
    #notices == 1 and notices[1].msg:find(URL, 1, true) ~= nil and notices[1].level == vim.log.levels.WARN,
    "an opener that cannot start shows the URL to open by hand: " .. vim.inspect(notices)
)
calls, notices = attempt({ nil, "vim.ui.open: no handler found" }, 7, 3)
ok(
    #notices == 1 and notices[1].msg:find(URL, 1, true) ~= nil,
    "an opener that exits nonzero shows the URL to open by hand: " .. vim.inspect(notices)
)
calls, notices = attempt(
    { nil, "vim.ui.open: no handler found" },
    ("Vim:E475: Invalid value for argument cmd: '%s' is not executable"):format(opener)
)
ok(
    #notices == 1 and notices[1].msg:find(URL, 1, true) ~= nil,
    "an opener jobstart refuses as not executable shows the URL to open by hand: " .. vim.inspect(notices)
)

H.section("Section 3: vim.ui.open found an opener")
calls, notices = attempt({ {} }, 7, 0)
eq(#calls, 0, "no fallback runs when vim.ui.open returns a handle")
eq(#notices, 0, "no notice when vim.ui.open returns a handle")

-- The fallback warns whatever notify says, so it carried the token into
-- :messages for a user who set notify = false to keep it out of there. It
-- names where the server is and leaves the token's value out.
H.section("Section 4: the fallback's notice never shows the token")
calls, notices = attempt({ nil, "vim.ui.open: no handler found" }, -1, nil, function()
    util.open_browser("http://127.0.0.1:8123/?t=SECRET-TOKEN")
end)
eq(
    #notices == 1 and notices[1].msg or vim.inspect(notices),
    "Could not open a browser; open http://127.0.0.1:8123/?t=... by hand",
    "a token URL is shown with the token's value left out"
)
local root = H.tmpdir()
H.write_file(root .. "/index.html", "<html><body>ok</body></html>")
local ls = require("kitehost")
local real_pick_path, real_pick_port = util.pick_path, util.pick_port
H.defer(function()
    util.pick_path, util.pick_port = real_pick_path, real_pick_port
    ls.stop_all()
end)
util.pick_path = function(cb)
    cb(root)
end
util.pick_port = function(_, cb)
    cb(0)
end
ls.setup({ notify = false, token = "SECRET-TOKEN", open_on_start = true })
calls, notices = attempt({ nil, "vim.ui.open: no handler found" }, -1, nil, ls.start_picker)
local port
for p in pairs(ls.state.servers) do
    port = p
end
local shown = table.concat(
    vim.tbl_map(function(n)
        return n.msg
    end, notices),
    " | "
)
eq(
    shown,
    ("Could not open a browser; open http://127.0.0.1:%s/?t=... by hand"):format(tostring(port)),
    "setup with notify = false and a token: the one notice holds the URL"
)
ok(not shown:find("SECRET-TOKEN", 1, true), "and never the token: " .. shown)

H.finish()
