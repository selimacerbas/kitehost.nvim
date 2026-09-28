-- tests/lifecycle_test.lua
-- What the server holds while it runs and how it lets go of it: a socket
-- is closed once, whoever ends the connection first, and a response whose
-- shutdown cannot start closes its socket at once. A raise inside a luv
-- callback, where every handler runs, leaves the exit code at 0, so the
-- rows read the ledger's error capture (H.errors) and count the handles
-- directly. hello.txt and big.bin (its bytes in big) are the small and the
-- 2 MiB file the transfer rows serve, and serve's cfg and get's extra are
-- what those rows pass.
--
-- Run: nvim --headless -u NONE -l "$PWD/tests/lifecycle_test.lua"

local H = dofile(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "helpers.lua"))
H.isolate()
H.rtp()

local server = require("live_server.server")
local eq, ok = H.eq, H.ok

local root = H.tmpdir()
H.write_file(root .. "/index.html", "<html><body>hi</body></html>")
H.write_file(root .. "/hello.txt", "hello")
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

local function get(path, port, extra)
    return ("GET %s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n%s\r\n"):format(path, port, extra or "")
end

-- The first line of each error message reported after the first seen.
local function errors_since(seen)
    local lines = {}
    for _, e in ipairs(vim.list_slice(H.errors(), seen + 1)) do
        table.insert(lines, (e:gsub("\nstack traceback:.*", ""):gsub("\n", " ")))
    end
    return lines
end

-- A client that stopped reading and then ended its side while a page was
-- still being written had its socket closed by the read path; libuv then
-- ran the pending shutdown's callback, whose second close raised "handle
-- is already closing" inside a luv callback: an error in the editor for
-- any client that asks (30 of 30 connections on 0.12.5 and 0.10.0). The
-- page is 16 MiB, past what the socket buffers of both ends take (1.6 MiB
-- at most on macOS, measured), so the write is still pending at the end.
H.case("Section 1: a peer that ends its side during a response is closed once", function()
    H.write_file(root .. "/large.html", "<html><body>" .. string.rep("p", 16 * 1024 * 1024) .. "</body></html>")
    local inst = serve()
    local port = inst.port
    -- The count is a baseline for this case alone, so any socket a case
    -- before this one left closing settles first.
    local settled = H.handle_count("tcp")
    H.wait_for(function()
        local now = H.handle_count("tcp")
        if now == settled then
            return true
        end
        settled = now
        return false
    end, 500)
    local sockets = settled
    local seen = #H.errors()
    for _ = 1, 3 do
        local c = assert(H.raw_connect(port))
        assert(c.tcp:read_stop())
        assert(c:send(get("/large.html", port)))
        assert(c:half_close())
        -- The server reads the end before this client closes: a close with
        -- the page unread sends a reset, which ends the write instead.
        assert(
            H.wait_for(function()
                return H.handle_count("tcp") <= sockets + 1
            end, 1000),
            "the server read the half-close within 1 s"
        )
        c:close()
    end
    local raised = errors_since(seen)
    ok(
        #raised == 0,
        "3 clients that stop reading a 16 MiB page and half-close raise nothing"
            .. (#raised > 0 and (": " .. table.concat(raised, " | ")) or "")
    )
    ok(
        H.wait_for(function()
            return H.handle_count("tcp") == sockets
        end, 3000),
        "and each connection is closed"
    )
end)

-- shutdown returns nil, err (ENOTCONN) on a socket that cannot shut and
-- never calls back, so a response that waited for its callback left the
-- socket open for good. The server makes the accepted socket itself and
-- accept takes no stand-in, so the row stubs shutdown in the method table
-- every tcp handle shares, and restores it before it rules.
H.case("Section 2: a response whose shutdown cannot start closes its socket at once", function()
    local inst = serve()
    local port = inst.port
    local sockets = H.handle_count("tcp")
    local c = assert(H.raw_connect(port))
    local methods = getmetatable(c.tcp).__index
    local real_shutdown = methods.shutdown
    H.defer(function()
        methods.shutdown = real_shutdown
    end)
    methods.shutdown = function()
        return nil, "ENOTCONN: stubbed", "ENOTCONN"
    end
    assert(c:send(get("/index.html", port)))
    local data, eof = c:read(3000)
    methods.shutdown = real_shutdown
    local res = H.responses(data)[1]
    eq(res and res.status, 200, "a page whose shutdown returns nil is answered")
    ok(eof, "and its socket closes at once, with no callback to wait for")
    -- Counted while the client stays open: the client's own end would have
    -- the read path close the server's socket anyway.
    ok(
        H.wait_for(function()
            return H.handle_count("tcp") == sockets + 1
        end, 3000),
        "and the server holds no socket for it"
    )
    c:close()
end)

H.finish()
