-- The plugin-author API loads this module directly, past both guards that
-- notify: below the floor it refuses at load with the floor module's text
-- (level 0 leaves the position out) rather than at the first use of vim.uv.
-- A failed load leaves require's sentinel behind, which answers a retry with
-- "loop or previous error", so the entry is cleared first and every require
-- reads the text.
local floor = require("live_server.floor")
if not floor.ok then
    package.loaded["live_server.util"] = nil
    error(floor.message, 0)
end

local uv = vim.uv
local U = {}

function U.notify(msg, opts, level)
    if opts and opts.notify == false then
        return
    end
    vim.notify(msg, (level and vim.log.levels[level]) or vim.log.levels.INFO, { title = "live-server.nvim" })
end

function U.joinpath(...)
    local sep = package.config:sub(1, 1)
    return table.concat({ ... }, sep)
end

function U.dirname(p)
    return p:match("^(.*)[/\\]") or "."
end

function U.basename(p)
    return (p:gsub("[/\\]+$", "")):match("([^/\\]+)$") or p
end

function U.find_git_root()
    local cwd = uv.cwd()
    local sep = package.config:sub(1, 1)
    local cur = cwd
    while cur and #cur > 0 do
        local candidate = U.joinpath(cur, ".git")
        if uv.fs_stat(candidate) then
            return cur
        end
        local parent = cur:match(("^(.*)%s[^%s]+$"):format(sep, sep))
        if not parent or parent == cur then
            break
        end
        cur = parent
    end
    return nil
end

