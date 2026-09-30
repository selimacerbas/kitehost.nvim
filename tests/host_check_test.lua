-- tests/host_check_test.lua
-- A DNS-rebinding page reaches a loopback bind under its own name, so a
-- loopback bind answers only the names this machine alone answers to, and
-- 421 for any other, before the token gate and any dispatch. Network binds
-- are reached by LAN, mDNS and Tailscale names; the token gates them.
--
-- Run: nvim --headless -u NONE -l "$PWD/tests/host_check_test.lua"

local H = dofile(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "helpers.lua"))
H.isolate()
H.rtp()

local server = require("live_server.server")
local eq, ok, http_get = H.eq, H.ok, H.http_get

local root = H.tmpdir()
vim.fn.mkdir(root .. "/assets", "p")
H.write_file(root .. "/index.html", "<html><body>ok</body></html>")
H.write_file(root .. "/content.md", "# secret")
H.write_file(root .. "/assets/pic.png", "PNGDATA")

local TOKEN = "tok"
local function serve(cfg)
    local inst = server.start(vim.tbl_extend("keep", cfg or {}, {
        port = 0,
        root = root,
        default_index = root .. "/index.html",
        token = TOKEN,
        protected_paths = { "^/content%.md$" },
        asset_root = root .. "/assets",
        live = { enabled = false, inject_script = false },
        features = { dirlist = { enabled = false } },
    }))
    H.defer(function()
        server.stop(inst)
    end)
    return inst
end

-- curl's -H replaces the Host it would send (measured).
local function status(port, path, host)
    return http_get(("http://127.0.0.1:%d%s"):format(port, path), host and { "Host: " .. host } or nil).status
end

local function raw_status(port, bytes)
    local r = H.response(assert(H.raw_request(port, bytes)))
    return r.status, r.reason
end

H.case("Section 1: a loopback bind answers only loopback names", function()
    local inst = serve()
    local port = inst.port
    eq(server.features.host_check, true, "features.host_check says the check exists")
    eq(status(port, "/", "attacker.example"), 421, "a foreign Host is 421")
    eq(status(port, "/", "attacker.example:" .. port), 421, "a foreign Host with this port is 421")
    local _, reason = raw_status(port, "GET / HTTP/1.1\r\nHost: attacker.example\r\n\r\n")
    eq(reason, "Misdirected Request", "the 421 names its reason phrase")
    ok(
        H.http_get(("http://127.0.0.1:%d/"):format(port), { "Host: attacker.example" }).body
            :find("allowed_hosts", 1, true) ~= nil,
        "and its body names allowed_hosts, the way to add a name"
    )
    eq(
        status(port, "/content.md?t=" .. TOKEN, "rebind.example"),
        421,
        "the token opens no protected file under a foreign Host"
    )
    eq(status(port, "/__live/asset?p=pic.png&t=" .. TOKEN, "rebind.example"), 421, "nor the asset route")
    eq(status(port, "/__live/script.js", "rebind.example"), 421, "nor the client script")
    eq(status(port, "/__live/events?t=" .. TOKEN, "rebind.example"), 421, "nor the event stream")
    eq(status(port, "/", "localhost:9999"), 200, "localhost on another port (an ssh -L tunnel) is served")
    eq(status(port, "/", "LOCALHOST"), 200, "a Host is compared without case")
    eq(status(port, "/", "localhost."), 200, "one trailing dot names the same host")
    eq(status(port, "/", "foo.localhost"), 200, "a *.localhost name is served")
    eq(status(port, "/", "127.0.0.2"), 200, "any 127.0.0.0/8 address is served")
    eq(status(port, "/", "[::1]:" .. port), 200, "[::1] with a port is served")
    eq(status(port, "/", "127.0.0.1"), 200, "a portless 127.0.0.1 (markdown-preview's remote.lua) is served")
    eq(status(port, "/", "127.0.0.1.evil.example"), 421, "a name that starts with a loopback address is 421")
    eq(status(port, "/", "127.1"), 421, "a two-label numeric name is no loopback address")
    eq(status(port, "/", "2130706433"), 421, "a one-label numeric name is no loopback address")
    eq(status(port, "/", "0x7f.0.0.1"), 421, "a hex octet is no loopback address")
    eq(status(port, "/", "127.0.0.01"), 421, "a leading-zero octet is no loopback address")
    eq(status(port, "/", "localhost.attacker.example"), 421, "a name that merely contains localhost is 421")
    eq(status(port, "/", "evillocalhost"), 421, "the suffix needs its dot")
    eq(status(port, "/", "10.0.0.1"), 421, "a non-loopback address is 421")
    -- The check runs before the token gate and the method check, so a
    -- rebinding page learns nothing from a 401 or a 405.
    eq(
        status(port, "/content.md", "rebind.example"),
        421,
        "a foreign Host on a protected path without the token is 421, not 401"
    )
    eq(
        raw_status(port, "POST / HTTP/1.1\r\nHost: attacker.example\r\n\r\n"),
        421,
        "and before the method check, not 405"
    )
    eq(
        raw_status(port, "GET http://evil.example/ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"),
        421,
        "an absolute-form authority is checked, not the Host beside it"
    )
    eq(
        raw_status(port, ("GET http://localhost:%d/ HTTP/1.1\r\nHost: evil.example\r\n\r\n"):format(port)),
        200,
        "a loopback authority wins over a foreign Host (RFC 9112 3.2.2)"
    )
    eq(raw_status(port, "GET / HTTP/1.0\r\n\r\n"), 200, "HTTP/1.0 without Host is served: no browser omits it")
end)

