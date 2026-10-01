-- live-server.nvim needs Neovim 0.10: vim.uv (the test runner needs it too).
-- Below the floor every documented command is still defined, as a refuser,
-- so a lazy.nvim cmd or keys spec finds its command and each use says why,
-- and one notification says it at load. Both wait for the loop: lazy.nvim
-- sources this file with :source and runs a cmd spec's command through
-- vim.cmd, where an ERROR notification on 0.9 raised Vim(source) or a
-- traceback through lazy's handler (measured).
local floor = require("kitehost.floor")
if not floor.ok then
    local function refuse()
        vim.schedule(function()
            vim.notify(floor.message, vim.log.levels.ERROR)
        end)
    end
    -- Lua user commands and notify_once arrived in 0.7, and this file is
    -- sourced from 0.5 on, where the notification at load is all there is.
    if vim.api.nvim_create_user_command then
        for _, name in ipairs({
            "LiveServerStart",
            "LiveServerOpen",
            "LiveServerReload",
            "LiveServerToggleLive",
            "LiveServerStatus",
            "LiveServerStop",
            "LiveServerStopAll",
        }) do
            vim.api.nvim_create_user_command(name, refuse, { desc = "LiveServer: requires Neovim 0.10" })
        end
    end
    vim.schedule(function()
        local notify = vim.notify_once or vim.notify
        notify(floor.message, vim.log.levels.ERROR)
    end)
    return
end

local LS = require("kitehost")

vim.api.nvim_create_user_command("LiveServerStart", function()
    LS.start_picker()
end, { desc = "LiveServer: start (pick path & port)" })

vim.api.nvim_create_user_command("LiveServerOpen", function()
    LS.open_existing()
end, { desc = "LiveServer: open existing server (pick port)" })

vim.api.nvim_create_user_command("LiveServerReload", function()
    LS.force_reload()
end, { desc = "LiveServer: force reload clients (pick port)" })

vim.api.nvim_create_user_command("LiveServerToggleLive", function()
    LS.toggle_livereload()
end, { desc = "LiveServer: toggle live-reload (pick port)" })

vim.api.nvim_create_user_command("LiveServerStop", function()
    LS.stop_one()
end, { desc = "LiveServer: stop one (pick port)" })

vim.api.nvim_create_user_command("LiveServerStatus", function()
    LS.status()
end, { desc = "LiveServer: show running servers" })

vim.api.nvim_create_user_command("LiveServerStopAll", function()
    LS.stop_all()
end, { desc = "LiveServer: stop all" })

vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("KiteHostExit", { clear = true }),
    callback = function()
        LS.stop_all()
    end,
    desc = "LiveServer: stop all servers on exit",
})
