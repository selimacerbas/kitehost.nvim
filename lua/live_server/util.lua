-- The plugin-author module's name before 2.0.0, kept through 2.x as the
-- very table require("kitehost.util") returns. Below the floor that require
-- raises the floor text and clears this name's entry too, so every retry
-- raises it again and no warning is sent.
local U = require("kitehost.util")
U.deprecated('require("live_server.util")', 'require("kitehost.util")')
return U
