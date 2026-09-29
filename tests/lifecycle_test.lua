-- tests/lifecycle_test.lua
-- What the server holds while it runs and how it lets go of it: a socket
-- is closed once, whoever ends the connection first, a response whose
-- shutdown cannot start or whose write fails at once closes its socket
-- at once, a file transfer closes its file once, however it ends, a head
-- write that fails included, and a client that half-closes after its
-- request still reads its whole response, where an event
-- stream's half-close ends the stream; stop closes every connection the
-- server accepted, whose set holds the open ones alone; a connection
-- whose head is not read in time is closed, and its timer lives only
-- while the head is unread; a connection accepted while max_connections
-- are open is closed at once, a place frees as a socket closes, and every
-- accepted socket closes through close_once, where the count falls. A
-- raise inside a luv callback, where every handler runs, leaves the exit
-- code at 0, so the rows read the ledger's error capture (H.errors) and
-- count the handles and the descriptors directly. hello.txt and big.bin
-- (its bytes in big) are the small and the 2 MiB file the transfer rows
-- serve, and serve's cfg and get's extra are what those rows pass. A
-- stopped server opens no watcher when its target or live reload
-- changes, and a reload timer that cannot start is reported once. A
-- watcher that cannot start refuses a live start and turns live reload
-- off at enable_live and update_target, with one warning, and a
-- directory under the root that cannot be watched or read is dropped
-- with one warning.
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

-- A client that stopped reading and then ended its side while a page was
-- still being written had its socket closed by the read path; libuv then
-- ran the pending shutdown's callback, whose second close raised "handle
-- is already closing" inside a luv callback: an error in the editor for
-- any client that asks (30 of 30 connections on 0.12.5 and 0.10.0). The
-- page is 16 MiB, past what the socket buffers of both ends take (1.6 MiB
-- at most on macOS, measured), so the write is still pending at the end.
-- The read path leaves a response's socket to the response, so the end
-- and the reset after it reach one close.
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
        -- The server reads the end before this client closes, and the page
        -- keeps the socket while it is written: the close, with the page
        -- unread, then sends a reset, which ends the write.
        assert(
            steady(function()
                return H.handle_count("tcp")
            end, 1000),
            "the tcp count held still within 1 s after the half-close"
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
    -- Counted while the client stays open, whose socket is the one above
    -- the baseline.
    ok(
        H.wait_for(function()
            return H.handle_count("tcp") == sockets + 1
        end, 3000),
        "and the server holds no socket for it"
    )
    c:close()
end)

