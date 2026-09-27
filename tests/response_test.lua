-- tests/response_test.lua
-- What every response carries and what it must not: the referrer policy,
-- the cors headers (never on /__live/*), the preflight answer and the
-- request headers it allows, a cors list's echo of a listed Origin, and a
-- 404 that names the request, never a filesystem path or the query.
--
-- Run: nvim --headless -u NONE -l "$PWD/tests/response_test.lua"

local H = dofile(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "helpers.lua"))
H.isolate()
H.rtp()

local uv = vim.uv
local server = require("live_server.server")
local eq, ok = H.eq, H.ok

local root = H.tmpdir()
vim.fn.mkdir(root .. "/assets", "p")
H.write_file(root .. "/index.html", "<html><body>ok</body></html>")
H.write_file(root .. "/style.css", "body{}")
H.write_file(root .. "/content.md", "# secret")
H.write_file(root .. "/assets/pic.png", "PNGDATA")

local function serve(cfg)
    local inst = server.start(vim.tbl_extend("keep", cfg or {}, {
        port = 0,
        root = root,
        asset_root = root .. "/assets",
        live = { enabled = false, inject_script = false },
        features = { dirlist = { enabled = false } },
    }))
    H.defer(function()
        server.stop(inst)
    end)
    return inst
end

local function get(path, port, extra)
    return ("GET %s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n%s\r\n"):format(path, port, extra or "")
end

-- The first response on a fresh connection. A failed exchange or bytes
-- that parse as no response raise, so a row that asserts a header is
-- absent never passes on nothing.
local function raw(port, bytes)
    return H.response(assert(H.raw_request(port, bytes)))
end

-- The head of an event stream, read until the retry line, then closed.
local function stream_head(port, path, extra)
    local c = assert(H.raw_connect(port))
    assert(c:send(get(path, port, extra)))
    local data = c:read(2000, function(d)
        return d:find("retry: 1000\n\n", 1, true) ~= nil
    end)
    c:close()
    return H.response(data)
end

-- A page opened with ?t=<token> sent its full URL, token included, as the
-- Referer to same-origin requests and its origin across origins. A
-- caller's own policy, under any spelling of the name, is replaced, so the
-- header goes out once and is always this one.
H.case("Section 1: every response carries Referrer-Policy: no-referrer", function()
    local inst = serve({ token = "tok", protected_paths = { "^/content%.md$" } })
    local port = inst.port
    local cases = {
        { "a file", get("/style.css", port) },
        { "a 404", get("/missing", port) },
        { "a 401", get("/content.md", port) },
        { "a 400", "GET /x HTTP/1.1\r\n\r\n" },
        { "a 421", "GET /style.css HTTP/1.1\r\nHost: evil.example\r\n\r\n" },
        { "the client script", get("/__live/script.js", port) },
    }
    for _, c in ipairs(cases) do
        eq(raw(port, c[2]).headers["referrer-policy"], "no-referrer", c[1] .. " carries it")
    end
    eq(
        stream_head(port, "/__live/events?t=tok").headers["referrer-policy"],
        "no-referrer",
        "the event stream carries it"
    )
    local own = serve({ headers = { ["Referrer-Policy"] = "unsafe-url" } })
    local r = raw(own.port, get("/style.css", own.port))
    eq(r.headers["referrer-policy"], "no-referrer", "a caller's own policy is replaced, not sent beside it")
    eq(r.count["referrer-policy"], 1, "and the header is sent once")
    local lower = serve({ headers = { ["referrer-policy"] = "unsafe-url" } })
    r = raw(lower.port, get("/style.css", lower.port))
    eq(r.headers["referrer-policy"], "no-referrer", "a caller's policy under another spelling is replaced too")
    -- A browser takes the last token across every Referrer-Policy line, so a
    -- second line with the caller's value would reopen what the first closes.
    eq(r.count["referrer-policy"], 1, "and sent once under that spelling too")
end)

-- With cors on, ACAO went out on the event stream and the asset route as
-- well, so any website could read the reload stream and the files beside
-- the document; an ACAO set by hand in headers, under any spelling, did
-- the same. A caller's ACAO beside cors went out as a second line on the
-- root route, and a browser refuses a response with two.
H.case("Section 2: cors never reaches /__live/*", function()
    local inst = serve({ cors = true })
    local port = inst.port
    eq(stream_head(port, "/__live/events").headers["access-control-allow-origin"], nil, "the event stream has no ACAO")
    eq(raw(port, get("/__live/inject?event=x", port)).headers["access-control-allow-origin"], nil, "inject has none")
    eq(
        raw(port, get("/__live/asset?p=pic.png", port)).headers["access-control-allow-origin"],
        nil,
        "the asset route has none"
    )
    eq(
        raw(port, get("/__live/script.js", port)).headers["access-control-allow-origin"],
        nil,
        "the client script has none"
    )
    eq(raw(port, get("/index.html", port)).headers["access-control-allow-origin"], "*", "a root-route file keeps it")
    local both = serve({ cors = "https://a.example", headers = { ["ACCESS-control-allow-origin"] = "*" } })
    local r = raw(both.port, get("/index.html", both.port))
    eq(r.count["access-control-allow-origin"], 1, "cors beside a caller's ACAO sends one origin line")
    eq(r.headers["access-control-allow-origin"], "https://a.example", "and it is the cors one")
    local manual = serve({ headers = { ["Access-control-ALLOW-Origin"] = "*" } })
    eq(
        raw(manual.port, get("/__live/asset?p=pic.png", manual.port)).headers["access-control-allow-origin"],
        nil,
        "an ACAO set by hand in headers stays off the asset route"
    )
    eq(
        stream_head(manual.port, "/__live/events").headers["access-control-allow-origin"],
        nil,
        "and off the event stream"
    )
    -- Without cors the caller's line is the root route's own choice and
    -- stays; only /__live/* refuses it.
    local kept = raw(manual.port, get("/index.html", manual.port))
    eq(kept.headers["access-control-allow-origin"], "*", "and kept on the root route without cors")
    eq(kept.count["access-control-allow-origin"], 1, "on one line")
end)

-- The stream sends the caller's headers as the asset route does, and each
-- of its own fields once: a caller's line beside the stream's own would
-- leave the client to pick which it reads. Start refuses a caller's
-- Content-Type and Connection; a Cache-Control, which a caller sets for
-- its files, yields here under any spelling of the name.
H.case("Section 3: the event stream carries the caller's headers, its own fields once", function()
    local inst = serve({
        headers = {
            ["X-Frame-Options"] = "DENY",
            ["CACHE-CONTROL"] = "max-age=60",
        },
    })
    local r = stream_head(inst.port, "/__live/events")
    eq(r.headers["x-frame-options"], "DENY", "a caller's header reaches the stream")
    eq(r.headers["content-type"], "text/event-stream", "the stream's own type")
    eq(r.count["content-type"], 1, "goes out once")
    eq(r.headers["cache-control"], "no-cache", "its Cache-Control holds against a caller's spelling")
    eq(r.count["cache-control"], 1, "and goes out once")
    eq(r.count["connection"], 1, "and its Connection once")
end)

-- cors = true promised cross-origin reads of the root route, but the
-- browser's preflight got 405 and it refused the read. /__live/* answers
-- no cross-origin read, so its preflight keeps the 405, and every 405
-- names the one method served (RFC 9110 15.5.6). The path checks still
-- come first: a NUL in the path is 400 whatever the method. A preflight
-- that named no request header refused every read carrying one outside
-- the safelist (a custom header, Authorization, a JSON Content-Type), so
-- the names asked for are echoed, never "*", which leaves Authorization
-- out, and Vary says the answer depends on them.
H.case("Section 4: a cors preflight is answered, a 405 names Allow", function()
    local inst = serve({ cors = true })
    local port = inst.port
    local pre = "Origin: http://a.example\r\nAccess-Control-Request-Method: GET\r\n"
    local r = raw(port, ("OPTIONS /style.css HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n%s\r\n"):format(port, pre))
    eq(r.status, 204, "a preflight on the root route is 204")
    eq(r.headers["access-control-allow-origin"], "*", "with the cors origin")
    eq(r.headers["access-control-allow-methods"], "GET", "and the one method served")
    eq(r.headers["access-control-max-age"], "600", "which the browser keeps for ten minutes")
    eq(r.headers["content-length"], nil, "and no Content-Length, which a 204 must not send (RFC 9110 8.6)")
    eq(r.headers["access-control-allow-headers"], nil, "a preflight that asks for no header is allowed none")
    eq(r.headers.vary, "Access-Control-Request-Headers", "and Vary names the field it reads")
    local function asks(headers)
        return raw(port, ("OPTIONS /style.css HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n%s%s\r\n"):format(port, pre, headers))
    end
    r = asks("Access-Control-Request-Headers: x-custom\r\n")
    eq(r.headers["access-control-allow-headers"], "x-custom", "the header a preflight asks for is allowed")
    eq(r.headers.vary, "Access-Control-Request-Headers", "with the Vary")
    eq(r.count.vary, 1, "on one line")
    eq(
        asks("Access-Control-Request-Headers: authorization, content-type\r\n").headers["access-control-allow-headers"],
        "authorization, content-type",
        "a list is echoed as asked, Authorization named, never *"
    )
    eq(
        asks("Access-Control-Request-Headers: x-a\r\nAccess-Control-Request-Headers: x-b\r\n").headers["access-control-allow-headers"],
        "x-a, x-b",
        "two lines are echoed as one list"
    )
    r = asks("Access-Control-Request-Headers: x;y\r\n")
    eq(r.status, 204, "a preflight asking for a name that is no token is still answered")
    eq(r.headers["access-control-allow-headers"], nil, "and allowed no header")
    -- Each item of the list is a token, not the value as a whole: ", ," and
    -- "x a" held only token characters, commas and spaces, and were echoed.
    eq(
        asks("Access-Control-Request-Headers: , ,\r\n").headers["access-control-allow-headers"],
        nil,
        "a list of empty items is allowed no header"
    )
    eq(
        asks("Access-Control-Request-Headers: x a\r\n").headers["access-control-allow-headers"],
        nil,
        "an item with a space inside it is allowed no header"
    )
    eq(
        asks("Access-Control-Request-Headers: x-custom, authorization\r\n").headers["access-control-allow-headers"],
        "x-custom, authorization",
        "a list of tokens is echoed as sent"
    )
    eq(
        raw(port, ("OPTIONS /__live/events HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n%s\r\n"):format(port, pre)).status,
        405,
        "a preflight on /__live/* is 405"
    )
    eq(
        raw(port, ("OPTIONS /__live/script.js HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n%s\r\n"):format(port, pre)).status,
        405,
        "a preflight on /__live/script.js is 405 too"
    )
    -- Only an OPTIONS is a preflight: a GET that carries the field is a GET.
    r = raw(port, ("GET /style.css HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n%s\r\n"):format(port, pre))
    eq(r.status, 200, "a GET carrying Access-Control-Request-Method is served as a GET")
    eq(r.body, "body{}", "with the file")
    r = raw(port, ("POST /style.css HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n\r\n"):format(port))
    eq(r.status, 405, "a POST is 405")
    eq(r.headers.allow, "GET", "and names the method allowed")
    eq(
        raw(port, ("POST /style.css%%00 HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n\r\n"):format(port)).status,
        400,
        "a POST with a NUL in its path is 400 before 405"
    )
    -- The preflight sits after the Host, path and dotfile checks and answers
    -- only a request that asks a method: each order has its row.
    eq(
        raw(port, ("OPTIONS /style.css HTTP/1.1\r\nHost: attacker.example\r\n%s\r\n"):format(pre)).status,
        421,
        "a preflight under a foreign Host is 421 before any answer"
    )
    eq(
        raw(port, ("OPTIONS /%%5F_live/events HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n%s\r\n"):format(port, pre)).status,
        405,
        "a preflight reads the canonical path: /%5F_live/events is /__live/events"
    )
    r = raw(
        port,
        ("OPTIONS /style.css HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nOrigin: http://a.example\r\n\r\n"):format(port)
    )
    eq(r.status, 405, "an OPTIONS that asks no method is no preflight: 405")
    eq(r.headers.allow, "GET", "with Allow: GET")
    eq(
        raw(port, ("OPTIONS /.env HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n%s\r\n"):format(port, pre)).status,
        404,
        "a preflight on a dot path is 404 before any answer"
    )
    local plain = serve()
    eq(
        raw(plain.port, ("OPTIONS /style.css HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n%s\r\n"):format(plain.port, pre)).status,
        405,
        "no cors, no preflight answer"
    )
    -- setup() hands the server cors = false, its default, never nil.
    local off = serve({ cors = false })
    r = raw(off.port, ("OPTIONS /style.css HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n%s\r\n"):format(off.port, pre))
    eq(r.status, 405, "cors = false gets no preflight answer: 405")
    eq(r.headers.allow, "GET", "with Allow: GET")
    -- A browser sends a preflight without credentials, so it is answered
    -- before the token gate, on a path the gate protects too.
    local gated = serve({ cors = true, token = "tok", protected_paths = { "%.css$" } })
    eq(raw(gated.port, get("/style.css", gated.port)).status, 401, "on a token server a protected file wants the token")
    r = raw(gated.port, ("OPTIONS /style.css HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n%s\r\n"):format(gated.port, pre))
    eq(r.status, 204, "and its preflight is answered with no token")
    eq(r.headers["access-control-allow-origin"], "*", "with the cors origin")
    -- A caller's ACAO riding beside the cors one would be a second origin
    -- line, and a browser refuses a preflight with two.
    local both = serve({ cors = "https://a.example", headers = { ["access-CONTROL-allow-origin"] = "*" } })
    r = raw(both.port, ("OPTIONS /style.css HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n%s\r\n"):format(both.port, pre))
    eq(r.count["access-control-allow-origin"], 1, "a preflight beside a caller's ACAO sends one origin line")
    eq(r.headers["access-control-allow-origin"], "https://a.example", "and it is the cors one")
end)

-- cors offered any origin (true) or exactly one (a string), so a page read
-- by two frontends had to open the root route to every website. A list
-- echoes a listed request Origin, and Vary: Origin keeps a cache from
-- answering one origin with the copy another got. The list alone decides:
-- a caller's own ACAO in headers, in any case, handed an unlisted Origin
-- its "*" and a listed one a second origin line, which a browser refuses.
-- The server keeps its own copy of the list, so an entry added after
-- start, which no check has read, is never echoed.
H.case("Section 5: a cors list echoes only a listed Origin", function()
    local list = { "http://a.example", "http://127.0.0.1:5173" }
    local inst = serve({ cors = list })
    local port = inst.port
    local r = raw(port, get("/style.css", port, "Origin: http://a.example\r\n"))
    eq(r.headers["access-control-allow-origin"], "http://a.example", "a listed Origin is echoed")
    eq(r.headers.vary, "Origin", "and a cache is told the answer depends on it")
    eq(
        raw(port, get("/style.css", port, "Origin: http://127.0.0.1:5173\r\n")).headers["access-control-allow-origin"],
        "http://127.0.0.1:5173",
        "each listed Origin is echoed, its port included"
    )
    r = raw(port, get("/style.css", port, "Origin: http://b.example\r\n"))
    eq(r.headers["access-control-allow-origin"], nil, "an unlisted Origin gets none")
    eq(r.headers.vary, "Origin", "with Vary all the same")
    eq(raw(port, get("/style.css", port)).headers["access-control-allow-origin"], nil, "no Origin, no ACAO")
    r = raw(port, get("/", port, "Origin: http://a.example\r\n"))
    eq(r.headers["access-control-allow-origin"], "http://a.example", "the root's index echoes it too")
    eq(r.headers.vary, "Origin", "with its Vary")
    local listing = serve({ cors = list, features = { dirlist = { enabled = true } } })
    r = raw(listing.port, get("/assets/", listing.port, "Origin: http://a.example\r\n"))
    eq(r.status, 200, "a listing is served")
    eq(r.headers["access-control-allow-origin"], "http://a.example", "and echoes a listed Origin")
    eq(
        raw(port, get("/__live/asset?p=pic.png", port, "Origin: http://a.example\r\n")).headers["access-control-allow-origin"],
        nil,
        "a listed Origin gets no ACAO on /__live/*"
    )
    -- Vary is one field: a page with the script on varies by Sec-Fetch-Mode
    -- as well, and a caller's own Vary, under any spelling, joins it.
    local live = serve({ cors = list, live = { enabled = false, inject_script = true } })
    r = raw(live.port, get("/index.html", live.port, "Origin: http://a.example\r\n"))
    eq(r.headers.vary, "Origin, Sec-Fetch-Mode", "a page with the script on names both")
    eq(r.count.vary, 1, "on one line")
    local own = serve({ cors = list, headers = { vary = "Accept" } })
    r = raw(own.port, get("/style.css", own.port, "Origin: http://a.example\r\n"))
    eq(r.headers.vary, "Accept, Origin", "a file joins a configured Vary with Origin")
    eq(r.count.vary, 1, "on one line")
    local manual = serve({ cors = { "http://a.example" }, headers = { ["access-control-allow-origin"] = "*" } })
    r = raw(manual.port, get("/style.css", manual.port, "Origin: http://b.example\r\n"))
    eq(r.headers["access-control-allow-origin"], nil, "a hand-set ACAO * never reaches an unlisted Origin")
    r = raw(manual.port, get("/style.css", manual.port, "Origin: http://a.example\r\n"))
    eq(r.count["access-control-allow-origin"], 1, "and a listed one gets exactly one ACAO")
    eq(r.headers["access-control-allow-origin"], "http://a.example", "its echo")
    local pre = "Access-Control-Request-Method: GET\r\n"
    local function preflight(origin)
        return raw(
            port,
            ("OPTIONS /style.css HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nOrigin: %s\r\n%s\r\n"):format(port, origin, pre)
        )
    end
    r = preflight("http://a.example")
    eq(r.status, 204, "a preflight from a listed Origin is answered")
    eq(r.headers["access-control-allow-origin"], "http://a.example", "with its Origin echoed")
    eq(r.headers.vary, "Origin, Access-Control-Request-Headers", "and Vary naming both fields it reads")
    eq(r.count.vary, 1, "on one line")
    r = preflight("http://b.example")
    eq(r.headers["access-control-allow-origin"], nil, "a preflight from an unlisted Origin gets no ACAO")
    eq(r.headers.vary, "Origin, Access-Control-Request-Headers", "with the same Vary")
    table.insert(list, "http://c.example")
    eq(
        raw(port, get("/style.css", port, "Origin: http://c.example\r\n")).headers["access-control-allow-origin"],
        nil,
        "an entry added to the caller's list after start is never echoed"
    )
end)

-- A file the server could not open answered a 404 naming its absolute
-- path, which gave a peer the user's home directory and project layout,
-- and a 404 on the root route echoed the query, a ?t=<token> with it. The
-- page names the path asked for, normalized and without its query; the
-- asset route names itself.
H.case("Section 6: a 404 names the request, never the filesystem path", function()
    local inst = serve()
    local function fetch(target)
        return H.http_get(("http://127.0.0.1:%d%s"):format(inst.port, target))
    end
    local function names_request(target, shown, what)
        local r = fetch(target)
        eq(r.status, 404, what .. " is 404")
        ok(r.body:find("<code>" .. shown .. "</code>", 1, true) ~= nil, "its page names " .. shown)
        ok(not r.body:find("secret", 1, true), "and never the query's token")
    end
    names_request("/missing.html?t=secret", "/missing.html", "a missing file")
    names_request("/.env?t=secret", "/.env", "a dot path")
    names_request("/assets/?t=secret", "/assets (no index)", "a directory with no index")
    -- A link the dot rule refuses by its target and a name that is neither
    -- a file nor a directory reach 404s of their own. Windows may refuse
    -- the link (no symlink privilege) and binds no unix socket to a path,
    -- so each fixture is measured and its checks skipped where it is not.
    H.write_file(root .. "/.env", "S")
    local linked, link_err = uv.fs_symlink(".env", root .. "/link.txt")
    local link_st, link_st_err = uv.fs_stat(root .. "/link.txt")
    if linked and link_st then
        names_request("/link.txt?t=secret", "/link.txt", "a link to a dot name")
    else
        for _ = 1, 3 do
            H.skip("a link to a dot name's 404 (" .. tostring(link_err or link_st_err) .. ")")
        end
    end
    local pipe = assert(uv.new_pipe(false))
    H.defer(function()
        pipe:close()
    end)
    local bound, bind_err = pipe:bind(root .. "/sock.s")
    local sock_st, sock_st_err = uv.fs_stat(root .. "/sock.s")
    if bound and sock_st and sock_st.type ~= "file" and sock_st.type ~= "directory" then
        names_request("/sock.s?t=secret", "/sock.s", "a socket")
    else
        for _ = 1, 3 do
            H.skip(
                "a socket's 404 (" .. tostring(bind_err or sock_st_err or ("the bind made a " .. sock_st.type)) .. ")"
            )
        end
    end
    local rows = {
        { "/locked.html", "/locked.html", "an unreadable page" },
        { "/locked.bin", "/locked.bin", "an unreadable file" },
        { "/__live/asset?p=locked.bin", "/__live/asset", "an unreadable asset" },
    }
    local files = { root .. "/locked.html", root .. "/locked.bin", root .. "/assets/locked.bin" }
    for _, path in ipairs(files) do
        H.write_file(path, "x")
        assert(uv.fs_chmod(path, 0))
        H.defer(function()
            assert(uv.fs_chmod(path, 420))
        end)
    end
    -- The superuser opens a mode-000 file and Windows keeps no such mode, so
    -- the refusal the rows need is measured before they run.
    local fd, open_err, open_code = uv.fs_open(files[1], "r", 438)
    if fd then
        assert(uv.fs_close(fd))
        for _, row in ipairs(rows) do
            for _ = 1, 3 do
                H.skip(row[3] .. "'s 404 (this process opens a mode-000 file: root, or no POSIX modes)")
            end
        end
        return
    end
    -- An open that failed for another reason measured nothing about the
    -- mode, and the rows would run on a fixture no probe read.
    assert(open_code == "EACCES" or open_code == "EPERM", "the mode-000 probe: " .. tostring(open_err))
    for _, row in ipairs(rows) do
        local r = fetch(row[1])
        eq(r.status, 404, row[3] .. " is 404")
        ok(not r.body:find(root, 1, true) and not r.body:find(H.canon(root), 1, true), "its page shows no root path")
        ok(r.body:find("<code>" .. row[2] .. "</code>", 1, true) ~= nil, "it names " .. row[2])
    end
end)

-- The root route and the asset route answer with the instance's own header
-- tables, by reference, and send_response writes Content-Length and
-- Connection into the table it gets: a path that handed one over uncopied
-- would put a stale length into every later response.
H.case("Section 7: a response leaves the instance's header tables as start made them", function()
    local inst = serve({ cors = true, headers = { ["X-Frame-Options"] = "DENY" } })
    local port = inst.port
    local headers, live_headers = vim.deepcopy(inst.headers), vim.deepcopy(inst.live_headers)
    eq(raw(port, get("/style.css", port)).status, 200, "a file is served")
    eq(raw(port, get("/index.html", port)).status, 200, "a page is served")
    eq(raw(port, get("/missing", port)).status, 404, "a 404 is served")
    eq(raw(port, get("/__live/asset?p=pic.png", port)).status, 200, "an asset is served")
    eq(stream_head(port, "/__live/events").status, 200, "the stream head is served")
    local function shown(t)
        return vim.inspect(t, { newline = " ", indent = "" })
    end
    ok(vim.deep_equal(inst.headers, headers), "inst.headers is as start made it: " .. shown(inst.headers))
    ok(
        vim.deep_equal(inst.live_headers, live_headers),
        "inst.live_headers is as start made it: " .. shown(inst.live_headers)
    )
end)

H.finish()
