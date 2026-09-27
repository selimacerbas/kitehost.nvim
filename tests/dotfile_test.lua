-- tests/dotfile_test.lua
-- Dotfiles hold secrets (.env, .git/config), yet the root route served them
-- to anyone the server answers (measured). The request path is checked, and
-- the file served by its path under the root, never the root's own path.
-- Since the rule the listing hides them too, where show_hidden alone named
-- them, and a change to one sends no reload.
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
vim.fn.mkdir(root .. "/sub/.well-known", "p")
H.write_file(root .. "/sub/.well-known/x", "SECRET-6")
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
    -- RFC 8615 reserves the prefix at the path's root alone, so a nested
    -- .well-known is a dot directory like any other.
    local nested = H.http_get(base .. "/sub/.well-known/x")
    eq(nested.status, 404, "/sub/.well-known/x is 404")
    ok(not nested.body:find("SECRET-", 1, true), "/sub/.well-known/x shows no secret")
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

-- :LiveServerStart on a file serves it at /, and a draft named .draft.html
-- answered 404 there: the user's own choice is exempt from the dot rule,
-- while the same name asked for as a path stays refused.
H.case("Section 5: the file the user started on", function()
    local drafts = H.tmpdir()
    H.write_file(drafts .. "/.draft.html", "<html><body>DRAFT</body></html>")
    local base = serve(drafts, { default_index = drafts .. "/.draft.html" })
    local r = H.http_get(base .. "/")
    eq(r.status, 200, "/ serves a default_index named .draft.html")
    ok(r.body:find("DRAFT", 1, true) ~= nil, "with its body")
    eq(H.http_get(base .. "/.draft.html").status, 404, "/.draft.html asked for by name stays 404")
end)

-- An index.html linking to a dot name answered 404 for its whole
-- directory; it is no index of that directory, as one linking out of the
-- root is not, so the next name or the listing answers.
H.case("Section 6: an index the dot rule refuses is not the directory's", function()
    local site = H.tmpdir()
    for _, dir in ipairs({ "both", "solo" }) do
        vim.fn.mkdir(site .. "/" .. dir, "p")
        H.write_file(site .. "/" .. dir .. "/.page.html", "<html><body>DOTPAGE</body></html>")
    end
    H.write_file(site .. "/both/index.htm", "<html><body>PLAIN</body></html>")
    local both, both_err = uv.fs_symlink(".page.html", site .. "/both/index.html")
    local solo, solo_err = uv.fs_symlink(".page.html", site .. "/solo/index.html")
    if not (both and solo and uv.fs_stat(site .. "/both/index.html") and uv.fs_stat(site .. "/solo/index.html")) then
        local why = " (" .. tostring(both_err or solo_err or "the link does not resolve") .. ")"
        H.skip("an index.htm beside an index.html linking to a dot name is served" .. why)
        H.skip("with no other index the directory is listed" .. why)
        return
    end
    local base = serve(site, { features = { dirlist = { enabled = true } } })
    local r = H.http_get(base .. "/both/")
    ok(
        r.status == 200 and r.body:find("PLAIN", 1, true) ~= nil,
        ("an index.htm beside an index.html linking to a dot name is served (got %d)"):format(r.status)
    )
    r = H.http_get(base .. "/solo/")
    ok(
        r.status == 200 and r.body:find("Index of /solo/", 1, true) ~= nil and not r.body:find("DOTPAGE", 1, true),
        ("with no other index the directory is listed (got %d)"):format(r.status)
    )
end)

