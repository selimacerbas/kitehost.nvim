# Changelog

All notable changes to this project; versions follow SemVer. From `[Unreleased]` on, the format follows Keep a Changelog. The sections below it are the release notes as published on GitHub, with their headings moved one level down and the em dash written as a colon.

## [Unreleased]

### Upgrading from v1.5.0 (plugin authors)

- Call `server.start` under `pcall`: it raises when it cannot serve: an option it refuses, a root that is not a directory, a host this machine does not have (`EADDRNOTAVAIL`), a port another socket holds (`EADDRINUSE`), a failed listen; for the last three it used to return a server that was not listening where asked. `server.features.start_raises` says so, and a plugin may match the text `EADDRINUSE: address already in use` in the message to name the taken port.
- A flag passed to `server.start` (`notify_on_reload`, `live.enabled`, `live.inject_script`, `live.css_inject`, `features.dirlist.enabled`, `features.dirlist.show_hidden`) must be `true` or `false`, as must the new `serve_dotfiles`; `0` or `"no"` once read as on and is now refused. `live`, `features` and `features.dirlist` must be tables and `token` a non-empty string: `live = false` and `token = false` once read as off and now raise; use `live = { enabled = false }` and leave `token` unset.
- A loopback bind answers `421` to a `Host` that is not `localhost`, a `*.localhost` name or a loopback address, and every bind answers `400` to a `Host` that is not a host. A client that connects by another name lists it in `allowed_hosts`; `server.features.host_check` says the check is there.
- A plugin that sends its own requests brackets an IPv6 host in `Host`: `Host: [::1]:8421`. The unbracketed `Host: ::1:8421`, which formatting `"%s:%d"` with `host = "::1"` builds, is `400`.
- `/__live/inject` answers `403` to a browser request its `Sec-Fetch-Site` or `Origin` marks as another site's, and an `Origin` naming another origin refuses a request that `Sec-Fetch-Site` marks as same-origin. A request that carries neither header is served with the token, and without a `token` only on a loopback bind reached under a loopback name: a network bind without a `token` refuses it, since a browser sends neither header to a plain-http LAN address, so a plugin that serves on a network bind sets `token`. gh-markdown-preview.nvim's page, opened from a LAN address on a network bind without a `token`, is refused there; a start with `token` admits it.
- The reload event's data is JSON: decode it, never compare its bytes. A reader of the event stream joins a frame's `data:` lines with line breaks, as `EventSource` does.
- `host = "localhost"` binds `127.0.0.1`, and `inst.host` reads `"127.0.0.1"`.
- Outside Linux, a start on a port another program listens on at the wildcard address, or a wildcard start on one held at the loopback address, raises `EADDRINUSE` as a start on the same address now does everywhere; on macOS it used to share the port with that program.
- `inst.sse_clients` is internal; read `server.connected_client_count(inst)`.
- The README's plugin-author section and `:help live-server-server-api` name the server API that SemVer covers; anything they do not name may change in any release.

### Added

- `server.start` options `allowed_hosts`, `serve_dotfiles`, `header_timeout_ms` (default 10000, 0 turns it off), `max_connections` (default 64) and `sse_heartbeat_ms` (default 20000, 0 turns it off); `setup()` takes the first two.
- `cors` accepts a list of origins and echoes a listed request `Origin`, with `Vary: Origin`; an unlisted `Origin` gets no origin line.
- `server.features.host_check`, `server.features.cors_list` and `server.features.start_raises`, for plugins that require the Host check, a `cors` list or a `start` that raises.
- `server.wildcard_loopback(ip)` answers the loopback address a wildcard bind's URL shows (`"127.0.0.1"` for `"0.0.0.0"`, `"::1"` for `"::"`); a plugin that replaces it moves the address `start` checks and the URL together.
- On a token server, the injected client takes the token from the page URL, keeps it in `sessionStorage` and warns once when the server refuses it, and the opened URL carries the token, so live reload works with `token` set.
- A `: ping` comment on every event stream every `sse_heartbeat_ms`.

### Changed