function U.url_decode(s)
    s = s:gsub("+", " ")
    s = s:gsub("%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end)
    return s
end

function U.url_encode(s)
    return (
        tostring(s):gsub("([^%w%-%._~])", function(c)
            return string.format("%%%02X", string.byte(c))
        end)
    )
end

-- A hex token from the OS random source alone: vim.uv.random (the
-- platform's CSPRNG, Windows included), then /dev/urandom, else a raise.
-- Never a userland PRNG fallback: math.random is seeded from about 31
-- bits, and reseeding it disturbs every other user of the global
-- generator. 1024 bytes is far above any secret's size and keeps the read
-- and the hex conversion trivial.
function U.random_token(byte_len)
    if byte_len == nil then
        byte_len = 16 -- 32 hex characters, 128 bits; false is no length
    end
    if type(byte_len) ~= "number" or byte_len % 1 ~= 0 or byte_len < 1 or byte_len > 1024 then
        error("random_token: byte_len must be an integer from 1 to 1024", 2)
    end
    local data, rand_err = uv.random(byte_len)
    local dev_err
    if type(data) ~= "string" or #data ~= byte_len then
        data = nil
        local fd
        fd, dev_err = uv.fs_open("/dev/urandom", "r", 384)
        if fd then
            -- On Windows the path names <drive>:\dev\urandom, a file another
            -- local account could plant, so only a character device is read.
            local stat, stat_err = uv.fs_fstat(fd)
            if not stat then
                dev_err = stat_err
            elseif stat.type ~= "char" then
                dev_err = "not a character device"
            else
                local read
                read, dev_err = uv.fs_read(fd, byte_len, 0)
                if type(read) == "string" and #read == byte_len then
                    data = read
                end
            end
            uv.fs_close(fd)
        end
    end
    if not data then
        error(
            ("random_token: no secure random source (vim.uv.random: %s; /dev/urandom: %s)"):format(
                tostring(rand_err or "short read"),
                tostring(dev_err or "short read")
            ),
            2
        )
    end
    return (data:gsub(".", function(c)
        return string.format("%02x", string.byte(c))
    end))
end

-- Constant-time-ish string comparison. Not strictly required at LAN-trust
-- scope (a 128-bit token is infeasible to brute-force regardless), but cheap
-- to do right and avoids handing attackers a trivial timing oracle.
function U.secure_compare(a, b)
    if type(a) ~= "string" or type(b) ~= "string" then
        return false
    end
    if #a ~= #b then
        return false
    end
    local mismatch = 0
    for i = 1, #a do
        if string.byte(a, i) ~= string.byte(b, i) then
            mismatch = mismatch + 1
        end
    end
    return mismatch == 0
end

function U.path_has_prefix(path, prefix)
    local sep = package.config:sub(1, 1)
    if prefix:sub(-1) ~= sep then
        prefix = prefix .. sep
    end
    return path == prefix:sub(1, -2) or path:sub(1, #prefix) == prefix
end

function U.html_escape(s)
    local map = { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&#39;" }
    return (tostring(s):gsub('[&<>"]', map):gsub("'", map["'"]))
end

-- Open URL in default browser (portable)
-- vim.ui.open answers nil and a message when it finds no opener, without
-- raising, so its result is read, not pcall's alone. The platform's opener
-- is tried next, and when that cannot start or exits nonzero the URL, its
-- token's value left out, is shown to open by hand. jobstart raises E475
-- for an opener that is not executable (measured), the Linux case where
-- vim.ui.open found none, so the raise counts as not started.
function U.open_browser(url)
    local ok, handle = pcall(vim.ui.open, url)
    if ok and handle then
        return
    end
    local sys = (jit and jit.os) or uv.os_uname().sysname
    local argv
    if sys == "Windows" or sys == "Windows_NT" then
        argv = { "cmd.exe", "/c", "start", "", url }
    elseif sys == "OSX" or sys == "Darwin" then
        argv = { "open", url }
    else
        argv = { "xdg-open", url }
    end
    -- Shown whatever notify says, so the token's value is left out: a user
    -- who set notify = false keeps it out of :messages, and the start
    -- notice that carries it is the one notify silences.
    local function by_hand()
        local shown = url:gsub("([?&]t=)[^&#]*", "%1...")
        U.notify(("Could not open a browser; open %s by hand"):format(shown), { notify = true }, "WARN")
    end
    vim.schedule(function()
        local started, job = pcall(vim.fn.jobstart, argv, {
            detach = true,
            on_exit = function(_, code)
                if code ~= 0 then
                    by_hand()
                end
            end,
        })
        if not started or job <= 0 then
            by_hand()
        end
    end)
end

-- Telescope presence
local function has_telescope()
    return pcall(require, "telescope")
end

-- Generic list picker
function U.pick_list(opts, cb)
    local title = (opts and opts.title) or "Select"
    local items = (opts and opts.items) or {}
    if has_telescope() then
        local pickers, finders, conf =
            require("telescope.pickers"), require("telescope.finders"), require("telescope.config").values
        local actions, action_state = require("telescope.actions"), require("telescope.actions.state")
        pickers
            .new({}, {
                prompt_title = title,
                finder = finders.new_table({ results = items }),
                sorter = conf.generic_sorter({}),
                attach_mappings = function(prompt_bufnr, _)
                    actions.select_default:replace(function()
                        local entry = action_state.get_selected_entry()
                        actions.close(prompt_bufnr)
                        local val = entry and (entry.value or entry[1] or entry.text)
                        cb(val)
                    end)
                    return true
                end,
            })
            :find()
    else
        vim.ui.select(items, { prompt = title }, cb)
    end
end

-- Directory scanner (simple, bounded depth)
local function scan_dirs(root, maxdepth, limit)
    maxdepth = maxdepth or 3
    limit = limit or 500
    local res, q = {}, { { root, 0 } }
    while #q > 0 and #res < limit do
        local item = table.remove(q, 1)
        local dir, depth = item[1], item[2]
        local it = uv.fs_scandir(dir)
        if it then
            while true do
                local name, t = uv.fs_scandir_next(it)
                if not name then
                    break
                end
                if t == "directory" and name:sub(1, 1) ~= "." then
                    local full = U.joinpath(dir, name)
                    table.insert(res, full)
                    if depth < maxdepth then
                        table.insert(q, { full, depth + 1 })
                    end
                end
            end
        end
    end
    table.sort(res)
    return res
end

-- Path picker (Telescope-first): choose file OR directory
function U.pick_path(cb)
    if has_telescope() then
        local pickers, finders, conf =
            require("telescope.pickers"), require("telescope.finders"), require("telescope.config").values
        local actions, action_state = require("telescope.actions"), require("telescope.actions.state")
        local cwd = uv.cwd()
        local menu = {
            { "📄 Pick a file…", "__PICK_FILE__" },
            { "📁 Pick a directory…", "__PICK_DIR__" },
            { "📌 Current file", "__CUR_FILE__" },
            { "📂 Current directory", "__CUR_DIR__" },
        }
        local git_root = U.find_git_root()
        if git_root then
            table.insert(menu, { "🪵 Git root", "__GIT_ROOT__" })
        end

        pickers
            .new({}, {
                prompt_title = "LiveServer: Choose path",
                finder = finders.new_table({
                    results = menu,
                    entry_maker = function(e)
                        return { value = e[2], display = e[1], ordinal = e[1] }
                    end,
                }),
                sorter = conf.generic_sorter({}),
                attach_mappings = function(prompt_bufnr, _)
                    actions.select_default:replace(function()
                        local entry = action_state.get_selected_entry()
                        actions.close(prompt_bufnr)
                        local tag = entry and entry.value
                        if tag == "__PICK_FILE__" then
                            require("telescope.builtin").find_files({
                                prompt_title = "LiveServer: Pick file",
                                cwd = cwd,
                                attach_mappings = function(pb)
                                    actions.select_default:replace(function()
                                        local e = action_state.get_selected_entry()
                                        actions.close(pb)
                                        cb(e and (e.path or e.filename or e[1]))
                                    end)
                                    return true
                                end,
                            })
                        elseif tag == "__PICK_DIR__" then
                            local dirs = scan_dirs(cwd, 4, 800)
                            if #dirs == 0 then
                                return cb(cwd)
                            end
                            U.pick_list({ title = "Pick directory", items = dirs }, cb)
                        elseif tag == "__CUR_FILE__" then
                            local f = vim.api.nvim_buf_get_name(0)
                            if f == "" then
                                U.notify("No current file.", { notify = true }, "WARN")
                                return
                            end
                            cb(f)
                        elseif tag == "__CUR_DIR__" then
                            cb(cwd)
                        elseif tag == "__GIT_ROOT__" then
                            cb(git_root)
                        end
                    end)
                    return true
                end,
            })
            :find()
    else
        -- Fallback: simple UI
        vim.ui.select(
            { "Pick file", "Pick directory", "Current file", "Current directory" },
            { prompt = "LiveServer: Choose path" },
            function(choice)
                if choice == "Pick file" then
                    vim.ui.input({ prompt = "File path: " }, cb)
                elseif choice == "Pick directory" then
                    vim.ui.input({ prompt = "Directory path: ", default = uv.cwd() }, cb)
                elseif choice == "Current file" then
                    local f = vim.api.nvim_buf_get_name(0)
                    if f == "" then
                        U.notify("No current file.", { notify = true }, "WARN")
                        return
                    end
                    cb(f)
                elseif choice == "Current directory" then
                    cb(uv.cwd())
                end
            end
        )
    end
end

-- Port picker
function U.pick_port(opts, cb)
    local default = tostring((opts and opts.default) or 8000)
    local known = {}
    for _, p in ipairs(opts.known_ports or {}) do
        table.insert(known, tostring(p))
    end
    table.sort(known, function(a, b)
        return tonumber(a) < tonumber(b)
    end)
    local list = {}
    local seen = {}
    for _, p in ipairs(known) do
        table.insert(list, p)
        seen[p] = true
    end
    if not seen[default] then
        table.insert(list, default .. " (default)")
    end
    table.insert(list, "Other…")

    local function finish_with_port(p)
        if not p then
            return cb(nil)
        end
        p = tonumber(tostring(p):match("^(%d+)"))
        if not p or p <= 0 or p > 65535 then
            return U.notify("Invalid port.", { notify = true }, "ERROR")
        end
        cb(p)
    end

    U.pick_list({ title = "Pick Port (default " .. default .. ")", items = list }, function(choice)
        if not choice then
            return cb(nil)
        end
        if choice == "Other…" then
            vim.ui.input({ prompt = "Port: ", default = default }, finish_with_port)
        else
            finish_with_port(choice)
        end
    end)
end

-- The length of the valid UTF-8 sequence at byte i of s, or nil (RFC 3629:
-- no overlong form, no surrogate, nothing past U+10FFFF). The one reader
-- of UTF-8, so every caller refuses the same bytes.
function U.utf8_len(s, i)
    local c = s:byte(i)
    if not c then
        return nil
    end
    if c < 0x80 then
        return 1
    end
    local n, lo, hi = nil, 0x80, 0xBF
    if c >= 0xC2 and c <= 0xDF then
        n = 2
    elseif c >= 0xE0 and c <= 0xEF then
        n = 3
        lo = c == 0xE0 and 0xA0 or lo
        hi = c == 0xED and 0x9F or hi
    elseif c >= 0xF0 and c <= 0xF4 then
        n = 4
        lo = c == 0xF0 and 0x90 or lo
        hi = c == 0xF4 and 0x8F or hi
    else
        return nil
    end
    local second = s:byte(i + 1)
    if not second or second < lo or second > hi then
        return nil
    end
    for k = i + 2, i + n - 1 do
        local b = s:byte(k)
        if not b or b < 0x80 or b > 0xBF then
            return nil
        end
    end
    return n
end

-- .liveignore parser
function U.parse_liveignore(root)
    local path = U.joinpath(root, ".liveignore")
    local fd = uv.fs_open(path, "r", 438)
    if not fd then
        return {}
    end
    local stat = uv.fs_fstat(fd)
    if not stat then
        uv.fs_close(fd)
        return {}
    end
    local content = uv.fs_read(fd, stat.size, 0)
    uv.fs_close(fd)
    if not content then
        return {}
    end
    local patterns = {}
    for line in content:gmatch("[^\r\n]+") do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" and line:sub(1, 1) ~= "#" then
            -- Every pattern character is escaped: an unescaped bracket raised
            -- inside the watcher once its literal prefix matched a path, and an
            -- unescaped question mark made the character before it optional,
            -- so a line a?b dropped every path holding a b.
            local pat = line:gsub("([%.%+%-%^%$%(%)%%%[%]%?])", "%%%1"):gsub("%*", ".*")
            -- The path is matched with a leading slash (schedule_reload), so
            -- a line starting with one is anchored at the root.
            if pat:sub(1, 1) == "/" then
                pat = "^" .. pat
            end
            table.insert(patterns, pat)
        end
    end
    return patterns
end

function U.match_ignore(path, patterns)
    for _, pat in ipairs(patterns) do
        if path:find(pat) then
            return true
        end
    end
    return false
end

return U
