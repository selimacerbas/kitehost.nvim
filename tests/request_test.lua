-- tests/request_test.lua
-- The request pipeline, driven over raw TCP: split writes, missing or
-- doubled headers, a NUL byte, a half-close, which curl cannot send.
-- Section 1 pins the behaviour the pipeline refactor must keep; each later
-- section holds one change made on top of it.
--
-- Run: nvim --headless -u NONE -l tests/request_test.lua

local H = dofile(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "helpers.lua"))
H.isolate()
H.rtp()

local server = require("live_server.server")
local eq, ok = H.eq, H.ok

local root = H.tmpdir()
H.write_file(root .. "/index.html", "<html><body>hi</body></html>")
H.write_file(root .. "/style.css", "body{color:red}")
H.write_file(root .. "/content.md", "# secret")
H.write_file(root .. "/hello.txt", "hello")
-- 2 MiB, so a transfer is still streaming when a late chunk or an abort
-- arrives.
local big = string.rep("0123456789abcdef", 131072)
H.write_file(root .. "/big.bin", big)

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

-- One request on its own connection: the parsed responses, the tail (what
-- followed them, unparsed) and the bytes. A failed exchange raises.
local function ask(port, bytes)
    local data = assert(H.raw_request(port, bytes))
    local list, tail = H.responses(data)
    return list, tail, data
end

local function get(path, port, extra)
    return ("GET %s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n%s\r\n"):format(path, port, extra or "")
end

