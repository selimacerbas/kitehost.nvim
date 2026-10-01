-- tests/token_auth_test.lua
-- The token's source first: random_token draws from vim.uv.random, then
-- /dev/urandom read as a character device, and raises naming both when
-- neither answers; its bytes are the token, its length an integer from 1
-- to 1024 (16 by default), and no descriptor stays open. Then verify that
-- cfg.token gates /__live/events, /__live/inject, and any path listed in
-- cfg.protected_paths but the injected client, /__live/script.js, while
-- leaving static assets (index.html) reachable without auth. The gate
-- reads the request path, then the name on disk of the file, index or
-- directory about to be served (a case variant, a link), each name once
-- a request; a NUL or a backslash in the path is 400 before it; a link
-- out of the root is 404.
-- The token is read first: a request carrying it runs no pattern, one
-- that cannot be read included, and is served. What start refuses is
-- tests/start_test.lua's.
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

-- Windows takes a / in a link's target unconverted, leaving the link
-- dangling, and opens no link to a directory made without dir = true
-- (measured on the hosted runner): a target here carries the platform's
-- separator and a link to a directory is made as one. A row through a
-- link runs only where the link resolves to the name it is about;
-- unresolved says why it does not, the reason the row is skipped with.
local sep = package.config:sub(1, 1)
local function unresolved(made, made_err, name, want)
    if not made then
        return "no link: " .. tostring(made_err)
    end
    local real, err = uv.fs_realpath(name)
    if not real then
        return "the link does not resolve: " .. tostring(err)
    end
    if not H.same_path(real, want) then
        return ("the link resolves to %s, not %s"):format(real, want)
    end
