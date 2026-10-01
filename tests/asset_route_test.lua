-- tests/asset_route_test.lua
-- Verify the /__live/asset endpoint:
--   - serves files relative to cfg.asset_root (string or function form)
--   - requires ?t=<token> when token auth is configured
--   - rejects traversal (a symlink out of the root too), absolute paths, and schemes
--   - refuses secrets by name (.env, .git, key files) and anything but a file
--   - serves nothing from an asset root that is no path, and refuses at
--     start a string root inside a credential directory such as .ssh,
--     whose function form serves nothing there (Section 4)
--   - sandboxes the HTML, SVG and XML documents it serves, never the root
--     route's index (Section 5)
--   - fixes a string root at start (a relative one needs the working
--     directory then) and resolves the string given again per request,
--     which must still name the real path kept: a link put at the kept
--     path, the root removed or a link given as the root and repointed
--     is 404 and warned once; reads a function per request, a raise or
--     an answer that is no absolute directory outside the credential
--     directories warned once, nil a silent 404 (Section 6)
--
-- Run: nvim --headless -u NONE -l "$PWD/tests/asset_route_test.lua"

local H = dofile(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "helpers.lua"))
H.isolate()
H.rtp()

local uv = vim.uv
local server = require("live_server.server")
local lutil = require("live_server.util")
local eq, http_get, write_file = H.eq, H.http_get, H.write_file

-- Layout:
--   tmpdir/www/index.html          (served root)
--   tmpdir/src/pic.png             (asset root)
--   tmpdir/src/sub/nested.txt
--   tmpdir/src/.images/pic.png     (a dot directory served on purpose)
--   tmpdir/secret.txt              (outside asset root)
local tmpdir = H.tmpdir()
vim.fn.mkdir(tmpdir .. "/www", "p")
vim.fn.mkdir(tmpdir .. "/src/sub", "p")
write_file(tmpdir .. "/www/index.html", "<html><body>ok</body></html>")
write_file(tmpdir .. "/src/pic.png", "PNGDATA")
write_file(tmpdir .. "/src/sub/nested.txt", "nested")
write_file(tmpdir .. "/secret.txt", "SECRET")
vim.fn.mkdir(tmpdir .. "/src/.images", "p")
write_file(tmpdir .. "/src/.images/pic.png", "PNGDATA")
vim.fn.mkdir(tmpdir .. "/src/dir.png", "p")
write_file(tmpdir .. "/src/.env", "DENIED")
write_file(tmpdir .. "/src/.env.local", "DENIED")
vim.fn.mkdir(tmpdir .. "/src/sub/.git", "p")
write_file(tmpdir .. "/src/sub/.git/config", "DENIED")
write_file(tmpdir .. "/src/key.pem", "DENIED")
write_file(tmpdir .. "/src/cert.crt", "DENIED")
write_file(tmpdir .. "/src/id.key", "DENIED")
write_file(tmpdir .. "/src/SERVER.PEM", "DENIED")
write_file(tmpdir .. "/src/.npmrc", "DENIED")
write_file(tmpdir .. "/src/store.p12", "DENIED")
vim.fn.mkdir(tmpdir .. "/src/.ssh", "p")
write_file(tmpdir .. "/src/.ssh/id_ed25519", "DENIED")
write_file(tmpdir .. "/src/.ssh/config", "DENIED")
vim.fn.mkdir(tmpdir .. "/src/.gnupg", "p")
write_file(tmpdir .. "/src/.gnupg/pubring.kbx", "DENIED")
vim.fn.mkdir(tmpdir .. "/src/.github/assets", "p")
write_file(tmpdir .. "/src/.github/assets/logo.png", "PNGDATA")
write_file(tmpdir .. "/src/my pic.png", "PNGDATA")
write_file(tmpdir .. "/src/gr\195\188n.png", "PNGDATA")
write_file(tmpdir .. "/src/id_card.png", "PNGDATA")
write_file(tmpdir .. "/src/page.html", "<html><body>x</body></html>")
write_file(tmpdir .. "/src/page.htm", "<html><body>x</body></html>")
write_file(tmpdir .. "/src/page.xhtml", "<html xmlns='http://www.w3.org/1999/xhtml'/>")
write_file(tmpdir .. "/src/pic.svg", "<svg xmlns='http://www.w3.org/2000/svg'/>")
write_file(tmpdir .. "/src/UPPER.SVG", "<svg xmlns='http://www.w3.org/2000/svg'/>")
write_file(tmpdir .. "/src/feed.xml", "<feed/>")
write_file(tmpdir .. "/src/notes.txt", "notes")

