-- tests/contract_test.lua
-- The calls the two known consumers make, held as rows: markdown-preview's
-- start, its raw-TCP inject and its page's stream, and gh-markdown-preview's
-- tokenless server, its back channel, its page's hello and its read of
-- inst.sse_clients. A change that breaks one of them reds here first.
--
-- Run: nvim --headless -u NONE -l "$PWD/tests/contract_test.lua"

local H = dofile(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "helpers.lua"))
H.isolate()
H.rtp()

local server = require("live_server.server")
local util = require("live_server.util")
local eq, ok = H.eq, H.ok

local work = H.tmpdir()
vim.fn.mkdir(work .. "/ws", "p")
vim.fn.mkdir(work .. "/ws2", "p")
vim.fn.mkdir(work .. "/doc/sub", "p")
H.write_file(work .. "/ws/index.html", "<html><body>INDEX-ONE</body></html>")
H.write_file(work .. "/ws/content.md", "# body text")
H.write_file(work .. "/ws2/index.html", "<html><body>INDEX-TWO</body></html>")
H.write_file(work .. "/doc/pic.png", "PNGDATA")
H.write_file(work .. "/doc/sub/pic.png", "PNGSUB")

-- Opens an event stream as a page or a back channel does and reads its
-- preamble; the client stays open for the rows that follow.
local function open_stream(port, target, extra)
    local c = assert(H.raw_connect(port))
    assert(c:send(("GET %s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n%s\r\n"):format(target, port, extra or "")))
    local head = c:read(2000, function(d)
        return d:find("retry: 1000\n\n", 1, true) ~= nil
    end)
    return c, H.response(head)
end

-- The data of the first complete frame named event on stream c, or nil.
-- A frame is complete at its blank line, where EventSource dispatches it.
-- The read starts past the last frame this function matched on c, so a
-- frame an earlier row already took can never satisfy a later one.
local function frame(c, event)
    local want = "event: " .. vim.pesc(event) .. "\ndata: ([^\n]*)\n\n"
    local from = (c.cursor or 0) + 1
    local data = c:read(2000, function(d)
        return d:find(want, from) ~= nil
    end)
    local _, last, payload = data:find(want, from)
    if last then
        c.cursor = last
    end
    return payload
end

H.case("Section 1: markdown-preview's server, page and raw sender", function()
    local token = util.random_token(16)
    local inst = server.start({
        port = 0,
        host = "127.0.0.1",
        root = work .. "/ws",
        default_index = work .. "/ws/index.html",
        headers = { ["Cache-Control"] = "no-cache" },
        live = { enabled = true, inject_script = false, debounce = 100 },
        features = { dirlist = { enabled = false } },
        token = token,
        protected_paths = { "^/content%.md$", "^/asset_root$" },
        asset_root = function()
            return work .. "/doc"
        end,
    })
    H.defer(function()
        server.stop(inst)
    end)
    local port = inst.port
    ok(type(port) == "number" and port > 0, "start with markdown-preview's options reports the bound port")
    ok(
        server.features and server.features.asset_route == true,
        "features.asset_route is declared, which markdown-preview reads before every start"
    )
    local base = ("http://127.0.0.1:%d"):format(port)
    local r = H.http_get(base .. "/")
    eq(r.status, 200, "the loopback index is served without the token")
    ok(r.body:find("INDEX-ONE", 1, true) ~= nil, "and it is the default_index")
    -- browser_url opens the index with the token in the query.
    eq(H.http_get(base .. "/?t=" .. token).status, 200, "the index with the token in the query is served")
    eq(
        H.response(H.raw_request(port, ("GET / HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n\r\n"):format(port))).headers["cache-control"],
        "no-cache",
        "the caller's headers ride every response"
    )
    -- lock.is_server_alive's probe: a connect and a close, no byte sent.
    local probe = assert(H.raw_connect(port))
    probe:close()
    eq(H.http_get(base .. "/").status, 200, "a zero-byte connect and close leaves the server answering")
    eq(H.http_get(base .. "/content.md").status, 401, "content.md without the token is 401")
    eq(
        H.http_get(("%s/content.md?ts=%d&t=%s"):format(base, os.time() * 1000, token)).body,
        "# body text",
        "content.md with the token is served"
    )
    eq(
        H.http_get(base .. "/__live/asset?p=pic.png&t=" .. token).body,
        "PNGDATA",
        "an image beside the document is served"
    )
    -- The pages send the image's path through encodeURIComponent.
    eq(
        H.http_get(base .. "/__live/asset?p=sub%2Fpic.png&t=" .. token).body,
        "PNGSUB",
        "an encoded slash in the asset path is decoded"
    )
    local c, head = open_stream(
        port,
        "/__live/events?t=" .. token,
        "Sec-Fetch-Site: same-origin\r\n"
            .. "Sec-Fetch-Mode: cors\r\n"
            .. "Sec-Fetch-Dest: empty\r\n"
            .. "Accept: text/event-stream\r\n"
            .. "Cache-Control: no-cache\r\n"
    )
    eq(head.headers["content-type"], "text/event-stream", "the page's stream opens with the token")
    ok(
        H.wait_for(function()
            return server.connected_client_count(inst) == 1
        end, 2000),
        "connected_client_count counts it"
    )
    -- remote.lua's request, built as it builds it: raw TCP, a portless Host,
    -- no browser headers, the token in the query.
    local query = ("event=%s&data=%s"):format("scroll", vim.uri_encode('{"line":42,"total":100}'))
    query = query .. "&t=" .. vim.uri_encode(token)
    local raw = ("GET /__live/inject?%s HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"):format(query)
    local rc = assert(H.raw_connect(port))
    ok(rc:send(raw) == true, "remote.lua's inject is written as it writes it")
    -- remote.lua shuts down and closes in its write callback and never reads,
    -- so the server's answer often meets a peer that is already gone.
    assert(rc.tcp:shutdown())
    rc:close()
    eq(frame(c, "scroll"), '{"line":42,"total":100}', "and its event reaches the page")
    server.send_event(inst, "scroll", vim.json.encode({ line = 7 }))
    eq(frame(c, "scroll"), '{"line":7}', "send_event reaches the page")
    server.reload(inst, "content.md")
    local decoded, obj = pcall(vim.json.decode, frame(c, "reload") or "")
    eq(decoded and obj.path, "content.md", "reload sends JSON naming the path")
    -- A takeover secondary writes content.md and never calls reload: the
    -- watcher is what tells the page.
    H.write_file(work .. "/ws/content.md", "# body text changed")
    local decoded2, obj2 = pcall(vim.json.decode, frame(c, "reload") or "")
    eq(decoded2 and obj2.path, "content.md", "an edit under the root reaches the page through the watcher")
    server.update_target(inst, work .. "/ws2", work .. "/ws2/index.html")
    ok(H.http_get(base .. "/").body:find("INDEX-TWO", 1, true) ~= nil, "update_target serves the new index")
    server.stop(inst)
    local late, late_err = H.raw_connect(port)
    ok(
        late == nil and type(late_err) == "string" and late_err:find("ECONNREFUSED", 1, true) ~= nil,
        "stop closes the port: " .. tostring(late_err)
    )
end)

