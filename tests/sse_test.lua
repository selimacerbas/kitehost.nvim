-- tests/sse_test.lua
-- The event stream's heartbeat. Nothing was written to an idle stream, so
-- a proxy's idle cut ended it and a peer that vanished without a FIN
-- stayed listed, holding its place, for good. A comment line (": ping"
-- and a blank line, which EventSource and both pages ignore) now goes to
-- every stream at sse_heartbeat_ms, and to nothing else; 0 turns it off,
-- stop closes its timer, and a start that cannot arm it raises and leaves
-- nothing open.
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
-- nowhere left a server whose streams never hear a beat.
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
                uv.new_timer = function()
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
                and tostring(res):find(says, 1, true) ~= nil,
            ("a start whose beat cannot be %s raises, naming sse_heartbeat_ms and %s: %s"):format(
                what,
                says,
                tostring(res)
            )
        )
        eq(H.handle_count("tcp"), tcps, ("and leaves no socket when the beat cannot be %s"):format(what))
        eq(H.handle_count("timer"), timers, ("and no timer when the beat cannot be %s"):format(what))
    end
end)

H.finish()
