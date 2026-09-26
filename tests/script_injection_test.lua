-- tests/script_injection_test.lua
-- The reload script goes into pages a browser shows, not into HTML a
-- page's own script fetches (Sec-Fetch-Dest: empty), where it would run
-- nowhere and change the bytes the page reads.
--
-- Run: nvim --headless -u NONE -l tests/script_injection_test.lua

local H = dofile(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "helpers.lua"))
H.isolate()
H.rtp()

local server = require("live_server.server")
local ok = H.ok

H.case("Section 1: only a page a browser shows gets the reload script", function()
    local root = H.tmpdir()
    H.write_file(root .. "/page.html", "<html><body>p</body></html>")
    vim.fn.mkdir(root .. "/dir", "p")
    H.write_file(root .. "/dir/a.txt", "a")
    local inst = server.start({
        port = 0,
        root = root,
        live = { enabled = false, inject_script = true },
        features = { dirlist = { enabled = true } },
    })
    H.defer(function()
        server.stop(inst)
    end)
    local base = ("http://127.0.0.1:%d"):format(inst.port)
    local tag = "/__live/script.js"
    local function has_tag(path, dest)
        return H.http_get(base .. path, dest and { "Sec-Fetch-Dest: " .. dest } or nil).body:find(tag, 1, true) ~= nil
    end
    ok(not has_tag("/page.html", "empty"), "fetch() of a page gets no reload script")
    ok(has_tag("/page.html", "document"), "a navigation gets it")
    ok(has_tag("/page.html", "iframe"), "a frame gets it")
    ok(has_tag("/page.html", nil), "a client that sends no Sec-Fetch-Dest keeps it")
    ok(not has_tag("/dir/", "empty"), "a listing a script fetches gets none")
end)

H.finish()
