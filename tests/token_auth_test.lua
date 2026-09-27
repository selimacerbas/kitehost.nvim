-- tests/token_auth_test.lua
-- Verify that cfg.token gates /__live/events, /__live/inject, and any path
-- listed in cfg.protected_paths, while leaving static assets (index.html)
-- reachable without auth. The gate reads the request path, then the name
-- on disk of the file, index or directory about to be served (a case
-- variant, a link); a NUL or a backslash in the path is 400 before it; a
-- link out of the root is 404; and start refuses a bad token,
-- protected_paths (patterns with no token among them), serve_dotfiles or
-- index_names before any socket opens.
--
-- Run: nvim --headless -u NONE -l "$PWD/tests/token_auth_test.lua"

local H = dofile(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "helpers.lua"))
H.isolate()
H.rtp()

local server = require("live_server.server")
local util = require("live_server.util")
local ok, eq, http_get = H.ok, H.eq, H.http_get

-- Workspace with two files
local tmpdir = H.tmpdir()
local f1 = vim.fs.joinpath(tmpdir, "index.html")
local f2 = vim.fs.joinpath(tmpdir, "content.md")
H.write_file(f1, "<html><body>hi</body></html>")
H.write_file(f2, "# secret content")
local uv = vim.uv
H.write_file(vim.fs.joinpath(tmpdir, "asset_root"), "/some/dir")

