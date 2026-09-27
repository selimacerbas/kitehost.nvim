-- tests/response_test.lua
-- What every response carries and what it must not: the referrer policy,
-- the cors headers (never on /__live/*), the preflight answer, and a 404
-- that names the request, never a filesystem path.
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
-- of its own fields once under any spelling of the name: a caller's line
-- beside the stream's own would leave the client to pick which it reads.
H.case("Section 3: the event stream carries the caller's headers, its own fields once", function()
    local inst = serve({
        headers = {
            ["X-Frame-Options"] = "DENY",
            ["content-type"] = "text/plain",
            ["CACHE-CONTROL"] = "max-age=60",
            ["connection"] = "close",
        },
    })
    local r = stream_head(inst.port, "/__live/events")
    eq(r.headers["x-frame-options"], "DENY", "a caller's header reaches the stream")
    eq(r.headers["content-type"], "text/event-stream", "the stream's own type holds against a caller's spelling")
    eq(r.count["content-type"], 1, "and goes out once")
    eq(r.count["cache-control"], 1, "its Cache-Control goes out once")
    eq(r.count["connection"], 1, "and its Connection once")
end)

-- cors = true promised cross-origin reads of the root route, but the
-- browser's preflight got 405 and it refused the read. /__live/* answers
-- no cross-origin read, so its preflight keeps the 405, and every 405
-- names the one method served (RFC 9110 15.5.6). The path checks still
-- come first: a NUL in the path is 400 whatever the method.
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
    eq(
        raw(port, ("OPTIONS /__live/events HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n%s\r\n"):format(port, pre)).status,
        405,
        "a preflight on /__live/* is 405"
    )
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
    -- A caller's ACAO riding beside the cors one would be a second origin
    -- line, and a browser refuses a preflight with two.
    local both = serve({ cors = "https://a.example", headers = { ["access-CONTROL-allow-origin"] = "*" } })
    r = raw(both.port, ("OPTIONS /style.css HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n%s\r\n"):format(both.port, pre))
    eq(r.count["access-control-allow-origin"], 1, "a preflight beside a caller's ACAO sends one origin line")
    eq(r.headers["access-control-allow-origin"], "https://a.example", "and it is the cors one")
end)

H.finish()
