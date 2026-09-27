-- tests/client_js_test.lua
-- The reload client. A token server gates its event stream, and the
-- client opened it without the token, got 401 and never reconnected, so
-- live reload died in the README's network setup.
--
-- Run: nvim --headless -u NONE -l "$PWD/tests/client_js_test.lua"

local H = dofile(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "helpers.lua"))
H.isolate()
H.rtp()

local server = require("live_server.server")
local eq, ok = H.eq, H.ok

local root = H.tmpdir()
H.write_file(root .. "/index.html", "<html><body>ok</body></html>")

local function script(cfg)
    local inst = server.start(vim.tbl_extend("keep", cfg or {}, {
        port = 0,
        root = root,
        live = { enabled = false, inject_script = true },
        features = { dirlist = { enabled = false } },
    }))
    H.defer(function()
        server.stop(inst)
    end)
    return H.http_get(("http://127.0.0.1:%d/__live/script.js"):format(inst.port))
end

H.case("Section 1: a tokenless server's client is the one it always served", function()
    local r = script()
    eq(r.status, 200, "the client is served")
    eq(#r.body, 576, "576 bytes, as at 3a13c7c")
    eq(
        vim.fn.sha256(r.body),
        "376cf1554a8830f105cc712512d33e040427288a9c94b9bcb19707627c3023b6",
        "the same bytes as at 3a13c7c"
    )
end)

H.case("Section 2: a token server's client carries the page's token to the stream", function()
    local r = script({ token = "tok123" })
    eq(r.status, 200, "the client is served without the token")
    ok(r.body:find("location.search", 1, true) ~= nil, "it reads t from the page's query")
    ok(r.body:find("sessionStorage", 1, true) ~= nil, "and keeps it for reloads that drop the query")
    ok(
        r.body:find("'/__live/events'+(t?'?t='+encodeURIComponent(t):'')", 1, true) ~= nil,
        "and puts it on the event stream"
    )
    ok(not r.body:find("tok123", 1, true), "the token itself is never in the script")
end)

H.finish()
