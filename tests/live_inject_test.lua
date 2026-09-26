-- tests/live_inject_test.lua
-- /__live/inject broadcasts to every open tab, so a page on another site
-- (another port of the same host counts) must not reach it. A browser says
-- which page sent a request in Sec-Fetch-Site and, on a cors request,
-- Origin; clients that send neither, such as curl and markdown-preview's
-- raw sender, keep working on a loopback bind. A browser marks nothing it
-- sends to a plain-http LAN address, so there, without a token, only a
-- request that names this origin fires events.
--
-- Run: nvim --headless -u NONE -l tests/live_inject_test.lua

local H = dofile(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "helpers.lua"))
H.isolate()
H.rtp()

local server = require("live_server.server")
local eq, ok = H.eq, H.ok

local root = H.tmpdir()
H.write_file(root .. "/index.html", "<html><body>ok</body></html>")

local function serve(cfg)
    local inst = server.start(vim.tbl_extend("keep", cfg or {}, {
        port = 0,
        root = root,
        live = { enabled = false, inject_script = false },
        features = { dirlist = { enabled = false } },
    }))
    H.defer(function()
        server.stop(inst)
    end)
    return inst
end

local function inject(port, query, headers, host)
    local raw = ("GET /__live/inject?%s HTTP/1.1\r\nHost: %s\r\n%s\r\n"):format(
        query,
        host or ("127.0.0.1:%d"):format(port),
        headers or ""
    )
    return H.response(assert(H.raw_request(port, raw)))
end

H.case("Section 1: a cross-site request cannot fire events", function()
    local inst = serve()
    local port = inst.port
    local own = ("http://127.0.0.1:%d"):format(port)
    local r = inject(port, "event=reload", "Sec-Fetch-Site: cross-site\r\n")
    eq(r.status, 403, "Sec-Fetch-Site: cross-site is 403")
    eq(r.reason, "Forbidden", "with its reason phrase")
    eq(inject(port, "event=reload", "Sec-Fetch-Site: same-site\r\n").status, 403, "same-site (another port) is 403")
    eq(inject(port, "event=reload", "Origin: https://evil.example\r\n").status, 403, "a foreign Origin is 403")
    eq(inject(port, "event=reload", "Origin: null\r\n").status, 403, "Origin: null is 403")
    eq(inject(port, "event=reload", "Sec-Fetch-Site: same-origin\r\n").status, 200, "same-origin is served")
    eq(
        inject(port, "event=reload", "Sec-Fetch-Site: none\r\n").status,
        200,
        "none (an extension, a typed URL) is served"
    )
    eq(inject(port, "event=reload", "Origin: " .. own .. "\r\n").status, 200, "the server's own Origin is served")
    eq(inject(port, "event=reload").status, 200, "a request with neither header is served on a loopback bind")
end)

H.case("Section 2: a refused request broadcasts nothing", function()
    local inst = serve()
    local port = inst.port
    local c = assert(H.raw_connect(port))
    assert(c:send(("GET /__live/events HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n\r\n"):format(port)))
    c:read(2000, function(d)
        return d:find("retry: 1000\n\n", 1, true) ~= nil
    end)
    inject(port, "event=forged", "Sec-Fetch-Site: cross-site\r\n")
    inject(port, "event=real", "Sec-Fetch-Site: same-origin\r\n")
    local data = c:read(2000, function(d)
        return d:find("event: real", 1, true) ~= nil
    end)
    ok(data:find("event: real", 1, true) ~= nil, "the allowed event arrives")
    ok(not data:find("event: forged", 1, true), "the refused one never does")
end)

H.case("Section 3: the token does not stand in for the site check", function()
    local inst = serve({ token = "tok" })
    eq(
        inject(inst.port, "event=reload&t=tok", "Sec-Fetch-Site: cross-site\r\n").status,
        403,
        "a cross-site request with the token is 403"
    )
    eq(inject(inst.port, "event=reload&t=tok").status, 200, "the token with no browser headers is served")
end)

H.case("Section 4: a tokenless network bind fires events only for its own origin", function()
    -- What an <img> on any site sends to a LAN address over plain http:
    -- no Fetch Metadata, and no Origin on a no-cors GET.
    local inst = serve({ host = "0.0.0.0" })
    local port = inst.port
    local own = ("http://127.0.0.1:%d"):format(port)
    eq(inject(port, "event=reload").status, 403, "a request with neither header is 403")
    eq(inject(port, "event=reload", "Origin: " .. own .. "\r\n").status, 200, "a matching Origin is served")
    eq(
        inject(port, "event=reload", "Sec-Fetch-Site: same-origin\r\n").status,
        200,
        "Sec-Fetch-Site: same-origin is served"
    )
    eq(inject(port, "event=reload", "Sec-Fetch-Site: cross-site\r\n").status, 403, "Sec-Fetch-Site: cross-site is 403")
    local gated = serve({ host = "0.0.0.0", token = "tok" })
    eq(inject(gated.port, "event=reload&t=tok").status, 200, "with a token, a request with neither header is served")
end)

H.case("Section 5: a loopback bind reached by a name a browser does not mark", function()
    local inst = serve({ allowed_hosts = { "dev.test" } })
    local host = "dev.test:" .. inst.port
    eq(inject(inst.port, "event=reload", nil, host).status, 403, "an allowed_hosts name with neither header is 403")
    eq(
        inject(inst.port, "event=reload", "Sec-Fetch-Site: same-origin\r\n", host).status,
        200,
        "and is served with Sec-Fetch-Site: same-origin"
    )
end)

H.finish()
