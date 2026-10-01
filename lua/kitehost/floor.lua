-- lua/kitehost/floor.lua
-- The one statement of the Neovim floor, read by the plugin file, the module
-- and the two submodules the plugin-author API loads. It loads on any Neovim
-- that sources a Lua plugin file (0.5 on), so it calls nothing newer. The
-- feature is tested beside the version: a 0.10.0-dev build from before
-- 2023-06-03 answers has("nvim-0.10") without vim.uv. The version goes
-- first, as in markdown-preview.nvim's floor module, where a feature test
-- indexes vim.fs, which Neovim before 0.8 lacks.
return {
    ok = vim.fn.has("nvim-0.10") == 1 and vim.uv ~= nil,
    message = "live-server.nvim requires Neovim 0.10 or newer; on Neovim 0.8 or 0.9 pin the plugin to v1.5.0",
}
