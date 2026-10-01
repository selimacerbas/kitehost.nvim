-- tests/response_test.lua
-- What every response carries and what it must not: the referrer policy,
-- the cors headers (never on /__live/*), the event stream's caller headers
-- and its own fields once, the preflight answer (before the token gate,
-- never with cors off or on /__live/*) and the request headers it allows,
-- a cors list's echo of a listed Origin, a 404 that names the request,
-- never a filesystem path or the query, the instance's header tables left
-- as start made them, and a /__live/ name that is no route answered 404,
-- a preflight or any other method included, as is a preflight or any
-- other method through a link elsewhere into the directory (Section 8).
-- Of the directory behind /__live/: a listing names nothing in it
-- (Section 9), an index that resolves into it is not its directory's
-- (Section 10), its name is matched in any letter case (Section 11), the
-- rule reaches the root's own entry alone, the started-on file served at
-- / (Section 12), and a link so named at the root is refused whatever it
-- resolves to (Section 13).
--
-- Run: nvim --headless -u NONE -l "$PWD/tests/response_test.lua"

local H = dofile(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "helpers.lua"))
H.isolate()
H.rtp()

local uv = vim.uv
local server = require("live_server.server")
local eq, ok = H.eq, H.ok

-- Windows takes a / in a relative link's target unconverted, leaving the
-- link dangling (an absolute target's / resolves), and opens no link to a
-- directory made without dir = true (measured on the hosted runner): a
-- relative target here carries the platform's separator and a link to a
-- directory is made as one. A row through a link runs only where the
-- link resolves to the name it is about; unresolved says why it does
-- not, the reason the row is skipped with.
local sep = package.config:sub(1, 1)
local function unresolved(made, made_err, name, want)
    if not made then
        return "no link: " .. tostring(made_err)
    end
    local real, err = uv.fs_realpath(name)
    if not real then
        return "the link does not resolve: " .. tostring(err)
    end
    if not H.same_path(real, want) then
        return ("the link resolves to %s, not %s"):format(real, want)
    end
end

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
-- Referer to same-origin requests and its origin across origins. The
-- policy sends no path or query in any Referer, same-origin included, and
-- the origin alone to a destination as secure: no-referrer sent nothing,
-- and every YouTube embed, which needs the origin, showed Error 153. A
-- caller's no-referrer or strict-origin, under any spelling of the name
-- or the value, is kept and sent in lower case, as the policy names are
-- defined, since neither sends a path or query: replaced, a
-- caller's no-referrer was loosened, and a network bind's address reached
-- third parties the caller kept it from. Any other policy is replaced, so
-- the header goes out once and never sends the token.
H.case("Section 1: every response carries Referrer-Policy: strict-origin or stricter", function()
    local inst = serve({ token = "tok", protected_paths = { "^/content%.md$" } })
    local port = inst.port
    local cases = {
        { "a file", get("/style.css", port) },
        { "the index", get("/", port) },
        { "a 404", get("/missing", port) },
        { "a 401", get("/content.md", port) },
        { "a 400", "GET /x HTTP/1.1\r\n\r\n" },
        { "a 421", "GET /style.css HTTP/1.1\r\nHost: evil.example\r\n\r\n" },
        { "the client script", get("/__live/script.js", port) },
    }
    for _, c in ipairs(cases) do
        eq(raw(port, c[2]).headers["referrer-policy"], "strict-origin", c[1] .. " carries it")
    end
    eq(
        stream_head(port, "/__live/events?t=tok").headers["referrer-policy"],
        "strict-origin",
        "the event stream carries it"
    )
    local own = serve({ headers = { ["Referrer-Policy"] = "unsafe-url" } })
    local r = raw(own.port, get("/style.css", own.port))
    eq(r.headers["referrer-policy"], "strict-origin", "a caller's own policy is replaced, not sent beside it")
    eq(r.count["referrer-policy"], 1, "and the header is sent once")
    local lower = serve({ headers = { ["referrer-policy"] = "unsafe-url" } })
    r = raw(lower.port, get("/style.css", lower.port))
    eq(r.headers["referrer-policy"], "strict-origin", "a caller's policy under another spelling is replaced too")
    -- A browser takes the last token across every Referrer-Policy line, so a
    -- second line with the caller's value would reopen what the first closes.
    eq(r.count["referrer-policy"], 1, "and sent once under that spelling too")
    -- same-origin sends the full URL, the token with it, to this origin.
    local same = serve({ headers = { ["Referrer-Policy"] = "same-origin" } })
    r = raw(same.port, get("/style.css", same.port))
    eq(r.headers["referrer-policy"], "strict-origin", "a caller's same-origin is replaced")
    eq(r.count["referrer-policy"], 1, "and sent once")
    for _, c in ipairs({
        { "Referrer-Policy", "no-referrer", "no-referrer" },
        { "Referrer-Policy", "strict-origin", "strict-origin" },
        { "referrer-POLICY", "No-Referrer", "no-referrer" },
        { "Referrer-Policy", " NO-REFERRER\t", "no-referrer" },
    }) do
        local mine = serve({ headers = { [c[1]] = c[2] } })
        r = raw(mine.port, get("/style.css", mine.port))
        eq(
            r.headers["referrer-policy"],
            c[3],
            ("a caller's %s: %s is kept and sent as %s"):format(c[1], vim.inspect(c[2]), c[3])
        )
        eq(r.count["referrer-policy"], 1, "once")
    end
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

-- Under cors = true a simple cross-origin GET of the root route was
-- readable, but a read carrying a header outside the safelist sends a
-- preflight first, which got 405, and the browser refused it. /__live/*
-- answers no cross-origin read, so its preflight keeps the 405, and every
-- 405 names the one method served (RFC 9110 15.5.6). The path checks still
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
    -- An empty item is no token either (RFC 9110 5.6.1 forbids sending one).
    eq(
        asks("Access-Control-Request-Headers: , ,\r\n").headers["access-control-allow-headers"],
        nil,
        "a list of empty items is allowed no header"
    )
    eq(
        asks("Access-Control-Request-Headers: x,\r\n").headers["access-control-allow-headers"],
        nil,
        "a list whose last item is empty is allowed no header"
    )
    eq(
        asks("Access-Control-Request-Headers: ,x\r\n").headers["access-control-allow-headers"],
        nil,
        "a list whose first item is empty is allowed no header"
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
    -- The namespace's own path and a name under it that is no route are
    -- the server's before the preflight: /__live and /__live/ were answered
    -- as the root route, 204 with the cors origin, and a name that is no
    -- route 405, where its GET is 404.
    for _, target in ipairs({ "/__live", "/__live/", "/__live/other.txt", "/__live%2fother.txt", "/%5F_live" }) do
        r = raw(port, ("OPTIONS %s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n%s\r\n"):format(target, port, pre))
        eq(r.status, 404, ("a preflight on %s is 404"):format(target))
        eq(r.headers["access-control-allow-origin"], nil, ("with no origin line on %s"):format(target))
    end
    r = raw(port, ("POST /__live/other.txt HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n\r\n"):format(port))
    eq(r.status, 404, "a POST to a name under /__live/ that is no route is 404, as its GET is")
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
    local link_why = unresolved(linked, link_err, root .. "/link.txt", root .. "/.env")
    if not link_why then
        names_request("/link.txt?t=secret", "/link.txt", "a link to a dot name")
    else
        for _ = 1, 3 do
            H.skip("a link to a dot name's 404 (" .. link_why .. ")")
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

-- root_headers and asset_headers hand back the instance's own header
-- tables, or under a cors list a copy root_headers makes per request for
-- its echo and Vary; stream_file and send_html_with_injection copy what
-- they get before writing a length, Connection or a page's Vary into it.
-- A write that reached an instance table would ride every later response.
-- The rows pin the tables unchanged through those copies: a file, a page,
-- a 404, an asset and the stream head, then a listing and a file under a
-- cors list.
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
    local listed = serve({
        cors = { "http://a.example" },
        headers = { ["X-Frame-Options"] = "DENY", vary = "Accept" },
        features = { dirlist = { enabled = true } },
        live = { enabled = false, inject_script = true },
    })
    headers = vim.deepcopy(listed.headers)
    local from = "Origin: http://a.example\r\n"
    eq(raw(listed.port, get("/assets/", listed.port, from)).status, 200, "a listing is served under a cors list")
    eq(raw(listed.port, get("/style.css", listed.port, from)).status, 200, "and a file")
    ok(
        vim.deep_equal(listed.headers, headers),
        "under a cors list inst.headers is as start made it: " .. shown(listed.headers)
    )
end)

-- A name under /__live/ that is no route fell through to the root route,
-- so a user's own <root>/__live/ file was served with the cors origin the
-- namespace never carries. The namespace is the server's: such a name is
-- 404 under each configuration below and the disk is never read, while
-- the four routes answer as they did. The token gate comes first, so on a
-- token server whose protected_paths pattern matches such a name, a GET
-- without the token is 401 before the namespace's 404, and 404 with it.
-- The rule reads the path as normalized, so an escaped, doubled or dotted
-- spelling of the namespace is held too; a FIFO there answers at once,
-- since opening one blocks the editor's loop.
H.case("Section 8: a /__live/ name that is no route is 404", function()
    local site = H.tmpdir()
    H.write_file(site .. "/index.html", "<html><body>ok</body></html>")
    vim.fn.mkdir(site .. "/__live", "p")
    H.write_file(site .. "/__live/other.txt", "USERFILE")
    -- The mkfifo on the Windows runner's PATH exits 0 where the system has
    -- no FIFO (measured), and with none at /__live/x the FIFO rows hold
    -- whatever a FIFO there would do, so they run only on a FIFO the stat
    -- reads as one.
    local fifo, fifo_why = false, "mkfifo is not on PATH"
    if vim.fn.executable("mkfifo") == 1 then
        local made = vim.system({ "mkfifo", site .. "/__live/x" }):wait()
        local st = uv.fs_stat(site .. "/__live/x")
        if made.code ~= 0 then
            fifo_why = "mkfifo exited " .. tostring(made.code) .. ": " .. vim.trim(tostring(made.stderr))
        elseif not st or st.type ~= "fifo" then
            fifo_why = "no FIFO this Neovim can stat; Windows has none"
        else
            fifo = true
        end
    end
    -- The directory behind the namespace is reached under other request
    -- spellings too: a case variant on a case-folding volume, a link to a
    -- file in it and a link to it. Each is read by the name the disk gives
    -- it, as the dot rule reads one. The case variant holds on every
    -- volume: where case is kept it names no file and is 404 all the same,
    -- which its label says, since there the rule is never reached.
    -- A row runs only where its name resolves into __live/: a link that
    -- dangles is answered as a missing name, so a GET's 404 then holds
    -- with no rule reached, and OPTIONS or POST gets the root route's 204
    -- or 405.
    local file_link, file_link_err = uv.fs_symlink("__live" .. sep .. "other.txt", site .. "/link.txt")
    local dir_link, dir_link_err = uv.fs_symlink("__live", site .. "/dirlink", { dir = true })
    local file_why = unresolved(file_link, file_link_err, site .. "/link.txt", site .. "/__live/other.txt")
    local through_why = unresolved(dir_link, dir_link_err, site .. "/dirlink/other.txt", site .. "/__live/other.txt")
    local dir_why = unresolved(dir_link, dir_link_err, site .. "/dirlink", site .. "/__live")
    local folds = uv.fs_stat(site .. "/__LIVE/other.txt") ~= nil
    local resolved = {
        {
            "/__LIVE/other.txt",
            true,
            nil,
            folds and "which this case-folding volume resolves under __live/"
                or "which names no file on this case-keeping volume",
        },
        { "/link.txt", not file_why, file_why },
        { "/dirlink/other.txt", not through_why, through_why },
        { "/dirlink/", not dir_why, dir_why },
    }
    for _, c in ipairs({
        { "no cors, no token", {} },
        { "cors", { cors = true } },
        { "a token", { token = "tok" } },
        { "cors and a token", { cors = true, token = "tok" } },
    }) do
        local cfg = vim.tbl_extend("force", { root = site, features = { dirlist = { enabled = true } } }, c[2])
        local inst = serve(cfg)
        local port = inst.port
        local q = cfg.token and "?t=tok" or ""
        for _, target in ipairs({
            "/__live/other.txt",
            "/__live/other.txt?t=tok",
            "/__live/",
            "/__live",
            "/__live%2fother.txt",
            "//__live/other.txt",
            "/./__live/other.txt",
            "/%5F_live/other.txt",
        }) do
            -- The server shares this process's vim.uv, so a filesystem call
            -- naming the directory is seen here.
            local touched = {}
            local real_fs = {}
            for _, fn in ipairs({ "fs_stat", "fs_lstat", "fs_realpath", "fs_open", "fs_scandir" }) do
                real_fs[fn] = uv[fn]
                uv[fn] = function(p, ...)
                    if type(p) == "string" and p:lower():find("__live", 1, true) then
                        table.insert(touched, fn .. " " .. p)
                    end
                    return real_fs[fn](p, ...)
                end
            end
            local sent, r = pcall(raw, port, get(target, port))
            for fn, f in pairs(real_fs) do
                uv[fn] = f
            end
            assert(sent, r)
            eq(#touched, 0, ("under %s, %s reads no disk: %s"):format(c[1], target, table.concat(touched, ", ")))
            eq(r.status, 404, ("under %s, %s is 404"):format(c[1], target))
            ok(not r.body:find("USERFILE", 1, true), ("under %s, %s never serves the file"):format(c[1], target))
            eq(r.headers["access-control-allow-origin"], nil, ("under %s, %s carries no ACAO"):format(c[1], target))
        end
        for _, t in ipairs(resolved) do
            local label = ("under %s, %s, %s, is 404"):format(c[1], t[1], t[4] or "which resolves under __live/")
            if t[2] then
                local r = raw(port, get(t[1] .. q, port))
                eq(r.status, 404, label)
                ok(not r.body:find("USERFILE", 1, true), ("under %s, %s never serves the file"):format(c[1], t[1]))
                eq(r.headers["access-control-allow-origin"], nil, ("under %s, %s carries no ACAO"):format(c[1], t[1]))
                -- The preflight and any method but GET read the request's
                -- spelling alone, so a link elsewhere into the directory
                -- got the root route's 204 and its origin line, or 405.
                for _, method in ipairs({ "OPTIONS", "POST" }) do
                    local asked = ("%s %s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nOrigin: http://a.test\r\n"):format(
                        method,
                        t[1],
                        port
                    ) .. "Access-Control-Request-Method: GET\r\n\r\n"
                    r = raw(port, asked)
                    eq(r.status, 404, ("under %s, %s %s is 404"):format(c[1], method, t[1]))
                    eq(
                        r.headers["access-control-allow-origin"],
                        nil,
                        ("under %s, %s %s carries no ACAO"):format(c[1], method, t[1])
                    )
                end
            else
                H.skip(label .. " (" .. t[3] .. ")")
            end
        end
        if fifo then
            local t0 = uv.hrtime()
            local r = raw(port, get("/__live/x", port))
            local ms = (uv.hrtime() - t0) / 1e6
            eq(r.status, 404, ("under %s, a FIFO at /__live/x is 404"):format(c[1]))
            ok(ms < 1000, ("under %s, and answers at once, never opened (%d ms)"):format(c[1], ms))
        else
            H.skip(("under %s, a FIFO at /__live/x is 404 at once (%s)"):format(c[1], fifo_why))
        end
        eq(raw(port, get("/__live/script.js", port)).status, 200, "under " .. c[1] .. ", the client script is 200")
        eq(stream_head(port, "/__live/events" .. q).status, 200, "under " .. c[1] .. ", the event stream is 200")
        eq(
            raw(port, get("/__live/inject" .. (q == "" and "?" or q .. "&") .. "event=x", port)).status,
            200,
            "under " .. c[1] .. ", inject is 200"
        )
        eq(
            raw(port, get("/__live/asset" .. (q == "" and "?" or q .. "&") .. "p=pic.png", port)).status,
            200,
            "under " .. c[1] .. ", the asset route is 200"
        )
        eq(raw(port, get("/index.html", port)).status, 200, "under " .. c[1] .. ", a root-route file is 200")
    end
    local gated = serve({ root = site, token = "tok", protected_paths = { "^/__live/" } })
    eq(
        raw(gated.port, get("/__live/other.txt", gated.port)).status,
        401,
        "under a pattern matching /__live/, a name that is no route is 401 without the token"
    )
    eq(raw(gated.port, get("/__live/other.txt?t=tok", gated.port)).status, 404, "and 404 with it")
end)

-- The listing named the __live directory and links into it, each 404 on
-- a click. As with a name the dot rule refuses, it names none of them.
H.case("Section 9: a listing names nothing behind /__live/", function()
    local site = H.tmpdir()
    vim.fn.mkdir(site .. "/__live", "p")
    H.write_file(site .. "/__live/other.txt", "USERFILE")
    H.write_file(site .. "/plain.txt", "plain")
    -- The first two rows need no link, so a link that does not resolve
    -- skips its own row alone.
    local links = {
        {
            target = "__live" .. sep .. "other.txt",
            name = "/lo.txt",
            want = "/__live/other.txt",
            row = "nor a link to a file in it",
        },
        { target = "__live", name = "/dl", want = "/__live", flags = { dir = true }, row = "nor a link to it" },
    }
    for _, l in ipairs(links) do
        local made, err = uv.fs_symlink(l.target, site .. l.name, l.flags)
        l.why = unresolved(made, err, site .. l.name, site .. l.want)
    end
    local inst = serve({ root = site, features = { dirlist = { enabled = true } } })
    local listing = raw(inst.port, get("/", inst.port)).body
    ok(listing:find('href="/plain.txt"', 1, true) ~= nil, "the root listing names plain.txt")
    ok(not listing:find('href="/__live/"', 1, true), "and not the __live directory")
    for _, l in ipairs(links) do
        if l.why then
            H.skip(l.row .. " (" .. l.why .. ")")
        else
            ok(not listing:find('href="' .. l.name, 1, true), l.row)
        end
    end
end)

-- An index.html linking into the directory behind /__live/ made its
-- whole directory 404. As with an index the dot rule refuses, it is not
-- the directory's, so the next index name or the listing answers.
H.case("Section 10: an index that resolves behind /__live/ is not the directory's", function()
    local site = H.tmpdir()
    vim.fn.mkdir(site .. "/__live", "p")
    H.write_file(site .. "/__live/page.html", "<html><body>LIVEPAGE</body></html>")
    for _, dir in ipairs({ "both", "solo" }) do
        vim.fn.mkdir(site .. "/" .. dir, "p")
    end
    H.write_file(site .. "/both/index.htm", "<html><body>PLAIN</body></html>")
    -- Each row reads its own directory's link, so a link that does not
    -- resolve skips its own row alone.
    local why = {}
    for _, dir in ipairs({ "both", "solo" }) do
        local link = site .. "/" .. dir .. "/index.html"
        local made, err = uv.fs_symlink(".." .. sep .. "__live" .. sep .. "page.html", link)
        why[dir] = unresolved(made, err, link, site .. "/__live/page.html")
    end
    local inst = serve({ root = site, features = { dirlist = { enabled = true } } })
    if why.both then
        H.skip("an index.htm beside an index.html linking into __live/ is served (" .. why.both .. ")")
    else
        local r = raw(inst.port, get("/both/", inst.port))
        ok(
            r.status == 200 and r.body:find("PLAIN", 1, true) ~= nil,
            ("an index.htm beside an index.html linking into __live/ is served (got %d)"):format(r.status)
        )
    end
    if why.solo then
        H.skip("with no other index the directory is listed (" .. why.solo .. ")")
    else
        local r = raw(inst.port, get("/solo/", inst.port))
        ok(
            r.status == 200 and r.body:find("Index of /solo/", 1, true) ~= nil and not r.body:find("LIVEPAGE", 1, true),
            ("with no other index the directory is listed (got %d)"):format(r.status)
        )
    end
end)

-- A directory made as __LIVE is the reserved one on a case-folding
-- volume, where it and __live are one directory, and it was served with
-- the root route's headers. The name on disk is read without regard to
-- case on every volume, so no detection of how a volume folds is needed;
-- the request's own spelling stays exact.
H.case("Section 11: the directory behind /__live/ is matched in any case", function()
    local site = H.tmpdir()
    vim.fn.mkdir(site .. "/__LIVE", "p")
    H.write_file(site .. "/__LIVE/x.txt", "UPPERFILE")
    H.write_file(site .. "/__LIVE/page.html", "<html><body>LIVEPAGE</body></html>")
    H.write_file(site .. "/plain.txt", "plain")
    vim.fn.mkdir(site .. "/solo", "p")
    local link = site .. "/solo/index.html"
    local made, made_err = uv.fs_symlink(".." .. sep .. "__LIVE" .. sep .. "page.html", link)
    local link_why = unresolved(made, made_err, link, site .. "/__LIVE/page.html")
    local inst = serve({ root = site, cors = true, features = { dirlist = { enabled = true } } })
    for _, target in ipairs({ "/__LIVE/x.txt", "/__Live/x.txt", "/__live/x.txt", "/__LIVE/" }) do
        local r = raw(inst.port, get(target, inst.port))
        eq(r.status, 404, target .. " is 404")
        ok(not r.body:find("UPPERFILE", 1, true), target .. " never serves the file")
        eq(r.headers["access-control-allow-origin"], nil, target .. " carries no ACAO")
    end
    local listing = raw(inst.port, get("/", inst.port)).body
    ok(listing:find('href="/plain.txt"', 1, true) ~= nil, "the root listing names plain.txt")
    ok(not listing:find("__LIVE", 1, true), "and not the __LIVE directory")
    if not link_why then
        local r = raw(inst.port, get("/solo/", inst.port))
        ok(
            r.status == 200 and r.body:find("Index of /solo/", 1, true) ~= nil and not r.body:find("LIVEPAGE", 1, true),
            ("an index linking into __LIVE/ is not the directory's, which is listed (got %d)"):format(r.status)
        )
    else
        H.skip("an index linking into __LIVE/ is not the directory's (" .. link_why .. ")")
    end
end)

-- The rule holds the root's own __live entry alone, and each edge of it
-- is a promise: the file the server was started on is served at / though
-- it sits there, a directory so named below the root is an ordinary one,
-- listed and served, and the asset route serves one under asset_root.
H.case("Section 12: the rule reaches the root's own __live entry alone", function()
    local site = H.tmpdir()
    vim.fn.mkdir(site .. "/__live", "p")
    H.write_file(site .. "/__live/page.html", "<html><body>LIVEPAGE</body></html>")
    vim.fn.mkdir(site .. "/sub/__live", "p")
    H.write_file(site .. "/sub/__live/x.txt", "NESTED")
    vim.fn.mkdir(site .. "/assets/__live", "p")
    H.write_file(site .. "/assets/__live/pic.png", "PNGDATA")
    local inst = serve({
        root = site,
        token = "tok",
        default_index = site .. "/__live/page.html",
        asset_root = site .. "/assets",
        features = { dirlist = { enabled = true } },
    })
    local r = raw(inst.port, get("/", inst.port))
    ok(
        r.status == 200 and r.body:find("LIVEPAGE", 1, true) ~= nil,
        ("the started-on file in <root>/__live/ is served at / (got %d)"):format(r.status)
    )
    eq(raw(inst.port, get("/__live/page.html", inst.port)).status, 404, "and at its own name it is 404")
    r = raw(inst.port, get("/sub/__live/x.txt", inst.port))
    ok(r.status == 200 and r.body == "NESTED", ("<root>/sub/__live/x.txt is served (got %d)"):format(r.status))
    r = raw(inst.port, get("/sub/", inst.port))
    ok(
        r.status == 200 and r.body:find('href="/sub/__live/"', 1, true) ~= nil,
        ("and the listing of /sub/ names its __live directory (got %d)"):format(r.status)
    )
    r = raw(inst.port, get("/__live/asset?p=__live/pic.png&t=tok", inst.port))
    ok(
        r.status == 200 and r.body == "PNGDATA",
        ("the asset route serves __live/pic.png under asset_root with the token (got %d)"):format(r.status)
    )
    eq(raw(inst.port, get("/__live/asset?p=__live/pic.png", inst.port)).status, 401, "and wants the token for it")
end)

-- A link named __Live at the root was read by the name it resolves to, so
-- one pointing at an ordinary directory of the root served that
-- directory's files under the reserved name, with the root route's
-- origin line. The request's first segment is read in any case too, so
-- the entry is refused whatever it resolves to; the directory it points
-- at is served by its own name. A link out of the root is refused by
-- containment before its name is read, so its rows say so; the links to
-- the root's own file and to the root itself are answered by the name.
H.case("Section 13: a link named __live at the root is refused whatever it resolves to", function()
    local outside = H.tmpdir()
    H.write_file(outside .. "/x.txt", "OUTSIDE")
    for _, c in ipairs({
        { "an ordinary directory of the root", "real" },
        { "a directory outside the root (refused by containment)" },
    }) do
        local site = H.tmpdir()
        vim.fn.mkdir(site .. "/real", "p")
        H.write_file(site .. "/real/x.txt", "INROOT")
        H.write_file(site .. "/plain.txt", "plain")
        local target = c[2] and (site .. "/" .. c[2]) or outside
        local made, made_err = uv.fs_symlink(target, site .. "/__Live", { dir = true, junction = true })
        local why = unresolved(made, made_err, site .. "/__Live", target)
        local inst = serve({ root = site, cors = true, features = { dirlist = { enabled = true } } })
        if not why then
            for _, path in ipairs({ "/__Live/x.txt", "/__LIVE/x.txt", "/__live/x.txt", "/__Live/", "/__Live" }) do
                local r = raw(inst.port, get(path, inst.port))
                local label = ("%s through a link to %s"):format(path, c[1])
                eq(r.status, 404, label .. " is 404")
                ok(
                    not r.body:find("INROOT", 1, true) and not r.body:find("OUTSIDE", 1, true),
                    label .. " serves nothing"
                )
                eq(r.headers["access-control-allow-origin"], nil, label .. " carries no ACAO")
            end
            -- The preflight read the exact spelling alone, so a case
            -- variant got the root route's 204 and its origin line.
            for _, path in ipairs({ "/__Live/x.txt", "/__LIVE/x.txt", "/__live/x.txt" }) do
                local r = raw(
                    inst.port,
                    ("OPTIONS %s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nOrigin: http://a.test\r\n"):format(path, inst.port)
                        .. "Access-Control-Request-Method: GET\r\n\r\n"
                )
                local label = ("a preflight for %s beside a link to %s"):format(
                    path,
                    (c[1]:gsub("containment", "name"))
                )
                eq(r.status, 404, label .. " is 404")
                eq(r.headers["access-control-allow-origin"], nil, label .. " carries no ACAO")
            end
            local listing = raw(inst.port, get("/", inst.port)).body
            ok(
                listing:find('href="/plain.txt"', 1, true) ~= nil and not listing:find("__Live", 1, true),
                "the root listing names plain.txt and not the link to " .. c[1]
            )
            if c[2] then
                local r = raw(inst.port, get("/real/x.txt", inst.port))
                ok(
                    r.status == 200 and r.body == "INROOT",
                    ("the directory the link points at is served by its own name (got %d)"):format(r.status)
                )
            end
        else
            H.skip(("a link named __Live to %s is refused (%s)"):format(c[1], why))
        end
    end
    -- Each resolves to a name the disk rule lets through: plain.txt, or the
    -- root, whose files then sit under the reserved spelling. The root is
    -- named bare: libuv writes a junction's target as spelled, a . segment
    -- included, and a junction to <root>/. was made on Windows but did not
    -- resolve while the ones above did (measured). Elsewhere the kernel
    -- drops the . and the server reads a link by realpath alone, so the
    -- bare name tests the same thing there.
    for _, c in ipairs({
        { "a file of the root", "plain.txt", false, { "/__Live", "/__LIVE" } },
        { "the root itself", false, true, { "/__Live/plain.txt", "/__LIVE/plain.txt" } },
    }) do
        local site = H.tmpdir()
        H.write_file(site .. "/plain.txt", "PLAINFILE")
        local target = c[2] and (site .. "/" .. c[2]) or site
        local flags = c[3] and { dir = true, junction = true } or nil
        local made, made_err = uv.fs_symlink(target, site .. "/__Live", flags)
        local why = unresolved(made, made_err, site .. "/__Live", target)
        local inst = serve({ root = site, cors = true, features = { dirlist = { enabled = true } } })
        if not why then
            for _, path in ipairs(c[4]) do
                local r = raw(inst.port, get(path, inst.port))
                local label = ("%s through a link to %s"):format(path, c[1])
                eq(r.status, 404, label .. " is 404")
                ok(not r.body:find("PLAINFILE", 1, true), label .. " serves nothing")
                eq(r.headers["access-control-allow-origin"], nil, label .. " carries no ACAO")
            end
            local r = raw(inst.port, get("/plain.txt", inst.port))
            ok(
                r.status == 200 and r.body == "PLAINFILE",
                ("plain.txt is served by its own name beside a link to %s (got %d)"):format(c[1], r.status)
            )
        else
            H.skip(("a link named __Live to %s is refused (%s)"):format(c[1], why))
        end
    end
end)

H.finish()
