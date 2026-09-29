-- tests/dotfile_test.lua
-- Dotfiles hold secrets (.env, .git/config), yet the root route served them
-- to anyone the server answers (measured). The request path is checked, and
-- the file served by its path under the root, never the root's own path.
-- Since the rule the listing hides them too, where show_hidden alone named
-- them, and a change to one sends no reload. A .liveignore that is not a
-- regular file (a FIFO, a directory), cannot be read or is over 64 KiB (a
-- link to a large file among them) is never read, gives no rule and is
-- named once; the FIFO row starts in a child Neovim bounded at 5 s. A
-- start refused after reading it warns nothing, and a retarget to another
-- root warns anew. One debounce window reloads the page when any change
-- in it is not a stylesheet, a path gone by the send is dropped (a
-- save's probe and backup files, a temporary name renamed away), and a
-- window names its latest page change however long the burst.
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

-- The reload events in data after byte mark, each decoded: the payload's
-- escaping is the JSON library's (0.10's writes a slash as \/, measured),
-- so no row reads its bytes. One that does not decode is kept as a path
-- naming it, so a row's message shows it.
local function reloads(data, mark)
    local got = {}
    for payload in data:sub(mark + 1):gmatch("event: reload\ndata: ([^\n]*)\n\n") do
        local decoded, obj = pcall(vim.json.decode, payload)
        got[#got + 1] = decoded and type(obj) == "table" and obj or { path = "undecodable " .. payload }
    end
    return got
end

-- Whether an event in data after mark reloads for want: a path, a test
-- of the decoded payload, or any reload when nil.
local function reloads_for(data, mark, want)
    for _, obj in ipairs(reloads(data, mark)) do
        if want == nil or obj.path == want or (type(want) == "function" and want(obj)) then
            return true
        end
    end
    return false
end

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
-- root is not, so the next name or the listing answers. An index name
-- that is itself a dot name is passed over the same way.
H.case("Section 6: an index the dot rule refuses is not the directory's", function()
    local named = H.tmpdir()
    H.write_file(named .. "/.index.html", "<html><body>DOTINDEX</body></html>")
    H.write_file(named .. "/index.htm", "<html><body>PLAININDEX</body></html>")
    local names = { ".index.html", "index.htm" }
    local got = H.http_get(serve(named, { index_names = names }) .. "/")
    ok(
        got.status == 200 and got.body:find("PLAININDEX", 1, true) ~= nil,
        ("index_names = { .index.html, index.htm } serves index.htm without serve_dotfiles (got %d)"):format(got.status)
    )
    got = H.http_get(serve(named, { index_names = names, serve_dotfiles = true }) .. "/")
    ok(
        got.status == 200 and got.body:find("DOTINDEX", 1, true) ~= nil,
        ("and .index.html with it (got %d)"):format(got.status)
    )
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
-- sits on disk. The file the user started on is served at / whatever its
-- name or the directory holding it, so its change reloads, naming /: the
-- page at / is what reloads, and a dot path it sits under stays unnamed.
H.case("Section 7: a dot path's change sends no reload", function()
    local function watched(extra, site)
        site = site or H.tmpdir()
        vim.fn.mkdir(site .. "/.git", "p")
        vim.fn.mkdir(site .. "/.hidden", "p")
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
    -- Whether a reload for want (reloads_for's) arrives after mark within
    -- ms.
    local function reloaded(c, mark, ms, want)
        local got = c:read(ms, function(b)
            return reloads_for(b, mark, want)
        end)
        return reloads_for(got, mark, want)
    end
    -- A late event sits before the one a row waited for, so a row that
    -- says none arrived reads the whole stream after its mark: whether a
    -- reload after it names a path matching the Lua pattern.
    local function streamed(c, mark, pattern)
        for _, obj in ipairs(reloads(table.concat(c.chunks), mark)) do
            if tostring(obj.path):find(pattern) then
                return true
            end
        end
        return false
    end
    -- The paths the events after a mark name, for a row's message.
    local function named(c, mark)
        local paths = {}
        for _, obj in ipairs(reloads(table.concat(c.chunks), mark)) do
            paths[#paths + 1] = tostring(obj.path)
        end
        return "(named: " .. table.concat(paths, " ") .. ")"
    end
    local site, c, mark = watched()
    H.write_file(site .. "/.env", "API_KEY=SECRET-7")
    H.write_file(site .. "/.git/index", "SECRET-8")
    vim.wait(300)
    local early = reloaded(c, mark, 1)
    H.write_file(site .. "/page.html", "<html><body>changed</body></html>")
    local page = reloaded(c, mark, 2000, "page.html")
    ok(
        not early and not streamed(c, mark, "^%.env$") and not streamed(c, mark, "^%.git"),
        "a write to .env or .git/index sends no reload event"
    )
    ok(page, "a write to page.html reloads within 2 s, naming page.html")
    local open_site, open_c, open_mark = watched({ serve_dotfiles = true })
    H.write_file(open_site .. "/.env", "API_KEY=open")
    ok(reloaded(open_c, open_mark, 2000, ".env"), "with serve_dotfiles a write to .env reloads")
    -- A watcher per directory (Linux) spent a watch on every dot directory
    -- but .git, whose changes the rule drops, and none on .git when
    -- serve_dotfiles admits it.
    H.write_file(open_site .. "/.hidden/x", "x")
    ok(reloaded(open_c, open_mark, 2000, ".hidden/x"), "and a write to .hidden/x")
    H.write_file(open_site .. "/.git/index", "index")
    ok(reloaded(open_c, open_mark, 2000, ".git/index"), "and a write to .git/index")
    local own_site = H.tmpdir()
    H.write_file(own_site .. "/.draft.html", "<html><body>DRAFT</body></html>")
    local _, oc, omark = watched({ default_index = own_site .. "/.draft.html" }, own_site)
    H.write_file(own_site .. "/.env", "API_KEY=SECRET-13")
    vim.wait(300)
    H.write_file(own_site .. "/.draft.html", "<html><body>DRAFT 2</body></html>")
    ok(
        reloaded(oc, omark, 2000, "/") and not streamed(oc, omark, "draft"),
        "a write to the file the user started on, .draft.html, reloads, naming / " .. named(oc, omark)
    )
    ok(not streamed(oc, omark, "^%.env$"), "and a write to .env beside it still sends none")
    -- A watcher per directory (Linux) spent no watch on the dot directory
    -- holding the file the user started on, so it never reloaded, and the
    -- other watchers named that dot path, a link's target too, to every
    -- events client.
    local held = H.tmpdir()
    vim.fn.mkdir(held .. "/.drafts", "p")
    H.write_file(held .. "/.drafts/page.html", "<html><body>DRAFT</body></html>")
    local _, hc, hmark = watched({ default_index = held .. "/.drafts/page.html" }, held)
    H.write_file(held .. "/.drafts/other.html", "SECRET-14")
    vim.wait(300)
    H.write_file(held .. "/.drafts/page.html", "<html><body>DRAFT 2</body></html>")
    ok(
        reloaded(hc, hmark, 2000, "/") and not streamed(hc, hmark, "drafts/page"),
        "a write to a default_index under .drafts/ reloads, naming / " .. named(hc, hmark)
    )
    ok(
        not streamed(hc, hmark, "other%.html"),
        "and a write to a file beside it in .drafts/ still sends none " .. named(hc, hmark)
    )
    local linked = H.tmpdir()
    vim.fn.mkdir(linked .. "/.hidden", "p")
    H.write_file(linked .. "/.hidden/real.html", "<html><body>REAL</body></html>")
    local made, made_err = uv.fs_symlink(".hidden/real.html", linked .. "/page.html")
    if made and uv.fs_stat(linked .. "/page.html") then
        local _, lc, lmark = watched({ default_index = linked .. "/page.html" }, linked)
        H.write_file(linked .. "/page.html", "<html><body>REAL 2</body></html>")
        ok(
            reloaded(lc, lmark, 2000, "/") and not streamed(lc, lmark, "real%.html"),
            "and one started on page.html, a link to .hidden/real.html, naming / and never its target "
                .. named(lc, lmark)
        )
    else
        H.skip(
            "and one started on page.html, a link to .hidden/real.html, naming / and never its target ("
                .. tostring(made_err or "the link does not resolve")
                .. ")"
        )
    end
    -- A watcher on Linux names the full path, so the root's own is left out
    -- of the read, as the dot rule leaves it out of every request.
    local dotted = H.tmpdir() .. "/.local/site"
    vim.fn.mkdir(dotted, "p")
    local _, dc, dmark = watched(nil, dotted)
    H.write_file(dotted .. "/page.html", "<html><body>dotted</body></html>")
    ok(reloaded(dc, dmark, 2000, "page.html"), "a root under .local reloads for page.html")
    -- .liveignore read that full path too, so a line naming a directory
    -- above the root dropped every reload there.
    local ignoring = H.tmpdir() .. "/dist/site"
    vim.fn.mkdir(ignoring, "p")
    H.write_file(ignoring .. "/.liveignore", "dist\n*.log\n")
    local _, ic, imark = watched(nil, ignoring)
    H.write_file(ignoring .. "/notes.log", "log")
    vim.wait(300)
    H.write_file(ignoring .. "/page.html", "<html><body>ignoring</body></html>")
    ok(reloaded(ic, imark, 2000, "page.html"), "a .liveignore line naming a directory above the root drops no reload")
    ok(not streamed(ic, imark, "notes%.log"), "and a line naming *.log still drops notes.log's")
    -- A line with a leading slash matched the relative path only where a
    -- directory above supplied the slash, so /dist dropped sub/dist/'s
    -- reloads and never dist/'s; it anchors at the root on every watcher,
    -- and a line without one matches anywhere in the path.
    local function ignore_site(lines)
        local site = H.tmpdir()
        vim.fn.mkdir(site .. "/dist", "p")
        vim.fn.mkdir(site .. "/sub/dist", "p")
        H.write_file(site .. "/.liveignore", lines)
        return site
    end
    local anchored = ignore_site("/dist\n")
    local _, ac, amark = watched(nil, anchored)
    H.write_file(anchored .. "/dist/x.js", "x")
    vim.wait(300)
    H.write_file(anchored .. "/sub/dist/y.js", "y")
    ok(
        reloaded(ac, amark, 2000, "sub/dist/y.js") and not streamed(ac, amark, "^dist/"),
        "a .liveignore line /dist drops dist/x.js's reload and not sub/dist/y.js's " .. named(ac, amark)
    )
    local loose = ignore_site("dist\n")
    local _, uc, umark = watched(nil, loose)
    H.write_file(loose .. "/dist/x.js", "x")
    H.write_file(loose .. "/sub/dist/y.js", "y")
    vim.wait(300)
    H.write_file(loose .. "/page.html", "<html><body>loose</body></html>")
    ok(
        reloaded(uc, umark, 2000, "page.html") and not streamed(uc, umark, "dist/"),
        "and a line dist drops both " .. named(uc, umark)
    )
    -- A started-on file with a plain name keeps its path in the payload, so
    -- a stylesheet started on still swaps instead of reloading the page.
    local css_site = H.tmpdir()
    H.write_file(css_site .. "/style.css", "body{}")
    local _, cc, cmark = watched({ default_index = css_site .. "/style.css" }, css_site)
    H.write_file(css_site .. "/style.css", "body{color:red}")
    ok(
        reloaded(cc, cmark, 2000, function(obj)
            return obj.path == "style.css" and obj.css == true
        end),
        "a started-on style.css reloads as a stylesheet swap, named " .. named(cc, cmark)
    )
    -- A .liveignore line holding a bracket raised inside the watcher once
    -- its literal prefix matched a path, and the reload was lost; a question
    -- mark made the character before it optional, so a?b dropped every path
    -- holding a b; every pattern character is escaped.
    local bracket = ignore_site("draft[\n")
    local _, bc, bmark = watched(nil, bracket)
    H.write_file(bracket .. "/draft.html", "<html><body>bracket</body></html>")
    ok(
        reloaded(bc, bmark, 2000, "draft.html"),
        "a .liveignore line with a bracket is read and draft.html reloads " .. named(bc, bmark)
    )
    local question = ignore_site("a?b\n")
    local _, qc, qmark = watched(nil, question)
    H.write_file(question .. "/axb.txt", "x")
    ok(
        reloaded(qc, qmark, 2000, "axb.txt"),
        "a .liveignore line a?b is literal, so axb.txt reloads " .. named(qc, qmark)
    )
end)

-- libuv names an event on the watched directory itself by the directory's
-- own name, which read as a child of that name: the payload named the
-- root's directory, and a root named .drafts dropped the reload. The libuv
-- of Neovim 0.10 on macOS reports no such event (measured), so the rows
-- are read where a watcher sees one.
H.case("Section 7b: a change to the root itself reloads, naming /", function()
    local function own_event_seen()
        local dir = H.tmpdir()
        local ev = assert(uv.new_fs_event())
        H.defer(function()
            if not ev:is_closing() then
                ev:close()
            end
        end)
        local seen = false
        assert(ev:start(dir, {}, function()
            seen = true
        end))
        vim.wait(300)
        seen = false
        assert(uv.fs_chmod(dir, 448))
        vim.wait(1000, function()
            return seen
        end, 5)
        return seen
    end
    local rows = {
        { "site", "a chmod of the root reloads, naming /" },
        { ".drafts", "and of a root named .drafts" },
    }
    if not own_event_seen() then
        for _, row in ipairs(rows) do
            H.skip(row[2] .. " (this watcher reports no event for the directory it watches)")
        end
        return
    end
    for _, row in ipairs(rows) do
        local site = H.tmpdir() .. "/" .. row[1]
        vim.fn.mkdir(site, "p")
        local base = serve(site, { live = { enabled = true, debounce = 20, inject_script = false } })
        local port = tonumber(base:match(":(%d+)$"))
        local c = assert(H.raw_connect(port))
        assert(c:send(("GET /__live/events HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n\r\n"):format(port)))
        c:read(2000, function(b)
            return b:find("retry: 1000\n\n", 1, true) ~= nil
        end)
        vim.wait(300)
        local mark = #table.concat(c.chunks)
        assert(uv.fs_chmod(site, 448))
        local got = c:read(2000, function(b)
            return reloads_for(b, mark, "/")
        end)
        local named = {}
        for _, obj in ipairs(reloads(got, mark)) do
            named[#named + 1] = tostring(obj.path)
        end
        ok(reloads_for(got, mark, "/"), ("%s (named: %s)"):format(row[2], table.concat(named, " ")))
    end
end)

-- The listing read an entry's own name, so a plain-named link to a dot name
-- (cfg -> .git, dotlink -> .env) was listed and then 404 on click. A link is
-- judged by where it points: outside the root or nowhere, no flag opens it;
-- a link to a dot name is shown with serve_dotfiles, with which the rule
-- refuses nothing, inside or beside a listed .hidden/ alike.
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
    vim.fn.mkdir(site .. "/.hidden/a", "p")
    H.write_file(site .. "/.hidden/b.txt", "b")
    H.write_file(site .. "/.hidden/a/own.txt", "own")
    -- { target, link, whether the target exists }
    local links = {
        { ".git", "cfg", true },
        { ".env", "dotlink", true },
        { "target.txt", ".hidden/plain", true },
        { ".inner", ".hidden/hid2", true },
        { "missing.txt", "gone", false },
        { ".well-known" .. sep .. "x", "sub/wk", true },
        { ".." .. sep .. "b.txt", ".hidden/a/up", true },
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
        "and a link to a dot name inside it too, which serve_dotfiles serves",
        "with both flags /.hidden/ names that link too",
        "a dangling link is not named without the flags",
        "nor with show_hidden and serve_dotfiles",
        "a link in sub/ to its .well-known is not named",
        "with serve_dotfiles /.hidden/a/ names up -> ../b.txt, beside it under .hidden",
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
    ok(hidden_dotted["/.hidden/target.txt"] and hidden_dotted["/.hidden/hid2"], rows[4])
    ok(hidden_open["/.hidden/plain"], rows[5])
    ok(root_plain["/page.txt"] and not root_plain["/gone"], rows[6])
    ok(root_open["/page.txt"] and not root_open["/gone"], rows[7])
    ok(sub_plain["/sub/f.txt"] and not sub_plain["/sub/wk"], rows[8])
    local hidden_a = hrefs(dotted, "/.hidden/a/")
    ok(hidden_a["/.hidden/a/own.txt"] and hidden_a["/.hidden/a/up"], rows[9])
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

-- Every route reads a file's type before it opens it, since opening a
-- FIFO blocks the loop until a writer comes, past SIGTERM; .liveignore was
-- opened as found, after the bind, so a FIFO by that name hung start with
-- its socket held (measured). One that is not a regular file is read as
-- absent and named once. The FIFO's start runs in a child Neovim killed at
-- a 5 s bound, so a start that blocks fails its row instead of hanging the
-- suite: SIGKILL ends a process blocked opening a FIFO, where SIGTERM
-- waits on the loop.
H.case("Section 10: a .liveignore that is not a regular file is not opened", function()
    local notes = {}
    local real_notify = vim.notify
    vim.notify = function(msg, level)
        table.insert(notes, { msg = msg, level = level })
    end
    H.defer(function()
        vim.notify = real_notify
    end)
    local function warnings(mark)
        vim.wait(100)
        local got = {}
        for i = mark + 1, #notes do
            if notes[i].level == vim.log.levels.WARN then
                table.insert(got, notes[i].msg)
            end
        end
        return got
    end
    local function start(site)
        local inst = server.start({
            port = 0,
            root = site,
            live = { enabled = false, inject_script = false },
            features = { dirlist = { enabled = false } },
        })
        H.defer(function()
            server.stop(inst)
        end)
        return inst
    end
    local function ignored(inst)
        return ("live-server: port %d ignores %s: not a regular file"):format(
            inst.port,
            vim.fs.joinpath(inst.root_real, ".liveignore")
        )
    end

    local dir_site = H.tmpdir()
    H.write_file(dir_site .. "/index.html", "<html><body>dir</body></html>")
    vim.fn.mkdir(dir_site .. "/.liveignore", "p")
    local mark = #notes
    local dir_inst = start(dir_site)
    eq(#dir_inst.ignore_patterns, 0, "a directory named .liveignore gives no rule")
    local warned = warnings(mark)
    ok(#warned == 1 and warned[1] == ignored(dir_inst), "and warns once, naming it: " .. vim.inspect(warned))
    eq(H.http_get(("http://127.0.0.1:%d/"):format(dir_inst.port)).status, 200, "and the server serves")

    local plain = H.tmpdir()
    H.write_file(plain .. "/.liveignore", "dist\n")
    mark = #notes
    local plain_inst = start(plain)
    ok(
        vim.deep_equal(plain_inst.ignore_patterns, { "dist" }),
        "a regular .liveignore is read as before: " .. vim.inspect(plain_inst.ignore_patterns)
    )
    eq(#warnings(mark), 0, "and warns nothing")
    mark = #notes
    server.update_target(plain_inst, dir_site, nil)
    eq(#plain_inst.ignore_patterns, 0, "update_target to a root whose .liveignore is a directory gives no rule")
    warned = warnings(mark)
    ok(#warned == 1 and warned[1] == ignored(plain_inst), "and warns once, naming it: " .. vim.inspect(warned))
    -- A start refused after the .liveignore was read warned about a port
    -- no server held.
    local real_new_timer = uv.new_timer
    H.defer(function()
        uv.new_timer = real_new_timer
    end)
    uv.new_timer = function()
        return nil, "EMFILE: stubbed", "EMFILE"
    end
    mark = #notes
    local refused, refusal = pcall(server.start, {
        port = 0,
        root = dir_site,
        live = { enabled = false, inject_script = false },
        features = { dirlist = { enabled = false } },
    })
    uv.new_timer = real_new_timer
    if refused then
        server.stop(refusal)
    end
    ok(
        not refused and tostring(refusal):find("Failed to make the reload timer", 1, true) ~= nil,
        "a start that cannot make its reload timer raises: " .. tostring(refusal)
    )
    warned = warnings(mark)
    eq(#warned, 0, "and delivers no warning about the .liveignore it read: " .. vim.inspect(warned))

    if is_win then
        H.skip("a FIFO named .liveignore starts and serves within 5 s (Windows has no FIFO)")
        H.skip("and warns once, naming it")
        H.skip("and gives no rule")
        H.skip("and a retarget to it from a root already warned about warns again")
        return
    end
    local fifo_site = H.tmpdir()
    H.write_file(fifo_site .. "/index.html", "<html><body>fifo</body></html>")
    local fifo = fifo_site .. "/.liveignore"
    local made = vim.system({ "mkfifo", fifo }):wait()
    if made.code ~= 0 then
        H.skip("a FIFO named .liveignore starts and serves within 5 s (mkfifo: " .. tostring(made.stderr) .. ")")
        H.skip("and warns once, naming it")
        H.skip("and gives no rule")
        H.skip("and a retarget to it from a root already warned about warns again")
        return
    end
    local script = H.tmpdir() .. "/child.lua"
    H.write_file(
        script,
        ([[
vim.opt.rtp:prepend(%q)
local server = require("live_server.server")
local notes = {}
vim.notify = function(msg, level)
    table.insert(notes, { msg = msg, level = level })
end
local inst = server.start({
    port = 0,
    root = %q,
    live = { enabled = false, inject_script = false },
    features = { dirlist = { enabled = false } },
})
local got
vim.system({ "curl", "-q", "-s", "-o", "/dev/null", "-w", "%%{http_code}", "--noproxy", "*", "--max-time", "2",
    ("http://127.0.0.1:%%d/"):format(inst.port) }, { text = true }, function(r)
    got = r.stdout
end)
vim.wait(2500, function()
    return got ~= nil
end)
vim.wait(100)
local first_notes = vim.deepcopy(notes)
local two = server.start({
    port = 0,
    root = %q,
    live = { enabled = false, inject_script = false },
    features = { dirlist = { enabled = false } },
})
vim.wait(100)
local before = #notes
server.update_target(two, %q, nil)
vim.wait(100)
local again = {}
for i = before + 1, #notes do
    if notes[i].level == vim.log.levels.WARN then
        table.insert(again, notes[i].msg)
    end
end
io.stdout:write(vim.json.encode({
    status = got,
    rules = #inst.ignore_patterns,
    port = inst.port,
    root_real = inst.root_real,
    notes = first_notes,
    two_port = two.port,
    two_root_real = two.root_real,
    two_rules = #two.ignore_patterns,
    again = again,
}))
server.stop(two)
server.stop(inst)
]]):format(H.root, fifo_site, dir_site, fifo_site)
    )
    local done
    local t0 = uv.hrtime()
    local proc = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-l", script }, { text = true }, function(r)
        done = r
    end)
    local in_time = H.wait_for(function()
        return done ~= nil
    end, 5000)
    local took = math.floor((uv.hrtime() - t0) / 1e6)
    if not in_time then
        proc:kill(9)
        H.wait_for(function()
            return done ~= nil
        end, 2000)
    end
    local child = done and done.code == 0 and select(2, pcall(vim.json.decode, done.stdout or "")) or nil
    ok(
        in_time and type(child) == "table" and child.status == "200",
        ("a FIFO named .liveignore starts and serves within 5 s (%d ms): %s"):format(
            took,
            vim.inspect(done, { newline = " ", indent = "" })
        )
    )
    local shown = type(child) == "table" and child or {}
    local want = shown.port
        and ("live-server: port %d ignores %s: not a regular file"):format(
            shown.port,
            vim.fs.joinpath(shown.root_real, ".liveignore")
        )
    local child_warned = {}
    for _, n in ipairs(shown.notes or {}) do
        if n.level == vim.log.levels.WARN then
            table.insert(child_warned, n.msg)
        end
    end
    ok(#child_warned == 1 and child_warned[1] == want, "and warns once, naming it: " .. vim.inspect(child_warned))
    eq(shown.rules, 0, "and gives no rule")
    -- The kind was spent per server, so a second root's went unsaid.
    local want_again = shown.two_port
        and ("live-server: port %d ignores %s: not a regular file"):format(
            shown.two_port,
            vim.fs.joinpath(shown.two_root_real, ".liveignore")
        )
    local again = shown.again or {}
    ok(
        #again == 1 and again[1] == want_again and shown.two_rules == 0,
        "and a retarget to it from a root already warned about warns again: " .. vim.inspect(again)
    )
end)

-- A .liveignore the stat reads and the open refuses was an empty rule
-- list with no word, and one over 64 KiB, a link to a large system file
-- among them, was read and parsed on the loop at every start and
-- retarget (measured: past 20 s). Each is read as absent and named once,
-- as is one whose stat fails other than ENOENT.
H.case("Section 10b: a .liveignore that cannot be read, or is too large, is named", function()
    local notes = {}
    local real_notify = vim.notify
    local real_stat = uv.fs_stat
    vim.notify = function(msg, level)
        table.insert(notes, { msg = msg, level = level })
    end
    H.defer(function()
        vim.notify = real_notify
        uv.fs_stat = real_stat
    end)
    local function warnings(mark)
        vim.wait(100)
        local got = {}
        for i = mark + 1, #notes do
            if notes[i].level == vim.log.levels.WARN then
                table.insert(got, notes[i].msg)
            end
        end
        return got
    end
    -- The start, then a stub undone, then a GET, so the stub sees the
    -- start's read alone.
    local function check(label, site, why, undo)
        local mark = #notes
        local inst = server.start({
            port = 0,
            root = site,
            live = { enabled = false, inject_script = false },
            features = { dirlist = { enabled = false } },
        })
        H.defer(function()
            server.stop(inst)
        end)
        if undo then
            undo()
        end
        eq(#inst.ignore_patterns, 0, label .. " gives no rule")
        local want = ("live-server: port %d ignores %s: %s"):format(
            inst.port,
            vim.fs.joinpath(inst.root_real, ".liveignore"),
            why
        )
        local warned = warnings(mark)
        ok(#warned == 1 and warned[1] == want, label .. " warns once, naming it and the cause: " .. vim.inspect(warned))
        eq(H.http_get(("http://127.0.0.1:%d/"):format(inst.port)).status, 200, label .. " serves")
    end
    local function site_with(content)
        local site = H.tmpdir()
        H.write_file(site .. "/index.html", "<html><body>ok</body></html>")
        if content then
            H.write_file(site .. "/.liveignore", content)
        end
        return site
    end
    local big = string.rep("dist\n", 14336)
    local over = ".liveignore is 71680 bytes, over the 65536-byte limit"
    check("a 70 KiB .liveignore", site_with(big), over)
    local target = H.tmpdir() .. "/big-ignore"
    H.write_file(target, big)
    local linked = site_with(nil)
    assert(uv.fs_symlink(target, linked .. "/.liveignore"))
    check("a link to a 70 KiB file named .liveignore", linked, over)

    local locked = site_with("dist\n")
    local locked_file = locked .. "/.liveignore"
    assert(uv.fs_chmod(locked_file, 0))
    H.defer(function()
        uv.fs_chmod(locked_file, 420)
    end)
    local probe, probe_err = uv.fs_open(locked_file, "r", 438)
    if probe then
        uv.fs_close(probe)
        H.skip("a mode-000 .liveignore gives no rule (this account reads it anyway)")
        H.skip("a mode-000 .liveignore warns once, naming it and the cause")
        H.skip("a mode-000 .liveignore serves")
    else
        -- The cause names the path luv opened, the root as start resolves it.
        local real_file = vim.fs.joinpath(assert(uv.fs_realpath(locked)), ".liveignore")
        check("a mode-000 .liveignore", locked, (tostring(probe_err):gsub(vim.pesc(locked_file), real_file)))
    end

    local failing = site_with("dist\n")
    local failing_file = vim.fs.joinpath(assert(uv.fs_realpath(failing)), ".liveignore")
    uv.fs_stat = function(path, ...)
        if path == failing_file then
            return nil, "EIO: stubbed", "EIO"
        end
        return real_stat(path, ...)
    end
    check("a .liveignore whose stat fails", failing, "EIO: stubbed", function()
        uv.fs_stat = real_stat
    end)
end)

-- Two changes inside one debounce window kept the last path alone, so
-- index.html then style.css sent one reload marked as a stylesheet: the
-- injected client swapped the stylesheets and the page stayed stale
-- (measured). The window keeps every path, and it is a swap only when
-- every one of them is a stylesheet.
H.case("Section 11: a mixed debounce window reloads the page", function()
    -- The reload frames after the stream opens, decoded, once the window
    -- has closed.
    local function window(writes)
        local site = H.tmpdir()
        H.write_file(site .. "/index.html", "<html><body>0</body></html>")
        H.write_file(site .. "/style.css", "body{}")
        H.write_file(site .. "/print.css", "body{}")
        local base = serve(site, { live = { enabled = true, debounce = 300, inject_script = false } })
        local port = tonumber(base:match(":(%d+)$"))
        local c = assert(H.raw_connect(port))
        assert(c:send(("GET /__live/events HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n\r\n"):format(port)))
        c:read(2000, function(b)
            return b:find("retry: 1000\n\n", 1, true) ~= nil
        end)
        -- FSEvents delivered a fixture written just before the watcher
        -- started after the stream opened (measured), so it settles first.
        vim.wait(600)
        local mark = #table.concat(c.chunks)
        for _, name in ipairs(writes) do
            H.write_file(site .. "/" .. name, "changed " .. name)
        end
        c:read(2000, function(b)
            return #reloads(b, mark) > 0
        end)
        -- A second frame from a late event would land in this wait.
        vim.wait(600)
        return reloads(table.concat(c.chunks), mark)
    end
    local function shown(got)
        return vim.inspect(got, { newline = " ", indent = "" })
    end
    local mixed = window({ "index.html", "style.css" })
    ok(
        #mixed == 1 and mixed[1].css == false and mixed[1].path == "index.html",
        "index.html then style.css in one window send one reload of the page, naming index.html: " .. shown(mixed)
    )
    local sheets = window({ "style.css", "print.css" })
    ok(
        #sheets == 1 and sheets[1].css == true and sheets[1].path == "print.css",
        "style.css then print.css send one stylesheet swap, naming the last: " .. shown(sheets)
    )
    local one = window({ "style.css" })
    ok(
        #one == 1 and one[1].css == true and one[1].path == "style.css",
        "style.css alone sends one stylesheet swap: " .. shown(one)
    )
    -- A file written faster than the debounce restarts the timer at each
    -- write, so a window that kept every change grew for as long as the
    -- writes came (67 entries after 60 writes, measured); it holds each
    -- path once.
    local site = H.tmpdir()
    H.write_file(site .. "/app.log", "0")
    local inst = server.start({
        port = 0,
        root = site,
        live = { enabled = true, debounce = 1500, inject_script = false },
        features = { dirlist = { enabled = false } },
    })
    H.defer(function()
        server.stop(inst)
    end)
    local c = assert(H.raw_connect(inst.port))
    assert(c:send(("GET /__live/events HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n\r\n"):format(inst.port)))
    c:read(2000, function(b)
        return b:find("retry: 1000\n\n", 1, true) ~= nil
    end)
    vim.wait(600)
    local mark = #table.concat(c.chunks)
    for i = 1, 20 do
        H.write_file(site .. "/app.log", tostring(i))
        vim.wait(30)
    end
    vim.wait(300)
    -- The root's own directory may be named too (Section 7b), once.
    local times = {}
    for p in pairs(inst.reload_window) do
        times[p] = (times[p] or 0) + 1
    end
    local repeated = false
    for _, n in pairs(times) do
        repeated = repeated or n > 1
    end
    ok(
        times["app.log"] == 1 and not repeated,
        "twenty writes to one file hold it once in the window: " .. shown(inst.reload_window)
    )
    c:read(3000, function(b)
        return #reloads(b, mark) > 0
    end)
    vim.wait(600)
    local logs = reloads(table.concat(c.chunks), mark)
    ok(#logs == 1 and logs[1].path == "app.log", "and send one reload naming it: " .. shown(logs))
    -- Two windows on one server: a send that left its window behind would
    -- read the second, a lone stylesheet, as a page change.
    local two = H.tmpdir()
    H.write_file(two .. "/index.html", "<html><body>0</body></html>")
    H.write_file(two .. "/style.css", "body{}")
    local twice = serve(two, { live = { enabled = true, debounce = 300, inject_script = false } })
    local tport = tonumber(twice:match(":(%d+)$"))
    local tc = assert(H.raw_connect(tport))
    assert(tc:send(("GET /__live/events HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n\r\n"):format(tport)))
    tc:read(2000, function(b)
        return b:find("retry: 1000\n\n", 1, true) ~= nil
    end)
    vim.wait(600)
    local tmark = #table.concat(tc.chunks)
    H.write_file(two .. "/index.html", "<html><body>1</body></html>")
    tc:read(3000, function(b)
        return #reloads(b, tmark) > 0
    end)
    vim.wait(600)
    local second = #table.concat(tc.chunks)
    H.write_file(two .. "/style.css", "body{color:red}")
    tc:read(3000, function(b)
        return #reloads(b, second) > 0
    end)
    vim.wait(600)
    local frames = reloads(table.concat(tc.chunks), tmark)
    ok(
        #frames == 2 and frames[1].path == "index.html" and frames[2].css == true and frames[2].path == "style.css",
        "a page's window, then a lone stylesheet's, send a reload, then a swap: " .. shown(frames)
    )
    -- A repeated path is its latest change: A, B, then A again names A.
    local again = H.tmpdir()
    H.write_file(again .. "/a.html", "<html><body>a</body></html>")
    H.write_file(again .. "/b.html", "<html><body>b</body></html>")
    local abase = serve(again, { live = { enabled = true, debounce = 1500, inject_script = false } })
    local aport = tonumber(abase:match(":(%d+)$"))
    local ac = assert(H.raw_connect(aport))
    assert(ac:send(("GET /__live/events HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n\r\n"):format(aport)))
    ac:read(2000, function(b)
        return b:find("retry: 1000\n\n", 1, true) ~= nil
    end)
    vim.wait(600)
    local amark = #table.concat(ac.chunks)
    for _, name in ipairs({ "a.html", "b.html", "a.html" }) do
        H.write_file(again .. "/" .. name, "changed " .. name)
        vim.wait(200)
    end
    ac:read(4000, function(b)
        return #reloads(b, amark) > 0
    end)
    vim.wait(600)
    local named = reloads(table.concat(ac.chunks), amark)
    ok(
        #named == 1 and named[1].path == "a.html",
        "a.html, b.html, then a.html again in one window send one reload naming a.html: " .. shown(named)
    )
end)

-- Neovim's :w with default options writes a probe file (4913) and a
-- backup (style.css~) beside the file and deletes both, so a stylesheet
-- save filled the window with other names and the page reloaded, naming
-- a file already gone (measured); a save through a temporary name and a
-- rename did the same. A path gone by the send is dropped, unless every
-- one is: a deleted page, or stylesheet, reloads the page. The window is
-- a map, sorted at the send, so a burst is linear.
H.case("Section 11b: a save's vanished temp files never decide the reload", function()
    local function shown(got)
        return vim.inspect(got, { newline = " ", indent = "" })
    end
    -- The reload frames act causes on a fresh live server over site.
    local function frames_after(site, debounce, act)
        local base = serve(site, { live = { enabled = true, debounce = debounce, inject_script = false } })
        local port = tonumber(base:match(":(%d+)$"))
        local c = assert(H.raw_connect(port))
        H.defer(function()
            c:close()
        end)
        assert(c:send(("GET /__live/events HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n\r\n"):format(port)))
        c:read(2000, function(b)
            return b:find("retry: 1000\n\n", 1, true) ~= nil
        end)
        -- FSEvents delivered a fixture written just before the watcher
        -- started after the stream opened (measured), so it settles first.
        vim.wait(600)
        local mark = #table.concat(c.chunks)
        act()
        local t0 = uv.hrtime()
        c:read(debounce + 3000, function(b)
            return #reloads(b, mark) > 0
        end)
        local took = math.floor((uv.hrtime() - t0) / 1e6)
        -- A second frame from a late event would land in this wait.
        vim.wait(600)
        return reloads(table.concat(c.chunks), mark), took
    end
    local function sheet_site()
        local site = H.tmpdir()
        H.write_file(site .. "/index.html", "<html><body>0</body></html>")
        H.write_file(site .. "/style.css", "body{}")
        return site
    end

    -- The fixture sits under $TMPDIR, which backupskip names by default,
    -- so the child clears it: every other option is Neovim's default, as
    -- in a project directory.
    local saved = sheet_site()
    local save_result
    local by_nvim = frames_after(saved, 300, function()
        save_result = vim.system({
            vim.v.progpath,
            "--headless",
            "-u",
            "NONE",
            "-c",
            "set backupskip=",
            "-c",
            "edit " .. vim.fn.fnameescape(saved .. "/style.css"),
            "-c",
            "normal! Goa{}",
            "-c",
            "write",
            "-c",
            "qall!",
        }):wait(5000)
    end)
    eq(save_result and H.exit_code(save_result), 0, "a child Neovim saves style.css")
    ok(
        #by_nvim == 1 and by_nvim[1].css == true and by_nvim[1].path == "style.css",
        "a stylesheet saved by Neovim's :w sends one swap naming it: " .. shown(by_nvim)
    )

    local renamed = sheet_site()
    local by_rename = frames_after(renamed, 300, function()
        H.write_file(renamed .. "/style.css.tmp", "body{color:red}")
        assert(uv.fs_rename(renamed .. "/style.css.tmp", renamed .. "/style.css"))
    end)
    ok(
        #by_rename == 1 and by_rename[1].css == true and by_rename[1].path == "style.css",
        "a stylesheet saved through a temporary name sends one swap naming it: " .. shown(by_rename)
    )

    local gone_page = sheet_site()
    H.write_file(gone_page .. "/page.html", "<html><body>page</body></html>")
    local page_frames = frames_after(gone_page, 300, function()
        assert(uv.fs_unlink(gone_page .. "/page.html"))
    end)
    ok(
        #page_frames == 1 and page_frames[1].css == false and page_frames[1].path == "page.html",
        "a deleted page alone reloads the page, naming it: " .. shown(page_frames)
    )
    local gone_sheet = sheet_site()
    local sheet_frames = frames_after(gone_sheet, 300, function()
        assert(uv.fs_unlink(gone_sheet .. "/style.css"))
    end)
    ok(
        #sheet_frames == 1 and sheet_frames[1].css == false and sheet_frames[1].path == "style.css",
        "a deleted stylesheet alone reloads the page, naming it: " .. shown(sheet_frames)
    )

    -- 200 pages written twice, in order: the last written is named, and
    -- the window is sent within 2 s of the last write.
    local burst = H.tmpdir()
    for i = 1, 200 do
        H.write_file(("%s/f%03d.html"):format(burst, i), "0")
    end
    local burst_frames, took = frames_after(burst, 500, function()
        for write = 1, 2 do
            for i = 1, 200 do
                H.write_file(("%s/f%03d.html"):format(burst, i), tostring(write))
            end
        end
    end)
    ok(
        #burst_frames == 1 and burst_frames[1].path == "f200.html" and took < 2000,
        ("a burst of 200 pages written twice sends one reload naming the last, within 2 s (%d ms): %s"):format(
            took,
            shown(burst_frames)
        )
    )
end)

H.finish()
