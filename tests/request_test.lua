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

-- One request on its own connection: the parsed responses and the bytes.
local function ask(port, bytes)
    local data = H.raw_request(port, bytes) or ""
    return H.responses(data), data
end

local function get(path, port, extra)
    return ("GET %s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n%s\r\n"):format(path, port, extra or "")
end

H.case("Section 1: the behaviour the pipeline refactor keeps", function()
    local inst = serve({ token = "tok", protected_paths = { "^/content%.md$" } })
    local port = inst.port
    local res = ask(port, get("/style.css", port))
    eq(#res, 1, "one request, one response")
    eq(res[1] and res[1].status, 200, "a request in one write is served")
    eq(res[1] and res[1].body, "body{color:red}", "the body is the file")
    eq(res[1] and res[1].headers.connection, "close", "a file response closes the connection")
    res = ask(port, "GET /index.html HTTP/1.0\n\n")
    eq(res[1] and res[1].status, 200, "a head ended by bare LF lines is served")
    res = ask(port, get("/content.md", port))
    eq(res[1] and res[1].status, 401, "a protected path without the token is 401")
    res = ask(port, get("/content.md?t=tok", port))
    eq(res[1] and res[1].status, 200, "the token opens it")
    res = ask(port, ("POST / HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n\r\n"):format(port))
    eq(res[1] and res[1].status, 405, "a method other than GET is 405")
    res = ask(port, "get / HTTP/1.1\r\n\r\n")
    eq(res[1] and res[1].status, 400, "a lowercase method is 400")
    res = ask(port, "\r\n\r\n")
    eq(res[1] and res[1].status, 400, "an empty head is 400")

    -- Buffering must keep SSE disconnect detection: the stream leaves the
    -- client list only when its socket reports the end.
    local c = assert(H.raw_connect(port))
    c:send(get("/__live/events?t=tok", port))
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
    c:send("GET /whatever HTTP/1.1\r\n\r\n")
    local after = c:read(300)
    ok(not after:find("HTTP/1.1 400", 1, true), "a later chunk on the stream gets no response")
    c:close()
    ok(
        H.wait_for(function()
            return server.connected_client_count(inst) == 0
        end, 2000),
        "a closed stream leaves the client list"
    )
end)

H.finish()
