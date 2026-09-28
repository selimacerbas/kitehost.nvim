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

local function write_headers(sock, status, headers)
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
    sock:write(table.concat(lines))
end

-- The fields a response computes for itself, which start refuses in a
-- caller's headers under any spelling.
local SERVER_FIELDS = {
    ["content-type"] = true,
    ["content-length"] = true,
    ["transfer-encoding"] = true,
    ["connection"] = true,
}

-- Every socket closes here. A peer that ended its side while a response
-- was still being written had its socket closed by the read path; libuv
-- then ran the pending shutdown's callback (ECANCELED), whose second close
-- raised "handle is already closing" inside a luv callback (measured).
local function close_once(sock)
    if not sock:is_closing() then
        sock:close()
    end
end

-- headers is a table the caller built for this one response, which the
-- length and Connection are written into.
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

-- The request head, parsed once: method, target, version, and the header
-- fields by lowercased name, each the list of its values in order, so a
-- check can refuse a repeated field instead of reading one copy. The
-- target is a path (origin-form) or an http URL (absolute-form, RFC 9112
-- 3.2.2), whose authority is kept for the Host check and whose path is
-- served. nil and the reason for any head it refuses.
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
            close_once(cl)
            table.remove(inst.sse_clients, i)
        else
            i = i + 1
        end
    end
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

local function schedule_reload(inst, changed_path)
    if not inst.live_enabled then
        return
    end
    local rel = changed_path and changed_rel(inst, changed_path)
    local own = rel and is_own_index(inst, rel)
    -- A dot path's change names it to every events client, the name the
    -- listing hides, and reloads a page for a file the server never serves.
    if rel and not inst.serve_dotfiles and has_dot_segment(rel) and not own then
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
    -- a dot path (its own name, or the target of a plain-named link) the
    -- payload says / so no dot name reaches an events client, and a plain
    -- name keeps its path, so a started-on stylesheet still swaps.
    inst._last_change = (own and has_dot_segment(rel)) and "/" or rel or inst._last_change
    inst.debounce_timer:stop()
    inst.debounce_timer:start(inst.live_debounce, 0, function()
        S.reload(inst, inst._last_change or "")
    end)
end

-- A directory whose changes never reload (a dot path, without
-- serve_dotfiles) spends no watch; with serve_dotfiles each is watched,
-- .git included.
local function dir_watched(inst, dir)
    local rel = changed_rel(inst, dir)
    return inst.serve_dotfiles or not has_dot_segment(rel) or holds_own_index(inst, rel)
end

-- Recursively scan all subdirectories under root (for Linux fallback watchers)
local function scan_dirs(inst)
    local dirs = { inst.root_real }
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
            local full = util.joinpath(dir, name)
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
            if st and st.type == "directory" and not inst._fs_events[full] and dir_watched(inst, full) then
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
    for _, dir in ipairs(scan_dirs(inst)) do
        add_dir_watch(inst, dir)
    end
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
    -- refused it), so the target's whole path is read.
    local function link_shown(name)
        local rel = root_rel(inst.root_real, util.joinpath(fs_path, name))
        return rel ~= nil and (inst.serve_dotfiles or not has_dot_segment(rel))
    end
    while true do
        local name, t = uv.fs_scandir_next(iter)
        if not name then
            break
        end
        -- A name the dot rule refuses is not shown: show_hidden alone
        -- named .env and .git to anyone the server answers, behind 404s.
        local shown = show_all or name:sub(1, 1) ~= "."
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
local function stream_file(sock, abs_path, extra_headers, shown)
    local fd = uv.fs_open(abs_path, "r", 438)
    if not fd then
        return http_404(sock, shown or "/")
    end
    local stat = uv.fs_fstat(fd)
    if not stat or stat.type ~= "file" then
        uv.fs_close(fd)
        return http_404(sock, shown or "/")
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
                    close_once(sock)
                end)
                return
            end
            offset = offset + #data
            sock:write(data, function()
                if #data < 64 * 1024 then
                    uv.fs_close(fd)
                    sock:shutdown(function()
                        close_once(sock)
                    end)
                else
                    read_chunk()
                end
            end)
        end)
    end
    read_chunk()
end

