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
vim.fn.mkdir(root .. "/list/.git", "p")
H.write_file(root .. "/list/.env", "SECRET-5")
H.write_file(root .. "/list/page.txt", "page")

-- The dot names a listing shows as entries; the parent row ("..") is none.
local function dot_names(body)
    local names = {}
    for label in body:gmatch('<a href="[^"]*">([^<]*)</a>') do
        if label:sub(1, 1) == "." and label ~= ".." then
            names[#names + 1] = label
        end
    end
    return names
end

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
    -- A scanner probes /.env.local blind; the link's target has a plain
    -- name, so only the request path carries the dot.
    local alias = root .. "/.env.local"
    local aliased, alias_err = uv.fs_symlink("index.html", alias)
    if aliased and uv.fs_stat(alias) then
        eq(H.http_get(base .. "/.env.local").status, 404, "a dot name linking to a plain name is 404")
    else
        H.skip(
            "a dot name linking to a plain name is 404 (" .. tostring(alias_err or "the link does not resolve") .. ")"
        )
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

-- show_hidden alone listed .env and .git to anyone the server answers,
-- linking names the dot rule then refused.
H.case("Section 4: a show_hidden listing names no dot entry the server refuses", function()
    local listing = { dirlist = { enabled = true, show_hidden = true } }
    local body = H.http_get(serve(root, { features = listing }) .. "/list/").body
    ok(body:find('href="/list/page.txt"', 1, true), "a show_hidden listing links its plain entry")
    ok(not body:find('href="/list/.env"', 1, true), "and no .env link without serve_dotfiles")
    eq(table.concat(dot_names(body), " "), "", "and names no dot entry")
    body = H.http_get(serve(root, { features = listing, serve_dotfiles = true }) .. "/list/").body
    ok(body:find('href="/list/.env"', 1, true), "with serve_dotfiles too it links .env")
    ok(body:find('href="/list/.git/"', 1, true), "and .git/")
    -- Serving dotfiles to a caller who asks for one by name lists none.
    local plain = { dirlist = { enabled = true } }
    body = H.http_get(serve(root, { features = plain, serve_dotfiles = true }) .. "/list/").body
    ok(
        body:find('href="/list/page.txt"', 1, true) and #dot_names(body) == 0,
        "serve_dotfiles alone lists page.txt and no dot entry"
    )
end)

H.finish()