H.case("Section 1: the behaviour the pipeline refactor keeps", function()
    local inst = serve({ token = "tok", protected_paths = { "^/content%.md$" } })
    local port = inst.port
    local res, tail = ask(port, get("/style.css", port))
    eq(#res, 1, "one request, one response")
    eq(res[1] and res[1].status, 200, "a request in one write is served")
    eq(res[1] and res[1].body, "body{color:red}", "the body is the file")
    eq(res[1] and res[1].headers.connection, "close", "a file response closes the connection")
    eq(tail, "", "nothing follows the file response")
    res = ask(port, "GET /index.html HTTP/1.0\n\n")
    eq(res[1] and res[1].status, 200, "a head ended by bare LF lines is served")
    res = ask(port, get("/content.md", port))
    eq(res[1] and res[1].status, 401, "a protected path without the token is 401")
    eq(res[1] and res[1].body, "Unauthorized", "with its body")
    res = ask(port, get("/content.md?t=tok", port))
    eq(res[1] and res[1].status, 200, "the token opens it")
    eq(res[1] and res[1].body, "# secret", "and serves the file")
    res = ask(port, ("POST / HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n\r\n"):format(port))
    eq(res[1] and res[1].status, 405, "a method other than GET is 405")
    eq(res[1] and res[1].body, "Method Not Allowed", "with its body")
    res = ask(port, "get / HTTP/1.1\r\n\r\n")
    eq(res[1] and res[1].status, 400, "a lowercase method is 400")
    res = ask(port, "\r\n\r\n")
    eq(res[1] and res[1].status, 400, "an empty head is 400")

    -- Buffering must keep SSE disconnect detection: the stream leaves the
    -- client list only when its socket reports the end.
    local c = assert(H.raw_connect(port))
    assert(c:send(get("/__live/events?t=tok", port)))
    local head = c:read(2000, function(d)
        return d:find("retry: 1000\n\n", 1, true) ~= nil
    end)
    local sse = H.responses(head)[1]
    eq(sse and sse.headers["content-type"], "text/event-stream", "the event stream opens")
    ok(
        H.wait_for(function()
            return server.connected_client_count(inst) == 1
        end, 2000),
        "the stream counts as one client"
    )
    assert(c:send("GET /whatever HTTP/1.1\r\n\r\n"))
    local after = c:read(300)
    eq(after, head, "a later chunk on the stream gets no response")
    -- Silence alone would also fit a stream closed on the chunk.
    eq(server.connected_client_count(inst), 1, "and the stream stays open")
    c:close()
    ok(
        H.wait_for(function()
            return server.connected_client_count(inst) == 0
        end, 2000),
        "a closed stream leaves the client list"
    )
end)

H.case("Section 2: one request per connection, read to the end of its head", function()
    local inst = serve()
    local port = inst.port
    local c = assert(H.raw_connect(port))
    assert(c:send("GET /sty"))
    vim.wait(150)
    assert(c:send(("le.css HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n\r\n"):format(port)))
    local res = H.responses((c:read(3000)))
    eq(#res, 1, "a request line split across writes gets one response")
    eq(res[1] and res[1].status, 200, "for the whole path")
    eq(res[1] and res[1].body, "body{color:red}", "the body is /style.css")

    c = assert(H.raw_connect(port))
    assert(c:send("GET /index.html HTTP/1.1\r\nHo"))
    vim.wait(100)
    assert(c:send(("st: 127.0.0.1:%d\r\n\r\n"):format(port)))
    res = H.responses((c:read(3000)))
    eq(#res, 1, "headers split across writes get one response")
    eq(res[1] and res[1].status, 200, "and it is served")

    -- A late chunk used to be parsed as a new request and its 400 spliced
    -- into the streaming body (measured at byte 131176).
    c = assert(H.raw_connect(port))
    assert(c:send(get("/big.bin", port)))
    c:read(3000, function(d)
        return #d > 1024
    end)
    assert(c:send(get("/style.css", port)))
    res = H.responses((c:read(10000)))
    eq(#res, 1, "a second request on a streaming connection gets no response")
    ok(res[1] ~= nil and res[1].body == big, "the streamed body arrives whole, nothing spliced in")

    res = ask(port, "GET / HTTP/1.1\r\nX-Pad: " .. string.rep("a", 17 * 1024))
    eq(res[1] and res[1].status, 431, "a head over 16 KiB with no end is 431")
    eq(res[1] and res[1].reason, "Request Header Fields Too Large", "with its reason phrase")

    -- The blank line's two line ends may mix CRLF and bare LF; before the
    -- buffering the old parser answered every mix, so the buffer must too.
    res = ask(port, "GET /index.html HTTP/1.0\n\r\n")
    eq(res[1] and res[1].status, 200, "a head ended by a bare LF then CRLF is served")
    res = ask(port, "GET /index.html HTTP/1.0\r\n\n")
    eq(res[1] and res[1].status, 200, "a head ended by CRLF then a bare LF is served")
end)

H.case("Section 3: the head, parsed once", function()
    local inst = serve()
    local port = inst.port
    local res =
        ask(port, ("GET http://127.0.0.1:%d/style.css HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n\r\n"):format(port, port))
    eq(res[1] and res[1].status, 200, "an absolute-form target is served from its path")
    eq(res[1] and res[1].body, "body{color:red}", "the path after the authority names the file")
    res = ask(port, "GET javascript:alert(1)//%2e%2e? HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
    eq(res[1] and res[1].status, 400, "a target that is neither a path nor an http URL is 400")
    res = ask(port, "GET /style.css\r\n\r\n")
    eq(res[1] and res[1].status, 400, "a request line without an HTTP version is 400")
    res = ask(port, "GET /style.css HTTP/2.0\r\nHost: 127.0.0.1\r\n\r\n")
    eq(res[1] and res[1].status, 400, "a version other than HTTP/1.0 or 1.1 is 400")
    res = ask(port, "GET /style.css HTTP/1.1\r\nHost: 127.0.0.1\r\nno colon here\r\n\r\n")
    eq(res[1] and res[1].status, 400, "a header line without a colon is 400")
    res = ask(port, "GET /style.css HTTP/1.1\r\nHost: 127.0.0.1\r\nX-A: 1\r\n folded\r\n\r\n")
    eq(res[1] and res[1].status, 400, "an obsolete folded header line is 400")
end)

H.finish()
