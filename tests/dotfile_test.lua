-- tests/dotfile_test.lua
-- Dotfiles hold secrets (.env, .git/config) and the listing already hid
-- them, yet the root route served them to anyone the server answers
-- (measured). The request path is checked, and the file served by
-- its path under the root, never the root's own path.
--
-- Run: nvim --headless -u NONE -l "$PWD/tests/dotfile_test.lua"

local H = dofile(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "helpers.lua"))
H.isolate()
H.rtp()

local uv = vim.uv
local server = require("live_server.server")
local eq, ok = H.eq, H.ok

local function serve(root, extra)
    local inst = server.start(vim.tbl_extend("keep", extra or {}, {
        port = 0,
        root = root,
        live = { enabled = false, inject_script = false },
        features = { dirlist = { enabled = false } },
    }))
    H.defer(function()
        server.stop(inst)
    end)
    return ("http://127.0.0.1:%d"):format(inst.port)
end

local root = H.tmpdir()
H.write_file(root .. "/index.html", "<html><body>ok</body></html>")
H.write_file(root .. "/.env", "API_KEY=SECRET-1")
vim.fn.mkdir(root .. "/.git", "p")
H.write_file(root .. "/.git/config", "SECRET-2")
vim.fn.mkdir(root .. "/.hidden", "p")
H.write_file(root .. "/.hidden/x", "SECRET-3")
vim.fn.mkdir(root .. "/sub", "p")
H.write_file(root .. "/sub/.env", "SECRET-4")
vim.fn.mkdir(root .. "/.well-known", "p")
H.write_file(root .. "/.well-known/x", "wk")

H.case("Section 1: dot segments are 404", function()
    local base = serve(root, { cors = true })
    for _, p in ipairs({ "/.env", "/.git/config", "/.hidden/x", "/sub/.env", "/%2eenv" }) do
        local r = H.http_get(base .. p)
        eq(r.status, 404, p .. " is 404")
        ok(not r.body:find("SECRET-", 1, true), p .. " shows no secret")
    end
    eq(H.http_get(base .. "/.well-known/x").body, "wk", "/.well-known/ is served")
    eq(H.http_get(base .. "/index.html").status, 200, "a plain file is served")
    local link = root .. "/pub.txt"
    local linked, link_err = uv.fs_symlink(".env", link)
    if linked and uv.fs_stat(link) then
        eq(H.http_get(base .. "/pub.txt").status, 404, "a link to .env is 404")
    else
        H.skip("a link to .env is 404 (" .. tostring(link_err or "the link does not resolve") .. ")")
    end
end)

H.case("Section 2: serve_dotfiles = true serves them", function()
    local base = serve(root, { serve_dotfiles = true })
    local r = H.http_get(base .. "/.env")
    eq(r.status, 200, "/.env is served when asked for")
    eq(r.body, "API_KEY=SECRET-1", "with its bytes")
end)

H.case("Section 3: a root inside a dot directory still serves", function()
    local dotted = H.tmpdir() .. "/.local/site"
    vim.fn.mkdir(dotted, "p")
    H.write_file(dotted .. "/index.html", "<html><body>dotted</body></html>")
    eq(H.http_get(serve(dotted) .. "/index.html").status, 200, "a root under .local serves /index.html")
end)

H.finish()
