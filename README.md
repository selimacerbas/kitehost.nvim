# live-server.nvim

A tiny, zero-dependency **local web server** for Neovim — written in pure Lua with `vim.uv`.
Start a server on any file or folder, auto-reload the browser on save, and quickly reopen existing ports.

* **Pure Lua**: no npm, no Python, no binaries.
* **Local by default**: binds to `127.0.0.1`; set `host = "0.0.0.0"` for network access.
* **SSE live-reload**: instant page refresh on file changes (debounced).
* **CSS hot-inject**: stylesheet changes apply instantly without a full page reload.
* **Directory listing**: clean index when no `index.html` exists.
* **Telescope UX**: pick a path (file or directory) and a port from a friendly picker.
* **Which-key friendly**: group label in `init`, real mappings in `keys`, no conflicts.
* **Same-port retargeting**: starting on the same port updates the served root/index (reuses the same browser tab/URL).
* **Auto-start**: optionally start a server when you open an HTML file.
* **Statusline**: show active servers in your statusline/lualine.

> This plugin binds to `127.0.0.1` by default. Set `host = "0.0.0.0"` to make it accessible from other machines on the network.

---

## Requirements

* Neovim **0.10+** (on Neovim 0.8 or 0.9, pin the plugin to v1.5.0, the last release that runs there; from the next release on, v1.5.0 receives no fixes).
* Linux, macOS, or Windows.
* [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) **recommended** for the best picking UX (falls back to `vim.ui.select/input` if missing).
* [which-key.nvim](https://github.com/folke/which-key.nvim) recommended.

---

## Installation (lazy.nvim)

```lua
-- lua/plugins/live-server.lua
return {
  "selimacerbas/live-server.nvim",
  dependencies = {
    "folke/which-key.nvim",
    "nvim-telescope/telescope.nvim", -- recommended for path picker
  },
  init = function()
    -- which-key group label only (best practice)
    local ok, wk = pcall(require, "which-key")
    if ok then wk.add({ { "<leader>l", group = "LiveServer" } }) end
  end,
  opts = {
    default_port = 8000,
    live_reload = { enabled = true, inject_script = true, debounce = 120, css_inject = true },
    directory_listing = { enabled = true, show_hidden = false },
  },
  -- map to user commands (robust lazy-loading)
  keys = {
    { "<leader>ls", "<cmd>LiveServerStart<cr>",      desc = "Start (pick path & port)" },
    { "<leader>lo", "<cmd>LiveServerOpen<cr>",       desc = "Open existing port in browser" },
    { "<leader>lr", "<cmd>LiveServerReload<cr>",     desc = "Force reload (pick port)" },
    { "<leader>lt", "<cmd>LiveServerToggleLive<cr>", desc = "Toggle live-reload (pick port)" },
    { "<leader>li", "<cmd>LiveServerStatus<cr>",     desc = "Show server status" },
    { "<leader>lS", "<cmd>LiveServerStop<cr>",       desc = "Stop one (pick port)" },
    { "<leader>lA", "<cmd>LiveServerStopAll<cr>",    desc = "Stop all" },
  },
  config = function(_, opts)
    require("live_server").setup(opts)
  end,
}
```

---

## Usage

### Start a server

* Press **`<leader>ls`** (or run `:LiveServerStart`).
* Pick a **path** (file or directory), then pick a **port** (default `8000`).
* Your browser opens `http://127.0.0.1:<port>/`.

> If you pick a **file**, the server serves the file's folder with that file as the default index.
> If you pick the **same port** again later, the server **retargets** to the new root/index instead of creating a new instance.

### Other commands

| Command | Description |
| --- | --- |
| `:LiveServerStart` | Pick a path and port, start serving |
| `:LiveServerOpen` | Pick a port, open its URL in browser |
| `:LiveServerReload` | Force reload all connected clients |
| `:LiveServerToggleLive` | Enable/disable file watching for a port |
| `:LiveServerStatus` | Show running servers (port, root, uptime, clients) |
| `:LiveServerStop` | Pick a port to stop |
| `:LiveServerStopAll` | Stop all servers |

---

## Options

Configured via `require("live_server").setup({...})` or `opts = { ... }` in your lazy spec.

```lua
{
  default_port     = 8000,           -- default suggestion in the port picker
  host             = "127.0.0.1",    -- bind address; "0.0.0.0" = all interfaces (network access)
  token            = nil,            -- optional: require ?t=<token> on /__live/events, /__live/inject and protected_paths (and on /__live/asset, which only a caller of server.start() that passes asset_root enables)
  protected_paths  = {},             -- Lua patterns of request paths that also require the token
  open_on_start    = true,           -- open browser after start/retarget
  notify           = true,           -- use vim.notify for events
  notify_on_reload = false,          -- notify on every live-reload event
  headers          = { ["Cache-Control"] = "no-cache" }, -- extra response headers
  cors             = false,          -- true/"*", one origin (e.g. "http://localhost:3000") or a list of origins
  index_names      = { "index.html", "index.htm" }, -- index files to try in order

  auto_start = nil,                  -- set to auto-start on filetype, e.g.:
  -- auto_start = { filetypes = { "html" }, port = 8000 },

  live_reload = {
    enabled       = true,            -- watch files under the served root
    inject_script = true,            -- injects <script src="/__live/script.js">
    debounce      = 120,             -- ms debounce for rapid changes
    css_inject    = true,            -- hot-swap CSS without full page reload
  },

  directory_listing = {
    enabled     = true,              -- render an index page if no index.html
    show_hidden = false,             -- include dotfiles in listing
  },
}
```

---

## Features

### CSS hot-inject

When `css_inject` is enabled (default), editing a `.css` file triggers an instant stylesheet swap in the browser — no full page reload, no DOM state lost. All other file changes still trigger a full reload.
A change under a dot path (`.env`, `.git/`) pushes no reload unless `serve_dotfiles` is set, the file you started on excepted, and `.liveignore` patterns match the path relative to the served root.

### Auto-start

Set `auto_start` to automatically start a server when you open a matching filetype:

```lua
auto_start = { filetypes = { "html" }, port = 8000 }
```

The server starts once per directory — opening another HTML file in the same folder won't spawn a duplicate.

### `.liveignore`

Create a `.liveignore` file in your served root to skip file-watcher noise. One pattern per line, `*` as wildcard, `#` for comments:

```
# Don't reload on these
node_modules
*.log
.git
dist
```

A line starting with `/` is anchored at the served root: `/dist` skips `dist/` and not `sub/dist/`.

### CORS

Enable cross-origin headers on the root route's responses; `/__live/*` never carries them:

```lua
cors = true,                         -- Access-Control-Allow-Origin: *
cors = "http://localhost:3000",      -- specific origin
cors = { "http://localhost:3000", "http://localhost:5173" }, -- a listed Origin is echoed, with Vary: Origin
```

Useful when your frontend (on the live server) makes API calls to a separate backend.

### Statusline

Show active servers in lualine or any statusline:

```lua
-- lualine example
sections = {
  lualine_x = {
    { require("live_server").statusline },
  },
}
```

Returns `"[LS :8000]"` when a server is running, or `""` when idle.

### Styled error pages

404 and 400 errors display a clean, dark-mode-aware HTML page instead of raw text — easier to spot during development.

---

## Keymaps (default)

All under the which-key group **`<leader>l`**:

| Key          | Action                         |
| ------------ | ------------------------------ |
| `<leader>ls` | Start (pick path & port)       |
| `<leader>lo` | Open existing port in browser  |
| `<leader>lr` | Force reload (pick port)       |
| `<leader>lt` | Toggle live-reload (pick port) |
| `<leader>li` | Show server status             |
| `<leader>lS` | Stop one (pick port)           |
| `<leader>lA` | Stop all                       |

> We register only the **group label** in `init`, and return actual mappings in `keys` — the recommended pattern for Folke's ecosystem to avoid conflicts and enable lazy-loading on keypress.

---

## Design notes

* **Local by default**: binds to `127.0.0.1`. Set `host = "0.0.0.0"` in your setup opts to expose over the network (e.g. when SSH-ing in and viewing on another machine). **Be deliberate about this**: every file under the served root, except a dot path unless `serve_dotfiles` is set, becomes readable by anyone who can reach the port, traffic is plain unencrypted HTTP, and without `token` the `/__live/inject` control endpoint is open too. Set `token` (and `protected_paths` for sensitive files) when binding beyond loopback, or prefer an SSH tunnel (`ssh -L 8000:localhost:8000 <host>`), which needs no config at all.
* **Path safety**: requests are realpath-checked to prevent escaping the served root.
* **Index resolution**: root directory → `default_index` (if starting from a file) → `index_names` in order → directory listing. Subdirectories always use their own index files.
* **Port 0 (OS-assigned)**: pass `port = 0` to let the OS pick a free port. The actual port is available via `inst.port` after `server.start()`.
* **Same port, new path**: reusing the same port retargets the server → same URL, so browsers typically reuse the same tab.
* **Event injection**: `GET /__live/inject?event=<type>&data=<json>` lets external processes broadcast SSE events to connected clients. A browser request from another site, or from another port of the same host, is refused (403) by its `Sec-Fetch-Site` or `Origin` header, on loopback binds too; a request that sends neither, such as curl's, is served on a loopback bind, so set `token` when other programs on this machine must not inject. A browser sends no Fetch Metadata to a plain-http LAN address (an `Origin` still rides on a cors fetch and a WebSocket handshake), so a network bind without a `token` (and a loopback bind reached by an `allowed_hosts` name) fires events only for a request that sends `Sec-Fetch-Site: same-origin` or `none` (a typed URL, which no page can send); an `Origin` refuses a request from another origin and admits none, because a page's own `Origin` rides on its WebSocket handshake, so the token is that bind's boundary.
* **Graceful exit**: all servers are automatically stopped on `VimLeavePre`.

---

## Troubleshooting

* **"Port in use or failed to bind"**
  Another process is using that port (or a previous server didn't exit cleanly). Pick a different port, or stop the other process.
  You can stop live-server instances via `:LiveServerStop` or `:LiveServerStopAll`.

* **"start() bad argument #2 to 'start' (table expected, got number)"**
  Some `luv` builds expect `fs_event:start(path, {recursive=true}, cb)` while others accept `start(path, cb)`. The plugin tries both. Make sure you're on the **latest** plugin files.

* **Browser didn't open**
  We try `vim.ui.open` and fall back to `xdg-open`/`open`/`start`. If none work, copy the URL from the message and open manually.

* **Live-reload didn't trigger**

  * It only injects into **HTML** pages.
  * Ensure the served root actually changed (the watcher is per root).
  * Check `.liveignore` isn't excluding the file.
  * A change under a dot path pushes no reload unless `serve_dotfiles` is set.
  * Try `:LiveServerToggleLive` off/on, or `:LiveServerReload` to force.

---

## API (for lua configs)

```lua
local ls = require("live_server")

ls.setup({ ... })                -- configure defaults
ls.start_picker()                -- UI flow: pick path, then port
ls.open_existing()               -- pick a port → open in browser
ls.force_reload()                -- broadcast reload to clients
ls.toggle_livereload()           -- enable/disable live-reload for a port
ls.status()                      -- print running server info
ls.statusline()                  -- returns "[LS :8000]" or ""
ls.stop_one()                    -- pick a port → stop
ls.stop_all()                    -- stop everything
```

### Server-level API (for plugin authors)

Below Neovim 0.10, `require("live_server.server")` and `require("live_server.util")` raise the floor message, on every `require`, so a plugin that also runs on an older Neovim loads them under `pcall`.

```lua
local server = require("live_server.server")
local util   = require("live_server.util")

local inst = server.start({
  port = 0,                                   -- port 0 = OS-assigned
  root = "/path",
  token = util.random_token(16),              -- optional, see "Token auth" below
  protected_paths = { "^/content%.md$" },     -- Lua patterns; require ?t=<token>
})
server.send_event(inst, "scroll", '{"line":42}')               -- broadcast custom SSE event
server.reload(inst, "file.html")                                -- broadcast reload event
server.update_target(inst, new_root, new_index)                 -- retarget without restart
server.connected_client_count(inst)                             -- number of SSE clients
server.stop(inst)                                               -- shut down
```

### HTTP event injection

External processes can inject SSE events via HTTP:

```
GET /__live/inject?event=<type>&data=<url-encoded-json>[&t=<token>]
```

This broadcasts the event to all connected SSE clients. Used by [markdown-preview.nvim](https://github.com/selimacerbas/markdown-preview.nvim) for cross-instance scroll sync. The `t=<token>` parameter is required when the server was started with `cfg.token`. The endpoint refuses a browser request from another site (403); a request without browser headers is served on a loopback bind, and on a network bind only with the token (Design notes).

### Token auth (optional)

When `cfg.token` is set, the server requires `?t=<token>` on:

* `/__live/events` (the SSE stream)
* `/__live/inject` (event injection)
* `/__live/asset` (the asset route)
* Any path matching one of the Lua patterns in `cfg.protected_paths`, except `/__live/script.js`, the injected client, which holds no secret

Static assets (`index.html`, `style.css`, etc.) are intentionally not gated because the browser bootstraps from them before any JS runs and cannot append query strings to tags it discovers itself. The gated routes above (the event stream, the inject endpoint, the asset route and the `protected_paths` matches) need `?t=<token>`: pass it to the browser via the initial URL, and the injected client keeps it in `sessionStorage` and puts it on the event stream itself, while a caller's own `fetch`/`EventSource` calls still append it.

`util.random_token(byte_len)` generates a hex token (default 16 bytes = 128 bits) from the operating system's random source (`vim.uv.random`, then `/dev/urandom`) and raises when neither is available. `util.secure_compare(a, b)` is a constant-time-ish string compare for token validation.

Token auth is opt-in. When `cfg.token` is nil (the default), no token is required; the Host check on loopback binds (unless `allowed_hosts = true`) and the inject endpoint's origin check (Design notes) apply on every server.

---

## Roadmap

* Pluggable middlewares (custom headers, rewrites).
* Directory listing customization (sorting, columns).

---

## Contributing

PRs and issues are welcome: [CONTRIBUTING.md](CONTRIBUTING.md) names the commands CI runs and the commit rules, and [SECURITY.md](SECURITY.md) says how to report a vulnerability privately.
A bug report needs your **OS**, **Neovim version**, **plugin version**, the **minimal config** that reproduces it and the **`:messages`** output after the failure, as the bug form asks. Repro steps make fixes fast.

---

## License

MIT © Selim Acerbaş
