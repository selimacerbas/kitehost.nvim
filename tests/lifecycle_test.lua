-- tests/lifecycle_test.lua
-- What the server holds while it runs and how it lets go of it: a socket
-- is closed once, whoever ends the connection first, a response whose
-- shutdown cannot start closes its socket at once, and a file transfer
-- closes its file once, however it ends. A raise inside a luv callback,
-- where every handler runs, leaves the exit code at 0, so the rows read
-- the ledger's error capture (H.errors) and count the handles and the
-- descriptors directly. hello.txt and big.bin (its bytes in big) are the
-- small and the 2 MiB file the transfer rows serve, and serve's cfg and
-- get's extra are what those rows pass.
--
-- Run: nvim --headless -u NONE -l "$PWD/tests/lifecycle_test.lua"

local H = dofile(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "helpers.lua"))
H.isolate()
H.rtp()

local server = require("live_server.server")
local eq, ok = H.eq, H.ok
local uv = vim.uv

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

-- Samples sample() until it gives one value ten times in a row, within
-- ms: whether it did, and the value. A peer's end reaches the server a
-- loop turn after the client's close, and a transfer's next read a turn
-- after its write, so a count is read once it holds still.
local function steady(sample, ms)
    local n, same = sample(), 0
    local held = H.wait_for(function()
        local now = sample()
        same = now == n and same + 1 or 0
        n = now
        return same >= 10
    end, ms)
    return held, n
end

