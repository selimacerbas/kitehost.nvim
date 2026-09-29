-- tests/start_test.lua
-- What start refuses, each before any socket opens,
-- naming what it refused, at level 0: options that are no table, a bad
-- token (one that is no UTF-8 among them), default_index, a live, dirlist
-- or notify_on_reload flag that is no boolean, protected_paths
-- (patterns with no token among them), serve_dotfiles, index_names, headers
-- (a control byte in a value, two spellings of one name and the server's
-- own fields among them), cors, allowed_hosts (a string, a map, a hole, a
-- wildcard, an entry no Host can match), live and its debounce, features,
-- host, header_timeout_ms, sse_heartbeat_ms, max_connections, a port it
-- cannot hold or a root that is no string or does not resolve; a bind to an
-- address this machine lacks or to a port in use raises naming it and
-- leaves no socket, a socket that cannot be made raises naming it, and a
-- failed listen or a reload timer that cannot be made leaves no socket,
-- timer or watcher, the timer's raise naming it. A wildcard bind raises
-- unless the loopback address its URL names is free, and its probe of that
-- address is never left open. A pattern the check cannot read past its
-- literal starts and gates every path it is asked about, and each option is
-- read from the caller's table once.
--
-- Run: nvim --headless -u NONE -l "$PWD/tests/start_test.lua"

local H = dofile(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "helpers.lua"))
H.isolate()
H.rtp()

local server = require("live_server.server")
local util = require("live_server.util")
local ok, eq, http_get = H.ok, H.eq, H.http_get

-- Every refusal the suite provokes, kept as raised for the last case: the
-- rows match a refusal by substring, which a "server.lua:NNN: " prefix
-- would still pass.
local refusals = {}
local real_start = server.start
H.defer(function()
    server.start = real_start
end)
server.start = function(cfg)
    local started, res = pcall(real_start, cfg)
    if not started then
        table.insert(refusals, tostring(res))
        error(res, 0)
    end
    return res
end

local root = H.tmpdir()
H.write_file(vim.fs.joinpath(root, "index.html"), "<html><body>hi</body></html>")
H.write_file(vim.fs.joinpath(root, "content.md"), "# secret content")
local TOKEN = util.random_token(16)

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

