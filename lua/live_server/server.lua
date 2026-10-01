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
-- An install without cors_list reads a cors list as its widest value, "*".
-- One without start_raises could return from a start that served nothing
-- while another program answered on the port, so a pcall saw no error.
S.features = {
    token_auth = true,
    host_binding = true,
    asset_route = true,
    host_check = true,
    cors_list = true,
    start_raises = true,
}

-- A document type added here joins ACTIVE_DOCUMENT, or the asset route
-- serves it unsandboxed.
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

-- One character of an RFC 9110 token (5.6.2), a field name among them, as
-- a Lua pattern class: every reader of a name builds its pattern from it.
local TCHAR = "[%w!#$%%&'*+%-.^_`|~]"

-- Reason phrases by status: one table for every status this server sends
-- or may send, so a status line never reads "401 OK" again. A status with
-- no entry goes out with an empty reason, which RFC 9112 allows and which a
-- suite row catches, never with a wrong one.
local REASONS = {
    [200] = "OK",
    [204] = "No Content",
    [301] = "Moved Permanently",
    [302] = "Found",
    [400] = "Bad Request",
    [401] = "Unauthorized",
    [403] = "Forbidden",
    [404] = "Not Found",
    [405] = "Method Not Allowed",
    [414] = "URI Too Long",
    [421] = "Misdirected Request",
    [431] = "Request Header Fields Too Large",
    [500] = "Internal Server Error",
}

-- The policies that send no path or query in any Referer.
local KEPT_POLICIES = { ["no-referrer"] = true, ["strict-origin"] = true }

-- A caller's Referrer-Policy value when it is one of them as Chromium
-- reads it, its case ignored and its blanks trimmed (measured), in the
-- lower case the policy names are defined in; else nil. Two one-pass
-- trims, as parse_head's.
local function kept_policy(v)
    local bare = (v:gsub("^[ \t]+", ""):match("^(.*[^ \t])") or ""):lower()
    return KEPT_POLICIES[bare] and bare or nil
end

-- The sockets a status line has gone out on. A raise after that point
-- cannot be answered with a 500, which would land inside the first
-- response's body, so the connection is closed instead. Weak, so a socket
-- leaves it with its handle.
local started = setmetatable({}, { __mode = "k" })

-- Returns what the write returned, which every caller reads: a request,
-- or nil and the error on a closed or shut socket.
local function write_headers(sock, status, headers, on_written)
    local reason = REASONS[status] or ""
    local lines = { ("HTTP/1.1 %d %s\r\n"):format(status, reason) }
    local policy = "strict-origin"
    for k, v in pairs(headers or {}) do
        if k:lower() ~= "referrer-policy" then
            table.insert(lines, ("%s: %s\r\n"):format(k, v))
        else
            policy = kept_policy(v) or policy
        end
    end
    -- A page URL can carry ?t=<token>. The browser's default,
    -- strict-origin-when-cross-origin, sends the full URL same-origin, so
    -- the token would ride to the server's own log or a same-origin embed;
    -- this policy sends no path or query in any Referer. The origin alone
    -- still reaches a destination as secure, which an embed needs: under
    -- no-referrer every YouTube iframe showed Error 153. A caller's
    -- no-referrer is kept, and strict-origin with it: neither sends a path
    -- or query, and no-referrer keeps a network bind's address from third
    -- parties, which the caller chose over embeds. Any other policy is
    -- replaced; same-origin sends the full URL to this origin. A page's
    -- own meta or referrerpolicy attribute can still widen or narrow it.
    table.insert(lines, ("Referrer-Policy: %s\r\n"):format(policy))
    table.insert(lines, "\r\n")
    started[sock] = true
    return sock:write(table.concat(lines), on_written)
end

-- The fields a response computes for itself, which start refuses in a
-- caller's headers under any spelling.
local SERVER_FIELDS = {
    ["content-type"] = true,
    ["content-length"] = true,
    ["transfer-encoding"] = true,
    ["connection"] = true,
}

-- What a socket's close must also end, run once by the close that ends
-- it: an accepted connection's place in its server's count. An entry
-- leaves with its socket, which only close_once closes.
local on_close = {}

-- Every socket closes here. Two closers can reach one socket: a response's
-- shutdown callback and the handler's close of a response that had
-- started, and a second close raises "handle is already closing" inside a
-- luv callback (measured, when the read path still closed a half-closed
-- client under a pending shutdown).
local function close_once(sock)
    if not sock:is_closing() then
        sock:close()
        local after = on_close[sock]
        if after then
            on_close[sock] = nil
            after()
        end
    end
end

-- headers is a table the caller built for this one response, which the
-- length and Connection are written into. A write that fails at once, on
-- a closed or shut socket, ends the response there: no body follows a
-- head that failed, and the socket closes now, not through a shutdown.
local function send_response(sock, status, headers, body)
    local h = headers or {}
    if body then
        h["Content-Length"] = #body
    end
    h["Connection"] = "close"
    if not write_headers(sock, status, h) or body and not sock:write(body) then
        return close_once(sock)
    end
    local shut = sock:shutdown(function()
        close_once(sock)
    end)
    -- shutdown returns nil, err (ENOTCONN) on a socket that cannot shut and
    -- then never calls back.
    if not shut then
        close_once(sock)
    end
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

-- A raise's text as a notice carries it: its first line, which already
-- names the file and line (a traceback ran to 15 lines, a hit-enter
-- prompt each), cut to 300 bytes and marked. A control in the line is a
-- mark: Neovim shows one as a caret pair, but a notifier that forwards to
-- a terminal or a desktop would deliver an escape a peer wrote. A request's
-- fault and a caller's callback that raised are both told through it.
local function raise_line(raised)
    return util.marked(tostring(raised):match("^[^\n]*"), 300)
end

-- A caller's value as a refusal or a warning repeats it, marked and cut
-- to 300 bytes as a notice's text is. Raw, an escape or a C1 control in
-- it acted in the terminal a notifier forwards to, and vim.inspect
-- escaped C0 controls alone and cut nothing.
local function shown(value)
    return util.marked(value, 300)
end

-- Tells the user, once and on one line, that answering path raised on
-- port, which the line names, as every notice does, for a user with two
-- servers. 0.10's v:errmsg kept a traceback's last line alone, so the
-- cause is the raise's first line (raise_line). The query is cut, since
-- ?t=<token> rides there and :messages keeps it, and so is the length,
-- since a peer controls the path up to the head's cap, as it would a
-- cause that quoted the path. Scheduled: a request runs in a fast event,
-- where vim.notify raises.
local function report_raise(port, path, raised)
    local cause = raise_line(raised)
    local shown = util.marked(path:match("^[^?#]*"), 200)
    local line = ("live-server: port %d %s failed: %s"):format(port, shown, cause)
    vim.schedule(function()
        util.notify(line, { notify = true }, "ERROR")
    end)
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

-- The shape of an origin (RFC 6454 6.2): scheme://host with an optional
-- port, and no userinfo, path or trailing slash, so nothing in it can end
-- a header line.
local function is_origin(s)
    local authority = s:match("^%a[%w+.-]*://(.+)$")
    return authority ~= nil and host_name(authority) ~= nil and not authority:find(":$")
end

local DEFAULT_PORTS = { http = "80", ws = "80", https = "443", wss = "443" }