local TOKEN = lutil.random_token(16)

H.section("Section 1: token-gated asset route (asset_root as string)")

local inst = server.start({
    port = 0,
    root = tmpdir .. "/www",
    token = TOKEN,
    asset_root = tmpdir .. "/src",
    live = { inject_script = false },
    features = { dirlist = { enabled = false } },
})
local base = ("http://127.0.0.1:%d"):format(inst.port)

eq(http_get(base .. "/__live/asset?p=pic.png").status, 401, "asset without token is 401")
local r = http_get(base .. "/__live/asset?p=pic.png&t=" .. TOKEN)
eq(r.status, 200, "asset with token is 200")
eq(r.body, "PNGDATA", "asset body matches")
eq(http_get(base .. "/__live/asset?p=sub%2Fnested.txt&t=" .. TOKEN).status, 200, "nested asset (encoded slash) is 200")
eq(http_get(base .. "/__live/asset?p=../secret.txt&t=" .. TOKEN).status, 404, "traversal ../ is 404")
eq(http_get(base .. "/__live/asset?p=%2e%2e%2fsecret.txt&t=" .. TOKEN).status, 404, "encoded traversal is 404")
eq(http_get(base .. "/__live/asset?p=/etc/hosts&t=" .. TOKEN).status, 404, "absolute path is 404")
eq(http_get(base .. "/__live/asset?p=c:%5Cwin&t=" .. TOKEN).status, 404, "drive letter / backslash is 404")
eq(http_get(base .. "/__live/asset?p=missing.png&t=" .. TOKEN).status, 404, "missing file is 404")
eq(http_get(base .. "/__live/asset?t=" .. TOKEN).status, 404, "missing p param is 404")
eq(
    http_get(base .. "/__live/asset?p=pic.png%00.txt&t=" .. TOKEN).status,
    404,
    "a NUL in p is 404 (libuv would open the name before it)"
)
-- Vite's default fs.deny names: an image beside a markdown file is
-- served, its secrets are not.
for _, p in ipairs({ ".env", ".env.local", "sub/.git/config", "key.pem", "cert.crt", "id.key", ".ENV" }) do
    eq(http_get(base .. "/__live/asset?p=" .. p .. "&t=" .. TOKEN).status, 404, "p=" .. p .. " is 404")
end
-- The name asked for is read too: the resolved name (nested.txt) passes,
-- and a link named .env still serves the secret it points at.
local named = tmpdir .. "/src/sub/.env"
local named_ok, named_err = uv.fs_symlink("nested.txt", named)
local named_st, named_st_err = uv.fs_stat(named)
if named_ok and named_st then
    eq(http_get(base .. "/__live/asset?p=sub/.env&t=" .. TOKEN).status, 404, "a .env linking to a plain name is 404")
else
    H.skip("a .env linking to a plain name is 404 (" .. tostring(named_err or named_st_err) .. ")")
end
-- A file's name never ends in a separator or a dot segment, yet macOS's
-- realpath resolves one on a file: sub/.env/ read an empty base name past
-- the list and served the link's target.
if named_ok and named_st then
    for _, p in ipairs({ "sub/.env/", "sub/.env/." }) do
        eq(http_get(base .. "/__live/asset?p=" .. p .. "&t=" .. TOKEN).status, 404, "p=" .. p .. " is 404")
    end
else
    local why = " (" .. tostring(named_err or named_st_err) .. ")"
    H.skip("p=sub/.env/ is 404" .. why)
    H.skip("p=sub/.env/. is 404" .. why)