-- ─── Section 1: random_token / secure_compare ───────────────────────────────
H.section("Section 1: helpers")
local t1 = util.random_token(16)
local t2 = util.random_token(16)
eq(#t1, 32, "random_token(16) returns 32 hex chars")
ok(t1 ~= t2, "two calls return different tokens")
ok(t1:match("^[0-9a-f]+$") ~= nil, "token is pure hex")
ok(util.secure_compare("abc", "abc"), "secure_compare equal strings")
ok(not util.secure_compare("abc", "abd"), "secure_compare unequal strings")
ok(not util.secure_compare("abc", "abcd"), "secure_compare different lengths")
ok(not util.secure_compare(nil, "abc"), "secure_compare nil arg")
-- The token comes from the OS CSPRNG: vim.uv.random, then /dev/urandom,
-- else a raise; the math.random fallback held about 31 bits and reseeded
-- the global generator.
local calls, seeds = 0, 0
local real_random, real_seed, real_open = uv.random, math.randomseed, uv.fs_open
math.randomseed = function(...)
    seeds = seeds + 1
    return real_seed(...)
end
uv.random = function(...)
    calls = calls + 1
    return real_random(...)
end
local tok = util.random_token(16)
eq(calls, 1, "random_token reads vim.uv.random")
ok(#tok == 32 and tok:match("^[0-9a-f]+$") ~= nil, "and returns 32 hex characters")
uv.random = function()
    return nil, "EIO: stubbed", "EIO"
end
uv.fs_open = function(path, ...)
    if path == "/dev/urandom" then
        return nil, "ENOENT: stubbed", "ENOENT"
    end
    return real_open(path, ...)
end
local made, made_err = pcall(util.random_token, 16)
ok(
    not made and tostring(made_err):find("no secure random source", 1, true) ~= nil,
    "with no source it raises: " .. tostring(made_err)
)
uv.random, uv.fs_open = real_random, real_open
-- A bad length raises before any source is read. Infinity equals its own
-- floor, and the /dev/urandom read it reached raised before the descriptor
-- closed, one descriptor lost per call; a length of 2^31 held the editor
-- for seconds reading 2 GB (measured).
local function raises_length_error(len, label)
    local good, err = pcall(util.random_token, len)
    ok(not good and tostring(err):find("byte_len must be", 1, true) ~= nil, label .. ": " .. tostring(err))
end
for _, bad in ipairs({ { -1, "a negative length" }, { math.huge, "an infinite length" } }) do
    local fds = H.fd_count()
    raises_length_error(bad[1], bad[2] .. " raises the length error")
    if fds then
        eq(H.fd_count(), fds, bad[2] .. " leaves no descriptor open")
    else
        H.skip(bad[2] .. " leaves no descriptor open (no descriptor listing on this platform)")
    end
end
raises_length_error(2 ^ 31, "a length of 2^31 raises the length error")
raises_length_error(1.5, "a fractional length raises the length error")
raises_length_error("16", "a string length raises the length error")
raises_length_error(false, "false is no length and raises the length error")
local long = util.random_token(1024)
ok(#long == 2048 and long:match("^[0-9a-f]+$") ~= nil, "a length of 1024 returns 2048 hex characters")
math.randomseed = real_seed
eq(seeds, 0, "the global math.randomseed is never called")

-- With neither source the raise carries both errors, so the host says why.
H.case("Section 1b: with no source the raise names both causes", function()
    H.defer(function()
        uv.random, uv.fs_open = real_random, real_open
    end)
    uv.random = function()
        return nil, "EIO: random stubbed", "EIO"
    end
    uv.fs_open = function(path, ...)
        if path == "/dev/urandom" then
            return nil, "EACCES: urandom stubbed", "EACCES"
        end
        return real_open(path, ...)
    end
    local good, err = pcall(util.random_token, 16)
    err = tostring(err)
    ok(
        not good
            and err:find("EIO: random stubbed", 1, true) ~= nil
            and err:find("EACCES: urandom stubbed", 1, true) ~= nil,
        "the message names vim.uv.random's and /dev/urandom's errors: " .. err
    )
end)

-- ─── Section 2: server with token ───────────────────────────────────────────
H.section("Section 2: server enforces token")
local TOKEN = util.random_token(16)
local inst = server.start({
    port = 0, -- OS-assigned
    root = tmpdir,
    default_index = f1,
    token = TOKEN,
    protected_paths = { "^/content%.md$", "^/asset_root$" },
    live = { inject_script = false },
    features = { dirlist = { enabled = false } },
})
local port = inst.port

-- Static asset (index.html) is reachable without token
local r = http_get(("http://127.0.0.1:%d/"):format(port))
eq(r.status, 200, "/ (index.html) reachable without token")

-- /content.md requires token
r = http_get(("http://127.0.0.1:%d/content.md"):format(port))
eq(r.status, 401, "/content.md without token is 401")
-- The status line read "401 OK"; a raw read shows the reason.
local raw401 =
    H.response(assert(H.raw_request(port, ("GET /content.md HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n\r\n"):format(port))))
eq(raw401.reason, "Unauthorized", "a 401 names its reason phrase")

r = http_get(("http://127.0.0.1:%d/content.md?t=wrong"):format(port))
eq(r.status, 401, "/content.md with wrong token is 401")

r = http_get(("http://127.0.0.1:%d/content.md?t=%s"):format(port, TOKEN))
eq(r.status, 200, "/content.md with correct token is 200")
ok(r.body:find("secret content") ~= nil, "/content.md body contains expected text")

-- /__live/inject requires token
r = http_get(("http://127.0.0.1:%d/__live/inject?event=reload"):format(port))
eq(r.status, 401, "/__live/inject without token is 401")

r = http_get(("http://127.0.0.1:%d/__live/inject?event=reload&t=%s"):format(port, TOKEN))
eq(r.status, 200, "/__live/inject with correct token is 200")

-- /__live/events also requires token (we don't actually read SSE; just confirm
-- the status code from the initial response line)
r = http_get(("http://127.0.0.1:%d/__live/events"):format(port))
eq(r.status, 401, "/__live/events without token is 401")

-- Path-normalization bypass: encoded or slash-padded variants of a protected
-- path must NOT evade the token (they resolve to the same file).
r = http_get(("http://127.0.0.1:%d//content.md"):format(port))
eq(r.status, 401, "//content.md (extra slash) without token is 401")

r = http_get(("http://127.0.0.1:%d/content%%2emd"):format(port))
eq(r.status, 401, "/content%2emd (encoded dot) without token is 401")

r = http_get(("http://127.0.0.1:%d/./content.md"):format(port))
eq(r.status, 401, "/./content.md (dot segment) without token is 401")

r = http_get(("http://127.0.0.1:%d/sub/../content.md?t=wrong"):format(port))
eq(r.status, 401, "/sub/../content.md (traversal) with wrong token is 401")

-- And the normalized/encoded form still serves with the correct token.
r = http_get(("http://127.0.0.1:%d//content.md?t=%s"):format(port, TOKEN))
eq(r.status, 200, "//content.md with correct token still serves")
-- libuv cuts a path at its first NUL, so the gate matched the whole
-- string while the mapper opened the file before the NUL.
r = http_get(("http://127.0.0.1:%d/content.md%%00"):format(port))
eq(r.status, 400, "/content.md%00 is 400")
r = http_get(("http://127.0.0.1:%d/asset_root%%00"):format(port))
eq(r.status, 400, "/asset_root%00 is 400")
r = http_get(("http://127.0.0.1:%d/..%%00"):format(port))
eq(r.status, 400, "/..%00 is 400, not left to the containment check")
r = http_get(("http://127.0.0.1:%d/content%%5Cmd"):format(port))
eq(r.status, 400, "a backslash (%5C) in the path is 400")
-- One segment to the gate's patterns, a parent step to a Win32 path read.
r = http_get(("http://127.0.0.1:%d/x%%5C..%%5Ccontent.md"):format(port))
eq(r.status, 400, "a backslash traversal is 400 before the gate, not a file")
local nul = H.response(
    assert(H.raw_request(port, ("GET /content.md\0.txt HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n\r\n"):format(port)))
)
eq(nul.status, 400, "a raw NUL byte in the request line is 400")
local gated_root = server.start({
    port = 0,
    root = tmpdir,
    default_index = f1,
    token = TOKEN,
    protected_paths = { "^/$" },
    live = { inject_script = false },
    features = { dirlist = { enabled = false } },
})
eq(http_get(("http://127.0.0.1:%d/%%00"):format(gated_root.port)).status, 400, "/%00 on a server that gates / is 400")
eq(http_get(("http://127.0.0.1:%d/"):format(gated_root.port)).status, 401, "and / itself is 401 there")
server.stop(gated_root)
-- realpath returns the name the disk holds: on a case-folding volume
-- (APFS, NTFS) /CONTENT.MD reached content.md past the gate.
for _, variant in ipairs({ "/CONTENT.MD", "/Content.md" }) do
    r = http_get(("http://127.0.0.1:%d%s"):format(port, variant))
    if H.fs_folds_case then
        eq(r.status, 401, variant .. " without the token is 401")
    else
        eq(r.status, 404, variant .. " names no file on a case-sensitive volume (the 401 row is vacuous here)")
    end
end
if H.fs_folds_case then
    eq(
        http_get(("http://127.0.0.1:%d/CONTENT.MD?t=%s"):format(port, TOKEN)).status,
        200,
        "/CONTENT.MD with the token serves"
    )
else
    H.skip("/CONTENT.MD with the token serves (a case-sensitive volume has no such file)")
end
local alias = vim.fs.joinpath(tmpdir, "alias.md")
local linked, link_err = uv.fs_symlink("content.md", alias)
if linked and uv.fs_stat(alias) then
    eq(
        http_get(("http://127.0.0.1:%d/alias.md"):format(port)).status,
        401,
        "a link to content.md without the token is 401"
    )
else
    H.skip(
        "a link to content.md without the token is 401 (" .. tostring(link_err or "the link does not resolve") .. ")"
    )
end
-- A root that ends in a separator ("/", a drive root) lost the name's
-- leading slash, so a pattern anchored at ^/ never matched the file served.
local disk = assert(uv.fs_realpath(f2))
local drive = disk:match("^%a:[/\\]") or "/"
local slashed = "/" .. disk:sub(#drive + 1):gsub("\\", "/")
local at_root = server.start({
    port = 0,
    root = drive,
    token = TOKEN,
    protected_paths = { "^" .. vim.pesc(slashed) .. "$" },
    live = { enabled = false, inject_script = false },
    features = { dirlist = { enabled = false } },
})
if linked and uv.fs_stat(alias) then
    local via = (slashed:gsub("content%.md$", "alias.md"))
    eq(
        http_get(("http://127.0.0.1:%d%s"):format(at_root.port, via)).status,
        401,
        "a link to content.md under root / is 401"
    )
else
    H.skip("a link to content.md under root / is 401 (" .. tostring(link_err or "the link does not resolve") .. ")")
end
server.stop(at_root)
-- The listing names a directory's files: a link to a protected directory
-- listed what the directory's own spelling refused.
vim.fn.mkdir(vim.fs.joinpath(tmpdir, "secret"), "p")
H.write_file(vim.fs.joinpath(tmpdir, "secret", "notes.md"), "notes")
vim.fn.mkdir(vim.fs.joinpath(tmpdir, "docs"), "p")
H.write_file(vim.fs.joinpath(tmpdir, "docs", "index.html"), "<html>docs</html>")
local listed = server.start({
    port = 0,
    root = tmpdir,
    token = TOKEN,
    protected_paths = { "^/secret", "^/docs/index%.html$" },
    live = { inject_script = false },
    features = { dirlist = { enabled = true } },
})
local dlinked, dlink_err = uv.fs_symlink("secret", vim.fs.joinpath(tmpdir, "pub"))
if dlinked and uv.fs_stat(vim.fs.joinpath(tmpdir, "pub")) then
    eq(
        http_get(("http://127.0.0.1:%d/pub/"):format(listed.port)).status,
        401,
        "a link to a protected directory lists nothing"
    )
else
    H.skip(
        "a link to a protected directory lists nothing (" .. tostring(dlink_err or "the link does not resolve") .. ")"
    )
end
if H.fs_folds_case then
    eq(
        http_get(("http://127.0.0.1:%d/SECRET/"):format(listed.port)).status,
        401,
        "/SECRET/ without the token lists nothing"
    )
else
    H.skip("/SECRET/ without the token lists nothing (a case-sensitive volume has no such directory)")
end
-- With the listing off, a directory the gate refuses answered "(no index)"
-- before the gate read it, so a case variant told a protected directory
-- apart from a missing one.
local unlisted = server.start({
    port = 0,
    root = tmpdir,
    token = TOKEN,
    protected_paths = { "^/secret", "^/docs/index%.html$" },
    live = { enabled = false, inject_script = false },
    features = { dirlist = { enabled = false } },
})
if H.fs_folds_case then
    local res = http_get(("http://127.0.0.1:%d/SECRET/"):format(unlisted.port))
    eq(res.status, 401, "/SECRET/ without the token is 401 with the listing off")
    ok(not res.body:find("(no index)", 1, true), "and its body never says (no index)")
else
    H.skip("/SECRET/ without the token is 401 with the listing off (a case-sensitive volume has no such directory)")
    H.skip("and its body never says (no index) (a case-sensitive volume has no such directory)")
end
server.stop(unlisted)
-- The first check reads /docs; only the index about to be served matches.
eq(http_get(("http://127.0.0.1:%d/docs/"):format(listed.port)).status, 401, "/docs/ serving a protected index is 401")
-- A directory whose index.html links out of the root has no index of its
-- own: the file route refuses the link by name, so /sub/ shows what the
-- directory itself holds, never the bytes of the file behind it, and the
-- listing leaves out the link, which containment refuses whatever the
-- flags.
local outside = vim.fs.joinpath(H.tmpdir(), "leak.html")
H.write_file(outside, "outside the root")
vim.fn.mkdir(vim.fs.joinpath(tmpdir, "sub"), "p")
local sub_index = vim.fs.joinpath(tmpdir, "sub", "index.html")
local olinked, olink_err = uv.fs_symlink(outside, sub_index)
local function lists_sub(res)
    return res.status == 200
        and res.body:find("Index of /sub/", 1, true) ~= nil
        and not res.body:find(">index.html</a>", 1, true)
        and not res.body:find("outside the root", 1, true)
end
if olinked and uv.fs_stat(sub_index) then
    local res = http_get(("http://127.0.0.1:%d/sub/"):format(listed.port))
    ok(lists_sub(res), ("an index linked out of the root leaves /sub/ its listing (got %d)"):format(res.status))
    res = http_get(("http://127.0.0.1:%d/sub/?t=%s"):format(listed.port, TOKEN))
    ok(lists_sub(res), ("and the same listing with the token (got %d)"):format(res.status))
    local shows_all = server.start({
        port = 0,
        root = tmpdir,
        token = TOKEN,
        serve_dotfiles = true,
        live = { enabled = false, inject_script = false },
        features = { dirlist = { enabled = true, show_hidden = true } },
    })
    res = http_get(("http://127.0.0.1:%d/sub/"):format(shows_all.port))
    ok(lists_sub(res), ("and the same listing with show_hidden and serve_dotfiles (got %d)"):format(res.status))
    server.stop(shows_all)
else
    local why = " (" .. tostring(olink_err or "the link does not resolve") .. ")"
    H.skip("an index linked out of the root leaves /sub/ its listing" .. why)
    H.skip("and the same listing with the token" .. why)
    H.skip("and the same listing with show_hidden and serve_dotfiles" .. why)
end
server.stop(listed)
-- A listing is read by the directory's name with its slash, as the request
-- that lists it spells it: ^/secret/ gated every file under secret/ and
-- never its listing. The name without the slash is read too, as the
-- request path's check reads /secret for /secret/.
local function dir_gated(pattern)
    return server.start({
        port = 0,
        root = tmpdir,
        token = TOKEN,
        protected_paths = { pattern },
        live = { enabled = false, inject_script = false },
        features = { dirlist = { enabled = true } },
    })
end
local slashed_dir = dir_gated("^/secret/")
eq(
    http_get(("http://127.0.0.1:%d/secret/"):format(slashed_dir.port)).status,
    401,
    "/secret/ under ^/secret/ is 401 without the token"
)
eq(http_get(("http://127.0.0.1:%d/secret/?t=%s"):format(slashed_dir.port, TOKEN)).status, 200, "and 200 with it")
server.stop(slashed_dir)
local bare_dir = dir_gated("^/secret$")
if dlinked and uv.fs_stat(vim.fs.joinpath(tmpdir, "pub")) then
    eq(
        http_get(("http://127.0.0.1:%d/pub/"):format(bare_dir.port)).status,
        401,
        "a link to secret/ under ^/secret$ is 401 without the token"
    )
else
    H.skip(
        "a link to secret/ under ^/secret$ is 401 without the token ("
            .. tostring(dlink_err or "the link does not resolve")
            .. ")"
    )
end
server.stop(bare_dir)
-- default_index may sit outside the root and is served for / alone: a link
-- in the root back to the root reached it under a name the first check read
-- as another path, past a ^/$ pattern.
local outside_index = vim.fs.joinpath(H.tmpdir(), "outside.html")
H.write_file(outside_index, "<html>outside the root</html>")
local ws = H.tmpdir()
local loop = vim.fs.joinpath(ws, "loop")
local llinked, llink_err = uv.fs_symlink(ws, loop)
local looped = llinked and uv.fs_stat(loop) ~= nil
local loop_skip = " (" .. tostring(llink_err or "the link does not resolve") .. ")"
local function ws_server(protected)
    return server.start({
        port = 0,
        root = ws,
        default_index = outside_index,
        token = TOKEN,
        protected_paths = protected,
        live = { enabled = false, inject_script = false },
        features = { dirlist = { enabled = false } },
    })
end
local open_ws = ws_server({})
r = http_get(("http://127.0.0.1:%d/"):format(open_ws.port))
eq(r.status, 200, "/ serves a default_index outside the root")
ok(r.body:find("outside the root", 1, true) ~= nil, "/ answers with that default_index's body")
if looped then
    eq(
        http_get(("http://127.0.0.1:%d/loop/"):format(open_ws.port)).status,
        404,
        "a link to the root does not serve an outside default_index"
    )
else
    H.skip("a link to the root does not serve an outside default_index" .. loop_skip)
end
server.stop(open_ws)
local gated_ws = ws_server({ "^/$" })
-- The link names the root on disk, which ^/$ refuses as it refuses /; with
-- the token it is a directory with no index, never the outside file.
if looped then
    eq(
        http_get(("http://127.0.0.1:%d/loop/"):format(gated_ws.port)).status,
        401,
        "a link to the root is 401 past ^/$ without the token, as / is"
    )
    r = http_get(("http://127.0.0.1:%d/loop/?t=%s"):format(gated_ws.port, TOKEN))
    ok(
        r.status == 404 and not r.body:find("outside the root", 1, true),
        ("and with the token it serves no outside default_index (got %d)"):format(r.status)
    )
else
    H.skip("a link to the root is 401 past ^/$ without the token, as / is" .. loop_skip)
    H.skip("and with the token it serves no outside default_index" .. loop_skip)
end
eq(http_get(("http://127.0.0.1:%d/"):format(gated_ws.port)).status, 401, "/ under ^/$ is 401 without the token")
eq(
    http_get(("http://127.0.0.1:%d/?t=%s"):format(gated_ws.port, TOKEN)).status,
    200,
    "/ under ^/$ is 200 with the token"
)
server.stop(gated_ws)
-- The root's own index is exempt from containment and the dot rule, never
-- from the gate by name: a default_index spelled through a link to the
-- root (macOS's /var names /private/var) is read as realpath names it.
local via_root = vim.fs.joinpath(H.tmpdir(), "L")
local vlinked, vlink_err = uv.fs_symlink(tmpdir, via_root)
local spelled
if vlinked and uv.fs_stat(via_root) then
    spelled = vim.fs.joinpath(via_root, "index.html")
elseif uv.fs_realpath(f1) ~= f1 then
    spelled = f1
end
if spelled then
    local own = server.start({
        port = 0,
        root = tmpdir,
        default_index = spelled,
        token = TOKEN,
        protected_paths = { "^/index%.html$" },
        live = { enabled = false, inject_script = false },
        features = { dirlist = { enabled = false } },
    })
    eq(
        http_get(("http://127.0.0.1:%d/"):format(own.port)).status,
        401,
        "a default_index spelled through a link to the root is 401 without the token"
    )
    eq(http_get(("http://127.0.0.1:%d/?t=%s"):format(own.port, TOKEN)).status, 200, "and 200 with it")
    server.stop(own)
else
    local why = " (" .. tostring(vlink_err or "no link resolves and the root is spelled as realpath names it") .. ")"
    H.skip("a default_index spelled through a link to the root is 401 without the token" .. why)
    H.skip("and 200 with it" .. why)
end
-- A directory named as default_index is no index: its page named the path
-- on disk where / is a plain 404, or the root's listing when that is on.
local dir_ws = H.tmpdir()
vim.fn.mkdir(vim.fs.joinpath(dir_ws, "page.html"), "p")
local function dir_index_server(listing)
    return server.start({
        port = 0,
        root = dir_ws,
        default_index = vim.fs.joinpath(dir_ws, "page.html"),
        live = { enabled = false, inject_script = false },
        features = { dirlist = { enabled = listing } },
    })
end
local dir_off = dir_index_server(false)
r = http_get(("http://127.0.0.1:%d/"):format(dir_off.port))
eq(r.status, 404, "a directory named as default_index is 404 at / with the listing off")
ok(
    not r.body:find(dir_ws, 1, true) and not r.body:find(assert(uv.fs_realpath(dir_ws)), 1, true),
    "and that 404 names no path on disk"
)
server.stop(dir_off)
local dir_on = dir_index_server(true)
r = http_get(("http://127.0.0.1:%d/"):format(dir_on.port))
ok(
    r.status == 200 and r.body:find('href="/page.html/"', 1, true) ~= nil,
    ("and / lists the root with the listing on (got %d)"):format(r.status)
)
server.stop(dir_on)
-- The index chain reads default_index, then index_names, then the listing;
-- a default_index that is no file skipped index_names at / and listed the
-- root, or answered 404, beside an index.html.
local fall_ws = H.tmpdir()
vim.fn.mkdir(vim.fs.joinpath(fall_ws, "page.html"), "p")
H.write_file(vim.fs.joinpath(fall_ws, "index.html"), "<html>FALLBACK</html>")
local fall = server.start({
    port = 0,
    root = fall_ws,
    default_index = vim.fs.joinpath(fall_ws, "page.html"),
    live = { enabled = false, inject_script = false },
    features = { dirlist = { enabled = false } },
})
r = http_get(("http://127.0.0.1:%d/"):format(fall.port))
ok(
    r.status == 200 and r.body:find("FALLBACK", 1, true) ~= nil,
    ("a default_index that is a directory falls through to index.html (got %d)"):format(r.status)
)
server.stop(fall)
-- The root's own index, with no default_index set, linked out of the root:
-- the candidate's resolution and the gate each refuse it, 404 at / too.
local root_index = vim.fs.joinpath(ws, "index.html")
local rlinked, rlink_err = uv.fs_symlink(outside_index, root_index)
local root_linked = rlinked and uv.fs_stat(root_index) ~= nil
local bare_ws = server.start({
    port = 0,
    root = ws,
    token = TOKEN,
    protected_paths = {},
    live = { enabled = false, inject_script = false },
    features = { dirlist = { enabled = false } },
})
if root_linked then
    eq(
        http_get(("http://127.0.0.1:%d/"):format(bare_ws.port)).status,
        404,
        "the root's index linked out of the root is 404"
    )
    eq(http_get(("http://127.0.0.1:%d/?t=%s"):format(bare_ws.port, TOKEN)).status, 404, "and 404 with the token")
else
    local why = " (" .. tostring(rlink_err or "the link does not resolve") .. ")"
    H.skip("the root's index linked out of the root is 404" .. why)
    H.skip("and 404 with the token" .. why)
end
server.stop(bare_ws)

server.stop(inst)
-- Refused is curl 7: a listener left open after stop answers (curl 0) and
-- one left bound and silent reads 28, both with status 0.
r = http_get(("http://127.0.0.1:%d/"):format(port))
eq(r.curl_exit, 7, "the port refuses connections after stop")

-- ─── Section 3: backward compat (no token in cfg) ───────────────────────────
H.section("Section 3: no token = no auth (backward compat)")
inst = server.start({
    port = 0,
    root = tmpdir,
    default_index = f1,
    live = { inject_script = false },
    features = { dirlist = { enabled = false } },
})
port = inst.port

r = http_get(("http://127.0.0.1:%d/content.md"):format(port))
eq(r.status, 200, "/content.md reachable when token not configured")

r = http_get(("http://127.0.0.1:%d/__live/inject?event=reload"):format(port))
eq(r.status, 200, "/__live/inject reachable when token not configured")

server.stop(inst)
r = http_get(("http://127.0.0.1:%d/"):format(port))
eq(r.curl_exit, 7, "the port refuses connections after stop without a token")

-- The index a directory serves was read by its own name alone, so under
-- ^/secret$ a case variant (/SECRET/) or a link (pub -> secret) served
-- secret's index where its listing is 401. A request that ends in a slash
-- is read with it, so ^/nosuch/ is 401 whether or not the directory
-- exists, where a 404 said it did not.
H.case("a directory the gate refuses serves no index", function()
    local site = H.tmpdir()
    vim.fn.mkdir(vim.fs.joinpath(site, "secret"), "p")
    H.write_file(vim.fs.joinpath(site, "secret", "index.html"), "<html>SECRET-INDEX</html>")
    local function gated(patterns)
        local s = server.start({
            port = 0,
            root = site,
            token = TOKEN,
            protected_paths = patterns,
            live = { enabled = false, inject_script = false },
            features = { dirlist = { enabled = false } },
        })
        H.defer(function()
            server.stop(s)
        end)
        return ("http://127.0.0.1:%d"):format(s.port)
    end
    local base = gated({ "^/secret$" })
    eq(http_get(base .. "/secret/").status, 401, "/secret/ under ^/secret$ is 401 without the token")
    local res = http_get(base .. "/secret/?t=" .. TOKEN)
    ok(
        res.status == 200 and res.body:find("SECRET-INDEX", 1, true) ~= nil,
        ("and serves its index with it (got %d)"):format(res.status)
    )
    if H.fs_folds_case then
        eq(http_get(base .. "/SECRET/").status, 401, "/SECRET/ without the token is 401, never secret's index")
    else
        H.skip(
            "/SECRET/ without the token is 401, never secret's index (a case-sensitive volume has no such directory)"
        )
    end
    local pub = vim.fs.joinpath(site, "pub")
    local linked, link_err = uv.fs_symlink("secret", pub)
    if linked and uv.fs_stat(pub) then
        eq(http_get(base .. "/pub/").status, 401, "a link pub -> secret without the token is 401, never its index")
    else
        H.skip(
            "a link pub -> secret without the token is 401, never its index ("
                .. tostring(link_err or "the link does not resolve")
                .. ")"
        )
    end
    local slashed = gated({ "^/secret/", "^/nosuch/" })
    eq(http_get(slashed .. "/secret/").status, 401, "/secret/ under ^/secret/ is 401 without the token")
    eq(
        http_get(slashed .. "/nosuch/").status,
        401,
        "and /nosuch/ under ^/nosuch/ is 401 too, though no such directory exists"
    )
    -- A last segment of . names the directory as a slash does; curl
    -- squashes it, so the request goes raw.
    local port = tonumber(slashed:match(":(%d+)$"))
    local raw =
        H.response(assert(H.raw_request(port, ("GET /nosuch/. HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n\r\n"):format(port))))
    eq(raw.status, 401, "and /nosuch/. sent raw is 401 as well")
end)

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
-- number, and a headers string opened the socket before it raised.
H.case("start refuses a bad token, protected_paths, serve_dotfiles, index_names or headers", function()
    -- { option, value, the text the refusal must carry (the option's name
    -- unless given) }
    local bad = {
        { "token", "" },
        { "token", 42 },
        { "token", false },
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
        { "headers", "x", "headers must be a table" },
    }
    for _, c in ipairs(bad) do
        local name, value, says = c[1], c[2], c[3] or c[1]
        local shown = ("%s = %s"):format(name, vim.inspect(value, { newline = " ", indent = "" }))
        local tcps = H.handle_count("tcp")
        local started, res = pcall(server.start, { port = 0, root = tmpdir, [name] = value })
        local after = H.handle_count("tcp")
        if started then
            server.stop(res)
        end
        ok(
            not started and tostring(res):find(says, 1, true) ~= nil,
            ("%s is refused, naming %s: %s"):format(shown, says, tostring(res))
        )
        eq(after, tcps, ("%s opens no socket"):format(shown))
    end
    local started, res = pcall(server.start, {
        port = 0,
        root = tmpdir,
        token = TOKEN,
        protected_paths = { "^/content%.md$", "[%w_]+%.key$", "^/a/(b)$" },
    })
    ok(started, "a list of well-formed patterns starts: " .. tostring(started and "" or res))
    if started then
        server.stop(res)
    end
    -- init.lua's default: no patterns ask for no token.
    started, res = pcall(server.start, { port = 0, root = tmpdir, protected_paths = {} })
    ok(started, "protected_paths = {} starts without a token: " .. tostring(started and "" or res))
    if started then
        server.stop(res)
    end
    started, res = pcall(server.start, { port = 0, root = tmpdir, headers = { ["X-Custom"] = "1" } })
    ok(started, 'headers = { ["X-Custom"] = "1" } starts: ' .. tostring(started and "" or res))
    if started then
        server.stop(res)
    end
    -- The start check reads a pattern against the empty subject, so a
    -- malformed part after a literal ("/[") is never parsed there. The
    -- request the pattern was asked about raised in the read callback and
    -- went unanswered; no token satisfies a pattern nobody can read.
    local function unreadable_server(patterns)
        local up, inst_or_err = pcall(server.start, {
            port = 0,
            root = tmpdir,
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
        root = tmpdir,
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
    local computed = setmetatable({ port = 0, root = tmpdir, protected_paths = { "^/content%.md$" } }, {
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

-- The server read the caller's own table, which init.lua hands from the
-- user's options, so a caller that holed or emptied it after start dropped
-- the gate; index_names changed after start would name an index the start
-- check never read.
H.case("the server keeps its own copy of protected_paths and index_names", function()
    local patterns = { "^/content%.md$" }
    local inst = server.start({
        port = 0,
        root = tmpdir,
        token = TOKEN,
        protected_paths = patterns,
        live = { enabled = false, inject_script = false },
        features = { dirlist = { enabled = false } },
    })
    H.defer(function()
        server.stop(inst)
    end)
    local url = ("http://127.0.0.1:%d/content.md"):format(inst.port)
    eq(http_get(url).status, 401, "/content.md without the token is 401")
    patterns[1] = nil
    eq(http_get(url).status, 401, "and stays 401 after the caller's list is holed")
    local names = { "index.html" }
    local named = server.start({
        port = 0,
        root = tmpdir,
        index_names = names,
        live = { enabled = false, inject_script = false },
        features = { dirlist = { enabled = false } },
    })
    H.defer(function()
        server.stop(named)
    end)
    local root_url = ("http://127.0.0.1:%d/"):format(named.port)
    eq(http_get(root_url).status, 200, "/ answers with index.html")
    names[1] = 42
    local got = http_get(root_url)
    ok(
        got.status == 200 and got.body:find("hi", 1, true) ~= nil,
        ("and still does after the caller's index_names changes (got %d)"):format(got.status)
    )
end)

-- ─── Summary ────────────────────────────────────────────────────────────────
H.finish()
