-- tests/floor_guard_test.lua
-- Below Neovim 0.10 every documented command is a refuser that answers each
-- use with the floor module's text, the module answers a config's setup()
-- without loading the plugin (one ERROR notification at load between them)
-- and the modules the plugin-author API loads refuse at every require; on a
-- supported version the commands and the exit hook are defined.
--
-- Run: nvim --headless -u NONE -l "$PWD/tests/floor_guard_test.lua"
local H = dofile(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "helpers.lua"))
H.isolate()
H.rtp()
local plugin_file = H.root .. "/plugin/kitehost.lua"
-- The plugin's entry module, its name before 2.0.0 (an alias through 2.x),
-- the prefixes its commands share, the command's and the one before 2.0.0
-- (each such command runs a subcommand through 2.x), and the features its
-- floor module tests beside the version.
local MODULE = "kitehost"
local FORMER = "live_server"
local COMMAND_PREFIXES = { "KiteHost", "LiveServer" }
local FEATURES = { "uv" }

-- The documented commands: every name the README's command tables list,
-- once each, sorted; and every use they document, each command bare and
-- with each subcommand its rows name, so a refuser that takes no argument
-- reds on its subcommands.
local documented, uses = {}, {}
for line in io.lines(H.root .. "/README.md") do
    local name = line:match("^| `:(%w+)`")
    if name and not vim.tbl_contains(documented, name) then
        table.insert(documented, name)
        table.insert(uses, name)
    end
    local sub = line:match("^| `:%w+` | `([%w-]+)`")
    if sub then
        table.insert(uses, name .. " " .. sub)
    end
end
table.sort(documented)
documented = table.concat(documented, " ")

-- The plugin's commands Neovim has, by the shared prefixes, sorted: a set
-- equal to the README's is every documented command and no other.
local function defined()
    local names = {}
    for name in pairs(vim.api.nvim_get_commands({})) do
        for _, prefix in ipairs(COMMAND_PREFIXES) do
            if vim.startswith(name, prefix) then
                table.insert(names, name)
                break
            end
        end
    end
    table.sort(names)
    return table.concat(names, " ")
end

-- A loaded module of this plugin under either name besides the entry
-- module, its alias, which hands back the entry module's stub, and the
-- floor module is code that needs 0.10.
local function loaded_below()
    local found = {}
    for name in pairs(package.loaded) do
        local plugin = name == MODULE or vim.startswith(name, MODULE .. ".")
        local former = name == FORMER or vim.startswith(name, FORMER .. ".")
        if (plugin or former) and name ~= MODULE and name ~= FORMER and name ~= MODULE .. ".floor" then
            table.insert(found, name)
        end
    end
    table.sort(found)
    return table.concat(found, ", ")
end

-- The floor module's verdict, its chunk run against a vim that lacks field
-- (a dotted name; nil hides nothing), since a field removed from the running
-- vim can come back through its lazy loader (vim.uri_encode does, measured).
local function floor_ok_without(field)
    local chunk = assert(loadfile(H.root .. "/lua/" .. MODULE .. "/floor.lua"))
    local function proxy(real, prefix)
        return setmetatable({}, {
            __index = function(_, key)
                local name = prefix .. key
                if name == field then
                    return nil
                end
                local value = real[key]
                if type(value) == "table" and field and vim.startswith(field, name .. ".") then
                    return proxy(value, name .. ".")
                end
                return value
            end,
        })
    end
    setfenv(chunk, setmetatable({ vim = proxy(vim, "") }, { __index = _G }))
    return chunk().ok
end

-- What a pcall returned, or what it raised, as one value: an and/or idiom
-- would read a false verdict as a raise.
local function outcome(done, value)
    if done then
        return value
    end
    return "raised " .. tostring(value)
end