-- A download its client abandoned left the file open: the write into the
-- gone socket failed, by its return (EBADF) or its callback (ECANCELED),
-- nothing read either, and the loop stopped there. Each abandoned download
-- held one descriptor until the editor quit and stop gave none back
-- (measured), so any client that can reach the port could run the editor
-- out of descriptors. The shapes: a client that reads the first chunk and
-- resets, which mostly lands while the server reads the file (the write's
-- return), and one that stops reading a 16 MiB file, past what both ends'
-- socket buffers take, and once the server's write waits on it resets,
-- or half-closes and closes (the write's callback).
H.case("Section 3: an aborted download leaks no descriptor", function()
    local rows = {
        "the descriptor count returns to its baseline after 3 aborted downloads",
        "3 downloads that stop reading a 16 MiB file and reset give their descriptors back",
        "and 3 that stop reading it, half-close and close",
    }
    if not H.fd_count() then
        for _, row in ipairs(rows) do
            H.skip(row .. " (no descriptor listing on this platform)")
        end
        return
    end
    H.write_file(root .. "/large.bin", string.rep("b", 16 * 1024 * 1024))
    local inst = serve()
    local port = inst.port
    -- The reads the transfers have started: a transfer whose count holds
    -- still waits on a write its client does not take.
    local reads = 0
    local real_read = uv.fs_read
    H.defer(function()
        uv.fs_read = real_read
    end)
    uv.fs_read = function(...)
        reads = reads + 1
        return real_read(...)
    end
    -- Whether the count is back at n within 3 s.
    local function back(n)
        return H.wait_for(function()
            return H.fd_count() == n
        end, 3000)
    end
    local _, fds = steady(H.fd_count, 1000)
    for _ = 1, 3 do
        local c = assert(H.raw_connect(port))
        assert(c:send(get("/big.bin", port)))
        c:read(3000, function(d)
            return #d >= 65536
        end)
        assert(c:abort())
    end
    ok(back(fds), ("%s: %d (now %d)"):format(rows[1], fds, H.fd_count()))
    -- Each client in turn, against the count before it, so a descriptor an
    -- earlier one kept never fails a later one: the count says when its
    -- transfer has begun (the file open beside the two sockets) and whether
    -- it gave them all back.
    local function abandon(ends)
        local given = 0
        for _ = 1, 3 do
            local _, before = steady(H.fd_count, 1000)
            local c = assert(H.raw_connect(port))
            assert(c.tcp:read_stop())
            assert(c:send(get("/large.bin", port)))
            assert(
                H.wait_for(function()
                    return H.fd_count() >= before + 3
                end, 1000),
                "the transfer opened its file within 1 s"
            )
            assert(
                steady(function()
                    return reads
                end, 3000),
                "the transfer stalled on the client within 3 s"
            )
            ends(c)
            given = given + (back(before) and 1 or 0)
        end
        return given
    end
    eq(
        abandon(function(c)
            assert(c:abort())
        end),
        3,
        rows[2]
    )
    eq(
        abandon(function(c)
            assert(c:half_close())
            c:close()
        end),
        3,
        rows[3]
    )
end)

-- The files the server opens, followed through fs_open and fs_close: one
-- left open, and a close of a number no longer open, which takes the file
-- whatever opened that number since from its owner. Restored when the case
-- ends.
local function watch_files()
    local open, twice = {}, 0
    local real_open, real_close = uv.fs_open, uv.fs_close
    H.defer(function()
        uv.fs_open, uv.fs_close = real_open, real_close
    end)
    uv.fs_open = function(...)
        local fd, err, name = real_open(...)
        if type(fd) == "number" then
            open[fd] = true
        end
        return fd, err, name
    end
    uv.fs_close = function(fd, ...)
        if open[fd] then
            open[fd] = nil
        else
            twice = twice + 1
        end
        return real_close(fd, ...)
    end
    return function()
        return vim.tbl_count(open), twice
    end
end

-- Every way a transfer ends, each forced by a stub where no real disk or
-- socket fails on demand: the file is closed once and the client reads the
-- end. Files are followed through fs_open and fs_close, not a descriptor
-- listing, so these rows run where none exists. The stubs go in the method
-- table every tcp handle shares and in vim.uv, and each is restored before
-- its rows rule.
H.case("Section 3b: a transfer closes its file once, whichever way it ends", function()
    local inst = serve()
    local port = inst.port
    local files = watch_files()
    local methods = getmetatable(inst.handle).__index
    local real_write, real_shutdown, real_read = methods.write, methods.shutdown, uv.fs_read
    local function restore()
        methods.write, methods.shutdown, uv.fs_read = real_write, real_shutdown, real_read
    end
    H.defer(restore)
    -- Hands the first write that carries body to fn; every other goes out.
    local function on_write(body, fn)
        methods.write = function(h, data, cb)
            if data ~= body then
                return real_write(h, data, cb)
            end
            methods.write = real_write
            return fn(h, data, cb)
        end
    end
    -- Hands the transfer's reads, the ones that take a callback, to fn.
    local function on_file_read(fn)
        uv.fs_read = function(fd, size, offset, cb)
            if type(cb) ~= "function" then
                return real_read(fd, size, offset)
            end
            return fn(fd, size, offset, cb)
        end
    end
    -- One request for path, read to the server's end or 3 s: the response
    -- and whether the end came.
    local function fetch(path)
        local c = assert(H.raw_connect(port))
        assert(c:send(get(path, port)))
        local data, eof = c:read(3000)
        c:close()
        return H.responses(data)[1], eof
    end
    -- From here: whether every file opened since is closed, within 3 s.
    -- Counted from a mark, so a row rules on its own files alone.
    local function since()
        local mark = files()
        return function()
            return H.wait_for(function()
                return (files()) <= mark
            end, 3000)
        end
    end

    local closed = since()
    local small, small_end = fetch("/hello.txt")
    local large, large_end = fetch("/big.bin")
    ok(
        small ~= nil and small.body == "hello" and large ~= nil and large.body == big and small_end and large_end,
        "a small and a 2 MiB file arrive whole and each connection ends"
    )
    ok(closed(), "and each whole transfer closes its file")

    closed = since()
    for _ = 1, 3 do
        local c = assert(H.raw_connect(port))
        assert(c:send(get("/big.bin", port)))
        c:read(3000, function(d)
            return #d >= 65536
        end)
        assert(c:abort())
    end
    ok(closed(), "3 downloads reset after their first 64 KiB close their files")

    closed = since()
    on_file_read(function(fd, size, offset, cb)
        return real_read(fd, size, offset, function()
            cb("EIO: stubbed")
        end)
    end)
    local res, eof = fetch("/hello.txt")
    restore()
    ok(eof and res ~= nil and res.body == "", "a read that fails ends the response with no body")
    ok(closed(), "and closes its file")

    closed = since()
    on_file_read(function()
        return nil, "EINVAL: stubbed", "EINVAL"
    end)
    res, eof = fetch("/hello.txt")
    restore()
    ok(eof and res ~= nil and res.body == "", "a read that cannot start ends the response with no body")
    ok(closed(), "and closes its file")

    closed = since()
    on_write("hello", function()
        return nil, "EBADF: stubbed", "EBADF"
    end)
    res, eof = fetch("/hello.txt")
    restore()
    ok(eof and res ~= nil and res.body == "", "a write that fails at once ends the connection")
    ok(closed(), "and closes its file")

    closed = since()
    on_write(big:sub(1, 65536), function(h, data, cb)
        return real_write(h, data, function()
            cb("ECONNRESET: stubbed")
        end)
    end)
    res, eof = fetch("/big.bin")
    restore()
    ok(eof and res ~= nil and not res.complete, "a write whose callback fails ends the transfer, the rest unsent")
    ok(closed(), "and closes its file")

    closed = since()
    on_write("hello", function()
        error("deliberate write failure")
    end)
    local reported = H.expect_error("deliberate write failure", function()
        res, eof = fetch("/hello.txt")
    end)
    restore()
    ok(reported, "a raise inside the transfer is reported")
    ok(eof, "and ends the connection")
    ok(closed(), "and closes its file")

    -- The first read runs on the handler's own stack, so its raise goes
    -- back to the handler, which owns the socket; the file is the
    -- transfer's to close.
    closed = since()
    on_file_read(function()
        error("deliberate read failure")
    end)
    reported = H.expect_error("deliberate read failure", function()
        local c = assert(H.raw_connect(port))
        assert(c:send(get("/hello.txt", port)))
        c:read(3000, function(d)
            return d:find("\r\n\r\n", 1, true) ~= nil
        end)
        c:close()
    end)
    restore()
    ok(reported, "a raise before the first read is reported")
    ok(closed(), "and the transfer closes its file before the raise goes on")

    closed = since()
    methods.shutdown = function()
        return nil, "ENOTCONN: stubbed", "ENOTCONN"
    end
    res, eof = fetch("/hello.txt")
    restore()
    ok(eof and res ~= nil and res.body == "hello", "a transfer whose shutdown cannot start closes its socket at once")
    ok(closed(), "and its file")

    methods.shutdown = function()
        error("deliberate shutdown failure")
    end
    reported = H.expect_error("deliberate shutdown failure", function()
        res, eof = fetch("/hello.txt")
    end)
    restore()
    ok(reported, "a raise after the file is closed is reported")
    ok(eof and res ~= nil and res.body == "hello", "and ends the connection")
    eq(select(2, files()), 0, "no transfer closed its file twice")
end)

H.finish()