- `server.start` raises when the server cannot listen: a port another program holds (`EADDRINUSE`), an address this machine does not have (`EADDRNOTAVAIL`), a failed listen, or a reload or heartbeat timer it cannot make, and it leaves no socket, timer or watcher behind. It used to return a server that was not listening while the port kept answering from the other program, or, for an address this machine lacks, one listening on every interface. Call it under `pcall`.
- `server.start` checks every option before it opens a socket and refuses, naming it:
  - a configuration that is not a table;
  - a `root` that is not a string, does not resolve or is not a directory;
  - a `host` that is not a string;
  - a `port` that is not an integer from 0 to 65535, a numeric string included;
  - a `token` that is not a non-empty UTF-8 string, `token = false` included;
  - an `allowed_hosts` that is neither `true` nor a list of host names: a map, a list with holes, or an entry with a port, brackets, a wildcard or a spelling no `Host` carries;
  - a `protected_paths` that is not a list of Lua patterns, or a non-empty one without a `token`;
  - an `index_names` that is not a list of file names;
  - a `default_index` that is not a string;
  - a `live`, `features` or `features.dirlist` that is not a table, `false` included;
  - a flag that is not `true` or `false`;
  - a `headers` name that is not a token, a value that is not a string or holds a control byte other than a tab, a field the server computes (`Content-Type`, `Content-Length`, `Transfer-Encoding`, `Connection`), or two spellings of one name;
  - a `cors` origin spelled as no browser sends it (an upper-case letter, a `%`, a path, a default port, or a port of zero, with a leading zero or over 65535), or a `"*"` entry in a list;
  - an `asset_root` that is neither a string nor a function;
  - a `live.debounce`, `header_timeout_ms` or `sse_heartbeat_ms` outside 0 to 2147483647;
  - a `max_connections` below 1.
- A start that fails shows `LiveServer did not start: <cause>`; the `Failed to bind port` prefix is gone.
- A `port = 0` start takes another port when the one the OS chose is held by another program on the wildcard address.
- A root that cannot be watched is served with live reload off and one warning, and `is_live_enabled` reports `false`; a watch on Linux that misses some directories under the root keeps live reload on and names the first one missed and how many.
- A server tells the user of a fault once per kind, naming its port: a listener that stopped accepting connections, a connection it could not serve or read, a reload it could not schedule, a root or directory it could not watch, a `.liveignore` it ignores, and a `protected_paths` pattern it could not read; a start that raises leaves no warning behind.
- The start notice prints the URL the plugin opens, token included, with `0.0.0.0` shown as `127.0.0.1` and `::` as `[::1]`; the notice for a browser that did not open names the URL with the token's value left out.
- A request is read to the end of its head (64 KiB at most, then `431`). An HTTP/1.1 request without `Host`, a request with two `Host` lines or with a `Host` that is not a host (an unbracketed IPv6 address with a port, brackets around what is no IPv6 address, a `%` not followed by two hex digits, an empty label, userinfo, a space, a port that is not digits), a request with two `Origin`, `Sec-Fetch-Site` or `Sec-Fetch-Mode` lines, or a request line without an HTTP/1.0 or 1.1 version is `400`, on every bind.
- A request for a file whose name holds a backslash, such as `a\b.txt` on Linux or macOS, is `400`; such a file is no longer served.
- The reload event's data is JSON written by `vim.json.encode`, `{"ts":<seconds>,"path":<string>,"css":<boolean>}`, keys in that order; Neovim 0.10 writes a slash as `\/`.
- `send_event` and `reload` raise at the caller for a name, payload or path that is not a string, and `send_event` for an event name holding a line break; a number payload was once sent as its digits.
- `update_target` raises at the caller for a root that is not a string or, on a running server, one it cannot serve, answers `true` for the root it serves and `false` with the cause when it cannot watch it; `enable_live` raises for a flag that is not a boolean; `is_live_enabled` answers `true` or `false`. A retarget the server refuses is shown as a notice.
- A change under a dot path pushes no reload unless `serve_dotfiles` is set, the file you started on excepted.
- `util.random_token` reads `vim.uv.random`, then `/dev/urandom`, and raises with neither, naming both causes; the `math.random` fallback is gone. Its length must be an integer from 1 to 1024.
- A `405` names `Allow: GET`; with `cors` set, a preflight on the root route is answered with `204`, echoing the requested headers.
- HTML is injected with the reload script only when a browser shows it (`Sec-Fetch-Mode: navigate`: a page, a frame, an object, an embed, a download) or when the client sends no `Sec-Fetch-Mode`, so HTML a page's own script fetches gets none; with `inject_script` on, every HTML page carries `Vary: Sec-Fetch-Mode`.
- `/__live/script.js`, the injected client, is never behind the token, even when a `protected_paths` pattern matches it.
- `setup()` reads `live_reload` or `directory_listing` given as `false` as off and `true` as on, refuses a section of any other type, a flag that is not `true` or `false` (`open_on_start`, `notify` and `serve_dotfiles` among them), an `auto_start` that is neither a table nor `false` and an `auto_start.filetypes` that is not a list of strings, naming the key, and keeps the options it had; `open_on_start = "no"` once opened the browser.
- `setup()` puts a header you give in place of its default under any spelling of the name, keeping your spelling and value.
- The picker titles read `LiveServer: Choose path` and `LiveServer: Pick file`.
- `vim.uv` replaces the deprecated `vim.loop` throughout.