-- The guard's return comes before every require but the floor module's, in
-- the source, a pcall(require, ...) included, so a require moved above it
-- reds even when the module it loads happens to need nothing newer.
local function guard_precedes_requires()
    local src = table.concat(vim.fn.readfile(H.root .. "/lua/" .. MODULE .. "/init.lua"), "\n")
    src = src:gsub("%-%-[^\n]*", "")
    local guard = src:find("if not floor.ok then", 1, true)
    local ret = guard and src:find("return setmetatable", guard, true)
    local first
    for _, pattern in ipairs({
        "()require%s*%(?%s*[\"']([^\"']+)[\"']",
        "()pcall%s*%(%s*require%s*,%s*[\"']([^\"']+)[\"']",
    }) do
        for at, name in src:gmatch(pattern) do
            if name ~= MODULE .. ".floor" then
                first = math.min(first or at, at)
                break
            end
        end
    end
    return guard ~= nil and ret ~= nil and (first == nil or ret < first),
        ("guard at %s, its return at %s, the first other require at %s"):format(guard, ret, first)
end

-- Every refusal is recorded, notify_once's own dedupe aside, so the plugin
-- file's and the module's are checked apart; a refuser's goes through
-- vim.notify, since each use answers.
local notices, refusals = {}, {}
local real_once, real_notify = vim.notify_once, vim.notify
vim.notify_once = function(msg, level)
    notices[#notices + 1] = { msg = msg, level = level }
end
vim.notify = function(msg, level)
    refusals[#refusals + 1] = { msg = msg, level = level }
end
local real_has = vim.fn.has
vim.fn.has = function(feature)
    if feature == "nvim-0.10" then
        return 0
    end
    return real_has(feature)
end
local function turn_loop()
    vim.wait(50, function()
        return false
    end)
end

-- The plugin file sourced under pcall: a raise is the answer of the row
-- that reads the source, where it ended the suite with no Results line.
local function source_plugin()
    local done, err = pcall(vim.cmd, "source " .. vim.fn.fnameescape(plugin_file))
    return not done and ("source raised " .. tostring(err)) or nil
end

H.section("Section 1: below the floor")
H.ok(documented ~= "", "the README's command table lists the commands: " .. documented)
local source_err = source_plugin()
local message = require(MODULE .. ".floor").message
H.ok(vim.startswith(message, "kitehost: "), "the floor text starts kitehost:, as every notice does: " .. message)
H.ok(message:find("0.10", 1, true) ~= nil, "the floor text names the floor")
H.ok(
    message:find("on Neovim 0.8 or 0.9 pin the plugin to v1.5.0", 1, true) ~= nil,
    "the floor text names the release to pin on 0.8 and 0.9"
)
-- lazy.nvim's cmd and keys specs run the command they were given, so each
-- documented one exists below the floor to say why.
H.eq(source_err or defined(), documented, "every documented command is defined below the floor, and no other")
-- lazy.nvim sources plugin files with :source, where an ERROR notification
-- on 0.9 raised a Vim(source) exception, so the refusal waits for the source
-- to return and shows once the loop turns.
H.eq(#notices, 0, "the plugin file's refusal waits until the :source returns")
vim.wait(1000, function()
    return #notices > 0
end)
H.eq(#notices, 1, "the plugin file refuses with one notification")
-- A vim.notify a load queues beside its notify_once would be counted by the
-- next case's rows, so each load's is read where it happens and cleared.
turn_loop()
H.eq(#refusals, 0, "the plugin file's load notifies through notify_once alone")
refusals = {}
-- A cmd spec runs the command through vim.cmd inside lazy.nvim's handler,
-- where an ERROR notification on 0.9 raised a traceback, so a refuser's waits
-- too; every use answers, a second one included.
local names = vim.split(documented, " ")
H.ok(#uses > #names, "the README's command tables name subcommands too: " .. table.concat(uses, ", "))
-- Under pcall, so a command that is missing reds its own rows below and not
-- the whole suite.
for _, use in ipairs(uses) do
    pcall(vim.cmd, use)
end
H.eq(#refusals, 0, "a refuser's answer waits until the command returns")
pcall(vim.cmd, uses[1])
turn_loop()
H.eq(#refusals, #uses + 1, "every documented command and subcommand answers each use below the floor")
local refused_right = #refusals > 0
for _, refusal in ipairs(refusals) do
    refused_right = refused_right and refusal.msg == message and refusal.level == vim.log.levels.ERROR
end
H.ok(refused_right, "every refuser answers with the floor text as an ERROR")
refusals = {}
-- lazy.nvim's config calls setup() whatever the plugin file did.
package.loaded[MODULE] = nil
local setup_ok, setup_err = pcall(function()
    require(MODULE).setup({})
end)
H.ok(setup_ok, "setup() raises nothing below the floor" .. (setup_ok and "" or (": " .. tostring(setup_err))))
H.eq(loaded_below(), "", "the module returns before any module but the floor module loads")
local structural, where = guard_precedes_requires()
H.ok(structural, "the module's floor guard returns before its first require but the floor module's: " .. where)
-- A lazy load on FileType runs the module inside 0.9's filetype nvim_cmd,
-- where an ERROR notification raised Vim(append), so this refusal waits too.
H.eq(#notices, 1, "the module's refusal waits until the require returns")
vim.wait(1000, function()
    return #notices > 1
end)
H.eq(#notices, 2, "the module refuses with one notification too")
turn_loop()
H.eq(#refusals, 0, "the module's load notifies through notify_once alone")
-- lualine's documented component calls statusline(), and a nil there
-- rendered as the word nil.
local status_ok, status = pcall(function()
    return require(MODULE).statusline()
end)
H.eq(status_ok and tostring(status) or ("raised " .. tostring(status)), "", "the stub's statusline is empty")
-- Any other field a config calls answers the same, never a nil.
local other_ok, other = pcall(function()
    return require(MODULE).anything_else()
end)
H.eq(
    other_ok and tostring(other) or ("raised " .. tostring(other)),
    "",
    "an undocumented field on the stub answers the same"
)
-- notify_once shows a text once, so the floor module's text in both
-- refusals is one notification on screen, whichever of them runs first.
local all_floor_text, all_errors = #notices > 0, #notices > 0
for _, notice in ipairs(notices) do
    all_floor_text = all_floor_text and notice.msg == message
    all_errors = all_errors and notice.level == vim.log.levels.ERROR
end
H.ok(all_floor_text, "both refusals are the floor module's text, so the user sees one notification")
H.ok(all_errors, "every refusal is an ERROR")
-- The plugin-author API loads these two directly, so each refuses at load
-- with the floor text, and again on a retry. util goes first: server
-- requires util, so a server without its own guard still raises util's text
-- once, and only its second require shows the sentinel it left. A plugin
-- written before 2.0.0 loads them by the former names, which refuse alike.
for _, modname in ipairs({ MODULE .. ".util", MODULE .. ".server", FORMER .. ".util", FORMER .. ".server" }) do
    for attempt = 1, 2 do
        local loaded, err = pcall(require, modname)
        H.eq(
            loaded and "loaded" or tostring(err),
            message,
            ("%s refuses to load with the floor text (require %d)"):format(modname, attempt)
        )
    end
end
-- A config still calling require("live_server").setup() meets the stub
-- through the former name, and the floor text is its one notice: the
-- deprecation waits for a Neovim the plugin runs on.
package.loaded[MODULE] = nil
notices, refusals = {}, {}
local former_ok, former = pcall(function()
    return require(FORMER).setup({})
end)
turn_loop()
H.eq(former_ok and tostring(former) or ("raised " .. tostring(former)), "", "the former name answers with the stub")
H.ok(rawequal(package.loaded[FORMER], package.loaded[MODULE]), "the former name is the entry module's own stub")
H.eq(#notices == 1 and notices[1].msg or #notices, message, "the former name's one notice is the floor text")
H.eq(#refusals, 0, "the former name sends nothing through vim.notify")
H.eq(loaded_below(), "", "the former name loads no module but the entry and floor modules")
-- notify_once arrived in 0.7 and a Lua plugin file is sourced from 0.5 on,
-- so without it each guard shows the text through vim.notify, once.
vim.notify_once = nil
refusals = {}
for name in pairs(package.loaded) do
    if name == MODULE or vim.startswith(name, MODULE .. ".") then
        package.loaded[name] = nil
    end
end
source_err = source_plugin()
turn_loop()
H.eq(
    source_err or (#refusals == 1 and refusals[1].msg or #refusals),
    message,
    "without notify_once the plugin file shows the text once"
)
refusals = {}
local again_ok, again_err = pcall(function()
    require(MODULE).setup({})
end)
turn_loop()
H.eq(
    not again_ok and ("setup() raised " .. tostring(again_err)) or (#refusals == 1 and refusals[1].msg or #refusals),
    message,
    "without notify_once the module shows the text once"
)
-- A Neovim before 0.8 has no vim.fs, and one with a vim.uv = vim.loop
-- polyfill passed a vim.uv test into an index of it (measured on 0.7.2
-- and 0.6.1), so below the floor the predicate answers false without
-- raising where the first table of any feature it tests is missing.
for _, field in ipairs(FEATURES) do
    local first = field:match("^[^.]+")
    H.eq(
        outcome(pcall(floor_ok_without, first)),
        false,
        "below the floor the predicate answers without vim." .. first .. " and raises nothing"
    )
end

H.section("Section 2: at the floor")
vim.fn.has = real_has
vim.notify_once = real_once
vim.notify = real_notify
-- The refusers go, so every command counted below is the real plugin's.
for _, name in ipairs(names) do
    pcall(vim.api.nvim_del_user_command, name)
end
-- The stub and the floor module's verdict go with every other module of
-- the plugin, and so does the sentinel require leaves for a module that
-- raised while loading, under either name.
for name in pairs(package.loaded) do
    for _, prefix in ipairs({ MODULE, FORMER }) do
        if name == prefix or vim.startswith(name, prefix .. ".") then
            package.loaded[name] = nil
        end
    end
end
H.eq(outcome(pcall(floor_ok_without, nil)), true, "the floor admits this Neovim")
for _, field in ipairs(FEATURES) do
    H.eq(
        outcome(pcall(floor_ok_without, field)),
        false,
        "the floor refuses a Neovim without vim." .. field .. ", whatever its version"
    )
end
-- Twice, for the exit hook's group below; under pcall, so a plugin that
-- raises at the floor reds this row and not the whole suite.
local sourced = { pcall(vim.cmd, "source " .. vim.fn.fnameescape(plugin_file)) }
local resourced = { pcall(vim.cmd, "source " .. vim.fn.fnameescape(plugin_file)) }
H.eq(
    (sourced[1] and "sourced" or ("raised " .. tostring(sourced[2])))
        .. ", "
        .. (resourced[1] and "sourced" or ("raised " .. tostring(resourced[2]))),
    "sourced, sourced",
    "the plugin file sources twice without raising on a supported Neovim"
)
-- By type: a failed require leaves a truthy sentinel, and a left-over stub
-- answers state with a function; under pcall, so a module that raises reds
-- this row and not the whole suite.
local module_ok, module = pcall(require, MODULE)
H.ok(
    type(package.loaded[MODULE .. ".server"]) == "table" and module_ok and type(module.state) == "table",
    "the plugin's own modules load on a supported Neovim" .. (module_ok and "" or (": " .. tostring(module)))
)
-- A former name loaded here would warn every user at startup.
local former_loaded = {}
for name in pairs(package.loaded) do
    if name == FORMER or vim.startswith(name, FORMER .. ".") then
        table.insert(former_loaded, name)
    end
end
H.eq(table.concat(former_loaded, ", "), "", "the plugin file and its modules load no former name")
H.eq(defined(), documented, "every documented command is defined on a supported Neovim, and no other")
local hooked, hooks = pcall(vim.api.nvim_get_autocmds, { group = "KiteHostExit", event = "VimLeavePre" })
H.eq(hooked and #hooks or 0, 1, "the exit hook sits once in the KiteHostExit group, a second source included")
-- stop_all notifies at exit, after the Results line and with no newline,
-- where its line fused with the runner's next one (a CI ::endgroup::
-- marker).
if hooked then
    vim.api.nvim_clear_autocmds({ group = "KiteHostExit" })
end
H.finish()