-- Each refused before any socket opens. An empty token is truthy, so it
-- would mark every request as the token's holder and pass the gate with
-- no t= at all. A false token, read as none, would pass the check that
-- patterns need a token and leave the files they name open to any
-- request (measured). protected_paths is walked with ipairs, which skips
-- a map's keys and stops at a hole, so a map protected nothing and the
-- entries after a hole were never read, without a word; a malformed
-- pattern started and then raised in the read callback of every request,
-- which was never answered; serve_dotfiles = 1 read as false. Patterns
-- with no token started and gated nothing, and an index_names string
-- raised in the read callback of every directory request; a name with a
-- path in it (../x) read a directory's index from another directory. A
-- header is written as the table spells it: Chromium trims a name, so
-- "Access-Control-Allow-Origin " let any site read the event stream
-- (measured); a colon in a name or a CR or LF in a value sends a header
-- other than the one named, a key that is not a string went out as a
-- number, and a headers string opened the socket before it raised. A
-- caller's Content-Type, Content-Length, Transfer-Encoding or Connection
-- replaced the server's own or went out beside it: a second framing line
-- that left Chrome rendering nothing, and on the asset route a type that
-- rendered a text file as HTML in the server's origin, past the sandbox
-- its extension decides. A cors value goes out as a header value too, so
-- a CR or LF in it wrote a line of its own; one that is no origin as a
-- browser sends it could never match, and a list is walked with ipairs,
-- which skips a map's keys. live, features and its dirlist are indexed as
-- given and host is bound as given, where a number read as a failed bind
-- and a table raised as a fault in the server's own code, naming no
-- option. live.debounce, header_timeout_ms and sse_heartbeat_ms each
-- arm a timer: a debounce that is no number started and then raised in
-- the watcher's callback at every file change, and luv reads NaN as 0, a
-- negative value or math.huge as never and a fraction cut down
-- (measured), so each takes an integer from 0 to 2^31 - 1 and refuses
-- the rest alike. Each accept compares its open count with
-- max_connections, where text raised at every connection and left its
-- socket open, 0 closed them all and NaN or math.huge capped nothing
-- (measured).
H.case("start refuses a bad option, naming it, before any socket opens", function()
    -- { option, value, the text the refusal must carry (the option's name
    -- unless given) }
    local bad = {
        { "token", "" },
        { "token", 42 },
        { "token", false },
        { "allowed_hosts", { 42 } },
        { "allowed_hosts", { "" } },
        { "protected_paths", { content = "^/content%.md$" } },
        { "protected_paths", { [1] = "^/a$", [3] = "^/b$" } },
        { "protected_paths", { 42 } },
        { "protected_paths", { "(" }, "protected_paths pattern is malformed: (" },
        { "protected_paths", { "^/a$", "%" }, "protected_paths pattern is malformed: %" },
        { "serve_dotfiles", 1 },
        { "protected_paths", { "^/secret" }, "protected_paths needs a token" },
        { "index_names", "index.html" },
        { "index_names", { 42 } },
        { "index_names", { "" } },
        { "index_names", { "../x" }, "index_names entry is not a file name: ../x" },
        { "index_names", { "sub/index.html" }, "index_names entry is not a file name: sub/index.html" },
        { "index_names", { "sub\\index.html" }, "index_names entry is not a file name: sub\\index.html" },
        { "index_names", { "." }, "index_names entry is not a file name: ." },
        { "index_names", { ".." }, "index_names entry is not a file name: .." },
        {
            "headers",
            { ["Access-Control-Allow-Origin "] = "*" },
            "headers: a name must be a token and a value a line: Access-Control-Allow-Origin ",
        },
        { "headers", { ["X-A:b"] = "1" }, "headers: a name must be a token and a value a line: X-A:b" },
        { "headers", { [1] = "x" }, "headers: a name must be a token and a value a line: 1" },
        {
            "headers",
            { ["X-Custom"] = "a\r\nSet-Cookie: x=1" },
            "headers: a name must be a token and a value a line: X-Custom",
        },
        -- Chromium splits a header at a bare LF, so either character alone
        -- is refused, not only the pair.
        { "headers", { ["X-Custom"] = "a\rb" }, "headers: a name must be a token and a value a line: X-Custom" },
        { "headers", { ["X-Custom"] = "a\nb" }, "headers: a name must be a token and a value a line: X-Custom" },
        { "headers", { ["X-Custom"] = 1 }, "headers: a name must be a token and a value a line: X-Custom" },
        { "headers", { [""] = "x" }, "headers: a name must be a token and a value a line: " },
        { "headers", { ["X\tA"] = "x" }, "headers: a name must be a token and a value a line: X\tA" },
        -- RFC 9110 5.5: a value holds visible characters, spaces and tabs. A
        -- NUL started the server, and then Chromium (ERR_INVALID_HTTP_RESPONSE)
        -- and curl refused every response that carried it.
        { "headers", { ["X-Custom"] = "a\0b" }, "headers: a name must be a token and a value a line: X-Custom" },
        { "headers", { ["X-Custom"] = "a\1b" }, "headers: a name must be a token and a value a line: X-Custom" },
        { "headers", { ["X-Custom"] = "a\127b" }, "headers: a name must be a token and a value a line: X-Custom" },
        -- Two spellings of one name went out as two lines, which a cache
        -- reads as one list: "no-cache, max-age=60" left the second inert.
        {
            "headers",
            { ["Cache-Control"] = "a", ["cache-control"] = "b" },
            "headers: Cache-Control and cache-control name one field",
        },
        { "headers", { ["Content-Type"] = "text/html" }, "headers: Content-Type is the server's own field" },
        { "headers", { ["content-type"] = "text/html" }, "headers: content-type is the server's own field" },
        { "headers", { ["Content-Length"] = "1" }, "headers: Content-Length is the server's own field" },
        { "headers", { ["content-length"] = "1" }, "headers: content-length is the server's own field" },
        {
            "headers",
            { ["Transfer-Encoding"] = "chunked" },
            "headers: Transfer-Encoding is the server's own field",
        },
        {
            "headers",
            { ["transfer-encoding"] = "chunked" },
            "headers: transfer-encoding is the server's own field",
        },
        { "headers", { ["Connection"] = "keep-alive" }, "headers: Connection is the server's own field" },
        { "headers", { ["connection"] = "keep-alive" }, "headers: connection is the server's own field" },
        { "headers", { ["CONTENT-type"] = "text/html" }, "headers: CONTENT-type is the server's own field" },
        { "headers", "x", "headers must be a table" },
        { "cors", "http://a.example\r\nSet-Cookie: x=1", "cors entry is not an origin" },
        { "cors", "http://a.example\n", "cors entry is not an origin" },
        { "cors", "http://a .example", "cors entry is not an origin" },
        { "cors", "http://a.example\1", "cors entry is not an origin" },
        { "cors", "http://a.example/", "cors entry is not an origin" },
        { "cors", "http://a.example/app", "cors entry is not an origin" },
        { "cors", "http://a.example:", "cors entry is not an origin" },
        { "cors", "http://user@a.example", "cors entry is not an origin" },
        { "cors", "a.example", "cors entry is not an origin" },
        { "cors", "null", "cors entry is not an origin" },
        { "cors", "", "cors entry is not an origin" },
        {
            "cors",
            "HTTP://A.EXAMPLE",
            "not an origin as a browser sends it (lower case, no default port): HTTP://A.EXAMPLE",
        },
        {
            "cors",
            "http://a.example:80",
            "not an origin as a browser sends it (lower case, no default port): http://a.example:80",
        },
        {
            "cors",
            "https://a.example:443",
            "not an origin as a browser sends it (lower case, no default port): https://a.example:443",
        },
        {
            "cors",
            "http://a.example:05173",
            "not an origin as a browser sends it (lower case, no default port): http://a.example:05173",
        },
        {
            "cors",
            "http://a.example:99999",
            "not an origin as a browser sends it (lower case, no default port): http://a.example:99999",
        },
        {
            "cors",
            "http://a%41.example",
            "not an origin as a browser sends it (lower case, no default port): http://a%41.example",
        },
        {
            "cors",
            "ws://a.example:80",
            "not an origin as a browser sends it (lower case, no default port): ws://a.example:80",
        },
        { "cors", 1, "cors must be true, an origin or a list of origins" },
        { "cors", { "http://a.example", 42 }, "cors must be true, an origin or a list of origins" },
        { "cors", { "http://a.example", "*" }, "cors entry is not an origin" },
        { "cors", { "http://a.example", "http://b.example\r\nX: y" }, "cors entry is not an origin" },
        { "cors", { origin = "http://a.example" }, "cors must be true, an origin or a list of origins" },
        {
            "cors",
            { [1] = "http://a.example", [3] = "http://b.example" },
            "cors must be true, an origin or a list of origins",
        },
        { "live", 1, "live must be a table" },
        { "live", true, "live must be a table" },
        { "features", 1, "features must be a table" },
        { "features", { dirlist = 1 }, "features.dirlist must be a table" },
        { "host", 1, "host must be a string" },
        { "host", { "127.0.0.1" }, "host must be a string" },
        { "live", false, "live must be a table" },
        { "features", false, "features must be a table" },
        -- A default_index that is no string started, and every GET / then
        -- answered 500.
        { "default_index", true, "default_index must be a string" },
        { "default_index", { "index.html" }, "default_index must be a string" },
        -- A flag turned off on exactly false, so 0 turned it on.
        { "notify_on_reload", 0, "notify_on_reload must be true or false" },
        { "notify_on_reload", "no", "notify_on_reload must be true or false" },
        { "live", { enabled = 0 }, "live.enabled must be true or false" },
        { "live", { inject_script = 0 }, "live.inject_script must be true or false" },
        { "live", { css_inject = "no" }, "live.css_inject must be true or false" },
        { "features", { dirlist = { enabled = 0 } }, "features.dirlist.enabled must be true or false" },
        { "features", { dirlist = { show_hidden = 1 } }, "features.dirlist.show_hidden must be true or false" },
        -- The stream refuses a token that is no UTF-8 in the page's encoded
        -- form, so the URL the start prints would never connect.
        { "token", "ab\255cd", "token must be valid UTF-8" },
        { "token", "ab\195", "token must be valid UTF-8" },
        { "token", "\192\175", "token must be valid UTF-8" },
        { "token", "\224\128\175", "token must be valid UTF-8" },
        { "token", "\237\160\128", "token must be valid UTF-8" },
        { "token", "\244\144\128\128", "token must be valid UTF-8" },
        { "token", "\195\40", "token must be valid UTF-8" },
    }
    -- Each millisecond option is refused the same values the same way.
    for _, v in ipairs({ "soon", true, -1, 1.5, 0 / 0, math.huge, 2 ^ 31 }) do
        local range = " must be an integer from 0 to 2147483647"
        table.insert(bad, { "live", { debounce = v }, "live.debounce" .. range })
        table.insert(bad, { "header_timeout_ms", v, "header_timeout_ms" .. range })
        table.insert(bad, { "sse_heartbeat_ms", v, "sse_heartbeat_ms" .. range })
    end
    for _, v in ipairs({ "64", true, 0, -1, 1.5, 0 / 0, math.huge }) do
        table.insert(bad, { "max_connections", v, "max_connections must be an integer at or above 1" })
    end
    for _, c in ipairs(bad) do
        local name, value, says = c[1], c[2], c[3] or c[1]
        local shown = ("%s = %s"):format(name, vim.inspect(value, { newline = " ", indent = "" }))
        local tcps, fds = H.handle_count("tcp"), H.fd_count()
        local started, res = pcall(server.start, { port = 0, root = root, [name] = value })
        local after, fds_after = H.handle_count("tcp"), H.fd_count()
        if started then
            server.stop(res)
        end
        ok(
            not started and tostring(res):find(says, 1, true) ~= nil,
            ("%s is refused, naming %s: %s"):format(shown, says, tostring(res))
        )
        eq(after, tcps, ("%s opens no socket"):format(shown))
        eq(fds_after, fds, ("%s opens no descriptor"):format(shown))
    end
    -- A cfg that is no table raised at the server's own line, naming
    -- nothing a user could act on.
    for _, cfg in ipairs({ { "nil", nil }, { "5", 5 }, { '"x"', "x" } }) do
        local tcps, fds = H.handle_count("tcp"), H.fd_count()
        local started, res = pcall(server.start, cfg[2])
        local after, fds_after = H.handle_count("tcp"), H.fd_count()
        if started then
            server.stop(res)
        end
        ok(
            not started and tostring(res) == "start takes a table of options",
            ("start(%s) is refused, naming its options: %s"):format(cfg[1], tostring(res))
        )
        eq(after, tcps, ("start(%s) opens no socket"):format(cfg[1]))
        eq(fds_after, fds, ("start(%s) opens no descriptor"):format(cfg[1]))
    end
    local started, res = pcall(server.start, {
        port = 0,
        root = root,
        token = TOKEN,
        protected_paths = { "^/content%.md$", "[%w_]+%.key$", "^/a/(b)$" },
    })
    ok(started, "a list of well-formed patterns starts: " .. tostring(started and "" or res))
    if started then
        server.stop(res)
    end
    -- UTF-8 up to U+10FFFF, each sequence length among it.
    started, res = pcall(server.start, {
        port = 0,
        root = root,
        token = "a\195\182\226\130\172\240\157\132\158\244\143\191\191",
    })
    ok(started, "a token in valid UTF-8 starts: " .. tostring(started and "" or res))
    if started then
        server.stop(res)
    end
    started, res = pcall(server.start, {
        port = 0,
        root = root,
        default_index = vim.fs.joinpath(root, "index.html"),
        notify_on_reload = true,
        live = { enabled = true, inject_script = true, css_inject = true },
        features = { dirlist = { enabled = true, show_hidden = true } },
    })
    ok(started, "a string default_index and every flag true start: " .. tostring(started and "" or res))
    if started then
        server.stop(res)
    end
    -- init.lua's default: no patterns ask for no token.
    started, res = pcall(server.start, { port = 0, root = root, protected_paths = {} })
    ok(started, "protected_paths = {} starts without a token: " .. tostring(started and "" or res))
    if started then
        server.stop(res)
    end
    for _, ms in ipairs({ 0, 2 ^ 31 - 1 }) do
        started, res = pcall(server.start, { port = 0, root = root, live = { enabled = false, debounce = ms } })
        ok(started, ("live.debounce = %d starts: %s"):format(ms, tostring(started and "" or res)))
        if started then
            server.stop(res)
        end
        started, res = pcall(server.start, { port = 0, root = root, header_timeout_ms = ms })
        ok(started, ("header_timeout_ms = %d starts: %s"):format(ms, tostring(started and "" or res)))
        if started then
            server.stop(res)
        end
        started, res = pcall(server.start, { port = 0, root = root, sse_heartbeat_ms = ms })
        ok(started, ("sse_heartbeat_ms = %d starts: %s"):format(ms, tostring(started and "" or res)))
        if started then
            server.stop(res)
        end
    end
    for _, cap in ipairs({ 1, 2 ^ 31 }) do
        started, res = pcall(server.start, { port = 0, root = root, max_connections = cap })
        ok(started, ("max_connections = %d starts: %s"):format(cap, tostring(started and "" or res)))
        if started then
            server.stop(res)
        end
    end
    started, res = pcall(server.start, { port = 0, root = root, headers = { ["X-Custom"] = "1" } })
    ok(started, 'headers = { ["X-Custom"] = "1" } starts: ' .. tostring(started and "" or res))
    if started then
        server.stop(res)
    end
    started, res = pcall(server.start, { port = 0, root = root, headers = { ["X-Custom"] = "a\tb" } })
    ok(started, "a tab inside a header value starts: " .. tostring(started and "" or res))
    if started then
        server.stop(res)
    end
    -- "*" is the documented spelling of true.
    for _, cors in ipairs({
        true,
        false,
        "*",
        "http://a.example",
        "https://127.0.0.1:5173",
        "http://[::1]:8080",
        "http://a.example:5173",
        "http://a.example:65535",
        "chrome-extension://abcdef",
        { "http://a.example", "https://b.example:8443" },
        {},
    }) do
        started, res = pcall(server.start, { port = 0, root = root, cors = cors })
        ok(
            started,
            ("cors = %s starts: %s"):format(
                vim.inspect(cors, { newline = " ", indent = "" }),
                tostring(started and "" or res)
            )
        )
        if started then
            server.stop(res)
        end
    end
    -- The start check reads a pattern against the empty subject, so a
    -- malformed part after a literal ("/[") is never parsed there. The
    -- request the pattern was asked about raised in the read callback and
    -- went unanswered; no token satisfies a pattern nobody can read.
    local function unreadable_server(patterns)
        local up, inst_or_err = pcall(server.start, {
            port = 0,
            root = root,
            token = TOKEN,
            protected_paths = patterns,
            live = { enabled = false, inject_script = false },
            features = { dirlist = { enabled = false } },
        })
        ok(
            up,
            ("protected_paths = %s starts: the start check cannot read past the literal%s"):format(
                vim.inspect(patterns, { newline = " ", indent = "" }),
                up and "" or ": " .. tostring(inst_or_err)
            )
        )
        if up then
            H.defer(function()
                server.stop(inst_or_err)
            end)
            return ("http://127.0.0.1:%d/content.md"):format(inst_or_err.port)
        end
    end
    local function answers_401(url, label)
        local got = http_get(url)
        ok(got.status == 401, ("%s (got %d, curl %d)"):format(label, got.status, got.curl_exit))
    end
    -- A 401 alone reads like a bad token, so the first pattern that cannot
    -- be read is named once per instance. Captured here, where the real
    -- notify would print to the run.
    local notes = {}
    local real_notify = vim.notify
    vim.notify = function(msg, level)
        table.insert(notes, { msg = msg, level = level })
    end
    H.defer(function()
        vim.notify = real_notify
    end)
    local warning = "live-server: protected_paths pattern cannot be read, refusing what it gates: /["
    local function settled(count)
        H.wait_for(function()
            return #notes >= count
        end, 1000)
        -- A second warning scheduled by a later request would land here.
        vim.wait(100)
        return #notes
    end
    local alone = unreadable_server({ "/[" })
    if alone then
        answers_401(alone, "/content.md under an unreadable pattern is 401 without the token, never unanswered")
        answers_401(
            alone .. "?t=" .. TOKEN,
            "and 401 with it: a pattern nobody can read gates every path it is asked about"
        )
        local count = settled(1)
        ok(
            count == 1 and notes[1].level == vim.log.levels.WARN and notes[1].msg == warning,
            ("two requests warn once, naming the pattern: %s"):format(
                vim.inspect(notes, { newline = " ", indent = "" })
            )
        )
    end
    -- Every pattern is read, so a path an earlier pattern matches is asked
    -- about the unreadable one too.
    local after = unreadable_server({ "^/content%.md$", "/[" })
    if after then
        answers_401(after .. "?t=" .. TOKEN, "an unreadable pattern after a matching one refuses the token too")
        local count = settled(2)
        ok(
            count == 2 and notes[2].msg == warning,
            ("another instance warns once of its own: %s"):format(vim.inspect(notes, { newline = " ", indent = "" }))
        )
    end
    local before = #notes
    local readable = server.start({
        port = 0,
        root = root,
        token = TOKEN,
        protected_paths = { "^/content%.md$" },
        live = { enabled = false, inject_script = false },
        features = { dirlist = { enabled = false } },
    })
    H.defer(function()
        server.stop(readable)
    end)
    answers_401(("http://127.0.0.1:%d/content.md"):format(readable.port), "a readable pattern gates as before")
    vim.wait(100)
    eq(#notes, before, "and a list of readable patterns warns nothing")
    -- The token is read from the caller's table once: a table that computes
    -- the field could pass the check with one value and hand the gate another.
    local reads = 0
    local computed = setmetatable({ port = 0, root = root, protected_paths = { "^/content%.md$" } }, {
        __index = function(_, key)
            if key == "token" then
                reads = reads + 1
                return "secret-token"
            end
        end,
    })
    local once = server.start(computed)
    H.defer(function()
        server.stop(once)
    end)
    eq(reads, 1, "start reads cfg.token once")
end)

H.case("start refuses allowed_hosts but true or a list of hostnames", function()
    local tcps = H.handle_count("tcp")
    local started, err = pcall(server.start, { port = 0, root = root, allowed_hosts = "my.name" })
    ok(not started and tostring(err):find("allowed_hosts", 1, true) ~= nil, "a string is refused: " .. tostring(err))
    eq(H.handle_count("tcp"), tcps, "before any socket opens")
    local typo_started, typo_err = pcall(server.start, { port = 0, root = root, allowed_hosts = { "a b" } })
    ok(
        not typo_started and tostring(typo_err):find("a b", 1, true) ~= nil,
        "an entry no Host can match is refused, naming it: " .. tostring(typo_err)
    )
    eq(H.handle_count("tcp"), tcps, "and opens no socket either")
    -- host_name drops a port and brackets from a Host, so an entry carrying
    -- either could never equal what the check compares against.
    local port_started, port_err = pcall(server.start, { port = 0, root = root, allowed_hosts = { "dev.test:80" } })
    ok(
        not port_started and tostring(port_err):find("dev.test:80", 1, true) ~= nil,
        "an entry with a port is refused, naming it: " .. tostring(port_err)
    )
    local six_started, six_err = pcall(server.start, { port = 0, root = root, allowed_hosts = { "[::1]" } })
    ok(
        not six_started and tostring(six_err):find("[::1]", 1, true) ~= nil,
        "a bracketed entry is refused, naming it: " .. tostring(six_err)
    )
    -- The list is walked in order, so a map or a list with a hole would
    -- start with names silently dropped, and a wildcard matches no
    -- subdomain, only that literal name.
    for _, case in ipairs({
        { { ["dev.test"] = true }, "a map is refused, naming allowed_hosts", { "allowed_hosts" } },
        { { "a.test", nil, "b.test" }, "a list with a hole is refused", { "allowed_hosts" } },
        { { "*.dev.test" }, "a wildcard entry is refused, naming it", { "wildcard", "*.dev.test" } },
    }) do
        local before = H.handle_count("tcp")
        local started, res = pcall(server.start, { port = 0, root = root, allowed_hosts = case[1] })
        local after = H.handle_count("tcp")
        if started then
            server.stop(res)
        end
        local named = not started
        for _, needle in ipairs(case[3]) do
            named = named and tostring(res):find(needle, 1, true) ~= nil
        end
        ok(named, case[2] .. ": " .. tostring(res))
        eq(after, before, case[2] .. ", before any socket opens")
    end
end)

H.case("a bind that fails and a port start cannot hold raise, leaving no socket", function()
    -- TEST-NET-1 (RFC 5737) is assigned to no interface on any OS.
    local tcps = H.handle_count("tcp")
    local started, err = pcall(server.start, { port = 0, root = root, host = "192.0.2.1" })
    ok(
        not started and tostring(err):find("192.0.2.1", 1, true) ~= nil,
        "a bind to an address this machine lacks raises: " .. tostring(err)
    )
    eq(H.handle_count("tcp"), tcps, "and leaves no handle open")
    -- Distinct specific addresses share a port on every OS, and macOS lets a
    -- specific address share one a wildcard listener holds, so both binds
    -- name the same address, 127.0.0.1.
    local a = serve()
    local busy_before = H.handle_count("tcp")
    local busy_started, busy_err = pcall(server.start, { port = a.port, root = root })
    local busy_after = H.handle_count("tcp")
    if busy_started then
        server.stop(busy_err)
    end
    ok(
        not busy_started and tostring(busy_err):find(tostring(a.port), 1, true) ~= nil,
        "a start on a port in use raises, naming the port: " .. tostring(busy_err)
    )
    eq(busy_after, busy_before, "and leaves no handle open")
    -- luv truncates a port it cannot hold, so 70000 or 8123.5 would listen
    -- on another port while the start reports success.
    for _, bad in ipairs({ 70000, 8123.5, 65536, -1 }) do
        local before = H.handle_count("tcp")
        local port_started, res = pcall(server.start, { port = bad, root = root })
        local after = H.handle_count("tcp")
        if port_started then
            server.stop(res)
        end
        ok(
            not port_started and tostring(res):find("port", 1, true) ~= nil,
            ("port = %s is refused, naming port: %s"):format(tostring(bad), tostring(res))
        )
        eq(after, before, ("port = %s opens no socket"):format(tostring(bad)))
    end
    -- The top of the range is a port: a bind may still find it taken, but
    -- the check passes it.
    local top_started, top_res = pcall(server.start, { port = 65535, root = root })
    if top_started then
        server.stop(top_res)
    end
    ok(
        top_started or not tostring(top_res):find("port must be", 1, true),
        "port = 65535 passes the port check: " .. tostring(top_started and "" or top_res)
    )
    local text_started, text_err = pcall(server.start, { port = "8765", root = root })
    if text_started then
        server.stop(text_err)
    end
    ok(
        not text_started and tostring(text_err):find("(string)", 1, true) ~= nil,
        "a port given as text is refused, naming its type: " .. tostring(text_err)
    )
end)

-- A browser reaches a wildcard bind on the loopback address the opened URL
-- names. macOS lets a listener bound to 127.0.0.1 alone share the port with
-- a wildcard bind and take every connection to that address, so the start
-- succeeded and the URL, token and all, reached the other program
-- (measured); Linux refuses the wildcard bind itself. The start probes that
-- address with a socket that never listens and is closed on every path. A
-- probe that fails any other way cannot tell the address is free: a real
-- EMFILE at the probe's bind let the start serve while another program
-- answered the URL (measured).
H.case("a wildcard bind raises unless its URL's address is free", function()
    local real_new_tcp = vim.uv.new_tcp
    local real_rule = server.wildcard_loopback
    H.defer(function()
        vim.uv.new_tcp = real_new_tcp
        server.wildcard_loopback = real_rule
    end)
    -- Counts the sockets a start makes. The one numbered at fails as answer
    -- says: answer.new_tcp is returned by new_tcp itself, answer.bind by the
    -- bind of a socket handed to start in its place, each as nil, a cause
    -- and its name.
    local made, at, answer = 0, nil, nil
    vim.uv.new_tcp = function(...)
        made = made + 1
        local stubbed = made == at and answer or nil
        if stubbed and stubbed.new_tcp then
            return nil, stubbed.new_tcp[1], stubbed.new_tcp[2]
        end
        local handle, err = real_new_tcp(...)
        if not stubbed or not handle then
            return handle, err
        end
        return setmetatable({}, {
            __index = function(_, name)
                if name == "bind" then
                    return function()
                        return nil, stubbed.bind[1], stubbed.bind[2]
                    end
                end
                return function(_, ...)
                    return handle[name](handle, ...)
                end
            end,
        })
    end
    -- Starts, counts the sockets the start made and the ones it left open,
    -- hands a server that started to use, then stops it, so no start holds
    -- the port for the next one. The server's socket is the first a start
    -- makes and the probe the second, which probe_stub fails.
    local function start_counted(cfg, probe_stub, use)
        made, at, answer = 0, probe_stub and 2, probe_stub
        local before = H.handle_count("tcp")
        local started, res = pcall(server.start, vim.tbl_extend("keep", cfg, { root = root }))
        local sockets, open = made, H.handle_count("tcp") - before
        made, at, answer = 0, nil, nil
        local used
        if started then
            used = use and use(res)
            server.stop(res)
        end
        return started, tostring(res), sockets, open, used
    end

    local _, _, loop_made, loop_open = start_counted({ port = 0 })
    eq(loop_made, 1, "a loopback start makes its own socket alone, no probe")
    eq(loop_open, 1, "and leaves that one open")

    -- One skip per row below, so a machine that refuses a wildcard bind
    -- counts every row it could not run.
    local wild = assert(real_new_tcp())
    local wild_ok, wild_err = wild:bind("0.0.0.0", 0)
    if wild_ok then
        wild_ok, wild_err = wild:getsockname()
    end
    wild:close()
    if not wild_ok then
        for _, row in ipairs({
            "a start beside a loopback listener raises",
            "naming the port",
            "leaving no socket",
            "saying another socket holds 127.0.0.1",
            "a start with nothing beside it serves",
            "making its socket and the probe",
            "closing the probe",
            "reached on 127.0.0.1",
            "a probe whose bind finds no descriptor raises",
            "leaving no socket",
            "a probe that cannot open raises",
            "leaving no socket",
            "a probe of an address this machine lacks raises",
            "leaving no socket",
            "a probe of an address bind cannot read raises",
            "leaving no socket",
            "a loopback rule that raises refuses the start",
            "leaving no socket",
        }) do
            H.skip(("a wildcard bind: %s (this machine refuses one: %s)"):format(row, tostring(wild_err)))
        end
        return
    end

    local hold = assert(real_new_tcp())
    H.defer(function()
        if not hold:is_closing() then
            hold:close()
        end
    end)
    assert(hold:bind("127.0.0.1", 0))
    assert(hold:listen(8, function() end))
    local port = hold:getsockname().port
    -- Whether this machine lets a wildcard bind share the port at all.
    local beside = assert(real_new_tcp())
    local shares = beside:bind("0.0.0.0", port) ~= nil and beside:getsockname() ~= nil
    beside:close()

    local started, res, _, open = start_counted({ host = "0.0.0.0", port = port })
    ok(not started and res:find("EADDRINUSE", 1, true) ~= nil, "a wildcard start beside it raises: " .. res)
    ok(not started and res:find(":" .. port, 1, true) ~= nil, "naming the port: " .. res)
    eq(open, 0, "and leaves no socket open, the probe's included")
    -- A busy address is named as held, never as one start could not check.
    if shares then
        ok(
            not started and res:find("another socket holds 127.0.0.1:" .. port, 1, true) ~= nil,
            "where a wildcard bind shares the port, the raise says another socket holds 127.0.0.1, the address the URL names: "
                .. res
        )
    else
        H.skip(
            "the raise says another socket holds 127.0.0.1 (this machine refuses the wildcard bind beside the listener)"
        )
    end

    hold:close()
    local free_started, free_res, free_made, free_open, status = start_counted(
        { host = "0.0.0.0", port = port },
        nil,
        function()
            return http_get(("http://127.0.0.1:%d/"):format(port)).status
        end
    )
    ok(free_started, "with nothing on 127.0.0.1 at that port, the wildcard start serves: " .. free_res)
    eq(free_made, 2, "its own socket and the probe")
    eq(free_open, 1, "and the probe is closed")
    eq(status, 200, "the URL's address reaches this server")

    -- Each refuses naming the address it could not check and the cause.
    -- EMFILE comes from the bind: libuv opens the descriptor there, not in
    -- new_tcp, whose own failure is kept too. An address bind cannot read
    -- raises inside luv, and a rule that raises raised past start: each
    -- left the server's socket open (measured).
    local function refuses(label, rule, probe_stub, needles)
        server.wildcard_loopback = rule or real_rule
        local refused, why, _, left = start_counted({ host = "0.0.0.0", port = 0 }, probe_stub)
        server.wildcard_loopback = real_rule
        local named = not refused
        for _, needle in ipairs(needles) do
            named = named and why:find(needle, 1, true) ~= nil
        end
        ok(named, label .. ", naming the address and the cause: " .. why)
        eq(left, 0, label .. ", leaving no socket open")
    end
    local function names(address)
        return function(ip)
            return ip == "0.0.0.0" and address or nil
        end
    end
    refuses(
        "a probe whose bind finds no descriptor raises",
        nil,
        { bind = { "EMFILE: stubbed", "EMFILE" } },
        { "cannot check 127.0.0.1:", "EMFILE: stubbed" }
    )
    refuses(
        "a probe that cannot open raises",
        nil,
        { new_tcp = { "EMFILE: stubbed", "EMFILE" } },
        { "cannot check 127.0.0.1:", "EMFILE: stubbed" }
    )
    refuses(
        "a probe of an address this machine lacks raises",
        names("192.0.2.1"),
        nil,
        { "cannot check 192.0.2.1:", "EADDRNOTAVAIL" }
    )
    refuses(
        "a probe of an address bind cannot read raises",
        names("[127.0.0.1]"),
        nil,
        { "cannot check [127.0.0.1]:", "Invalid IP address" }
    )
    -- Level 0, so the cause carries no position the suite's level check
    -- would read as start's.
    refuses("a loopback rule that raises refuses the start", function()
        error("rule stubbed to raise", 0)
    end, nil, { "Failed to bind 0.0.0.0:", "the loopback rule raised: rule stubbed to raise" })
end)

-- The root was resolved after the server's socket was bound, and its raise
-- left that socket open for the rest of the session.
H.case("a root that does not resolve is refused before any socket opens", function()
    local missing = vim.fs.joinpath(root, "missing")
    local tcps = H.handle_count("tcp")
    local started, res = pcall(server.start, { port = 0, root = missing })
    local after = H.handle_count("tcp")
    if started then
        server.stop(res)
    end
    ok(
        not started and tostring(res) == "Invalid root: " .. missing,
        "a missing root is refused, naming it: " .. tostring(res)
    )
    eq(after, tcps, "and opens no socket")
    -- fs_realpath raised its own argument error for a nil root, naming no
    -- option, and read a number as a path under the working directory.
    for _, case in ipairs({ { "nil", nil }, { "42", 42 } }) do
        local before = H.handle_count("tcp")
        local bad_started, bad = pcall(server.start, { port = 0, root = case[2] })
        local bad_after = H.handle_count("tcp")
        if bad_started then
            server.stop(bad)
        end
        ok(
            not bad_started and tostring(bad) == "root must be a string",
            ("root = %s is refused, naming root: %s"):format(case[1], tostring(bad))
        )
        eq(bad_after, before, ("root = %s opens no socket"):format(case[1]))
    end
end)

-- new_tcp's nil went unread, so the bind indexed it and raised at the
-- server's own line, naming nothing a user could act on.
H.case("a start that cannot make its socket raises, naming it, and opens nothing", function()
    local real_new_tcp = vim.uv.new_tcp
    H.defer(function()
        vim.uv.new_tcp = real_new_tcp
    end)
    local tcps, timers = H.handle_count("tcp"), H.handle_count("timer")
    vim.uv.new_tcp = function()
        return nil, "ENOMEM: stubbed", "ENOMEM"
    end
    local started, res = pcall(server.start, { port = 0, root = root })
    vim.uv.new_tcp = real_new_tcp
    if started then
        server.stop(res)
    end
    ok(
        not started
            and tostring(res):find("Failed to bind 127.0.0.1:0: no socket", 1, true) ~= nil
            and tostring(res):find("ENOMEM: stubbed", 1, true) ~= nil,
        "a start whose socket cannot be made raises, naming it: " .. tostring(res)
    )
    eq(H.handle_count("tcp"), tcps, "and opens no socket")
    eq(H.handle_count("timer"), timers, "and no timer")
end)

-- A port taken between the bind and the listen fails the listen, after
-- the socket, the reload timer and the file watchers were open: the socket
-- was closed and the timer and watchers were left running. The stub hands
-- start a socket whose listen answers so.
H.case("a listen that fails leaves no socket, timer or watcher", function()
    local real_new_tcp = vim.uv.new_tcp
    H.defer(function()
        vim.uv.new_tcp = real_new_tcp
    end)
    vim.uv.new_tcp = function(...)
        local handle, err = real_new_tcp(...)
        if not handle then
            return handle, err
        end
        return setmetatable({}, {
            __index = function(_, name)
                if name == "listen" then
                    return function()
                        return nil, "EADDRINUSE: stubbed"
                    end
                end
                return function(_, ...)
                    return handle[name](handle, ...)
                end
            end,
        })
    end
    for _, live in ipairs({ false, true }) do
        local label = live and "with live reload on" or "with live reload off"
        local before = {}
        for _, kind in ipairs({ "tcp", "timer", "fs_event" }) do
            before[kind] = H.handle_count(kind)
        end
        local started, res = pcall(server.start, { port = 0, root = root, live = { enabled = live } })
        local after = {}
        for _, kind in ipairs({ "tcp", "timer", "fs_event" }) do
            after[kind] = H.handle_count(kind)
        end
        if started then
            server.stop(res)
        end
        ok(
            not started
                and tostring(res):find("Failed to listen on", 1, true) ~= nil
                and tostring(res):find("EADDRINUSE: stubbed", 1, true) ~= nil,
            ("%s, a failed listen raises, naming it: %s"):format(label, tostring(res))
        )
        eq(after.tcp, before.tcp, label .. ", it leaves no socket")
        eq(after.timer, before.timer, label .. ", no timer")
        eq(after.fs_event, before.fs_event, label .. ", and no watcher")
    end
end)

-- The reload timer's nil went unread, so a start served with none and
-- the first file change raised in the watcher's callback, where the
-- reload indexes it. With the beat off, the reload's is the one timer
-- start makes.
H.case("a start that cannot make its reload timer raises, naming it, and leaves nothing open", function()
    local real_new_timer = vim.uv.new_timer
    H.defer(function()
        vim.uv.new_timer = real_new_timer
    end)
    for _, live in ipairs({ false, true }) do
        local label = live and "with live reload on" or "with live reload off"
        local before = {}
        for _, kind in ipairs({ "tcp", "timer", "fs_event" }) do
            before[kind] = H.handle_count(kind)
        end
        vim.uv.new_timer = function()
            return nil, "ENOMEM: stubbed", "ENOMEM"
        end
        local started, res = pcall(server.start, {
            port = 0,
            root = root,
            live = { enabled = live },
            sse_heartbeat_ms = 0,
        })
        vim.uv.new_timer = real_new_timer
        local after = {}
        for _, kind in ipairs({ "tcp", "timer", "fs_event" }) do
            after[kind] = H.handle_count(kind)
        end
        if started then
            server.stop(res)
        end
        ok(
            not started
                and tostring(res):find("reload timer", 1, true) ~= nil
                and tostring(res):find("ENOMEM: stubbed", 1, true) ~= nil
                and not tostring(res):find("%.lua:%d+: "),
            ("%s, a start whose reload timer cannot be made raises at level 0, naming it: %s"):format(
                label,
                tostring(res)
            )
        )
        eq(after.tcp, before.tcp, label .. ", it leaves no socket")
        eq(after.timer, before.timer, label .. ", no timer")
        eq(after.fs_event, before.fs_event, label .. ", and no watcher")
    end
end)

-- A table that computes a field could pass a check with one value and
-- hand the server another, so every option is read once, by the check,
-- and the server keeps what the check read. A read of the caller's table
-- after the check reads an option twice.
H.case("start reads each option from the caller's table once", function()
    local given = {
        port = 0,
        host = "127.0.0.1",
        root = root,
        default_index = vim.fs.joinpath(root, "index.html"),
        token = TOKEN,
        protected_paths = { "^/content%.md$" },
        allowed_hosts = { "dev.test" },
        index_names = { "index.html" },
        serve_dotfiles = false,
        headers = { ["X-Custom"] = "1" },
        cors = { "http://a.example" },
        live = { enabled = false, inject_script = false, debounce = 50, css_inject = false },
        features = { dirlist = { enabled = false, show_hidden = false } },
        notify_on_reload = false,
        asset_root = root,
        header_timeout_ms = 5000,
        sse_heartbeat_ms = 20000,
        max_connections = 64,
    }
    local reads = {}
    -- A nested table is counted too, each read under its dotted name.
    local function counted(tbl, prefix)
        return setmetatable({}, {
            __index = function(_, key)
                local name = prefix .. key
                reads[name] = (reads[name] or 0) + 1
                local v = tbl[key]
                if type(v) == "table" and (name == "live" or name == "features" or name == "features.dirlist") then
                    return counted(v, name .. ".")
                end
                return v
            end,
        })
    end
    for _, name in ipairs({
        "live.enabled",
        "live.inject_script",
        "live.debounce",
        "live.css_inject",
        "features.dirlist",
        "features.dirlist.enabled",
        "features.dirlist.show_hidden",
    }) do
        reads[name] = 0
    end
    local computed = counted(given, "")
    local inst = server.start(computed)
    H.defer(function()
        server.stop(inst)
    end)
    local keys = vim.tbl_keys(vim.tbl_extend("force", {}, given, reads))
    table.sort(keys)
    local not_once = {}
    for _, key in ipairs(keys) do
        if reads[key] ~= 1 then
            table.insert(not_once, ("%s read %d times"):format(key, reads[key] or 0))
        end
    end
    eq(table.concat(not_once, ", "), "", "start reads each option it is given, and any other, once")
end)

-- The caller shows a refusal to the user as it is raised, so a check at
-- level 1 would lead with the server's file and line. Last, so it reads
-- every refusal the cases above provoked.
H.case("every refusal the suite provokes raises at level 0", function()
    local positioned = {}
    for _, msg in ipairs(refusals) do
        if msg:find("%.lua:%d+: ") then
            table.insert(positioned, msg)
        end
    end
    ok(
        #refusals > 0 and #positioned == 0,
        ("each of the %d refusals is its message alone: %s"):format(#refusals, table.concat(positioned, " | "))
    )
end)

H.finish()
