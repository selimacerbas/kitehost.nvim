-- A config calls setup() whatever the plugin file did (lazy.nvim's config
-- runs it), so below the floor the module is a stub that answers every call
-- with an empty string and returns before the requires below, whose code
-- needs vim.uv: a statusline component (lualine's, as the README shows)
-- renders nil as the word. The text is the floor module's, so notify_once
-- shows it once with the plugin file's (notify_once arrived in 0.7), and it
-- waits for the loop as the plugin file's does: a lazy load on FileType runs
-- inside 0.9's filetype nvim_cmd, where an ERROR notification raised
-- Vim(append) with a traceback.
local floor = require("live_server.floor")
if not floor.ok then
    vim.schedule(function()
        local notify = vim.notify_once or vim.notify
        notify(floor.message, vim.log.levels.ERROR)
    end)
    local function nothing()
        return ""
    end
    return setmetatable({}, {
        __index = function()
            return nothing
        end,
    })
end

local M = {}

local util = require("live_server.util")
local server = require("live_server.server")

local defaults = {
    default_port = 8000,
    host = "127.0.0.1", -- bind address; use "0.0.0.0" for network access
    open_on_start = true,
    notify = true,
    notify_on_reload = false, -- show notification on every live-reload
    headers = { ["Cache-Control"] = "no-cache" },
    cors = false, -- true/"*", one origin or a list of origins
    index_names = { "index.html", "index.htm" },
    auto_start = nil, -- { filetypes = {"html"}, port = 8000 }

    -- Optional auth: when token is set, /__live/events and /__live/inject
    -- require ?t=<token>, as does any request path matching protected_paths
    -- (Lua patterns) but the injected client, /__live/script.js, and
    -- /__live/asset where a caller of server.start() passes asset_root,
    -- which setup() never does. Every other file but a dot path is still
    -- served openly: with a non-loopback host the whole served root but
    -- its dot paths is reachable from the network.
    token = nil,
    protected_paths = {},
    -- Extra Host names a loopback bind answers besides localhost and the
    -- loopback addresses; true turns the check off (warned at each start).
    allowed_hosts = nil,
    serve_dotfiles = false, -- serve .env, .git/ and other dot paths (default: 404)

    live_reload = {
        enabled = true, -- watch files & push SSE "reload"
        inject_script = true, -- inject <script src="/__live/script.js">
        debounce = 120, -- ms
        css_inject = true, -- hot-swap CSS without full page reload
    },

    directory_listing = {
        enabled = true, -- keep simple listing if no index.html
        show_hidden = false,
    },
}

M.opts = vim.deepcopy(defaults)
M.state = { servers = {}, opened_ports = {} } -- [port] = inst; opened_ports[port]=true

local start_for_path -- forward declaration (used by auto_start and start_picker)

-- The URL a browser opens for a server: a wildcard bind is reached on the
-- loopback address the server's rule gives, the one its start found free;
-- for a port this plugin does not serve (open_existing) nothing probed it,
-- and a server's token rides in the query, so the page's first request
-- and its injected client carry it. token is a started server's, which
-- start keeps non-empty, or nil.
local function browser_url(host, port, token)
    local display = server.wildcard_loopback(host) or host
    -- Chromium rewrites [::ffff:a.b.c.d] to hex, a Host the server refuses.
    display = display:match("^::[fF][fF][fF][fF]:(%d+%.%d+%.%d+%.%d+)$") or display
    -- An IPv6 literal takes brackets once, or its colons read as the port.
    if display:find(":", 1, true) and display:sub(1, 1) ~= "[" then
        display = "[" .. display .. "]"
    end
    local url = ("http://%s:%d/"):format(display, port)
    if token then
        url = url .. "?t=" .. util.url_encode(token)
    end
    return url
end

-- A caller's header replaces one of the current set under any spelling of
-- its name: deep-extended, a ["cache-control"] sat beside the default's
-- Cache-Control, and a cache read both as one list, "no-cache, max-age=60",
-- so the caller's value did nothing. Start refuses two spellings of one
-- name, which a caller's own table can still hold.
local function fold_headers(current, given)
    local named = {}
    for k in pairs(given) do
        if type(k) == "string" then
            named[k:lower()] = true
        end
    end
    local out = {}
    for k, v in pairs(current) do
        if not (type(k) == "string" and named[k:lower()]) then
            out[k] = v
        end
    end
    for k, v in pairs(given) do
        out[k] = v
    end
    return out
end

function M.setup(opts)
    local before = M.opts
    local merged = vim.tbl_deep_extend("force", before, opts or {})
    if type(before.headers) == "table" and type(opts) == "table" and type(opts.headers) == "table" then
        merged.headers = fold_headers(before.headers, opts.headers)
    end
    -- A section given as anything but a table replaced it, and every start
    -- read its fields: a boolean or a number raised there, outside the
    -- start's pcall, and "off" read as a section with nothing set, live
    -- reload on. false is the section off and true on, its other fields
    -- kept; any other value is refused, at level 0, before the merge is
    -- kept, so the options stay as they were.
    for _, section in ipairs({ "live_reload", "directory_listing" }) do
        local given = merged[section]
        if type(given) == "boolean" then
            merged[section] = vim.tbl_extend("force", before[section], { enabled = given })
        elseif type(given) ~= "table" then
            error(section .. " must be a table or a boolean", 0)
        end
    end
    -- A flag no start accepts is named here, at the config that holds it.
    for _, flag in ipairs({
        { "live_reload", "enabled" },
        { "live_reload", "inject_script" },
        { "live_reload", "css_inject" },
        { "directory_listing", "enabled" },
        { "directory_listing", "show_hidden" },
    }) do
        if type(merged[flag[1]][flag[2]]) ~= "boolean" then
            error(("%s.%s must be true or false, got %s"):format(flag[1], flag[2], type(merged[flag[1]][flag[2]])), 0)
        end
    end
    -- A string or a number read as on: open_on_start = "no" opened the
    -- browser, and serve_dotfiles was refused only when a start read it.
    for _, key in ipairs({ "notify_on_reload", "open_on_start", "notify", "serve_dotfiles" }) do
        if type(merged[key]) ~= "boolean" then
            error(("%s must be true or false, got %s"):format(key, type(merged[key])), 0)
        end
    end
    -- Its fields are read below; a number there, or in its filetypes, raised
    -- with a file position. false is off, as for a section; nil cannot
    -- come through the merge. port is the start's to check when it fires.
    local auto = merged.auto_start
    if auto ~= nil and auto ~= false and type(auto) ~= "table" then
        error("auto_start must be a table or false", 0)
    end
    -- Each entry becomes an autocmd pattern, which reads "" as every
    -- filetype and a comma as two, and refuses a brace or a line break only
    -- after the options below are replaced and the earlier autocmd cleared,
    -- so an entry is a filetype name or refused here.
    if type(auto) == "table" and auto.filetypes ~= nil then
        local fts = auto.filetypes
        local listed = type(fts) == "table" and vim.islist(fts)
        for _, ft in ipairs(listed and fts or {}) do
            listed = listed and type(ft) == "string" and ft:find("^[%w_.+-]+$") ~= nil
        end
        if not listed then
            error("auto_start.filetypes must be a list of filetype names", 0)
        end
    end
    M.opts = merged

    -- Cleared on every call: a later auto_start = false or an empty
    -- filetypes list must disarm the earlier autocmd, which otherwise kept
    -- starting servers and raised on a false auto_start. A later call that
    -- names no filetypes keeps the earlier list through the merge above.
    local group = vim.api.nvim_create_augroup("LiveServerAutoStart", { clear = true })
    if M.opts.auto_start and M.opts.auto_start.filetypes then
        local fts = M.opts.auto_start.filetypes
        if #fts > 0 then
            vim.api.nvim_create_autocmd("FileType", {
                pattern = fts,
                group = group,
                callback = function(args)
                    local file = vim.api.nvim_buf_get_name(args.buf)
                    if file == "" then
                        return
                    end
                    local dir = util.dirname(file)
                    local real = vim.uv.fs_realpath(dir)
                    if not real then
                        return
                    end
                    for _, s in pairs(M.state.servers) do
                        if s.root_real == real then
                            return
                        end
                    end
                    local port = M.opts.auto_start.port or M.opts.default_port
                    start_for_path(file, port)
                end,
            })
        end
    end
end

-- Start server for a path (file or directory) on a port
function start_for_path(path, port)
    local stat = vim.uv.fs_stat(path)
    if not stat then
        return util.notify("Path not found: " .. path, M.opts, "ERROR")
    end
    local root, index = path, nil
    if stat.type == "file" then
        root = util.dirname(path)
        index = path
    end

    local s = M.state.servers[port]
    local active_port = port
    local started_here = false
    if s then
        -- By pcall itself, so a refused root is a notice with no position.
        local retargeted, answer = pcall(server.update_target, s, root, index)
        if not retargeted then
            return util.notify("LiveServer could not retarget: " .. tostring(answer), M.opts, "ERROR")
        end
        -- The retarget read as done while its live reload went off unsaid;
        -- the server's own warning names the cause, and a root may carry
        -- a peer's bytes, so the line is marked.
        if answer == false then
            local off = ("LiveServer %d retargeted to %s; live reload is off"):format(port, root)
            util.notify(util.marked(off), M.opts, "WARN")
        else
            util.notify(
                ("LiveServer %d retargeted → %s%s"):format(
                    port,
                    root,
                    index and (" (index " .. util.basename(index) .. ")") or ""
                ),
                M.opts
            )
        end
    else
        local ok, inst_or_err = pcall(server.start, {
            port = port,
            host = M.opts.host,
            root = root,
            default_index = index,
            headers = M.opts.headers,
            cors = M.opts.cors,
            token = M.opts.token,
            protected_paths = M.opts.protected_paths,
            allowed_hosts = M.opts.allowed_hosts,
            serve_dotfiles = M.opts.serve_dotfiles,
            index_names = M.opts.index_names,
            notify_on_reload = M.opts.notify_on_reload,
            live = {
                enabled = M.opts.live_reload.enabled,
                inject_script = M.opts.live_reload.inject_script,
                debounce = M.opts.live_reload.debounce,
                css_inject = M.opts.live_reload.css_inject,
            },
            features = {
                dirlist = {
                    enabled = M.opts.directory_listing.enabled,
                    show_hidden = M.opts.directory_listing.show_hidden,
                },
            },
        })
        if not ok then
            -- The server's message names the cause; this names what failed,
            -- since :messages shows the notice without its title. A bind
            -- prefix here read a refused option as a busy port.
            return util.notify("LiveServer did not start: " .. tostring(inst_or_err), M.opts, "ERROR")
        end
        active_port = inst_or_err.port
        M.state.servers[active_port] = inst_or_err
        started_here = true
    end

    -- One URL, printed and opened: a page opened by hand needs its token,
    -- which the printed URL carries. Both branches above leave a server on
    -- the port, so the bound address is what the URL names.
    local s = M.state.servers[active_port]
    local url = browser_url(s.host, active_port, s.token)
    if started_here then
        util.notify(("LiveServer %d started → %s at %s"):format(active_port, root, url), M.opts)
    end
    if M.opts.open_on_start then
        util.open_browser(url)
        M.state.opened_ports[active_port] = true
    end
end

-- Public: pick path (Telescope) then port → start
function M.start_picker()
    util.pick_path(function(picked_path)
        if not picked_path or picked_path == "" then
            return
        end
        util.pick_port({ default = M.opts.default_port, known_ports = vim.tbl_keys(M.state.servers) }, function(port)
            if not port then
                return
            end
            start_for_path(picked_path, tonumber(port))
        end)
    end)
end

-- Open an existing server (ours or external) in browser via port picker
function M.open_existing()
    util.pick_port({
        default = M.opts.default_port,
        known_ports = vim.tbl_keys(M.state.servers),
        title = "Open http://<host>:<port>/ in Browser",
    }, function(port)
        if not port then
            return
        end
        local s = M.state.servers[tonumber(port)]
        util.open_browser(browser_url(s and s.host or M.opts.host, tonumber(port), s and s.token))
        M.state.opened_ports[tonumber(port)] = true
    end)
end

-- Live-reload controls
function M.force_reload()
    util.pick_port({
        default = M.opts.default_port,
        known_ports = vim.tbl_keys(M.state.servers),
        title = "Force reload (pick port)",
    }, function(port)
        if not port then
            return
        end
        local s = M.state.servers[tonumber(port)]
        if not s then
            return util.notify("No live-server instance on that port.", M.opts, "WARN")
        end
        server.reload(s, "manual")
    end)
end

function M.toggle_livereload()
    util.pick_port({
        default = M.opts.default_port,
        known_ports = vim.tbl_keys(M.state.servers),
        title = "Toggle live-reload (pick port)",
    }, function(port)
        if not port then
            return
        end
        local s = M.state.servers[tonumber(port)]
        if not s then
            return util.notify("No live-server instance on that port.", M.opts, "WARN")
        end
        local want = not server.is_live_enabled(s)
        local enabled, cause = server.enable_live(s, want)
        -- A toggle that failed read as a plain DISABLED, naming no cause.
        if want and not enabled then
            local why = cause and (": " .. cause) or ""
            local line = ("Live-reload DISABLED on %d%s"):format(port, why)
            return util.notify(util.marked(line), M.opts, "WARN")
        end
        util.notify(("Live-reload %s on %d"):format(enabled and "ENABLED" or "DISABLED", port), M.opts)
    end)
end

-- Stop
function M.stop_one()
    local ports = vim.tbl_keys(M.state.servers)
    if #ports == 0 then
        return util.notify("No live-server instances to stop.", M.opts, "WARN")
    end
    util.pick_list({
        title = "Stop LiveServer on Port",
        items = vim.tbl_map(function(p)
            return tostring(p)
        end, ports),
    }, function(choice)
        if not choice then
            return
        end
        local port = tonumber(choice)
        local s = M.state.servers[port]
        if s then
            server.stop(s)
            M.state.servers[port] = nil
            util.notify(("Stopped LiveServer %d"):format(port), M.opts)
        end
    end)
end

function M.stop_all()
    local ports = vim.tbl_keys(M.state.servers)
    for _, port in ipairs(ports) do
        local s = M.state.servers[port]
        if s then
            server.stop(s)
        end
    end
    M.state.servers = {}
    util.notify("Stopped all LiveServer instances.", M.opts)
end

-- Status. Printed whatever notify says: the command exists to print, and
-- a user who ran it asked for the list.
local SHOWN = { notify = true }
function M.status()
    local ports = vim.tbl_keys(M.state.servers)
    if #ports == 0 then
        return util.notify("No running servers.", SHOWN)
    end
    table.sort(ports)
    local lines = { "LiveServer status:" }
    for _, port in ipairs(ports) do
        local s = M.state.servers[port]
        local live = server.is_live_enabled(s) and "ON" or "OFF"
        local clients = server.connected_client_count(s)
        local uptime = os.time() - s.started_at
        table.insert(
            lines,
            ("  :%d → %s  [live:%s  clients:%d  uptime:%ds]"):format(port, s.root, live, clients, uptime)
        )
    end
    util.notify(table.concat(lines, "\n"), SHOWN)
end

-- Statusline component: returns "[LS :8000]" or ""
function M.statusline()
    local ports = vim.tbl_keys(M.state.servers)
    if #ports == 0 then
        return ""
    end
    table.sort(ports)
    local parts = {}
    for _, p in ipairs(ports) do
        table.insert(parts, ":" .. p)
    end
    return "[LS " .. table.concat(parts, ",") .. "]"
end

return M
