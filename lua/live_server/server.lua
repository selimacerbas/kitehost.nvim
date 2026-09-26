-- The plugin-author API loads this module directly, past both guards that
-- notify: below the floor it refuses at load with the floor module's text
-- (level 0 leaves the position out) rather than at the first use of vim.uv.
-- A failed load leaves require's sentinel behind, which answers a retry with
-- "loop or previous error", so the entry is cleared first and every require
-- reads the text.
local floor = require("live_server.floor")
if not floor.ok then
    package.loaded["live_server.server"] = nil
    error(floor.message, 0)
end

local uv = vim.uv
local util = require("live_server.util")

local S = {}

-- Capability flags for callers to feature-detect against an independently
-- versioned install (plugin managers update sibling plugins separately).
S.features = {
    token_auth = true,
    host_binding = true,
    asset_route = true,
}

local MIME = {
    html = "text/html; charset=utf-8",
    htm = "text/html; charset=utf-8",
    css = "text/css; charset=utf-8",
    js = "application/javascript; charset=utf-8",
    mjs = "application/javascript; charset=utf-8",
    json = "application/json; charset=utf-8",
    txt = "text/plain; charset=utf-8",
    svg = "image/svg+xml",
    png = "image/png",
    jpg = "image/jpeg",
    jpeg = "image/jpeg",
    gif = "image/gif",
    ico = "image/x-icon",
    wasm = "application/wasm",
}

local function guess_mime(path)
    local ext = string.match(path, "%.([%w]+)$")
    return (ext and MIME[ext:lower()]) or "application/octet-stream"
end

-- -------- HTTP helpers -----------------------------------------------------

local function write_headers(sock, status, headers)
    local reason = ({
        [200] = "OK",
        [301] = "Moved Permanently",
        [302] = "Found",
        [400] = "Bad Request",
        [404] = "Not Found",
        [405] = "Method Not Allowed",
        [431] = "Request Header Fields Too Large",
        [500] = "Internal Server Error",
    })[status] or "OK"
    local lines = { ("HTTP/1.1 %d %s\r\n"):format(status, reason) }
    for k, v in pairs(headers or {}) do
        table.insert(lines, ("%s: %s\r\n"):format(k, v))
    end
    table.insert(lines, "\r\n")
    sock:write(table.concat(lines))
end

local function send_response(sock, status, headers, body)
    local h = headers or {}
    if body then
        h["Content-Length"] = #body
    end
    h["Connection"] = "close"
    write_headers(sock, status, h)
    if body then
        sock:write(body)
    end
    sock:shutdown(function()
        sock:close()
    end)
end

local function error_page(status, title, detail)
    return string.format(
        '<!doctype html><html><head><meta charset="utf-8"><title>%d %s</title>'
            .. "<style>:root{color-scheme:light dark}"
            .. "body{font:16px/1.6 system-ui,sans-serif;padding:40px;max-width:600px;margin:80px auto;text-align:center}"
            .. "h1{font-size:48px;margin:0;opacity:.3}p{opacity:.7}"
            .. "code{background:rgba(127,127,127,.15);padding:2px 8px;border-radius:4px;font-size:14px}"
            .. "</style></head><body><h1>%d</h1><p>%s</p><p><code>%s</code></p></body></html>",
        status,
        util.html_escape(title),
        status,
        util.html_escape(title),
        util.html_escape(detail)
    )
end

local function http_404(sock, path)
    send_response(sock, 404, { ["Content-Type"] = "text/html; charset=utf-8" }, error_page(404, "Not Found", path))
end

local function http_400(sock, msg)
    send_response(
        sock,
        400,
        { ["Content-Type"] = "text/html; charset=utf-8" },
        error_page(400, "Bad Request", msg or "")
    )
end

