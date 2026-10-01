-- kitehost.nvim needs Neovim 0.10: vim.uv (the test runner needs it too).
-- Below the floor every documented command is still defined, as a refuser,
-- so a lazy.nvim cmd or keys spec finds its command and each use says why,
-- and one notification says it at load. Both wait for the loop: lazy.nvim
-- sources this file with :source and runs a cmd spec's command through
-- vim.cmd, where an ERROR notification on 0.9 raised Vim(source) or a
-- traceback through lazy's handler (measured).
local floor = require("kitehost.floor")

-- :KiteHost's subcommands, each with the module function it runs and the
-- command it replaced, which runs it through 2.x.
local SUBCOMMANDS = {
    { name = "start", run = "start_picker", former = "LiveServerStart" },
    { name = "stop", run = "stop_one", former = "LiveServerStop" },
    { name = "stop-all", run = "stop_all", former = "LiveServerStopAll" },
    { name = "open", run = "open_existing", former = "LiveServerOpen" },
    { name = "reload", run = "force_reload", former = "LiveServerReload" },
    { name = "status", run = "status", former = "LiveServerStatus" },
    { name = "toggle-live", run = "toggle_livereload", former = "LiveServerToggleLive" },
}

if not floor.ok then
    local function refuse()
        vim.schedule(function()
            vim.notify(floor.message, vim.log.levels.ERROR)
        end)
    end
    -- Lua user commands and notify_once arrived in 0.7, and this file is
    -- sourced from 0.5 on, where the notification at load is all there is.
    if vim.api.nvim_create_user_command then
        -- Any arguments, so a subcommand is refused with the floor text
        -- rather than with E488.
        vim.api.nvim_create_user_command("KiteHost", refuse, { nargs = "*", desc = "kitehost: requires Neovim 0.10" })
        for _, sub in ipairs(SUBCOMMANDS) do
            vim.api.nvim_create_user_command(sub.former, refuse, { desc = "kitehost: requires Neovim 0.10" })
        end
    end
    vim.schedule(function()
        local notify = vim.notify_once or vim.notify
        notify(floor.message, vim.log.levels.ERROR)
    end)
    return
end

local KH = require("kitehost")
local util = require("kitehost.util")

local NAMES = {}
for _, sub in ipairs(SUBCOMMANDS) do
    table.insert(NAMES, sub.name)
end

-- An ERROR notification sent while a command runs raises out of the vim.cmd
-- that ran it, lazy.nvim's cmd handler among them (measured on 0.10.0 and
-- 0.12.5), so a refusal waits for the loop. What was typed is marked, as a
-- root is.
local function refuse(text)
    vim.schedule(function()
        util.notify(util.marked(text), KH.opts, "ERROR")
    end)
end

-- The module's function is read at each use, as each command read it.
local function run(name, extra)
    for _, sub in ipairs(SUBCOMMANDS) do
        if sub.name == name then
            if extra then
                return refuse(("kitehost: %s takes no arguments"):format(name))
            end
            return KH[sub.run]()
        end
    end
    refuse(("kitehost: no subcommand %s; the subcommands are %s"):format(name, table.concat(NAMES, ", ")))
end

vim.api.nvim_create_user_command("KiteHost", function(args)
    run(args.fargs[1] or "start", args.fargs[2])
end, {
    nargs = "*",
    desc = "kitehost: " .. table.concat(NAMES, ", "),
    -- The subcommands, then a subcommand's arguments, of which none takes
    -- any. Neovim shows a Lua function's list unfiltered (measured), so
    -- the names are filtered by what was typed.
    complete = function(lead, line, pos)
        local after = line:sub(1, pos):match("^%s*%S+%s+(.*)$") or ""
        if after:find("%s") then
            return {}
        end
        return vim.tbl_filter(function(name)
            return vim.startswith(name, lead)
        end, NAMES)
    end,
})

for _, sub in ipairs(SUBCOMMANDS) do
    vim.api.nvim_create_user_command(sub.former, function()
        util.deprecated(":" .. sub.former, ":KiteHost " .. sub.name)
        run(sub.name)
    end, { desc = "kitehost: deprecated, :KiteHost " .. sub.name })
end

vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("KiteHostExit", { clear = true }),
    callback = function()
        KH.stop_all()
    end,
    desc = "kitehost: stop all servers on exit",
})