local function serve_path(inst, sock, abs_path, req, extra_headers, shown)
    local mime = guess_mime(abs_path)
    if mime:find("^text/html") then
        return serve_html_file_with_injection(inst, sock, abs_path, extra_headers, req, shown)
    else
        return stream_file(sock, abs_path, extra_headers, shown)
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
    local called, bound, bind_err, bind_name = pcall(probe.bind, probe, ip, port)
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
-- protected_paths pattern; the second value is true when a pattern could
-- not be read. The start check reads a pattern against the empty subject
-- only, so a malformed part after a literal ("/[") raises here, in the
-- read callback, where it left the request unanswered: a raise reads as a
-- match no token satisfies, since the gate cannot tell what it protects.
-- Every pattern is read, so the answer does not hang on the list's order.
-- A 401 alone reads like a bad token, so the first pattern that raises is
-- named once per instance, scheduled, as a request runs in a fast event.
local function needs_auth(inst, p)
    if p == "/__live/events" or p == "/__live/inject" or p == "/__live/asset" then
        return true
    end
    local needed = false
    for _, pat in ipairs(inst.protected_paths) do
        local read, hit = pcall(string.find, p, pat)
        if not read then
            if not inst._unreadable_warned then
                inst._unreadable_warned = true
                vim.schedule(function()
                    util.notify(
                        "live-server: protected_paths pattern cannot be read, refusing what it gates: " .. pat,
                        { notify = true },
                        "WARN"
                    )
                end)
            end
            return true, true
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