H.case("Section 2: network binds keep the token gate alone", function()
    local inst = serve({ host = "0.0.0.0" })
    eq(status(inst.port, "/", "attacker.example"), 200, "a wildcard bind serves any Host")
    eq(status(inst.port, "/content.md", "my-laptop.local"), 401, "and gates a protected file by token")
    local guarded = serve({ host = "0.0.0.0", protected_paths = { "^/$", "^/index%.html$", "^/content%.md$" } })
    eq(
        status(guarded.port, "/", "my-laptop.local"),
        401,
        "a wildcard bind that protects the index gates it by token too"
    )
    eq(status(guarded.port, "/?t=" .. TOKEN, "my-laptop.local"), 200, "and the token opens it")
end)

H.case("Section 3: allowed_hosts adds names, true turns the check off", function()
    local inst = serve({ allowed_hosts = { "My.Name." } })
    eq(status(inst.port, "/", "my.name:8000"), 200, "a listed name is served, compared as the check compares")
    eq(status(inst.port, "/", "other.name"), 421, "an unlisted one is still 421")
    local notes = {}
    local real_notify = vim.notify
    vim.notify = function(msg, level)
        table.insert(notes, { msg = msg, level = level })
    end
    H.defer(function()
        vim.notify = real_notify
    end)
    local open = serve({ allowed_hosts = true })
    eq(status(open.port, "/", "attacker.example"), 200, "allowed_hosts = true serves any Host")
    ok(
        H.wait_for(function()
            return #notes >= 1
        end, 1000),
        "the warning is delivered"
    )
    eq(#notes, 1, "and says so once")
    ok(
        notes[1] ~= nil and notes[1].level == vim.log.levels.WARN and notes[1].msg:find("allowed_hosts", 1, true) ~= nil,
        "as a warning naming the option"
    )
    -- With two servers a line naming no port named neither.
    ok(
        notes[1] ~= nil and notes[1].msg:find(("live-server: port %d "):format(open.port), 1, true) == 1,
        "and the server's port: " .. tostring(notes[1] and notes[1].msg)
    )
    serve({ host = "0.0.0.0", allowed_hosts = true })
    vim.wait(200)
    eq(#notes, 1, "a network bind adds no warning: it had no check to turn off")
    -- TEST-NET-1 (RFC 5737) is assigned to no interface on any OS.
    local failed = pcall(server.start, { port = 0, root = root, host = "192.0.2.1", allowed_hosts = true })
    vim.wait(100)
    ok(not failed, "a start with allowed_hosts = true that cannot bind raises")
    eq(#notes, 1, "and warns nothing: no server turned the check off")
    local quick = server.start({ port = 0, root = root, allowed_hosts = true, live = { enabled = false } })
    server.stop(quick)
    vim.wait(100)
    eq(#notes, 1, "a server stopped before the warning ran warns nothing")
    local bare = serve({ allowed_hosts = { "fe80::1" } })
    eq(
        status(bare.port, "/", "[fe80::1]:" .. bare.port),
        200,
        "an IPv6 entry written without brackets matches a bracketed Host"
    )
    -- The real vim.notify raises E5560 in a fast event context; a start
    -- from a luv callback must still return the instance it opened.
    vim.notify = real_notify
    local tcps_before = H.handle_count("tcp")
    local started, inst_or_err
    local t = assert(vim.uv.new_timer())
    H.defer(function()
        t:close()
    end)
    t:start(10, 0, function()
        started, inst_or_err = pcall(server.start, {
            port = 0,
            root = root,
            allowed_hosts = true,
            live = { enabled = false },
        })
    end)
    ok(
        H.wait_for(function()
            return started ~= nil
        end, 2000),
        "the start returned"
    )
    if started then
        H.defer(function()
            server.stop(inst_or_err)
        end)
    end
    ok(
        started == true,
        ("a start with allowed_hosts = true from a luv callback returns an instance: %s (tcp %d then %d)"):format(
            tostring(inst_or_err),
            tcps_before,
            H.handle_count("tcp")
        )
    )
end)

-- Only the OS refusing the address means no IPv6 here; any other raise,
-- one before the OS saw the address included, is a fault.
local function refused_by_os(err)
    err = tostring(err)
    return err:find("EADDRNOTAVAIL", 1, true) ~= nil or err:find("EAFNOSUPPORT", 1, true) ~= nil
end

-- The check follows the address the socket reports, so no spelling of a
-- loopback bind leaves it off.
H.case("Section 4: the check follows the bound address, not its spelling", function()
    local bound, six = pcall(serve, { host = "0:0:0:0:0:0:0:1" })
    if bound then
        eq(six.host_check, true, "a spelled-out IPv6 loopback bind keeps the check on")
        eq(
            H.http_get(("http://[::1]:%d/"):format(six.port), { "Host: attacker.example" }).status,
            421,
            "and refuses a foreign Host"
        )
        eq(six.host, "::1", "inst.host is the bound address, canonical")
    elseif not refused_by_os(six) then
        error(six, 0)
    else
        H.skip("a spelled-out IPv6 loopback bind keeps the check on (bind refused: " .. tostring(six) .. ")")
        H.skip("and refuses a foreign Host (bind refused: " .. tostring(six) .. ")")
        H.skip("inst.host is the bound address, canonical (bind refused: " .. tostring(six) .. ")")
    end
    local mapped_bound, mapped = pcall(serve, { host = "::ffff:127.0.0.1" })
    if mapped_bound then
        eq(mapped.host_check, true, "an IPv4-mapped loopback bind keeps the check on")
    elseif not refused_by_os(mapped) then
        error(mapped, 0)
    else
        H.skip("an IPv4-mapped loopback bind keeps the check on (bind refused: " .. tostring(mapped) .. ")")
    end
    -- The warning reads the bound address, so a spelled-out IPv6 loopback
    -- bind with the check off says so.
    local notes = {}
    local real_notify = vim.notify
    vim.notify = function(msg, level)
        table.insert(notes, { msg = msg, level = level })
    end
    H.defer(function()
        vim.notify = real_notify
    end)
    local warned_bound, warned = pcall(serve, { host = "0:0:0:0:0:0:0:1", allowed_hosts = true })
    if warned_bound then
        H.wait_for(function()
            return #notes >= 1
        end, 1000)
        eq(#notes, 1, "a spelled-out IPv6 loopback bind with allowed_hosts = true warns once")
    elseif not refused_by_os(warned) then
        error(warned, 0)
    else
        H.skip(
            "a spelled-out IPv6 loopback bind with allowed_hosts = true warns once (bind refused: "
                .. tostring(warned)
                .. ")"
        )
    end
end)

H.finish()