-- A write to .env or .git/index sent its name to every events client, the
-- name the listing hides, and reloaded the page for a change the server
-- never serves. The event names the path relative to the root: a watcher
-- on Linux names it in full, which told every events client where the root
-- sits on disk.
H.case("Section 7: a dot path's change sends no reload", function()
    local function watched(extra, site)
        site = site or H.tmpdir()
        vim.fn.mkdir(site .. "/.git", "p")
        local base = serve(
            site,
            vim.tbl_extend("keep", extra or {}, { live = { enabled = true, debounce = 20, inject_script = false } })
        )
        local port = tonumber(base:match(":(%d+)$"))
        local c = assert(H.raw_connect(port))
        assert(c:send(("GET /__live/events HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n\r\n"):format(port)))
        local head = c:read(2000, function(b)
            return b:find("retry: 1000\n\n", 1, true) ~= nil
        end)
        ok(head:find("retry: 1000", 1, true) ~= nil, "the events stream opens")
        -- FSEvents delivered a fixture written just before the watcher
        -- started after the stream opened (measured), so the stream settles
        -- and each row reads what follows the mark.
        vim.wait(300)
        return site, c, #table.concat(c.chunks)
    end
    local function reloaded(c, mark, ms, pattern)
        local got = c:read(ms, function(b)
            return b:find(pattern, mark + 1) ~= nil
        end)
        return got:find(pattern, mark + 1) ~= nil
    end
    local site, c, mark = watched()
    H.write_file(site .. "/.env", "API_KEY=SECRET-7")
    H.write_file(site .. "/.git/index", "SECRET-8")
    vim.wait(300)
    ok(not reloaded(c, mark, 1, "event: reload"), "a write to .env or .git/index sends no reload event")
    H.write_file(site .. "/page.html", "<html><body>changed</body></html>")
    ok(reloaded(c, mark, 2000, '"path":"page%.html"'), "a write to page.html reloads within 2 s, naming page.html")
    local open_site, open_c, open_mark = watched({ serve_dotfiles = true })
    H.write_file(open_site .. "/.env", "API_KEY=open")
    ok(reloaded(open_c, open_mark, 2000, '"path":"%.env"'), "with serve_dotfiles a write to .env reloads")
    -- A watcher on Linux names the full path, so the root's own is left out
    -- of the read, as the dot rule leaves it out of every request.
    local dotted = H.tmpdir() .. "/.local/site"
    vim.fn.mkdir(dotted, "p")
    local _, dc, dmark = watched(nil, dotted)
    H.write_file(dotted .. "/page.html", "<html><body>dotted</body></html>")
    ok(reloaded(dc, dmark, 2000, '"path":"page%.html"'), "a root under .local reloads for page.html")
end)

