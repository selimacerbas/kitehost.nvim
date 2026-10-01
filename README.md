# live-server.nvim

A tiny, zero-dependency **local web server** for Neovim, written in pure Lua with `vim.uv`.
Start a server on any file or folder, auto-reload the browser on save, and quickly reopen existing ports.

* **Pure Lua**: no npm, no Python, no binaries.
* **Local by default**: binds to `127.0.0.1`; set `host = "0.0.0.0"` for network access, with a `token`, after reading [SECURITY.md](SECURITY.md).
* **SSE live-reload**: instant page refresh on file changes (debounced).
* **CSS hot-inject**: stylesheet changes apply instantly without a full page reload.
* **Directory listing**: clean index when no `index.html` exists.
* **Telescope UX**: pick a path (file or directory) and a port from a friendly picker.
* **Which-key friendly**: group label in `init`, real mappings in `keys`, no conflicts.
* **Same-port retargeting**: starting on the same port updates the served root/index (reuses the same browser tab/URL).
* **Auto-start**: optionally start a server when you open an HTML file.
* **Statusline**: show active servers in your statusline/lualine.

> This plugin binds to `127.0.0.1` by default. Set `host = "0.0.0.0"` to make it accessible from other machines on the network: anyone who can reach the port then reads every file the server serves, so set `token` and read [SECURITY.md](SECURITY.md) first.

---

## Requirements

* Neovim **0.10+** (on Neovim 0.8 or 0.9, pin the plugin to v1.5.0, the last release that runs there, which receives no fixes and keeps every hole the CHANGELOG's Security entries after it close; the two holes its own Security notes name, the path-normalization bypass of the token gate and the event stream's fixed `Access-Control-Allow-Origin: *`, it closed itself).
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
  host             = "127.0.0.1",    -- bind address, an IP address or "localhost"; "0.0.0.0" = all interfaces (network access)
  token            = nil,            -- optional: require ?t=<token> on /__live/events, /__live/inject and protected_paths matches but /__live/script.js (and on /__live/asset, which only a caller of server.start() that passes asset_root enables)
  protected_paths  = {},             -- Lua patterns of request paths that also require the token; /__live/script.js, the injected client, never does; a non-empty list needs `token`; spell a name as the disk does (a hard link is not gated); a start refuses a pattern the rules below the start-key table refuse (write `^.*` in front of an unanchored one, `%-` for a hyphen)
  allowed_hosts    = nil,            -- more Host names a loopback bind answers besides localhost, *.localhost and loopback addresses; true turns the check off
  serve_dotfiles   = false,          -- serve .env, .git/ and other dot paths (default: 404; `/.well-known/` at the root is served)
  open_on_start    = true,           -- open browser after start/retarget
  notify           = true,           -- informational notices (start, retarget, stop, reload toggle); warnings and errors always show
  notify_on_reload = false,          -- notify on every live-reload event, its own switch, which notify = false leaves as it is
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

`live_reload` and `directory_listing` also take `true` or `false`, which turns the section on or off and keeps its other fields. `setup()` refuses a section of any other type, a flag that is not `true` or `false` and a key it does not read, naming it (`live_reload.enabled must be true or false, got string`; `open_on_start`, `notify` and `serve_dotfiles` the same way; `auto_start` must be a table or `false`; a misspelled key reads `setup does not read the key live_reload.debounc`), and keeps the options it had. It checks the table's own keys alone: a key a metatable supplies through `__index` is never refused, and is read or not as the merge reaches it (a whole `auto_start` table is read through it), so give it a plain table. A value the server refuses is named by the server's own key when a start fails (`live.debounce` for `live_reload.debounce`).

---

## Features

### CSS hot-inject

When `css_inject` is enabled (default), editing a `.css` file triggers an instant stylesheet swap in the browser: no full page reload, no DOM state lost. All other file changes still trigger a full reload.
A change under a dot path (`.env`, `.git/`) pushes no reload unless `serve_dotfiles` is set, nor does one under an entry named `__live` at the root in any letter case, the file you started on excepted, and `.liveignore` patterns match the path relative to the served root.

### Auto-start

Set `auto_start` to automatically start a server when you open a matching filetype:

```lua
auto_start = { filetypes = { "html" }, port = 8000 }
```