-- A write fails at once on a closed or shut socket, and a response read
-- the return of neither of its writes: a head that failed was followed
-- by its body, and a body that failed by the response's shutdown. Each
-- write's nil, err is read now, and the response ends there, its socket
-- closed through close_once. The stubs sit in the method table every tcp
-- handle shares, each restored before its rows rule.
H.case("Section 2b: a response whose write fails at once closes its socket there", function()
    local inst = serve()
    local port = inst.port
    local methods = getmetatable(inst.handle).__index
    local real_write, real_shutdown = methods.write, methods.shutdown
    H.defer(function()
        methods.write, methods.shutdown = real_write, real_shutdown
    end)
    local shuts = 0
    methods.shutdown = function(...)
        shuts = shuts + 1
        return real_shutdown(...)
    end
    -- Fails the first write that starts with prefix; every other goes out.
    local function fail_first(prefix)
        methods.write = function(h, data, cb)
            if type(data) ~= "string" or data:sub(1, #prefix) ~= prefix then
                return real_write(h, data, cb)
            end
            methods.write = real_write
            return nil, "EBADF: stubbed", "EBADF"
        end
    end
    fail_first("HTTP/1.1 404 ")
    local data, eof = H.raw_request(port, get("/missing.txt", port))
    methods.write = real_write
    ok(
        eof and data == "",
        ("a 404 whose head write fails sends nothing after it and ends the connection (got %s)"):format(
            vim.inspect(data)
        )
    )
    eq(shuts, 0, "and closes its socket there, with no shutdown")
    shuts = 0
    fail_first("<!doctype html>")
    data, eof = H.raw_request(port, get("/missing.txt", port))
    methods.write = real_write
    local res = H.responses(data or "")[1]
    ok(
        eof and res ~= nil and res.status == 404 and res.body == "",
        "a 404 whose body write fails ends the connection after its head"
    )
    eq(shuts, 0, "and closes its socket there, with no shutdown")
    methods.shutdown = real_shutdown
    ok(
        H.wait_for(function()
            return inst.open_conns == 0
        end, 1000),
        ("and neither holds a place (%d held, want 0)"):format(inst.open_conns)
    )
end)

-- A download its client abandoned left the file open: the write into the
-- gone socket failed, by its return (EBADF) or its callback (EPIPE, or
-- ECANCELED once the read path closed it),
-- nothing read either, and the loop stopped there. Each abandoned download
-- held one descriptor until the editor quit and stop gave none back
-- (measured), so any client that can reach the port could run the editor
-- out of descriptors. The shapes: a client that reads the first chunk and
-- resets, which lands while the server reads the file in about half the
-- runs (the write's return), and one that stops reading a 16 MiB file,
-- past what both ends' socket buffers take, and once the server's write
-- waits on it resets,
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
    local held, fds = steady(H.fd_count, 1000)
    assert(held, "the descriptor count settled before the downloads")
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
            local settled, before = steady(H.fd_count, 1000)
            assert(settled, "the descriptor count settled before this download")
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
            -- A finished transfer holds still too; the open file says it
            -- stalled with the write pending, on a host whose buffers
            -- took the whole page it would not.
            assert(H.fd_count() >= before + 3, "the file is still open while the client stalls")
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
    -- The notices the server sends, each with whether it ran in a fast
    -- event, where the real vim.notify raises. A raise inside a transfer
    -- reached the editor as a bare callback error with no notice.
    local notes = {}
    local real_notify = vim.notify
    H.defer(function()
        vim.notify = real_notify
    end)
    vim.notify = function(msg, level)
        table.insert(notes, { msg = msg, level = level, fast = vim.in_fast_event() })
    end
    -- Whether one notice, and no second, arrives after the first mark
    -- notices within 1 s: an error on one line naming path and cause,
    -- sent outside the fast event.
    local function one_notice(mark, path, cause)
        H.wait_for(function()
            return #notes > mark
        end, 1000)
        vim.wait(50)
        local note = notes[mark + 1]
        return #notes == mark + 1
            and note.level == vim.log.levels.ERROR
            and not note.msg:find("\n", 1, true)
            and note.msg:find(path .. " failed: ", 1, true) ~= nil
            and note.msg:find(cause, 1, true) ~= nil
            and not note.fast
    end
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

    -- The same clients as the first descriptor row, counted through the
    -- open and close spy rather than the descriptor table, which Windows
    -- has none of; the row that runs there.
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
    methods.write = function(h, data, cb)
        if type(data) ~= "string" or data:sub(1, 9) ~= "HTTP/1.1 " then
            return real_write(h, data, cb)
        end
        methods.write = real_write
        return nil, "EBADF: stubbed", "EBADF"
    end
    local bytes, ended = H.raw_request(port, get("/hello.txt", port))
    restore()
    ok(
        ended and bytes == "",
        ("a head write that fails at once sends nothing after it and ends the connection (got %s)"):format(
            vim.inspect(bytes)
        )
    )
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
    local mark, errs = #notes, #H.errors()
    on_write("hello", function()
        error("deliberate write failure")
    end)
    res, eof = fetch("/hello.txt")
    restore()
    ok(
        one_notice(mark, "/hello.txt", "deliberate write failure"),
        "a raise inside the transfer is reported once, on one line, outside the fast event"
    )
    eq(#H.errors(), errs, "and reaches the editor as no callback error")
    ok(eof, "and ends the connection")
    ok(closed(), "and closes its file")

    -- The first read runs on the handler's own stack, so its raise goes
    -- back to the handler, which owns the socket and reports the raise;
    -- the file is the transfer's to close.
    closed = since()
    mark = #notes
    on_file_read(function()
        error("deliberate read failure")
    end)
    local c = assert(H.raw_connect(port))
    assert(c:send(get("/hello.txt", port)))
    c:read(3000, function(d)
        return d:find("\r\n\r\n", 1, true) ~= nil
    end)
    c:close()
    restore()
    ok(one_notice(mark, "/hello.txt", "deliberate read failure"), "a raise before the first read is reported")
    ok(closed(), "and the transfer closes its file before the raise goes on")

    closed = since()
    methods.shutdown = function()
        return nil, "ENOTCONN: stubbed", "ENOTCONN"
    end
    res, eof = fetch("/hello.txt")
    restore()
    ok(eof and res ~= nil and res.body == "hello", "a transfer whose shutdown cannot start closes its socket at once")
    ok(closed(), "and its file")

    mark, errs = #notes, #H.errors()
    methods.shutdown = function()
        error("deliberate shutdown failure")
    end
    res, eof = fetch("/hello.txt")
    restore()
    ok(
        one_notice(mark, "/hello.txt", "deliberate shutdown failure"),
        "a raise after the file is closed is reported once, on one line, outside the fast event"
    )
    eq(#H.errors(), errs, "and reaches the editor as no callback error")
    ok(eof and res ~= nil and res.body == "hello", "and ends the connection")
    eq(select(2, files()), 0, "no transfer closed its file twice")
end)

-- A client that sent its request and then ended its side (a FIN, as a
-- script's shutdown or a proxy's half-close sends) had the socket closed
-- under its response: a file came back as its head alone, and a page
-- larger than the socket buffers was cut where its write stood
-- (measured). An event stream is the one response that never ends by
-- itself, so its client's end still closes it and takes it off the
-- client list.
H.case("Section 4: a client that half-closes after its request reads it all", function()
    H.write_file(root .. "/page.html", "<html><body>" .. string.rep("q", 4 * 1024 * 1024) .. "</body></html>")
    local inst = serve()
    local port = inst.port
    local held, fds = steady(function()
        return H.fd_count() or 0
    end, 1000)
    assert(held, "the descriptor count settled before the requests")
    -- One request, then the half-close, read to the server's end or ms:
    -- the responses and whether the half-close went out. A server that
    -- answered and closed with a request body's tail unread resets the
    -- connection, and the half-close then finds it gone (ENOTCONN,
    -- measured), so the rows with a body rule on the response alone.
    -- after_shut runs once the half-close has gone out.
    local function half_closed(bytes, ms, after_shut)
        local c = assert(H.raw_connect(port))
        assert(c:send(bytes))
        local shut = c:half_close()
        if after_shut then
            after_shut()
        end
        local data = c:read(ms)
        c:close()
        return H.responses(data), shut
    end
    local res, shut = half_closed(get("/big.bin", port), 10000)
    ok(shut and res[1] ~= nil and res[1].body == big, "a 2 MiB body arrives whole after the half-close")
    -- Five bytes could go out whole before the FIN landed (13 to 28 of
    -- 200 connections, measured), so the file's read is held until the
    -- server has read the FIN.
    local real_read, release = uv.fs_read, nil
    H.defer(function()
        uv.fs_read = real_read
    end)
    uv.fs_read = function(fd, size, offset, cb)
        if type(cb) ~= "function" then
            return real_read(fd, size, offset)
        end
        uv.fs_read = real_read
        release = function()
            assert(real_read(fd, size, offset, cb))
        end
        return true
    end
    res, shut = half_closed(get("/hello.txt", port), 3000, function()
        assert(
            H.wait_for(function()
                return release ~= nil
            end, 1000),
            "the transfer asked for its first read within 1 s"
        )
        uv.fs_read = real_read
        assert(
            steady(function()
                return H.handle_count("tcp")
            end, 1000),
            "the tcp count held still within 1 s after the half-close"
        )
        release()
    end)
    ok(shut and res[1] ~= nil and res[1].body == "hello", "a small body arrives whole after the half-close")
    res, shut = half_closed(get("/page.html", port), 10000)
    ok(
        shut and res[1] ~= nil and res[1].complete and #res[1].body > 4 * 1024 * 1024,
        "a 4 MiB page arrives whole after the half-close"
    )
    local answered = 0
    local body = string.rep("b", 65536)
    for _ = 1, 20 do
        res = half_closed(
            ("GET /index.html HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nContent-Length: %d\r\n\r\n%s"):format(port, #body, body),
            3000
        )
        answered = answered + (#res == 1 and 1 or 0)
    end
    eq(answered, 20, "each of 20 half-closed requests with a 64 KiB body gets its response")
    if H.fd_count() then
        ok(
            H.wait_for(function()
                return H.fd_count() == fds
            end, 3000),
            "and no descriptor is left open"
        )
    else
        H.skip("and no descriptor is left open (no descriptor listing on this platform)")
    end

    local c = assert(H.raw_connect(port))
    assert(c:send(get("/__live/events", port)))
    c:read(2000, function(d)
        return d:find("retry: 1000\n\n", 1, true) ~= nil
    end)
    assert(
        H.wait_for(function()
            return server.connected_client_count(inst) == 1
        end, 2000),
        "the event stream opened within 2 s"
    )
    assert(c:half_close())
    ok(
        H.wait_for(function()
            return server.connected_client_count(inst) == 0
        end, 2000),
        "an event stream whose client half-closes leaves the client list"
    )
    local _, eof = c:read(2000)
    ok(eof, "and its connection ends")
    c:close()
end)

-- Of its sockets, stop closed the listener and the event streams alone,
-- so a stopped server kept every other connection it had accepted: an
-- idle client, one mid-head, a download stalled on its client with its
-- file open, and a page whose shutdown waited on its write (the download
-- held its file one second after stop, measured). Each shape is counted
-- back after stop and before its client closes, since a client's close
-- ends the server's side by itself.
H.case("Section 5: stop closes every connection it accepted", function()
    H.write_file(root .. "/large.bin", string.rep("b", 16 * 1024 * 1024))
    H.write_file(root .. "/large.html", "<html><body>" .. string.rep("p", 16 * 1024 * 1024) .. "</body></html>")
    local function tcp_count()
        return H.handle_count("tcp")
    end
    -- How many clients saw the server's end within ms.
    local function all_ended(clients, ms)
        local ended = 0
        H.wait_for(function()
            ended = 0
            for _, c in ipairs(clients) do
                ended = ended + (c.eof and 1 or 0)
            end
            return ended == #clients
        end, ms)
        return ended
    end

    local held, tcps = steady(tcp_count, 1000)
    assert(held, "the tcp count settled before the idle clients")
    local inst = serve()
    local port = inst.port
    local clients = {}
    for i = 1, 5 do
        local c = assert(H.raw_connect(port))
        if i > 3 then
            assert(c:send(("GET /index.html HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n"):format(port)))
        end
        clients[i] = c
    end
    assert(
        H.wait_for(function()
            return tcp_count() == tcps + 11
        end, 1000),
        "the server accepted the five clients within 1 s"
    )
    server.stop(inst)
    eq(all_ended(clients, 2000), 5, "every client that sent nothing or half a head sees its connection end at stop")
    ok(
        H.wait_for(function()
            return tcp_count() == tcps + 5
        end, 2000),
        ("and the server holds none of their sockets (%d over the clients')"):format(tcp_count() - tcps - 5)
    )
    for _, c in ipairs(clients) do
        c:close()
    end

    -- The files the server opens, and the reads its transfers start: once
    -- the reads hold still, a transfer waits on a write its client does
    -- not take.
    local files = watch_files()
    local reads = 0
    local real_read = uv.fs_read
    H.defer(function()
        uv.fs_read = real_read
    end)
    uv.fs_read = function(...)
        reads = reads + 1
        return real_read(...)
    end
    local fds
    held, fds = steady(function()
        return H.fd_count() or 0
    end, 1000)
    assert(held, "the descriptor count settled before the download")
    held, tcps = steady(tcp_count, 1000)
    assert(held, "the tcp count settled before the download")
    inst = serve()
    port = inst.port
    local d = assert(H.raw_connect(port))
    assert(d.tcp:read_stop())
    assert(d:send(get("/large.bin", port)))
    assert(
        H.wait_for(function()
            return (files()) == 1
        end, 1000),
        "the transfer opened its file within 1 s"
    )
    assert(
        steady(function()
            return reads
        end, 3000),
        "the transfer stalled on its client within 3 s"
    )
    assert((files()) == 1, "the file is still open while the client stalls")
    server.stop(inst)
    ok(
        H.wait_for(function()
            return (files()) == 0
        end, 3000),
        "a download stalled on its client at stop closes its file"
    )
    ok(
        H.wait_for(function()
            return tcp_count() == tcps + 1
        end, 3000),
        ("and its socket, counted while the client stays open (%d over the client's)"):format(tcp_count() - tcps - 1)
    )
    if H.fd_count() then
        ok(
            H.wait_for(function()
                return H.fd_count() == fds + 1
            end, 3000),
            ("and holds no descriptor (%d over the client's)"):format(H.fd_count() - fds - 1)
        )
    else
        H.skip("and holds no descriptor (no descriptor listing on this platform)")
    end
    d:close()

    -- stop is a second closer beside a page's shutdown callback: its close
    -- cancels the pending shutdown, whose callback then closes again. The
    -- page is 16 MiB, past what both ends' socket buffers take, so its
    -- write and the shutdown behind it are still pending at stop.
    local methods = getmetatable(inst.handle).__index
    local real_shutdown = methods.shutdown
    H.defer(function()
        methods.shutdown = real_shutdown
    end)
    local shutting = {}
    methods.shutdown = function(h, ...)
        table.insert(shutting, h)
        return real_shutdown(h, ...)
    end
    held, tcps = steady(tcp_count, 1000)
    assert(held, "the tcp count settled before the pages")
    local seen = #H.errors()
    inst = serve()
    port = inst.port
    local pages = {}
    for i = 1, 3 do
        local c = assert(H.raw_connect(port))
        assert(c.tcp:read_stop())
        assert(c:send(get("/large.html", port)))
        pages[i] = c
    end
    assert(
        H.wait_for(function()
            return #shutting == 3
        end, 3000),
        "each page asked for its shutdown within 3 s"
    )
    methods.shutdown = real_shutdown
    for _, h in ipairs(shutting) do
        assert(h:get_write_queue_size() > 0, "each page is still being written when stop runs")
    end
    server.stop(inst)
    -- Counted while the clients still read nothing: one that reads takes
    -- the whole page, and the page then closes its own socket.
    ok(
        H.wait_for(function()
            return tcp_count() == tcps + 3
        end, 2000),
        ("3 pages whose shutdown waits on a stalled client close at stop (%d over the clients')"):format(
            tcp_count() - tcps - 3
        )
    )
    -- The cancelled shutdown's callback runs a loop turn after the close,
    -- and its raise reaches the error capture a turn or more after that.
    steady(function()
        return #H.errors()
    end, 1000)
    local raised = errors_since(seen)
    ok(
        #raised == 0,
        "and each closes once, raising nothing" .. (#raised > 0 and (": " .. table.concat(raised, " | ")) or "")
    )
    for _, c in ipairs(pages) do
        c:close()
    end

    local again, why = pcall(server.stop, inst)
    ok(again, "a second stop raises nothing" .. (again and "" or (": " .. tostring(why))))
end)

-- The set stop reads: a connection enters it at its accept and leaves it
-- as its socket closes, whoever closes it, so it holds the open
-- connections alone, however many came before; a closed one waited in it
-- for the next accept. An accept that fails leaves the handle the server
-- made for it unopened, and nothing closed it. A handle the server cannot
-- make for a connection raised in the listen callback, where the user saw
-- a callback error and no word that the server had stopped taking
-- connections.
H.case("Section 5b: the set holds the open connections alone", function()
    local inst = serve()
    local port = inst.port
    local function tcp_count()
        return H.handle_count("tcp")
    end
    local answered = 0
    for _ = 1, 100 do
        local res = H.responses(H.raw_request(port, get("/hello.txt", port)) or "")[1]
        answered = answered + (res and res.status == 200 and 1 or 0)
    end
    assert(answered == 100, "the server answered 100 requests")
    -- Once every socket of the 100 is closing, none is left in the set,
    -- and the next accept's connection is alone in it.
    local held, tcps = steady(tcp_count, 1000)
    assert(held, "the tcp count settled after the requests")
    eq(vim.tbl_count(inst.conns), 0, "after 100 connections one after another, none is left in the set")
    local idle = assert(H.raw_connect(port))
    assert(
        H.wait_for(function()
            return tcp_count() == tcps + 2
        end, 1000),
        "the server accepted one more connection within 1 s"
    )
    eq(
        type(inst.conns) == "table" and vim.tbl_count(inst.conns) or nil,
        1,
        "after 100 connections one after another, the next accept leaves its own alone in the set"
    )
    idle:close()

    held, tcps = steady(tcp_count, 1000)
    assert(held, "the tcp count settled before the failed accept")
    -- No real accept fails on demand. The stub takes the connection into a
    -- handle of its own and closes it, as libuv closes the descriptor of an
    -- accept that failed, and returns the failure: the server's own handle
    -- is left as a failed accept leaves it, made and never opened.
    local methods = getmetatable(inst.handle).__index
    local real_accept = methods.accept
    H.defer(function()
        methods.accept = real_accept
    end)
    local failed = false
    methods.accept = function(listener)
        methods.accept = real_accept
        local taken = assert(uv.new_tcp())
        assert(real_accept(listener, taken))
        taken:close()
        failed = true
        return nil, "ECONNABORTED: stubbed", "ECONNABORTED"
    end
    local c = assert(H.raw_connect(port))
    assert(
        H.wait_for(function()
            return failed
        end, 1000),
        "the server met the failed accept within 1 s"
    )
    methods.accept = real_accept
    ok(
        H.wait_for(function()
            return H.handle_count("tcp") == tcps + 1
        end, 2000),
        ("a connection whose accept failed leaves the server no socket (%d over the client's)"):format(
            H.handle_count("tcp") - tcps - 1
        )
    )
    c:close()
    local res = H.responses(H.raw_request(port, get("/hello.txt", port)) or "")[1]
    eq(res and res.status, 200, "and the server answers the next connection")

    -- A fresh server, since the listener takes no connection after a
    -- handle it could not make. The client's handle is made on the suite's
    -- own stack and the server's in the listen callback, a fast event, so
    -- only the server's call gets nil.
    local notes = {}
    local real_notify = vim.notify
    H.defer(function()
        vim.notify = real_notify
    end)
    vim.notify = function(msg, level)
        table.insert(notes, { msg = msg, level = level })
    end
    local stuck = serve()
    held, tcps = steady(tcp_count, 1000)
    assert(held, "the tcp count settled before the handle that cannot be made")
    local errs = #H.errors()
    local real_new_tcp = uv.new_tcp
    H.defer(function()
        uv.new_tcp = real_new_tcp
    end)
    uv.new_tcp = function(...)
        if not vim.in_fast_event() then
            return real_new_tcp(...)
        end
        uv.new_tcp = real_new_tcp
        return nil, "ENOMEM: stubbed", "ENOMEM"
    end
    local lost = assert(H.raw_connect(stuck.port))
    H.wait_for(function()
        return #notes > 0
    end, 1000)
    uv.new_tcp = real_new_tcp
    steady(function()
        return #notes
    end, 1000)
    local note = notes[1]
    ok(
        #notes == 1
            and note.level == vim.log.levels.WARN
            and note.msg:find("stopped accepting connections", 1, true) ~= nil,
        ("a connection the server can make no socket for is warned of once, at WARN (%d notices)"):format(#notes)
    )
    eq(#H.errors(), errs, "and raises nothing")
    eq(tcp_count(), tcps + 1, "and the server makes no socket for it")
    lost:close()
end)

-- A connection that never finished its head held its socket until its
-- client left: 50 clients, idle or with half a head sent, held 50 sockets
-- 12 s on (measured). A timer per connection closes one whose head is not
-- read in time, with no response, since a browser opens spare connections
-- it may never use; a head sent a byte at a time is held to the same
-- deadline. A head read in time stops the timer, so an event stream,
-- whose head is read at once, is never timed out.
H.case("Section 6: a connection that never finishes its head is closed", function()
    local inst = serve({ header_timeout_ms = 200 })
    local port = inst.port
    local idle = assert(H.raw_connect(port))
    local t0 = uv.hrtime()
    local _, eof = idle:read(3000)
    ok(eof, "an idle connection is closed")
    ok((uv.hrtime() - t0) / 1e6 < 1500, "at the header timeout, not the test's read bound")
    local part = assert(H.raw_connect(port))
    assert(part:send(("GET /hello.txt HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n"):format(port)))
    local answer, part_eof = part:read(3000)
    ok(
        part_eof and answer == "",
        ("a head sent in part is closed too, with no response (%d bytes read)"):format(#answer)
    )
    -- A head trickled a byte every 50 ms never idles for the timeout, so
    -- a timer that counted from the last byte would hold it for the whole
    -- trickle, over 2 s; the deadline counts from the accept.
    local slow = assert(H.raw_connect(port))
    local t1 = uv.hrtime()
    for ch in ("GET /hello.txt HTTP/1.1\r\nHost: 127.0.0.1\r\nX: y\r\n"):gmatch(".") do
        if slow.eof or not slow:send(ch) then
            break
        end
        vim.wait(50)
    end
    local _, slow_eof = slow:read(3000)
    local slow_ms = (uv.hrtime() - t1) / 1e6
    ok(
        slow_eof and slow_ms < 1000,
        ("a head trickled a byte at a time is closed at the timeout too (%d ms)"):format(math.floor(slow_ms))
    )
    local res = H.responses(H.raw_request(port, get("/hello.txt", port)) or "")
    eq(res[1] and res[1].status, 200, "a head sent in time is served")
    local s = assert(H.raw_connect(port))
    assert(s:send(get("/__live/events", port)))
    s:read(1000, function(d)
        return d:find("retry: 1000\n\n", 1, true) ~= nil
    end)
    local _, sse_eof = s:read(600)
    ok(not sse_eof, "an event stream outlives the header timeout")
    server.send_event(inst, "tick", "{}")
    local data = s:read(1000, function(d)
        return d:find("event: tick", 1, true) ~= nil
    end)
    ok(data:find("event: tick", 1, true) ~= nil, "and still receives events")
end)

-- The timer is the connection's while its head is unread: a head read or
-- refused stops it, so an answered request and an event stream hold
-- none, a connection that ends first takes its timer with it, and stop
-- closes the timers of the connections still waiting. It is on by
-- default and 0 turns it off. A connection no timer can be made for
-- could be held for good, so it is closed, and the user is told once,
-- where a silent close left pages failing with no word of why.
H.case("Section 6b: a connection's timer lives while its head is unread", function()
    local function timer_count()
        return H.handle_count("timer")
    end
    local function tcp_count()
        return H.handle_count("tcp")
    end
    -- Once the server holds one more accepted socket than before.
    local function accepted(tcps)
        return H.wait_for(function()
            return tcp_count() == tcps + 2
        end, 1000)
    end
    local before = timer_count()
    local inst = serve({ header_timeout_ms = 5000 })
    local port = inst.port
    local timers = timer_count()
    local tcps = tcp_count()
    local gone = assert(H.raw_connect(port))
    assert(accepted(tcps), "the server accepted a connection within 1 s")
    eq(timer_count(), timers + 1, "an idle connection waits on a timer of its own")
    gone:close()
    ok(
        H.wait_for(function()
            return timer_count() == timers
        end, 1000),
        "a connection that ends before its head closes its timer with it"
    )
    local idle = assert(H.raw_connect(port))
    assert(
        H.wait_for(function()
            return timer_count() == timers + 1
        end, 1000),
        "the server took the idle connection within 1 s"
    )
    local waiting = timer_count()
    local res = H.responses(H.raw_request(port, get("/hello.txt", port)) or "")[1]
    assert(res and res.status == 200, "the server answered /hello.txt")
    eq(timer_count(), waiting, "a request whose head is read holds no timer once answered")
    -- A head refused before it is read whole: a first byte no method
    -- starts with (a TLS ClientHello on the plain port) and one past the
    -- cap with no end.
    for _, c in ipairs({
        { "a head refused at its first byte", "\22\3\1\0\5hello", 400 },
        { "a head refused over the cap", "GET / HTTP/1.1\r\nX-Pad: " .. string.rep("a", 70 * 1024), 431 },
    }) do
        local refused = H.responses(H.raw_request(port, c[2]) or "")[1]
        assert(refused and refused.status == c[3], ("%s is answered %d"):format(c[1], c[3]))
        eq(timer_count(), waiting, c[1] .. " holds no timer once answered")
    end
    local s = assert(H.raw_connect(port))
    assert(s:send(get("/__live/events", port)))
    assert(
        H.wait_for(function()
            return server.connected_client_count(inst) == 1
        end, 2000),
        "the event stream opened within 2 s"
    )
    eq(timer_count(), waiting, "an event stream holds no timer once its head is read")
    server.stop(inst)
    eq(timer_count(), before, "stop closes the timer of every connection still waiting")
    idle:close()
    s:close()

    inst = serve()
    local due
    assert(H.raw_connect(inst.port))
    H.wait_for(function()
        for conn in pairs(inst.conns) do
            due = conn.timer and conn.timer:get_due_in()
        end
        return due ~= nil
    end, 1000)
    ok(
        due ~= nil and due > 9000 and due <= 10000,
        ("by default a connection waits 10 s for its head (due in %s ms)"):format(tostring(due))
    )

    inst = serve({ header_timeout_ms = 0 })
    timers, tcps = timer_count(), tcp_count()
    assert(H.raw_connect(inst.port))
    assert(accepted(tcps), "the server accepted the connection within 1 s")
    eq(timer_count(), timers, "with header_timeout_ms = 0 a connection gets no timer")

    -- No real timer fails to be made. The server makes it in the listen
    -- callback, a fast event, and the client's handles are made on the
    -- suite's own stack, so only the server's calls get nil: two of them,
    -- so the notice is seen to come once.
    inst = serve({ header_timeout_ms = 5000 })
    local notes = {}
    local real_notify = vim.notify
    H.defer(function()
        vim.notify = real_notify
    end)
    vim.notify = function(msg, level)
        table.insert(notes, { msg = msg, level = level })
    end
    local errs = #H.errors()
    local real_new_timer = uv.new_timer
    H.defer(function()
        uv.new_timer = real_new_timer
    end)
    local failing = 2
    uv.new_timer = function(...)
        if not vim.in_fast_event() or failing == 0 then
            return real_new_timer(...)
        end
        failing = failing - 1
        return nil, "ENOMEM: stubbed", "ENOMEM"
    end
    local ended = 0
    for _ = 1, 2 do
        local lost = assert(H.raw_connect(inst.port))
        local _, lost_eof = lost:read(2000)
        ended = ended + (lost_eof and 1 or 0)
    end
    uv.new_timer = real_new_timer
    eq(ended, 2, "a connection the server can make no timer for is closed")
    steady(function()
        return #notes
    end, 1000)
    local note = notes[1] or {}
    ok(
        #notes == 1
            and note.level == vim.log.levels.WARN
            and tostring(note.msg):find("closed a connection it could not serve", 1, true) ~= nil,
        ("and the user is warned once, at WARN, for two such (%d notices: %s)"):format(#notes, tostring(note.msg))
    )
    eq(#H.errors(), errs, "and raises nothing")
    res = H.responses(H.raw_request(inst.port, get("/hello.txt", inst.port)) or "")[1]
    eq(res and res.status, 200, "and the server answers the next connection")
    -- The two kinds warn on their own: one flag for both would let the
    -- timer's notice swallow the socket's, the one that says the server
    -- stopped accepting and must be restarted.
    local real_new_tcp = uv.new_tcp
    H.defer(function()
        uv.new_tcp = real_new_tcp
    end)
    local once = true
    uv.new_tcp = function(...)
        if not vim.in_fast_event() or not once then
            return real_new_tcp(...)
        end
        once = false
        return nil, "EMFILE: stubbed", "EMFILE"
    end
    local unmet = assert(H.raw_connect(inst.port))
    unmet:read(500)
    uv.new_tcp = real_new_tcp
    steady(function()
        return #notes
    end, 1000)
    local second = notes[2] or {}
    ok(
        #notes == 2
            and second.level == vim.log.levels.WARN
            and tostring(second.msg):find("stopped accepting connections", 1, true) ~= nil,
        ("and a socket it cannot make is still warned of after the timer's notice (%d notices)"):format(#notes)
    )
end)

-- Nothing bounded the sockets a client could hold open, and each is a
-- descriptor of the editor's own process, whose soft limit is 256 for a
-- macOS app by default. A connection accepted while max_connections are
-- open is closed at once, unread and unanswered, and counts nowhere; a
-- browser page holds a handful. A connection leaves the count as its
-- socket closes, whoever closes it, so a place frees as a response ends,
-- a client leaves, the header timeout fires or an event stream ends. A
-- connection whose read cannot start is closed: with no head timer
-- nothing else ended it, and it held its place after its client left
-- (measured). The count is kept, never recounted: each accept checked
-- every connection in the set (100 checks with 100 open, measured).
H.case("Section 7: connections over the cap are closed at once", function()
    local function tcp_count()
        return H.handle_count("tcp")
    end
    -- Whether the server's set reaches n connections within 2 s.
    local function holds(inst, n)
        return H.wait_for(function()
            return vim.tbl_count(inst.conns) == n
        end, 2000)
    end
    -- Once the tcp count holds still, every close so far has landed.
    local function settled()
        assert(steady(tcp_count, 1000), "the tcp count settled within 1 s")
    end
    -- The status one request on a fresh connection is answered with.
    local function status(port)
        local res = H.responses(H.raw_request(port, get("/hello.txt", port)) or "")[1]
        return res and res.status
    end
    -- Whether a fresh connection that sends a request is closed with no
    -- byte sent back, and the bytes it read. Its send may meet the close
    -- already made, so the read alone rules.
    local function shut_out(port)
        local c = assert(H.raw_connect(port))
        c:send(get("/hello.txt", port))
        local data, eof = c:read(1000)
        c:close()
        return eof and data == "", #data
    end
    -- The servers started before the one that holds 100 connections, each
    -- stopped before it: the two ends of 100 connections are 200 of this
    -- process's descriptors.
    local servers = {}
    local function start(cfg)
        local started = serve(cfg)
        table.insert(servers, started)
        return started
    end

    local inst = start({ max_connections = 2 })
    local port = inst.port
    local a = assert(H.raw_connect(port))
    assert(H.raw_connect(port))
    assert(holds(inst, 2), "the server took two connections within 2 s")
    local tcps = tcp_count()
    local third = assert(H.raw_connect(port))
    third:send(get("/hello.txt", port))
    local data, eof = third:read(1000)
    ok(eof and data == "", ("a third connection is closed at once, unread and unanswered (%d bytes)"):format(#data))
    ok(
        H.wait_for(function()
            return tcp_count() == tcps + 1
        end, 1000),
        ("and the server holds no socket for it (%d over the client's)"):format(tcp_count() - tcps - 1)
    )
    third:close()
    assert(a:send(get("/hello.txt", port)))
    local res = H.responses((a:read(2000)))
    eq(res[1] and res[1].status, 200, "a connection under the cap is served")
    a:close()
    settled()
    eq(status(port), 200, "and its place, freed as its response ends, serves the next connection")

    inst = start({ max_connections = 1 })
    port = inst.port
    local gone = assert(H.raw_connect(port))
    assert(holds(inst, 1), "the server took the connection within 2 s")
    gone:close()
    settled()
    eq(status(port), 200, "a client that leaves before its head frees its place")

    inst = start({ max_connections = 1, header_timeout_ms = 200 })
    port = inst.port
    local idle = assert(H.raw_connect(port))
    local _, idle_eof = idle:read(2000)
    assert(idle_eof, "the header timeout closed the idle connection within 2 s")
    eq(status(port), 200, "a connection the header timeout closes frees its place")

    inst = start({ max_connections = 1 })
    port = inst.port
    local s = assert(H.raw_connect(port))
    assert(s:send(get("/__live/events", port)))
    assert(
        H.wait_for(function()
            return server.connected_client_count(inst) == 1
        end, 2000),
        "the event stream opened within 2 s"
    )
    local shut, n = shut_out(port)
    ok(shut, ("an open event stream holds its place: the next connection is closed at once (%d bytes)"):format(n))
    s:close()
    assert(
        H.wait_for(function()
            return server.connected_client_count(inst) == 0
        end, 2000),
        "the event stream ended within 2 s"
    )
    settled()
    eq(status(port), 200, "and its end frees the place")

    -- No real read fails to start on demand. The stub fails the server's
    -- next two, made in the listen callback, a fast event; a client's read
    -- starts on the suite's own stack. Two, so the notice is seen to come
    -- once.
    inst = start({ max_connections = 1, header_timeout_ms = 0 })
    port = inst.port
    local notes = {}
    local real_notify = vim.notify
    H.defer(function()
        vim.notify = real_notify
    end)
    vim.notify = function(msg, level)
        table.insert(notes, { msg = msg, level = level })
    end
    local methods = getmetatable(inst.handle).__index
    local real_read_start = methods.read_start
    H.defer(function()
        methods.read_start = real_read_start
    end)
    local failing = 2
    methods.read_start = function(h, ...)
        if not vim.in_fast_event() or failing == 0 then
            return real_read_start(h, ...)
        end
        failing = failing - 1
        return nil, "EINVAL: stubbed", "EINVAL"
    end
    local errs = #H.errors()
    local ended = 0
    for _ = 1, 2 do
        local c = assert(H.raw_connect(port))
        local _, c_eof = c:read(1000)
        ended = ended + (c_eof and 1 or 0)
        c:close()
    end
    methods.read_start = real_read_start
    eq(ended, 2, "a connection whose read cannot start is closed")
    settled()
    eq(status(port), 200, "and its place serves the next connection")
    steady(function()
        return #notes
    end, 1000)
    local note = notes[1] or {}
    ok(
        #notes == 1
            and note.level == vim.log.levels.WARN
            and tostring(note.msg):find("closed a connection it could not read", 1, true) ~= nil,
        ("and the user is warned once, at WARN, for two such (%d notices: %s)"):format(#notes, tostring(note.msg))
    )
    eq(#H.errors(), errs, "and raises nothing")
    vim.notify = real_notify

    inst = start()
    port = inst.port
    local clients = {}
    for i = 1, 64 do
        clients[i] = assert(H.raw_connect(port))
    end
    assert(holds(inst, 64), "the server took 64 connections within 2 s")
    shut, n = shut_out(port)
    ok(shut, ("by default a 65th connection is closed at once (%d bytes)"):format(n))
    for _, c in ipairs(clients) do
        c:close()
    end
    settled()
    for _, earlier in ipairs(servers) do
        server.stop(earlier)
    end
    settled()

    -- Only the server's own checks count: the harness checks every handle
    -- it registered each 64th registration.
    inst = serve({ max_connections = 200, header_timeout_ms = 0 })
    port = inst.port
    clients = {}
    for i = 1, 100 do
        clients[i] = assert(H.raw_connect(port))
    end
    assert(holds(inst, 100), "the server took 100 connections within 2 s")
    local watched = {}
    for conn in pairs(inst.conns) do
        watched[conn.sock] = true
    end
    local real_is_closing = methods.is_closing
    H.defer(function()
        methods.is_closing = real_is_closing
    end)
    local checks = 0
    methods.is_closing = function(h)
        if watched[h] and debug.getinfo(2, "S").source:find("[/\\]live_server[/\\]server%.lua$") then
            checks = checks + 1
        end
        return real_is_closing(h)
    end
    table.insert(clients, assert(H.raw_connect(port)))
    local took = holds(inst, 101)
    methods.is_closing = real_is_closing
    assert(took, "the server took the 101st connection within 2 s")
    eq(checks, 0, "with 100 connections open, one more accept checks none of them")
    for _, c in ipairs(clients) do
        c:close()
    end
end)

-- The count falls in close_once alone, so a socket closed any other way
-- keeps its place for good. Every close of a socket the server accepted
-- is seen here, with whether close_once made it, over one of each way a
-- connection ends: a file, a 404, a listing, a page, a head refused at
-- its first byte, over the head's size cap or cut by its client's end, a client that
-- leaves or never finishes its head, an event stream its client ends or
-- a broadcast write fails, a transfer reset mid-way or while stalled, a
-- raise in the handler after the head went out, a shutdown that cannot
-- start, and stop. The stubs that force the rarer ways sit in the method
-- table every tcp handle shares and in vim.uv, each restored before its
-- rows rule.
H.case("Section 7b: every accepted socket closes through close_once", function()
    H.write_file(root .. "/huge.bin", string.rep("h", 16 * 1024 * 1024))
    vim.fn.mkdir(root .. "/sub", "p")
    H.write_file(root .. "/sub/a.txt", "a")
    local inst = serve({ header_timeout_ms = 200, features = { dirlist = { enabled = true } } })
    local port = inst.port
    local close_once
    for i = 1, 100 do
        local name, value = debug.getupvalue(server.stop, i)
        if name == nil then
            break
        end
        if name == "close_once" then
            close_once = value
        end
    end
    assert(
        type(close_once) == "function",
        "S.stop holds no upvalue named close_once: renamed, or stop no longer closes through it"
    )
    local methods = getmetatable(inst.handle).__index
    local real_new_tcp, real_close = uv.new_tcp, methods.close
    local real_write, real_shutdown, real_read = methods.write, methods.shutdown, uv.fs_read
    local function restore()
        methods.write, methods.shutdown, uv.fs_read = real_write, real_shutdown, real_read
    end
    H.defer(function()
        restore()
        uv.new_tcp, methods.close = real_new_tcp, real_close
    end)
    local notes = {}
    local real_notify = vim.notify
    H.defer(function()
        vim.notify = real_notify
    end)
    vim.notify = function(msg, level)
        table.insert(notes, { msg = msg, level = level })
    end
    -- The server makes an accepted socket in the listen callback, a fast
    -- event; a client's is made on the suite's own stack.
    local made, closes, raw = {}, 0, 0
    uv.new_tcp = function(...)
        local h, err = real_new_tcp(...)
        if h and vim.in_fast_event() then
            made[h] = true
        end
        return h, err
    end
    methods.close = function(h, ...)
        if made[h] then
            closes = closes + 1
            if debug.getinfo(2, "f").func ~= close_once then
                raw = raw + 1
            end
        end
        return real_close(h, ...)
    end
    local function settled()
        assert(
            steady(function()
                return H.handle_count("tcp")
            end, 2000),
            "the tcp count settled within 2 s"
        )
    end
    local function streams(n)
        return H.wait_for(function()
            return server.connected_client_count(inst) == n
        end, 2000)
    end

    for _, bytes in ipairs({
        get("/hello.txt", port),
        get("/missing.txt", port),
        get("/sub/", port),
        get("/", port),
        "\22\3\1\0\5hello",
        "GET / HTTP/1.1\r\nX-Pad: " .. string.rep("a", 70 * 1024),
    }) do
        H.raw_request(port, bytes)
    end
    local cut = assert(H.raw_connect(port))
    assert(cut:send("GET /hello.txt HTTP/1.1\r\n"))
    assert(cut:half_close())
    cut:read(2000)
    cut:close()
    local left = assert(H.raw_connect(port))
    left:close()
    local idle = assert(H.raw_connect(port))
    local _, idle_eof = idle:read(2000)
    assert(idle_eof, "the header timeout closed the idle connection within 2 s")
    idle:close()

    local ended = assert(H.raw_connect(port))
    assert(ended:send(get("/__live/events", port)))
    assert(streams(1), "an event stream opened within 2 s")
    ended:close()
    assert(streams(0), "the stream its client ended left within 2 s")
    local dropped = assert(H.raw_connect(port))
    assert(dropped:send(get("/__live/events", port)))
    assert(streams(1), "a second event stream opened within 2 s")
    local target = inst.sse_clients[1]
    methods.write = function(h, ...)
        if h == target then
            return nil, "EPIPE: stubbed", "EPIPE"
        end
        return real_write(h, ...)
    end
    server.send_event(inst, "tick", "{}")
    restore()
    assert(streams(0), "the stream whose write failed left within 2 s")
    dropped:read(2000)
    dropped:close()

    local reset = assert(H.raw_connect(port))
    assert(reset:send(get("/huge.bin", port)))
    reset:read(3000, function(d)
        return #d >= 65536
    end)
    assert(reset:abort())
    local reads = 0
    uv.fs_read = function(...)
        reads = reads + 1
        return real_read(...)
    end
    local stalled = assert(H.raw_connect(port))
    assert(stalled.tcp:read_stop())
    assert(stalled:send(get("/huge.bin", port)))
    assert(
        steady(function()
            return reads
        end, 3000),
        "the stalled transfer held still within 3 s"
    )
    restore()
    assert(stalled:abort())
    settled()

    uv.fs_read = function(fd, size, offset, cb)
        if type(cb) ~= "function" then
            return real_read(fd, size, offset)
        end
        error("EIO: stubbed")
    end
    H.raw_request(port, get("/hello.txt", port))
    restore()
    assert(
        H.wait_for(function()
            return #notes > 0
        end, 1000),
        "the raise was reported within 1 s"
    )
    methods.shutdown = function(h, ...)
        if made[h] then
            return nil, "ENOTCONN: stubbed", "ENOTCONN"
        end
        return real_shutdown(h, ...)
    end
    H.raw_request(port, get("/missing.txt", port))
    H.raw_request(port, get("/hello.txt", port))
    restore()
    settled()
    eq(inst.open_conns, 0, "after one of each way a connection ends, no place is held")

    local tcps = H.handle_count("tcp")
    local waiting = assert(H.raw_connect(port))
    assert(
        H.wait_for(function()
            return H.handle_count("tcp") == tcps + 2
        end, 2000),
        "the server took the last connection within 2 s"
    )
    server.stop(inst)
    waiting:close()
    local accepted = vim.tbl_count(made)
    methods.close = real_close
    ok(
        raw == 0 and closes > 0,
        ("every close of an accepted socket comes through close_once (%d closes, %d not)"):format(closes, raw)
    )
    eq(closes, accepted, "and each of the " .. accepted .. " sockets the server accepted is closed once")
end)

-- update_target and enable_live on a stopped server opened a watcher
-- nothing closed (one fs_event more, measured), and the reload timer,
-- closed by the stop, then refused every start, so each change it saw
-- reloaded nothing and said nothing. A stopped server now opens nothing
-- and raises nothing.
H.case("Section 8: a stopped server's update_target and enable_live open nothing", function()
    local errs = #H.errors()
    local live = serve({ live = { enabled = true, debounce = 20, inject_script = false } })
    local off = serve()
    server.stop(live)
    server.stop(off)
    local watchers = H.handle_count("fs_event")
    local updated, update_err = pcall(server.update_target, live, root, nil)
    ok(updated, "update_target on a stopped server raises nothing: " .. tostring(update_err))
    eq(H.handle_count("fs_event"), watchers, "and opens no watcher")
    local enabled, got = pcall(server.enable_live, off, true)
    ok(enabled, "enable_live on a stopped server raises nothing: " .. tostring(got))
    eq(got, false, "and reports live reload off")
    eq(H.handle_count("fs_event"), watchers, "and opens no watcher")
    eq(server.is_live_enabled(live), false, "and a stopped server reports live reload off")
    eq(#H.errors(), errs, "and nothing raises in a callback")
end)

-- The reload timer's start returns nil and an error on a closing timer,
-- which no guard above can see from a watcher's callback, and the reload
-- was then dropped unreported. The first failure tells the user, once.
H.case("Section 8b: a reload timer that cannot start is reported once", function()
    local site = H.tmpdir()
    H.write_file(site .. "/index.html", "<html><body>live</body></html>")
    local errs = #H.errors()
    local inst = serve({ root = site, live = { enabled = true, debounce = 20, inject_script = false } })
    local real_timer = inst.debounce_timer
    local starts = 0
    inst.debounce_timer = {
        stop = function()
            return 0
        end,
        start = function()
            starts = starts + 1
            return nil, "EINVAL: stubbed"
        end,
    }
    local notes = {}
    local real_notify = vim.notify
    vim.notify = function(msg, level)
        table.insert(notes, { msg = msg, level = level })
    end
    H.defer(function()
        vim.notify = real_notify
        inst.debounce_timer = real_timer
    end)
    -- FSEvents delivered a fixture written just before the watcher started
    -- after it (measured), so the watcher settles first.
    vim.wait(300)
    H.write_file(site .. "/a.html", "a")
    ok(
        H.wait_for(function()
            return starts >= 1
        end, 2000),
        "a change reaches the reload timer"
    )
    vim.wait(300)
    H.write_file(site .. "/b.html", "b")
    ok(
        H.wait_for(function()
            return starts >= 2
        end, 2000),
        "and a second change reaches it again"
    )
    vim.wait(100)
    local warned = {}
    for _, n in ipairs(notes) do
        if n.msg:find("reload", 1, true) then
            table.insert(warned, n)
        end
    end
    eq(#warned, 1, "the failed start is reported once, not per change: " .. vim.inspect(notes))
    ok(
        warned[1] and warned[1].level == vim.log.levels.WARN and warned[1].msg:find("EINVAL: stubbed", 1, true) ~= nil,
        "as a warning naming the error"
    )
    eq(#H.errors(), errs, "and nothing raises")
end)

-- A watcher's start was read through a pcall that dropped its tuple, so a
-- failed start counted as success, a nil handle was kept as the watcher,
-- the per-directory fallback never ran and is_live_enabled reported live
-- reload on with nothing watching. A start asked for live reload raises
-- when the root cannot be watched; enable_live and update_target turn it
-- off and warn; a per-directory watch that fails for one directory warns
-- and keeps the rest.
H.case("Section 9: a watcher that cannot start refuses or warns, never reports live", function()
    local real_new = uv.new_fs_event
    local real_uname = uv.os_uname
    local real_scandir = uv.fs_scandir
    local real_notify = vim.notify
    local notes = {}
    vim.notify = function(msg, level)
        table.insert(notes, { msg = msg, level = level })
    end
    H.defer(function()
        uv.new_fs_event = real_new
        uv.os_uname = real_uname
        uv.fs_scandir = real_scandir
        vim.notify = real_notify
    end)
    -- "make" fails every new_fs_event; "start" hands back watchers whose
    -- start fails on dir, or on every path when dir is nil.
    local function stub(mode, dir)
        uv.new_fs_event = function()
            if mode == "make" then
                return nil, "EMFILE: stubbed", "EMFILE"
            end
            local h, err = real_new()
            if not h then
                return h, err
            end
            return setmetatable({}, {
                __index = function(_, name)
                    if name == "start" then
                        return function(_, path, ...)
                            if dir == nil or path == dir then
                                return nil, "ENOSPC: stubbed", "ENOSPC"
                            end
                            return h:start(path, ...)
                        end
                    end
                    return function(_, ...)
                        return h[name](h, ...)
                    end
                end,
            })
        end
    end
    local function unstub()
        uv.new_fs_event = real_new
    end
    local function counts()
        return { tcp = H.handle_count("tcp"), timer = H.handle_count("timer"), fs_event = H.handle_count("fs_event") }
    end
    -- The warnings scheduled since mark.
    local function warnings(mark)
        vim.wait(100)
        local got = {}
        for i = mark + 1, #notes do
            if notes[i].level == vim.log.levels.WARN then
                table.insert(got, notes[i].msg)
            end
        end
        return got
    end
    local site = H.tmpdir()
    H.write_file(site .. "/index.html", "<html><body>watched</body></html>")
    local live = { enabled = true, inject_script = false, debounce = 20 }

    for _, case in ipairs({ { "make", "EMFILE: stubbed" }, { "start", "ENOSPC: stubbed" } }) do
        local label = ("a root watcher that cannot %s"):format(case[1])
        local before = counts()
        stub(case[1])
        local started, res = pcall(server.start, { port = 0, root = site, live = live })
        unstub()
        local after = counts()
        if started then
            server.stop(res)
        end
        eq(
            not started and tostring(res) or "started",
            ("Failed to start live reload on %s: %s"):format(site, case[2]),
            label .. " refuses the start at level 0, naming the root and the cause"
        )
        ok(
            vim.deep_equal(after, before),
            ("%s leaves no socket, timer or watcher: %s against %s"):format(
                label,
                vim.inspect(after, { newline = " ", indent = "" }),
                vim.inspect(before, { newline = " ", indent = "" })
            )
        )
    end

    local mark = #notes
    local off = serve({ root = site, live = { enabled = false, inject_script = false } })
    local before = counts()
    stub("start")
    local enabled = server.enable_live(off, true)
    unstub()
    eq(enabled, false, "enable_live whose watcher cannot start returns false")
    eq(server.is_live_enabled(off), false, "and reports live reload off")
    ok(
        vim.deep_equal(counts(), before),
        "and holds no watcher: " .. vim.inspect(counts(), { newline = " ", indent = "" })
    )
    local warned = warnings(mark)
    ok(
        #warned == 1
            and warned[1]:find(("live-server: port %d cannot watch "):format(off.port), 1, true) == 1
            and warned[1]:find("ENOSPC: stubbed", 1, true) ~= nil,
        "and warns once, naming the port and the cause: " .. vim.inspect(warned)
    )
    eq(server.enable_live(off, true), true, "a later enable_live that can watch turns it on")
    eq(server.is_live_enabled(off), true, "and reports it on")

    mark = #notes
    before = counts()
    local on = serve({ root = site, live = live })
    ok(counts().fs_event > before.fs_event, "a live start on a plain root watches it")
    eq(server.is_live_enabled(on), true, "and reports live reload on")
    eq(#warnings(mark), 0, "and warns nothing")
    stub("start")
    local retargeted = server.update_target(on, site, nil)
    unstub()
    eq(retargeted, false, "update_target whose watcher cannot start returns false")
    eq(server.is_live_enabled(on), false, "and reports live reload off")
    eq(counts().fs_event, before.fs_event, "and holds no watcher")
    warned = warnings(mark)
    ok(
        #warned == 1
            and warned[1]:find(("live-server: port %d cannot watch "):format(on.port), 1, true) == 1
            and warned[1]:find("ENOSPC: stubbed", 1, true) ~= nil,
        "and warns once, naming the port and the cause: " .. vim.inspect(warned)
    )

    -- The per-directory watchers inotify needs, run here by reading the
    -- system as Linux.
    uv.os_uname = function()
        return { sysname = "Linux" }
    end
    local tree = H.tmpdir()
    vim.fn.mkdir(tree .. "/a", "p")
    vim.fn.mkdir(tree .. "/b", "p")
    H.write_file(tree .. "/a/x.html", "a")
    H.write_file(tree .. "/b/y.html", "b")
    local real_tree = assert(uv.fs_realpath(tree))
    mark = #notes
    before = counts()
    stub("start", real_tree .. "/a")
    local per = serve({ root = tree, live = live })
    unstub()
    eq(counts().fs_event - before.fs_event, 2, "a directory that cannot be watched is dropped, the rest kept")
    eq(server.is_live_enabled(per), true, "and live reload stays on")
    warned = warnings(mark)
    ok(
        #warned == 1
            and warned[1]
                == ("live-server: port %d cannot watch %s (ENOSPC: stubbed)"):format(per.port, real_tree .. "/a"),
        "and warns once, naming the directory and the cause: " .. vim.inspect(warned)
    )
    -- A directory that cannot be read was dropped with its whole subtree
    -- and no word.
    mark = #notes
    uv.fs_scandir = function(dir, ...)
        if dir == real_tree .. "/b" then
            return nil, "EACCES: stubbed", "EACCES"
        end
        return real_scandir(dir, ...)
    end
    local unread = serve({ root = tree, live = live })
    uv.fs_scandir = real_scandir
    warned = warnings(mark)
    ok(
        #warned == 1
            and warned[1]
                == ("live-server: port %d cannot watch the directories under %s (EACCES: stubbed)"):format(
                    unread.port,
                    real_tree .. "/b"
                ),
        "a directory that cannot be read warns once, naming it and the cause: " .. vim.inspect(warned)
    )
    eq(server.is_live_enabled(unread), true, "and live reload stays on")
end)

H.finish()
