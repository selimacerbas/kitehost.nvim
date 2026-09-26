-- tests/token_auth_test.lua
-- Verify that cfg.token gates /__live/events, /__live/inject, and any path
-- listed in cfg.protected_paths, while leaving static assets (index.html)
-- reachable without auth.
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
-- The first check reads /docs; only the index about to be served matches.
eq(http_get(("http://127.0.0.1:%d/docs/"):format(listed.port)).status, 401, "/docs/ serving a protected index is 401")
-- An index name may be a link out of the root, which the file route refuses.
local outside = vim.fs.joinpath(H.tmpdir(), "leak.html")
H.write_file(outside, "outside the root")
vim.fn.mkdir(vim.fs.joinpath(tmpdir, "sub"), "p")
local sub_index = vim.fs.joinpath(tmpdir, "sub", "index.html")
local olinked, olink_err = uv.fs_symlink(outside, sub_index)
if olinked and uv.fs_stat(sub_index) then
    eq(http_get(("http://127.0.0.1:%d/sub/"):format(listed.port)).status, 404, "an index linked out of the root is 404")
    eq(http_get(("http://127.0.0.1:%d/sub/?t=%s"):format(listed.port, TOKEN)).status, 404, "and 404 with the token")
else
    local why = " (" .. tostring(olink_err or "the link does not resolve") .. ")"
    H.skip("an index linked out of the root is 404" .. why)
    H.skip("and 404 with the token" .. why)
end
server.stop(listed)

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

-- An empty token is truthy, so it would mark every request as the
-- token's holder and pass the gate with no t= at all.
H.case("a token is a non-empty string or nothing", function()
    for _, bad in ipairs({ "", 42 }) do
        local tcps = H.handle_count("tcp")
        local started, res = pcall(server.start, { port = 0, root = tmpdir, token = bad })
        local after = H.handle_count("tcp")
        if started then
            server.stop(res)
        end
        ok(
            not started and tostring(res):find("token", 1, true) ~= nil,
            ("token = %s is refused, naming token: %s"):format(vim.inspect(bad), tostring(res))
        )
        eq(after, tcps, ("token = %s opens no socket"):format(vim.inspect(bad)))
    end
end)

-- ─── Summary ────────────────────────────────────────────────────────────────
H.finish()
