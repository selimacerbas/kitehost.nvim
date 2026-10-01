-- tests/request_test.lua
-- The request pipeline, driven over raw TCP: split writes, a missing or
-- doubled Host, a NUL byte, a half-close and a truncated head, which curl
-- cannot send.
-- Section 1 pins the behaviour the buffered pipeline keeps from the server
-- before it; each later section holds one change made on top of it.
-- Sections 6 and 7 read the index and listing routes, 6 through curl and
-- 7 over raw TCP; Section 8 forces a raise inside the handler; Section 9
-- refuses a target over 8 KiB (414) before the Host check, the gate or
-- any pattern reads it, and times the pattern's CPU cost under the cap.
--
-- Run: nvim --headless -u NONE -l "$PWD/tests/request_test.lua"

local H = dofile(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "helpers.lua"))
H.isolate()
H.rtp()

local server = require("kitehost.server")
local eq, ok = H.eq, H.ok

-- Windows takes a / in a relative link's target unconverted, leaving the
-- link dangling (an absolute target's / resolves; measured on the hosted
-- runner): a relative target here carries the platform's separator. A row
-- through a link runs only where the link resolves to the name it is
-- about; unresolved says why it does not, the reason the row is skipped
-- with.
local sep = package.config:sub(1, 1)
local function unresolved(made, made_err, name, want)
    if not made then
        return "no link: " .. tostring(made_err)
    end
    local real, err = vim.uv.fs_realpath(name)
    if not real then
        return "the link does not resolve: " .. tostring(err)
    end
    if not H.same_path(real, want) then
        return ("the link resolves to %s, not %s"):format(real, want)
    end
end

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