-- Whether an origin is spelled as a browser serializes one. A request's
-- Origin is compared byte for byte, so an upper-case letter, an escape, a
-- port with a leading zero or past 65535, or the scheme's default port
-- could never match; such an entry is refused, never rewritten, since a
-- partial rewrite would disagree with the browser's at the edges. Any
-- scheme is left free (an extension's origin is one). A non-canonical
-- IP literal (127.1, [0:0::1]) is not caught here, and never matches
-- either.
local function as_browser_sends(s)
    local scheme, authority = s:match("^(.-)://(.*)$")
    if s:find("[A-Z]") or authority:find("%", 1, true) then
        return false
    end
    local port = authority:match(":(%d+)$")
    return port == nil or (port:find("^[1-9]%d*$") ~= nil and tonumber(port) <= 65535 and DEFAULT_PORTS[scheme] ~= port)
end

-- The Origin and Fetch Metadata fields the gates read, as sent, each once.
local SINGLE_FIELDS = { "Origin", "Sec-Fetch-Site", "Sec-Fetch-Mode" }

-- The longest request target read. The gate matches every protected_paths
-- pattern against the path on the loop, so the path's length multiplies
-- each pattern's cost: under the rules start holds a pattern to
-- (pattern_cost), the costliest shape found, two ? items before 32
-- nested captures and a literal tail filling 256 bytes, costs at most
-- about 105 ms for one read of the 8 KiB this takes, the README's figure.
-- The cap bounds the request's spelling; the name on disk the gate reads
-- second is bounded by the OS's path limit.
local MAX_TARGET = 8 * 1024

-- The request head, parsed once: method, target, version, and the header
-- fields by lowercased name, each the list of its values in order, so a
-- check can refuse a repeated field instead of reading one copy. The
-- target is a path (origin-form) or an http URL (absolute-form, RFC 9112
-- 3.2.2), whose authority is kept for the Host check and whose path is
-- served. nil and the reason for any head it refuses, and 414 as a third
-- value for a target over the cap.
local function parse_head(head)
    local lines = vim.split(head, "\r?\n")
    -- RFC 9112 2.2: empty lines before the request line are ignored; an empty head is refused.
    while #lines > 1 and lines[1] == "" do
        table.remove(lines, 1)
    end
    local method, target, minor = lines[1]:match("^(%u+) (%S+) HTTP/1%.(%d)$")
    if not method then
        return nil, "Cannot parse request line"
    end
    -- RFC 9112 3: 414, read before any field, so neither the Host check
    -- nor a pattern reads a target past the cap.
    if #target > MAX_TARGET then
        return nil, "URI Too Long", 414
    end
    -- RFC 9110 2.5: a higher minor version of HTTP/1 is answered as 1.1.
    local version = minor == "0" and "1.0" or "1.1"
    local headers = {}
    for i = 2, #lines do
        local name, value = lines[i]:match("^(" .. TCHAR .. "+):(.*)$")
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
    -- A browser sends each of these once; a gate must not read one copy
    -- while another reads the next.
    for _, field in ipairs(SINGLE_FIELDS) do
        local values = headers[field:lower()]
        if values and #values > 1 then
            return nil, "More than one " .. field .. " header"
        end
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

-- Canonicalize a request path, which the gate reads before the mapper does;
-- the gate reads the name on disk second, and a name that passes one read
-- and not the other is refused. Strip the query, percent-decode, then
-- lexically resolve '.'/'..' and collapse duplicate slashes. Without this a
-- peer could evade a protected_paths pattern with an encoded or slash-padded
-- variant that still resolves to the protected file: //content.md,
-- /content%2emd, /x/../content.md.
local function normalize_path(req_path)
    local raw = req_path:match("^([^?#]*)") or req_path
    raw = util.url_decode(raw)
    -- libuv cuts a path at its first NUL (fs_realpath, fs_stat, fs_open), so
    -- the gate would match one name and the mapper open another; Windows
    -- takes a backslash as a separator this lexical walk never sees.
    if raw:find("%z") or raw:find("\\", 1, true) then
        return nil
    end
    local parts = {}
    for seg in raw:gmatch("[^/]+") do
        if seg == ".." then
            parts[#parts] = nil
        elseif seg ~= "." then
            parts[#parts + 1] = seg
        end
    end
    -- The second value: the path names a directory (a trailing slash, or a
    -- last segment of . or ..), which the gate reads with its slash.
    local tail = raw:match("[^/]*$")
    return "/" .. table.concat(parts, "/"), tail == "" or tail == "." or tail == ".."
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

-- A file's path under a resolved base as the filesystem spells it
-- (realpath: the case on disk, links followed), then the resolved path; nil
-- when realpath fails or the path resolves outside the base. A base that
-- ends in a separator ("/", "D:\") keeps it on the name, where a pattern
-- anchored at ^/ expects it.
local function root_rel(base_real, path)
    local ok_real, real = pcall(uv.fs_realpath, path)
    if not ok_real or not real or not util.path_has_prefix(real, base_real) then
        return nil
    end
    local base = base_real:gsub("[/\\]$", "")
    local rel = real:sub(#base + 1):gsub("\\", "/")
    return rel == "" and "/" or rel, real
end

-- A path segment naming a dotfile or dot directory; .well-known stays
-- public as the first segment, the path root where RFC 8615 reserves it.
local function has_dot_segment(p)
    local i = 0
    for seg in p:gmatch("[^/]+") do
        i = i + 1
        if seg:sub(1, 1) == "." and not (i == 1 and seg == ".well-known") then
            return true
        end
    end
    return false
end

-- The directory behind the /__live/ namespace, read from a path under the
-- real root as the disk spells it: a case variant or a link reaches it
-- under another request spelling, so the request's own is not enough.
-- The name is read in any case: on a case-folding volume a directory made
-- as __LIVE is that same directory, and one rule for every volume needs no
-- measure of how a volume folds.
local function in_live_dir(rel)
    local first = rel:match("^/([^/]*)")
    return first ~= nil and first:lower() == "__live"
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

-- Everything after the EventSource opens, reload handling and the logs,
-- then the end of the script: shared by both clients below.
local CLIENT_ON = table.concat({
    "es.addEventListener('reload',function(e){",
    "var d;try{d=JSON.parse(e.data)}catch(_){d={}}",
    "if(d.css){var ls=document.querySelectorAll('link[rel=\"stylesheet\"]');",
    "if(ls.length){ls.forEach(function(l){var h=l.href.replace(/[?&]_lr=\\d+/,'');",
    "l.href=h+(h.indexOf('?')>-1?'&':'?')+'_lr='+Date.now()});return}}",
    "location.reload()});",
    "es.onopen=function(){console.log('[live-server.nvim] connected')};",
    "es.onerror=function(e){console.warn('[live-server.nvim] SSE error',e)};",
})
local CLIENT_END = "}catch(e){console.warn('[live-server.nvim] no EventSource',e)}}();"

-- A tokenless server's client, byte for byte the one it always served.
local CLIENT_JS = "!function(){try{var es=new EventSource('/__live/events');" .. CLIENT_ON .. CLIENT_END

-- A token server gates its stream, so the page's ?t= goes on it, and a
-- copy is kept for the tab's other documents. With nothing kept the value
-- is kept at once: a page that left before its stream opened (a meta
-- refresh) or an iframe that read first found none. A page's own URL may
-- use t for something else (a time, a tab), so a value that differs from
-- a kept token replaces it only once its stream opens, and one the server
-- refuses gives way, once, to the kept token. A document with no token
-- waits for another to keep one and says why after two seconds; a refused
-- token with nothing left to try is named, where the stream's error line
-- said nothing, and is no longer kept, so a later page's iframe cannot
-- read it first. Chromium closes a stream the same way on a navigation
-- away and on window.stop(), so a stream that opened counts as refused
-- only after a reconnect error, and the refusal waits one turn, which a
-- leaving document never reaches. A stream that ever opened has replaced
-- the kept token with its own, so its refusal never falls back to the
-- token it replaced. The token is never written into the script, which
-- any page may load.
local CLIENT_JS_TOKEN = table.concat({
    "!function(){try{",
    "var k='live-server.nvim:t',q=new URLSearchParams(location.search).get('t'),s=null,x,o;",
    "try{s=sessionStorage.getItem(k)}catch(e){x=e}",
    "var w=function(m){console.warn('[live-server.nvim] '+m)},",
    "p=function(t){try{sessionStorage.setItem(k,t)}catch(e){w('the token could not be kept: '+e)}},",
    "c=function(t){o=1;var u,v,es=new EventSource('/__live/events?t='+encodeURIComponent(t));",
    "es.addEventListener('open',function(){u=v=1;if(t===q&&s&&s!==q)p(t)});",
    "es.addEventListener('error',function(){if(es.readyState===0)u=0;",
    "else if(es.readyState===2&&!u)setTimeout(function(){if(!v&&t===q&&s&&s!==q)c(s);",
    "else{try{sessionStorage.getItem(k)===t&&sessionStorage.removeItem(k)}catch(e){}",
    "w('the token was refused: open the page with the server\\'s ?t=<token>')}},0)});",
    CLIENT_ON,
    "};",
    "if(q){if(!s)p(q);c(q)}else if(s)c(s);else if(x)w('the token could not be kept: '+x);",
    "else{addEventListener('storage',function(e){if(!o&&e.key===k&&e.newValue)c(e.newValue)});",
    "setTimeout(function(){o||w('no token: open the page with ?t=<token> in its URL')},2000)}",
    CLIENT_END,
})

-- A stream leaves the client list here when its socket reports its end,
-- or through sse_evict when a write to it fails, it falls too far behind
-- (SSE_MAX_QUEUE) or the server stops.
local function sse_drop(inst, sock)
    for i, cl in ipairs(inst.sse_clients) do
        if cl == sock then
            table.remove(inst.sse_clients, i)
            return
        end
    end
end

-- The loop time of the first send that found a stream over SSE_MAX_QUEUE,
-- cleared by a send that finds it at or under, and by the stream's
-- eviction; weak, so an entry leaves with its socket, as started's does.
local over_since = setmetatable({}, { __mode = "k" })

-- A write's callback can report after the stream left (ECANCELED once
-- stop or the read path closed it), and then finds nothing to drop and
-- nothing left to close.
local function sse_evict(inst, sock)
    sse_drop(inst, sock)
    over_since[sock] = nil
    close_once(sock)
end

-- A stream's head and retry line are its first writes, made before it is
-- listed. A closed or shut socket fails them at once, and a peer that
-- resets right after its request can fail them on their callbacks
-- (EPIPE, measured); either ends the stream as a failed frame does, and
-- one that fails at once is never listed.
local function sse_accept(inst, sock)
    local h = {}
    -- Every key is a token string: start refuses any other, and the
    -- stream's Content-Type and Connection. A caller's Cache-Control, set
    -- for its files, would go out under another spelling as a second line
    -- beside the stream's own.
    for k, v in pairs(inst.live_headers) do
        if k:lower() ~= "cache-control" then
            h[k] = v
        end
    end
    h["Content-Type"] = "text/event-stream"
    h["Cache-Control"] = "no-cache"
    h["Connection"] = "keep-alive"
    local function on_written(err)
        if err then
            sse_evict(inst, sock)
        end
    end
    if not write_headers(sock, 200, h, on_written) or not sock:write("retry: 1000\n\n", on_written) then
        return sse_evict(inst, sock)
    end
    table.insert(inst.sse_clients, sock)
end

-- A reader that stops reading without closing raises no error, so every
-- frame after both ends' buffers filled waited in its write queue, which
-- grew for as long as it stayed open (7.85 MB after 128 events of 64 KiB,
-- measured). A stream is judged on its progress over loop time, in which
-- alone a queue drains: one over SSE_MAX_QUEUE for longer than
-- SSE_STALL_MS is dropped at its next send, and one over SSE_HARD_QUEUE
-- at once, the bound on a burst within one turn. The queue a frame left
-- is no measure: macOS takes 0.3 to 1.6 MB of one at once, so a reader
-- that keeps up was dropped when a second frame came before a 3 MiB one
-- drained; curl drains 8 MiB in 11 to 166 ms, well within the grace
-- (measured). Loop time the editor spends blocked counts too, since it
-- advances while no queue can drain, so a send right after a block
-- longer than the grace drops a reader that keeps up (measured).
local SSE_MAX_QUEUE = 1024 * 1024
local SSE_STALL_MS = 1000
local SSE_HARD_QUEUE = 8 * 1024 * 1024

-- Writes one frame to every stream, the only writer after a stream's
-- preamble: an event and the heartbeat both. luv reports a dead stream
-- without raising, by write's nil, err on a closed or shut socket and by
-- its callback's error after a reset, or once TCP gives up on a peer that
-- vanished; either evicts the stream, as falling behind does.
-- write raises only on a bad argument, a fault no pcall should hide. The
-- list is copied, since an eviction during the walk removes from it.
local function sse_send(inst, text)
    local now = uv.now()
    for _, cl in ipairs(vim.list_slice(inst.sse_clients)) do
        local queued = cl:get_write_queue_size()
        if queued <= SSE_MAX_QUEUE then
            over_since[cl] = nil
        elseif not over_since[cl] then
            over_since[cl] = now
        end
        if queued > SSE_HARD_QUEUE or (queued > SSE_MAX_QUEUE and now - over_since[cl] > SSE_STALL_MS) then
            sse_evict(inst, cl)
        else
            local sent = cl:write(text, function(err)
                if err then
                    sse_evict(inst, cl)
                end
            end)
            if not sent then
                sse_evict(inst, cl)
            end
        end
    end
end

-- One event frame: every payload line its own data: line, so a line break
-- in a payload (a path, an injected value) cannot end the frame early or
-- start a field of its own. SSE ends a line at CR, LF or CRLF. A one-line
-- payload keeps the bytes it always had, which every reader relies on.
local function sse_frame(event, payload)
    local text = payload:gsub("\r\n", "\n"):gsub("\r", "\n")
    local out = { "event: " .. event .. "\n" }
    for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
        table.insert(out, "data: " .. line .. "\n")
    end
    table.insert(out, "\n")
    return table.concat(out)
end

local function sse_broadcast(inst, event, payload)
    sse_send(inst, sse_frame(event, payload or "{}"))
end

-- A changed path relative to the root, slash-separated, which the dot
-- filter, the .liveignore match and the reload event read: the recursive
-- watcher reports it so (measured on macOS); a per-directory one (Linux)
-- names the full path, which told every events client where the root sits
-- and put the root's own segments under the dot rule and .liveignore,
-- neither of which reads them. The root itself is "/".
local function changed_rel(inst, changed_path)
    local p = changed_path:gsub("\\", "/")
    local base = inst.root_real:gsub("\\", "/"):gsub("/$", "")
    if p == base then
        return "/"
    elseif p:sub(1, #base + 1) == base .. "/" then
        p = p:sub(#base + 2)
    end
    -- libuv names an event on the watched directory itself by that
    -- directory's own name (inotify, and FSEvents in Neovim 0.12's libuv:
    -- measured), which read as a child of that name; with no such child
    -- the name is the root's own.
    local own = util.basename(inst.root_real)
    if p == own and not uv.fs_lstat(util.joinpath(inst.root_real, own)) then
        return "/"
    end
    return p
end

-- The file the user started on is served at / whatever its name, so its
-- change reloads as a page's does; it is read by realpath, as the gate
-- reads it.
local function is_own_index(inst, rel)
    local own = inst.default_index and root_rel(inst.root_real, inst.default_index)
    return own == "/" .. rel
end

-- A directory on that file's path, which is watched whatever its name: a
-- default_index under .drafts/, or a plain-named link to .hidden/page.html,
-- reloads though the dot rule drops the changes beside it.
local function holds_own_index(inst, rel)
    local own = inst.default_index and root_rel(inst.root_real, inst.default_index)
    return own and own:sub(1, #rel + 2) == "/" .. rel .. "/"
end

-- The user is told of a fault once per instance for each kind, scheduled,
-- since a fault is found in a fast event (an accept, a watcher's
-- callback). A path in the text may be a peer's, so the line is marked.
-- While start runs, the notice waits in inst.queued: a start that raises
-- drops it, where it warned about a port no server held.
local function warn_once(inst, kind, text)
    if inst.warned[kind] then
        return
    end
    inst.warned[kind] = true
    local line = util.marked(("live-server: port %d %s"):format(inst.port, text))
    if inst.queued then
        table.insert(inst.queued, line)
        return
    end
    vim.schedule(function()
        util.notify(line, { notify = true }, "WARN")
    end)
end

local function is_stylesheet(path)
    return path:match("%.css$") ~= nil
end

-- One reload frame, a swap when css and css_inject hold.
local function send_reload(inst, rp, css)
    local is_css = inst.css_inject and css or false
    -- JSON, where %q wrote a tab as \9 and a newline as a line break, which
    -- JSON.parse refused. Each value is encoded on its own: an encoded
    -- table's key order is the hash's, which differs between processes
    -- (measured), and the escaping stays the library's (0.10's writes a
    -- slash as \/), so a reader decodes the payload and never compares it.
    local payload = ('{"ts":%s,"path":%s,"css":%s}'):format(
        vim.json.encode(os.time()),
        vim.json.encode(rp),
        vim.json.encode(is_css)
    )
    sse_broadcast(inst, "reload", payload)
    -- The path may be a peer's file name, so the line is marked.
    if inst.notify_on_reload then
        local line = util.marked(
            ("live-server: port %d reload%s → %s"):format(
                inst.port,
                is_css and " (CSS)" or "",
                rp ~= "" and rp or "manual"
            )
        )
        vim.schedule(function()
            util.notify(line, { notify = true })
        end)
    end
end

-- Whether a window's path still names something at the send; the root
-- ("/") always does; ENOENT or ENOTDIR (a directory on the path became a
-- file) is gone, and any other failure keeps it.
local function still_there(inst, path)
    if path == "/" or path == "" then
        return true
    end
    local st, _, st_name = uv.fs_lstat(util.joinpath(inst.root_real, path))
    return st ~= nil or (st_name ~= "ENOENT" and st_name ~= "ENOTDIR")
end

-- A page changed beside a stylesheet must reload whole, where a swap left
-- it stale. Neovim's :w writes a probe (4913) and a backup (name~) beside
-- the file and deletes both, and a save through a temporary name renames
-- it away, so a stylesheet save reloaded the page naming a file already
-- gone (measured): a path gone by the send is dropped, unless all are,
-- since a deleted page must reload. The path and whether it is a swap.
local function window_send(inst, window)
    local order = {}
    for path, seq in pairs(window) do
        order[#order + 1] = { path = path, seq = seq }
    end
    table.sort(order, function(a, b)
        return a.seq < b.seq
    end)
    local alive = {}
    for _, entry in ipairs(order) do
        if still_there(inst, entry.path) then
            alive[#alive + 1] = entry.path
        end
    end
    if #alive == 0 then
        return order[#order] and order[#order].path or "", false
    end
    for i = #alive, 1, -1 do
        if not is_stylesheet(alive[i]) then
            return alive[i], false
        end
    end
    return alive[#alive], true
end

local function schedule_reload(inst, changed_path)
    if not inst.live_enabled then
        return
    end
    local rel = changed_path and changed_rel(inst, changed_path)
    local own = rel and is_own_index(inst, rel)
    -- A dot path's change names it to every events client, the name the
    -- listing hides, and reloads a page for a file the server never serves;
    -- so does a change in the directory behind /__live/, whatever
    -- serve_dotfiles says.
    local hidden = rel and in_live_dir("/" .. rel)
    if rel and (hidden or (not inst.serve_dotfiles and has_dot_segment(rel))) and not own then
        return
    end
    -- Read with a leading slash, so a line starting with one anchors at
    -- the root (parse_liveignore) on every watcher; the root itself is no
    -- path a line names.
    local ignorable = rel and rel ~= "" and rel ~= "/"
    if ignorable and #inst.ignore_patterns > 0 and util.match_ignore("/" .. rel, inst.ignore_patterns) then
        return
    end
    -- The file the user started on reloads the page at /; when it sits on
    -- a dot path (its own name, or the target of a plain-named link) or in
    -- that directory, the payload says / so no hidden name reaches an
    -- events client, and a plain name keeps its path, so a started-on
    -- stylesheet still swaps.
    local path = (own and (hidden or has_dot_segment(rel))) and "/" or rel
    -- Each path once, at its latest change: a file written faster than the
    -- debounce restarts it at every write. A map to the change's number,
    -- sorted at the send, where a move to the end was quadratic in a burst.
    if path then
        inst.reload_seq = inst.reload_seq + 1
        inst.reload_window[path] = inst.reload_seq
    end
    inst.debounce_timer:stop()
    -- start refuses a closing timer, and the change was then dropped with
    -- no word (measured through a stub).
    local armed, arm_err = inst.debounce_timer:start(inst.live_debounce, 0, function()
        local window = inst.reload_window
        inst.reload_window = {}
        send_reload(inst, window_send(inst, window))
    end)
    if not armed then
        -- A window no timer sends is dropped, or it grows at every change.
        inst.reload_window = {}
        warn_once(inst, "reload", ("could not schedule a reload (%s); restart the server"):format(tostring(arm_err)))
    end
end

-- A pending window would reload after live reload is reported off.
local function drop_window(inst)
    inst.reload_window = {}
    local timer = inst.debounce_timer
    if timer and not timer:is_closing() then
        local stopped, stop_err = timer:stop()
        if not stopped then
            warn_once(inst, "reload", ("could not cancel a reload (%s)"):format(tostring(stop_err)))
        end
    end
end

-- A directory under the root the watchers miss; one gone since the scan
-- (ENOENT) is a race, not a fault.
local function cannot_watch(misses, what, cause, cause_name)
    if cause_name ~= "ENOENT" then
        misses[#misses + 1] = { what = what, cause = cause }
    end
end

-- One notice per scan, sent after the walk, naming the first miss and the
-- count, so each scan that misses a directory is heard.
local function report_misses(inst, misses)
    local first = misses[1]
    if not first then
        return
    end
    inst.warned["watch-dir"] = nil
    local more = #misses > 1 and (" and %d more under %s"):format(#misses - 1, inst.root_real) or ""
    warn_once(inst, "watch-dir", ("cannot watch %s%s (%s)"):format(first.what, more, tostring(first.cause)))
end

-- A directory whose changes never reload (a dot path, without
-- serve_dotfiles) spends no watch; with serve_dotfiles each is watched,
-- .git included.
local function dir_watched(inst, dir)
    local rel = changed_rel(inst, dir)
    if holds_own_index(inst, rel) then
        return true
    end
    return (inst.serve_dotfiles or not has_dot_segment(rel)) and not in_live_dir("/" .. rel)
end

-- Recursively scan all subdirectories under root (for Linux fallback watchers)
local function scan_dirs(inst, misses)
    local dirs = { inst.root_real }
    local function walk(dir)
        local handle, scan_err, scan_name = uv.fs_scandir(dir)
        if not handle then
            cannot_watch(misses, "the directories under " .. dir, scan_err, scan_name)
            return
        end
        while true do
            local name, typ = uv.fs_scandir_next(handle)
            if not name then
                break
            end
            local full = util.joinpath(dir, name)
            -- An untyped entry left its whole subtree unwatched.
            if typ == nil then
                local st, st_err, st_name = uv.fs_lstat(full)
                if st then
                    typ = st.type
                else
                    cannot_watch(misses, full, st_err, st_name)
                end
            end
            if typ == "directory" and name ~= "node_modules" and dir_watched(inst, full) then
                dirs[#dirs + 1] = full
                walk(full)
            end
        end
    end
    walk(inst.root_real)
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

-- Attach a single-directory fs_event watcher with a dir-aware callback.
local function add_dir_watch(inst, dir)
    local ev, new_err, new_name = uv.new_fs_event()
    if not ev then
        return nil, new_err, new_name
    end
    local cb = function(err, fname, _status)
        if err then
            return
        end
        local full = fname and fname ~= "" and util.joinpath(dir, fname) or dir
        schedule_reload(inst, full)
        -- Watch newly created subdirectories
        if fname and fname ~= "" then
            local st = uv.fs_stat(full)
            if st and st.type == "directory" and not inst._fs_events[full] and dir_watched(inst, full) then
                local added, add_err, add_name = add_dir_watch(inst, full)
                if not added and add_name ~= "ENOENT" then
                    warn_once(inst, "watch-dir", ("cannot watch %s (%s)"):format(full, tostring(add_err)))
                end
            end
        end
    end
    local started, start_err, start_name = ev:start(dir, {}, cb)
    if not started then
        ev:close()
        return nil, start_err, start_name
    end
    inst._fs_events[dir] = ev
    return true
end

-- The guard every handle closes by, where a pcall hid a second close.
local function close_watcher(ev)
    if not ev:is_closing() then
        ev:close()
    end
end

local function stop_fs_watch(inst)
    if inst.fs_event then
        close_watcher(inst.fs_event)
        inst.fs_event = nil
    end
    if inst._fs_events then
        for _, ev in pairs(inst._fs_events) do
            close_watcher(ev)
        end
        inst._fs_events = nil
    end
end

local function start_fs_watch(inst)
    stop_fs_watch(inst)

    if supports_recursive_watch() then
        -- macOS / Windows: single recursive watcher
        local single = uv.new_fs_event()
        if single then
            local cb = function(err, fname, _status)
                if err then
                    return
                end
                schedule_reload(inst, fname or "")
            end
            if single:start(inst.root_real, { recursive = true }, cb) then
                inst.fs_event = single
                return true
            end
            single:close()
        end
    end

    -- Linux (or recursive failed): per-directory watchers, the root first,
    -- since a root nothing watches is no live reload at all.
    inst._fs_events = {}
    local misses = {}
    for i, dir in ipairs(scan_dirs(inst, misses)) do
        local added, add_err, add_name = add_dir_watch(inst, dir)
        if not added then
            if i == 1 then
                stop_fs_watch(inst)
                return nil, add_err
            end
            cannot_watch(misses, dir, add_err, add_name)
        end
    end
    report_misses(inst, misses)
    return true
end

-- -------- HTML helpers (injection + templating) ---------------------------

-- A navigation is what a browser shows: a page, a frame, an object, an
-- embed or a service worker's pass-through, and a page's own fetch is
-- never one. A client with no Fetch Metadata keeps the script, and a
-- download sends the navigation's mode and gets the script too.
local function wants_injection(req)
    local mode = req and req.headers["sec-fetch-mode"]
    mode = mode and mode[1]
    return mode == nil or mode == "navigate"
end

-- Folds every Vary in headers, under any spelling of the name, and member
-- into the one field sent, with no empty member (RFC 9110 5.6.1 forbids
-- generating one) and each member once, since a repeated member adds
-- nothing.
local function join_vary(headers, member)
    local configured = {}
    for k, v in pairs(headers) do
        if k:lower() == "vary" then
            table.insert(configured, tostring(v))
            headers[k] = nil
        end
    end
    table.insert(configured, member)
    local members, seen = {}, {}
    for m in table.concat(configured, ","):gmatch("[^,]+") do
        m = m:match("^%s*(.-)%s*$")
        if m ~= "" and not seen[m:lower()] then
            seen[m:lower()] = true
            table.insert(members, m)
        end
    end
    headers.Vary = table.concat(members, ", ")
end

local function send_html_with_injection(inst, sock, html, extra_headers, req)
    if inst.inject_script and wants_injection(req) then
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
    -- With the script on, the body differs by Sec-Fetch-Mode, so a cache
    -- must not answer a navigation with a copy a page's fetch received.
    if inst.inject_script then
        join_vary(headers, "Sec-Fetch-Mode")
    end
    send_response(sock, 200, headers, html)
end

local function serve_html_file_with_injection(inst, sock, abs_path, extra_headers, req, shown)
    local body = read_file_all(abs_path)
    if not body then
        return http_404(sock, shown or "/")
    end
    send_html_with_injection(inst, sock, body, extra_headers, req)
end

-- -------- Directory listing -----------------------------------------------

-- req_path is the normalized path, decoded: the title shows it as read,
-- and each href encodes its segments.
local function dir_listing_html(inst, fs_path, req_path)
    local entries = {}
    local iter = uv.fs_scandir(fs_path)
    if not iter then
        return "<!doctype html><meta charset=utf-8><h2>Cannot read directory</h2>"
    end
    if req_path ~= "/" then
        table.insert(entries, { name = "..", is_dir = true, up = true })
    end
    local show_all = inst.dir_show_hidden and inst.serve_dotfiles
    -- A link is judged by where it points, one realpath per link: outside
    -- the root or nowhere, containment refuses it on click whatever the
    -- flags; a dot name under the root (cfg -> .git) is 404 on click, so it
    -- is hidden unless serve_dotfiles, with which the rule refuses nothing.
    -- Without it no listed directory has a dot segment of its own (the gate
    -- refused it), so the target's whole path is read. A target in the
    -- directory behind /__live/ is 404 on click whatever the flags.
    local function link_shown(name)
        local rel = root_rel(inst.root_real, util.joinpath(fs_path, name))
        return rel ~= nil and not in_live_dir(rel) and (inst.serve_dotfiles or not has_dot_segment(rel))
    end
    -- That directory is refused by its name on disk, which only the root's
    -- own listing can hold: every listing inside it is refused.
    local at_root = fs_path == inst.root_real
    while true do
        local name, t = uv.fs_scandir_next(iter)
        if not name then
            break
        end
        -- A name the dot rule refuses is not shown: show_hidden alone
        -- named .env and .git to anyone the server answers, behind 404s.
        local shown = (show_all or name:sub(1, 1) ~= ".") and not (at_root and in_live_dir("/" .. name))
        -- luv gives no type for an entry a filesystem leaves untyped (XFS
        -- with ftype=0, some NFS and FUSE mounts), so anything not typed as
        -- a file or a directory is judged as a link; a plain entry so judged
        -- costs one realpath and shows as before.
        if shown and t ~= "file" and t ~= "directory" then
            shown = link_shown(name)
        end
        if shown then
            table.insert(entries, { name = name, is_dir = (t == "directory") })
        end
    end
    table.sort(entries, function(a, b)
        if a.is_dir ~= b.is_dir then
            return a.is_dir
        end
        return a.name:lower() < b.name:lower()
    end)

    -- Each segment encoded, so no byte of a name reaches an href raw.
    local enc_path = req_path:gsub("[^/]+", util.url_encode)
    local rows = {}
    for _, e in ipairs(entries) do
        local label = util.html_escape(e.name)
        local href
        if e.up then
            local parent = enc_path:gsub("/+$", ""):match("^(.*)/[^/]*$") or "/"
            href = parent == "" and "/" or parent .. "/"
        else
            href = enc_path
                .. (enc_path:sub(-1) == "/" and "" or "/")
                .. util.url_encode(e.name)
                .. (e.is_dir and "/" or "")
        end
        local icon = e.up and "⤴" or (e.is_dir and "📁" or "📄")
        table.insert(
            rows,
            string.format('<tr><td class="ico">%s</td><td><a href="%s">%s</a></td></tr>', icon, href, label)
        )
    end

    -- Escaped once, where the page is formatted: a second escape here
    -- showed "&amp;" to a browser for a name holding an ampersand.
    local title = "Index of " .. (req_path:sub(-1) == "/" and req_path or req_path .. "/")
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

-- shown is what a 404 names: the request path, never abs_path, which gave
-- a peer the user's home directory and project layout.
local function stream_file(inst, sock, abs_path, extra_headers, shown)
    local fd = uv.fs_open(abs_path, "r", 438)
    if not fd then
        return http_404(sock, shown or "/")
    end
    -- From here the transfer owns the descriptor and closes it on every
    -- exit, once. A peer that resets or goes away shows as write's fail
    -- tuple or its callback's error (EPIPE after a reset, EBADF on a
    -- socket closed under it), never as a raise; a loop that read neither
    -- stopped there with the file open, one descriptor per abandoned
    -- download until the editor quit (measured).
    local fd_open = true
    local function close_fd()
        if fd_open then
            fd_open = false
            -- Never retried, even on an error: the number may already
            -- belong to a file opened since, which a second close takes.
            uv.fs_close(fd)
        end
    end
    local function finish()
        close_fd()
        local shut = sock:shutdown(function()
            close_once(sock)
        end)
        -- nil, err on a socket that cannot shut, which never calls back.
        if not shut then
            close_once(sock)
        end
    end
    local function abort()
        close_fd()
        close_once(sock)
    end
    -- Runs fn as a finally would: a raise closes the descriptor. The first
    -- call runs on the handler's stack, and its raise goes on to the
    -- handler with the socket still the handler's. In a callback no caller
    -- is left: luv showed the raise as a bare callback error with no
    -- notice, so it is reported here, first, and the socket closes too.
    local function step(fn, in_callback)
        local ran, err = pcall(fn)
        if ran then
            return
        end
        if not in_callback then
            close_fd()
            error(err, 0)
        end
        report_raise(inst.port, shown or "/", err)
        abort()
    end
    local CHUNK = 64 * 1024
    local offset = 0
    local function read_chunk()
        local reading = uv.fs_read(fd, CHUNK, offset, function(err_read, data)
            step(function()
                if err_read or not data then
                    return abort()
                end
                offset = offset + #data
                local sent = sock:write(data, function(err_write)
                    step(function()
                        if err_write then
                            return abort()
                        end
                        if #data < CHUNK then
                            finish()
                        else
                            read_chunk()
                        end
                    end, true)
                end)
                if not sent then
                    abort()
                end
            end, true)
        end)
        if not reading then
            abort()
        end
    end
    step(function()
        local stat = uv.fs_fstat(fd)
        if not stat or stat.type ~= "file" then
            close_fd()
            return http_404(sock, shown or "/")
        end
        local headers =
            { ["Content-Type"] = guess_mime(abs_path), ["Content-Length"] = stat.size, ["Connection"] = "close" }
        for k, v in pairs(extra_headers or {}) do
            headers[k] = v
        end
        if not write_headers(sock, 200, headers) then
            return abort()
        end
        read_chunk()
    end)
end

local function serve_path(inst, sock, abs_path, req, extra_headers, shown)
    local mime = guess_mime(abs_path)
    if mime:find("^text/html") then
        return serve_html_file_with_injection(inst, sock, abs_path, extra_headers, req, shown)
    else
        return stream_file(inst, sock, abs_path, extra_headers, shown)
    end
end

-- 127.0.0.0/8 or ::1: the binds only this machine can reach.
local function is_loopback_ip(ip)
    -- A dual-stack bind reports an IPv4 address in its IPv6-mapped form.
    local v4 = ip:match("^::[fF][fF][fF][fF]:(%d+%.%d+%.%d+%.%d+)$")
    if v4 then
        return is_loopback_ip(v4)
    end
    return ip == "::1" or (is_ipv4(ip) and ip:match("^127%.") ~= nil)
end

-- The loopback address a browser reaches a wildcard bind on, the one the
-- opened URL names, or nil for an address that is no wildcard. start's
-- probe and init.lua's URL both read it through S, so the address checked
-- is the address shown, a replaced rule included.
function S.wildcard_loopback(ip)
    if ip == "0.0.0.0" then
        return "127.0.0.1"
    end
    if ip == "::" then
        return "::1"
    end
    return nil
end

-- S.wildcard_loopback's mirror, fixed where a caller may replace that rule.
-- Each specific address probes its own family's wildcard: any IPv4 one,
-- and the IPv4-mapped spelling of one, probes 0.0.0.0, and any IPv6 one
-- probes ::, since a LAN address shadows a wildcard as loopback does.
local function wildcard_of(ip)
    -- A dual-stack bind of the mapped spelling answers IPv4 too.
    ip = ip:match("^::[fF][fF][fF][fF]:(%d+%.%d+%.%d+%.%d+)$") or ip
    if is_ipv4(ip) then
        return ip ~= "0.0.0.0" and "0.0.0.0" or nil
    end
    if ip:find(":", 1, true) then
        return ip ~= "::" and "::" or nil
    end
    return nil
end

-- Whether ip:port is free, by binding a socket that never listens and
-- closing it: true, or nil, the cause and its name. libuv holds a bind's
-- EADDRINUSE until getsockname and opens the descriptor at the bind, so an
-- EMFILE comes from there; bind raises on an address it cannot read, and
-- that raise past start left both sockets open (measured).
local function address_free(ip, port)
    local probe, err, name = uv.new_tcp()
    if not probe then
        return nil, err, name
    end
    -- ipv6only, so a probe of :: never meets an IPv4 socket (Linux).
    local flags = ip == "::" and { ipv6only = true } or nil
    local called, bound, bind_err, bind_name = pcall(probe.bind, probe, ip, port, flags)
    local free
    if not called then
        err = bound
    elseif not bound then
        err, name = bind_err, bind_name
    else
        free, err, name = probe:getsockname()
    end
    close_once(probe)
    if free then
        return true
    end
    return nil, err, name
end

-- localhost, a *.localhost name or a loopback address: the names only this
-- machine answers to.
local function is_loopback_name(name)
    return name == "localhost" or name:sub(-10) == ".localhost" or is_loopback_ip(name)
end

-- The host a request names: its absolute-form authority, else its Host.
local function request_host(req)
    return req.authority or (req.headers.host and req.headers.host[1])
end

-- A DNS-rebinding page reaches a loopback bind under its own name, so the
-- name must be one only this machine answers to. The port is never
-- compared: an ssh -L tunnel sends localhost:<its own port>. A request
-- with no Host (HTTP/1.0) passes: every browser sends one. parse_head has
-- refused a value host_name cannot read; a nil here still refuses.
local function host_ok(inst, req)
    local value = request_host(req)
    if not value then
        return true
    end
    local name = host_name(value)
    if not name then
        return false
    end
    return is_loopback_name(name) or inst.allowed_hosts[name] == true
end

-- How a browser marked this request: "cross" when Sec-Fetch-Site or Origin
-- names another site or another port, "same" only when Sec-Fetch-Site is
-- same-origin or none (a typed URL or an extension, the user's own act),
-- nil otherwise. An Origin refuses and never admits: Sec-Fetch-Site is a
-- header no page controls, while a page's own Origin rides on a WebSocket
-- handshake, so under a rebinding name it names this server.
local function request_site(req)
    local site = req.headers["sec-fetch-site"]
    site = site and site[1]
    if site and site ~= "same-origin" and site ~= "none" then
        return "cross"
    end
    local origin = req.headers.origin
    origin = origin and origin[1]
    if origin then
        local host = request_host(req)
        if host == nil or origin:lower() ~= ("http://" .. host):lower() then
            return "cross"
        end
    end
    return (site == "same-origin" or site == "none") and "same" or nil
end

-- Whether a request no browser marked may fire events. Browsers mark every
-- request to a loopback address, localhost or *.localhost, so an unmarked
-- one on a loopback bind under such a name came from a program on this
-- machine (curl, markdown-preview's raw sender). A page on any site reaches
-- a LAN address, or a name of the user's own, over plain http unmarked, so
-- there only the token, checked before dispatch, tells it apart.
local function unmarked_ok(inst, req)
    if inst.token then
        return true
    end
    if not is_loopback_ip(inst.host) then
        return false
    end
    local value = request_host(req)
    local name = value and host_name(value)
    return value == nil or (name ~= nil and is_loopback_name(name))
end

-- Whether a path needs ?t=<token>: the live endpoints and any
-- protected_paths pattern, asked only for a request that does not carry
-- the token (authorized). Start refuses a malformed pattern, and none it
-- takes is known to nest past LuaJIT's depth within 256 bytes (the
-- deepest shapes found raised on no path tried), yet each read stays
-- under pcall: a raise in the read callback left the request unanswered,
-- so one reads as a match, since the gate cannot tell what it protects.
-- A match also costs time on the loop, which a backtracking pattern
-- spends on a long path; MAX_TARGET bounds the path.
-- Every pattern is read, so the answer does not hang on the list's order.
-- A 401 alone reads like a bad token, so the first pattern that raises is
-- named once per instance (warn_once). dir: p names a directory, refused
-- when a pattern matches it with or without its slash, and each pattern
-- is read once, in its form for that (dir_form), on p with the slash; one
-- with no such form is read on both.
local function needs_auth(inst, p, dir)
    if p == "/__live/events" or p == "/__live/inject" or p == "/__live/asset" then
        return true
    end
    local needed = false
    local slashed = dir and p .. "/"
    for k, pat in ipairs(inst.protected_paths) do
        local form = dir and inst.protected_dirs[k]
        local read, hit
        if form then
            read, hit = pcall(string.find, slashed, form)
        else
            read, hit = pcall(string.find, p, pat)
            if read and not hit and dir then
                read, hit = pcall(string.find, slashed, pat)
            end
        end
        if not read then
            warn_once(
                inst,
                "pattern",
                ("cannot read protected_paths pattern %s (%s); the request was refused"):format(
                    shown(pat),
                    tostring(hit)
                )
            )
            return true
        end
        needed = needed or hit ~= nil
    end
    return needed
end

-- The asset route serves a document's neighbours, never its secrets. An
-- image may sit in any dot directory (.images), so the rule is a list of
-- names, not the dot rule. Lowercased, as a case-folding volume maps .ENV
-- to .env.
local ASSET_DENY = {
    -- Credential files by name: Vite's .env, .npmrc and .yarnrc.yml, plus
    -- the ones other tools keep.
    names = {
        [".env"] = true,
        [".envrc"] = true,
        [".npmrc"] = true,
        [".yarnrc.yml"] = true,
        [".pypirc"] = true,
        [".netrc"] = true,
        ["_netrc"] = true,
        [".pgpass"] = true,
        [".my.cnf"] = true,
        [".htpasswd"] = true,
        [".git-credentials"] = true,
        [".gitconfig"] = true,
        [".s3cfg"] = true,
        [".boto"] = true,
        [".vault-token"] = true,
        ["id_rsa"] = true,
        ["id_dsa"] = true,
        ["id_ecdsa"] = true,
        ["id_ecdsa_sk"] = true,
        ["id_ed25519"] = true,
        ["id_ed25519_sk"] = true,
    },
    -- Key and certificate files by extension: Vite's set plus Java and
    -- PuTTY key stores.
    exts = {
        pem = true,
        crt = true,
        cer = true,
        der = true,
        key = true,
        p12 = true,
        pfx = true,
        jks = true,
        keystore = true,
        ppk = true,
    },
    -- Dot directories that hold credentials, refused at any depth.
    dirs = {
        [".git"] = true,
        [".ssh"] = true,
        [".aws"] = true,
        [".kube"] = true,
        [".docker"] = true,
        [".gnupg"] = true,
    },
}

-- The first segment of path that names a credential directory, as path
-- spells it, or nil; a Windows path separates with a backslash too.
local function in_credential_dir(path)
    for seg in path:gmatch("[^/\\]+") do
        if ASSET_DENY.dirs[seg:lower()] then
            return seg
        end
    end
    return nil
end

-- An asset root's real path, or nil, what it is instead and its error's
-- name: a directory outside every credential directory, whose requests
-- the deny list would answer 404 one by one. libuv's text repeats the
-- path raw after the error's name, so the name alone is kept.
local function asset_dir(path)
    local real, real_err = uv.fs_realpath(path)
    local st, st_err = nil, real_err
    if real then
        st, st_err = uv.fs_stat(real)
    end
    if not (st and st.type == "directory") then
        return nil, "not a directory", st_err and tostring(st_err):match("^[^:]*")
    end
    local keys = in_credential_dir(real)
    if keys then
        return nil, ("inside a credential directory (%s)"):format(keys)
    end
    return real
end

-- A function asset_root's answer, held to the rule start holds a string
-- to, and absolute: a missing directory, a file or another type answered
-- every request 404 without a word, and a relative path followed the
-- working directory at each request. The real path, or nil and a warning
-- naming the answer, cut to 300 bytes and marked, once until a request's
-- root resolves again (the asset route re-arms it). nil is
-- no root yet, the caller's to say, and never reaches here. Absolute is
-- read per OS: a drive letter or a leading backslash is a relative name
-- on macOS and Linux, which followed the working directory there.
local WINDOWS = package.config:sub(1, 1) == "\\"
local function is_absolute(path)
    if WINDOWS then
        return path:find("^[/\\]") ~= nil or path:find("^%a:[/\\]") ~= nil
    end
    return path:sub(1, 1) == "/"
end
local function answered_root(inst, answer)
    local what, cause
    if type(answer) ~= "string" then
        what = "no path"
    elseif answer:find("%z") then
        what = "a path holding a NUL byte"
    elseif not is_absolute(answer) then
        what = "a relative path"
    else
        local real
        real, what, cause = asset_dir(answer)
        if real then
            return real
        end
    end
    local named = type(answer) == "string" and ('"' .. util.marked(answer, 300) .. '"') or ("a " .. type(answer))
    warn_once(
        inst,
        "asset-root",
        ("asset_root answered %s, which is %s%s; the asset request was answered 404"):format(
            named,
            what,
            cause and (" (" .. cause .. ")") or ""
        )
    )
end

-- A string asset_root, kept at start as the real path it named, read
-- again per request: a link put at that path after start (the directory
-- moved away, a link in its place) was followed with no word, and so
-- was a link given as the root and repointed, since the kept path was
-- what the check resolved. The string given, made absolute at start,
-- must still resolve to the path kept; otherwise nil and a warning,
-- naming the string, under the kind a function's faults share, once
-- until a request's root resolves again.
local function kept_root(inst, given, kept)
    local fault
    local now, now_err = uv.fs_realpath(given)
    if not now then
        fault = ("does not resolve (%s)"):format(tostring(now_err):match("^[^:]*"))
    elseif now ~= kept then
        fault = ('resolves to "%s"'):format(shown(now))
    else
        local real, what, cause = asset_dir(kept)
        if real then
            return real
        end
        fault = ("is %s%s"):format(what, cause and (" (" .. cause .. ")") or "")
    end
    warn_once(
        inst,
        "asset-root",
        ('asset_root "%s" %s since start; the asset request was answered 404'):format(shown(given), fault)
    )
end

local function asset_denied(rel)
    if in_credential_dir(rel) then
        return true
    end
    local base = rel:lower():match("([^/]+)$") or ""
    return ASSET_DENY.names[base] ~= nil
        or base:sub(1, 5) == ".env."
        or ASSET_DENY.exts[base:match("%.([^.]+)$") or ""] ~= nil
end

-- The asset route's files a browser would render as a document in this
-- server's origin. Never applied to the index page: a sandboxed page has
-- an opaque origin, and its event stream would then be cross-origin.
local ACTIVE_DOCUMENT = { html = true, htm = true, xhtml = true, svg = true, xml = true }

-- The headers of an asset-route response. The extension is read as
-- guess_mime reads it, lowercased, so PAGE.HTML on disk, served as HTML,
-- is sandboxed too. A caller's policy is kept, under any spelling of the
-- name, in one field with the sandbox last. CSP enforces each
-- comma-separated policy in a field, and the HTML standard reads the last
-- sandbox directive, so a caller's sandbox allow-scripts cannot loosen it.
local function asset_headers(inst, real)
    local ext = real:match("%.([%w]+)$")
    if not (ext and ACTIVE_DOCUMENT[ext:lower()]) then
        return inst.live_headers
    end
    local h, policies = {}, {}
    for k, v in pairs(inst.live_headers) do
        if k:lower() == "content-security-policy" then
            table.insert(policies, v)
        else
            h[k] = v
        end
    end
    table.insert(policies, "sandbox")
    h["Content-Security-Policy"] = table.concat(policies, ", ")
    return h
end

-- The root route's cors answer, read by its responses and its preflight
-- alike so the two cannot drift: the Access-Control-Allow-Origin value or
-- nil, and whether the answer varies by Origin. With a cors list the list
-- alone decides (start dropped any ACAO of the caller's, whatever its
-- case, so an unlisted Origin never gets a hand-set "*"): a listed Origin
-- is echoed, and the answer varies by Origin whether or not it was listed.
local function cors_origin(inst, req)
    if not inst.cors_list then
        return inst.headers["Access-Control-Allow-Origin"], false
    end
    local origin = req.headers.origin and req.headers.origin[1]
    if origin and vim.tbl_contains(inst.cors_list, origin) then
        return origin, true
    end
    return nil, true
end

-- The headers of a root-route response; Vary tells a cache when the
-- answer depends on the request's Origin.
local function root_headers(inst, req)
    local origin, varies = cors_origin(inst, req)
    if not varies then
        return inst.headers
    end
    local h = {}
    for k, v in pairs(inst.headers) do
        h[k] = v
    end
    join_vary(h, "Origin")
    h["Access-Control-Allow-Origin"] = origin
    return h
end

-- The four routes of the namespace, each answered by name below.
local LIVE_ROUTES = {
    ["/__live/events"] = true,
    ["/__live/inject"] = true,
    ["/__live/asset"] = true,
    ["/__live/script.js"] = true,
}

-- Answers one parsed request: the token gate, the routes and every
-- response. The connection's reader hands it a head read whole.
local function handle_request(conn, req)
    local inst, sock = conn.inst, conn.sock
    if inst.host_check and not host_ok(inst, req) then
        return send_response(
            sock,
            421,
            { ["Content-Type"] = "text/plain" },
            "Misdirected Request: this Host is no loopback name (see allowed_hosts)"
        )
    end

    -- Canonicalize the path once; the gate reads it first and the name on
    -- disk second (refusal below), and a name that passes one read and not
    -- the other is refused, so an encoded or slash-padded variant can't
    -- reach a protected file ungated.
    local path_only, names_dir = normalize_path(req.path)
    if not path_only then
        return http_400(sock, "Bad request path")
    end
    -- Dotfiles hold secrets and the listing already hides them.
    if not inst.serve_dotfiles and has_dot_segment(path_only) then
        return http_404(sock, path_only)
    end
    -- The namespace is the server's (the rule below the routes): a name
    -- in it that is no route is 404 for any method. A GET meets the token
    -- gate first; any other method never reaches the gate, so it is
    -- answered here, before the preflight, which answered /__live and
    -- /__live/ (one canonical path) as the root route's, origin and all.
    -- The first segment is read in any case here, as refusal() reads it:
    -- a case variant (/__Live/x.txt) got the root route's preflight 204
    -- and its origin line while its GET was 404. The routes stay exact.
    local namespaced = path_only == "/__live" or path_only:find("^/__live/") ~= nil
    local reserved = in_live_dir(path_only)
    -- The name the disk gives is read too, as refusal() reads it for a
    -- GET: a link elsewhere in the root into the entry got the preflight's
    -- 204 and its origin line, and 405 for any other method.
    if req.method ~= "GET" and not reserved then
        local mapped = sanitize_and_map(path_only, inst.root_real)
        local rel = mapped and root_rel(inst.root_real, mapped)
        reserved = rel and in_live_dir(rel) or false
    end
    if reserved and req.method ~= "GET" and not LIVE_ROUTES[path_only] then
        return http_404(sock, path_only)
    end
    -- A cors preflight for the root route; /__live/* answers no
    -- cross-origin read, so its preflight gets the 405 below. Both read the
    -- canonical path: /%5F_live/events is served as /__live/events.
    if req.method == "OPTIONS" and inst.cors and req.headers["access-control-request-method"] and not reserved then
        -- A browser refuses a read that carries a header outside the
        -- safelist unless the preflight names it. The names asked for are
        -- echoed when every comma-separated item is a token, never as "*":
        -- Fetch leaves Authorization out of it, and engines hold to that.
        local asked = req.headers["access-control-request-headers"]
        asked = asked and table.concat(asked, ", ")
        if asked then
            for item in (asked .. ","):gmatch("([^,]*),") do
                if not item:find("^[ \t]*" .. TCHAR .. "+[ \t]*$") then
                    asked = nil
                    break
                end
            end
        end
        local origin, varies = cors_origin(inst, req)
        return send_response(sock, 204, {
            ["Access-Control-Allow-Origin"] = origin,
            ["Access-Control-Allow-Methods"] = "GET",
            ["Access-Control-Allow-Headers"] = asked,
            ["Access-Control-Max-Age"] = "600",
            Vary = varies and "Origin, Access-Control-Request-Headers" or "Access-Control-Request-Headers",
        }, nil)
    end
    if req.method ~= "GET" then
        return send_response(sock, 405, { ["Content-Type"] = "text/plain", ["Allow"] = "GET" }, "Method Not Allowed")
    end
    local query = req.path:match("%?(.*)$") or ""

    -- Pull a query-string parameter by key. Anchored to either
    -- the start of the query or just after an '&' so we don't
    -- accidentally match a key as a substring of another (e.g.
    -- 't' inside 'event').
    local function qparam(key)
        return query:match("^" .. key .. "=([^&]*)") or query:match("&" .. key .. "=([^&]*)")
    end

    -- Auth gate. When inst.token is set, the SSE stream, the event
    -- injection endpoint, the asset route and any path in
    -- inst.protected_paths but the injected client, answered below
    -- before the gate, require a matching ?t=<token>. Static assets
    -- (/index.html, /style.css, /favicon.ico, etc.) are intentionally
    -- NOT gated because the browser bootstraps from them before any JS
    -- runs and cannot append query strings to <link>/<img> tags it
    -- discovers itself. Protect the user content (caller passes
    -- protected_paths) and the live-reload control plane.
    -- The token is read first, once per request: its holder may read
    -- every path, so a request carrying it runs no pattern, whose match
    -- spent the loop's time on a request the token opened anyway and
    -- whose raise refused the holder.
    -- Each name's answer is kept for the request: every pattern spends the
    -- loop's time on each name it reads, and the name on disk, read again
    -- below, is most often the request's own, which then read every
    -- pattern twice for one answer. A link or a case variant is another
    -- name and is still read.
    local carries_token
    local answered = { [false] = {}, [true] = {} }
    local function authorized(p, dir)
        if not inst.token then
            return true
        end
        if carries_token == nil then
            local req_token = qparam("t")
            carries_token = util.secure_compare(req_token and util.url_decode(req_token) or "", inst.token)
        end
        if carries_token then
            return true
        end
        local kept = answered[dir == true]
        if kept[p] == nil then
            kept[p] = not needs_auth(inst, p, dir)
        end
        return kept[p]
    end
    -- The injected client is answered before the gate: it holds no secret
    -- and its tag carries no token, so a pattern that matched it (%.js$,
    -- ^/) stopped live reload on every page, the client's own hint to add
    -- ?t= included. The route never reads the disk; exempted by name inside
    -- the gate instead, a file of the root's at that name, reached through
    -- a link or a case variant, was served ungated.
    if path_only == "/__live/script.js" then
        return send_response(
            sock,
            200,
            { ["Content-Type"] = "application/javascript; charset=utf-8" },
            inst.token and CLIENT_JS_TOKEN or CLIENT_JS
        )
    end
    -- A path that names a directory is read with its slash too, as the
    -- directory's own read below is, both spellings in one read (dir_form):
    -- ^/secret/ answered 401 for an existing /secret/ and 404 for a missing
    -- one, which told the two apart.
    if not authorized(path_only, names_dir and path_only ~= "/") then
        return send_response(sock, 401, { ["Content-Type"] = "text/plain" }, "Unauthorized")
    end

    -- The check above reads the request's spelling; the filesystem may serve
    -- another name for it: /CONTENT.MD on a case-folding volume, or a link,
    -- is content.md. The file or listing about to be served is checked
    -- again by its path under the root as realpath spells it. kind "own"
    -- marks the root's own index, the file the user started on: where it
    -- sits and what it is named are the caller's choice (outside the root,
    -- a .draft.html), so containment and the dot rule pass it, while a name
    -- under the root is still read by the gate. kind "dir" marks a
    -- directory about to be listed or answered.
    local function refusal(path, kind)
        local own = kind == "own"
        local rel = root_rel(inst.root_real, path)
        if not rel then
            if own then
                return nil
            end
            return 404
        end
        if not own and not inst.serve_dotfiles and has_dot_segment(rel) then
            return 404
        end
        -- A directory is named with its slash, as the request that lists
        -- it is, so ^/secret/ gates the listing too; the name without it
        -- stays read, as the request path's check reads /secret.
        if not authorized(rel, kind == "dir" and rel ~= "/") then
            return 401
        end
        -- The entry behind the namespace is refused by both names: the
        -- request's first segment in any case, since a link so named at
        -- the root resolved to another name and served what it points at,
        -- and the name the disk gives, since a link elsewhere in the root
        -- or a case variant reaches it by another (see the namespace rule).
        if not own and (in_live_dir(path_only) or in_live_dir(rel)) then
            return 404
        end
    end
    local function refuse(status)
        if status == 401 then
            return send_response(sock, 401, { ["Content-Type"] = "text/plain" }, "Unauthorized")
        end
        return http_404(sock, path_only)
    end

    -- Special endpoints
    if path_only == "/__live/events" then
        conn.sse = true
        return sse_accept(inst, sock)
    elseif path_only == "/__live/inject" then
        local site = request_site(req)
        if site == "cross" or (site == nil and not unmarked_ok(inst, req)) then
            return send_response(sock, 403, { ["Content-Type"] = "text/plain" }, "Forbidden")
        end
        local event = qparam("event")
        local data = qparam("data")
        if event then
            local decoded = data and util.url_decode(data) or "{}"
            sse_broadcast(inst, event, decoded)
        end
        return send_response(sock, 200, { ["Content-Type"] = "text/plain" }, "ok")
    elseif path_only == "/__live/asset" then
        -- The list reads the asset root's own path too: a document kept in
        -- ~/.ssh or ~/.aws would serve the credentials beside it. A string
        -- was checked at start and is read again, since it may be gone.
        local aroot, aroot_real = inst.asset_root, nil
        if type(aroot) == "function" then
            local ok_root, res = pcall(aroot)
            -- A raise read as a root not set, with no word: vim.fn inside
            -- this callback raises on every request.
            if not ok_root then
                warn_once(
                    inst,
                    "asset-root",
                    ("asset_root raised (%s); the asset request was answered 404"):format(raise_line(res))
                )
            elseif res ~= nil then
                aroot_real = answered_root(inst, res)
            end
        elseif aroot then
            aroot_real = kept_root(inst, inst.asset_given, aroot)
        end
        -- A fault that clears re-arms its warning: a root removed and
        -- made again by a build spent the one warning, and a link put
        -- there later answered 404 with no word.
        if aroot_real then
            inst.warned["asset-root"] = nil
        end
        local rel = qparam("p")
        rel = rel and util.url_decode(rel) or ""
        -- A file's name never ends in a separator or a dot segment, yet
        -- macOS's realpath resolves one on a file, and the list below read
        -- sub/.env/ as an empty name.
        local last = rel:match("[^/]*$")
        -- Relative paths only: reject absolute paths, drive
        -- letters / URL schemes (':'), backslashes and a NUL (libuv cuts
        -- a name at it) outright; realpath containment below handles
        -- '..' traversal.
        if
            not aroot_real
            or rel == ""
            or last == ""
            or last == "."
            or last == ".."
            or rel:find("^/")
            or rel:find(":")
            or rel:find("\\")
            or rel:find("%z")
        then
            return http_404(sock, "/__live/asset")
        end
        if asset_denied(rel) then
            return http_404(sock, "/__live/asset")
        end
        -- Containment and the resolved name come from one realpath: p may be
        -- a link out of the root or to a secret.
        local name, real = root_rel(aroot_real, util.joinpath(aroot_real, rel))
        if not name or asset_denied(name) then
            return http_404(sock, "/__live/asset")
        end
        -- A regular file alone: stream_file opens before it reads the type,
        -- and opening a FIFO blocks the loop past SIGTERM.
        local st = uv.fs_stat(real)
        if not st or st.type ~= "file" then
            return http_404(sock, "/__live/asset")
        end
        return stream_file(inst, sock, real, asset_headers(inst, real), "/__live/asset")
    end
    -- The namespace is the server's: a name under it that is no route never
    -- reaches the disk. This reads the request's exact spelling; the entry
    -- behind it, <root>/__live, is reached by other spellings too (a case
    -- variant, a link), so refusal() reads the request's first segment in
    -- any case and the name the disk gives. Between them, no file there is
    -- served with the root route's headers, the cors origin among them.
    if namespaced then
        return http_404(sock, path_only)
    end

    -- Map path
    local mapped = sanitize_and_map(path_only, inst.root_real)
    if not mapped then
        return http_404(sock, path_only)
    end

    local st = uv.fs_stat(mapped)
    if st and st.type == "directory" then
        -- The gate reads the directory before any page says it exists or
        -- serves its index: a "(no index)" told a protected directory
        -- reached by a case variant apart from a missing one, and an index
        -- read by its own name alone served, under a case variant or a
        -- link, the directory the gate refuses.
        local status = refusal(mapped, "dir")
        if status then
            return refuse(status)
        end
        local candidate, kind
        -- / alone names the root's own index: a link back to the root
        -- (/loop/) is a directory like any other, never a way to the
        -- default_index past a ^/$ pattern. A directory or a FIFO so named
        -- is no index, as with the names below, which answer next.
        if inst.default_index and path_only == "/" then
            local dst = uv.fs_stat(inst.default_index)
            if dst and dst.type == "file" then
                candidate, kind = inst.default_index, "own"
            end
        end
        if not candidate then
            for _, iname in ipairs(inst.index_names) do
                -- Resolved as a file request is: a linked index.html that
                -- points outside the root, at a name the dot rule refuses or
                -- into the directory behind /__live/ is not this directory's,
                -- so the next name or the listing answers; a directory named
                -- index.html is no page, and a FIFO so named would block the
                -- editor's loop.
                local try = sanitize_and_map((path_only == "/" and "" or path_only) .. "/" .. iname, inst.root_real)
                local tst = try and uv.fs_stat(try)
                local trel = tst and tst.type == "file" and root_rel(inst.root_real, try)
                if trel and not in_live_dir(trel) and (inst.serve_dotfiles or not has_dot_segment(trel)) then
                    candidate = try
                    break
                end
            end
        end
        if candidate then
            status = refusal(candidate, kind)
            if status then
                return refuse(status)
            end
            return serve_path(inst, sock, candidate, req, root_headers(inst, req), path_only)
        end
        if inst.dir_enabled then
            -- The path as normalized: the request's own spelling carries its
            -- query and whatever markup a raw target holds into every href.
            local html = dir_listing_html(inst, mapped, path_only)
            return send_html_with_injection(inst, sock, html, root_headers(inst, req), req)
        else
            return http_404(sock, path_only .. " (no index)")
        end
    elseif st and st.type == "file" then
        local status = refusal(mapped)
        if status then
            return refuse(status)
        end
        return serve_path(inst, sock, mapped, req, root_headers(inst, req), path_only)
    else
        return http_404(sock, path_only)
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

-- A connection's head timer is stopped and closed once, by whichever gets
-- there first: the head read, the connection's end, the timer's own
-- callback or the close of its socket, stop's among them.
local function conn_stop_timer(conn)
    local t = conn.timer
    conn.timer = nil
    if t and not t:is_closing() then
        t:stop()
        t:close()
    end
end

-- The head is read or refused: the connection is handled and its head
-- timer goes in one call, so no site can mark the one and forget the
-- other.
local function head_done(conn)
    conn.handled = true
    conn_stop_timer(conn)
end

-- One accepted socket's state, or nil and the error when its head timer
-- cannot be made or armed: the timer is the connection's bound, and one
-- taken without it could be held for good. A connection that never
-- finished its head held its socket until its client left (50 clients,
-- idle or with half a head sent, held 50 sockets 12 s on, measured).
-- Browsers open spare connections they may never use, so the close is
-- silent, no 408.
local function new_conn(inst, sock)
    local conn = { inst = inst, sock = sock, buf = "", handled = false }
    if inst.header_timeout > 0 then
        local timer, err = uv.new_timer()
        conn.timer = timer
        local armed
        if timer then
            armed, err = timer:start(inst.header_timeout, 0, function()
                conn_stop_timer(conn)
                if not conn.handled then
                    close_once(sock)
                end
            end)
        end
        if not armed then
            conn_stop_timer(conn)
            return nil, err
        end
    end
    return conn
end

-- A connection is open from its accept until its socket closes, whoever
-- closes it: that close takes it out of the set and the count and ends
-- its timer. Each accept reads the count, where a walk of the set cost it
-- one check per open connection (100 with 100 open, measured).
local function track_conn(conn)
    local inst = conn.inst
    inst.conns[conn] = true
    inst.open_conns = inst.open_conns + 1
    on_close[conn.sock] = function()
        inst.conns[conn] = nil
        inst.open_conns = inst.open_conns - 1
        conn_stop_timer(conn)
    end
end

-- Every read on an accepted socket lands here.
local function on_read(conn, err, chunk)
    local sock = conn.sock
    if err or not chunk then
        -- Every branch below ends the connection or leaves it to its
        -- response, so the head timer goes first, the cut head's 400 too.
        conn_stop_timer(conn)
        if conn.sse then
            sse_drop(conn.inst, sock)
            close_once(sock)
            return
        end
        -- A handled connection's socket is its response's, which closes it
        -- once written. Closed here, it cut a half-closed client's file to
        -- its head and a large page where its write stood (measured); a
        -- reset reaches the response as its write's error.
        if conn.handled then
            sock:read_stop()
            return
        end
        -- A head cut off by the client's FIN still gets an answer; a connect
        -- that sent nothing (markdown-preview's lock check) closes silently.
        if not err and not conn.handled and conn.buf ~= "" then
            conn.handled = true
            conn.buf = ""
            return http_400(sock, "Incomplete request head")
        end
        close_once(sock)
        return
    end
    -- One request per connection: bytes after the head (a pipelined request,
    -- a late chunk, anything on an event stream) are never parsed again.
    if conn.handled then
        return
    end
    conn.buf = conn.buf .. chunk
    -- A request line, after any empty lines, starts with a method token;
    -- anything else (a TLS ClientHello on the plain port) is refused at once,
    -- never left waiting for a blank line that will not come.
    local first = conn.buf:match("^[\r\n]*([^\r\n])")
    if first and not first:find("^[A-Z]") then
        head_done(conn)
        conn.buf = ""
        return http_400(sock, "Cannot parse request line")
    end
    -- A terminator of at most four bytes may straddle the previous read.
    local head_end = find_head_end(conn.buf, math.max(1, #conn.buf - #chunk - 3))
    -- The cap judges the head's bytes: while no blank line is found, a
    -- buffer within three bytes of the cap may hold a terminator's start.
    if head_end and head_end > MAX_HEAD or not head_end and #conn.buf > MAX_HEAD + 3 then
        head_done(conn)
        conn.buf = ""
        return send_response(sock, 431, { ["Content-Type"] = "text/plain" }, "Request Header Fields Too Large")
    end
    if not head_end then
        return
    end
    head_done(conn)
    local req, why, status = parse_head(conn.buf:sub(1, head_end))
    conn.buf = ""
    if status == 414 then
        return send_response(sock, 414, { ["Content-Type"] = "text/plain" }, "URI Too Long")
    end
    if not req then
        return http_400(sock, why)
    end
    local ran, raised = pcall(handle_request, conn, req)
    if ran then
        return
    end
    -- A raise in the handler left the connection open with no answer until
    -- the client gave up, and reached the editor as a callback error
    -- (measured). The client gets a 500 while no status line has gone out
    -- and a closed connection once one has; the cause goes to the user
    -- alone, never into the page. A file the raise cut short was closed by
    -- its transfer on the way out. Reported first, so a raise while the
    -- connection is answered or closed cannot swallow the notice.
    report_raise(conn.inst.port, req.path, raised)
    if started[sock] then
        close_once(sock)
    elseif not sock:is_closing() then
        send_response(
            sock,
            500,
            { ["Content-Type"] = "text/html; charset=utf-8" },
            error_page(500, "Internal Server Error", "Details are in the editor's messages")
        )
    end
end

-- A millisecond option arms a luv timer, which reads NaN as 0, a negative
-- value or math.huge as never and cuts a fraction down (measured), so each
-- takes an integer; past 2^31 - 1 ms, over 24 days, a wait is a spelling
-- of never. It raises naming the option, at level 0, as check_start's
-- refusals do.
local MAX_MS = 2147483647
local function check_ms(name, v)
    if v ~= nil and (type(v) ~= "number" or v ~= math.floor(v) or v < 0 or v > MAX_MS) then
        error(("%s must be an integer from 0 to %d"):format(name, MAX_MS), 0)
    end
    return v
end

-- libuv reads a path as a C string and cut it at a NUL, so a path holding
-- one named another file; a token, a host and a pattern are held to the
-- same rule. Raised naming the option, the value left out.
local function no_nul(name, s)
    if s:find("%z") then
        error(name .. " holds a NUL byte", 0)
    end
end

-- A FIFO root blocked the loop in the watcher's start, a file root 404ed.
local function root_directory(real)
    local st, st_err = uv.fs_stat(real)
    if not st then
        return nil, st_err
    end
    return st.type == "directory"
end

-- Read per request, a relative index or asset_root followed a later :cd
-- to another file. Absolute is read per OS (is_absolute), as the asset
-- route reads it.
local function absolute_path(path)
    if path == nil or path == "" or is_absolute(path) then
        return path
    end
    local cwd, cwd_err = uv.cwd()
    if not cwd then
        return nil, cwd_err
    end
    return util.joinpath(cwd, path)
end

-- Where a set opened at i ends, the byte after its "]", or nil: the first
-- character after "[" or "[^" is the set's own, "]" included, and a "%"
-- takes the next one with it, as LuaJIT reads a set.
local function set_end(pat, i)
    local j = i + 1
    if pat:sub(j, j) == "^" then
        j = j + 1
    end
    repeat
        if j > #pat then
            return nil
        end
        local c = pat:sub(j, j)
        j = j + 1
        if c == "%" and j <= #pat then
            j = j + 1
        end
    until pat:sub(j, j) == "]"
    return j + 1
end

-- The byte of a Lua pattern's first fault and what it is, or nil. The
-- matcher reads a part only when a subject reaches it, so trying a pattern
-- on one subject left a fault past its first literal to raise in the
-- gate. A quantifier or an anchor never faults: out of place, each is a
-- literal character. LuaJIT holds at most 32 captures. A pattern holding
-- none of ^$*+?.([%- is read by LuaJIT's find as plain text, where a lone
-- ) is a literal and nothing faults: /draft) gated /draft) in every
-- release, and the walk refused it.
local function pattern_fault(pat)
    if not pat:find("[%^%$%*%+%?%.%(%[%%%-]") then
        return nil
    end
    local i, n = 1, #pat
    local open, closed, count = {}, {}, 0
    while i <= n do
        local c = pat:sub(i, i)
        if c == "(" then
            count = count + 1
            if count > 32 then
                return i, "more than 32 captures"
            end
            table.insert(open, { count, i })
            i = i + 1
        elseif c == ")" then
            local top = table.remove(open)
            if not top then
                return i, "a ) closes no capture"
            end
            closed[top[1]] = true
            i = i + 1
        elseif c == "[" then
            local e = set_end(pat, i)
            if not e then
                return i, "a set is not closed"
            end
            i = e
        elseif c == "%" then
            local d = pat:sub(i + 1, i + 1)
            if d == "" then
                return i, "a % ends it"
            elseif d == "b" then
                if i + 3 > n then
                    return i, "%b takes two characters"
                end
                i = i + 4
            elseif d == "f" then
                if pat:sub(i + 2, i + 2) ~= "[" then
                    return i, "%f takes a set"
                end
                local e = set_end(pat, i + 2)
                if not e then
                    return i + 2, "a set is not closed"
                end
                i = e
            elseif d:find("%d") then
                if not closed[tonumber(d)] then
                    return i, ("%%%s names no closed capture"):format(d)
                end
                i = i + 2
            else
                i = i + 2
            end
        else
            i = i + 1
        end
    end
    if #open > 0 then
        return open[1][2], "a capture is not closed"
    end
end

-- Whether a literal character can be matched by an item (a character, an
-- escape, a class or a set). "$" alone reads as an anchor in a pattern
-- of its own, so it is compared as text.
local function item_matches(item, ch)
    if item == "$" then
        return ch == "$"
    end
    return ch:find("^" .. item) ~= nil
end

-- The byte of the first part of a well-formed pattern that makes a
-- request path cost seconds on the loop, and why, or nil. The gate
-- matches every pattern on the loop, read as LuaJIT's matcher reads it
-- (a capture's parenthesis skipped, any element but a literal before an
-- item no literal). Measured on an 8 KiB path unless named:
--   * A second unbounded quantifier (* or + after an item; a - there is
--     refused as a hyphen, below) splits a path in more ways than its
--     length: /.*/.*%.md$ cost 4.2 s of CPU
--     time on a 2 KiB path and 42.7 s on 4 KiB. It is taken when the
--     character right before its item is a literal the item cannot
--     match, which ends each of its runs there: /%.[^/]+%.%d+%.tmp$ cost
--     0.2 ms on every path tried.
--   * Without a leading ^ the pattern is tried at every start, so one
--     unbounded quantifier costs the square of the path's length:
--     /.*%.md$ 535 ms, ^/.*%.md$ 0.2 ms. It is taken unanchored when the
--     pattern starts with a literal that item cannot match, which ends
--     each run at the next place a match can start (the same pattern).
--     The refusal names ^.* in front, which finds what the pattern found
--     since a leading .* takes any prefix; a bare ^ narrowed it. A .* the
--     pattern starts or ends with, a final $ aside (.*$ matches any end),
--     adds nothing to a find, and kept, it made the rewrite a second
--     quantifier start refuses (^.*/secret/.*).
--   * Each ? item doubles the ways a path is tried: twenty-four took 1 s
--     on a 26-byte path, and eight after a wildcard 175 ms on 8 KiB, so
--     two are taken.
--   * A balanced match (%bxy) scans to the path's end wherever it cannot
--     balance, a scan no rule above counts: unanchored, %b() cost
--     30 ms on 8 KiB of ( and .?.?%b() 132 ms. No path rule needs one, so
--     it is refused; a frontier (%f) reads two bytes and is taken.
--   * Every try reads as much of the pattern as matches, so its length
--     multiplies the cost: a wildcard, eight ? items and a 1000-byte tail
--     took 14 s. 256 bytes are taken. The costliest shape found that the
--     rules then take, two ? items before 32 nested captures and a
--     literal tail filling the 256 bytes, costs at most about 105 ms for
--     one read of an 8 KiB path, the figure the README states below its
--     start-key table beside how many reads a request makes.
-- One rule here is no cost: a - after an item is a name's hyphen read
-- as a lazy repetition, so ^/my-notes%.md$ and ^/%d%d%d%d-%d%d%.md$
-- found no hyphen and served the file without the token. After any
-- item, a class or a set too, x- finds what x* finds, so a - used as a
-- quantifier is refused at the -, naming %- and *, and no rule is lost.
local HYPHEN = "a - after an item repeats it and finds no hyphen:"
    .. " write %- for a hyphen; a lazy repeat finds what * finds, write * to repeat"
local SECOND = "a second unbounded quantifier makes a request path cost seconds of the editor's time"
local UNANCHORED = "an unbounded quantifier in a pattern not anchored with ^ tries every start position,"
    .. " so a request path costs the square of its length; write ^.* in front to keep the same matches,"
    .. " and drop a .* it starts or ends with, a final $ aside: it adds nothing to a find"
local OPTIONAL = "more than two ? items double a request path's cost with each one"
local LONG = "a pattern longer than 256 bytes multiplies a request path's cost by its length"
local BALANCED = "a balanced match (%b) scans a request path without bound and has no place in a path rule"
local function pattern_cost(pat)
    if #pat > 256 then
        return 257, LONG
    end
    local anchored = pat:sub(1, 1) == "^"
    local i, n = anchored and 2 or 1, #pat
    -- first: the pattern's first element when it is a fixed literal,
    -- false when it is anything else, nil before it is read.
    local seen, before, first, optional = false, nil, nil, 0
    while i <= n do
        local c, d = pat:sub(i, i), pat:sub(i + 1, i + 1)
        if c == "(" or c == ")" then
            i = i + 1
        elseif c == "$" and i == n then
            break
        elseif c == "%" and d == "b" then
            return i, BALANCED
        elseif c == "%" and (d == "f" or d:find("%d")) then
            before = nil
            first = first == nil and false or first
            i = d == "f" and set_end(pat, i + 2) or i + 2
        else
            local stop = c == "%" and i + 2 or c == "[" and set_end(pat, i) or i + 1
            local item, q = pat:sub(i, stop - 1), pat:sub(stop, stop)
            -- A literal: one character but ".", or "%" and a character
            -- that is no letter or digit.
            local literal = (#item == 1 and item ~= ".") and item or (c == "%" and not d:find("%w") and d) or nil
            if q == "-" then
                return stop, HYPHEN
            end
            if q == "*" or q == "+" then
                if seen and not (before and not item_matches(item, before)) then
                    return stop, SECOND
                end
                if not seen and not anchored and not (first and not item_matches(item, first)) then
                    return stop, UNANCHORED
                end
                seen, before, first = true, nil, first or false
                i = stop + 1
            elseif q == "?" then
                optional = optional + 1
                if optional > 2 then
                    return stop, OPTIONAL
                end
                before, first = nil, first == nil and false or first
                i = stop + 1
            else
                before = literal
                if first == nil then
                    first = literal or false
                end
                i = stop
            end
        end
    end
end

-- A path naming a directory is refused when a pattern matches its name
-- with or without the slash, and reading both spellings spent the loop's
-- time twice. This is the form of a pattern that answers for both in one
-- read, on the name with the slash. A match without the slash is one with
-- it too, since the slash only adds a byte after it, except at the end:
-- an end anchor, which the form takes the slash as optional before, and
-- a frontier whose set holds one of "/" and the path's end (read as "\0")
-- but not the other (%f[%z], %f[^/]), which tells the two apart there;
-- for that pattern the form is nil and the gate reads both spellings.
-- Taken patterns hold no %b, which this walk would misread.
local function dir_form(pat)
    local i, n = 1, #pat
    while i <= n do
        local c, d = pat:sub(i, i), pat:sub(i + 1, i + 1)
        if c == "[" then
            i = set_end(pat, i)
        elseif c == "%" and d == "f" then
            local e = set_end(pat, i + 2)
            local set = "^" .. pat:sub(i + 2, e - 1)
            if (("\0"):find(set) ~= nil) ~= (("/"):find(set) ~= nil) then
                return nil
            end
            i = e
        elseif c == "%" then
            i = i + 2
        elseif c == "$" and i == n then
            return pat:sub(1, n - 1) .. "/?$"
        else
            i = i + 1
        end
    end
    return pat
end

-- A malformed pattern's bytes around its fault, at most 40 each side, and
-- the first and last byte shown. The refusal named a byte of the pattern
-- and showed it marked and cut at 300 bytes, so a fault past the cut was
-- not shown and one after a mark was named where the text shown did not
-- hold it. Each byte of a control, or of a sequence no UTF-8 reader
-- accepts, is a ?, so the text shown counts as the pattern does.
local function fault_window(pat, at)
    local lo, hi = math.max(1, at - 40), math.min(#pat, at + 40)
    local s, out, i = pat:sub(lo, hi), {}, 1
    while i <= #s do
        local len = util.utf8_len(s, i) or 1
        local seq = s:sub(i, i + len - 1)
        table.insert(out, util.marked(seq) == seq and seq or ("?"):rep(len))
        i = i + len
    end
    return table.concat(out), lo, hi
end

-- The keys start reads, a nested table for a section (util.unread_key).
local START_KEYS = {
    token = true,
    port = true,
    host = true,
    allowed_hosts = true,
    protected_paths = true,
    index_names = true,
    serve_dotfiles = true,
    headers = true,
    cors = true,
    live = { enabled = true, inject_script = true, css_inject = true, debounce = true },
    features = { dirlist = { enabled = true, show_hidden = true } },
    notify_on_reload = true,
    default_index = true,
    header_timeout_ms = true,
    sse_heartbeat_ms = true,
    max_connections = true,
    asset_root = true,
    root = true,
}

-- Start's options, each read from the caller's table once and checked
-- before any handle opens, so a refusal leaks nothing; start reads only the
-- copy returned. A table that computes a field could otherwise pass a check
-- with one value and hand the server another. The caller shows a refusal
-- to the user, so each raises at level 0.
local function check_start(cfg)
    if type(cfg) ~= "table" then
        error("start takes a table of options", 0)
    end
    local unread = util.unread_key(cfg, START_KEYS)
    if unread then
        error("start does not read the key " .. unread, 0)
    end
    -- An empty token is truthy and would pass the gate with no t= at all.
    local token = cfg.token
    if token ~= nil and (type(token) ~= "string" or token == "") then
        error("token must be a non-empty string", 0)
    end
    if token ~= nil then
        no_nul("token", token)
    end
    -- The stream refuses the encoded URL of a non-UTF-8 token (measured).
    if token ~= nil then
        local i = 1
        while i <= #token do
            local n = util.utf8_len(token, i)
            if not n then
                error("token must be valid UTF-8", 0)
            end
            i = i + n
        end
        -- The token travels URL-encoded in the query, which the 8 KiB
        -- target cap counts: 1400 of U+00E9 encode to 8400 bytes, and every
        -- request carrying them was a 414 (measured). Half the cap leaves
        -- room for a path; random_token makes at most 2048 characters.
        local encoded = #util.url_encode(token)
        if encoded > 4096 then
            error(("token must be at most 4096 bytes once URL-encoded, got %d"):format(encoded), 0)
        end
    end
    -- luv truncates a port it cannot hold and listens on another one.
    local p = cfg.port
    if type(p) ~= "number" or p ~= math.floor(p) or p < 0 or p > 65535 then
        error(("port must be an integer from 0 to 65535, got %s (%s)"):format(shown(tostring(p)), type(p)), 0)
    end
    -- A host that is no string reached the bind, and a table raised while
    -- the bind's error was written, naming no option.
    local host = cfg.host
    if host ~= nil and type(host) ~= "string" then
        error("host must be a string", 0)
    end
    if host ~= nil then
        no_nul("host", host)
    end
    -- libuv binds an IP literal alone, so a name, an empty string or a
    -- bracketed literal met no check here and was refused by the
    -- bind as an invalid address, naming no option. An IPv6 address may
    -- carry a zone (fe80::1%en0), an interface name: letters, digits, ".",
    -- "_" and "-". Any other zone (a second %, a control byte, a space)
    -- reached the bind, which dropped a zone it could not read without a
    -- word. "localhost" is read as 127.0.0.1 below.
    local address = host and (host:match("^(.-)%%[%w._-]+$") or host)
    if host ~= nil and host ~= "localhost" and not (is_ipv4(host) or is_ipv6(address)) then
        error(('host must be an IP address or "localhost", got "%s"'):format(shown(host)), 0)
    end
    local allowed = cfg.allowed_hosts
    local allowed_set = {}
    if allowed ~= nil and allowed ~= true then
        -- The list is walked with ipairs, which stops at a hole and skips
        -- every key of a map, so either would drop names without a word.
        if type(allowed) ~= "table" or not vim.islist(allowed) then
            error("allowed_hosts must be true or a list of hostnames", 0)
        end
        for _, name in ipairs(allowed) do
            if type(name) ~= "string" or name == "" then
                error("allowed_hosts must be true or a list of hostnames", 0)
            end
            -- A wildcard reads as a reg-name and matches no subdomain, only
            -- that literal name.
            if name:find("*", 1, true) then
                error("allowed_hosts takes exact names, no wildcard: " .. util.marked(name, 300), 0)
            end
            -- The check reads a Host through host_name, so an entry must be
            -- what host_name would return for it: a port, brackets or a
            -- spelling the grammar rejects could never match and stay inert.
            local key = (name:lower():gsub("%.$", ""))
            local read = host_name(name) or host_name("[" .. name .. "]")
            if read ~= key then
                error("allowed_hosts entry is not a hostname: " .. util.marked(name, 300), 0)
            end
            allowed_set[key] = true
        end
    end
    -- needs_auth walks the patterns with ipairs, so a map protected nothing
    -- and the entries after a hole were never read; a number matched as its
    -- digits, and a table, a boolean or a malformed pattern ("(", "%")
    -- raised inside the read callback, and every request went unanswered
    -- (measured).
    local protected = cfg.protected_paths
    if protected ~= nil then
        if type(protected) ~= "table" or not vim.islist(protected) then
            error("protected_paths must be a list of Lua patterns", 0)
        end
        for _, pat in ipairs(protected) do
            if type(pat) ~= "string" then
                error("protected_paths must be a list of Lua patterns", 0)
            end
            no_nul("protected_paths pattern", pat)
            local at, why = pattern_fault(pat)
            if at then
                local text, lo, hi = fault_window(pat, at)
                local span = (lo > 1 or hi < #pat) and (", bytes %d to %d"):format(lo, hi) or ""
                error(("protected_paths pattern is malformed at byte %d (%s)%s: %s"):format(at, why, span, text), 0)
            end
            at, why = pattern_cost(pat)
            if at then
                local text, lo, hi = fault_window(pat, at)
                local span = (lo > 1 or hi < #pat) and (", bytes %d to %d"):format(lo, hi) or ""
                error(("protected_paths pattern is refused at byte %d (%s)%s: %s"):format(at, why, span, text), 0)
            end
        end
    end
    -- The patterns gate by the token, so without one they started and
    -- gated nothing, without a word; an empty list asks for none.
    if protected ~= nil and #protected > 0 and token == nil then
        error("protected_paths needs a token", 0)
    end
    -- Each name is joined to a directory's path in the read callback, where
    -- a string raised and every directory request went unanswered
    -- (measured).
    local index_names = cfg.index_names
    if index_names ~= nil then
        if type(index_names) ~= "table" or not vim.islist(index_names) then
            error("index_names must be a list of file names", 0)
        end
        for _, iname in ipairs(index_names) do
            if type(iname) ~= "string" or iname == "" then
                error("index_names must be a list of file names", 0)
            end
            no_nul("index_names entry", iname)
            -- A name is joined to the directory it indexes, so a path in it
            -- read another directory's file as this one's index.
            if iname:find("[/\\]") or iname == "." or iname == ".." then
                error("index_names entry is not a file name: " .. shown(iname), 0)
            end
        end
    end
    -- Any value but true read as false, so serve_dotfiles = 1 served no
    -- dotfile without a word.
    local dotfiles = cfg.serve_dotfiles
    if dotfiles ~= nil and type(dotfiles) ~= "boolean" then
        error("serve_dotfiles must be true or false, got " .. type(dotfiles), 0)
    end
    -- A header is written as the table spells it. Chromium trims a name, so
    -- "Access-Control-Allow-Origin " let any site read the event stream
    -- (measured); a colon in a name or a CR or LF in a value sends a header
    -- other than the one named, and a value holds no other control byte but
    -- a tab (RFC 9110 5.5): a NUL made Chromium and curl refuse every
    -- response. The fields the server computes are its own: a caller's
    -- replaced them or went out beside them, a second framing line, or a
    -- Content-Type that rendered an asset as HTML past the sandbox its
    -- extension decides. Two spellings of one name went out as two lines,
    -- which a cache reads as one list. The copy comes from the same pass,
    -- so the table served is the one checked. false is refused as for
    -- the other table keys, where it read as no headers.
    local cfg_headers = cfg.headers
    if cfg_headers == nil then
        cfg_headers = {}
    elseif type(cfg_headers) ~= "table" then
        error("headers must be a table of header names and values", 0)
    end
    local headers, spelled = {}, {}
    for k, v in pairs(cfg_headers) do
        -- Before the refusal below, which repeats the name raw.
        for _, s in ipairs({ k, v }) do
            if type(s) == "string" then
                no_nul("headers", s)
            end
        end
        if
            type(k) ~= "string"
            or not k:find("^" .. TCHAR .. "+$")
            or type(v) ~= "string"
            or v:find("[%z\1-\8\10-\31\127]")
        then
            error("headers: a name must be a token and a value a line: " .. shown(tostring(k)), 0)
        end
        local name = k:lower()
        if SERVER_FIELDS[name] then
            error(("headers: %s is the server's own field"):format(shown(k)), 0)
        end
        if spelled[name] then
            local a, b = spelled[name], k
            if b < a then
                a, b = b, a
            end
            error(("headers: %s and %s name one field"):format(shown(a), shown(b)), 0)
        end
        spelled[name] = k
        headers[k] = v
    end
    -- A cors value goes out as a header value, so a CR or LF in it wrote a
    -- header line of its own; a value that is no origin as a browser sends
    -- it could never match, and a list is walked with ipairs, which skips a
    -- map's keys. "*" is the documented spelling of true. Read once and the
    -- list copied, so the value served is the one checked.
    local cors = cfg.cors
    if cors ~= nil and cors ~= false and cors ~= true and cors ~= "*" then
        local list = type(cors) == "table" and cors or { cors }
        if type(cors) == "table" and not vim.islist(cors) then
            error("cors must be true, an origin or a list of origins", 0)
        end
        for _, origin in ipairs(list) do
            if type(origin) ~= "string" then
                error("cors must be true, an origin or a list of origins", 0)
            end
            if not is_origin(origin) then
                error(('cors entry is not an origin (scheme://host[:port]): "%s"'):format(shown(origin)), 0)
            end
            if not as_browser_sends(origin) then
                local why = "cors entry is not an origin as a browser sends it (lower case, no default port): "
                error(why .. shown(origin), 0)
            end
        end
    end
    -- /__live/* answers no cross-origin read: the stream and the asset route
    -- get the caller's headers minus any ACAO, under any spelling, and cors
    -- applies to the root route only. With cors set its line is the one
    -- origin: a caller's ACAO beside it went out as a second line, and a
    -- browser refuses a response with two.
    local live_headers = {}
    for k, v in pairs(headers) do
        if k:lower() ~= "access-control-allow-origin" then
            live_headers[k] = v
        elseif cors then
            headers[k] = nil
        end
    end
    if cors and type(cors) ~= "table" then
        headers["Access-Control-Allow-Origin"] = type(cors) == "string" and cors or "*"
    end
    -- Each is indexed as given, where a number raised as a fault in this
    -- code, naming no option.
    local live, features = cfg.live, cfg.features
    if live ~= nil and type(live) ~= "table" then
        error("live must be a table", 0)
    end
    if features ~= nil and type(features) ~= "table" then
        error("features must be a table", 0)
    end
    local dirlist = features and features.dirlist
    if dirlist ~= nil and type(dirlist) ~= "table" then
        error("features.dirlist must be a table", 0)
    end
    -- A flag turned off on exactly false, so 0 or "no" turned it on.
    local function flag(name, v)
        if v ~= nil and type(v) ~= "boolean" then
            error(name .. " must be true or false, got " .. type(v), 0)
        end
        return v
    end
    local live_on = flag("live.enabled", live and live.enabled)
    local inject = flag("live.inject_script", live and live.inject_script)
    local css_inject = flag("live.css_inject", live and live.css_inject)
    local dir_on = flag("features.dirlist.enabled", dirlist and dirlist.enabled)
    local show_hidden = flag("features.dirlist.show_hidden", dirlist and dirlist.show_hidden)
    local notify_on_reload = flag("notify_on_reload", cfg.notify_on_reload)
    -- Every GET / reads it as a path, where any other type answered 500;
    -- an empty one named no file, so / fell to the index names with no
    -- word.
    local default_index = cfg.default_index
    if default_index ~= nil and (type(default_index) ~= "string" or default_index == "") then
        error("default_index must be a non-empty string", 0)
    end
    if default_index ~= nil then
        no_nul("default_index", default_index)
    end
    local index_err
    default_index, index_err = absolute_path(default_index)
    if index_err then
        error("default_index is relative and the working directory is unknown: " .. tostring(index_err), 0)
    end
    -- A debounce that is no number raised in the watcher's callback at
    -- every file change (measured).
    local debounce = check_ms("live.debounce", live and live.debounce)
    -- Every connection arms a timer with it; 0 turns the timeout off.
    local header_timeout = check_ms("header_timeout_ms", cfg.header_timeout_ms)
    -- The server's beat timer repeats at it; 0 turns the heartbeat off.
    local heartbeat = check_ms("sse_heartbeat_ms", cfg.sse_heartbeat_ms)
    -- Each accept compares the open count with it: text raised there at
    -- every connection and left its socket open, 0 closed them all, 1.5
    -- held 2, and NaN or math.huge capped nothing (measured).
    local max_conns = cfg.max_connections
    if
        max_conns ~= nil
        and (
            type(max_conns) ~= "number"
            or max_conns ~= math.floor(max_conns)
            or max_conns < 1
            or max_conns == math.huge
        )
    then
        error("max_connections must be an integer at or above 1", 0)
    end
    -- A number, or a string naming no directory, started and then answered
    -- every asset request 404 without a word (measured). A string is kept
    -- as its real path, since a relative one followed a later :cd; a
    -- function is left to each request, whose caller may retarget it.
    local asset_root, asset_given = cfg.asset_root, nil
    if asset_root ~= nil and type(asset_root) ~= "string" and type(asset_root) ~= "function" then
        error("asset_root must be a directory or a function returning one, got " .. type(asset_root), 0)
    end
    if type(asset_root) == "string" then
        no_nul("asset_root", asset_root)
        -- Named marked, beside the error's name (asset_dir). A root inside
        -- a credential directory had that same silent 404 on every request.
        local real, what, cause = asset_dir(asset_root)
        if not real then
            error(
                ('asset_root is %s: "%s"%s'):format(what, shown(asset_root), cause and (" (" .. cause .. ")") or ""),
                0
            )
        end
        -- The string is kept too, made absolute, since each request
        -- resolves it again (kept_root) and a relative one followed a
        -- later :cd.
        local given_err
        asset_given, given_err = absolute_path(asset_root)
        if not asset_given then
            error("asset_root is relative and the working directory is unknown: " .. tostring(given_err), 0)
        end
        asset_root = real
    end
    -- fs_realpath raised its own argument error for a nil root and read a
    -- number as a path under the working directory.
    local root = cfg.root
    if type(root) ~= "string" then
        error("root must be a string", 0)
    end
    no_nul("root", root)
    -- Worded as update_target words it, the cause named: "Invalid root"
    -- left a user to guess between a typo and a permission.
    local root_real, real_err = uv.fs_realpath(root)
    if not root_real then
        error(("root %s does not resolve (%s)"):format(shown(root), tostring(real_err):match("^[^:]*")), 0)
    end
    -- libuv's text repeats the path raw after the error's name, so the
    -- name alone is kept, as asset_dir keeps it.
    local is_dir, dir_err = root_directory(root_real)
    if not is_dir then
        local cause = dir_err and (" (" .. tostring(dir_err):match("^[^:]*") .. ")") or ""
        error("root must be a directory: " .. shown(root) .. cause, 0)
    end

    return {
        token = token,
        port = p,
        -- libuv binds IP literals only; users write "localhost" for loopback.
        host = (host == nil or host == "localhost") and "127.0.0.1" or host,
        -- true turns the Host check off; the set holds the listed names as
        -- host_name reads a Host.
        any_host = allowed == true,
        allowed_hosts = allowed_set,
        -- Copies of the checked lists: the caller's table (init.lua hands the
        -- user's own) holed or emptied after start dropped the gate, and
        -- index_names changed after start named an index never checked.
        protected_paths = vim.list_extend({}, protected or {}),
        -- Each pattern's form for a path naming a directory, false where
        -- none reads both spellings at once (dir_form).
        protected_dirs = vim.tbl_map(function(pat)
            return dir_form(pat) or false
        end, protected or {}),
        index_names = index_names and vim.list_extend({}, index_names) or { "index.html", "index.htm" },
        serve_dotfiles = dotfiles == true,
        headers = headers,
        live_headers = live_headers,
        cors = cors and true or false,
        cors_list = type(cors) == "table" and vim.list_extend({}, cors) or nil,
        root = root,
        root_real = root_real,
        default_index = default_index,
        live_enabled = live and live_on ~= false,
        inject_script = live and inject ~= false,
        live_debounce = debounce or 120,
        css_inject = live and css_inject ~= false,
        dir_enabled = dir_on ~= false,
        dir_show_hidden = show_hidden == true,
        notify_on_reload = notify_on_reload == true,
        asset_root = asset_root,
        asset_given = asset_given,
        header_timeout = header_timeout or 10000,
        heartbeat_ms = heartbeat or 20000,
        max_connections = max_conns or 64,
    }
end

-- A .liveignore that cannot be read, or lines of it skipped for a NUL, is
-- named once under one kind, re-armed by a retarget to another root.
local function read_liveignore(inst)
    local rules, why, skipped = util.parse_liveignore(inst.root_real)
    inst.ignore_patterns = rules or {}
    local file = util.joinpath(inst.root_real, ".liveignore")
    if not rules then
        warn_once(inst, "liveignore", ("ignores %s: %s"):format(file, why))
    elseif skipped then
        local which = #skipped == 1 and ("line %d of %s: it holds"):format(skipped[1], file)
            or ("%d lines of %s, the first line %d: each holds"):format(#skipped, file, skipped[1])
        warn_once(inst, "liveignore", ("skips %s a NUL byte, which no path holds"):format(which))
    end
end

-- Live reload reported on with nothing watching reloads nothing and says
-- nothing. A watcher that starts re-arms the warning, so a later failure
-- is heard; the cause is returned for a caller that reports the toggle.
local function watch_or_warn(inst)
    local watching, watch_err = start_fs_watch(inst)
    if watching then
        inst.warned.watch = nil
        return true
    end
    inst.live_enabled = false
    drop_window(inst)
    local cause = ("could not watch %s (%s)"):format(inst.root, tostring(watch_err))
    warn_once(inst, "watch", cause .. "; live reload is off")
    return false, cause
end

-- One bind and the probes before the listen: the socket and its
-- address, or nil, the refusal and whether a probe found the port held.
local function bind_probed(host, port)
    -- Unread, a nil here was indexed by the bind and raised at this file's
    -- line, naming nothing a user could act on.
    local tcp, tcp_err = uv.new_tcp()
    if not tcp then
        return nil, "Failed to bind " .. host .. ":" .. tostring(port) .. ": no socket: " .. tostring(tcp_err)
    end
    -- luv returns a failed bind as nil, err, which a pcall alone never sees,
    -- and listen binds an unbound socket to every interface. bind raises
    -- only on an address it cannot parse, which the pcall catches. The caller
    -- shows the message to the user, so the raise is at level 0.
    local called, bound_ok, bind_err = pcall(tcp.bind, tcp, host, port)
    if not called or not bound_ok then
        close_once(tcp)
        local reason = called and bind_err or bound_ok
        return nil, "Failed to bind " .. host .. ":" .. tostring(port) .. ": " .. tostring(reason)
    end

    -- The bound address, not the configured spelling, decides the Host
    -- check: 0:0:0:0:0:0:0:1 and ::ffff:127.0.0.1 are loopback binds too.
    -- It also carries the OS-assigned port when cfg.port is 0. libuv holds
    -- a bind's EADDRINUSE until here, so a failure reads as the bind's.
    local bound, sockname_err = tcp:getsockname()
    if not bound then
        close_once(tcp)
        return nil, "Failed to bind " .. host .. ":" .. tostring(port) .. ": " .. tostring(sockname_err)
    end

    -- macOS and Windows let a listener bound to the loopback address alone
    -- share the port with a wildcard bind and take every connection to that
    -- address, where the opened URL, token and all, would go (measured on
    -- macOS; Linux refuses the bind above). start serves only when a probe
    -- before the listen finds the address free, or absent from this
    -- machine, which no listener can hold: a probe that failed any other
    -- way cannot tell, and a real EMFILE there once let the URL reach
    -- another program (measured). A caller may replace the rule, and one
    -- that raised went past start with the server's socket open.
    local here = host .. ":" .. tostring(bound.port)
    local ruled, loopback = pcall(S.wildcard_loopback, bound.ip)
    if not ruled then
        close_once(tcp)
        return nil, ("Failed to bind %s: the loopback rule raised: %s"):format(here, tostring(loopback))
    end
    if loopback then
        local free, why, why_name = address_free(loopback, bound.port)
        if not free and why_name ~= "EADDRNOTAVAIL" then
            close_once(tcp)
            local there = tostring(loopback) .. ":" .. tostring(bound.port)
            if why_name == "EADDRINUSE" then
                return nil,
                    ("Failed to bind %s: another socket holds %s, the address the URL names (%s)"):format(
                        here,
                        there,
                        tostring(why)
                    ),
                    true
            end
            return nil,
                ("Failed to bind %s: cannot check %s, the address the URL names: %s"):format(here, there, tostring(why))
        end
    end

    -- macOS lets a loopback bind shadow another program's wildcard
    -- listener (measured). This socket, bound and not listening, never
    -- meets the probe (measured on macOS).
    -- Linux refuses that bind at the bind; a probe there refuses free ones.
    local info = uv.os_uname()
    local shadows = not (info and info.sysname == "Linux")
    local wildcard = shadows and wildcard_of(bound.ip)
    if wildcard then
        local free, why, why_name = address_free(wildcard, bound.port)
        if not free then
            close_once(tcp)
            local there = wildcard .. ":" .. tostring(bound.port)
            if why_name == "EADDRINUSE" then
                local held = "Failed to bind %s: another socket holds"
                    .. " a wildcard on port %d, which this address would"
                    .. " shadow (%s)"
                return nil, held:format(here, bound.port, tostring(why)), true
            end
            return nil, ("Failed to bind %s: cannot check %s: %s"):format(here, there, tostring(why))
        end
    end

    return tcp, bound
end

-- -------- Public server API -----------------------------------------------

-- cfg: { port, root, default_index|nil, headers, cors, live={enabled,inject_script,debounce,css_inject}, features={dirlist={enabled,show_hidden}}, host, token, protected_paths, serve_dotfiles, index_names, notify_on_reload, asset_root, allowed_hosts, header_timeout_ms, sse_heartbeat_ms, max_connections }
-- header_timeout_ms (default 10000, 0 off): a connection whose head is not
-- read by then is closed with no response.
-- sse_heartbeat_ms (default 20000, 0 off): every event stream is written
-- a comment line (": ping") at that interval, which EventSource ignores.
-- max_connections (default 64): a connection accepted while that many are
-- open is closed at once, unread and unanswered.
-- Raises at level 0, returning nothing, when it cannot serve: a refused
-- option, a failed bind or listen, a port in use, a reload timer it cannot
-- make, a heartbeat whose timer cannot be armed, or a wildcard bind whose
-- URL's loopback address another socket holds or start cannot check, or
-- a loopback bind whose wildcard of its family the same holds for. A root
-- whose watcher cannot start is served with live reload off and one
-- warning. A caller reads S.features.start_raises before it relies on that.
function S.start(cfg)
    local checked = check_start(cfg)
    local host = checked.host
    -- On port 0 the OS may choose a port a wildcard listener holds, which a
    -- probe refuses (measured 0 in 2000 on macOS), so it binds again, at
    -- most three times.
    local tcp, bound, held
    for _ = 1, checked.port == 0 and 4 or 1 do
        tcp, bound, held = bind_probed(host, checked.port)
        if tcp or not held then
            break
        end
    end
    if not tcp then
        error(bound, 0)
    end
    local actual_port = bound.port

    local inst = {
        handle = tcp,
        port = actual_port,
        -- A later reader compares it to the loopback rule, and the configured
        -- spelling may differ; cfg.host keeps what was asked for.
        host = bound.ip,
        -- Network binds are reached by names no default list knows; the
        -- token gates them.
        host_check = is_loopback_ip(bound.ip) and not checked.any_host,
        -- Names the user controls; one whose DNS an attacker controls
        -- reopens rebinding (the Vite docs' warning).
        allowed_hosts = checked.allowed_hosts,
        root = checked.root,
        root_real = checked.root_real,
        default_index = checked.default_index,
        headers = checked.headers,
        live_headers = checked.live_headers,
        cors = checked.cors,
        cors_list = checked.cors_list,
        started_at = os.time(),
        -- Every open connection, which stop closes, and how many.
        conns = {},
        open_conns = 0,
        max_connections = checked.max_connections,
        header_timeout = checked.header_timeout,

        -- live
        live_enabled = checked.live_enabled,
        inject_script = checked.inject_script,
        live_debounce = checked.live_debounce,
        css_inject = checked.css_inject,
        sse_clients = {},
        -- Path to the number of its latest change (schedule_reload).
        reload_window = {},
        reload_seq = 0,
        heartbeat_ms = checked.heartbeat_ms,
        -- The kinds of fault the user was told of (warn_once).
        warned = {},
        -- Warnings found during start, sent once it serves.
        queued = {},

        -- features
        dir_enabled = checked.dir_enabled,
        dir_show_hidden = checked.dir_show_hidden,
        index_names = checked.index_names,
        -- read_liveignore fills it once the instance can warn.
        ignore_patterns = {},
        notify_on_reload = checked.notify_on_reload,

        -- auth
        token = checked.token, -- nil = no auth; string = required on protected paths
        protected_paths = checked.protected_paths,
        protected_dirs = checked.protected_dirs,
        serve_dotfiles = checked.serve_dotfiles,

        -- /__live/asset root: a directory, or a function returning one.
        -- Lets a caller expose files that live next to its source document
        -- (e.g. images referenced from markdown) without serving that
        -- directory as the root. Token-gated whenever token is set.
        asset_root = checked.asset_root,
        -- A string asset_root as given, made absolute (kept_root).
        asset_given = checked.asset_given,
    }
    read_liveignore(inst)

    -- A connection the server cannot equip with a handle, or whose read
    -- cannot start, is dropped, and the user is told (warn_once). With no
    -- socket the connection is never accepted, and libuv then stops
    -- polling the listener, so the server takes no connection after it; a
    -- raise there did the same and told the user only of a callback error
    -- (measured, the handle stubbed to nil). With no head timer, or no
    -- read, the connection is closed: unread and with no timer it held its
    -- place after its client left (measured), and a close alone would
    -- leave a page failing with no word of why.
    local listening, listen_err = tcp:listen(128, function(err_listen)
        if err_listen then
            return
        end
        local sock, sock_err = uv.new_tcp()
        if not sock then
            warn_once(
                inst,
                "socket",
                ("stopped accepting connections (%s); restart the server"):format(tostring(sock_err))
            )
            return
        end
        -- A failed accept leaves a handle made and never opened, which
        -- nothing else would close.
        if not tcp:accept(sock) then
            close_once(sock)
            return
        end
        -- A cap on held sockets: a page opens a handful, a flood opens more
        -- than the editor's descriptor limit. A place is what the cap
        -- protects, so a connection over it is given none of what a place
        -- buys: a read, a head timer, an entry in the count.
        if inst.open_conns >= inst.max_connections then
            close_once(sock)
            return
        end
        local conn, conn_err = new_conn(inst, sock)
        if not conn then
            close_once(sock)
            warn_once(inst, "timer", ("closed a connection it could not serve (%s)"):format(tostring(conn_err)))
            return
        end
        track_conn(conn)
        local reading, read_err = sock:read_start(function(err_read, chunk)
            on_read(conn, err_read, chunk)
        end)
        if not reading then
            close_once(sock)
            warn_once(inst, "read", ("closed a connection it could not read (%s)"):format(tostring(read_err)))
        end
    end)
    if not listening then
        close_once(tcp)
        error("Failed to listen on " .. host .. ":" .. tostring(actual_port) .. ": " .. tostring(listen_err), 0)
    end
    -- Opened once the server listens: a failed listen closed the socket and
    -- left the reload timer and the watchers running. Unread, a nil here
    -- served, and the first file change raised in the watcher's callback,
    -- where the reload indexes the timer (measured).
    local reload_timer, reload_err = uv.new_timer()
    if not reload_timer then
        S.stop(inst)
        error(("Failed to make the reload timer on %s:%d: %s"):format(host, actual_port, tostring(reload_err)), 0)
    end
    inst.debounce_timer = reload_timer
    -- A comment line on every stream keeps an idle one open through a
    -- proxy's idle cut and lets a peer that vanished without a FIN
    -- surface: TCP gives up on a write it never acknowledges, where an
    -- idle socket waits for good, holding its place. A beat that cannot
    -- be armed fails the start, as a failed listen does, since the
    -- streams have no other bound.
    if inst.heartbeat_ms > 0 then
        local beat, beat_err = uv.new_timer()
        local armed
        if beat then
            inst.heartbeat_timer = beat
            armed, beat_err = beat:start(inst.heartbeat_ms, inst.heartbeat_ms, function()
                sse_send(inst, ": ping\n\n")
            end)
        end
        if not armed then
            S.stop(inst)
            error(
                ("Failed to arm the heartbeat on %s:%d: %s; sse_heartbeat_ms = 0 turns it off"):format(
                    host,
                    actual_port,
                    tostring(beat_err)
                ),
                0
            )
        end
    end
    -- A caller may reload through S.reload alone, so an inotify limit
    -- (ENOSPC) costs live reload, never the server.
    if inst.live_enabled then
        watch_or_warn(inst)
    end

    -- Scheduled, so a start from a fast event (a luv callback) cannot raise
    -- after the socket is serving; a network bind has no check to turn off.
    -- S.stop closes the handle, and a server stopped before the loop ran
    -- turned nothing off that is still reachable.
    if checked.any_host and is_loopback_ip(bound.ip) then
        vim.schedule(function()
            if inst.handle:is_closing() then
                return
            end
            local line = "live-server: port %d answers any Host: allowed_hosts = true turns the Host check off;"
                .. " a DNS-rebinding page can read this server"
            util.notify(line:format(inst.port), { notify = true }, "WARN")
        end)
    end
    -- Past the last raise: every warning start found now names a server.
    local queued = inst.queued
    inst.queued = nil
    for _, line in ipairs(queued) do
        vim.schedule(function()
            util.notify(line, { notify = true }, "WARN")
        end)
    end
    return inst
end

function S.stop(inst)
    -- A stopped server has no watcher and a closed timer, so it reports
    -- live reload off, as enable_live answers a stopped server.
    inst.live_enabled = false
    for _, cl in ipairs(vim.list_slice(inst.sse_clients)) do
        sse_evict(inst, cl)
    end
    -- Of its sockets, stop reached the listener and the event streams
    -- alone, so an idle client, a head half sent, a stalled download with
    -- its file open and a page mid-write outlived it (measured). A
    -- transfer closes its file when its socket closes under it. Each close
    -- ends its connection's timer and clears its entry, a clear Lua lets a
    -- walk make, so a second stop finds nothing to close.
    for conn in pairs(inst.conns) do
        close_once(conn.sock)
    end
    close_once(inst.handle)
    -- A close stops a timer; the guard makes a second stop close nothing.
    for _, timer in ipairs({ inst.debounce_timer or false, inst.heartbeat_timer or false }) do
        if timer and not timer:is_closing() then
            timer:close()
        end
    end
    stop_fs_watch(inst)
end

-- A stopped server's reload timer is closed, so a watcher opened here
-- would reload nothing and nothing would close it.
function S.update_target(inst, new_root, new_index)
    -- A nil root raised inside luv; a table index answered every GET / 500.
    if type(new_root) ~= "string" then
        error(("update_target: root is not a string (%s)"):format(type(new_root)), 2)
    end
    if new_index ~= nil and type(new_index) ~= "string" then
        error(("update_target: index is not a string (%s)"):format(type(new_index)), 2)
    end
    -- libuv cut a path at a NUL: a root retargeted to the part before it,
    -- and an index named another file. The value is left out, as start's
    -- refusal of a NUL leaves it out.
    for _, arg in ipairs({ { "root", new_root }, { "index", new_index } }) do
        if arg[2] and arg[2]:find("%z") then
            error(("update_target: %s holds a NUL byte"):format(arg[1]), 2)
        end
    end
    -- An empty index named no file, so / fell to the index names with no
    -- word; start refuses an empty default_index the same way.
    if new_index == "" then
        error("update_target: index is empty", 2)
    end
    if inst.handle:is_closing() then
        return false
    end
    -- A root that does not resolve was named while the old one was served.
    -- libuv's text repeats the path raw after the error's name, which
    -- alone is kept, and the root is shown marked and cut.
    local root_real, real_err = uv.fs_realpath(new_root)
    if not root_real then
        local cause = tostring(real_err):match("^[^:]*")
        error(("update_target: root %s does not resolve (%s)"):format(shown(new_root), cause), 2)
    end
    local is_dir, dir_err = root_directory(root_real)
    if not is_dir then
        local cause = dir_err and (" (" .. tostring(dir_err):match("^[^:]*") .. ")") or ""
        error(("update_target: root %s is not a directory%s"):format(shown(new_root), cause), 2)
    end
    local index, index_err = absolute_path(new_index)
    if index_err then
        error(
            ("update_target: index %s is relative and the working directory is unknown (%s)"):format(
                shown(new_index),
                tostring(index_err)
            ),
            2
        )
    end
    -- A new root's .liveignore is heard, though the last root's was.
    if root_real ~= inst.root_real then
        inst.warned.liveignore = nil
    end
    inst.root = new_root
    inst.root_real = root_real
    inst.default_index = index
    read_liveignore(inst)
    if inst.live_enabled then
        return watch_or_warn(inst)
    end
    return true
end

-- Live-reload controls
function S.reload(inst, reason_path)
    -- Any other value went out as its tostring, a table's address.
    if reason_path ~= nil and type(reason_path) ~= "string" then
        error(("reload: the path is not a string (%s)"):format(type(reason_path)), 2)
    end
    local rp = reason_path or ""
    send_reload(inst, rp, is_stylesheet(rp))
end

function S.send_event(inst, event_type, data)
    -- Through tostring any other value passed and raised inside the frame.
    if type(event_type) ~= "string" then
        error(("send_event: the event name is not a string (%s)"):format(type(event_type)), 2)
    end
    -- A line break in the name would start a field of its own (retry, id).
    if event_type:find("[\r\n]") then
        error("send_event: the event name holds a line break", 2)
    end
    if data ~= nil and type(data) ~= "string" then
        error(("send_event: the payload is not a string (%s)"):format(type(data)), 2)
    end
    sse_broadcast(inst, event_type, data or "{}")
end

function S.enable_live(inst, enable)
    -- not not read 0 as on, where start refuses 0.
    if type(enable) ~= "boolean" then
        error(("enable_live: the flag is not a boolean (%s)"):format(type(enable)), 2)
    end
    if inst.handle:is_closing() then
        return false
    end
    if inst.live_enabled == enable then
        return enable
    end
    inst.live_enabled = enable
    if enable then
        return watch_or_warn(inst)
    end
    stop_fs_watch(inst)
    drop_window(inst)
    return false
end

-- A server started without live holds nil there, a third answer.
function S.is_live_enabled(inst)
    return inst.live_enabled == true
end

function S.connected_client_count(inst)
    return #inst.sse_clients
end

return S