end

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
-- A count of calls passed a token drawn elsewhere after the call, from
-- /dev/urandom on every POSIX host, so the bytes are pinned. The stub
-- answers as luv does: a call with flags or a callback returns 0 and
-- delivers its bytes later, never as the token.
uv.random = function(n, ...)
    if select("#", ...) > 0 then
        return 0
    end
    local bytes = {}
    for i = 0, n - 1 do
        bytes[#bytes + 1] = string.char(i % 256)
    end
    return table.concat(bytes)
end
eq(util.random_token(16), "000102030405060708090a0b0c0d0e0f", "the token is vim.uv.random's bytes in hex, exactly")
uv.random = real_random
local plain = util.random_token()
ok(#plain == 32 and plain:match("^[0-9a-f]+$") ~= nil, "no length takes the default, 32 hex characters: " .. plain)
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
-- A length of 0 returned "", the token value start exists to refuse.
raises_length_error(0, "a length of 0 raises the length error")
raises_length_error(1025, "a length of 1025 raises the length error")
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

-- With vim.uv.random failing, /dev/urandom is the source: no row read it
-- answering, so its bytes dropped, a short read taken or its descriptor
-- left open all stayed green. It is read only as a character device: on
-- Windows the path names <drive>:\dev\urandom, which another local
-- account could plant, and a planted file gave a predictable token.
H.case("Section 1c: /dev/urandom answers when vim.uv.random fails, as a device alone", function()
    local real_read = uv.fs_read
    H.defer(function()
        uv.random, uv.fs_open, uv.fs_read = real_random, real_open, real_read
    end)
    uv.random = function()
        return nil, "EIO: random stubbed", "EIO"
    end
    local function fds_kept(before, label)
        if before then
            eq(H.fd_count(), before, label)
        else
            H.skip(label .. " (no descriptor listing on this platform)")
        end
    end
    local dev, dev_err = uv.fs_stat("/dev/urandom")
    if not (dev and dev.type == "char") then
        local why = " (no /dev/urandom device here: " .. tostring(dev_err or (dev and dev.type)) .. ")"
        for _, row in ipairs({
            "/dev/urandom answers with 32 hex characters",
            "and its descriptor is closed",
            "the token is the bytes read, in hex",
            "a short read raises naming both causes",
            "and its descriptor is closed",
        }) do
            H.skip(row .. why)
        end
    else
        local fds = H.fd_count()
        local good, res = pcall(util.random_token, 16)
        ok(
            good and #res == 32 and res:match("^[0-9a-f]+$") ~= nil,
            "/dev/urandom answers with 32 hex characters: " .. tostring(res)
        )
        fds_kept(fds, "and its descriptor is closed")
        -- The device's own descriptor answers with known bytes.
        local device_fd
        uv.fs_open = function(path, ...)
            local fd, err, name = real_open(path, ...)
            if path == "/dev/urandom" then
                device_fd = fd
            end
            return fd, err, name
        end
        local short = false
        uv.fs_read = function(fd, len, ...)
            if fd == device_fd then
                return string.rep("\171", short and len - 1 or len)
            end
            return real_read(fd, len, ...)
        end
        good, res = pcall(util.random_token, 4)
        eq(res, "abababab", "the token is the bytes read, in hex")
        short = true
        fds = H.fd_count()
        good, res = pcall(util.random_token, 16)
        res = tostring(res)
        ok(
            not good
                and res:find("vim.uv.random: EIO: random stubbed", 1, true) ~= nil
                and res:find("/dev/urandom: short read", 1, true) ~= nil,
            "a short read raises naming both causes: " .. res
        )
        fds_kept(fds, "and its descriptor is closed")
        uv.fs_open, uv.fs_read = real_open, real_read
    end
    local planted = H.tmpdir() .. "/urandom"
    H.write_file(planted, string.rep("A", 64))
    uv.fs_open = function(path, ...)
        if path == "/dev/urandom" then
            return real_open(planted, ...)
        end
        return real_open(path, ...)
    end
    local fds = H.fd_count()
    local good, res = pcall(util.random_token, 16)
    res = tostring(res)
    ok(
        not good and res:find("/dev/urandom: not a character device", 1, true) ~= nil,
        "a regular file at the path is no source: " .. res
    )
    fds_kept(fds, "and the planted file's descriptor is closed")
    -- An fstat that fails is no source either: the raise names its error,
    -- where a cause dropped there read as a short read.
    local real_fstat, urandom_fd = uv.fs_fstat, nil
    H.defer(function()
        uv.fs_fstat = real_fstat
    end)
    uv.fs_open = function(path, ...)
        if path == "/dev/urandom" then
            local fd, err, name = real_open(planted, ...)
            urandom_fd = fd
            return fd, err, name
        end
        return real_open(path, ...)
    end
    uv.fs_fstat = function(fd, ...)
        if fd == urandom_fd then
            return nil, "EIO: fstat stubbed", "EIO"
        end
        return real_fstat(fd, ...)
    end
    fds = H.fd_count()
    good, res = pcall(util.random_token, 16)
    res = tostring(res)
    ok(
        not good and res:find("/dev/urandom: EIO: fstat stubbed", 1, true) ~= nil,
        "an fstat that fails on the device's descriptor raises naming its error: " .. res
    )
    fds_kept(fds, "and that descriptor is closed")
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
local alias_why = unresolved(linked, link_err, alias, f2)
if not alias_why then
    eq(
        http_get(("http://127.0.0.1:%d/alias.md"):format(port)).status,
        401,
        "a link to content.md without the token is 401"
    )
else
    H.skip("a link to content.md without the token is 401 (" .. alias_why .. ")")
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
if not alias_why then
    local via = (slashed:gsub("content%.md$", "alias.md"))
    eq(
        http_get(("http://127.0.0.1:%d%s"):format(at_root.port, via)).status,
        401,
        "a link to content.md under root / is 401"
    )
else
    H.skip("a link to content.md under root / is 401 (" .. alias_why .. ")")
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
local dlinked, dlink_err = uv.fs_symlink("secret", vim.fs.joinpath(tmpdir, "pub"), { dir = true })
local dlink_why = unresolved(dlinked, dlink_err, vim.fs.joinpath(tmpdir, "pub"), vim.fs.joinpath(tmpdir, "secret"))
if not dlink_why then
    eq(
        http_get(("http://127.0.0.1:%d/pub/"):format(listed.port)).status,
        401,
        "a link to a protected directory lists nothing"
    )
else
    H.skip("a link to a protected directory lists nothing (" .. dlink_why .. ")")
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
local olink_why = unresolved(olinked, olink_err, sub_index, outside)
local function lists_sub(res)
    return res.status == 200
        and res.body:find("Index of /sub/", 1, true) ~= nil
        and not res.body:find(">index.html</a>", 1, true)
        and not res.body:find("outside the root", 1, true)
end
if not olink_why then
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
    local why = " (" .. olink_why .. ")"
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
if not dlink_why then
    eq(
        http_get(("http://127.0.0.1:%d/pub/"):format(bare_dir.port)).status,
        401,
        "a link to secret/ under ^/secret$ is 401 without the token"
    )
else
    H.skip("a link to secret/ under ^/secret$ is 401 without the token (" .. dlink_why .. ")")
end
server.stop(bare_dir)
-- default_index may sit outside the root and is served for / alone: a link
-- in the root back to the root reached it under a name the first check read
-- as another path, past a ^/$ pattern.
local outside_index = vim.fs.joinpath(H.tmpdir(), "outside.html")
H.write_file(outside_index, "<html>outside the root</html>")
local ws = H.tmpdir()
local loop = vim.fs.joinpath(ws, "loop")
local llinked, llink_err = uv.fs_symlink(ws, loop, { dir = true })
local loop_why = unresolved(llinked, llink_err, loop, ws)
local looped = not loop_why
local loop_skip = loop_why and (" (" .. loop_why .. ")")
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
local vlinked, vlink_err = uv.fs_symlink(tmpdir, via_root, { dir = true })
local via_why = unresolved(vlinked, vlink_err, via_root, tmpdir)
local spelled
if not via_why then
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
    local why = " (" .. via_why .. "; and the root is spelled as realpath names it)"
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
local rlink_why = unresolved(rlinked, rlink_err, root_index, outside_index)
local root_linked = not rlink_why
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
    local why = " (" .. rlink_why .. ")"
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
    local linked, link_err = uv.fs_symlink("secret", pub, { dir = true })
    local link_why = unresolved(linked, link_err, pub, vim.fs.joinpath(site, "secret"))
    if not link_why then
        eq(http_get(base .. "/pub/").status, 401, "a link pub -> secret without the token is 401, never its index")
    else
        H.skip("a link pub -> secret without the token is 401, never its index (" .. link_why .. ")")
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
    -- Such a path is read once, on its name with the slash, by a form of
    -- each pattern that matches wherever the pattern matches either
    -- spelling: an end anchor takes the slash as optional there, and a
    -- pattern whose frontier tells the path's end from a slash (%f[%z]) is
    -- read on both.
    local anchored = gated({ "^/gone$", "^/void%f[%z]", "^/held/$" })
    eq(http_get(anchored .. "/gone/").status, 401, "/gone/ under ^/gone$ is 401, though no such directory exists")
    eq(http_get(anchored .. "/void/").status, 401, "and /void/ under ^/void%f[%z]")
    eq(http_get(anchored .. "/held/").status, 401, "and /held/ under ^/held/$")
    eq(http_get(anchored .. "/gonex/").status, 404, "while /gonex/ under ^/gone$ is 404")
end)

-- A directory asked without its slash is read by its name, which
-- ^/secret/ does not match, then as the directory about to be served,
-- which it does. An answer kept by the name alone and given to the
-- directory's read served secret/ and its listing without the token.
H.case("a directory asked without its slash is gated as the directory", function()
    local function site(with_index)
        local root = H.tmpdir()
        vim.fn.mkdir(vim.fs.joinpath(root, "secret"), "p")
        H.write_file(vim.fs.joinpath(root, "secret", "a.txt"), "plain")
        if with_index then
            H.write_file(vim.fs.joinpath(root, "secret", "index.html"), "<html>SECRET-INDEX</html>")
        end
        local s = server.start({
            port = 0,
            root = root,
            token = TOKEN,
            protected_paths = { "^/secret/" },
            live = { enabled = false, inject_script = false },
            features = { dirlist = { enabled = true } },
        })
        H.defer(function()
            server.stop(s)
        end)
        return ("http://127.0.0.1:%d"):format(s.port)
    end
    local function shows_secret(body)
        return body:find("SECRET-INDEX", 1, true) ~= nil or body:find("a.txt", 1, true) ~= nil
    end
    for _, form in ipairs({
        { site(true), "its index", "SECRET-INDEX" },
        { site(false), "its listing", 'href="/secret/a.txt"' },
    }) do
        for _, path in ipairs({ "/secret", "/secret/" }) do
            local res = http_get(form[1] .. path)
            ok(
                res.status == 401 and not shows_secret(res.body),
                ("%s under ^/secret/ is 401 without the token, never %s (got %d)"):format(path, form[2], res.status)
            )
            res = http_get(form[1] .. path .. "?t=" .. TOKEN)
            ok(
                res.status == 200 and res.body:find(form[3], 1, true) ~= nil,
                ("and %s serves %s with it (got %d)"):format(path, form[2], res.status)
            )
        end
    end
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

-- The injected tag names /__live/script.js with no token, so a pattern
-- matching it (%.js$, ^/) answered the server's own client 401: live
-- reload died on every page, and the client's hint to add ?t= lived in
-- the refused script. The client holds no secret. A user's own file at
-- that name is no client: exempted by name inside the gate, it was served
-- ungated through a link to it or a case variant of its name, which the
-- route's exact match lets fall through to the file.
H.case("the injected client is never gated", function()
    local site = H.tmpdir()
    H.write_file(site .. "/index.html", "<html><body>page</body></html>")
    H.write_file(site .. "/app.js", "var secret = 1")
    vim.fn.mkdir(site .. "/__live", "p")
    H.write_file(site .. "/__live/script.js", "var mine = 1")
    -- A file of the client's name outside the reserved directory, whose
    -- files the root route never serves, so a link to it reads the gate.
    vim.fn.mkdir(site .. "/lib", "p")
    H.write_file(site .. "/lib/script.js", "var linked = 1")
    local linked, link_err = uv.fs_symlink("lib" .. sep .. "script.js", site .. "/alias.txt")
    local gated = server.start({
        port = 0,
        root = site,
        token = TOKEN,
        protected_paths = { "%.js$" },
        live = { enabled = false, inject_script = true },
        features = { dirlist = { enabled = false } },
    })
    H.defer(function()
        server.stop(gated)
    end)
    local base = ("http://127.0.0.1:%d"):format(gated.port)
    local client = http_get(base .. "/__live/script.js")
    eq(client.status, 200, "a token server with protected_paths %.js$ serves /__live/script.js without the token")
    ok(
        client.body:find("EventSource", 1, true) ~= nil and not client.body:find("var mine", 1, true),
        "and it is the client, never the root's file of that name"
    )
    eq(http_get(base .. "/app.js").status, 401, "while a .js file under the root still wants the token")
    -- The route reads the canonical path, so each spelling of it is the
    -- client: one matched on the request's own spelling wanted the token
    -- for a query, an escape, a doubled or a trailing slash, and with no
    -- pattern served the root's own file of that name.
    local open = server.start({
        port = 0,
        root = site,
        token = TOKEN,
        live = { enabled = false, inject_script = true },
        features = { dirlist = { enabled = false } },
    })
    H.defer(function()
        server.stop(open)
    end)
    for _, s in ipairs({ { gated, "%.js$" }, { open, "no pattern" } }) do
        for _, spelling in ipairs({
            "/__live/script.js?x=1",
            "/%5F_live/script.js",
            "//__live/script.js",
            "/__live/script.js/",
        }) do
            local r = http_get(("http://127.0.0.1:%d%s"):format(s[1].port, spelling))
            ok(
                r.status == 200 and r.body == client.body,
                ("under %s, %s answers the client's bytes, never the root's file (got %d: %s)"):format(
                    s[2],
                    spelling,
                    r.status,
                    r.body:sub(1, 40)
                )
            )
        end
    end
    -- Windows may refuse the link (no symlink privilege). The rows run
    -- only where the link resolves to lib/script.js: a dangling one is a
    -- missing name, whose 404 is no answer about the token.
    local why = unresolved(linked, link_err, site .. "/alias.txt", site .. "/lib/script.js")
    if not why then
        eq(http_get(base .. "/alias.txt").status, 401, "a file named script.js reached through a link wants the token")
        local r = http_get(base .. "/alias.txt?t=" .. TOKEN)
        ok(r.status == 200 and r.body == "var linked = 1", ("and is served with it (got %d)"):format(r.status))
    else
        H.skip("a file named script.js reached through a link wants the token (" .. why .. ")")
        H.skip("and is served with it (" .. why .. ")")
    end
    -- A case-sensitive volume has no second name for the file. The variant
    -- is a name under /__live/ that is no route, so it never reaches the
    -- file at all.
    if uv.fs_stat(site .. "/__live/SCRIPT.JS") then
        local r = http_get(base .. "/__live/SCRIPT.JS")
        eq(r.status, 404, "the root's own __live/script.js under a case variant is 404, never served")
    else
        H.skip("a case variant of the root's own __live/script.js (this volume is case-sensitive)")
    end
    local page = http_get(base .. "/", { "Sec-Fetch-Mode: navigate" })
    ok(
        page.body:find('<script src="/__live/script.js"></script>', 1, true) ~= nil,
        "the page's injected tag still names /__live/script.js: " .. page.body
    )
end)

-- The token opens every path, so the patterns decide only for a request
-- without it; matched first, each spent the loop's time on a request
-- the token was about to open whatever they answered. A request that
-- carries the token runs no pattern, a pattern that cannot be read
-- included, which answered it 401 though its holder may read any path.
H.case("a request carrying the token runs no pattern", function()
    -- No pattern start takes nests past LuaJIT's depth within 256 bytes,
    -- so the raise it gives one, "pattern too complex", is stubbed for
    -- this pattern on the path of x/ it is asked about.
    local deep = "^/" .. ("x*/"):rep(84)
    local xs = "/" .. ("x/"):rep(84)
    local counted = { ["^/content%.md$"] = true, [deep] = true }
    local real_find, runs = string.find, 0
    H.defer(function()
        string.find = real_find
    end)
    string.find = function(s, pat, ...)
        if counted[pat] then
            runs = runs + 1
        end
        if pat == deep and s == xs then
            error("pattern too complex", 0)
        end
        return real_find(s, pat, ...)
    end
    local inst = server.start({
        port = 0,
        root = tmpdir,
        token = TOKEN,
        protected_paths = { "^/content%.md$", deep },
        live = { enabled = false, inject_script = false },
        features = { dirlist = { enabled = false } },
    })
    H.defer(function()
        server.stop(inst)
    end)
    local base = ("http://127.0.0.1:%d"):format(inst.port)

    for _, c in ipairs({
        { "/content.md?t=" .. TOKEN, 200, 0, "a protected path with the token" },
        { "/index.html?t=" .. TOKEN, 200, 0, "an open path with the token" },
        { xs .. "?t=" .. TOKEN, 404, 0, "a path the deep pattern cannot read, with the token" },
        { "/content.md", 401, nil, "a protected path without it" },
        { "/content.md?t=wrong", 401, nil, "a protected path with a wrong token" },
        { xs, 401, nil, "a path the deep pattern cannot read, without it" },
    }) do
        runs = 0
        local got = http_get(base .. c[1])
        eq(got.status, c[2], c[4] .. " is " .. c[2])
        if c[3] then
            eq(runs, c[3], "and runs no pattern")
        else
            ok(runs > 0, ("and the patterns decide it (%d runs)"):format(runs))
        end
    end
end)

-- Each pattern spends the loop's time on every name it reads, so a name
-- is read once a request: the name on disk is read again only where it
-- differs from the request's spelling (a link, a case variant), which
-- the gate must still refuse by the name it reaches.
H.case("a request reads each pattern once for each name it reaches", function()
    local site = H.tmpdir()
    H.write_file(vim.fs.joinpath(site, "page.html"), "<html>page</html>")
    vim.fn.mkdir(vim.fs.joinpath(site, "docs"), "p")
    local patterns = { "^/one/", "^/two$", "^/%f[%w]three" }
    local real_find, runs = string.find, {}
    H.defer(function()
        string.find = real_find
    end)
    -- Counted by the pattern's text up to an end anchor.
    string.find = function(s, pat, ...)
        for _, p in ipairs(patterns) do
            local stem = p:gsub("%$$", "")
            if pat:sub(1, #stem) == stem then
                runs[p] = runs[p] + 1
            end
        end
        return real_find(s, pat, ...)
    end
    local inst = server.start({
        port = 0,
        root = site,
        token = TOKEN,
        protected_paths = patterns,
        live = { enabled = false, inject_script = false },
        features = { dirlist = { enabled = true } },
    })
    H.defer(function()
        server.stop(inst)
    end)
    local base = ("http://127.0.0.1:%d"):format(inst.port)
    local function reads(path, status, want, label)
        for _, p in ipairs(patterns) do
            runs[p] = 0
        end
        eq(http_get(base .. path).status, status, ("%s is %d without the token"):format(label, status))
        for _, p in ipairs(patterns) do
            eq(runs[p], want, ("and %s is read %d time%s"):format(p, want, want == 1 and "" or "s"))
        end
    end
    reads("/page.html", 200, 1, "a file asked by its own name")
    -- A path naming a directory is refused when a pattern matches its
    -- name with or without the slash, which read every pattern on both;
    -- it is read once, on the name with the slash. A directory asked
    -- without its slash is read by that name, then as a directory.
    reads("/docs/", 200, 1, "a directory asked with its slash")
    reads("/nosuch/", 404, 1, "a missing directory asked with its slash")
    reads("/" .. ("a"):rep(8 * 1024 - 2) .. "/", 404, 1, "an 8 KiB path ending in a slash")
    reads("/docs", 200, 2, "a directory asked without its slash")
    local alias = vim.fs.joinpath(site, "alias.html")
    local linked, link_err = uv.fs_symlink("page.html", alias)
    local why = unresolved(linked, link_err, alias, vim.fs.joinpath(site, "page.html"))
    if not why then
        reads("/alias.html", 200, 2, "a link to it, read by its name and the file's")
    else
        H.skip("a link to it is read by both names (" .. why .. ")")
    end
    if H.fs_folds_case then
        reads("/PAGE.HTML", 200, 2, "a case variant, read by its spelling and the disk's")
    else
        H.skip("a case variant is read by both names (a case-sensitive volume has no such file)")
    end
end)

-- ─── Summary ────────────────────────────────────────────────────────────────
H.finish()
