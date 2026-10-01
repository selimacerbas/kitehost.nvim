-- The entry module's name before 2.0.0, kept through 2.x as the very table
-- require("kitehost") returns, so a server started through either name is
-- in the one registry. Below the floor it sends no warning, so the floor
-- notice is all a user sees. lazy.nvim reads a spec still naming
-- live-server.nvim as this module's plugin and calls its setup, so the
-- warning names the repository as well as the module.
local M = require("kitehost")
if require("kitehost.floor").ok then
    require("kitehost.util").deprecated('require("live_server")', 'require("kitehost") from selimacerbas/kitehost.nvim')
end
return M
