-- tests/script_injection_test.lua
-- The reload script goes into HTML a browser navigates to, not into HTML a
-- page's own script fetches, where it would run nowhere and change the
-- bytes the page reads. Every navigation carries Sec-Fetch-Mode: navigate
-- (a page, a frame, an object, an embed, a service worker's pass-through)
-- and a page's fetch never does; a client with no Fetch Metadata keeps it.
--
-- Run: nvim --headless -u NONE -l "$PWD/tests/script_injection_test.lua"

local H = dofile(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "helpers.lua"))
H.isolate()
H.rtp()

local server = require("live_server.server")
local eq, ok = H.eq, H.ok

local PAGE = "<html><body>p</body></html>"
local TAG = '<script src="/__live/script.js"></script>'

local function serve(root, cfg)
    local inst = server.start(vim.tbl_extend("keep", cfg or {}, {
        port = 0,
        root = root,
        live = { enabled = false, inject_script = true },
        features = { dirlist = { enabled = true } },
    }))
    H.defer(function()
        server.stop(inst)
    end)
    return inst
end

local function fetch(port, path, mode, dest)
    local marks = ""
    if mode then
        marks = marks .. "Sec-Fetch-Mode: " .. mode .. "\r\n"
    end
    if dest then
        marks = marks .. "Sec-Fetch-Dest: " .. dest .. "\r\n"
    end
    local raw = ("GET %s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n%s\r\n"):format(path, port, marks)
    return H.response(assert(H.raw_request(port, raw)))
end

H.case("Section 1: only a navigation gets the reload script", function()
    local root = H.tmpdir()
    H.write_file(root .. "/page.html", PAGE)
    vim.fn.mkdir(root .. "/dir", "p")
    H.write_file(root .. "/dir/a.txt", "a")
    local port = serve(root).port

    local injected = (PAGE:gsub("</body>", TAG .. "</body>"))
    eq(fetch(port, "/page.html").body, injected, "no Fetch Metadata keeps the script")
    for _, dest in ipairs({ "document", "iframe", "frame", "object", "embed" }) do
        local r = fetch(port, "/page.html", "navigate", dest)
        eq(r.status, 200, "a navigation with Sec-Fetch-Dest: " .. dest .. " is 200")
        eq(r.body, injected, "and gets the script (Sec-Fetch-Dest: " .. dest .. ")")
    end

    -- A page's fetch or XHR (cors), a fetch with mode same-origin and a
    -- script load: the bytes as written. The mode alone decides, so a
    -- missing or a frame's Sec-Fetch-Dest changes nothing.
    for _, marks in ipairs({
        { "cors", "empty", "a page's fetch() or XHR" },
        { "same-origin", "empty", "a fetch with mode same-origin" },
        { "no-cors", "script", "HTML loaded as a script" },
        { "cors", nil, "a cors fetch with no Sec-Fetch-Dest" },
        { "same-origin", "iframe", "mode same-origin beside Sec-Fetch-Dest: iframe" },
    }) do
        local r = fetch(port, "/page.html", marks[1], marks[2])
        eq(r.status, 200, marks[3] .. " is 200")
        eq(r.body, PAGE, marks[3] .. " gets the bytes as written")
    end
    local dest_only = fetch(port, "/page.html", nil, "document")
    eq(dest_only.status, 200, "Sec-Fetch-Dest: document with no Sec-Fetch-Mode is 200")
    eq(dest_only.body, injected, "and gets the script, as a client with no mode does")
    local listing = fetch(port, "/dir/", "cors", "empty")
    eq(listing.status, 200, "a listing a script fetches is 200")
    ok(listing.body:find("a.txt", 1, true) ~= nil and not listing.body:find(TAG, 1, true), "and carries no script")
end)

H.case("Section 2: every page the server renders carries Vary", function()
    -- The body differs by Sec-Fetch-Mode, so a cached fetched copy would
    -- otherwise answer a later navigation without the script. The asset
    -- route streams an .html file as bytes and a 404 page varies on nothing.
    local root = H.tmpdir()
    H.write_file(root .. "/page.html", PAGE)
    local port = serve(root).port
    local injected = fetch(port, "/page.html", "navigate", "document")
    eq(injected.status, 200, "an injected page is served")
    eq(injected.headers.vary, "Sec-Fetch-Mode", "and names it")
    local written = fetch(port, "/page.html", "cors", "empty")
    eq(written.status, 200, "one as written is served")
    eq(written.headers.vary, "Sec-Fetch-Mode", "and names it too")
    local own = fetch(serve(root, { headers = { Vary = "Accept-Encoding" } }).port, "/page.html")
    eq(own.status, 200, "a configured Vary is served")
    eq(own.headers.vary, "Accept-Encoding, Sec-Fetch-Mode", "kept and joined")
    local both = fetch(serve(root, { headers = { Vary = "Accept-Encoding", vary = "Accept" } }).port, "/page.html")
    eq(both.status, 200, "two spellings of the name are served")
    eq(both.headers.vary, "Accept, Accept-Encoding, Sec-Fetch-Mode", "as one field")
    eq(both.count.vary, 1, "on one line")
    -- RFC 9110 5.6.1: a list carries no empty element and names a member once.
    local empty = fetch(serve(root, { headers = { Vary = "" } }).port, "/page.html")
    eq(empty.status, 200, "an empty configured Vary is served")
    eq(empty.headers.vary, "Sec-Fetch-Mode", "and adds no empty element")
    local named = fetch(serve(root, { headers = { Vary = "Sec-Fetch-Mode" } }).port, "/page.html")
    eq(named.status, 200, "a configured Vary of Sec-Fetch-Mode is served")
    eq(named.headers.vary, "Sec-Fetch-Mode", "and names it once")
    local twice = fetch(serve(root, { headers = { Vary = "sec-fetch-mode, Accept" } }).port, "/page.html")
    eq(twice.status, 200, "a configured list naming it in another case is served")
    eq(twice.headers.vary, "sec-fetch-mode, Accept", "and keeps its first spelling alone")
    local plain = fetch(serve(root, { live = { enabled = false, inject_script = false } }).port, "/page.html")
    eq(plain.status, 200, "with inject_script off a page is served")
    eq(plain.headers.vary, nil, "and carries no Vary: its body cannot vary")
end)

H.finish()
