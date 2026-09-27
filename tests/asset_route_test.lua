-- tests/asset_route_test.lua
-- Verify the /__live/asset endpoint:
--   - serves files relative to cfg.asset_root (string or function form)
--   - requires ?t=<token> when token auth is configured
--   - rejects traversal (a symlink out of the root too), absolute paths, and schemes
--   - refuses secrets by name (.env, .git, key files) and anything but a file
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
-- Vite's default fs.deny names plus private keys: an image beside a
-- markdown file is served, its secrets are not.
for _, p in ipairs({ ".env", ".env.local", "sub/.git/config", "key.pem", "cert.crt", "id.key", ".ENV" }) do
    eq(http_get(base .. "/__live/asset?p=" .. p .. "&t=" .. TOKEN).status, 404, "p=" .. p .. " is 404")
end
-- realpath returns the spelling on disk, so a case-folding volume hands the
-- check .ENV as .env; a name upper case on disk needs the lowercased read.
eq(http_get(base .. "/__live/asset?p=SERVER.PEM&t=" .. TOKEN).status, 404, "p=SERVER.PEM is 404")
local alias = tmpdir .. "/src/ok.png"
local aliased, alias_err = uv.fs_symlink(".env", alias)
if aliased and uv.fs_stat(alias) then
    eq(http_get(base .. "/__live/asset?p=ok.png&t=" .. TOKEN).status, 404, "an image name linking to .env is 404")
else
    H.skip("an image name linking to .env is 404 (" .. tostring(alias_err or "the link does not resolve") .. ")")
end
-- A deny list, not the root route's dot rule: markdown-preview serves a
-- document's images from a .images directory.
eq(http_get(base .. "/__live/asset?p=.images/pic.png&t=" .. TOKEN).status, 200, "an image under a dot directory is 200")
-- A regular file alone: stream_file opens before it reads the type, and a
-- FIFO blocks that open past SIGTERM, so a FIFO row would hang this suite
-- wherever the check is missing. A directory takes the same check; without
-- it the 404 came from stream_file, whose page named the path on disk.
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
if linked and uv.fs_stat(link) then
    eq(
        http_get(base .. "/__live/asset?p=link.txt&t=" .. TOKEN).status,
        404,
        "a symlink in the asset root pointing above it is 404"
    )
else
    H.skip(
        "a symlink in the asset root pointing above it is 404 ("
            .. tostring(link_err or "the link does not resolve")
            .. ")"
    )
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

H.finish()