-- RFC 3986 IPv4address: four dec-octets, 0 to 255, none with a leading
-- zero.
local function is_ipv4(s)
    local octets = { s:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$") }
    if #octets ~= 4 then
        return false
    end
    for _, o in ipairs(octets) do
        if #o > 3 or tonumber(o) > 255 or (#o > 1 and o:sub(1, 1) == "0") then
            return false
        end
    end
    return true
end

-- The 16-bit groups on one side of an IPv6 address's "::", or nil when a
-- field is not one to four hex digits. The last field of the right side
-- may be an IPv4 address, which fills two groups.
local function ipv6_groups(side, may_end_in_ipv4)
    if side == "" then
        return 0
    end
    local fields = vim.split(side, ":", { plain = true })
    local n = 0
    for i, field in ipairs(fields) do
        if may_end_in_ipv4 and i == #fields and field:find(".", 1, true) then
            if not is_ipv4(field) then
                return nil
            end
            n = n + 2
        elseif field:match("^%x%x?%x?%x?$") then
            n = n + 1
        else
            return nil
        end
    end
    return n
end

-- RFC 3986 IPv6address: eight groups, or fewer around one "::" that
-- stands for at least one zero group. No zone and no IPvFuture: no
-- browser sends either in Host.
local function is_ipv6(s)
    local i, j = s:find("::", 1, true)
    if not i then
        return ipv6_groups(s, true) == 8
    end
    local left, right = ipv6_groups(s:sub(1, i - 1), false), ipv6_groups(s:sub(j + 1), true)
    return left ~= nil and right ~= nil and left + right <= 7
end

-- RFC 3986 reg-name in the shape DNS resolves: unreserved, sub-delims and
-- pct-encoded characters, each "%" followed by two hex digits, in labels
-- that are never empty but for one trailing dot, the root. An IPv4
-- address has this shape too.
local function is_reg_name(s)
    if s:find("[^%w%-%._~%%!%$&'%(%)%*%+,;=]") or s:gsub("%%%x%x", ""):find("%", 1, true) then
        return false
    end
    local labels = s:gsub("%.$", "")
    return labels ~= "" and not labels:find("^%.") and not labels:find("%.%.") and not labels:find("%.$")
end

-- The hostname in a Host value or an absolute-form authority, RFC 9110
-- 7.2's uri-host [":" port]: lowercased, without its brackets or one
-- trailing dot, the port dropped. nil when the value is not a host: an
-- unbracketed IPv6 address with a port cannot be split, and a check that
-- guessed would read a name never sent. An escape is never decoded; the
-- whole name is lowercased, its hex digits included.
local function host_name(value)
    local name, port = value:match("^%[([^%]]*)%](.*)$")
    if name then
        name = is_ipv6(name) and name or nil
    else
        name, port = value:match("^([^:]*)(.*)$")
        name = is_reg_name(name) and name or nil
    end
    if not name or not (port == "" or port:match("^:%d*$")) then
        return nil
    end
    return (name:lower():gsub("%.$", ""))
end

-- The request head, parsed once: method, target, version, and the header
-- fields by lowercased name, each the list of its values in order, so a
-- check can refuse a repeated field instead of reading one copy. The
-- target is a path (origin-form) or an http URL (absolute-form, RFC 9112
-- 3.2.2), whose authority is kept for the Host check and whose path is
-- served. nil and the reason for any head it refuses.
local function parse_head(head)
    local lines = vim.split(head, "\r?\n")
    local method, target, minor = lines[1]:match("^(%u+) (%S+) HTTP/1%.(%d+)$")
    if not method then
        return nil, "Cannot parse request line"
    end
    -- RFC 9110 2.5: a higher minor version of HTTP/1 is answered as 1.1.
    local version = minor == "0" and "1.0" or "1.1"
    local headers = {}
    for i = 2, #lines do
        local name, value = lines[i]:match("^([%w!#$%%&'*+.^_`|~-]+):(.*)$")
        if not name then
            return nil, "Malformed header line"
        end
        -- Two one-pass trims: a lazy capture with a greedy tail rescans an
        -- inner run of blanks from every position and stalled the loop.
        value = value:gsub("^[ \t]+", "")
        value = value:match("^(.*[^ \t])") or ""
        -- RFC 9112 5.5: a value with a CR or a NUL is no field value, and a
        -- check that read one would compare against a byte no client sends.
        if value:find("[\r%z]") then
            return nil, "Malformed header line"
        end
        name = name:lower()
        headers[name] = headers[name] or {}
        table.insert(headers[name], value)
    end
    local authority
    if target:sub(1, 1) ~= "/" then
        local rest = target:match("^[hH][tT][tT][pP]://(.*)$")
        if not rest then
            return nil, "Unsupported request target"
        end
        authority, target = rest:match("^([^/?#]*)(.*)$")
        if target:sub(1, 1) ~= "/" then
            target = "/" .. target
        end
    end
    -- RFC 9112 3.2: an HTTP/1.1 request names its host, on one line; two
    -- would let the Host check read one copy and anything in front the other.
    local hosts = headers.host
    if hosts and #hosts > 1 then
        return nil, "More than one Host header"
    end
    if version == "1.1" and not hosts then
        return nil, "HTTP/1.1 request without Host"
    end
    -- RFC 9112 3.2: a Host that is not a host is 400 on every bind, HTTP/1.0
    -- too; a check that guessed at one would read a name never sent.
    if hosts and not host_name(hosts[1]) then
        return nil, "Invalid Host header"
    end
    if authority and not host_name(authority) then
        return nil, "Invalid request target authority"
    end
    return { method = method, path = target, version = version, headers = headers, authority = authority }
end

-- -------- Path mapping & file read ----------------------------------------

-- Canonicalize a request path so the auth gate and the file mapper can never
-- disagree. Strip the query, percent-decode, then lexically resolve '.'/'..'
-- and collapse duplicate slashes. Without this a peer could evade a
-- protected_paths pattern with an encoded or slash-padded variant that still
-- resolves to the protected file: //content.md, /content%2emd, /x/../content.md.
local function normalize_path(req_path)
    local raw = req_path:match("^([^?#]*)") or req_path
    raw = util.url_decode(raw)
    local parts = {}
    for seg in raw:gmatch("[^/]+") do
        if seg == ".." then
            parts[#parts] = nil
        elseif seg ~= "." then
            parts[#parts + 1] = seg
        end
    end
    return "/" .. table.concat(parts, "/")
end

-- Map an already-normalized path (see normalize_path) to a real file under
-- root. realpath containment stays as defense in depth against anything
-- normalization missed (symlinks, filesystem-level surprises).
local function sanitize_and_map(norm_path, root_real)
    if norm_path == "/" then
        return root_real
    end
    local joined = util.joinpath(root_real, (norm_path:gsub("^/+", "")))
    local ok, real = pcall(uv.fs_realpath, joined)
    if not ok or not real then
        return nil
    end
    if not util.path_has_prefix(real, root_real) then
        return nil
    end
    return real
end

local function read_file_all(abs_path)
    local fd = uv.fs_open(abs_path, "r", 438)
    if not fd then
        return nil
    end
    local stat = uv.fs_fstat(fd)
    if not stat or stat.type ~= "file" then
        uv.fs_close(fd)
        return nil
    end
    local chunk = uv.fs_read(fd, stat.size, 0)
    uv.fs_close(fd)
    return chunk, stat
end

-- -------- LiveReload (SSE) ------------------------------------------------

local CLIENT_JS = table.concat({
    "!function(){try{",
    "var es=new EventSource('/__live/events');",
    "es.addEventListener('reload',function(e){",
    "var d;try{d=JSON.parse(e.data)}catch(_){d={}}",
    "if(d.css){var ls=document.querySelectorAll('link[rel=\"stylesheet\"]');",
    "if(ls.length){ls.forEach(function(l){var h=l.href.replace(/[?&]_lr=\\d+/,'');",
    "l.href=h+(h.indexOf('?')>-1?'&':'?')+'_lr='+Date.now()});return}}",
    "location.reload()});",
    "es.onopen=function(){console.log('[live-server.nvim] connected')};",
    "es.onerror=function(e){console.warn('[live-server.nvim] SSE error',e)};",
    "}catch(e){console.warn('[live-server.nvim] no EventSource',e)}}();",
})

local function sse_accept(inst, sock)
    local h = {
        ["Content-Type"] = "text/event-stream",
        ["Cache-Control"] = "no-cache",
        ["Connection"] = "keep-alive",
    }
    -- Send CORS on the SSE stream only when the instance was configured for
    -- it; an unconditional wildcard would let any origin read this stream.
    -- Match the header key case-insensitively so a user-supplied lowercase
    -- key still carries through.
    for k, v in pairs(inst.headers) do
        if k:lower() == "access-control-allow-origin" then
            h["Access-Control-Allow-Origin"] = v
            break
        end
    end
    write_headers(sock, 200, h)
    sock:write("retry: 1000\n\n")
    table.insert(inst.sse_clients, sock)
end

-- A stream whose socket reported its end leaves the client list here;
-- stop and a failed broadcast write remove theirs.
local function sse_drop(inst, sock)
    for i, cl in ipairs(inst.sse_clients) do
        if cl == sock then
            table.remove(inst.sse_clients, i)
            return
        end
    end
end

local function sse_broadcast(inst, event, payload)
    local line = ("event: %s\ndata: %s\n\n"):format(event, payload or "{}")
    local i = 1
    while i <= #inst.sse_clients do
        local cl = inst.sse_clients[i]
        local ok = pcall(function()
            cl:write(line)
        end)
        if not ok then
            pcall(function()
                cl:close()
            end)
            table.remove(inst.sse_clients, i)
        else
            i = i + 1
        end
    end
end

local function schedule_reload(inst, changed_path)
    if not inst.live_enabled then
        return
    end
    if changed_path and changed_path ~= "" and #inst.ignore_patterns > 0 then
        if util.match_ignore(changed_path, inst.ignore_patterns) then
            return
        end
    end
    inst._last_change = changed_path or inst._last_change
    inst.debounce_timer:stop()
    inst.debounce_timer:start(inst.live_debounce, 0, function()
        S.reload(inst, inst._last_change or "")
    end)
end

-- Recursively scan all subdirectories under root (for Linux fallback watchers)
local function scan_dirs(root)
    local dirs = { root }
    local function walk(dir)
        local handle = uv.fs_scandir(dir)
        if not handle then
            return
        end
        while true do
            local name, typ = uv.fs_scandir_next(handle)
            if not name then
                break
            end
            if typ == "directory" and name ~= ".git" and name ~= "node_modules" then
                local full = util.joinpath(dir, name)
                dirs[#dirs + 1] = full
                walk(full)
            end
        end
    end
    walk(root)
    return dirs
end

-- UV_FS_EVENT_RECURSIVE is only supported on macOS and Windows.
-- On Linux (inotify) the flag is silently ignored: it does NOT error,
-- it just watches only the given directory. We detect this via uv.os_uname().
local function supports_recursive_watch()
    local info = uv.os_uname()
    local sys = info and info.sysname or ""
    return sys == "Darwin" or sys:find("Windows") ~= nil
end

-- Attach a single-directory fs_event watcher with a dir-aware callback
local function add_dir_watch(inst, dir)
    local ev = uv.new_fs_event()
    local cb = function(err, fname, _status)
        if err then
            return
        end
        local full = fname and fname ~= "" and util.joinpath(dir, fname) or dir
        schedule_reload(inst, full)
        -- Watch newly created subdirectories
        if fname and fname ~= "" then
            local st = uv.fs_stat(full)
            if st and st.type == "directory" and not inst._fs_events[full] then
                add_dir_watch(inst, full)
            end
        end
    end
    local ok = pcall(function()
        ev:start(dir, {}, cb)
    end)
    if not ok then
        pcall(function()
            ev:start(dir, cb)
        end)
    end
    inst._fs_events[dir] = ev
end

local function stop_fs_watch(inst)
    if inst.fs_event then
        pcall(function()
            inst.fs_event:stop()
            inst.fs_event:close()
        end)
        inst.fs_event = nil
    end
    if inst._fs_events then
        for _, ev in pairs(inst._fs_events) do
            pcall(function()
                ev:stop()
                ev:close()
            end)
        end
        inst._fs_events = nil
    end
end

local function start_fs_watch(inst)
    stop_fs_watch(inst)

    if supports_recursive_watch() then
        -- macOS / Windows: single recursive watcher
        local single = uv.new_fs_event()
        local cb = function(err, fname, _status)
            if err then
                return
            end
            schedule_reload(inst, fname or "")
        end
        local ok = pcall(function()
            single:start(inst.root_real, { recursive = true }, cb)
        end)
        if ok then
            inst.fs_event = single
            return
        end
        pcall(function()
            single:close()
        end)
    end

    -- Linux (or recursive failed): per-directory watchers
    inst._fs_events = {}
    for _, dir in ipairs(scan_dirs(inst.root_real)) do
        add_dir_watch(inst, dir)
    end
end

-- -------- HTML helpers (injection + templating) ---------------------------

local function send_html_with_injection(inst, sock, html, extra_headers)
    if inst.inject_script then
        local tag = '<script src="/__live/script.js"></script>'
        if html:find("</body>", 1, true) then
            html = html:gsub("</body>", tag .. "</body>", 1)
        else
            html = html .. tag
        end
    end
    local headers = { ["Content-Type"] = "text/html; charset=utf-8" }
    for k, v in pairs(extra_headers or {}) do
        headers[k] = v
    end
    send_response(sock, 200, headers, html)
end

local function serve_html_file_with_injection(inst, sock, abs_path, extra_headers)
    local body = read_file_all(abs_path)
    if not body then
        return http_404(sock, abs_path)
    end
    send_html_with_injection(inst, sock, body, extra_headers)
end

-- -------- Directory listing -----------------------------------------------

local function dir_listing_html(inst, fs_path, req_path)
    local entries = {}
    local iter = uv.fs_scandir(fs_path)
    if not iter then
        return "<!doctype html><meta charset=utf-8><h2>Cannot read directory</h2>"
    end
    if req_path ~= "/" then
        table.insert(entries, { name = "..", is_dir = true, up = true })
    end
    while true do
        local name, t = uv.fs_scandir_next(iter)
        if not name then
            break
        end
        if not inst.dir_show_hidden and name:sub(1, 1) == "." then
            -- skip hidden
        else
            table.insert(entries, { name = name, is_dir = (t == "directory") })
        end
    end
    table.sort(entries, function(a, b)
        if a.is_dir ~= b.is_dir then
            return a.is_dir
        end
        return a.name:lower() < b.name:lower()
    end)

    local rows = {}
    for _, e in ipairs(entries) do
        local label = util.html_escape(e.name)
        local href
        if e.up then
            local parent = req_path:gsub("/+$", ""):match("^(.*)/[^/]*$") or "/"
            href = parent == "" and "/" or parent .. "/"
        else
            href = req_path
                .. (req_path:sub(-1) == "/" and "" or "/")
                .. util.url_encode(e.name)
                .. (e.is_dir and "/" or "")
        end
        local icon = e.up and "⤴" or (e.is_dir and "📁" or "📄")
        table.insert(
            rows,
            string.format('<tr><td class="ico">%s</td><td><a href="%s">%s</a></td></tr>', icon, href, label)
        )
    end

    local title = "Index of " .. util.html_escape(req_path)
    local css = [[
    <style>
      :root{color-scheme:light dark}
      body{font:14px/1.5 system-ui,Segoe UI,Roboto,Helvetica,Arial,sans-serif;padding:24px;max-width:900px;margin:auto}
      h1{font-size:20px;margin:0 0 16px}
      table{width:100%;border-collapse:collapse}
      td{padding:6px 8px;border-bottom:1px solid rgba(127,127,127,.2)}
      td.ico{width:2rem;text-align:center}
      a{text-decoration:none} a:hover{text-decoration:underline}
    </style>
  ]]
    return string.format(
        [[
  <!doctype html><html><head><meta charset="utf-8"><title>%s</title>%s</head>
  <body><h1>%s</h1><table>%s</table></body></html>
  ]],
        util.html_escape(title),
        css,
        util.html_escape(title),
        table.concat(rows)
    )
end

-- -------- Static file streaming -------------------------------------------

local function stream_file(sock, abs_path, extra_headers)
    local fd = uv.fs_open(abs_path, "r", 438)
    if not fd then
        return http_404(sock, abs_path)
    end
    local stat = uv.fs_fstat(fd)
    if not stat or stat.type ~= "file" then
        uv.fs_close(fd)
        return http_404(sock, abs_path)
    end

    local headers =
        { ["Content-Type"] = guess_mime(abs_path), ["Content-Length"] = stat.size, ["Connection"] = "close" }
    for k, v in pairs(extra_headers or {}) do
        headers[k] = v
    end
    write_headers(sock, 200, headers)

    local offset = 0
    local function read_chunk()
        uv.fs_read(fd, 64 * 1024, offset, function(err_read, data)
            if err_read or not data then
                uv.fs_close(fd)
                sock:shutdown(function()
                    sock:close()
                end)
                return
            end
            offset = offset + #data
            sock:write(data, function()
                if #data < 64 * 1024 then
                    uv.fs_close(fd)
                    sock:shutdown(function()
                        sock:close()
                    end)
                else
                    read_chunk()
                end
            end)
        end)
    end
    read_chunk()
end

local function serve_path(inst, sock, abs_path, req_path, extra_headers)
    local mime = guess_mime(abs_path)
    if mime:find("^text/html") then
        return serve_html_file_with_injection(inst, sock, abs_path, extra_headers)
    else
        return stream_file(sock, abs_path, extra_headers)
    end
end

-- Answers one parsed request: the token gate, the routes and every
-- response. The connection's reader hands it a head read whole.
local function handle_request(conn, req)
    local inst, sock = conn.inst, conn.sock
    if req.method ~= "GET" then
        return send_response(sock, 405, { ["Content-Type"] = "text/plain" }, "Method Not Allowed")
    end

    -- Canonicalize the path once; auth matching, endpoint dispatch,
    -- and file mapping all use this same string so an encoded or
    -- slash-padded variant can't reach a protected file ungated.
    local path_only = normalize_path(req.path)
    local query = req.path:match("%?(.*)$") or ""

    -- Pull a query-string parameter by key. Anchored to either
    -- the start of the query or just after an '&' so we don't
    -- accidentally match a key as a substring of another (e.g.
    -- 't' inside 'event').
    local function qparam(key)
        return query:match("^" .. key .. "=([^&]*)") or query:match("&" .. key .. "=([^&]*)")
    end

    -- Auth gate. When inst.token is set, the SSE stream, the event
    -- injection endpoint, and any path in inst.protected_paths
    -- require a matching ?t=<token>. Static assets (/index.html,
    -- /style.css, /favicon.ico, etc.) are intentionally NOT gated
    -- because the browser bootstraps from them before any JS runs
    -- and cannot append query strings to <link>/<img> tags it
    -- discovers itself. Protect the user content (caller passes
    -- protected_paths) and the live-reload control plane.
    if inst.token then
        local function path_needs_auth(p)
            if p == "/__live/events" or p == "/__live/inject" or p == "/__live/asset" then
                return true
            end
            for _, pat in ipairs(inst.protected_paths) do
                if p:find(pat) then
                    return true
                end
            end
            return false
        end
        if path_needs_auth(path_only) then
            local req_token = qparam("t")
            local decoded = req_token and util.url_decode(req_token) or ""
            if not util.secure_compare(decoded, inst.token) then
                return send_response(sock, 401, { ["Content-Type"] = "text/plain" }, "Unauthorized")
            end
        end
    end

    -- Special endpoints
    if path_only == "/__live/script.js" then
        return send_response(sock, 200, { ["Content-Type"] = "application/javascript; charset=utf-8" }, CLIENT_JS)
    elseif path_only == "/__live/events" then
        conn.sse = true
        return sse_accept(inst, sock)
    elseif path_only == "/__live/inject" then
        local event = qparam("event")
        local data = qparam("data")
        if event then
            local decoded = data and util.url_decode(data) or "{}"
            sse_broadcast(inst, event, decoded)
        end
        return send_response(sock, 200, { ["Content-Type"] = "text/plain" }, "ok")
    elseif path_only == "/__live/asset" then
        local aroot = inst.asset_root
        if type(aroot) == "function" then
            local ok_root, res = pcall(aroot)
            aroot = ok_root and res or nil
        end
        local rel = qparam("p")
        rel = rel and util.url_decode(rel) or ""
        -- Relative paths only: reject absolute paths, drive
        -- letters / URL schemes (':'), and backslashes outright;
        -- realpath containment below handles '..' traversal.
        if not aroot or rel == "" or rel:find("^/") or rel:find(":") or rel:find("\\") then
            return http_404(sock, "/__live/asset")
        end
        local aroot_real = uv.fs_realpath(aroot)
        if not aroot_real then
            return http_404(sock, "/__live/asset")
        end
        local ok_real, real = pcall(uv.fs_realpath, util.joinpath(aroot_real, rel))
        if not ok_real or not real or not util.path_has_prefix(real, aroot_real) then
            return http_404(sock, "/__live/asset")
        end
        return stream_file(sock, real, inst.headers)
    end

    -- Map path
    local mapped = sanitize_and_map(path_only, inst.root_real)
    if not mapped then
        return http_404(sock, req.path)
    end

    local st = uv.fs_stat(mapped)
    if st and st.type == "directory" then
        local candidate
        if inst.default_index and mapped == inst.root_real then
            candidate = inst.default_index
        else
            for _, iname in ipairs(inst.index_names) do
                local try = util.joinpath(mapped, iname)
                if uv.fs_stat(try) then
                    candidate = try
                    break
                end
            end
        end
        if candidate and uv.fs_stat(candidate) then
            return serve_path(inst, sock, candidate, req.path, inst.headers)
        end
        if inst.dir_enabled then
            local html = dir_listing_html(inst, mapped, req.path)
            return send_html_with_injection(inst, sock, html, inst.headers)
        else
            return http_404(sock, req.path .. " (no index)")
        end
    elseif st and st.type == "file" then
        return serve_path(inst, sock, mapped, req.path, inst.headers)
    else
        return http_404(sock, req.path)
    end
end

-- A head larger than this is refused (431). A browser's localhost cookie jar
-- is shared by every dev server on the host and was measured near 20 KiB, so
-- the cap sits well above it and still bounds a connection's memory.
local MAX_HEAD = 64 * 1024

-- Where the head ends: the first blank line, whether its two line ends are
-- CRLF or bare LF in any mix (RFC 9112 2.2 lets a server accept a bare LF,
-- and this server always answered one). The index of the head's last byte
-- and the spelling found, or nil while it is incomplete. The search starts
-- at from, so a head read in many chunks is scanned once, not once per
-- chunk. Only the "\n\n" spelling can leave the CR of a CRLF line end
-- before it, which is excluded; a CR before any other spelling is the last
-- field value's own byte and must reach the CR check.
local function find_head_end(buf, from)
    local first, spelling
    for _, blank in ipairs({ "\r\n\r\n", "\n\n", "\n\r\n" }) do
        local at = buf:find(blank, from, true)
        if at and (not first or at < first) then
            first, spelling = at, blank
        end
    end
    if not first then
        return nil
    end
    local last = first - 1
    if spelling == "\n\n" and buf:sub(last, last) == "\r" then
        last = last - 1
    end
    return last, spelling
end

-- One accepted socket's state.
local function new_conn(inst, sock)
    return { inst = inst, sock = sock, buf = "", handled = false }
end

-- Every read on an accepted socket lands here.
local function on_read(conn, err, chunk)
    local sock = conn.sock
    if err or not chunk then
        if conn.sse then
            sse_drop(conn.inst, sock)
            if not sock:is_closing() then
                sock:close()
            end
            return
        end
        -- A head cut off by the client's FIN still gets an answer; a connect
        -- that sent nothing (markdown-preview's lock check) closes silently.
        if not err and not conn.handled and conn.buf ~= "" then
            conn.handled = true
            conn.buf = ""
            return http_400(sock, "Incomplete request head")
        end
        sock:close()
        return
    end
    -- One request per connection: bytes after the head (a pipelined request,
    -- a late chunk, anything on an event stream) are never parsed again.
    if conn.handled then
        return
    end
    conn.buf = conn.buf .. chunk
    -- A request line starts with a method token; anything else (a TLS
    -- ClientHello on the plain port) is refused at once, never left waiting
    -- for a blank line that will not come.
    if not conn.buf:find("^[A-Z]") then
        conn.handled = true
        conn.buf = ""
        return http_400(sock, "Cannot parse request line")
    end
    -- A terminator of at most four bytes may straddle the previous read.
    local head_end = find_head_end(conn.buf, math.max(1, #conn.buf - #chunk - 3))
    -- The cap judges the head's bytes: while no blank line is found, a
    -- buffer within three bytes of the cap may hold a terminator's start.
    if head_end and head_end > MAX_HEAD or not head_end and #conn.buf > MAX_HEAD + 3 then
        conn.handled = true
        conn.buf = ""
        return send_response(sock, 431, { ["Content-Type"] = "text/plain" }, "Request Header Fields Too Large")
    end
    if not head_end then
        return
    end
    conn.handled = true
    local req, why = parse_head(conn.buf:sub(1, head_end))
    conn.buf = ""
    if not req then
        return http_400(sock, why)
    end
    return handle_request(conn, req)
end

-- -------- Public server API -----------------------------------------------

-- cfg: { port, root, default_index|nil, headers, live={enabled,inject_script,debounce}, features={dirlist={enabled,show_hidden}}, host, token, protected_paths, asset_root }
function S.start(cfg)
    local tcp = uv.new_tcp()
    local host = cfg.host or "127.0.0.1"
    -- The caller shows the message to the user, so it carries no source
    -- position: bind is called directly under pcall, which adds none, and the
    -- raise is at level 0.
    local ok, bind_err = pcall(tcp.bind, tcp, host, cfg.port)
    if not ok then
        error(bind_err or "bind failed", 0)
    end

    -- Resolve actual port (needed when cfg.port == 0 for OS-assigned port)
    local actual_port = cfg.port
    if cfg.port == 0 then
        actual_port = tcp:getsockname().port
    end

    local root_real = uv.fs_realpath(cfg.root)
    if not root_real then
        error("Invalid root: " .. tostring(cfg.root), 0)
    end

    local headers = vim.tbl_extend("keep", cfg.headers or {}, {})
    if cfg.cors then
        headers["Access-Control-Allow-Origin"] = type(cfg.cors) == "string" and cfg.cors or "*"
    end

    local inst = {
        handle = tcp,
        port = actual_port,
        host = host,
        root = cfg.root,
        root_real = root_real,
        default_index = cfg.default_index,
        headers = headers,
        started_at = os.time(),

        -- live
        live_enabled = cfg.live and cfg.live.enabled ~= false,
        inject_script = cfg.live and cfg.live.inject_script ~= false,
        live_debounce = (cfg.live and cfg.live.debounce) or 120,
        css_inject = cfg.live and cfg.live.css_inject ~= false,
        sse_clients = {},
        debounce_timer = uv.new_timer(),

        -- features
        dir_enabled = not (cfg.features and cfg.features.dirlist and cfg.features.dirlist.enabled == false),
        dir_show_hidden = cfg.features and cfg.features.dirlist and cfg.features.dirlist.show_hidden or false,
        index_names = cfg.index_names or { "index.html", "index.htm" },
        ignore_patterns = util.parse_liveignore(root_real),
        notify_on_reload = cfg.notify_on_reload or false,

        -- auth
        token = cfg.token, -- nil = no auth; string = required on protected paths
        protected_paths = cfg.protected_paths or {},

        -- /__live/asset root: a directory, or a function returning one.
        -- Lets a caller expose files that live next to its source document
        -- (e.g. images referenced from markdown) without serving that
        -- directory as the root. Token-gated whenever token is set.
        asset_root = cfg.asset_root,
    }

    if inst.live_enabled then
        start_fs_watch(inst)
    end

    ok, bind_err = pcall(function()
        tcp:listen(128, function(err_listen)
            if err_listen then
                return
            end
            local sock = uv.new_tcp()
            tcp:accept(sock)
            local conn = new_conn(inst, sock)
            sock:read_start(function(err_read, chunk)
                on_read(conn, err_read, chunk)
            end)
        end)
    end)
    if not ok then
        error(bind_err or "listen failed", 0)
    end

    return inst
end

function S.stop(inst)
    if inst.debounce_timer then
        pcall(function()
            inst.debounce_timer:stop()
            inst.debounce_timer:close()
        end)
    end
    for _, cl in ipairs(inst.sse_clients) do
        pcall(function()
            cl:close()
        end)
    end
    inst.sse_clients = {}
    stop_fs_watch(inst)
    pcall(function()
        inst.handle:close()
    end)
end

function S.update_target(inst, new_root, new_index)
    inst.root = new_root
    inst.root_real = uv.fs_realpath(new_root) or inst.root_real
    inst.default_index = new_index
    inst.ignore_patterns = util.parse_liveignore(inst.root_real)
    if inst.live_enabled then
        start_fs_watch(inst)
    end
end

-- Live-reload controls
function S.reload(inst, reason_path)
    local rp = tostring(reason_path or "")
    local is_css = inst.css_inject and rp:match("%.css$")
    local payload = ('{"ts":%d,"path":%q,"css":%s}'):format(os.time(), rp, is_css and "true" or "false")
    sse_broadcast(inst, "reload", payload)
    if inst.notify_on_reload then
        vim.schedule(function()
            util.notify(
                ("Reload%s → %s"):format(is_css and " (CSS)" or "", rp ~= "" and rp or "manual"),
                { notify = true }
            )
        end)
    end
end

function S.send_event(inst, event_type, data)
    sse_broadcast(inst, event_type, data or "{}")
end

function S.enable_live(inst, enable)
    enable = not not enable
    if inst.live_enabled == enable then
        return enable
    end
    inst.live_enabled = enable
    if enable then
        start_fs_watch(inst)
    else
        stop_fs_watch(inst)
    end
    return enable
end

function S.is_live_enabled(inst)
    return inst.live_enabled
end

function S.connected_client_count(inst)
    return #inst.sse_clients
end

return S