-- Whether a segment of path names a credential directory; a Windows path
-- separates with a backslash too.
local function in_credential_dir(path)
    for seg in path:lower():gmatch("[^/\\]+") do
        if ASSET_DENY.dirs[seg] then
            return true
        end
    end
    return false
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
    -- A cors preflight for the root route; /__live/* answers no
    -- cross-origin read, so its preflight gets the 405 below. Both read the
    -- canonical path: /%5F_live/events is served as /__live/events.
    if
        req.method == "OPTIONS"
        and inst.cors
        and req.headers["access-control-request-method"]
        and not path_only:find("^/__live/")
    then
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
    local function authorized(p)
        if not inst.token then
            return true
        end
        local needed, unreadable = needs_auth(inst, p)
        if not needed then
            return true
        elseif unreadable then
            return false
        end
        local req_token = qparam("t")
        return util.secure_compare(req_token and util.url_decode(req_token) or "", inst.token)
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
    -- directory's own read below is: ^/secret/ answered 401 for an existing
    -- /secret/ and 404 for a missing one, which told the two apart.
    if not authorized(path_only) or (names_dir and path_only ~= "/" and not authorized(path_only .. "/")) then
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
        if not authorized(rel) or (kind == "dir" and rel ~= "/" and not authorized(rel .. "/")) then
            return 401
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
        local aroot = inst.asset_root
        if type(aroot) == "function" then
            local ok_root, res = pcall(aroot)
            aroot = ok_root and res or nil
        end
        -- A callback's table or number is no asset root: luv's realpath
        -- raised on it inside the read callback, and the peer waited.
        if type(aroot) ~= "string" then
            aroot = nil
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
            not aroot
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
        -- The list reads the asset root's own path too: a document kept in
        -- ~/.ssh or ~/.aws would serve the credentials beside it.
        local aroot_real = uv.fs_realpath(aroot)
        if not aroot_real or in_credential_dir(aroot_real) then
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
        return stream_file(sock, real, asset_headers(inst, real), "/__live/asset")
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
                -- points outside the root or at a name the dot rule refuses
                -- is not this directory's, so the next name or the listing
                -- answers; a directory named index.html is no page, and a
                -- FIFO so named would block the editor's loop.
                local try = sanitize_and_map((path_only == "/" and "" or path_only) .. "/" .. iname, inst.root_real)
                local tst = try and uv.fs_stat(try)
                local trel = tst and tst.type == "file" and root_rel(inst.root_real, try)
                if trel and (inst.serve_dotfiles or not has_dot_segment(trel)) then
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
            close_once(sock)
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

-- Start's options, each read from the caller's table once and checked
-- before any handle opens, so a refusal leaks nothing; start reads only the
-- copy returned. A table that computes a field could otherwise pass a check
-- with one value and hand the server another. The caller shows a refusal
-- to the user, so each raises at level 0.
local function check_start(cfg)
    -- An empty token is truthy and would pass the gate with no t= at all.
    local token = cfg.token
    if token ~= nil and (type(token) ~= "string" or token == "") then
        error("token must be a non-empty string", 0)
    end
    -- luv truncates a port it cannot hold and listens on another one.
    local p = cfg.port
    if type(p) ~= "number" or p ~= math.floor(p) or p < 0 or p > 65535 then
        error(("port must be an integer from 0 to 65535, got %s (%s)"):format(tostring(p), type(p)), 0)
    end
    -- A host that is no string reached the bind, and a table raised while
    -- the bind's error was written, naming no option.
    local host = cfg.host
    if host ~= nil and type(host) ~= "string" then
        error("host must be a string", 0)
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
                error("allowed_hosts takes exact names, no wildcard: " .. name, 0)
            end
            -- The check reads a Host through host_name, so an entry must be
            -- what host_name would return for it: a port, brackets or a
            -- spelling the grammar rejects could never match and stay inert.
            local key = (name:lower():gsub("%.$", ""))
            local read = host_name(name) or host_name("[" .. name .. "]")
            if read ~= key then
                error("allowed_hosts entry is not a hostname: " .. name, 0)
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
            if not pcall(string.find, "", pat) then
                error("protected_paths pattern is malformed: " .. pat, 0)
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
            -- A name is joined to the directory it indexes, so a path in it
            -- read another directory's file as this one's index.
            if iname:find("[/\\]") or iname == "." or iname == ".." then
                error("index_names entry is not a file name: " .. iname, 0)
            end
        end
    end
    -- Any value but true read as false, so serve_dotfiles = 1 served no
    -- dotfile without a word.
    local dotfiles = cfg.serve_dotfiles
    if dotfiles ~= nil and type(dotfiles) ~= "boolean" then
        error("serve_dotfiles must be true or false", 0)
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
    -- so the table served is the one checked.
    local cfg_headers = cfg.headers or {}
    if type(cfg_headers) ~= "table" then
        error("headers must be a table of header names and values", 0)
    end
    local headers, spelled = {}, {}
    for k, v in pairs(cfg_headers) do
        if
            type(k) ~= "string"
            or not k:find("^" .. TCHAR .. "+$")
            or type(v) ~= "string"
            or v:find("[%z\1-\8\10-\31\127]")
        then
            error("headers: a name must be a token and a value a line: " .. tostring(k), 0)
        end
        local name = k:lower()
        if SERVER_FIELDS[name] then
            error(("headers: %s is the server's own field"):format(k), 0)
        end
        if spelled[name] then
            local a, b = spelled[name], k
            if b < a then
                a, b = b, a
            end
            error(("headers: %s and %s name one field"):format(a, b), 0)
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
                error("cors entry is not an origin (scheme://host[:port]): " .. vim.inspect(origin), 0)
            end
            if not as_browser_sends(origin) then
                error("cors entry is not an origin as a browser sends it (lower case, no default port): " .. origin, 0)
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
    -- fs_realpath raised its own argument error for a nil root and read a
    -- number as a path under the working directory.
    local root = cfg.root
    if type(root) ~= "string" then
        error("root must be a string", 0)
    end
    local root_real = uv.fs_realpath(root)
    if not root_real then
        error("Invalid root: " .. root, 0)
    end

    return {
        token = token,
        port = p,
        host = host or "127.0.0.1",
        -- true turns the Host check off; the set holds the listed names as
        -- host_name reads a Host.
        any_host = allowed == true,
        allowed_hosts = allowed_set,
        -- Copies of the checked lists: the caller's table (init.lua hands the
        -- user's own) holed or emptied after start dropped the gate, and
        -- index_names changed after start named an index never checked.
        protected_paths = vim.list_extend({}, protected or {}),
        index_names = index_names and vim.list_extend({}, index_names) or { "index.html", "index.htm" },
        serve_dotfiles = dotfiles == true,
        headers = headers,
        live_headers = live_headers,
        cors = cors and true or false,
        cors_list = type(cors) == "table" and vim.list_extend({}, cors) or nil,
        root = root,
        root_real = root_real,
        default_index = cfg.default_index,
        live_enabled = live and live.enabled ~= false,
        inject_script = live and live.inject_script ~= false,
        live_debounce = (live and live.debounce) or 120,
        css_inject = live and live.css_inject ~= false,
        dir_enabled = not (dirlist and dirlist.enabled == false),
        dir_show_hidden = dirlist and dirlist.show_hidden or false,
        notify_on_reload = cfg.notify_on_reload or false,
        asset_root = cfg.asset_root,
    }
end

-- -------- Public server API -----------------------------------------------

-- cfg: { port, root, default_index|nil, headers, cors, live={enabled,inject_script,debounce,css_inject}, features={dirlist={enabled,show_hidden}}, host, token, protected_paths, serve_dotfiles, index_names, notify_on_reload, asset_root, allowed_hosts }
-- Raises at level 0, returning nothing, when it cannot serve: a refused
-- option, a failed bind or listen, a port in use, or a wildcard bind whose
-- URL's loopback address another socket holds or start cannot check. A
-- caller reads S.features.start_raises before it relies on that.
function S.start(cfg)
    local checked = check_start(cfg)
    local tcp = uv.new_tcp()
    local host = checked.host
    -- luv returns a failed bind as nil, err, which a pcall alone never sees,
    -- and listen binds an unbound socket to every interface. bind raises
    -- only on an address it cannot parse, which the pcall catches. The caller
    -- shows the message to the user, so the raise is at level 0.
    local called, bound_ok, bind_err = pcall(tcp.bind, tcp, host, checked.port)
    if not called or not bound_ok then
        close_once(tcp)
        local reason = called and bind_err or bound_ok
        error("Failed to bind " .. host .. ":" .. tostring(checked.port) .. ": " .. tostring(reason), 0)
    end

    -- The bound address, not the configured spelling, decides the Host
    -- check: 0:0:0:0:0:0:0:1 and ::ffff:127.0.0.1 are loopback binds too.
    -- It also carries the OS-assigned port when cfg.port is 0. libuv holds
    -- a bind's EADDRINUSE until here, so a failure reads as the bind's.
    local bound, sockname_err = tcp:getsockname()
    if not bound then
        close_once(tcp)
        error("Failed to bind " .. host .. ":" .. tostring(checked.port) .. ": " .. tostring(sockname_err), 0)
    end

    -- macOS and Windows let a listener bound to the loopback address alone
    -- share the port with a wildcard bind and take every connection to that
    -- address, where the opened URL, token and all, would go (measured on
    -- macOS; Linux refuses the bind above). start serves only when a probe
    -- before the listen finds the address free: a probe that failed any
    -- other way cannot tell, and a real EMFILE there once let the URL reach
    -- another program (measured). A caller may replace the rule, and one
    -- that raised went past start with the server's socket open.
    local here = host .. ":" .. tostring(bound.port)
    local ruled, loopback = pcall(S.wildcard_loopback, bound.ip)
    if not ruled then
        close_once(tcp)
        error(("Failed to bind %s: the loopback rule raised: %s"):format(here, tostring(loopback)), 0)
    end
    if loopback then
        local free, why, why_name = address_free(loopback, bound.port)
        if not free then
            close_once(tcp)
            local there = tostring(loopback) .. ":" .. tostring(bound.port)
            if why_name == "EADDRINUSE" then
                error(
                    ("Failed to bind %s: another socket holds %s, the address the URL names (%s)"):format(
                        here,
                        there,
                        tostring(why)
                    ),
                    0
                )
            end
            error(
                ("Failed to bind %s: cannot check %s, the address the URL names: %s"):format(here, there, tostring(why)),
                0
            )
        end
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

        -- live
        live_enabled = checked.live_enabled,
        inject_script = checked.inject_script,
        live_debounce = checked.live_debounce,
        css_inject = checked.css_inject,
        sse_clients = {},

        -- features
        dir_enabled = checked.dir_enabled,
        dir_show_hidden = checked.dir_show_hidden,
        index_names = checked.index_names,
        ignore_patterns = util.parse_liveignore(checked.root_real),
        notify_on_reload = checked.notify_on_reload,

        -- auth
        token = checked.token, -- nil = no auth; string = required on protected paths
        protected_paths = checked.protected_paths,
        serve_dotfiles = checked.serve_dotfiles,

        -- /__live/asset root: a directory, or a function returning one.
        -- Lets a caller expose files that live next to its source document
        -- (e.g. images referenced from markdown) without serving that
        -- directory as the root. Token-gated whenever token is set.
        asset_root = checked.asset_root,
    }

    local listening, listen_err = tcp:listen(128, function(err_listen)
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
    if not listening then
        close_once(tcp)
        error("Failed to listen on " .. host .. ":" .. tostring(actual_port) .. ": " .. tostring(listen_err), 0)
    end
    -- Opened once the server listens: a failed listen closed the socket and
    -- left the reload timer and the watchers running.
    inst.debounce_timer = uv.new_timer()
    if inst.live_enabled then
        start_fs_watch(inst)
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
            util.notify(
                "live-server: allowed_hosts = true turns the Host check off; a DNS-rebinding page can read this server",
                { notify = true },
                "WARN"
            )
        end)
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
        close_once(cl)
    end
    inst.sse_clients = {}
    stop_fs_watch(inst)
    close_once(inst.handle)
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