-- The listing read an entry's own name, so a plain-named link to a dot name
-- (cfg -> .git, dotlink -> .env) was listed and then 404 on click. A link is
-- judged by where it points: outside the root or nowhere, no flag opens it;
-- a dot name below the listed directory is shown with both flags alone, as
-- a dot entry is; the directory's own segments passed the rule already.
H.case("Section 8: a listing judges a link by where it points", function()
    local site = H.tmpdir()
    local sep = package.config:sub(1, 1)
    vim.fn.mkdir(site .. "/.git", "p")
    H.write_file(site .. "/.git/config", "SECRET-9")
    H.write_file(site .. "/.env", "SECRET-10")
    H.write_file(site .. "/page.txt", "page")
    vim.fn.mkdir(site .. "/.hidden", "p")
    H.write_file(site .. "/.hidden/target.txt", "target")
    H.write_file(site .. "/.hidden/.inner", "SECRET-11")
    vim.fn.mkdir(site .. "/sub/.well-known", "p")
    H.write_file(site .. "/sub/.well-known/x", "SECRET-12")
    H.write_file(site .. "/sub/f.txt", "f")
    -- { target, link, whether the target exists }
    local links = {
        { ".git", "cfg", true },
        { ".env", "dotlink", true },
        { "target.txt", ".hidden/plain", true },
        { ".inner", ".hidden/hid2", true },
        { "missing.txt", "gone", false },
        { ".well-known" .. sep .. "x", "sub/wk", true },
    }
    local why
    for _, l in ipairs(links) do
        local at = site .. "/" .. l[2]
        local linked, err = uv.fs_symlink(l[1], at)
        if not linked or not uv.fs_lstat(at) or (l[3] and not uv.fs_stat(at)) then
            why = " (" .. tostring(err or "the link does not resolve") .. ")"
            break
        end
    end
    local rows = {
        "a listing without the flags names no link to a dot name",
        "with show_hidden and serve_dotfiles both links are listed",
        "with serve_dotfiles /.hidden/ names a link to a plain name inside it",
        "and no link to a dot name inside it",
        "with both flags /.hidden/ names that link too",
        "a dangling link is not named without the flags",
        "nor with show_hidden and serve_dotfiles",
        "a link in sub/ to its .well-known is not named",
    }
    if why then
        for _, row in ipairs(rows) do
            H.skip(row .. why)
        end
        return
    end
    local listing = { dirlist = { enabled = true } }
    local all = { dirlist = { enabled = true, show_hidden = true } }
    local plain = serve(site, { features = listing })
    local dotted = serve(site, { features = listing, serve_dotfiles = true })
    local open = serve(site, { features = all, serve_dotfiles = true })
    -- The hrefs a listing names; a negative row reads a body that names a
    -- plain entry too, so a dead listener fails it.
    local function hrefs(base, path)
        local found = {}
        for href in H.http_get(base .. path).body:gmatch('href="([^"]*)"') do
            found[href] = true
        end
        return found
    end
    local root_plain, root_open = hrefs(plain, "/"), hrefs(open, "/")
    local hidden_dotted, hidden_open = hrefs(dotted, "/.hidden/"), hrefs(open, "/.hidden/")
    local sub_plain = hrefs(plain, "/sub/")
    ok(root_plain["/page.txt"] and not root_plain["/cfg"] and not root_plain["/dotlink"], rows[1])
    ok(root_open["/cfg"] and root_open["/dotlink"], rows[2])
    ok(hidden_dotted["/.hidden/plain"], rows[3])
    ok(hidden_dotted["/.hidden/target.txt"] and not hidden_dotted["/.hidden/hid2"], rows[4])
    ok(hidden_open["/.hidden/plain"], rows[5])
    ok(root_plain["/page.txt"] and not root_plain["/gone"], rows[6])
    ok(root_open["/page.txt"] and not root_open["/gone"], rows[7])
    ok(sub_plain["/sub/f.txt"] and not sub_plain["/sub/wk"], rows[8])
end)

-- luv gives no type for an entry a filesystem leaves untyped (XFS with
-- ftype=0, some NFS and FUSE mounts), and the link check ran for "link"
-- alone, so there cfg -> .git was listed by name. The scan is wrapped to
-- drop every type, as such a mount reports it.
H.case("Section 9: an entry the scan leaves untyped is judged as a link", function()
    local site = H.tmpdir()
    vim.fn.mkdir(site .. "/.git", "p")
    H.write_file(site .. "/page.txt", "page")
    local linked, link_err = uv.fs_symlink(".git", site .. "/cfg")
    if not (linked and uv.fs_stat(site .. "/cfg")) then
        H.skip(
            "an untyped cfg -> .git is not listed, page.txt is ("
                .. tostring(link_err or "the link does not resolve")
                .. ")"
        )
        return
    end
    local base = serve(site, { features = { dirlist = { enabled = true } } })
    local real_next = uv.fs_scandir_next
    H.defer(function()
        uv.fs_scandir_next = real_next
    end)
    uv.fs_scandir_next = function(iter)
        local name = real_next(iter)
        return name
    end
    local body = H.http_get(base .. "/").body
    uv.fs_scandir_next = real_next
    ok(
        body:find('href="/page.txt"', 1, true) ~= nil and not body:find('href="/cfg', 1, true),
        "an untyped cfg -> .git is not listed, page.txt is"
    )
end)

H.finish()
