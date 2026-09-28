-- tests/sse_test.lua
-- The event stream's heartbeat, and the end of a stream whose write
-- fails or that falls behind. Nothing was written to an idle stream, so
-- a proxy's idle cut ended it and a peer that vanished without a FIN
-- stayed listed, holding its place, for good. A comment line (": ping"
-- and a blank line, which EventSource and both pages ignore) now goes to
-- every stream at sse_heartbeat_ms, and to nothing else; 0 turns it off,
-- stop closes its timer, and a start that cannot arm it raises and
-- leaves nothing open.
-- TCP gives up on a beat such a peer never acknowledges, and a stream
-- whose write then fails, a beat's or an event's, by write's return or
-- its callback, leaves the list and its socket closes, where the pcall
-- once around each write saw neither and left the stream listed. A
-- reader that stops reading without closing raises no error at all, and
-- its write queue grew with every frame; a stream more than 1 MiB behind
-- for longer than a second, or more than 8 MiB behind at all, now leaves
-- the same way, the heartbeat's send judging it too, and one that keeps
-- up stays through a large frame or a burst that stays within 8 MiB; a
-- stream whose head or retry line fails is never kept. A reload's data
-- is JSON a decoder reads whatever the path holds, its keys in one order
-- on every process.
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
    ok(listed(inst, 1), "the stream is listed")
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
    local before, held_before = server.connected_client_count(inst), inst.open_conns
    open_stream(inst)
    ok(listed(inst, before + 1), "a new stream is listed")
    -- Shut, as 6c does, never closed raw: a raw close skips close_once,
    -- whose hook frees the socket's place, so the place would stay held.
    local last = inst.sse_clients[#inst.sse_clients]
    assert(last:read_stop())
    assert(last:shutdown())
    server.send_event(inst, "c", "{}")
    ok(
        server.connected_client_count(inst) == before
            and H.wait_for(function()
                return inst.open_conns == held_before
            end, 1000),
        ("a shut socket still listed is dropped by write's fail tuple, and its place frees (%d held, want %d)"):format(
            inst.open_conns,
            held_before
        )
    )
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

-- The server's bounds on a stream that falls behind, restated here since
-- they are local to it.
local CAP, STALL_MS, HARD = 1024 * 1024, 1000, 8 * 1024 * 1024
local CHUNK = string.rep("x", 65536)
local FRAME = ("event: big\ndata: %s\n\n"):format(CHUNK)

-- The bytes a raw client holds past its preamble, counted without
-- joining them.
local function received(c)
    local n = 0
    for _, s in ipairs(c.chunks) do
        n = n + #s
    end
    return n - (c.from - 1)
end

-- Runs fn in one timer callback, a turn of the loop in which no stream
-- drains, as an editor's timer or autocmd sends; a raise in fn is raised
-- again here, where the case hears it.
local function in_one_turn(fn)
    local t = assert(uv.new_timer())
    local res
    assert(t:start(0, 0, function()
        t:close()
        res = { pcall(fn) }
    end))
    assert(
        H.wait_for(function()
            return res ~= nil
        end, 2000),
        "the timer ran within 2 s"
    )
    if not res[1] then
        error(res[2], 0)
    end
end

-- Sends 64 KiB frames in one turn while sock is listed and its queue is
-- at most upto, at most max of them: how many went, and the turn's loop
-- time.
local function fill(inst, sock, upto, max)
    local sent, at = 0, nil
    in_one_turn(function()
        while sent < max and vim.tbl_contains(inst.sse_clients, sock) and sock:get_write_queue_size() <= upto do
            server.send_event(inst, "big", CHUNK)
            sent = sent + 1
        end
        at = uv.now()
    end)
    return sent, at
end

-- Spies on sock's close: how often it ran, and at the first the bytes
-- still queued and the loop time.
local function watch_close(sock)
    local methods = getmetatable(sock).__index
    local real_close = methods.close
    H.defer(function()
        methods.close = real_close
    end)
    local seen = { closes = 0 }
    methods.close = function(h, ...)
        if h == sock then
            seen.closes = seen.closes + 1
            if seen.closes == 1 then
                seen.held, seen.at = h:get_write_queue_size(), uv.now()
            end
        end
        return real_close(h, ...)
    end
    return seen
end

-- Starts a raw client reading again after read_stop, into its chunks as
-- H.raw_connect's reader does.
local function resume(c)
    assert(c.tcp:read_start(function(e, chunk)
        if chunk then
            table.insert(c.chunks, chunk)
        else
            c.eof, c.err = true, e
        end
    end))
end

-- A reader that stops reading and never closes raises no error on either
-- path: once both ends' buffers are full, every frame waited in the
-- server's write queue, which grew for as long as the stream stayed open
-- (7.85 MB after 128 events of 64 KiB, measured). A stream whose queue
-- has stayed over 1 MiB for longer than a second is now dropped at its
-- next send, as a dead one is, so what a stalled reader holds is bounded
-- by the grace (and by 8 MiB, Section 7c). The sends go on until the
-- drop, since a kernel that takes more of a stalled stream than macOS
-- does crosses the cap later.
H.case("Section 7: a reader behind for longer than the grace is dropped, a reading one is not", function()
    local inst = serve({ sse_heartbeat_ms = 0 })
    local stalled = open_stream(inst)
    local reading = open_stream(inst)
    ok(listed(inst, 2), "both streams are listed")
    local stalled_sock, reading_sock = inst.sse_clients[1], inst.sse_clients[2]
    local closed = watch_close(stalled_sock)
    local errs = #H.errors()
    -- A reader that neither reads nor closes: no error ever surfaces.
    assert(stalled.tcp:read_stop())
    -- The queue is read before each send, in the same turn and at the
    -- same loop time as the server's own read.
    local sent, over_at = 0, nil
    while sent < 400 and vim.tbl_contains(inst.sse_clients, stalled_sock) do
        if not over_at and stalled_sock:get_write_queue_size() > CAP then
            over_at = uv.now()
        end
        server.send_event(inst, "big", CHUNK)
        sent = sent + 1
        vim.wait(20)
    end
    ok(listed(inst, 1), ("the stalled reader is dropped (after %d sends)"):format(sent))
    ok(inst.sse_clients[1] == reading_sock, "and the stream still listed is the reading one")
    ok(
        closed.closes == 1 and inst.open_conns == 1,
        ("and the stalled one's socket is closed once, which frees its place (%d closes, %d held, want 1 and 1)"):format(
            closed.closes,
            inst.open_conns
        )
    )
    ok(
        closed.held ~= nil and closed.held > CAP and closed.held <= HARD,
        ("it was dropped more than 1 MiB behind and under the 8 MiB ceiling (%s bytes queued)"):format(
            tostring(closed.held)
        )
    )
    local waited = closed.at and over_at and closed.at - over_at
    ok(
        waited ~= nil and waited > STALL_MS and waited < STALL_MS + 500,
        ("once its queue had stayed over 1 MiB for the grace, 1 s, and within half a second more (%s ms)"):format(
            tostring(waited)
        )
    )
    local want = sent * #FRAME
    H.wait_for(function()
        return received(reading) >= want
    end, 3000)
    ok(
        reading:read(0):sub(reading.from) == FRAME:rep(sent),
        ("the reading stream hears all %d events whole (%d of %d bytes)"):format(sent, received(reading), want)
    )
    -- A frame larger than the cap drops no reader that keeps up: macOS
    -- takes 0.3 to 1.6 MB of one at once (measured, with curl too), and
    -- the rest drains from the queue well within the grace.
    local payload = string.rep("y", 8 * 1024 * 1024)
    local huge = ("event: huge\ndata: %s\n\n"):format(payload)
    local after = "event: after\ndata: {}\n\n"
    server.send_event(inst, "huge", payload)
    H.wait_for(function()
        return received(reading) >= want + #huge
    end, 3000)
    server.send_event(inst, "after", "{}")
    H.wait_for(function()
        return received(reading) >= want + #huge + #after
    end, 2000)
    ok(
        reading:read(0):sub(reading.from + want) == huge .. after and vim.tbl_contains(inst.sse_clients, reading_sock),
        "a reading stream hears an event larger than the cap whole, and the next, and stays listed"
    )
    eq(#H.errors(), errs, "and nothing raises")
end)

-- A queue read at each send judged what the last frame left behind, so a
-- reader that keeps up was dropped, with a cut frame and an end, when a
-- second frame came before a 3 MiB one drained or within a burst of
-- 64 KiB frames (measured with curl too). No stream drains within one
-- turn of the loop, and a turn takes no loop time, so the grace holds
-- through one.
H.case("Section 7b: a reader that keeps up is not dropped for a frame or a burst within 8 MiB", function()
    local function keeps_up(sends)
        local inst = serve({ sse_heartbeat_ms = 0 })
        local c = open_stream(inst)
        assert(listed(inst, 1), "the stream was listed within 2 s")
        local sock = inst.sse_clients[1]
        local want = {}
        for i, s in ipairs(sends) do
            want[i] = ("event: %s\ndata: %s\n\n"):format(s[1], s[2])
        end
        want = table.concat(want)
        in_one_turn(function()
            for _, s in ipairs(sends) do
                server.send_event(inst, s[1], s[2])
            end
        end)
        H.wait_for(function()
            return c.eof or received(c) >= #want
        end, 5000)
        return vim.tbl_contains(inst.sse_clients, sock) and c:read(0):sub(c.from) == want, received(c), #want
    end
    local errs = #H.errors()
    local kept, got, want = keeps_up({ { "big", string.rep("z", 3 * 1024 * 1024) }, { "after", "{}" } })
    ok(
        kept,
        ("a reading stream sent a 3 MiB frame and a small one in one turn stays listed and hears both whole (%d of %d bytes)"):format(
            got,
            want
        )
    )
    local burst = {}
    for i = 1, 40 do
        burst[i] = { "big", CHUNK }
    end
    kept, got, want = keeps_up(burst)
    ok(
        kept,
        ("a reading stream sent 40 frames of 64 KiB in one turn stays listed and hears all whole (%d of %d bytes)"):format(
            got,
            want
        )
    )
    eq(#H.errors(), errs, "and nothing raises")
end)

-- No loop time passes within one turn, so the grace never ends there:
-- the ceiling alone bounds a stalled reader under a burst.
H.case("Section 7c: a stream more than 8 MiB behind is dropped at once", function()
    local inst = serve({ sse_heartbeat_ms = 0 })
    local stalled = open_stream(inst)
    assert(listed(inst, 1), "the stream was listed within 2 s")
    local sock = inst.sse_clients[1]
    local closed = watch_close(sock)
    local errs = #H.errors()
    assert(stalled.tcp:read_stop())
    local sent = fill(inst, sock, math.huge, 400)
    ok(
        not vim.tbl_contains(inst.sse_clients, sock),
        ("a stalled reader under a burst in one turn is dropped within it (after %d sends)"):format(sent)
    )
    ok(
        closed.closes == 1 and inst.open_conns == 0,
        ("and its socket is closed once, which frees its place (%d closes, %d held, want 1 and 0)"):format(
            closed.closes,
            inst.open_conns
        )
    )
    ok(
        closed.held ~= nil and closed.held > HARD and closed.held <= HARD + #FRAME,
        ("it was dropped more than 8 MiB behind, and at most one frame more (%s bytes queued)"):format(
            tostring(closed.held)
        )
    )
    eq(#H.errors(), errs, "and nothing raises")
end)

-- With nothing else sent the beat is the send that judges a stream, so a
-- stalled reader is found within the grace and one interval.
H.case("Section 7d: the heartbeat alone drops a stalled reader after the grace", function()
    local inst = serve({ sse_heartbeat_ms = 100 })
    local stalled = open_stream(inst)
    assert(listed(inst, 1), "the stream was listed within 2 s")
    local sock = inst.sse_clients[1]
    local closed = watch_close(sock)
    local errs = #H.errors()
    assert(stalled.tcp:read_stop())
    local _, fell_at = fill(inst, sock, 2 * CAP, 256)
    ok(
        vim.tbl_contains(inst.sse_clients, sock) and sock:get_write_queue_size() > CAP,
        "a turn of events leaves a stalled reader more than 1 MiB behind and still listed"
    )
    H.wait_for(function()
        return closed.closes > 0
    end, 3000)
    local waited = closed.at and closed.at - fell_at
    ok(
        waited ~= nil and waited > STALL_MS and waited < STALL_MS + 100 + 400,
        ("the beats alone drop it once it has stayed behind for the grace, within an interval more (%s ms)"):format(
            tostring(waited)
        )
    )
    ok(
        closed.closes == 1 and inst.open_conns == 0 and server.connected_client_count(inst) == 0,
        ("and its socket is closed once, which frees its place (%d closes, %d held, want 1 and 0)"):format(
            closed.closes,
            inst.open_conns
        )
    )
    eq(#H.errors(), errs, "and nothing raises")
end)

-- A stream judged over the cap that then drains is judged afresh: its
-- time over the cap starts again at the next send that finds it behind,
-- so a large frame and a small one after the grace drop no reader that
-- stalled once.
H.case("Section 7e: a reader that resumes within the grace stays", function()
    local inst = serve({ sse_heartbeat_ms = 0 })
    local c = open_stream(inst)
    assert(listed(inst, 1), "the stream was listed within 2 s")
    local sock = inst.sse_clients[1]
    local errs = #H.errors()
    assert(c.tcp:read_stop())
    local sent, fell_at = fill(inst, sock, 2 * CAP, 256)
    vim.wait(300)
    resume(c)
    local early = FRAME:rep(sent)
    H.wait_for(function()
        return received(c) >= #early
    end, 3000)
    vim.wait(math.max(0, fell_at + STALL_MS + 200 - uv.now()))
    local big = string.rep("z", 3 * 1024 * 1024)
    local pair = ("event: big\ndata: %s\n\nevent: after\ndata: {}\n\n"):format(big)
    in_one_turn(function()
        server.send_event(inst, "big", big)
        server.send_event(inst, "after", "{}")
    end)
    H.wait_for(function()
        return c.eof or received(c) >= #early + #pair
    end, 5000)
    ok(
        vim.tbl_contains(inst.sse_clients, sock),
        "a reader that fell more than 1 MiB behind and resumed within the grace stays listed, through a 3 MiB frame and a small one in one turn after it"
    )
    ok(
        c:read(0):sub(c.from) == early .. pair,
        ("and hears every frame whole, those sent while it stalled and after (%d of %d bytes)"):format(
            received(c),
            #early + #pair
        )
    )
    eq(#H.errors(), errs, "and nothing raises")
end)

-- A stream's head and its retry line are its first writes, made before
-- it is listed. A closed or shut socket fails them at once, and a peer
-- that resets right after its request can fail them on their callbacks
-- (EPIPE); neither was read, so a stream whose head never went out was
-- listed and written to. Such a stream now ends as one whose frame fails
-- does: one that fails at once is never listed, one whose callback
-- reports it leaves the list, and its socket closes either way.
H.case("Section 8: a stream whose first writes fail is not kept", function()
    local inst = serve({ sse_heartbeat_ms = 0 })
    local methods = getmetatable(inst.handle).__index
    local real_write = methods.write
    H.defer(function()
        methods.write = real_write
    end)
    local function head(data)
        return data:find("^HTTP/1%.1 200 ") ~= nil and data:find("text/event-stream", 1, true) ~= nil
    end
    local function retry(data)
        return data == PREAMBLE
    end
    local function at_once()
        return nil, "EBADF: stubbed", "EBADF"
    end
    local function on_callback(h, data, cb)
        return real_write(h, data, function()
            if cb then
                cb("EPIPE: stubbed")
            end
        end)
    end
    local errs = #H.errors()
    for _, s in ipairs({
        { "head fails at once", head, at_once },
        { "retry line fails at once", retry, at_once },
        { "head's callback reports an error", head, on_callback },
        { "retry line's callback reports an error", retry, on_callback },
    }) do
        local what, match, fail = s[1], s[2], s[3]
        methods.write = function(h, data, cb)
            if type(data) ~= "string" or not match(data) then
                return real_write(h, data, cb)
            end
            methods.write = real_write
            return fail(h, data, cb)
        end
        local c = assert(H.raw_connect(inst.port))
        assert(c:send(("GET /__live/events HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n\r\n"):format(inst.port)))
        local data, eof = c:read(2000)
        methods.write = real_write
        ok(eof and server.connected_client_count(inst) == 0, ("a stream whose %s is ended and not listed"):format(what))
        ok(
            H.wait_for(function()
                return inst.open_conns == 0
            end, 1000),
            ("and its socket is closed, which frees its place (%d held, want 0)"):format(inst.open_conns)
        )
        if match == head and fail == at_once then
            eq(vim.inspect(data), vim.inspect(""), "and nothing follows the head that failed, the retry line included")
        end
        c:close()
    end
    eq(#H.errors(), errs, "and nothing raises")
end)

-- The reload event's data was Lua's %q quoting, which wrote a tab as \9
-- and split a newline over two data lines, neither of which JSON.parse
-- reads, so a page fell back to a full reload for a stylesheet (measured).
-- It is JSON a decoder reads, whatever the path holds, and its keys come
-- in one order on every process: an encoded table's order is the hash's,
-- which differs between processes (measured), so a reader comparing
-- bytes saw a payload change with nothing changed.
H.case("Section 9: a reload payload is JSON whatever the path holds", function()
    local inst = serve({ sse_heartbeat_ms = 0 })
    local c = open_stream(inst)
    local paths = { "a\nb.html", "tab\tx.css", 'q"uote.html', "sub/dir/page.html", "back\\slash.css" }
    for _, p in ipairs(paths) do
        server.reload(inst, p)
    end
    local data = c:read(2000, function(d)
        return select(2, d:sub(c.from):gsub("event: reload\n", "")) >= #paths
    end)
    local got, frames = {}, 0
    for frame in data:sub(c.from):gmatch("(.-)\n\n") do
        local payload = frame:match("^event: reload\ndata: ([^\n]*)$")
        frames = frames + (payload and 1 or 0)
        local decoded, obj = pcall(vim.json.decode, payload or "")
        table.insert(got, decoded and type(obj) == "table" and obj or {})
    end
    eq(frames, #paths, "each reload is a frame of one data line")
    eq(got[1].path, "a\nb.html", "a newline in the path survives")
    eq(got[2].path, "tab\tx.css", "a tab survives")
    eq(got[2].css, true, "a .css path still marks css")
    eq(got[3].path, 'q"uote.html', "a quote survives")
    eq(got[3].css, false, "and a page's css is false, a boolean")
    eq(got[4].path, "sub/dir/page.html", "a slash survives, escaped or not")
    eq(got[5].path, "back\\slash.css", "a backslash survives")
    ok(
        type(got[1].ts) == "number" and math.abs(got[1].ts - os.time()) <= 5,
        "ts is the time in seconds: " .. tostring(got[1].ts)
    )
end)

-- Each child process starts the module and reloads through a stand-in
-- stream, so the frame is the one a socket would carry, and prints it.
H.case("Section 9b: the payload's bytes are the same on every process", function()
    local script = H.tmpdir() .. "/reload_frame.lua"
    H.write_file(
        script,
        table.concat({
            "vim.opt.runtimepath:prepend(_G.arg[1])",
            "local server = require('live_server.server')",
            "os.time = function() return 1700000000 end",
            "local frame",
            "local stream = {",
            "    get_write_queue_size = function() return 0 end,",
            "    write = function(_, text) frame = text return true end,",
            "}",
            "server.reload({ sse_clients = { stream }, css_inject = true }, 'sub/style.css')",
            "io.stdout:write(frame or 'no frame')",
        }, "\n")
    )
    local frames = {}
    for i = 1, 4 do
        local res = vim.system(
            { vim.v.progpath, "--headless", "-u", "NONE", "-l", script, H.root },
            { text = true, timeout = 8000 }
        ):wait()
        frames[i] = H.exit_code(res) == 0 and res.stdout or ("exit " .. H.exit_code(res) .. ": " .. (res.stderr or ""))
    end
    local payload = frames[1]:match("^event: reload\ndata: ([^\n]*)\n\n$") or ""
    local decoded, obj = pcall(vim.json.decode, payload)
    ok(
        decoded and type(obj) == "table" and obj.ts == 1700000000 and obj.path == "sub/style.css" and obj.css == true,
        "a child's frame decodes to its fields: " .. vim.inspect(frames[1])
    )
    local ts_at, path_at, css_at =
        payload:find('"ts":', 1, true), payload:find('"path":', 1, true), payload:find('"css":', 1, true)
    ok(
        ts_at == 2 and path_at and css_at and ts_at < path_at and path_at < css_at,
        "its keys come as ts, path, css: " .. payload
    )
    for i = 2, #frames do
        eq(vim.inspect(frames[i]), vim.inspect(frames[1]), ("child %d's frame is child 1's, byte for byte"):format(i))
    end
end)

H.finish()
