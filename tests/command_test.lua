-- tests/command_test.lua
-- :KiteHost on a supported Neovim: each subcommand runs the module function
-- its former command ran, a bare :KiteHost runs start, completion lists the
-- subcommands and then each one's arguments (none takes any), and an
-- unknown subcommand or an argument is one error notice, sent once the
-- command has returned. Each command before 2.0.0 runs its subcommand after
-- one warning a session. The module's functions are spies, so no picker
-- opens; one use of each kind runs the real status. Below the floor the
-- commands are floor_guard_test's. A suite of its own, since a warning shows
-- once a session: no earlier use may have sent it.
--
-- Run: nvim --headless -u NONE -l "$PWD/tests/command_test.lua"

local H = dofile(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "helpers.lua"))
H.isolate()
H.rtp()

local eq, ok = H.eq, H.ok

-- The subcommands in the order the README lists them, each with the module
-- function it runs and the command it replaced.
local SUBCOMMANDS = {
    { "start", "start_picker", "LiveServerStart" },
    { "stop", "stop_one", "LiveServerStop" },
    { "stop-all", "stop_all", "LiveServerStopAll" },
    { "open", "open_existing", "LiveServerOpen" },
    { "reload", "force_reload", "LiveServerReload" },
    { "status", "status", "LiveServerStatus" },
    { "toggle-live", "toggle_livereload", "LiveServerToggleLive" },
}
local KNOWN = "start, stop, stop-all, open, reload, status, toggle-live"

local notices = {}
local real_notify = vim.notify
H.defer(function()
    vim.notify = real_notify
end)
vim.notify = function(msg, level)
    table.insert(notices, { msg = msg, level = level })
end

local sourced, source_err = pcall(vim.cmd, "runtime plugin/kitehost.lua")
ok(sourced, "the plugin file sources: " .. tostring(source_err))
local kitehost = require("kitehost")
-- stop_all notifies at exit, after the ruling and with no newline, where
-- its line fuses with the runner's next one, as floor_guard_test says.
H.defer(function()
    pcall(vim.api.nvim_clear_autocmds, { group = "KiteHostExit" })
end)

-- Every module function a subcommand runs is a spy recording its name.
local ran = {}
local real = {}
for _, sub in ipairs(SUBCOMMANDS) do
    local fn = sub[2]
    real[fn] = kitehost[fn]
    kitehost[fn] = function()
        table.insert(ran, fn)
    end
end
H.defer(function()
    for fn, f in pairs(real) do
        kitehost[fn] = f
    end
end)

local function turn_loop()
    vim.wait(50, function()
        return false
    end)
end

-- One use of a command: what it ran and what it sent, after the loop turns.
local function use(cmdline)
    ran, notices = {}, {}
    local done, err = pcall(vim.cmd, cmdline)
    local before_loop = #notices
    turn_loop()
    return done and "" or tostring(err), table.concat(ran, ", "), before_loop
end