end
eq(http_get(base .. "/__live/asset?p=pic.png/&t=" .. TOKEN).status, 404, "p=pic.png/ is 404")
-- One row per group beyond the names above: a credential file by name, a
-- key store by extension, a key in a credential directory, a credential
-- directory by name (the sub/.git row above reads it at depth), and a
-- plain name inside one, which the directory entry alone refuses.
for _, p in ipairs({ ".npmrc", "store.p12", ".ssh/id_ed25519", ".gnupg/pubring.kbx", ".ssh/config" }) do
    eq(http_get(base .. "/__live/asset?p=" .. p .. "&t=" .. TOKEN).status, 404, "p=" .. p .. " is 404")
end
-- realpath returns the spelling on disk, so a case-folding volume hands the
-- check .ENV as .env; a name upper case on disk needs the lowercased read.
eq(http_get(base .. "/__live/asset?p=SERVER.PEM&t=" .. TOKEN).status, 404, "p=SERVER.PEM is 404")
local alias = tmpdir .. "/src/ok.png"
local aliased, alias_err = uv.fs_symlink(".env", alias)
local alias_st, alias_st_err = uv.fs_stat(alias)
if aliased and alias_st then
    eq(http_get(base .. "/__live/asset?p=ok.png&t=" .. TOKEN).status, 404, "an image name linking to .env is 404")
else
    H.skip("an image name linking to .env is 404 (" .. tostring(alias_err or alias_st_err) .. ")")
end
-- A deny list, not the root route's dot rule: a document may keep its
-- images in a dot directory (.images); markdown-preview sends every relative
-- image here, so the names a document uses stay served: another dot
-- directory, a space, a non-ASCII name, a name that starts like a key file.
eq(http_get(base .. "/__live/asset?p=.images/pic.png&t=" .. TOKEN).status, 200, "an image under a dot directory is 200")
for _, p in ipairs({ ".github/assets/logo.png", "my%20pic.png", "gr%C3%BCn.png", "id_card.png" }) do
    eq(http_get(base .. "/__live/asset?p=" .. p .. "&t=" .. TOKEN).status, 200, "p=" .. p .. " is 200")
end
-- A regular file alone: opening a FIFO blocks the loop past SIGTERM before
-- stream_file's fstat reads the type, so the branch checks the type first,
-- and a FIFO row would hang this suite rather than fail. A directory takes
-- the same check; stream_file's own 404 names no disk path either, so this
-- row asserts the status and the page alone, not which of the two answered.
local dir_r = http_get(base .. "/__live/asset?p=dir.png&t=" .. TOKEN)
eq(dir_r.status, 404, "a directory named like an image is 404")
eq(dir_r.body:find(assert(uv.fs_realpath(tmpdir .. "/src")), 1, true), nil, "that 404 names no path on disk")
-- Containment is by the resolved path, not the spelling: a link inside the
-- asset root that points above it was served by a lexical check (measured on
-- a mutant). The target is written with the platform's separator, since
-- Windows took a / in it unconverted and the link did not resolve (measured
-- on the hosted runner); a link that cannot be made or does not resolve is
-- skipped, counted.
local link = tmpdir .. "/src/link.txt"
local linked, link_err = uv.fs_symlink(".." .. package.config:sub(1, 1) .. "secret.txt", link)
local link_st, link_st_err = uv.fs_stat(link)
if linked and link_st then
    eq(
        http_get(base .. "/__live/asset?p=link.txt&t=" .. TOKEN).status,
        404,
        "a symlink in the asset root pointing above it is 404"
    )
else
    H.skip("a symlink in the asset root pointing above it is 404 (" .. tostring(link_err or link_st_err) .. ")")
end

server.stop(inst)

H.section("Section 2: asset_root as function, no token configured")