### Removed

- **BREAKING:** Neovim 0.8 and 0.9 support (v1.5.0's README declared 0.8+). Below 0.10 the plugin shows one notification, "live-server.nvim requires Neovim 0.10 or newer; on Neovim 0.8 or 0.9 pin the plugin to v1.5.0", every command refuses with the same message, the statusline component shows nothing, and requiring `live_server.server` or `live_server.util` raises the message. To stay on Neovim 0.8 or 0.9, pin v1.5.0, the last release that runs there (`tag = "v1.5.0"` in a lazy.nvim spec); from the next release on, v1.5.0 receives no further fixes.

### Fixed

- When `vim.ui.open` finds no opener, the browser is opened with `open`, `xdg-open` or `start`, and a notification names the URL when that fails too; before, nothing opened and nothing said so.
- The exit hook that stops every server when Neovim quits joins the `LiveServerExit` augroup, so sourcing the plugin file again replaces it instead of adding a second.
- `host = "localhost"` binds `127.0.0.1` and the server reports that address; it raised "Invalid IP address or port".
- The opened URL brackets an IPv6 host (`host = "::1"` opens `http://[::1]:<port>/`), and an IPv4-mapped host (`::ffff:a.b.c.d`) is shown as the IPv4 address it answers on.
- A request line or header split across TCP reads is served as one request; a late chunk no longer puts a second response into a streaming body.
- An aborted download, a client that half-closes and `stop` no longer leak a descriptor or raise "handle is already closing"; a client that half-closes after its request reads the whole response, where a large file arrived cut short or with no body.
- `stop` closes every connection, event stream, timer and watcher, not only the listener, and a second `stop` does nothing; a connection that sends no complete head within `header_timeout_ms` is closed.
- A raise inside the request handler answers `500` and one error notice naming the path and the cause on one line; the connection used to stay open with no answer.
- `update_target` and `enable_live` on a stopped server return at once instead of opening a watcher nothing closed, and a stopped server reports live reload off.
- A changed path holding a tab or a line break no longer yields a reload payload the page cannot parse, which turned a stylesheet swap into a full page reload.
- A save of a page and a stylesheet within one debounce window reloads the page, which a stylesheet swap left stale; a stylesheet saved by Neovim's own `:w` or by a temp-and-rename save is still swapped in place.
- A `.liveignore` that is not a regular file is ignored with a warning; a FIFO there hung the editor, as a FIFO root did, and a root must now be a directory.
- A relative `default_index` is made absolute at start, so a later `:cd` no longer moves it out of the root.
- A directory's `index.html` that links outside the root is not served.
- A directory listing builds its links from the path, each segment encoded, never from the query, so a listing opened with `?t=` links by path alone.
- A `401` reads `401 Unauthorized`; it read `401 OK`.
- `inst.port` is the port the socket holds, and a `port` above 65535, whose low 16 bits libuv bound, is refused.
- A later `setup()` with `auto_start = false` or an empty filetype list disarms what an earlier call armed; the old autocmd stayed and raised at the next matching filetype.

### Security

- A loopback bind answers `421 Misdirected Request` to a request whose `Host` is not `localhost`, a `*.localhost` name or a loopback address, before the token gate: a DNS-rebinding page could read the served files, a token baked into a page, and `.env` through the asset route. The port is never compared, so an `ssh -L` tunnel works; `allowed_hosts` adds names, and `allowed_hosts = true` turns the check off with a warning. Network binds keep the token gate. Affects v1.0.0 and later.
- A `host` this machine does not have was not refused: the server listened on every interface instead, at a port `inst.port` did not name. Such a start now raises. Affects v1.3.0 and later.
- A NUL byte or a backslash in a request path is `400` before the token gate, and `protected_paths` is checked again against the file's name on disk, so `/content.md%00`, `/CONTENT.MD` on a case-folding volume, and a link to a protected file no longer skip the token. Affects v1.4.0 and later.
- Dot segments (`/.env`, `/.git/config`) are `404` unless `serve_dotfiles = true`, the file you started on excepted; `/.well-known/` at the root stays served, and a listing shows dot entries only with both `serve_dotfiles` and `show_hidden`. The asset route refuses credential files by name (`.env`, `.env.*`, `.npmrc`, `.netrc`, `id_rsa` and the like), key and certificate files by extension (`*.pem`, `*.crt`, `*.key` and the like) and paths through credential directories (`.git`, `.ssh`, `.aws` and the like) at any depth; it serves a regular file alone, images in other dot directories stay served, and no deny list is complete. Affects v1.0.0 and later; the asset route's part, v1.5.0 and later.
- `/__live/inject` refuses, with `403`, a browser request from another site or another port (`Sec-Fetch-Site` other than `same-origin` or `none`, or a foreign `Origin`, which refuses and never admits); a request with neither header, such as curl's, is served as before on a loopback bind reached under a loopback name, and refused on a network bind without a `token`, where a browser sends neither header to a plain-http LAN address. Affects v1.2.0 and later with no `token` set.
- Outside Linux, a bind to a specific address (`127.0.0.1`, `::1` or a LAN address) refuses a port another program listens on at its family's wildcard address, and a wildcard bind refuses one another socket holds at the loopback address its URL names; the other program used to take the page's requests, token included. Affects v1.0.0 and later; a wildcard or LAN address bind, v1.3.0 and later.
- `server.start` refuses `token = ""` and a token that is not a string: an empty token passed every gate. Affects v1.4.0 and later.
- `cors` never adds `Access-Control-Allow-Origin` to `/__live/*`, and with `cors` set an `Access-Control-Allow-Origin` passed in `headers` is replaced by what `cors` names, so under a list an unlisted `Origin` gets none. Every response carries `Referrer-Policy: strict-origin` (a caller's `no-referrer` or `strict-origin` kept, any other value replaced), so no Referer carries the page's path or query, the token included, not even to the server's own origin; a page's own `<meta name="referrer">` can still change it. A 404 names the request path, never a filesystem path, and HTML, SVG and XML from the asset route carry `Content-Security-Policy: sandbox`. Affects v1.0.0 and later; the asset route's part, v1.5.0 and later.
- A `Content-Type` passed in `headers` once replaced a served file's type, past the asset route's sandbox, and a framing field passed there went out beside the server's own; both are now refused at start. Affects v1.0.0 and later.
- A line break inside an event's payload, through `/__live/inject`'s data or a path, ended the frame early and started a forged event, and an event name holding a line break injected a `retry` field; every payload line is now its own `data:` line and `send_event` refuses such a name. Affects v1.0.0 and later through a path, v1.1.0 through `send_event`, v1.2.0 through `/__live/inject`.
- A client that reached the port could open connections without limit, each one a descriptor of the editor's own process; the server now closes a connection accepted while `max_connections` (64 by default) are open. Affects v1.0.0 and later.
- An idle event stream was never written to, so a proxy's idle timeout cut a live page's stream and a peer that vanished without closing its connection stayed listed, holding a connection place; the server now writes a comment line to every stream each `sse_heartbeat_ms` (20 s by default). Affects v1.0.0 and later.
- A client that stopped reading an event stream without closing it made the editor queue every later event for it without limit; a stream more than 1 MiB behind for longer than a second, or more than 8 MiB behind at all, is now dropped, and a reader that keeps up is not dropped for one large event or a burst while it stays within 8 MiB. The second counts time the editor spends blocked, so a send right after a longer block can drop a reader that keeps up. Affects v1.0.0 and later.
- The error of a failed write to an event stream went unread and a raise inside one went unreported; a failed write, a heartbeat's included, now drops the stream and closes its socket, and a raise is reported once. A response or stream whose first write fails closes its connection there, and such a stream is never kept. Affects v1.0.0 and later.
- A `.liveignore` over 64 KiB, or one that cannot be opened, is ignored with a warning; a link to a large file hung every start. Affects v1.0.0 and later.
- A notice shows a control byte, a C1 code or a bidi control from a request path or a file name as `?`, so a peer's bytes cannot act on the terminal or reorder the line. Affects v1.0.0 and later.

## [1.5.0] - 2026-07-07

### Features
- **Configurable bind address**: new `host` setup option (default `127.0.0.1`); set `"0.0.0.0"` for network access. Thanks @icyveins7 (#5).
- **Token auth in setup**: `token` and `protected_paths` are now exposed as setup options, so network binding can actually be secured from the plugin config.
- **Asset route**: new token-gated `/__live/asset?p=<relpath>` endpoint serves files relative to a configurable `asset_root` (a directory or a function), with realpath containment. Powers relative-image support in markdown-preview.nvim.
- **Capability flags**: `require('live_server.server').features` lets sibling plugins feature-detect against an independently-versioned install.

### Security
- **Path-normalization auth bypass fixed**: the token gate matched the raw request path while files were served after URL-decoding and slash-collapsing, so `//content.md`, `/content%2emd`, and `/x/../content.md` could evade the token on a network bind. The path is now canonicalized once and used for both the auth check and the file mapper.
- **SSE CORS**: the reload stream no longer sends a hardcoded `Access-Control-Allow-Origin: *`; it emits CORS only when configured.

### Docs & tests
- README documents the network-exposure trade-offs and the `ssh -L` alternative.
- New test suites for host binding and the asset route; token-auth tests extended with path-normalization cases (44 tests total).

## [1.4.0] - 2026-05-24

- **Feature:** Optional token auth for protected endpoints. When `cfg.token` is set, the SSE stream (`/__live/events`), the event injection endpoint (`/__live/inject`), and any path matching `cfg.protected_paths` (list of Lua patterns) require `?t=<token>` on the request. Static assets stay reachable so the browser can bootstrap. (#4)
- **API:** New helpers `util.random_token(byte_len)` (hex token from `/dev/urandom`, with a `math.random` fallback) and `util.secure_compare(a, b)` for constant-time-ish validation.
- **Backward compatible:** `cfg.token = nil` (the default) keeps the previous behaviour. No existing caller is affected.

## [1.3.0] - 2026-04-19

- Add configurable host binding via the `host` field on `server.start({ host = ... })`. Default remains `127.0.0.1`. Set to `0.0.0.0` to expose externally (useful in containers).

## [1.2.2] - 2026-03-22

- Fix recursive file watching on Linux: v1.2.1 fallback never triggered because `UV_FS_EVENT_RECURSIVE` is silently ignored on Linux (no error)
- Now detects platform via `uv.os_uname()` and always uses per-directory watchers on Linux
- Fixed callback path construction for subdirectory watchers

## [1.2.1] - 2026-03-21

- Fix recursive file watching on Linux: subdirectory changes (e.g. `css/style.css`) now trigger reloads
- Falls back to per-directory watchers when `UV_FS_EVENT_RECURSIVE` is not supported
- Dynamically watches newly created directories

## [1.2.0] - 2026-03-13

- Add `/__live/inject` HTTP endpoint for external SSE event injection
- Support port 0 (OS-assigned) with actual port resolution via `getsockname()`

## [1.1.0] - 2026-02-15

### New

- **`S.send_event(inst, event_type, data)`**: public API for sending custom SSE events to connected browsers. Exposes the internal broadcast mechanism so consumers (e.g. markdown-preview.nvim) can send arbitrary event types beyond the built-in \`reload\`.

## [1.0.0] - 2026-02-12

### live-server.nvim v1.0.0

Pure-Lua local web server for Neovim with live-reload. Zero external dependencies.

#### Features

- **SSE live-reload** with configurable debouncing
- **CSS hot-inject**: swap stylesheets without full page reload
- **Auto-start** on filetype (e.g. open an HTML file → server starts)
- **Statusline component**: `[LS :8000]` for lualine/statusline
- **`.liveignore`**: skip file watcher noise (`node_modules`, `*.log`, etc.)
- **CORS headers**: configurable `Access-Control-Allow-Origin`
- **Telescope integration**: path and port pickers
- **Directory listing**: styled index when no `index.html` exists
- **Styled error pages**: dark-mode-aware 404/400 pages
- **Same-port retargeting**: reuse browser tab when switching roots
- **Custom index names**: try `index.html`, `index.htm`, or your own list
- **Vimdoc**: full `:help live-server.nvim` documentation
- **Graceful exit**: servers stop automatically on `VimLeavePre`

#### Install

```lua
{ "selimacerbas/live-server.nvim", opts = {} }
```

See [README](https://github.com/selimacerbas/live-server.nvim#readme) for full setup and configuration.

[Unreleased]: https://github.com/selimacerbas/live-server.nvim/compare/v1.5.0...HEAD
[1.5.0]: https://github.com/selimacerbas/live-server.nvim/releases/tag/v1.5.0
[1.4.0]: https://github.com/selimacerbas/live-server.nvim/releases/tag/v1.4.0
[1.3.0]: https://github.com/selimacerbas/live-server.nvim/releases/tag/v1.3.0
[1.2.2]: https://github.com/selimacerbas/live-server.nvim/releases/tag/v1.2.2
[1.2.1]: https://github.com/selimacerbas/live-server.nvim/releases/tag/v1.2.1
[1.2.0]: https://github.com/selimacerbas/live-server.nvim/releases/tag/v1.2.0
[1.1.0]: https://github.com/selimacerbas/live-server.nvim/releases/tag/v1.1.0
[1.0.0]: https://github.com/selimacerbas/live-server.nvim/releases/tag/v1.0.0