The server starts once per directory: opening another HTML file in the same folder won't spawn a duplicate. Opening a matching file in a folder no running server serves starts one on `port` (`default_port` when unset) or, when a server already runs on that port, retargets it to that folder, so the root follows the files you open; with `host = "0.0.0.0"` it is the network-reachable root that moves. A new file not yet on disk starts nothing, and writing it does not either; `:edit` it once it is written. In a folder that is on disk and that no running server serves, the notice reads `Path not found`; in a folder not yet on disk, or one a running server already serves, no notice shows. A start that fails, a taken port among them, lets the file open and shows its notice after it. Each entry of `filetypes` is a filetype name (letters, digits, `_`, `.` and `-`); `"*"`, a `+`, an empty string or a comma is refused. A later `filetypes` list replaces the earlier one whole, and a later `setup()` that names none keeps it.

### `.liveignore`

Create a `.liveignore` file in your served root to skip file-watcher noise. One pattern per line, `*` as wildcard (a run of `*` matches as one `*` does), `#` for comments:

```
# Don't reload on these
node_modules
*.log
dist
```

A line starting with `/` is anchored at the served root: `/dist` skips `dist/` and not `sub/dist/`. A line's text between its stars is found in the changed path in order, with no backtracking. A rule line holding a NUL byte matches no path and is skipped, with one warning naming the first such line; a comment holding one stays a comment. A dot path such as `.git/` needs no line: a change under one pushes no reload unless `serve_dotfiles` is set.

### CORS

Enable cross-origin headers on the root route's successful answers; a 401, 404 or 400 carries none, so a listed origin reads an error as a CORS failure:

```lua
cors = true,                         -- Access-Control-Allow-Origin: *
cors = "http://localhost:3000",      -- specific origin
cors = { "http://localhost:3000", "http://localhost:5173" }, -- a listed Origin is echoed, with Vary: Origin
```

`cors` lets the named origins (every website, with `true`) read every file the root route serves; with a list, a request from an origin it does not name gets no CORS header; one origin string is sent on every answer, and only that origin may read it. The live endpoints (`/__live/*`), the event stream and the asset route among them, never carry an `Access-Control-Allow-Origin` header, not even one set in `headers`, so no other site reads them. Another `Access-Control-` header set in `headers` (`Access-Control-Allow-Credentials`, say) is not held back the same way: it reaches the event stream, the asset route and the files and listings the root route serves, and not the injected client, the inject endpoint or an error answer. Write an origin as a browser sends it: any other spelling a browser never sends (an upper-case letter, a path, a default port) is refused at start, naming it; write an IP address in its usual form (127.0.0.1, not 127.1), which start does not check. A page under a name `allowed_hosts` lists is the server's own origin once that name points at this machine, and `cors` does not govern what it reads. Leave `cors` off unless a page on another origin must fetch these files.

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

* **Local by default**: binds to `127.0.0.1`. Set `host = "0.0.0.0"` in your setup opts to expose over the network (e.g. when SSH-ing in and viewing on another machine). **Be deliberate about this**: every file under the served root, except a dot path (unless `serve_dotfiles` is set) and an entry named `__live` at the root in any letter case (the file you started on is served at `/` even then), becomes readable by anyone who can reach the port, and so does the directory listing, which names protected files too; traffic is plain unencrypted HTTP, and without `token` the `/__live/inject` control endpoint is open too. Set `token` (and `protected_paths` for sensitive files) when binding beyond loopback, or prefer an SSH tunnel (`ssh -L 8000:localhost:8000 <host>`), which needs no config at all.
* **Path safety**: requests are realpath-checked to prevent escaping the served root.
* **Host check**: on a loopback bind (`127.0.0.1`, `::1`) a request whose `Host` is not `localhost`, a `*.localhost` name or a loopback address gets `421 Misdirected Request`, so a DNS-rebinding page cannot read the server; the port is never compared, so an `ssh -L` tunnel works. Add your own names with `allowed_hosts`. A network bind (`0.0.0.0`, a LAN address) has no Host check; set `token` there.
* **Index resolution**: root directory → `default_index` (if starting from a file) → `index_names` in order → directory listing. Subdirectories always use their own index files.
* **Port 0 (OS-assigned)**: pass `port = 0` to let the OS pick a free port. The actual port is available via `inst.port` after `server.start()`.
* **Same port, new path**: reusing the same port retargets the server → same URL, so browsers typically reuse the same tab.
* **Event injection**: `GET /__live/inject?event=<type>&data=<json>` lets external processes broadcast SSE events to connected clients. A browser request from another site, or from another port of the same host, is refused (403) by its `Sec-Fetch-Site` or `Origin` header, on loopback binds too; a request that sends neither, such as curl's, is served on a loopback bind, so set `token` when other programs on this machine must not inject. A browser sends no Fetch Metadata to a plain-http LAN address (an `Origin` still rides on a cors fetch and a WebSocket handshake), so a network bind without a `token` (and a loopback bind reached by an `allowed_hosts` name) fires events only for a request that sends `Sec-Fetch-Site: same-origin` or `none` (a typed URL, which no page can send); an `Origin` refuses a request from another origin and admits none, because a page's own `Origin` rides on its WebSocket handshake, so the token is that bind's boundary.
* **Graceful exit**: all servers are automatically stopped on `VimLeavePre`.