local current_root = tmpdir .. "/src"
inst = server.start({
    port = 0,
    root = tmpdir .. "/www",
    asset_root = function()
        return current_root
    end,
    live = { inject_script = false },
    features = { dirlist = { enabled = false } },
})
base = ("http://127.0.0.1:%d"):format(inst.port)

eq(http_get(base .. "/__live/asset?p=pic.png").status, 200, "no-token server serves asset openly (backward compat)")
current_root = tmpdir .. "/src/sub"
eq(http_get(base .. "/__live/asset?p=nested.txt").status, 200, "function root is re-evaluated per request")
eq(http_get(base .. "/__live/asset?p=pic.png").status, 404, "old root no longer served after function retarget")

server.stop(inst)

H.section("Section 3: no asset_root configured")

inst = server.start({
    port = 0,
    root = tmpdir .. "/www",
    live = { inject_script = false },
    features = { dirlist = { enabled = false } },
})
base = ("http://127.0.0.1:%d"):format(inst.port)
eq(http_get(base .. "/__live/asset?p=pic.png").status, 404, "asset route 404s when asset_root unset")
server.stop(inst)

H.section("Section 4: the asset root itself")

local function asset_server(aroot)
    return server.start({
        port = 0,
        root = tmpdir .. "/www",
        token = TOKEN,
        asset_root = aroot,
        live = { enabled = false, inject_script = false },
        features = { dirlist = { enabled = false } },
    })
end
-- A callback returning a table raised inside the read callback, and the
-- connection was never answered. Its warning is Section 6's.
local section_notify = vim.notify
vim.notify = function() end
inst = asset_server(function()
    return {}
end)
base = ("http://127.0.0.1:%d"):format(inst.port)
eq(http_get(base .. "/__live/asset?p=a.png&t=" .. TOKEN).status, 404, "an asset_root callback returning a table is 404")
server.stop(inst)
vim.wait(50)
vim.notify = section_notify
-- The list read the names below the asset root alone, so a document kept in
-- ~/.ssh served the keys beside it. A string root there is refused at
-- start, since every request under it would answer 404 without a word;
-- a function's answer there is read per request.
vim.fn.mkdir(tmpdir .. "/.ssh", "p")
write_file(tmpdir .. "/.ssh/pic.png", "PNGDATA")
local up, why = pcall(asset_server, tmpdir .. "/.ssh")
eq(
    not up and tostring(why) or "started",
    ("asset_root is inside a credential directory (.ssh): %s"):format(vim.inspect(tmpdir .. "/.ssh")),
    "an asset root inside .ssh is refused at start, naming the directory"
)
if up then
    server.stop(why)
end
inst = asset_server(function()
    return tmpdir .. "/.ssh"
end)
base = ("http://127.0.0.1:%d"):format(inst.port)
eq(
    http_get(base .. "/__live/asset?p=pic.png&t=" .. TOKEN).status,
    404,
    "an asset root inside .ssh a function answers serves nothing"
)
server.stop(inst)

H.section("Section 5: active documents on the asset route are sandboxed")

-- A crafted SVG or HTML file beside a markdown document ran script in the
-- server's origin and could read the preview page; a sandboxed response
-- gets an opaque origin and no script.
local function sandbox_server(headers)
    return server.start({
        port = 0,
        root = tmpdir .. "/www",
        token = TOKEN,
        asset_root = tmpdir .. "/src",
        headers = headers,
        live = { inject_script = false },
        features = { dirlist = { enabled = false } },
    })
end
local function raw_get(path)
    local req = ("GET %s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n\r\n"):format(path, inst.port)
    return H.response(assert(H.raw_request(inst.port, req)))
end
inst = sandbox_server(nil)
-- realpath returns the name as spelled on disk, and the MIME lookup reads
-- UPPER.SVG as an SVG, so the extension is read lowercased.
for _, name in ipairs({ "page.html", "page.htm", "page.xhtml", "pic.svg", "feed.xml", "UPPER.SVG" }) do
    local res = raw_get("/__live/asset?p=" .. name .. "&t=" .. TOKEN)
    eq(res.count["content-security-policy"], 1, name .. " carries one policy field")
    eq(res.headers["content-security-policy"], "sandbox", name .. " on the asset route is sandboxed")
