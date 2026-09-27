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
    cors = false, -- true/"*" or origin string
    index_names = { "index.html", "index.htm" },
    auto_start = nil, -- { filetypes = {"html"}, port = 8000 }

    -- Optional auth: when token is set, /__live/events and /__live/inject
    -- require ?t=<token>, as does any request path matching protected_paths
    -- (Lua patterns), and /__live/asset where a caller of server.start()
    -- passes asset_root, which setup() never does. Everything else is still
    -- served openly: with a non-loopback host the whole served root is
    -- reachable from the network.
    token = nil,
    protected_paths = {},
    -- Extra Host names a loopback bind answers besides localhost and the
    -- loopback addresses; true turns the check off (warned once).
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

function M.setup(opts)
    M.opts = vim.tbl_deep_extend("force", M.opts, opts or {})

    if M.opts.auto_start and M.opts.auto_start.filetypes then
        local fts = M.opts.auto_start.filetypes
        if #fts > 0 then
            vim.api.nvim_create_autocmd("FileType", {
                pattern = fts,
                group = vim.api.nvim_create_augroup("LiveServerAutoStart", { clear = true }),
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
    if s then
        server.update_target(s, root, index)
        util.notify(
            ("LiveServer %d retargeted → %s%s"):format(
                port,
                root,
                index and (" (index " .. util.basename(index) .. ")") or ""
            ),
            M.opts
        )
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
            return util.notify(("Failed to bind port %s: %s"):format(tostring(port), inst_or_err), M.opts, "ERROR")
        end
        active_port = inst_or_err.port
        M.state.servers[active_port] = inst_or_err
        util.notify(("LiveServer %d started → %s"):format(active_port, root), M.opts)
    end

    if M.opts.open_on_start then
        local display_host = (M.opts.host == "0.0.0.0") and "127.0.0.1" or M.opts.host
        util.open_browser(("http://%s:%d/"):format(display_host, active_port))
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
        local h = s and s.host or M.opts.host
        local display_host = (h == "0.0.0.0") and "127.0.0.1" or h
        util.open_browser(("http://%s:%d/"):format(display_host, port))
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
        local enabled = server.enable_live(s, not server.is_live_enabled(s))
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

-- Status
function M.status()
    local ports = vim.tbl_keys(M.state.servers)
    if #ports == 0 then
        return util.notify("No running servers.", M.opts)
    end
    table.sort(ports)
    local lines = { "LiveServer status:" }
    for _, port in ipairs(ports) do
        local s = M.state.servers[port]
        local live = server.is_live_enabled(s) and "ON" or "OFF"
        local clients = #s.sse_clients
        local uptime = os.time() - s.started_at
        table.insert(
            lines,
            ("  :%d → %s  [live:%s  clients:%d  uptime:%ds]"):format(port, s.root, live, clients, uptime)
        )
    end
    util.notify(table.concat(lines, "\n"), M.opts)
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
