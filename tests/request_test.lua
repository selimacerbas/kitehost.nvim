-- tests/request_test.lua
-- The request pipeline, driven over raw TCP: split writes, a missing or
-- doubled Host, a NUL byte, a half-close and a truncated head, which curl
-- cannot send.
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
-- 2 MiB, so a transfer is still streaming when a late chunk arrives.
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
-- followed them, unparsed), the bytes and whether the server closed the
-- connection. A failed exchange raises.
local function ask(port, bytes)
    local data, eof = assert(H.raw_request(port, bytes))
    local list, tail = H.responses(data)
    return list, tail, data, eof
end

local function get(path, port, extra)
    return ("GET %s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n%s\r\n"):format(path, port, extra or "")
end

H.case("Section 1: the behaviour the pipeline refactor keeps", function()
    local inst = serve({ token = "tok", protected_paths = { "^/content%.md$" } })
    local port = inst.port
    local res, tail, _, closed = ask(port, get("/style.css", port))
    eq(#res, 1, "one request, one response")
    eq(res[1] and res[1].status, 200, "a request in one write is served")
    eq(res[1] and res[1].body, "body{color:red}", "the body is the file")
    eq(res[1] and res[1].headers.connection, "close", "a file response says it closes the connection")
    eq(closed, true, "a file response closes the connection")
    eq(tail, "", "nothing follows the file response")
    res = ask(port, "GET /index.html HTTP/1.0\n\n")
    eq(res[1] and res[1].status, 200, "a head ended by bare LF lines is served")
    res = ask(port, get("/content.md", port))
    eq(res[1] and res[1].status, 401, "a protected path without the token is 401")
    eq(res[1] and res[1].body, "Unauthorized", "with its body")
    res = ask(port, get("/content.md?t=tok", port))
    eq(res[1] and res[1].status, 200, "the token opens it")
    eq(res[1] and res[1].body, "# secret", "and serves the file")
    res, _, _, closed = ask(port, ("POST / HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n\r\n"):format(port))
    eq(res[1] and res[1].status, 405, "a method other than GET is 405")
    eq(res[1] and res[1].body, "Method Not Allowed", "with its body")
    eq(closed, true, "a 405 closes the connection")
    res, _, _, closed = ask(port, "get / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
    eq(res[1] and res[1].status, 400, "a lowercase method is 400")
    ok(
        res[1] and res[1].body:find("request line", 1, true) ~= nil,
        "a lowercase method is refused by the request line's grammar"
    )
    eq(closed, true, "a 400 closes the connection")
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

    -- A late chunk used to be parsed as a new request and its answer spliced
    -- into the streaming body at whatever offset the read boundary fell.
    c = assert(H.raw_connect(port))
    assert(c:send(get("/big.bin", port)))
    c:read(3000, function(d)
        return #d > 1024
    end)
    assert(c:send(get("/style.css", port)))
    res = H.responses((c:read(10000)))
    eq(#res, 1, "a second request on a streaming connection gets no response")
    ok(res[1] ~= nil and res[1].body == big, "the streamed body arrives whole, nothing spliced in")

    -- The cap judges the head's bytes, never its terminator: a head of
    -- exactly the cap is served and one byte more is refused, each with the
    -- blank line in a second write.
    local function head_of(size)
        local prefix = "GET /style.css HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Pad: "
        return prefix .. string.rep("a", size - #prefix)
    end
    for _, case in ipairs({ { 64 * 1024, 200, "served" }, { 64 * 1024 + 1, 431, "431" } }) do
        c = assert(H.raw_connect(port))
        assert(c:send(head_of(case[1])))
        vim.wait(100)
        assert(c:send("\r\n\r\n"))
        res = H.responses((c:read(3000)))
        c:close()
        eq(res[1] and res[1].status, case[2], ("a head of %d bytes is %s"):format(case[1], case[3]))
    end
    res = ask(port, head_of(60 * 1024) .. "\r\n\r\n")
    eq(res[1] and res[1].status, 200, "a 60 KiB head in one write is served")
    local closed
    res, _, _, closed = ask(port, "GET / HTTP/1.1\r\nX-Pad: " .. string.rep("a", 70 * 1024))
    eq(res[1] and res[1].status, 431, "a head over 64 KiB with no end is 431")
    eq(res[1] and res[1].reason, "Request Header Fields Too Large", "with its reason phrase")
    eq(closed, true, "a 431 closes the connection")

    c = assert(H.raw_connect(port))
    assert(c:send("GET /hello.txt HTTP/1.0\r\n"))
    assert(c:half_close())
    res = H.responses((c:read(3000)))
    c:close()
    eq(res[1] and res[1].status, 400, "a head cut off by a FIN is answered 400")
    -- Bare CR line ends never make a blank line; the FIN answers them.
    c = assert(H.raw_connect(port))
    assert(c:send("GET /hello.txt HTTP/1.0\r\r"))
    assert(c:half_close())
    res = H.responses((c:read(3000)))
    c:close()
    eq(res[1] and res[1].status, 400, "a head of bare CR line ends cut off by a FIN is answered 400")
    -- markdown-preview's lock check connects and closes without a byte.
    c = assert(H.raw_connect(port))
    assert(c:half_close())
    local data, eof = c:read(2000)
    c:close()
    eq(data, "", "a zero-byte connect and FIN gets no response")
    eq(eof, true, "and is closed")

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
    ok(res[1] and res[1].body:find("request target", 1, true) ~= nil, "and is refused for its request target")
    -- The earliest blank line ends the head; what follows is never a second
    -- request.
    res = ask(port, "GET /index.html HTTP/1.0\n\nGET /style.css HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
    eq(#res, 1, "a head ended early gets one response")
    eq(res[1] and res[1].body, "<html><body>hi</body></html>", "for the head the first blank line ends")
    -- The absolute-form path keeps its query and drops its fragment.
    local tok = serve({ token = "tok", protected_paths = { "^/content%.md$" } })
    res =
        ask(tok.port, ("GET http://127.0.0.1:%d/content.md?t=tok HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"):format(tok.port))
    eq(res[1] and res[1].status, 200, "an absolute-form target keeps its query")
    eq(res[1] and res[1].body, "# secret", "so its token opens the file")
    res = ask(tok.port, ("GET http://127.0.0.1:%d/style.css#frag HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"):format(tok.port))
    eq(res[1] and res[1].status, 200, "an absolute-form target's fragment never reaches the path")
    eq(res[1] and res[1].body, "body{color:red}", "and the file is served")
    res = ask(port, "GET /style.css\r\n\r\n")
    eq(res[1] and res[1].status, 400, "a request line without an HTTP version is 400")
    res = ask(port, "GET /style.css HTTP/2.0\r\nHost: 127.0.0.1\r\n\r\n")
    eq(res[1] and res[1].status, 400, "a version other than HTTP/1.0 or 1.1 is 400")
    -- RFC 9110 2.5: a higher minor version of HTTP/1 is answered as 1.1.
    res = ask(port, "GET /style.css HTTP/1.2\r\nHost: 127.0.0.1\r\n\r\n")
    eq(res[1] and res[1].status, 200, "HTTP/1.2 is served as 1.1")
    res = ask(port, "GET /style.css HTTP/10.1\r\nHost: 127.0.0.1\r\n\r\n")
    eq(res[1] and res[1].status, 400, "HTTP/10.1 is 400")
    -- RFC 9112 3 lets a recipient refuse whitespace beyond one SP.
    res = ask(port, "GET  /style.css HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
    eq(res[1] and res[1].status, 400, "two spaces after the method are 400")
    res = ask(port, "GET\t/style.css HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
    eq(res[1] and res[1].status, 400, "a tab separator is 400")
    res = ask(port, "GET /style.css HTTP/1.1 \r\nHost: 127.0.0.1\r\n\r\n")
    eq(res[1] and res[1].status, 400, "a trailing space after the version is 400")
    -- A TLS ClientHello on the plain port starts with 0x16.
    local t1 = vim.uv.hrtime()
    res = ask(port, "\22\3\1\0\5hello")
    eq(res[1] and res[1].status, 400, "bytes that cannot start a request line are refused at once")
    ok((vim.uv.hrtime() - t1) / 1e6 < 500, "without waiting for a head")
    res = ask(port, "GET /style.css HTTP/1.1\r\nHost: 127.0.0.1\r\nno colon here\r\n\r\n")
    eq(res[1] and res[1].status, 400, "a header line without a colon is 400")
    res = ask(port, "GET /style.css HTTP/1.1\r\nHost: 127.0.0.1\r\nX-A: 1\r\n folded\r\n\r\n")
    eq(res[1] and res[1].status, 400, "an obsolete folded header line is 400")
    local t0 = vim.uv.hrtime()
    res = ask(port, "GET /style.css HTTP/1.1\r\nHost: 127.0.0.1\r\nX-A: a" .. string.rep(" ", 16000) .. "b\r\n\r\n")
    eq(res[1] and res[1].status, 200, "a value with a long inner run of blanks is served")
    ok((vim.uv.hrtime() - t0) / 1e6 < 500, "and parsed in one pass")
end)

H.case("Section 4: HTTP/1.1 names its host, once", function()
    local inst = serve()
    local port = inst.port
    local res = ask(port, "GET /style.css HTTP/1.1\r\n\r\n")
    eq(res[1] and res[1].status, 400, "HTTP/1.1 without Host is 400")
    res = ask(port, "GET /style.css HTTP/1.0\r\n\r\n")
    eq(res[1] and res[1].status, 200, "HTTP/1.0 without Host is served")
    res = ask(port, "GET /style.css HTTP/1.1\r\nHost: 127.0.0.1\r\nHost: evil.example\r\n\r\n")
    eq(res[1] and res[1].status, 400, "two Host lines are 400")
    res = ask(port, "GET /style.css HTTP/1.0\r\nHost: a\r\nhost: b\r\n\r\n")
    eq(res[1] and res[1].status, 400, "two Host lines are 400 on HTTP/1.0 too, whatever their case")
    res = ask(port, "GET /hello.txt HTTP/1.1\r\nHost: 127.0.0.1\r\nHost : evil.example\r\n\r\n")
    eq(res[1] and res[1].status, 400, "a second Host with a space before its colon is 400")
    -- markdown-preview's remote.lua sends exactly this: a portless Host.
    res = ask(
        port,
        "GET /__live/inject?event=scroll&data=%7B%7D HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
    )
    eq(res[1] and res[1].status, 200, "markdown-preview's remote.lua request is served")
    res = ask(port, "GET /style.css HTTP/1.1\r\nHost: 127.0.0.1\r\nX-A: a\rb\r\n\r\n")
    eq(res[1] and res[1].status, 400, "a bare CR inside a header value is 400")
    res = ask(port, "GET /style.css HTTP/1.1\r\nHost: 127.0.0.1\r\nX-A: a\0b\r\n\r\n")
    eq(res[1] and res[1].status, 400, "a NUL inside a header value is 400")
    res = ask(port, "GET /style.css HTTP/1.1\r\nHost: 127.0.0.1\r\nX-A: a\r\r\n\r\n")
    eq(res[1] and res[1].status, 400, "a bare CR ending the last header value is 400 too")
end)

H.case("Section 4b: a Host value that is not a host is 400 on every bind", function()
    local function status(port, value, version)
        local r = ask(port, ("GET /style.css HTTP/%s\r\nHost: %s\r\n\r\n"):format(version or "1.1", value))
        return r[1] and r[1].status
    end
    for _, bind in ipairs({ "127.0.0.1", "0.0.0.0" }) do
        local inst = serve({ host = bind })
        local port = inst.port
        eq(status(port, "::1:" .. port), 400, bind .. ": an unbracketed IPv6 address with a port is 400")
        eq(status(port, "[::::]"), 400, bind .. ": brackets around what is no IPv6 address are 400")
        eq(status(port, "[::1"), 400, bind .. ": an unclosed bracket is 400")
        eq(status(port, "%ZZ"), 400, bind .. ": a % not followed by two hex digits is 400")
        eq(status(port, "a..example"), 400, bind .. ": an empty label is 400")
        eq(status(port, "a b"), 400, bind .. ": a space inside the value is 400")
        eq(status(port, "user@127.0.0.1"), 400, bind .. ": userinfo is 400")
        eq(status(port, "127.0.0.1:80a"), 400, bind .. ": a port that is not digits is 400")
        eq(status(port, ""), 400, bind .. ": an empty value is 400")
        eq(status(port, "a b", "1.0"), 400, bind .. ": HTTP/1.0 too")
        eq(status(port, "[::1]:" .. port), 200, bind .. ": a bracketed IPv6 address is served")
        eq(status(port, "localhost:"), 200, bind .. ": an empty port is served")
    end
    -- The grammar's other accepted forms, on a network bind.
    local wide = serve({ host = "0.0.0.0" })
    eq(status(wide.port, "[::ffff:127.0.0.1]:" .. wide.port), 200, "an IPv6 address ending in an IPv4 one is served")
    eq(status(wide.port, "a%41.example"), 200, "a % followed by two hex digits is served")
    local inst = serve()
    local res = ask(inst.port, "GET http://user@127.0.0.1/style.css HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
    eq(res[1] and res[1].status, 400, "an absolute-form authority that is not a host is 400")
end)

H.finish()