H.case("Section 1: each subcommand runs its former command's function", function()
    for _, sub in ipairs(SUBCOMMANDS) do
        local err, did = use("KiteHost " .. sub[1])
        eq(err, "", (":KiteHost %s raises nothing"):format(sub[1]))
        eq(did, sub[2], (":KiteHost %s runs %s alone"):format(sub[1], sub[2]))
        eq(#notices, 0, (":KiteHost %s sends nothing of its own"):format(sub[1]))
    end
    local err, did = use("KiteHost")
    eq(err .. did, "start_picker", "a bare :KiteHost runs start")
end)

H.case("Section 2: completion lists the subcommands, then their arguments", function()
    eq(table.concat(vim.fn.getcompletion("KiteHost ", "cmdline"), ", "), KNOWN, "every subcommand, in order")
    eq(
        table.concat(vim.fn.getcompletion("KiteHost st", "cmdline"), ", "),
        "start, stop, stop-all, status",
        "the subcommands the typed text begins"
    )
    eq(table.concat(vim.fn.getcompletion("KiteHost t", "cmdline"), ", "), "toggle-live", "one subcommand by its start")
    eq(table.concat(vim.fn.getcompletion("KiteHost x", "cmdline"), ", "), "", "none for a start no subcommand has")
    for _, sub in ipairs(SUBCOMMANDS) do
        eq(
            table.concat(vim.fn.getcompletion("KiteHost " .. sub[1] .. " ", "cmdline"), ", "),
            "",
            (":KiteHost %s completes no argument, as it takes none"):format(sub[1])
        )
    end
end)

-- An ERROR notification sent while the command runs raises out of the
-- vim.cmd that ran it (lazy.nvim's cmd handler among them), so each refusal
-- is sent once the command has returned.
H.case("Section 3: an unknown subcommand or an argument is one error notice", function()
    for _, case in ipairs({
        { "KiteHost bogus", "kitehost: no subcommand bogus; the subcommands are " .. KNOWN },
        { "KiteHost Start", "kitehost: no subcommand Start; the subcommands are " .. KNOWN },
        { "KiteHost start now", "kitehost: start takes no arguments" },
        { "KiteHost status a b", "kitehost: status takes no arguments" },
    }) do
        local err, did, before_loop = use(case[1])
        eq(err, "", (":%s raises nothing"):format(case[1]))
        eq(did, "", (":%s runs nothing"):format(case[1]))
        eq(before_loop, 0, (":%s sends nothing while it runs"):format(case[1]))
        eq(#notices, 1, (":%s sends one notice"):format(case[1]))
        eq(notices[1] and notices[1].msg, case[2], (":%s names what it takes"):format(case[1]))
        eq(notices[1] and notices[1].level, vim.log.levels.ERROR, (":%s's notice is an error"):format(case[1]))
    end
    -- What was typed is shown with its controls as ?, as a root is.
    use("KiteHost a\27[31mb")
    eq(
        notices[1] and notices[1].msg,
        "kitehost: no subcommand a?[31mb; the subcommands are " .. KNOWN,
        "a control in the typed name is shown as ?"
    )
end)

H.case("Section 4: each former command runs its subcommand after one warning", function()
    for _, sub in ipairs(SUBCOMMANDS) do
        local err, did = use(sub[3])
        eq(err, "", (":%s raises nothing"):format(sub[3]))
        eq(did, sub[2], (":%s runs %s, as :KiteHost %s does"):format(sub[3], sub[2], sub[1]))
        eq(#notices, 1, (":%s sends one notice"):format(sub[3]))
        eq(
            notices[1] and notices[1].msg,
            (":%s is deprecated, use :KiteHost %s instead.\nFeature will be removed in kitehost.nvim 3.0.0"):format(
                sub[3],
                sub[1]
            ),
            (":%s's notice names the plugin and the subcommand"):format(sub[3])
        )
        eq(notices[1] and notices[1].level, vim.log.levels.WARN, (":%s's notice is a warning"):format(sub[3]))
        err, did = use(sub[3])
        eq(err .. did, sub[2], (":%s runs again"):format(sub[3]))
        eq(#notices, 0, (":%s warns once a session"):format(sub[3]))
    end
    -- As before 2.0.0, a former command takes no argument.
    local err = use("LiveServerStart now")
    ok(err:find("E488", 1, true) ~= nil, ":LiveServerStart refuses an argument, as it did: " .. err)
end)

H.case("Section 5: the subcommand and the former command run the real function", function()
    kitehost.status = real.status
    local err, _ = use("KiteHost status")
    eq(err, "", ":KiteHost status raises nothing")
    eq(notices[1] and notices[1].msg, "No running servers.", ":KiteHost status prints the status")
    use("LiveServerStatus")
    eq(notices[1] and notices[1].msg, "No running servers.", ":LiveServerStatus prints it too")
end)

H.finish()