---

## Troubleshooting

* **"LiveServer 8000 did not start: Failed to bind 127.0.0.1:8000: EADDRINUSE: address already in use"**
  Another program holds that port. A start is refused the same way, its message carrying `EADDRINUSE: address already in use`, when a `127.0.0.1` bind meets a program on the port at `0.0.0.0`, or a `0.0.0.0` bind meets one at `127.0.0.1`. Pick a different port, or stop the other program; `:LiveServerStop` or `:LiveServerStopAll` stops a server of this plugin. The notice shows even with `notify = false`.

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

Versions follow SemVer, and the promise covers what a configuration and a plugin rely on: the `setup()` options as the Options block documents them, the `:LiveServer*` commands, the functions above and the plugin-author section below; a release that breaks any of it is a major release, while the wording of a notice, the statusline's text and anything these do not name may change in any release. A new option comes with a `server.features` flag (`require("live_server.server").features`, below), which a configuration shared across installs checks before it sets the option, since `setup()` refuses an option it does not read; an option is removed only in a major release. The options added in the release that followed v1.5.0 are the exception: `allowed_hosts` comes with `host_check` and `serve_dotfiles` with no flag; v1.5.0 ignored an option it did not read, so a configuration may set them there.

### Server-level API (for plugin authors)

Everything this section names is the public API that SemVer covers: the calls and what they answer, the `start` keys, the two instance fields, the capability flags, the HTTP routes with their gating and refusals, and the event framing. A release that breaks any of it is a major release. A new `start` key comes with a `server.features` flag, which a plugin checks before it sets the key, since `start` refuses a key it does not read; a key is removed only in a major release. The keys added in the release that followed v1.5.0 are the exception: `allowed_hosts` comes with `host_check`, and `serve_dotfiles`, `header_timeout_ms`, `max_connections` and `sse_heartbeat_ms` with no flag; v1.5.0 ignored a key it did not read, so a plugin may set them there. Anything of the two modules that this section does not name is internal and may change in any release, including every other field of the instance table (the event-stream list `sse_clients` among them: read `server.connected_client_count(inst)`), and the wording of a message, except the `EADDRINUSE` text below. One reservation: a minor release may refuse a request the server admits today when refusing it closes a security hole; the requests this section lists as admitted stay admitted where it admits them (a request with the right token, a request marked same-origin with no foreign `Origin`, and an unmarked request under a loopback name on a loopback bind). A minor release may also change how a method other than GET is answered (a `HEAD` and the `cors` preflight's answer, which the request order below states as it is today, among them, and the `Allow` field), how a request line naming `HTTP/1.2` to `HTTP/1.9` is answered, the 64 KiB cap on a request head, and the 8 KiB cap on a request target, which bounds the path every `protected_paths` pattern is matched against and so the time a request without the token costs the editor (below the table).

Below Neovim 0.10, `require("live_server.server")` and `require("live_server.util")` raise the floor message, on every `require`, so a plugin that also runs on an older Neovim loads them under `pcall`.

```lua
local server = require("live_server.server")
local util   = require("live_server.util")

local ok, inst = pcall(server.start, {
  root = "/path",                         -- required: the served directory
  port = 0,                               -- required: 0 = OS-assigned; the bound port is inst.port
  host = "127.0.0.1",                     -- an IP address, or "localhost", which binds 127.0.0.1
  default_index = nil,                    -- file served for "/"; a relative path is joined to the working directory at start
  index_names = { "index.html", "index.htm" }, -- file names tried in a directory, in order
  headers = {},                           -- extra response headers, each value a string
  cors = false,                           -- true (any origin), an origin, or a list of origins; root route only
  token = util.random_token(16),          -- example; omitted: no token; a non-empty UTF-8 string gates the routes below
  protected_paths = { "^/content%.md$" }, -- example; omitted: none; Lua patterns that also need ?t=<token>; a token is required
  asset_root = nil,                       -- a directory, or a function returning one, for /__live/asset
  allowed_hosts = nil,                    -- more Host names a loopback bind answers; true turns the check off
  serve_dotfiles = false,                 -- serve dot-segment paths (.env, .git/) on the root route
  notify_on_reload = false,               -- a notice on every reload
  header_timeout_ms = 10000,              -- close a connection whose request head has not arrived by then; 0 = off
  max_connections = 64,                   -- close a connection accepted while this many are open
  sse_heartbeat_ms = 20000,               -- ": ping" on every event stream; 0 = off
  live = { enabled = true, inject_script = true, debounce = 120, css_inject = true }, -- omitted: no watcher, no script
  features = { dirlist = { enabled = true, show_hidden = false } }, -- omitted: directories are listed
})
```

`root` and `port` are required: `start` refuses a table without either. Every other key may be left out, and the value shown is what leaving it out means, but for `token` and `protected_paths`, marked as examples, and `live`, whose comment says what leaving it out means. `live` left out starts no watcher and injects no script; `live = {}` turns both on, each of its fields taking the value shown, and a field given replaces its value alone. `features` left out lists a directory that has no index file; `show_hidden` needs `serve_dotfiles`, since a listing names no dot entry while that is off. `start` reads the table's own keys when it looks for a key it does not read (below): a key a metatable supplies through `__index` is read when it is one of the keys below and is never refused, a misspelled one included, so give it a plain table.

Each key takes the values below, and `start` refuses any other, naming the key; it also refuses a key it does not read (`start does not read the key live.debounc`, a misspelled key among them) and a string holding a NUL byte (`root holds a NUL byte`, and so for `host`, `token`, `default_index`, `asset_root`, an `index_names` entry, a `protected_paths` pattern and a `headers` name or value; a `cors` origin or an `allowed_hosts` entry holding one is refused by its own rule):

| Key | Takes | Left out | Refused besides another type |
| --- | --- | --- | --- |
| `root` | a path | required | a path that does not resolve or is not a directory |
| `port` | an integer from 0 to 65535 | required | a fraction, a number out of range, a numeric string |
| `host` | an IP address (IPv6 without brackets, a `%zone` of letters, digits, `.`, `_` and `-` after it allowed, not checked against the interfaces: on macOS a zoned link-local bind starts and answers no request; on Windows write the zone as the interface's number (`"::1%1"`), since a name there such as `Loopback Pseudo-Interface 1` holds spaces; `inst.host` carries no zone, nor does any URL the plugin opens, one built from `setup()`'s `host` included) or `"localhost"` | `"127.0.0.1"` | a name, `""`, `"[::1]"`, `"LOCALHOST"`, `"::1%"`, a zone holding any other byte (`"::1%a%b"`, `"::1%Loopback Pseudo-Interface 1"`), a dotted quad with a leading zero (`"127.000.0.1"`) |
| `default_index` | a path; a relative one is joined to the working directory at start, and a path is absolute by the OS's rule (on macOS and Linux a leading `/` alone, so `C:/i.html` and `\i.html` are relative there) | none | `""` |
| `index_names` | a list of file names | `{ "index.html", "index.htm" }` | a map, an empty name, a name holding `/` or `\`, `.`, `..` |
| `headers` | a map of names to strings | `{}` | `false`, a name that is no token, a value holding a control byte but a tab, `Content-Type`, `Content-Length`, `Transfer-Encoding`, `Connection`, one name spelled two ways |
| `cors` | `true`, `"*"`, an origin or a list of origins | `false` | a map, an origin a browser would not send (an upper-case letter, a `%`, a path, a default port, a port of zero, with a leading zero or over 65535), `"*"` in a list; an address form such as `127.1` is not checked |
| `token` | a non-empty UTF-8 string | none | `""`, `false`, invalid UTF-8 |
| `protected_paths` | a list of Lua patterns, each read as LuaJIT's `string.find` reads it, so one holding none of `^$*+?.([%-` is plain text (`/draft)` gates every path holding `/draft)`), and a `-` repeats the item before it, so a name's hyphen is written `%-` (`vim.pesc(name)` escapes a whole name) | `{}` | a map, a malformed pattern (the message names the byte where it fails and shows the pattern around it, at most 40 bytes each side), a pattern the cost rules below the table refuse, a `-` between two letters or digits, a non-empty list without `token` |
| `asset_root` | a directory, or a function answering one | none | a path that names no directory or lies inside a credential directory (`.git`, `.ssh`, `.aws`, `.kube`, `.docker`, `.gnupg`, in any letter case) |
| `allowed_hosts` | `true` or a list of host names | none | `false`, a map, a list with holes, an empty name, a wildcard, a port, brackets, a spelling no `Host` carries |
| `serve_dotfiles`, `notify_on_reload` | `true` or `false` | `false` | |
| `header_timeout_ms`, `sse_heartbeat_ms` | milliseconds, an integer from 0 to 2147483647 | 10000, 20000 | a fraction, a number out of range |
| `max_connections` | an integer at or above 1 | 64 | a fraction, 0, `math.huge` |
| `live` | a table | no watcher, no script | `false` |
| `live.enabled`, `live.inject_script`, `live.css_inject` | `true` or `false` | `true` | |
| `live.debounce` | milliseconds, an integer from 0 to 2147483647 | 120 | a fraction, a number out of range |
| `features`, `features.dirlist` | a table | a directory is listed | `false` |
| `features.dirlist.enabled`, `features.dirlist.show_hidden` | `true` or `false` | `true`, `false` | |

A request without the token is matched against every `protected_paths` pattern on the editor's own loop, so `start` holds each pattern to rules that limit that cost and refuses one that breaks them, naming the byte and the cost (`protected_paths pattern is refused at byte 3 (an unbounded quantifier in a pattern not anchored with ^ tries every start position, so a request path costs the square of its length; write ^.* in front to keep the same matches): /.*%.md$`). A pattern is at most 256 bytes long and holds no balanced match (`%b`) and at most two `?` items. Its first unbounded quantifier (`*`, `+` or `-` after an item) needs the pattern to start with `^`, or with a literal that quantifier's item cannot match (`/[^/]*%.md$`), and each later one needs the character right before its item to be a literal the item cannot match (`^/[^/]*/[^/]*%.md$`, `/%.[^/]+%.%d+%.tmp$`), a capture's parenthesis aside. So `/.*%.md$` is refused and `^/.*%.md$`, which gates every path `/.*%.md$` gated, at any depth, is taken. In general a pattern `P` gates what `^.*P` gates, since a leading `.*` takes any prefix, so `^.*` in front keeps a refused pattern's matches (`^.*private/[^/]*$` for `private/[^/]*$`), where a bare `^` keeps only the paths it matched at their first byte (`^/secret/.*` leaves `/a/secret/x.txt` served); a `.*` at its end adds nothing either, so `/secret/.*` is written `^.*/secret/`. A `-` between two letters or digits is refused too, at that byte: it repeats the one before it and finds no hyphen (`^/my-notes%.md$` would gate `/mynotes.md` and serve `/my-notes.md` without the token), so write `%-` for a hyphen. A malformed pattern is named malformed first. Under these rules the costliest pattern found costs about 105 ms of CPU time for one request without the token whose path is 8 KiB long, the longest the 414 cap admits, on the Apple M2 laptop it was measured on, and about 170 ms when it holds a frontier (`%f`) whose set treats `/` and the path's end differently, which is read twice for a path naming a directory; `^/.*%.md$` costs about 0.1 ms. These are measurements, not a bound: the cost is per pattern and per request, so a long list and concurrent requests add up, and a request carrying the token runs no pattern.

`asset_root` given as a string must name a directory outside every credential directory when `start` runs, or `start` refuses it (`asset_root is not a directory: "<path>"`, with libuv's error name after it when the path does not resolve: `(ENOENT)`; `asset_root is inside a credential directory (<name>): "<path>"`). `start` keeps the string, a relative one joined to the working directory then, and the real path it resolves to, so a later `:cd` is not followed. On every asset request that string is resolved again and must name that real path and a directory: when it resolves elsewhere (a link given as `asset_root` and pointed elsewhere after start, or a link put at its path), no longer resolves or no longer names a directory, the route answers 404 and warns (described below); a directory put at that same path, or a tree rebuilt at any directory above it, is served. A function is not called at `start`: it is called on every asset request, so it may name another directory while the server runs. It runs inside the request's callback, a fast event where `vim.fn` and `vim.api` raise, so compute the directory outside it and close over the value, or read it with `vim.uv`. Its answer is held to the string's rule on every request: an absolute path (on macOS and Linux one starting with `/`, on Windows one starting with a separator or with a drive letter and a separator) naming a directory outside every credential directory is served from; nil gets a 404 with no word (no directory yet); anything else (a relative path, `C:/x` and `\x` on macOS and Linux among them, a path holding a NUL byte, a path that names no directory or lies in a credential directory, a number, a table, `false`) gets a 404 and a warning, and a raise gets a 404 and a warning too (described below).

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

A call made wrongly raises at level 2, so the message names the calling line: `reload` with a path that is neither a string nor nil, `send_event` with a name that is not a string, a payload that is neither a string nor nil or a name holding a line break, `enable_live` with a flag that is not a boolean, `update_target` with a root that is not a string, an index that is neither a string nor nil, a root or index holding a NUL byte, an empty index (`update_target: index is empty`) or, on a running server, a root it cannot serve (one that does not resolve or is not a directory), changing nothing, and `util.random_token` with a length outside 1 to 1024. The instance argument is not checked: given nil, or a table `start` did not return, a call raises, its message naming a line of the module or of the Neovim function it calls rather than the caller's (`send_event`, `reload` and `stop` given `{}` name a line of Neovim's own runtime), or returns; a stopped instance is taken, and a call on it changes nothing. `util.random_token` also raises when the OS offers no random source.

On a running server, a relative `update_target` index is joined to the working directory at the call, by the same rule as `default_index` at start. On a stopped server `update_target` returns false without checking that the root resolves. On a running one it returns true when the server serves the root asked, whether it moved or was already that root, and false with the cause when live reload is on and the new root cannot be watched (the root moves and live reload turns off). `enable_live(inst, true)` returns true, or false with the cause when the watcher cannot start, and live reload stays off; `enable_live(inst, false)` returns false, as does `enable_live` on a stopped server. `inject_script` and `css_inject` are fixed at start from `live`: on a server started without `live`, `enable_live(inst, true)` watches files and sends reload events, but its pages load no client script, so no page reloads. A watch that misses some directories under the root keeps live reload on and says so (a notice, described below, outside the promise).

`util.secure_compare(a, b)` returns false at once for a non-string or a length difference; for two strings of one length, its time does not depend on where they differ.

`server.wildcard_loopback(ip)` answers `"127.0.0.1"` for `"0.0.0.0"`, `"::1"` for `"::"` and nil for any other address; a plugin calls it to show the address a wildcard bind's URL names, as this plugin's own URL does. Replacing it is not supported: `start` reads it through the module table, which every plugin in the process shares, so one plugin's replacement would move every other plugin's probe and URL.

Outside the promise, for a person reading the notices: their text and how often they repeat may change in any release. A server tells the user of a fault through `vim.notify`, each line starting `live-server: port <n>`, and shows a control byte, a C1 code, a line or paragraph separator (U+2028, U+2029) or a bidi control from a path or a name as `?`. A warning is sent once per server for each kind: a listener that stopped accepting connections, a connection it could not serve, a connection it could not read, a reload it could not schedule or cancel, a root it could not watch (sent again after a watcher starts), a directory under the root it could not watch (sent once per watch start that misses one, on the per-directory watcher Linux uses), a `.liveignore` it ignores or a line of it skipped for a NUL byte (sent again after `update_target` moves to a new root), a `protected_paths` pattern it could not read, and an `asset_root` function that raised (its first line, at most 300 bytes) or answered what it may not serve from (the answer or its type, at most 300 bytes), and a string `asset_root` that no longer resolves to the directory kept at start, one kind for the three, the request answered 404 each time; after a request whose asset root resolves, the next such fault warns again (a function answering nil neither warns nor counts). A loopback bind started with `allowed_hosts = true` warns that the Host check is off. A request whose handling raised is answered with a 500 (or its connection closed, when the response had begun) and an error notice naming the path and the cause, once per such request. With `notify_on_reload`, each reload is a notice of its own (`live-server: port <n> reload → <path>`).

`server.features` holds the flags a plugin checks before it relies on a capability: `token_auth` (the `token` option and the gated routes), `host_binding` (the `host` option), `asset_route` (`asset_root` and `/__live/asset`), `host_check` (a loopback bind answers only loopback Host names and the `allowed_hosts` names, 421 otherwise), `cors_list` (`cors` takes a list of origins; an install without it reads a list as `"*"`) and `start_raises` (`start` raises at level 0 when it cannot serve).

The HTTP surface is part of the same promise, and a request is checked in this order. A head the server cannot read is 400 first, on every bind: a request whose first byte, after any empty lines, is no upper-case letter, answered as soon as that byte arrives (a TLS handshake sent to the plain port among them), a request line whose version is not `HTTP/1.` and one digit (`HTTP/1.2` to `HTTP/1.9` are answered as 1.1), a method that is not upper-case letters alone (`GEt`, `M-SEARCH`), two spaces in a row in the request line, a header line without a colon, a header name that is no token (`X-A : 1`), a CR or a NUL in a header value, an HTTP/1.1 request without `Host`, two `Host`, `Origin`, `Sec-Fetch-Site` or `Sec-Fetch-Mode` lines, a target that is neither a path nor an `http://` URL, and a `Host` that is not a host: a `%` not followed by two hex digits, an empty label, userinfo, a space, a port that is not digits, brackets around what is no IPv6 address, or an IPv6 address without brackets, with a port or without one (`Host: ::1:8421` and `Host: ::1` are 400; a client sends `Host: [::1]:8421`). A head over 64 KiB is 431. Then, once the head has arrived (the 64 KiB cap and `header_timeout_ms` bound that wait), a target longer than 8 KiB (8192 bytes), its query included, is 414 (`URI Too Long`, the connection closed): the request line is read before any header field, so of the 400s above only the first byte's and those for the request line's method, version and spaces come before it, and the target's form, every header field, the Host check, the token gate and every `protected_paths` pattern come after. Next, on a loopback bind, a request whose Host line is neither a loopback name nor an `allowed_hosts` entry is 421 on every route, unless `allowed_hosts = true`; a request with no Host line (HTTP/1.0) is served. A target in absolute form (`GET http://127.0.0.1:8421/page.html`) is served by its path, and its authority is checked in place of `Host`. Then a malformed path is 400 and a dot path the server refuses is 404. A method other than GET on `/__live`, `/__live/`, any path whose first segment is `__live` in any letter case (`/__LIVE/x.txt`) that is none of the four routes below, or a path whose file resolves into an entry named `__live` at the root through a link elsewhere in the root (`link.txt` pointing at `__live/x.txt`) is 404 before the method check, so a preflight there gets no origin line; on any other path a method other than GET is 405, but with `cors` set the root route answers a preflight (an `OPTIONS` carrying `Access-Control-Request-Method`) with a 204 and no body, before the token gate: the origin line `cors` gives (none for an `Origin` a list does not name), `Access-Control-Allow-Methods: GET`, the names `Access-Control-Request-Headers` asks for in `Access-Control-Allow-Headers` when each is a token, `Access-Control-Max-Age: 600` and `Vary: Access-Control-Request-Headers` (after `Origin`, under a list). The token gate comes next (below). After it, a GET for `/__live`, `/__live/` or a path under `/__live/` that is none of the four routes is 404 and reads no disk; that match is exact, so `/__LIVE/x.txt` is no route and goes to the root route, which refuses it by the rule that follows. The entry behind the namespace is an entry named `__live` at the root, in any letter case (`__LIVE`, `__Live`): the root route answers 404, with no origin line, to every request whose first segment is such a name, whatever the entry is (a file, a directory, a link to anything), and to every request whose file resolves into such an entry through a link elsewhere in the root, but for the file the server was started on, which is served at `/` and by no other path; a hard link elsewhere in the root to a file in the entry is a separate name, which the rule cannot see, and is served; a listing does not name the entry; and an index file that resolves into such a directory is not its directory's index, so the next index name or the listing answers. An entry named `__live` below the root (`sub/__live/`) is ordinary. The asset route serves what `asset_root` covers, such a directory included, gated by the token and never with an `Access-Control-Allow-Origin` header.

- `/__live/events[?t=<token>]`: a `text/event-stream` that starts with `retry: 1000`, then one frame per event, `event: <name>` and one `data:` line per payload line, and a `: ping` comment line as a heartbeat. A reader joins a frame's `data:` lines with line breaks, as the browser's `EventSource` does; one that reads a single `data:` line reads only the first line of a payload. A frame with an empty name (`send_event(inst, "")`, or `event=` sent empty to the inject route) reaches an `EventSource` as a `message` event. A stream that falls behind is dropped at the first event or heartbeat that finds it more than 1 MiB behind over a second after an earlier send found it so, or at any send that finds it more than 8 MiB behind; a send that finds it at 1 MiB or less starts the second afresh. Its connection closes, it misses every event until its reader reconnects (`EventSource` does, after `retry`), and a reader that keeps up is not dropped for one large event or a burst that stays within 8 MiB. The second is loop time, which runs on while the editor is blocked, so a send right after a block longer than a second can drop a reader that keeps up.
- `/__live/inject?event=<name>[&data=<url-encoded>][&t=<token>]`: broadcasts one event to every stream and answers 200. `data` is URL-decoded, a `+` read as a space, and defaults to `{}`; `event` is taken as sent, not decoded, and a request without it answers 200 and sends nothing, while `event=` sent empty sends a frame with an empty name. A browser request from another site (its `Sec-Fetch-Site`, or an `Origin` naming another origin) is 403, and one marked `Sec-Fetch-Site: same-origin` or `none` is served unless it also carries an `Origin` naming another origin, which refuses it (403). The reservation above applies to these rules. A request no browser marked as same-origin (no `Sec-Fetch-Site: same-origin` or `none`; curl's among them) is served on a server with a token, and without one only on a loopback bind reached under a loopback name (`localhost`, a `*.localhost` name or a loopback address) or with no Host line, which no browser sends; under an `allowed_hosts` name or on a network bind it is 403. A push whose target, the encoded `data` included, is longer than 8 KiB is 414 (above); `server.send_event` in the editor has no such bound.
- `/__live/asset?p=<relative path>[&t=<token>]`: a regular file under `asset_root`, 404 when none is set. It answers 404 for a path that is absolute or holds a `:`, a backslash or a NUL, a path whose real path leaves `asset_root`, anything but a regular file, an `asset_root` inside a credential directory, and a name on its deny list: credential files by name (`.env`, `.env.*`, `.npmrc`, `.netrc`, `id_rsa` and the like), key and certificate files by extension (`*.pem`, `*.key`, `*.p12` and the like) and any path through `.git`, `.ssh`, `.aws`, `.kube`, `.docker` or `.gnupg`. The dot rule and `serve_dotfiles` do not apply here: any other file, a dot file included (`.images/logo.png`, `.bash_history`), is served. The deny list is a list of names, not a promise that nothing secret is served; point `asset_root` at a directory that holds only what a page may show. An HTML, SVG or XML file (by its extension: `html`, `htm`, `xhtml`, `svg`, `xml`) is sent with a `sandbox` directive in `Content-Security-Policy` (after any policy set in `headers`), so it runs no script in the server's origin; the root route never adds that directive.
- `/__live/script.js`: the injected client, never gated.

With `token` set, `/__live/events`, `/__live/inject`, `/__live/asset` and every path a `protected_paths` pattern matches (`/__live/script.js` excepted) need the query token `t`, URL-decoded with a `+` read as a space; a request without it or with another answers 401. Without `token`, no route needs it. The token is compared first: a request carrying it runs no pattern, since the token opens every gated path. A request without it is matched against every pattern, at the cost stated below the start-key table, each pattern read once for each name the request reaches: the request path, normalized, and the file's path under the root as the disk spells its name, where that is another string (a link, another letter case), and a directory asked without its slash once more, with its slash, a read the OS's path limit bounds since only an existing directory reaches it. Should reading a pattern raise (LuaJIT's `pattern too complex`), that request is answered 401 and the server warns once, naming the pattern; a request with the token is still served. On a case-insensitive file system, a pattern cased otherwise than the name on disk gates only the spellings it matches, and a request in the disk's spelling is served without the token. A hard link to a protected file under another name is not gated.

The `reload` event's data is JSON, `{"ts":<seconds>,"path":<string>,"css":<boolean>}`, its keys always in that order. `path` is `""` for `server.reload(inst)`, the string a caller gave `server.reload`, or, for a watched change, the changed file's path relative to the root, slash-separated with no leading slash (`/` for the root itself, and for the file the server was started on when it sits on a dot path or in the `__live` entry at the root). The watcher sends no reload for a change under a dot path while `serve_dotfiles` is off, nor for one under the `__live` entry at the root in any letter case, whatever `serve_dotfiles` says, the file the server was started on excepted in both; nor for a change a line of the root's `.liveignore` matches, that file included. On Linux, where each directory is watched on its own, a directory named `node_modules` that is there when the watch starts is not watched, nor anything under it, so a change there sends no reload; one made later is watched. A debounce window that held several changes names its latest file that is still on disk and is not a stylesheet (a name ending in `.css`), else its latest stylesheet; when none is left on disk it names its latest path, with `css` false. `css` is true only when `css_inject` is on and the path names a stylesheet, which the page swaps in place of a reload. Neovim 0.10 writes a slash as `\/`, so a reader decodes the JSON and never compares its bytes.

### HTTP event injection

Another process can fire an event at every open page through `/__live/inject`, for example with curl:

```
curl "http://127.0.0.1:8000/__live/inject?event=scroll&data=%7B%22line%22%3A42%7D"
```

[markdown-preview.nvim](https://github.com/selimacerbas/markdown-preview.nvim) uses it for cross-instance scroll sync. On a server started with a token, add `&t=<token>`; which requests the route serves is stated in the section above.

### Token auth (optional)

Set `token` (for example `util.random_token(16)`) and name the files that hold user content in `protected_paths`; the routes the token gates are listed above. Spell each name in a pattern as the disk spells it: on a case-insensitive file system (macOS's default), `^/CONTENT%.MD$` gates `/CONTENT.MD` while `/content.md` reaches the same file without the token, and a hard link to a protected file under another name is not gated. Static assets (`index.html`, `style.css`, etc.) stay ungated because the browser bootstraps from them before any JS runs and cannot append query strings to tags it discovers itself.

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