end
-- The resolved name decides, as it does for the MIME type: a link named
-- alias.txt serves pic.svg as an SVG, and alias2.svg serves a text file as
-- text. A link that cannot be made or does not resolve is skipped, counted.
for _, l in ipairs({
    { name = "alias.txt", target = "pic.svg", count = 1, policy = "sandbox" },
    { name = "alias.svg", target = "page.html", count = 1, policy = "sandbox" },
    { name = "alias2.svg", target = "notes.txt" },
}) do
    local what = l.name .. " linking to " .. l.target
    local rows = {
        what .. " is 200",
        what .. (l.count and " carries one policy field" or " carries no policy field"),
        what .. (l.policy and " is sandboxed" or " is not sandboxed"),
    }
    local link_path = tmpdir .. "/src/" .. l.name
    local made, made_err = uv.fs_symlink(l.target, link_path)
    local made_st, made_st_err = uv.fs_stat(link_path)
    if made and made_st then
        local res = raw_get("/__live/asset?p=" .. l.name .. "&t=" .. TOKEN)
        eq(res.status, 200, rows[1])
        eq(res.count["content-security-policy"], l.count, rows[2])
        eq(res.headers["content-security-policy"], l.policy, rows[3])
    else
        local why = " (" .. tostring(made_err or made_st_err) .. ")"
        for _, row in ipairs(rows) do
            H.skip(row .. why)
        end
    end
end
local img = raw_get("/__live/asset?p=pic.png&t=" .. TOKEN)
eq(img.status, 200, "an image on the asset route is 200")
eq(img.headers["content-security-policy"], nil, "an image is not sandboxed")
-- A sandboxed index would make its own event stream cross-origin. The
-- preview opens /, which the directory's index branch answers; the file by
-- name takes the file branch.
local index = raw_get("/index.html")
eq(index.status, 200, "the root route's index is 200")
eq(index.headers["content-security-policy"], nil, "the root route's index is never sandboxed")
local dir_index = raw_get("/?t=" .. TOKEN)
eq(dir_index.status, 200, "the root route's / is 200")
eq(dir_index.count["content-security-policy"], nil, "the root route's / carries no policy field")
server.stop(inst)
-- A caller's policy is kept and the sandbox joins it in one field, last:
-- each policy in the field is enforced, and the HTML standard reads the last
-- sandbox directive, so a caller's own sandbox cannot loosen the server's.
-- The image is read after the document, so a policy written into the shared
-- headers shows there.
inst = sandbox_server({ ["content-security-policy"] = "default-src *" })
local doc = raw_get("/__live/asset?p=pic.svg&t=" .. TOKEN)
eq(doc.count["content-security-policy"], 1, "a caller's lowercase policy and the sandbox are one field")
eq(doc.headers["content-security-policy"], "default-src *, sandbox", "the sandbox joins a caller's policy last")
eq(
    raw_get("/__live/asset?p=pic.png&t=" .. TOKEN).headers["content-security-policy"],
    "default-src *",
    "an image keeps the caller's policy"
)
server.stop(inst)
-- A caller's own sandbox allow-scripts would loosen the server's were it
-- read last, and it sorts after the bare word, so the server's sandbox is
-- appended after the caller's policy, never sorted in with it.
inst = sandbox_server({ ["Content-Security-Policy"] = "sandbox allow-scripts" })
local loose = raw_get("/__live/asset?p=pic.svg&t=" .. TOKEN)
eq(loose.count["content-security-policy"], 1, "a caller's sandbox allow-scripts and the server's are one field")
eq(
    loose.headers["content-security-policy"],
    "sandbox allow-scripts, sandbox",
    "the server's sandbox comes after the caller's"
)
server.stop(inst)

H.section("Section 6: a string root is fixed at start, a function is read per request")

