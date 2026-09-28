-- tests/sse_test.lua
-- The event stream's heartbeat, and the end of a stream whose write
-- fails. Nothing was written to an idle stream, so a proxy's idle cut
-- ended it and a peer that vanished without a FIN stayed listed, holding
-- its place, for good. A comment line (": ping" and a blank line, which
-- EventSource and both pages ignore) now goes to every stream at
-- sse_heartbeat_ms, and to nothing else; 0 turns it off, stop closes its
-- timer, and a start that cannot arm it raises and leaves nothing open.
-- TCP gives up on a beat such a peer never acknowledges, and a stream
-- whose write then fails, a beat's or an event's, by write's return or
-- its callback, leaves the list and its socket closes, where the pcall
-- once around each write saw neither and left the stream listed.
--
-- Run: nvim --headless -u NONE -l "$PWD/tests/sse_test.lua"

local H = dofile(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "helpers.lua"))
H.isolate()
H.rtp()

local server = require("live_server.server")
local eq, ok = H.eq, H.ok
local uv = vim.uv

local root = H.tmpdir()
H.write_file(root .. "/index.html", "<html><body>ok</body></html>")

local PREAMBLE = "retry: 1000\n\n"
local BEAT = ": ping\n\n"

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

-- A raw client with its stream open and the preamble read; c.from is the
-- first byte after it.
local function open_stream(inst)
    local c = assert(H.raw_connect(inst.port))
    assert(c:send(("GET /__live/events HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n\r\n"):format(inst.port)))
    local data = c:read(2000, function(d)
        return d:find(PREAMBLE, 1, true) ~= nil
    end)
    local at = data:find(PREAMBLE, 1, true)
    assert(at, "the stream's preamble arrived within 2 s")
    c.from = at + #PREAMBLE
    return c
end

local function beats(s)
    local n, at = 0, 1
    while true do
        local found = s:find(BEAT, at, true)
        if not found then
            return n
        end
        n, at = n + 1, found + #BEAT
    end
end

-- Reads c until n beats arrived after byte from, within ms: the bytes
-- after from, and the milliseconds it took.
local function read_beats(c, from, n, ms)
    local t0 = uv.hrtime()
    local data = c:read(ms, function(d)
        return beats(d:sub(from)) >= n
    end)
    return data:sub(from), math.floor((uv.hrtime() - t0) / 1e6)
end

