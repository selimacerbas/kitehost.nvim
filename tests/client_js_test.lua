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
    eq(#r.body, 576, "576 bytes, as v1.5.0 served")
    eq(
        vim.fn.sha256(r.body),
        "376cf1554a8830f105cc712512d33e040427288a9c94b9bcb19707627c3023b6",
        "the same bytes as v1.5.0 served"
    )
end)

H.case("Section 2: a token server's client carries the page's token to the stream", function()
    local r = script({ token = "tok123" })
    eq(r.status, 200, "the client is served without the token")
    -- Substrings alone passed a client with a syntax error, which dies on
    -- every token server, so its bytes are pinned as the tokenless one's
    -- are; the rows after the pin say what those bytes must hold.
    eq(#r.body, 895, "895 bytes, pinned as the tokenless client is")
    eq(vim.fn.sha256(r.body), "92ea71842af33078fc3c1646707d468853da389b5f3465d5edf32223aa152e86", "and by its sha256")
    ok(r.body:find("location.search", 1, true) ~= nil, "it reads t from the page's query")
    ok(r.body:find("sessionStorage", 1, true) ~= nil, "and keeps it for reloads that drop the query")
    ok(
        r.body:find("'/__live/events'+(t?'?t='+encodeURIComponent(t):'')", 1, true) ~= nil,
        "and puts it on the event stream"
    )
    local hint = "[live-server.nvim] no token: open the page through the URL the server printed (with ?t=)"
    ok(r.body:find(hint, 1, true) ~= nil, "a page with no token is told where to find one")
    ok(not r.body:find("localStorage", 1, true), "the token is never kept in localStorage, which outlives the tab")
    ok(not r.body:find("tok123", 1, true), "the token itself is never in the script")
end)

H.finish()
