-- tests/contract_test.lua
-- The calls the two known consumers make, held as rows: markdown-preview's
-- start, its raw-TCP inject and its page's stream, and gh-markdown-preview's
-- tokenless server, its back channel, its page's hello and its read of
-- inst.sse_clients. A change that breaks one of them reds here first.
--
-- Run: nvim --headless -u NONE -l tests/contract_test.lua

local H = dofile(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "helpers.lua"))
H.isolate()
H.rtp()

local server = require("live_server.server")
local util = require("live_server.util")
local eq, ok = H.eq, H.ok

local work = H.tmpdir()
vim.fn.mkdir(work .. "/ws", "p")
vim.fn.mkdir(work .. "/ws2", "p")
vim.fn.mkdir(work .. "/doc", "p")
H.write_file(work .. "/ws/index.html", "<html><body>INDEX-ONE</body></html>")
H.write_file(work .. "/ws/content.md", "# body text")
H.write_file(work .. "/ws2/index.html", "<html><body>INDEX-TWO</body></html>")
H.write_file(work .. "/doc/pic.png", "PNGDATA")

-- Opens an event stream as a page or a back channel does and reads its
-- preamble; the client stays open for the rows that follow.
local function open_stream(port, target, extra)
    local c = assert(H.raw_connect(port))
    c:send(("GET %s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n%s\r\n"):format(target, port, extra or ""))
    local head = c:read(2000, function(d)
        return d:find("retry: 1000\n\n", 1, true) ~= nil
    end)
    return c, H.responses(head)[1] or { headers = {} }
end

-- The data of the first complete frame named event on stream c, or nil.
-- A frame is complete at its blank line, where EventSource dispatches it.
local function frame(c, event)
    local want = "event: " .. event .. "\ndata: ([^\n]*)\n\n"
    local data = c:read(2000, function(d)
        return d:match(want) ~= nil
    end)
    return data:match(want)
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
    local base = ("http://127.0.0.1:%d"):format(port)
    local r = H.http_get(base .. "/")
    eq(r.status, 200, "the loopback index is served without the token")
    ok(r.body:find("INDEX-ONE", 1, true) ~= nil, "and it is the default_index")
    eq(H.http_get(base .. "/content.md").status, 401, "content.md without the token is 401")
    eq(H.http_get(base .. "/content.md?t=" .. token).body, "# body text", "content.md with the token is served")
    eq(
        H.http_get(base .. "/__live/asset?p=pic.png&t=" .. token).body,
        "PNGDATA",
        "an image beside the document is served"
    )
    local c, head = open_stream(port, "/__live/events?t=" .. token, "Sec-Fetch-Site: same-origin\r\n")
    eq(head.headers["content-type"], "text/event-stream", "the page's stream opens with the token")
    ok(
        H.wait_for(function()
            return server.connected_client_count(inst) == 1
        end, 2000),
        "connected_client_count counts it"
    )
    -- remote.lua's request, built as it builds it: raw TCP, a portless Host,
    -- no browser headers, the token in the query.
    local query = ("event=%s&data=%s"):format("scroll", vim.uri_encode('{"line":42}'))
    query = query .. "&t=" .. vim.uri_encode(token)
    local raw = ("GET /__live/inject?%s HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"):format(query)
    local res = H.responses(H.raw_request(port, raw) or "")[1]
    eq(res and res.status, 200, "remote.lua's inject is answered 200")
    eq(frame(c, "scroll"), '{"line":42}', "and its event reaches the page")
    server.send_event(inst, "scroll2", vim.json.encode({ line = 7 }))
    eq(frame(c, "scroll2"), '{"line":7}', "send_event reaches the page")
    server.reload(inst, "content.md")
    local decoded, obj = pcall(vim.json.decode, frame(c, "reload") or "")
    eq(decoded and obj.path, "content.md", "reload sends JSON naming the path")
    server.update_target(inst, work .. "/ws2", work .. "/ws2/index.html")
    ok(H.http_get(base .. "/").body:find("INDEX-TWO", 1, true) ~= nil, "update_target serves the new index")
    server.stop(inst)
    ok(H.raw_connect(port) == nil, "stop closes the port")
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
    local back, head = open_stream(port, "/__live/events")
    eq(head.headers["content-type"], "text/event-stream", "the back channel opens without a token")
    -- The page's hello: a same-origin fetch with no data and no token.
    local hello = H.responses(
        H.raw_request(
            port,
            ("GET /__live/inject?event=hello HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nSec-Fetch-Site: same-origin\r\nSec-Fetch-Mode: cors\r\nSec-Fetch-Dest: empty\r\n\r\n"):format(
                port
            )
        ) or ""
    )[1]
    eq(hello and hello.status, 200, "the page's tokenless hello is answered 200")
    eq(frame(back, "hello"), "{}", "and reaches the back channel with data {}")
    eq(
        H.http_get(base .. "/__live/inject?event=hello2").status,
        200,
        "curl's hello, with no browser headers, is answered 200"
    )
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