H.case("Section 1: the behaviour the buffered pipeline keeps", function()
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
    res = ask(port, ("GET http://127.0.0.1:%d?t=tok HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"):format(port))
    eq(res[1] and res[1].status, 200, "a query-only absolute form splits before the query")
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
    res = ask(port, "Get /style.css HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
    eq(res[1] and res[1].status, 400, "a mixed-case method is refused by the request line's grammar")
    ok(res[1] and res[1].body:find("request line", 1, true) ~= nil, "by the request line's grammar")
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
    local data, eof = c:read(3000)
    res = H.responses(data)
    c:close()
    eq(res[1] and res[1].status, 400, "a head cut off by a FIN is answered 400")
    eq(eof, true, "and the connection is closed")
    -- Bare CR line ends never make a blank line; the FIN answers them.
    c = assert(H.raw_connect(port))
    assert(c:send("GET /hello.txt HTTP/1.0\r\r"))
    assert(c:half_close())
    data, eof = c:read(3000)
    res = H.responses(data)
    c:close()
    eq(res[1] and res[1].status, 400, "a head of bare CR line ends cut off by a FIN is answered 400")
    eq(eof, true, "and that connection is closed")
    -- markdown-preview's lock check connects and closes without a byte.
    c = assert(H.raw_connect(port))
    assert(c:half_close())
    data, eof = c:read(2000)
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
    -- RFC 9112 2.3: the version is one digit, a dot and one digit.
    res = ask(port, "GET /style.css HTTP/1.10\r\nHost: 127.0.0.1\r\n\r\n")
    eq(res[1] and res[1].status, 400, "HTTP/1.10 is 400")
    res = ask(port, "GET /style.css HTTP/1.00\r\nHost: 127.0.0.1\r\n\r\n")
    eq(res[1] and res[1].status, 400, "HTTP/1.00 is 400")
    -- RFC 9112 3 lets a recipient refuse whitespace beyond one SP.
    res = ask(port, "GET  /style.css HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
    eq(res[1] and res[1].status, 400, "two spaces after the method are 400")
    res = ask(port, "GET\t/style.css HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
    eq(res[1] and res[1].status, 400, "a tab separator is 400")
    res = ask(port, "GET /style.css HTTP/1.1 \r\nHost: 127.0.0.1\r\n\r\n")
    eq(res[1] and res[1].status, 400, "a trailing space after the version is 400")
    -- RFC 9112 2.2: one empty line before the request line is ignored.
    res = ask(port, "\r\nGET /style.css HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
    eq(res[1] and res[1].status, 200, "a leading CRLF before the request line is ignored")
    res = ask(port, "\r\n\r\nGET /style.css HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
    eq(res[1] and res[1].status, 400, "two leading CRLFs make an empty head, which is 400")
    local c = assert(H.raw_connect(port))
    assert(c:send("\r\n"))
    vim.wait(100)
    assert(c:send("GET /style.css HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"))
    res = H.responses((c:read(3000)))
    c:close()
    eq(res[1] and res[1].status, 200, "a leading CRLF in its own read still waits for the request line")
    c = assert(H.raw_connect(port))
    assert(c:send("\r\n"))
    assert(c:half_close())
    res = H.responses((c:read(3000)))
    c:close()
    eq(res[1] and res[1].status, 400, "a CRLF then a FIN is 400")
    ok(res[1] and res[1].body:find("Incomplete", 1, true) ~= nil, "as an incomplete head")
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
    -- A gate may read these; a second copy would let a proxy or a later
    -- check read the other one.
    for _, pair in ipairs({
        { "Origin", "http://127.0.0.1", "https://evil.example" },
        { "Sec-Fetch-Site", "same-origin", "cross-site" },
        { "Sec-Fetch-Mode", "navigate", "cors" },
    }) do
        local name = pair[1]
        res = ask(
            port,
            ("GET /hello.txt HTTP/1.1\r\nHost: 127.0.0.1\r\n%s: %s\r\n%s: %s\r\n\r\n"):format(
                name,
                pair[2],
                name,
                pair[3]
            )
        )
        local r = res[1]
        ok(
            r ~= nil and r.status == 400 and r.body:find("More than one " .. name .. " header", 1, true) ~= nil,
            ("two %s lines are 400 naming %s (got %s)"):format(name, name, tostring(r and r.status))
        )
    end
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
        -- The OS port above is no hextet, so a parser that took an
        -- unbracketed literal still refused it; these two are literals.
        eq(status(port, "::1"), 400, bind .. ": an unbracketed IPv6 address with no port is 400")
        eq(status(port, "::1:80"), 400, bind .. ": an unbracketed ::1:80, a port that reads as a hextet, is 400")
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
    -- On a ::1 bind the unbracketed literal names the bound address itself.
    local probe = assert(vim.uv.new_tcp())
    local v6, v6_err = probe:bind("::1", 0)
    probe:close()
    if v6 then
        local six = serve({ host = "::1" })
        local function status6(value)
            local c = assert(H.raw_connect(six.port, "::1"))
            assert(c:send(("GET /style.css HTTP/1.1\r\nHost: %s\r\n\r\n"):format(value)))
            local data = c:read(3000)
            c:close()
            local r = H.responses(data or "")
            return r[1] and r[1].status
        end
        eq(status6("::1"), 400, "::1: an unbracketed IPv6 address with no port is 400")
        eq(status6("::1:80"), 400, "::1: an unbracketed ::1:80 is 400")
        eq(status6("[::1]:" .. six.port), 200, "::1: the bracketed form is served")
    else
        for _, row in ipairs({
            "::1: an unbracketed IPv6 address with no port is 400",
            "::1: an unbracketed ::1:80 is 400",
            "::1: the bracketed form is served",
        }) do
            H.skip(row .. " (no IPv6 loopback here: " .. tostring(v6_err) .. ")")
        end
    end
    -- The grammar's other accepted forms, on a network bind.
    local wide = serve({ host = "0.0.0.0" })
    eq(status(wide.port, "[::ffff:127.0.0.1]:" .. wide.port), 200, "an IPv6 address ending in an IPv4 one is served")
    eq(status(wide.port, "a%41.example"), 200, "a % followed by two hex digits is served")
    local inst = serve()
    local res = ask(inst.port, "GET http://user@127.0.0.1/style.css HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
    eq(res[1] and res[1].status, 400, "an absolute-form authority that is not a host is 400")
end)

H.case("Section 5: every status the server sends has its reason phrase", function()
    -- A status added to a response with no entry in the reason table would
    -- go out with an empty reason, which RFC 9112 allows; this row makes
    -- that omission a red run instead of a silent status line.
    local src = table.concat(vim.fn.readfile(H.root .. "/lua/kitehost/server.lua"), "\n")
    -- Only the table's own entries count, so a bracketed status elsewhere
    -- in the source cannot stand in for a missing reason.
    local block = assert(src:match("REASONS%s*=%s*(%b{})"), "the reason table was found in the source")
    local reasons = {}
    for code in block:gmatch('%[(%d%d%d)%] = "') do
        reasons[code] = true
    end
    ok(reasons["200"] and reasons["404"], "the reason table was read from the source")
    local missing, seen = {}, {}
    -- Any socket variable: a send through conn.sock is a send too.
    for code in src:gmatch("send_response%(%s*[%w_.]+,%s*(%d%d%d)") do
        seen[code] = true
        if not reasons[code] then
            table.insert(missing, code)
        end
    end
    for code in src:gmatch("write_headers%(%s*[%w_.]+,%s*(%d%d%d)") do
        seen[code] = true
        if not reasons[code] then
            table.insert(missing, code)
        end
    end
    ok(seen["401"] and seen["431"], "the status literals were read from the source")
    eq(#missing, 0, "every status literal the server sends has a reason entry: " .. table.concat(missing, ","))
    -- A status passed through a variable escapes the reads above, so every
    -- call passes a literal; the two definitions and send_response's own
    -- forward to write_headers are the exceptions.
    local forward = "write_headers(sock, status, h)"
    local _, forwards = src:gsub(vim.pesc(forward), "")
    eq(forwards, 1, "send_response's forward is the one send that passes a status through")
    local non_literal = {}
    for _, fn in ipairs({ "send_response", "write_headers" }) do
        -- The whole argument up to its comma or the closing paren, so an
        -- expression around a literal is read as the expression it is.
        for pos, token in src:gmatch("()" .. fn .. "%(%s*[%w_.]+,%s*([^,%)]-)%s*[,%)]") do
            local definition = src:sub(pos - 9, pos - 1) == "function "
            if not definition and src:sub(pos, pos + #forward - 1) ~= forward and not token:match("^%d%d%d$") then
                table.insert(non_literal, fn .. " " .. token)
            end
        end
    end
    eq(#non_literal, 0, "every status reaches a send as a three-digit literal: " .. table.concat(non_literal, ", "))
end)

-- The index a directory falls back to is resolved as a file request is:
-- inside the root by realpath, and a regular file. A directory named
-- index.html was taken for the index and answered with a 404 page naming
-- its path on disk (measured), where /sub/ lists sub/ or is a plain 404.
H.case("Section 6: a directory's index resolves inside the root", function()
    local uv = vim.uv
    local tree = H.tmpdir()
    vim.fn.mkdir(tree .. "/sub/index.html", "p")
    H.write_file(tree .. "/sub/index.html/page.txt", "page")
    local on_disk = assert(uv.fs_realpath(tree))
    local listed = serve({ root = tree, features = { dirlist = { enabled = true } } })
    local r = H.http_get(("http://127.0.0.1:%d/sub/"):format(listed.port))
    eq(r.status, 200, "/sub/ whose index.html is a directory is listed")
    ok(r.body:find('href="/sub/index.html/"', 1, true) ~= nil, "and the listing names index.html as a directory")
    r = H.http_get(("http://127.0.0.1:%d/sub/"):format(serve({ root = tree }).port))
    eq(r.status, 404, "with the listing off, /sub/ is 404")
    ok(not r.body:find(on_disk, 1, true), "and its page does not name the directory's path on disk")

    -- A linked index.html pointing out of the root is refused twice: by this
    -- resolution and by the gate's read of the name on disk. An index.htm
    -- beside it tells the two apart: the resolution passes over the link to
    -- the next name, while the gate alone answered 404 for the directory.
    local base = H.tmpdir()
    vim.fn.mkdir(base .. "/site/sub", "p")
    vim.fn.mkdir(base .. "/site/both", "p")
    vim.fn.mkdir(base .. "/outside", "p")
    H.write_file(base .. "/outside/secret.html", "<html><body>OUTSIDE</body></html>")
    H.write_file(base .. "/site/index.html", "<html><body>in</body></html>")
    H.write_file(base .. "/site/both/index.htm", "<html><body>beside the link</body></html>")
    local link = base .. "/site/sub/index.html"
    local outward = table.concat({ "..", "..", "outside", "secret.html" }, sep)
    local secret = base .. "/outside/secret.html"
    local linked, link_err = uv.fs_symlink(outward, link)
    local both = base .. "/site/both/index.html"
    local blinked, blink_err = uv.fs_symlink(outward, both)
    -- The first three rows read sub/'s link alone and the last both/'s,
    -- so a link that does not resolve skips its own rows alone.
    local link_why = unresolved(linked, link_err, link, secret)
    local both_why = unresolved(blinked, blink_err, both, secret)
    local inst = serve({ root = base .. "/site" })
    if link_why then
        local why = " (" .. link_why .. ")"
        H.skip("/sub/ whose index links outside the root is 404" .. why)
        H.skip("and its body is not the outside file" .. why)
        H.skip("the link asked for by name stays 404" .. why)
    else
        r = H.http_get(("http://127.0.0.1:%d/sub/"):format(inst.port))
        eq(r.status, 404, "/sub/ whose index links outside the root is 404")
        ok(not r.body:find("OUTSIDE", 1, true), "and its body is not the outside file")
        eq(
            H.http_get(("http://127.0.0.1:%d/sub/index.html"):format(inst.port)).status,
            404,
            "the link asked for by name stays 404"
        )
    end
    if both_why then
        H.skip("an index.htm beside an index.html linked out of the root is served (" .. both_why .. ")")
    else
        r = H.http_get(("http://127.0.0.1:%d/both/"):format(inst.port))
        ok(
            r.status == 200 and r.body:find("beside the link", 1, true) ~= nil,
            ("an index.htm beside an index.html linked out of the root is served (got %d)"):format(r.status)
        )
    end
end)

-- A listing's links are built from the path the server resolved, each
-- segment encoded. The request's own spelling carried its query into every
-- href, so a listing fetched with ?t= linked nowhere, and a raw target's
-- markup reached an href unescaped (measured).
H.case("Section 7: a listing's links come from the path, encoded", function()
    local tree = H.tmpdir()
    vim.fn.mkdir(tree .. "/sub", "p")
    H.write_file(tree .. "/sub/f.txt", "f")
    vim.fn.mkdir(tree .. "/a#b", "p")
    H.write_file(tree .. "/a#b/f.txt", "f")
    local inst = serve({ root = tree, token = "tok", features = { dirlist = { enabled = true } } })
    local port = inst.port
    local res = ask(port, get("/sub/?t=tok", port))
    local body = res[1] and res[1].body or ""
    ok(
        body:find('href="/"', 1, true) ~= nil
            and body:find('href="/sub/f.txt"', 1, true) ~= nil
            and not body:find('href="[^"]*%?'),
        "a listing fetched with ?t=tok links its parent and entries by the path alone"
    )
    res = ask(port, get("/a%23b/", port))
    body = res[1] and res[1].body or ""
    ok(body:find('href="/a%23b/f.txt"', 1, true) ~= nil, "a directory named a#b keeps its href encoded")
    -- The title showed the encoded path (Index of /docs%28old%29/): it is
    -- the path as read, while each href encodes its segments.
    vim.fn.mkdir(tree .. "/docs(old)", "p")
    H.write_file(tree .. "/docs(old)/f.txt", "f")
    res = ask(port, get("/docs%28old%29/", port))
    body = res[1] and res[1].body or ""
    ok(
        body:find("<title>Index of /docs(old)/</title>", 1, true) ~= nil,
        "a directory named docs(old) is titled as read"
    )
    ok(body:find('href="/docs%28old%29/f.txt"', 1, true) ~= nil, "and its entries link encoded")
    -- The title and heading are built from the decoded path, so the page's
    -- escape alone keeps a directory's name from reading as markup.
    local tag = "<img src=x onerror=alert(1)>"
    local made, mkdir_err = vim.uv.fs_mkdir(tree .. "/" .. tag, 493)
    local tag_row = "a directory named " .. tag .. " is titled escaped, never as a tag"
    if made then
        local enc = tag:gsub("[^%w]", function(ch)
            return ("%%%02X"):format(ch:byte())
        end)
        res = ask(port, get("/" .. enc .. "/", port))
        body = res[1] and res[1].body or ""
        ok(body:find("<title>Index of /&lt;img", 1, true) ~= nil and not body:find("<img", 1, true), tag_row)
    else
        H.skip(tag_row .. " (" .. tostring(mkdir_err) .. ")")
    end
    res = ask(port, get('/sub/?x="><b>X</b>', port))
    ok(
        res[1] ~= nil and res[1].status == 200 and not res[1].body:find("<b>X</b>", 1, true),
        ("a raw target's markup never reaches the listing (got %s)"):format(tostring(res[1] and res[1].status))
    )
end)

-- A raise inside the handler, where every request runs in a luv callback,
-- left the connection open with no answer until the client gave up, and
-- reached the editor as a callback error (measured). No real request
-- raises on demand, so the raises are forced through vim.uv, the table the
-- server reads, each for one request: fs_stat for the file asked for,
-- before any status line, and the transfer's first read, after its head.
-- The notice stub records whether it ran in a fast event, where the real
-- vim.notify raises (E5560).
H.case("Section 8: a raise inside the handler answers 500 and is reported", function()
    local uv = vim.uv
    local notes = {}
    local real_notify, real_stat, real_read = vim.notify, uv.fs_stat, uv.fs_read
    local inst = serve()
    local port = inst.port
    local methods = getmetatable(inst.handle).__index
    local real_close = methods.close
    H.defer(function()
        vim.notify, uv.fs_stat, uv.fs_read, methods.close = real_notify, real_stat, real_read, real_close
    end)
    vim.notify = function(msg, level)
        table.insert(notes, { msg = msg, level = level, fast = vim.in_fast_event() })
    end
    local seen = #H.errors()
    -- Whether notice n arrived within 1 s as an error naming cause, sent
    -- outside the fast event.
    local function reported(n, cause)
        local note = H.wait_for(function()
            return #notes >= n
        end, 1000) and notes[n]
        return note and note.level == vim.log.levels.ERROR and note.msg:find(cause, 1, true) ~= nil and not note.fast
    end

    local target = assert(uv.fs_realpath(root .. "/style.css"))
    local function stat_raises()
        uv.fs_stat = function(path, ...)
            if path == target then
                error("deliberate stat failure")
            end
            return real_stat(path, ...)
        end
    end
    stat_raises()
    local res, _, _, closed = ask(port, get("/style.css?t=secret", port))
    uv.fs_stat = real_stat
    eq(res[1] and res[1].status, 500, "a raise before any status line went out is answered 500")
    ok(closed, "and the connection ends")
    local body = res[1] and res[1].body or ""
    ok(
        body:find("Internal Server Error", 1, true) ~= nil
            and not body:find("deliberate", 1, true)
            and not body:find("style.css", 1, true)
            and not body:find("secret", 1, true),
        "its page names neither the cause nor the path"
    )
    ok(
        reported(1, "deliberate stat failure"),
        "the raise is reported as an error naming its cause, outside the fast event"
    )
    -- The path's query is cut: ?t=<token> rides there and :messages keeps
    -- what a notice says.
    ok(
        notes[1] ~= nil
            and not notes[1].msg:find("\n", 1, true)
            and notes[1].msg:find("/style.css failed: ", 1, true) ~= nil
            and not notes[1].msg:find("secret", 1, true),
        "on one line naming the path, never its query"
    )
    -- With two servers a line naming no port named neither.
    ok(
        notes[1] ~= nil and notes[1].msg:find(("kitehost: port %d /style.css failed: "):format(port), 1, true) == 1,
        "and the server's port: " .. tostring(notes[1] and notes[1].msg)
    )
    -- A peer on a network bind writes the path: an escape in it reaches
    -- whatever vim.notify was replaced with, so a control byte is a mark.
    stat_raises()
    local esc = ask(port, get("/\27]0;x\1/../style.css?t=secret", port))
    uv.fs_stat = real_stat
    eq(esc[1] and esc[1].status, 500, "a raise on a path holding control bytes is answered 500")
    ok(reported(2, "deliberate stat failure"), "and reported as an error naming its cause, outside the fast event")
    ok(
        notes[2] ~= nil and not notes[2].msg:find("[%c]") and notes[2].msg:find("failed: ", 1, true) ~= nil,
        "on a line with no control byte in it"
    )

    -- stream_file's first read raises on the handler's stack, after its
    -- head went out: a 500 then would land inside the 200's body, so the
    -- connection is closed instead. The transfer closes the file it opened
    -- and the handler's boundary the socket. The descriptor baseline is read
    -- once it holds still for ten samples: the first request's socket
    -- closes a loop turn after its client's.
    local fds, same = H.fd_count(), 0
    local held = fds ~= nil
        and H.wait_for(function()
            local now = H.fd_count()
            same = now == fds and same + 1 or 0
            fds = now
            return same >= 10
        end, 2000)
    uv.fs_read = function(fd, size, offset, cb)
        if type(cb) == "function" then
            error("deliberate read failure")
        end
        return real_read(fd, size, offset, cb)
    end
    local c = assert(H.raw_connect(port))
    assert(c:send(get("/hello.txt", port)))
    local data, eof = c:read(3000)
    uv.fs_read = real_read
    c:close()
    ok(eof, "a raise after the status line went out ends the connection")
    local _, lines = data:gsub("HTTP/1%.1 %d%d%d ", "")
    ok(
        data:find("^HTTP/1%.1 200 ") ~= nil and lines == 1,
        ("with the one status line that went out, no 500 after it (%d status lines)"):format(lines)
    )
    ok(
        reported(3, "deliberate read failure"),
        "the late raise is reported as an error naming its cause, outside the fast event"
    )
    ok(
        notes[3] ~= nil
            and not notes[3].msg:find("\n", 1, true)
            and notes[3].msg:find("/hello.txt failed: ", 1, true) ~= nil,
        "on one line naming the path"
    )
    vim.wait(100)
    eq(#notes, 3, "each raise is reported once")
    eq(#H.errors(), seen, "and neither reaches the editor as an error of its own")
    -- A control: the client's close reaches the server's read path, which
    -- closes the socket too, so the count comes back with the boundary or
    -- without it; it holds that the two closes give back both.
    if fds then
        ok(
            held and H.wait_for(function()
                return H.fd_count() == fds
            end, 2000),
            ("the file and the socket are given back: %d descriptors, %s (now %s)"):format(
                fds,
                held and "a baseline that held" or "a baseline that never held",
                tostring(H.fd_count())
            )
        )
    else
        H.skip("the file and the socket are given back (no descriptor listing on this platform)")
    end

    -- A peer controls the path up to the head's cap; every ./ segment
    -- still reaches the file, so the notice would carry all of them.
    stat_raises()
    ask(port, get("/" .. ("./"):rep(200) .. "style.css", port))
    uv.fs_stat = real_stat
    local shown = reported(4, "deliberate stat failure") and notes[4].msg:match("^kitehost: port %d+ (.-) failed: ")
    eq(shown and #shown, 200, "a 410-byte path is cut to 200 bytes in the notice")

    -- The notice goes out before the connection is answered or closed, so
    -- a raise there cannot swallow it: the first tcp close after the read
    -- raises is the boundary's, which the stub makes raise once its close
    -- is done.
    uv.fs_read = function(fd, size, offset, cb)
        if type(cb) == "function" then
            methods.close = function(h, ...)
                methods.close = real_close
                real_close(h, ...)
                error("deliberate close failure")
            end
            error("deliberate read failure")
        end
        return real_read(fd, size, offset, cb)
    end
    local escaped = H.expect_error("deliberate close failure", function()
        local rc = assert(H.raw_connect(port))
        assert(rc:send(get("/hello.txt", port)))
        rc:read(3000)
        rc:close()
    end)
    uv.fs_read, methods.close = real_read, real_close
    ok(escaped, "a raise while the boundary closes the connection reaches the editor")
    ok(reported(5, "deliberate read failure"), "and the handler's raise before it is still reported")

    -- %c marks 0 to 31 and 127 alone, so a raw 0x9B, a C1 CSI a terminal
    -- may act on, reached the notice, and so did U+009B encoded; the cut
    -- could split a letter. Each such byte or sequence is one mark, and
    -- the cut falls between letters.
    local function notice_for(n, path)
        stat_raises()
        ask(port, get(path, port))
        uv.fs_stat = real_stat
        return reported(n, "deliberate stat failure") and notes[n].msg:match("^kitehost: port %d+ (.-) failed: ") or ""
    end
    eq(notice_for(6, "/a\155b/../style.css"), "/a?b/../style.css", "a raw 0x9B in the path is one mark")
    eq(notice_for(7, "/a\194\155b/../style.css"), "/a?b/../style.css", "and U+009B encoded is one mark")
    eq(
        notice_for(8, "/a\255\194b/../style.css"),
        "/a??b/../style.css",
        "and each byte of a sequence no UTF-8 reader accepts is one mark"
    )
    eq(notice_for(9, "/a\195\169b/../style.css"), "/a\195\169b/../style.css", "a letter past ASCII is kept")
    local long = "/" .. ("./"):rep(99)
    eq(notice_for(10, long .. "\195\169/../style.css"), long, "a letter the 200-byte cut would split is left out whole")

    res = ask(port, get("/style.css", port))
    eq(res[1] and res[1].status, 200, "and the server answers the next request")
end)

-- The gate matches every protected_paths pattern against the request's
-- path on the loop, and a well-formed pattern backtracks: /.*%.md$ held
-- the editor 4.7 s on a 16 KiB path of a/a/... (measured). A target over
-- 8 KiB is refused before the Host check, the gate or any pattern reads
-- it; the 64 KiB head cap stays for the whole head.
H.case("Section 9: a target over 8 KiB is 414 before any check reads it", function()
    local pattern = "^/.*%.md$"
    local inst = serve({ token = "tok", protected_paths = { pattern } })
    local port = inst.port
    -- Each match of the pattern is counted, so a 414 is shown to run none.
    local real_find, runs = string.find, 0
    H.defer(function()
        string.find = real_find
    end)
    string.find = function(s, pat, ...)
        if pat == pattern then
            runs = runs + 1
        end
        return real_find(s, pat, ...)
    end
    local function target(size)
        return "/" .. ("a"):rep(size - 1)
    end
    runs = 0
    local res = ask(port, get(target(8 * 1024), port))
    eq(res[1] and res[1].status, 404, "a target of 8 KiB is read and answered")
    ok(runs > 0, ("and the gate matched its pattern against it (%d runs)"):format(runs))
    runs = 0
    local closed
    res, _, _, closed = ask(port, get(target(8 * 1024 + 1), port))
    eq(res[1] and res[1].status, 414, "a target one byte over 8 KiB is 414")
    eq(res[1] and res[1].reason, "URI Too Long", "with its reason phrase")
    eq(closed, true, "a 414 closes the connection")
    eq(runs, 0, "and no pattern was matched against it")
    local absolute = ("GET http://127.0.0.1:%d%s HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"):format(port, target(9 * 1024))
    res = ask(port, absolute)
    eq(res[1] and res[1].status, 414, "a 9 KiB target in absolute form is 414")
    res = ask(port, ("GET %s HTTP/1.1\r\nHost: evil.test\r\n\r\n"):format(target(9 * 1024)))
    eq(res[1] and res[1].status, 414, "a 9 KiB target under a Host the check refuses is 414, never 421")
    res = ask(port, ("GET %s HTTP/1.1\r\n\r\n"):format(target(9 * 1024)))
    eq(res[1] and res[1].status, 414, "and one with no Host is 414, never 400")
    eq(runs, 0, "and none of them reached a pattern")
    -- The 414 comes once the head has arrived, the order the README
    -- promises: a target over the cap and a header line with no blank
    -- line after them get no byte, and the blank line brings the 414.
    local c = assert(H.raw_connect(port))
    assert(c:send(("GET %s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n"):format(target(9 * 1024), port)))
    eq(c:read(300), "", "a 9 KiB target whose head has not ended gets no byte")
    assert(c:send("\r\n"))
    res = H.responses((c:read(3000)))
    eq(res[1] and res[1].status, 414, "and the head's blank line brings the 414")
    -- The cap counts the whole target, the query too: a short path whose
    -- query takes it past 8 KiB is refused, and at 8 KiB the query is
    -- read and the path matched.
    local queried = "/a.md?" .. ("q"):rep(8 * 1024 - 6)
    eq(#queried, 8 * 1024, "the queried target is 8 KiB")
    runs = 0
    res = ask(port, get(queried, port))
    eq(res[1] and res[1].status, 401, "a target of 8 KiB with a query is read and its path gated")
    eq(runs, 1, "and the gate matched its pattern once")
    runs = 0
    res = ask(port, get(queried .. "q", port))
    eq(res[1] and res[1].status, 414, "a short path whose query takes the target past 8 KiB is 414")
    eq(runs, 0, "and no pattern was matched against it")
    string.find = real_find
    -- The cost the start rules leave, measured on this machine, not a
    -- promise. Anchored, this pattern costs 0.1 ms on the longest path the
    -- cap lets through; unanchored, which start refuses, it cost 300 to
    -- 535 ms. A costly shape the caps take, one wildcard and two ? items
    -- before a literal tail filling the pattern's 256 bytes, tries 2^2
    -- ways at every split of 8 KiB, each as long as the tail: about 50 ms
    -- of CPU time on either binary, a reading moving with the machine's
    -- load (33 to 59 ms measured); the costliest shape found, two ? items
    -- before 32 nested captures and a literal tail filling the 256 bytes,
    -- at most about 105 ms, the README's figure. Its calls are timed by
    -- os.clock, so the row reads their work and not the machine's load
    -- beside it.
    local costly = "^/.*" .. ("a?"):rep(2) .. ("a"):rep(247) .. "b"
    local worst = serve({ token = "tok", protected_paths = { costly } })
    local spent, calls = 0, 0
    string.find = function(s, pat, ...)
        if pat ~= costly then
            return real_find(s, pat, ...)
        end
        calls = calls + 1
        local c0 = os.clock()
        local first, last = real_find(s, pat, ...)
        spent = spent + os.clock() - c0
        return first, last
    end
    local a_path = "/" .. ("a"):rep(8 * 1024 - 1)
    -- Asked through curl, another process, so the client's own work is
    -- no part of the loop's.
    local got = H.http_get(("http://127.0.0.1:%d%s"):format(worst.port, a_path))
    string.find = real_find
    eq(got.status, 404, "an 8 KiB path of a's is answered under a costly shape the caps take")
    eq(calls, 1, "which the gate matched once")
    -- LuaJIT's os.clock is C's clock(), which the Windows C runtime counts
    -- as wall time since the process began, so there it reads the load
    -- beside the work and the bound is skipped.
    local cpu = ("and the pattern held the loop under 1 s of CPU time (%d ms)"):format(spent * 1000)
    if vim.fn.has("win32") == 1 then
        H.skip(cpu .. " (os.clock reads wall time on Windows)")
    else
        ok(spent > 0 and spent < 1, cpu)
    end
end)

H.finish()
