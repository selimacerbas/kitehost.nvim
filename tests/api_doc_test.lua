-- tests/api_doc_test.lua
-- The README's plugin-author section is the public API SemVer covers:
-- every export and capability flag of the server module and every option
-- start reads is named there, so a new one cannot ship undeclared. Each
-- list is read from the modules as they run, never restated here.
--
-- Run: nvim --headless -u NONE -l "$PWD/tests/api_doc_test.lua"

local H = dofile(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "helpers.lua"))
H.isolate()
H.rtp()

local server = require("live_server.server")
local util = require("live_server.util")
local ok = H.ok

local readme = table.concat(vim.fn.readfile(H.root .. "/README.md"), "\n")
local section = readme:match("\n### Server%-level API %(for plugin authors%)\n(.-)\n### ") or ""

local function sorted_keys(t)
    local keys = vim.tbl_keys(t)
    table.sort(keys)
    return keys
end

H.case("every export of live_server.server is documented", function()
    ok(section ~= "", "the README has the plugin-author section")
    for _, name in ipairs(sorted_keys(server)) do
        local shown = type(server[name]) == "function" and ("server." .. name .. "(") or ("server." .. name)
        ok(section:find(shown, 1, true) ~= nil, ("server.%s is documented"):format(name))
    end
    ok(section:find("SemVer", 1, true) ~= nil, "the section says SemVer covers it")
end)

H.case("every capability flag is documented", function()
    ok(type(server.features) == "table" and next(server.features) ~= nil, "server.features holds flags")
    for _, flag in ipairs(sorted_keys(server.features)) do
        ok(section:find("`" .. flag .. "`", 1, true) ~= nil, ("features.%s is documented"):format(flag))
    end
end)

H.case("the two util functions a plugin calls are documented", function()
    for _, name in ipairs({ "random_token", "secure_compare" }) do
        ok(type(util[name]) == "function", ("util.%s exists"):format(name))
        ok(section:find("util." .. name .. "(", 1, true) ~= nil, ("util.%s is documented"):format(name))
    end
end)

-- The options are the keys start reads from its table, recorded through a
-- proxy, so a key start begins to read is a key this section must name. The
-- two nested tables are given so their own keys are read too.
H.case("every option start reads is documented", function()
    local root = H.tmpdir()
    local read = {}
    local function proxy(backing, prefix)
        return setmetatable({}, {
            __index = function(_, key)
                local value = backing[key]
                if type(value) == "table" then
                    return proxy(value, prefix .. key .. ".")
                end
                read[prefix .. key] = true
                return value
            end,
        })
    end
    local inst = server.start(proxy({
        port = 0,
        root = root,
        live = { enabled = false },
        features = { dirlist = {} },
    }, ""))
    H.defer(function()
        server.stop(inst)
    end)
    local keys = sorted_keys(read)
    ok(#keys > 0, "start reads its options through the table given")
    for _, key in ipairs(keys) do
        -- A nested key is named on its top-level key's line of the example.
        local parts = vim.split(key, ".", { plain = true })
        local line = section:match("\n  " .. vim.pesc(parts[1]) .. " = [^\n]*")
        local named = line ~= nil
        for i = 2, #parts do
            named = named and line:find(parts[i] .. " = ", 1, true) ~= nil
        end
        ok(named, ("start's %s is documented"):format(key))
    end
end)

H.finish()
