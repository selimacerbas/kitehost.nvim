# live-server.nvim

A tiny, zero-dependency **local web server** for Neovim, written in pure Lua with `vim.uv`.
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
  token            = nil,            -- optional: require ?t=<token> on /__live/events, /__live/inject and protected_paths matches but /__live/script.js (and on /__live/asset, which only a caller of server.start() that passes asset_root enables)
  protected_paths  = {},             -- Lua patterns of request paths that also require the token; /__live/script.js, the injected client, never does; a non-empty list needs `token`
  allowed_hosts    = nil,            -- more Host names a loopback bind answers besides localhost, *.localhost and loopback addresses; true turns the check off
  serve_dotfiles   = false,          -- serve .env, .git/ and other dot paths (default: 404; `/.well-known/` at the root is served)
  open_on_start    = true,           -- open browser after start/retarget
  notify           = true,           -- use vim.notify for events
  notify_on_reload = false,          -- notify on every live-reload event
  headers          = { ["Cache-Control"] = "no-cache" }, -- extra response headers
  cors             = false,          -- true/"*", an origin string, or a list of origins; the root route only, never /__live/*
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
    show_hidden = false,             -- list dot entries too; needs serve_dotfiles
  },
}
```

`live_reload` and `directory_listing` also take `true` or `false`, which turns the section on or off and keeps its other fields. `setup()` refuses a section of any other type and a flag that is not `true` or `false`, naming it (`live_reload.enabled must be true or false, got string`; `open_on_start`, `notify` and `serve_dotfiles` the same way; `auto_start` must be a table), and keeps the options it had. A value the server refuses is named by the server's own key when a start fails (`live.debounce` for `live_reload.debounce`).

---

## Features

### CSS hot-inject

When `css_inject` is enabled (default), editing a `.css` file triggers an instant stylesheet swap in the browser: no full page reload, no DOM state lost. All other file changes still trigger a full reload.
A change under a dot path (`.env`, `.git/`) pushes no reload unless `serve_dotfiles` is set, the file you started on excepted, and `.liveignore` patterns match the path relative to the served root.

### Auto-start

Set `auto_start` to automatically start a server when you open a matching filetype:

```lua
auto_start = { filetypes = { "html" }, port = 8000 }
```

The server starts once per directory: opening another HTML file in the same folder won't spawn a duplicate.

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

Enable cross-origin headers on the root route's successful answers; a 401, 404 or 400 carries none, so a listed origin reads an error as a CORS failure:

```lua
cors = true,                         -- Access-Control-Allow-Origin: *
cors = "http://localhost:3000",      -- specific origin
cors = { "http://localhost:3000", "http://localhost:5173" }, -- a listed Origin is echoed, with Vary: Origin
```

`cors` lets the named origins (every website, with `true`) read every file the root route serves; with a list, a request from an origin it does not name gets no CORS header; one origin string is sent on every answer, and only that origin may read it. The live endpoints (`/__live/*`), the event stream and the asset route among them, never carry a CORS header, not even one set in `headers`, so no other site reads them. Write an origin as a browser sends it: any other spelling a browser never sends (an upper-case letter, a path, a default port) is refused at start, naming it; write an IP address in its usual form (127.0.0.1, not 127.1), which start does not check. Leave `cors` off unless a page on another origin must fetch these files.

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

404 and 400 errors display a clean, dark-mode-aware HTML page instead of raw text, easier to spot during development.

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

> We register only the **group label** in `init`, and return actual mappings in `keys`, the recommended pattern for Folke's ecosystem to avoid conflicts and enable lazy-loading on keypress.

---

## Design notes

* **Local by default**: binds to `127.0.0.1`. Set `host = "0.0.0.0"` in your setup opts to expose over the network (e.g. when SSH-ing in and viewing on another machine). **Be deliberate about this**: every file under the served root, except a dot path unless `serve_dotfiles` is set, becomes readable by anyone who can reach the port, traffic is plain unencrypted HTTP, and without `token` the `/__live/inject` control endpoint is open too. Set `token` (and `protected_paths` for sensitive files) when binding beyond loopback, or prefer an SSH tunnel (`ssh -L 8000:localhost:8000 <host>`), which needs no config at all.
* **Path safety**: requests are realpath-checked to prevent escaping the served root.
* **Host check**: on a loopback bind (`127.0.0.1`, `::1`) a request whose `Host` is not `localhost`, a `*.localhost` name or a loopback address gets `421 Misdirected Request`, so a DNS-rebinding page cannot read the server; the port is never compared, so an `ssh -L` tunnel works. Add your own names with `allowed_hosts`. A network bind (`0.0.0.0`, a LAN address) has no Host check; set `token` there.
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
  An old copy of the plugin raised this, trying a two-argument `fs_event:start`; the plugin now calls the three-argument `fs_event:start(path, flags, cb)` alone, and a watcher that cannot start leaves the server serving with live reload off and a warning, so make sure you're on the **latest** plugin files.

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

Everything this section names is the public API that SemVer covers: the calls and what they answer, the `start` keys, the two instance fields, the capability flags, the HTTP routes with their gating and refusals, and the event framing. A release that breaks any of it is a major release. Anything not named here is internal and may change in any release, including every other field of the instance table (the event-stream list `sse_clients` among them: read `server.connected_client_count(inst)`), and the wording of a message, except the `EADDRINUSE` text below. One reservation: a minor release may refuse a request the server admits today when refusing it closes a security hole; the requests this section lists as admitted stay admitted where it admits them (a request with the right token, a request marked same-origin with no foreign `Origin`, and an unmarked request under a loopback name on a loopback bind).

Below Neovim 0.10, `require("live_server.server")` and `require("live_server.util")` raise the floor message, on every `require`, so a plugin that also runs on an older Neovim loads them under `pcall`.

```lua
local server = require("live_server.server")
local util   = require("live_server.util")

local ok, inst = pcall(server.start, {
  root = "/path",                         -- the served directory
  port = 0,                               -- 0 = OS-assigned; the bound port is inst.port
  host = "127.0.0.1",                     -- an IP address; "localhost" binds 127.0.0.1
  default_index = nil,                    -- file served for "/"; a relative path is made absolute at start
  index_names = { "index.html", "index.htm" }, -- file names tried in a directory, in order
  headers = {},                           -- extra response headers, each value a string
  cors = false,                           -- true (any origin), an origin, or a list of origins; root route only
  token = util.random_token(16),          -- optional, a non-empty UTF-8 string; gates the routes below
  protected_paths = { "^/content%.md$" }, -- Lua patterns that also need ?t=<token>; a token is required
  asset_root = nil,                       -- a directory, or a function returning one, for /__live/asset
  allowed_hosts = nil,                    -- more Host names a loopback bind answers; true turns the check off
  serve_dotfiles = false,                 -- serve dot-segment paths (.env, .git/) on the root route
  notify_on_reload = false,               -- a notice on every reload
  header_timeout_ms = 10000,              -- close a connection whose request head has not arrived by then; 0 = off
  max_connections = 64,                   -- close a connection accepted while this many are open
  sse_heartbeat_ms = 20000,               -- ": ping" on every event stream; 0 = off
  live = { enabled = true, inject_script = true, debounce = 120, css_inject = true }, -- omitted: no watcher, no script
  features = { dirlist = { enabled = true, show_hidden = false } }, -- show_hidden needs serve_dotfiles
})
```

`server.start(cfg)` checks every option before it opens a socket and returns the instance, or raises at level 0 (a message for the user, with no file position) and leaves no socket, timer or watcher behind, when it cannot serve: an option it refuses, named in the message; a root that does not resolve or is not a directory; a host that is not an address of this machine (`EADDRNOTAVAIL`); a port another socket holds; a probe that cannot check the loopback address a wildcard bind's URL names, or a wildcard address a specific bind would shadow; a failed listen; a reload or heartbeat timer it cannot make. A refusal for a taken port carries luv's text `EADDRINUSE: address already in use` in each of its shapes (the bind's own refusal, a specific bind beside a listener on the wildcard address of its family, a wildcard bind beside a socket on the loopback address its URL names), and a plugin may match that text to name the port. A root whose watcher cannot start is served with live reload off and a warning.

The instance has two public fields: `inst.port`, the port the socket holds, and `inst.host`, the address the socket is bound to as the OS reports it (a configured `"localhost"` reads `"127.0.0.1"`).

```lua
server.stop(inst)                                  -- close the listener, every connection, stream, timer and watcher; a second stop does nothing
server.update_target(inst, new_root, new_index)    -- retarget without a restart
server.reload(inst, "file.html")                   -- broadcast a reload event; the path is a string or nil
server.send_event(inst, "scroll", '{"line":42}')   -- broadcast an event; the payload is a string or nil ("{}")
server.enable_live(inst, true)                     -- start or stop watching files
server.is_live_enabled(inst)                       -- true while files are watched, false otherwise
server.connected_client_count(inst)                -- open event streams
server.wildcard_loopback(ip)                       -- the loopback address a wildcard bind's URL shows, or nil
util.random_token(16)                              -- hex token of n bytes (2n characters), n from 1 to 1024, 16 when omitted
util.secure_compare(a, b)                          -- whether two strings are equal; see below for its timing
```

A call made wrongly raises at level 2, so the message names the calling line: `reload` with a path that is not a string, `send_event` with a name or payload that is not a string or a name holding a line break, `enable_live` with a flag that is not a boolean, `update_target` with a root or index that is not a string or, on a running server, a root it cannot serve (one that does not resolve or is not a directory), changing nothing, and `util.random_token` with a length outside 1 to 1024. `util.random_token` also raises when the OS offers no random source.

On a stopped server `update_target` returns false without checking that the root resolves. On a running one it returns true when the server serves the root asked, whether it moved or was already that root, and false with the cause when live reload is on and the new root cannot be watched (the root moves and live reload turns off). `enable_live(inst, true)` returns true, or false with the cause when the watcher cannot start, and live reload stays off; `enable_live(inst, false)` returns false, as does `enable_live` on a stopped server. `inject_script` and `css_inject` are fixed at start from `live`: on a server started without `live`, `enable_live(inst, true)` watches files and sends reload events, but its pages load no client script, so no page reloads. A watch that misses some directories under the root keeps live reload on and says so (a notice, described below, outside the promise).

`util.secure_compare(a, b)` returns false at once for a non-string or a length difference; for two strings of one length, its time does not depend on where they differ.

`server.wildcard_loopback(ip)` answers `"127.0.0.1"` for `"0.0.0.0"`, `"::1"` for `"::"` and nil for any other address. A plugin may replace it: `start` reads it through the module to probe the address the URL names, as the plugin's own URL does, so a replaced rule moves the probe and the URL together, and a replacement that raises refuses every start.

Outside the promise, for a person reading the notices: their text and how often they repeat may change in any release. A server tells the user of a fault through `vim.notify`, each line naming its port. A warning is sent once per server for each kind: a listener that stopped accepting connections, a connection it could not serve, a connection it could not read, a reload it could not schedule or cancel, a root it could not watch (sent again after a watcher starts), a directory under the root it could not watch (sent once per watch start that misses one, on the per-directory watcher Linux uses), a `.liveignore` it ignores (sent again after `update_target` moves to a new root), and a `protected_paths` pattern it could not read. A loopback bind started with `allowed_hosts = true` warns that the Host check is off. A request whose handling raised is answered with a 500 (or its connection closed, when the response had begun) and an error notice naming the path and the cause, once per such request.

`server.features` holds the flags a plugin checks before it relies on a capability: `token_auth` (the `token` option and the gated routes), `host_binding` (the `host` option), `asset_route` (`asset_root` and `/__live/asset`), `host_check` (a loopback bind answers only loopback Host names, 421 otherwise), `cors_list` (`cors` takes a list of origins; an install without it reads a list as `"*"`) and `start_raises` (`start` raises at level 0 when it cannot serve).

The HTTP surface is part of the same promise. On a loopback bind a request whose Host line is neither a loopback name nor an `allowed_hosts` entry is 421 on every route before anything else is checked, unless `allowed_hosts = true`; a request with no Host line (HTTP/1.0) is served. Every route answers GET alone: another method is 405, after a malformed path (400) and a dot path the server refuses (404); with `cors` set, the root route also answers a preflight.

- `/__live/events[?t=<token>]`: a `text/event-stream` that starts with `retry: 1000`, then one frame per event, `event: <name>` and one `data:` line per payload line, and a `: ping` comment line as a heartbeat. A reader joins a frame's `data:` lines with line breaks, as the browser's `EventSource` does; one that reads a single `data:` line reads only the first line of a payload.
- `/__live/inject?event=<name>[&data=<url-encoded>][&t=<token>]`: broadcasts one event to every stream and answers 200. `data` is URL-decoded and defaults to `{}`; `event` is taken as sent, not decoded, and a request without it answers 200 and sends nothing. A browser request from another site (its `Sec-Fetch-Site`, or an `Origin` naming another origin) is 403, and one marked `Sec-Fetch-Site: same-origin` or `none` is served unless it also carries an `Origin` naming another origin, which refuses it (403). The reservation above applies to these rules. A request no browser marked as same-origin (no `Sec-Fetch-Site: same-origin` or `none`; curl's among them) is served on a server with a token, and without one only on a loopback bind reached under a loopback name (`localhost`, a `*.localhost` name or a loopback address); under an `allowed_hosts` name or on a network bind it is 403.
- `/__live/asset?p=<relative path>[&t=<token>]`: a file under `asset_root`, 404 when none is set.
- `/__live/script.js`: the injected client, never gated.

With `token` set, `/__live/events`, `/__live/inject`, `/__live/asset` and every path a `protected_paths` pattern matches (`/__live/script.js` excepted) need the query token `t`; a request without it or with another answers 401. Without `token`, no route needs it.

The `reload` event's data is JSON, `{"ts":<seconds>,"path":<string>,"css":<boolean>}`, its keys always in that order. `path` is `""` for `server.reload(inst)`, the string a caller passed to `server.reload`, or, for a watched change, the changed file's path relative to the root, slash-separated with no leading slash (`/` for the root itself, and for the file the server was started on when it sits on a dot path). A debounce window that held several changes names its latest file that is still on disk and is not a stylesheet (a name ending in `.css`), else its latest stylesheet; when none is left on disk it names its latest path, with `css` false. `css` is true only when `css_inject` is on and the path names a stylesheet, which the page swaps in place of a reload. Neovim 0.10 writes a slash as `\/`, so a reader decodes the JSON and never compares its bytes.

### HTTP event injection

Another process can fire an event at every open page through `/__live/inject`, for example with curl:

```
curl "http://127.0.0.1:8000/__live/inject?event=scroll&data=%7B%22line%22%3A42%7D"
```

[markdown-preview.nvim](https://github.com/selimacerbas/markdown-preview.nvim) uses it for cross-instance scroll sync. On a server started with a token, add `&t=<token>`; which requests the route serves is stated in the section above.

### Token auth (optional)

Set `token` (for example `util.random_token(16)`) and name the files that hold user content in `protected_paths`; the routes the token gates are listed above. Static assets (`index.html`, `style.css`, etc.) stay ungated because the browser bootstraps from them before any JS runs and cannot append query strings to tags it discovers itself.

Pass the token to the browser in the initial URL (`?t=<token>`): the injected client keeps it in `sessionStorage` and puts it on the event stream itself, while a caller's own `fetch`/`EventSource` calls append it.

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
