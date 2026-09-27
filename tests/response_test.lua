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

H.finish()