-- A relative string was resolved on every request, so a later :cd moved
-- the served asset tree.
local cwd = assert(uv.cwd())
assert(uv.chdir(tmpdir))
local started, res = pcall(asset_server, "src")
assert(uv.chdir(cwd))
eq(started, true, "a relative asset_root starts: " .. tostring(started or res))
if started then
    inst = res
    base = ("http://127.0.0.1:%d"):format(inst.port)
    eq(http_get(base .. "/__live/asset?p=pic.png&t=" .. TOKEN).status, 200, "a relative asset_root serves its asset")
    assert(uv.chdir(tmpdir .. "/www"))
    local after = http_get(base .. "/__live/asset?p=pic.png&t=" .. TOKEN)
    assert(uv.chdir(cwd))
    eq(after.status, 200, "and still does after the working directory changes")
    server.stop(inst)
end
-- The string is kept made absolute for the per-request check, so a
-- relative one needs the working directory at start.
local real_cwd = uv.cwd
assert(uv.chdir(tmpdir))
uv.cwd = function()
    return nil, "ENOENT: stubbed"
end
started, res = pcall(asset_server, "src")
uv.cwd = real_cwd
assert(uv.chdir(cwd))
if started then
    server.stop(res)
end
eq(
    not started and tostring(res) or "started",
    "asset_root is relative and the working directory is unknown: ENOENT: stubbed",
    "a relative asset_root with the working directory unknown is refused"
)
-- A caller retargets its function between requests and may have no root
-- yet when the server starts, so start never calls it; each request does.
local calls = 0
inst = asset_server(function()
    calls = calls + 1
    return tmpdir .. "/src"
end)
eq(calls, 0, "start does not call a function asset_root")
base = ("http://127.0.0.1:%d"):format(inst.port)
eq(http_get(base .. "/__live/asset?p=pic.png&t=" .. TOKEN).status, 200, "an asset request is served through it")
eq(calls, 1, "and that one request calls it once")
server.stop(inst)
-- A callback that raised answered 404 with no word, and vim.fn inside it
-- raises on every request. Captured here, where the real notify would
-- print to the run.
local notes = {}
local real_notify = vim.notify
vim.notify = function(msg, level)
    table.insert(notes, { msg = msg, level = level })