H.case("Section 2: gh-markdown-preview's tokenless server, back channel and page", function()
    local inst = server.start({
        port = 0,
        host = "127.0.0.1",
        root = work .. "/ws",
        headers = { ["Cache-Control"] = "no-cache" },
        live = { enabled = false, inject_script = false },
        features = { dirlist = { enabled = false } },
        asset_root = function()
            return work .. "/doc"
        end,
    })
    H.defer(function()
        server.stop(inst)
    end)
    local port = inst.port
    local base = ("http://127.0.0.1:%d"):format(port)
    -- The back channel: a raw GET of the stream with Host <host>:<port> and
    -- no token, read for as long as the preview lives.
    local back, head = open_stream(port, "/__live/events", "Accept: text/event-stream\r\nConnection: keep-alive\r\n")
    eq(head.headers["content-type"], "text/event-stream", "the back channel opens without a token")
    -- The page's hello: a same-origin fetch with no data and no token.
    local hello_bytes, hello_err = H.raw_request(
        port,
        (
            "GET /__live/inject?event=hello HTTP/1.1\r\n"
            .. "Host: 127.0.0.1:%d\r\n"
            .. "Sec-Fetch-Site: same-origin\r\n"
            .. "Sec-Fetch-Mode: cors\r\n"
            .. "Sec-Fetch-Dest: empty\r\n"
            .. "\r\n"
        ):format(port)
    )
    assert(hello_bytes, hello_err)
    local hello = H.response(hello_bytes)
    eq(hello.status, 200, "the page's tokenless hello is answered 200")
    eq(frame(back, "hello"), "{}", "and reaches the back channel with data {}")
    eq(
        H.http_get(base .. "/__live/inject?event=hello").status,
        200,
        "curl's hello, with no browser headers, is answered 200"
    )
    eq(frame(back, "hello"), "{}", "curl's hello reaches the back channel too")
    eq(H.http_get(base .. "/__live/asset?p=pic.png").body, "PNGDATA", "an image is served without a token")
    ok(
        type(inst.sse_clients) == "table" and #inst.sse_clients == 1 and server.connected_client_count(inst) == 1,
        "inst.sse_clients lists the one open stream"
    )
    server.reload(inst, "render.html")
    local decoded, obj = pcall(vim.json.decode, frame(back, "reload") or "")
    eq(decoded and obj.path, "render.html", "reload broadcasts with live reload off")
    server.send_event(inst, "close", "{}")
    eq(frame(back, "close"), "{}", "send_event's close reaches the back channel")
end)

H.finish()