H.case("Section 1: an idle stream hears a heartbeat at its interval", function()
    local before = H.handle_count("timer")
    local inst = serve({ sse_heartbeat_ms = 100 })
    eq(H.handle_count("timer"), before + 2, "a server with a heartbeat holds two timers, the reload's and the beat's")
    local c = open_stream(inst)
    local rest, took = read_beats(c, c.from, 1, 2000)
    ok(
        beats(rest) >= 1 and took < 1000,
        ("an idle stream hears a beat within its interval, not the read's bound (%d ms)"):format(took)
    )
    eq(
        vim.inspect(rest:sub(1, #BEAT)),
        vim.inspect(BEAT),
        "the beat is a comment line and a blank line, the frame EventSource ignores"
    )
    local from = c.from + #rest
    local three
    rest, three = read_beats(c, from, 3, 2000)
    ok(
        beats(rest) >= 3 and three >= 150 and three < 1500,
        ("and hears one again at every interval: three beats in %d ms, at least two intervals"):format(three)
    )
    from = from + #rest
    server.send_event(inst, "tick", "{}")
    local after = c:read(2000, function(d)
        local s = d:sub(from)
        local at = s:find("event: tick\ndata: {}\n\n", 1, true)
        return at ~= nil and beats(s:sub(at)) >= 1
    end)
    local frames, strays = 0, {}
    for frame in after:sub(c.from):gmatch("(.-)\n\n") do
        frames = frames + 1
        if frame ~= ": ping" and frame ~= "event: tick\ndata: {}" then
            table.insert(strays, vim.inspect(frame))
        end
    end
    ok(
        after:sub(from):find("event: tick\ndata: {}\n\n", 1, true) ~= nil and frames >= 5 and #strays == 0,
        ("an event sent between beats arrives whole, and each of the %d frames is a beat or the event: %s"):format(
            frames,
            table.concat(strays, ", ")
        )
    )
    server.stop(inst)
    eq(H.handle_count("timer"), before, "stop closes the beat's timer with the reload's")
end)

H.case("Section 2: 0 turns the heartbeat off", function()
    local before = H.handle_count("timer")
    local inst = serve({ sse_heartbeat_ms = 0 })
    eq(H.handle_count("timer"), before + 1, "with 0 start makes no beat timer, the reload's alone")
    local c = open_stream(inst)
    local data = c:read(500)
    eq(beats(data:sub(c.from)), 0, "and an idle stream hears no beat in 500 ms")
end)

-- The default is read off the timer, since a row cannot wait 20 s.
H.case("Section 3: by default the beat comes every 20 s", function()
    local inst = serve()
    local beat = inst.heartbeat_timer
    ok(beat ~= nil and not beat:is_closing(), "by default start arms a beat")
    eq(beat and beat:get_repeat(), 20000, "and it repeats every 20 s")
    local due = beat and beat:get_due_in()
    ok(
        due ~= nil and due > 19000 and due <= 20000,
        ("and the first is due 20 s after start (in %s ms)"):format(tostring(due))
    )
end)

-- A stream leaves the list when its client ends or resets it, so a beat
-- after that finds it gone; a connection that is no event stream is
-- never written one.
H.case("Section 4: a client that left before the beat is not written to", function()
    local inst = serve({ sse_heartbeat_ms = 100, header_timeout_ms = 0 })
    local function listed(n)
        return H.wait_for(function()
            return server.connected_client_count(inst) == n
        end, 2000)
    end
    local ended = open_stream(inst)
    assert(listed(1), "the first stream was listed within 2 s")
    local ended_sock = inst.sse_clients[1]
    local reset = open_stream(inst)
    assert(listed(2), "the second stream was listed within 2 s")
    local reset_sock = inst.sse_clients[2]
    local kept = open_stream(inst)
    assert(listed(3), "the third stream was listed within 2 s")
    local idle = assert(H.raw_connect(inst.port))
    local errs = #H.errors()
    local methods = getmetatable(inst.handle).__index
    local real_write = methods.write
    H.defer(function()
        methods.write = real_write
    end)
    ended:close()
    assert(reset:abort())
    ok(listed(1), "the streams whose clients left, by an end and by a reset, leave the list")
    local gone = 0
    methods.write = function(h, ...)
        if h == ended_sock or h == reset_sock then
            gone = gone + 1
        end
        return real_write(h, ...)
    end
    local from = #kept:read(0) + 1
    local rest = read_beats(kept, from, 2, 2000)
    methods.write = real_write
    ok(beats(rest) >= 2, "the beats after it reach the stream still open")
    eq(gone, 0, "and write nothing to the two that left")
    eq(vim.inspect(idle:read(0)), vim.inspect(""), "a connection that is no event stream hears no beat")
    eq(#H.errors(), errs, "and nothing raises")
end)

-- A timer luv cannot make or start returns nil and an error, which read
-- nowhere left a server whose streams never hear a beat. Start makes the
-- reload's timer first, so the made stub lets that one through and
-- refuses the beat's.
H.case("Section 5: a start that cannot arm its beat raises, naming it, and leaves nothing open", function()
    local real_new_timer = uv.new_timer
    local probe = assert(real_new_timer())
    local timer_methods = getmetatable(probe).__index
    probe:close()
    local real_start = timer_methods.start
    H.defer(function()
        uv.new_timer, timer_methods.start = real_new_timer, real_start
    end)
    local stubs = {
        {
            "made",
            function()
                local calls = 0
                uv.new_timer = function(...)
                    calls = calls + 1
                    if calls == 1 then
                        return real_new_timer(...)
                    end
                    return nil, "ENOMEM: stubbed", "ENOMEM"
                end
            end,
            "ENOMEM: stubbed",
        },
        {
            "started",
            function()
                timer_methods.start = function()
                    return nil, "EINVAL: stubbed", "EINVAL"
                end
            end,
            "EINVAL: stubbed",
        },
    }
    for _, s in ipairs(stubs) do
        local what, stub, says = s[1], s[2], s[3]
        local tcps, timers = H.handle_count("tcp"), H.handle_count("timer")
        stub()
        local started, res = pcall(server.start, {
            port = 0,
            root = root,
            live = { enabled = false },
            sse_heartbeat_ms = 100,
        })
        uv.new_timer, timer_methods.start = real_new_timer, real_start
        if started then
            server.stop(res)
        end
        ok(
            not started
                and tostring(res):find("sse_heartbeat_ms", 1, true) ~= nil
                and tostring(res):find(says, 1, true) ~= nil
                and not tostring(res):find("%.lua:%d+: "),
            ("a start whose beat cannot be %s raises at level 0, naming sse_heartbeat_ms and %s: %s"):format(
                what,
                says,
                tostring(res)
            )
        )
        eq(H.handle_count("tcp"), tcps, ("and leaves no socket when the beat cannot be %s"):format(what))
        eq(H.handle_count("timer"), timers, ("and no timer when the beat cannot be %s"):format(what))
    end
end)

local function listed(inst, n)
    return H.wait_for(function()
        return server.connected_client_count(inst) == n
    end, 2000)
end

-- A write that fails ends a stream as surely as a read that reports its
-- end. luv reports a failed write without raising, by write's return on
-- a closed or shut socket and by its callback after a reset (EPIPE on
-- macOS, where Linux may say ECONNRESET), and the pcall around each
-- write read neither: the read path, never stopped on a stream, dropped
-- a reset or closed peer on its own (measured), so the write's error was
-- unread rather than a held place, and a raise in a write was swallowed.
H.case("Section 6: a stream whose write fails leaves the list", function()
    local inst = serve({ sse_heartbeat_ms = 0 })
    local c = open_stream(inst)
    ok(
        H.wait_for(function()
            return server.connected_client_count(inst) == 1
        end, 1000),
        "the stream is listed"
    )
    -- Stop reading on the server's side, so only the write path can see
    -- the peer go (the read path is Section 1 of request_test).
    local gone = inst.sse_clients[1]
    assert(gone:read_stop())
    c:close()
    vim.wait(100)
    server.send_event(inst, "a", "{}")
    vim.wait(100)
    server.send_event(inst, "b", "{}")
    ok(
        H.wait_for(function()
            return server.connected_client_count(inst) == 0
        end, 1000),
        "a peer that left is dropped when a write reports it"
    )
    ok(
        gone:is_closing() and inst.open_conns == 0,
        ("and its socket is closed, which frees its place (%d held, want 0)"):format(inst.open_conns)
    )
    local before = server.connected_client_count(inst)
    open_stream(inst)
    ok(
        H.wait_for(function()
            return server.connected_client_count(inst) == before + 1
        end, 1000),
        "a new stream is listed"
    )
    inst.sse_clients[#inst.sse_clients]:close()
    server.send_event(inst, "c", "{}")
    eq(server.connected_client_count(inst), before, "a closed socket still listed is dropped by write's fail tuple")
end)

-- With no event sent, the beat is the write that finds such a peer.
H.case("Section 6b: a beat whose write fails drops its stream and closes its socket", function()
    local inst = serve({ sse_heartbeat_ms = 100 })
    local reset = open_stream(inst)
    assert(listed(inst, 1), "the first stream was listed within 2 s")
    local gone = inst.sse_clients[1]
    local kept = open_stream(inst)
    assert(listed(inst, 2), "the second stream was listed within 2 s")
    local errs = #H.errors()
    assert(gone:read_stop())
    assert(reset:abort())
    ok(
        H.wait_for(function()
            return server.connected_client_count(inst) == 1 and inst.sse_clients[1] ~= gone
        end, 2000),
        "a peer that reset is dropped at the next beat"
    )
    ok(
        gone:is_closing() and inst.open_conns == 1,
        ("and its socket is closed, which frees its place (%d held, want 1)"):format(inst.open_conns)
    )
    local from = #kept:read(0) + 1
    ok(beats((read_beats(kept, from, 2, 2000))) >= 2, "the stream still open keeps hearing the beat")
    eq(#H.errors(), errs, "and nothing raises")
end)

-- write returns nil and an error at once on a socket shut for writing, so
-- the stream leaves during the send, which goes on to the streams listed
-- after it.
H.case("Section 6c: a write that fails at once drops its stream during the send", function()
    local inst = serve({ sse_heartbeat_ms = 0 })
    local socks, clients = {}, {}
    for i = 1, 3 do
        clients[i] = open_stream(inst)
        assert(listed(inst, i), ("stream %d was listed within 2 s"):format(i))
        socks[i] = inst.sse_clients[i]
    end
    for i = 1, 2 do
        assert(socks[i]:read_stop())
        assert(socks[i]:shutdown())
    end
    server.send_event(inst, "d", "{}")
    eq(server.connected_client_count(inst), 1, "two streams whose writes fail at once both leave in one send")
    ok(
        socks[1]:is_closing() and socks[2]:is_closing() and inst.open_conns == 1,
        ("and their sockets are closed, which frees their places (%d held, want 1)"):format(inst.open_conns)
    )
    local frame = "event: d\ndata: {}\n\n"
    local got = clients[3]:read(2000, function(d)
        return d:find(frame, clients[3].from, true) ~= nil
    end)
    ok(
        vim.tbl_contains(inst.sse_clients, socks[3]) and got:find(frame, clients[3].from, true) ~= nil,
        "and the send reaches the stream listed after them, which stays listed"
    )
end)

-- luv raises on a write only for a bad argument, a fault in the server's
-- own code, which the pcall took for a dead stream and hid.
H.case("Section 6d: a write that raises is a fault its caller hears", function()
    local inst = serve({ sse_heartbeat_ms = 0 })
    open_stream(inst)
    assert(listed(inst, 1), "the stream was listed within 2 s")
    local target = inst.sse_clients[1]
    local methods = getmetatable(target).__index
    local real_write = methods.write
    H.defer(function()
        methods.write = real_write
    end)
    methods.write = function(h, ...)
        if h == target then
            error("bad argument: stubbed")
        end
        return real_write(h, ...)
    end
    local sent, err = pcall(server.send_event, inst, "e", "{}")
    methods.write = real_write
    ok(
        not sent and tostring(err):find("bad argument: stubbed", 1, true) ~= nil,
        ("a write that raises reaches send_event's caller: %s"):format(tostring(err))
    )
end)

-- Stop closes a stream whose writes are still queued, and each one's
-- callback then reports ECANCELED for a stream already gone from the list
-- and a socket already closing.
H.case("Section 6e: the writes stop cancels raise nothing", function()
    local inst = serve({ sse_heartbeat_ms = 0 })
    local c = open_stream(inst)
    assert(listed(inst, 1), "the stream was listed within 2 s")
    local sock = inst.sse_clients[1]
    local methods = getmetatable(sock).__index
    local real_write = methods.write
    H.defer(function()
        methods.write = real_write
    end)
    local cancelled, other = 0, {}
    methods.write = function(h, data, cb)
        if h ~= sock then
            return real_write(h, data, cb)
        end
        return real_write(h, data, function(err)
            if err == "ECANCELED" then
                cancelled = cancelled + 1
            elseif err then
                table.insert(other, tostring(err))
            end
            if cb then
                cb(err)
            end
        end)
    end
    -- The client stops reading, so the frames fill both ends' buffers and
    -- the rest wait in the server's write queue. macOS grows both buffers
    -- to 4 MiB, so the queue is read with no loop turn before stop: with
    -- one between them, a floor run found every write done and none to
    -- cancel.
    local errs = #H.errors()
    assert(c.tcp:read_stop())
    local big = string.rep("x", 1024 * 1024)
    local sends = 0
    while sock:get_write_queue_size() == 0 and sends < 64 do
        server.send_event(inst, "big", big)
        sends = sends + 1
    end
    server.send_event(inst, "big", big)
    local queued = sock:get_write_queue_size()
    assert(queued > 0, "a write was left queued within 64 MiB")
    server.stop(inst)
    H.wait_for(function()
        return cancelled > 0
    end, 1000)
    methods.write = real_write
    ok(
        cancelled > 0 and #other == 0,
        ("stop cancels the writes still queued (%d bytes; %d ECANCELED, others: %s)"):format(
            queued,
            cancelled,
            table.concat(other, ", ")
        )
    )
    eq(#H.errors(), errs, "and their callbacks raise nothing")
end)

H.finish()
