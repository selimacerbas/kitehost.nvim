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

    -- A page's fetch, an XHR and a script load: the bytes as written.
    for _, marks in ipairs({
        { "cors", "empty", "a page's fetch()" },
        { "same-origin", "empty", "an XHR" },
        { "no-cors", "script", "HTML loaded as a script" },
    }) do
        local r = fetch(port, "/page.html", marks[1], marks[2])
        eq(r.status, 200, marks[3] .. " is 200")
        eq(r.body, PAGE, marks[3] .. " gets the bytes as written")
    end
    local listing = fetch(port, "/dir/", "cors", "empty")
    eq(listing.status, 200, "a listing a script fetches is 200")
    ok(listing.body:find("a.txt", 1, true) ~= nil and not listing.body:find(TAG, 1, true), "and carries no script")
end)

H.case("Section 2: every HTML response says it varies by Sec-Fetch-Mode", function()
    -- The body differs by that header, so a cached fetched copy would
    -- otherwise answer a later navigation without the script.
    local root = H.tmpdir()
    H.write_file(root .. "/page.html", PAGE)
    local port = serve(root).port
    eq(fetch(port, "/page.html", "navigate", "document").headers.vary, "Sec-Fetch-Mode", "an injected page names it")
    eq(fetch(port, "/page.html", "cors", "empty").headers.vary, "Sec-Fetch-Mode", "and so does one as written")
    local own = serve(root, { headers = { Vary = "Accept-Encoding" } })
    eq(
        fetch(own.port, "/page.html").headers.vary,
        "Accept-Encoding, Sec-Fetch-Mode",
        "a configured Vary is kept and joined"
    )
end)

H.finish()