end
-- The text is cut as a request's fault is: its first line, 300 bytes, a
-- control byte marked, so a long or multi-line raise reaches no notifier
-- whole.
inst = asset_server(function()
    error("boom\27[2J" .. string.rep("L", 5000) .. "\nsecond line")
end)
base = ("http://127.0.0.1:%d"):format(inst.port)
eq(http_get(base .. "/__live/asset?p=pic.png&t=" .. TOKEN).status, 404, "a raising asset_root callback is 404")
eq(http_get(base .. "/__live/asset?p=pic.png&t=" .. TOKEN).status, 404, "and 404 again")
H.wait_for(function()
    return #notes >= 1
end, 1000)
-- A second warning scheduled by the later request would land here.
vim.wait(100)
local head = ("live-server: port %d asset_root raised ("):format(inst.port)
local tail = "); the asset request was answered 404"
local msg = notes[1] and notes[1].msg or ""
H.ok(
    #notes == 1
        and notes[1].level == vim.log.levels.WARN
        and msg:find(head, 1, true) == 1
        and msg:find("boom?[2J", 1, true) ~= nil
        and msg:sub(-#tail) == tail,
    "two requests warn once, carrying the error's text marked: " .. vim.inspect(notes, { newline = " ", indent = "" })
)
H.ok(
    not msg:find("second line", 1, true) and #msg <= #head + 300 + #tail,
    ("the warning holds the raise's first line, cut to 300 bytes (%d bytes)"):format(#msg)
)
server.stop(inst)
-- A callback returning nil says there is no root yet: a 404, and no word.
notes = {}
inst = asset_server(function() end)
base = ("http://127.0.0.1:%d"):format(inst.port)
eq(http_get(base .. "/__live/asset?p=pic.png&t=" .. TOKEN).status, 404, "a callback returning nil is 404")
server.stop(inst)
vim.wait(100)
eq(#notes, 0, "and warns nothing")
-- Any other answer is held to the string form's rule, an absolute path
-- naming a directory outside every credential directory: a missing
-- directory, a file or another type answered every request 404 without
-- a word, and a relative path followed the working directory at each
-- request (the cwd here makes "src" name the asset tree). Each is 404
-- and warns once per server, naming the answer marked.
vim.fn.mkdir(tmpdir .. "/.git/imgs", "p")
write_file(tmpdir .. "/.git/imgs/pic.png", "PNGDATA")
local answers = {
    { "a relative path", "src", '"src", which is a relative path' },
    { "a missing directory", tmpdir .. "/missing", ('"%s/missing", which is not a directory (ENOENT)'):format(tmpdir) },
    { "a file", tmpdir .. "/secret.txt", ('"%s/secret.txt", which is not a directory'):format(tmpdir) },
    {
        "a credential directory",
        tmpdir .. "/.git/imgs",
        ('"%s/.git/imgs", which is inside a credential directory (.git)'):format(tmpdir),
    },
    { "a number", 42, "a number, which is no path" },
    { "a table", {}, "a table, which is no path" },
    { "a name with controls", "sr\27[2Jc", '"sr?[2Jc", which is a relative path' },
    -- libuv reads a path as a C string, so the directory before the NUL
    -- was served.
    {
        "a path holding a NUL",
        tmpdir .. "/src\0junk",
        ('"%s/src?junk", which is a path holding a NUL byte'):format(tmpdir),
    },
}
-- A drive letter or a leading backslash is absolute on Windows alone; on
-- macOS and Linux each is a relative name, which followed the working
-- directory at each request, served with no word (the cwd here holds
-- both, a picture in each).
if vim.fn.has("win32") == 0 then
    vim.fn.mkdir(tmpdir .. "/C:/src", "p")
    vim.fn.mkdir(tmpdir .. "/\\src", "p")
    write_file(tmpdir .. "/C:/src/pic.png", "PNGDATA")
    write_file(tmpdir .. "/\\src/pic.png", "PNGDATA")
    table.insert(answers, { "a drive-letter path", "C:/src", '"C:/src", which is a relative path' })
    table.insert(answers, { "a backslash path", "\\src", '"\\src", which is a relative path' })
else
    H.skip("a drive-letter or backslash answer is relative on macOS and Linux (this is Windows)")
end
for _, c in ipairs(answers) do
    notes = {}
    local answer = c[2]
    inst = asset_server(function()
        return answer
    end)
    base = ("http://127.0.0.1:%d"):format(inst.port)
    assert(uv.chdir(tmpdir))
    local first = http_get(base .. "/__live/asset?p=pic.png&t=" .. TOKEN)
    local second = http_get(base .. "/__live/asset?p=pic.png&t=" .. TOKEN)
    assert(uv.chdir(cwd))
    eq(first.status, 404, "a callback answering " .. c[1] .. " is 404")
    eq(second.status, 404, "and 404 again")
    H.wait_for(function()
        return #notes >= 1
    end, 1000)
    vim.wait(100)
    local want = ("live-server: port %d asset_root answered %s; the asset request was answered 404"):format(
        inst.port,
        c[3]
    )
    H.ok(
        #notes == 1 and notes[1].msg == want and notes[1].level == vim.log.levels.WARN,
        ("and warns once, naming the answer: %s"):format(vim.inspect(notes, { newline = " ", indent = "" }))
    )
    server.stop(inst)
end
-- A string root is kept as its real path at start and read again at each
-- request, where a link put at that path after start (the directory
-- moved away) was followed with no word. The string given must still
-- resolve to the path kept; otherwise the request is 404 and the fault
-- is told once, naming the root as given.
for _, c in ipairs({
    { "a link put at the kept path", true },
    { "the kept directory removed", false },
}) do
    local kept = tmpdir .. "/kept"
    vim.fn.mkdir(kept, "p")
    write_file(kept .. "/a.txt", "KEPT")
    vim.fn.mkdir(tmpdir .. "/elsewhere", "p")
    write_file(tmpdir .. "/elsewhere/a.txt", "ELSEWHERE")
    notes = {}
    inst = asset_server(kept)
    local url = ("http://127.0.0.1:%d/__live/asset?p=a.txt&t=%s"):format(inst.port, TOKEN)
    eq(http_get(url).status, 200, "a string root serves its file before " .. c[1])
    assert(uv.fs_rename(kept, tmpdir .. "/kept-moved"))
    local fault, linked, link_err = "does not resolve (ENOENT)", true, nil
    if c[2] then
        linked, link_err = uv.fs_symlink(tmpdir .. "/elsewhere", kept, { dir = true, junction = true })
        fault = ('resolves to "%s"'):format(assert(uv.fs_realpath(tmpdir .. "/elsewhere")))
    end
    local rows = {
        "and after " .. c[1] .. " is 404",
        "and 404 again after " .. c[1],
        "and warns once after " .. c[1] .. ", naming the root as given",
    }
    if linked then
        eq(http_get(url).status, 404, rows[1])
        eq(http_get(url).status, 404, rows[2])
        H.wait_for(function()
            return #notes >= 1
        end, 1000)
        vim.wait(100)
        local want = ('live-server: port %d asset_root "%s" %s since start; the asset request was answered 404'):format(
            inst.port,
            kept,
            fault
        )
        H.ok(
            #notes == 1 and notes[1].msg == want and notes[1].level == vim.log.levels.WARN,
            ("%s: %s"):format(rows[3], vim.inspect(notes, { newline = " ", indent = "" }))
        )
    else
        for _, row in ipairs(rows) do
            H.skip(row .. " (" .. tostring(link_err) .. ")")
        end
    end
    server.stop(inst)
    vim.fn.delete(kept)
    vim.fn.delete(tmpdir .. "/kept-moved", "rf")
    vim.fn.delete(tmpdir .. "/elsewhere", "rf")
end
-- A link given as the root was read through once, at start, and the
-- per-request check read the real path kept then, so a link repointed
-- after start was not seen and the old target served on with no word.
-- The string given is resolved again at each request and must still
-- name the real path kept at start.
do
    local first, second, link = tmpdir .. "/first", tmpdir .. "/second", tmpdir .. "/current"
    vim.fn.mkdir(first, "p")
    vim.fn.mkdir(second, "p")
    write_file(first .. "/a.txt", "FIRST")
    write_file(second .. "/a.txt", "SECOND")
    local rows = {
        "a link given as asset_root serves its target",
        "and once repointed after start is 404",
        "and 404 again",
        "and warns once, naming the link and where it resolves now",
    }
    local made, made_err = uv.fs_symlink(first, link, { dir = true, junction = true })
    if not made then
        for _, row in ipairs(rows) do
            H.skip(row .. " (" .. tostring(made_err) .. ")")
        end
    else
        notes = {}
        inst = asset_server(link)
        local url = ("http://127.0.0.1:%d/__live/asset?p=a.txt&t=%s"):format(inst.port, TOKEN)
        local served = http_get(url)
        eq(served.status == 200 and served.body or served.status, "FIRST", rows[1])
        assert(uv.fs_unlink(link))
        assert(uv.fs_symlink(second, link, { dir = true, junction = true }))
        eq(http_get(url).status, 404, rows[2])
        eq(http_get(url).status, 404, rows[3])
        H.wait_for(function()
            return #notes >= 1
        end, 1000)
        vim.wait(100)
        local want = ('live-server: port %d asset_root "%s" resolves to "%s" since start; the asset request was answered 404'):format(
            inst.port,
            link,
            assert(uv.fs_realpath(second))
        )
        H.ok(
            #notes == 1 and notes[1].msg == want and notes[1].level == vim.log.levels.WARN,
            ("%s: %s"):format(rows[4], vim.inspect(notes, { newline = " ", indent = "" }))
        )
        server.stop(inst)
        vim.fn.delete(link)
    end
end
vim.notify = real_notify

H.finish()
