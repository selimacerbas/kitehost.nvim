#!/bin/sh
# The refusal a Neovim below the floor meets, run on such a Neovim (CI's
# floor-below job runs 0.9.5; locally, put one first on PATH). The suites
# cannot run there (the helper needs 0.10), and floor_guard mocks has() on a
# supported Neovim, which passes a 0.10 API reached before a guard that a
# real 0.9.5 raises on (measured); no helper is loaded here for that reason.
#
# The plugin file is sourced as Neovim's own loading sources it (:runtime),
# and the check then reads what the user meets: the floor text once in
# :messages and no traceback, every command the README's tables document
# defined and answering each use with the text again, bare and with each
# subcommand its rows name, setup() returning, a stub field answering an
# empty string, each submodule that requires the floor module raising its
# text on every require (the README promises it to a plugin that loads
# one), and no module but the entry and floor modules loaded, kitehost's
# included. Through 2.x a submodule's former name, a file that hands the
# module back, raises as the module does. A checkout that is not kitehost
# finds it as the suites do (KITEHOST_RTP, else LIVE_SERVER_RTP, its name
# before 2.0.0; then ./kitehost-rtp, ../kitehost.nvim and
# ../live-server.nvim; a set value that is not a directory, or none found,
# fails), since a plugin that loads kitehost below the floor would get
# through where kitehost is not on the runtimepath. The XDG directories
# point at a private directory, as tests/run.sh does, so a start package
# cannot answer for the checkout.
set -u
cd "$(dirname "$0")/.." || exit 1
set -- plugin/*.lua
if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
    echo "floor_smoke: expected one plugin/*.lua, found: $*" >&2
    exit 1
fi
plugin_file=$1
set -- lua/*/init.lua
if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
    echo "floor_smoke: expected one lua/<module>/init.lua, found: $*" >&2
    exit 1
fi
module=${1#lua/}
module=${module%/init.lua}
# The backticks are the README's Markdown, matched literally. A row whose
# second column names a subcommand gives "Name sub", any other row "Name";
# the entries are comma-separated, since one holds a space.
# shellcheck disable=SC2016
commands=$(sed -n -e 's/^| `:\([A-Za-z0-9_]*\)` | `\([a-z][a-z-]*\)`.*/\1 \2/p' -e t \
    -e 's/^| `:\([A-Za-z0-9_]*\)`.*/\1/p' README.md | tr '\n' ',')
if [ -z "$commands" ]; then
    echo "floor_smoke: README.md's command table lists no command" >&2
    exit 1
fi
# The floor module is the one statement of the floor: its text and its
# verdict are read from it, never restated here.
guarded=
for f in lua/"$module"/*.lua; do
    name=${f##*/}
    name=${name%.lua}
    case $name in init | floor) continue ;; esac
    if grep -qF "require(\"$module.floor\")" "$f"; then
        guarded="$guarded $module.$name"
    fi
done
# A file under another lua/ directory that requires a guarded module is
# that module's former name (lua/live_server/server.lua through 2.x).
for f in lua/*/*.lua; do
    [ -f "$f" ] || continue
    case $f in lua/"$module"/*) continue ;; esac
    dir=${f#lua/}
    dir=${dir%%/*}
    name=${f##*/}
    name=${name%.lua}
    for g in $guarded; do
        if grep -qF "require(\"$g\")" "$f"; then
            guarded="$guarded $dir.$name"
            break
        fi
    done
done
rtp=$PWD
if [ ! -d lua/kitehost ]; then
    dep=
    # KITEHOST_RTP first; LIVE_SERVER_RTP, its name before 2.0.0, through
    # 2.x when it is unset.
    var=
    if [ -n "${KITEHOST_RTP:-}" ]; then
        var=KITEHOST_RTP
        dep=$KITEHOST_RTP
    elif [ -n "${LIVE_SERVER_RTP:-}" ]; then
        var=LIVE_SERVER_RTP
        dep=$LIVE_SERVER_RTP
    fi
    if [ -n "$var" ]; then
        if [ ! -d "$dep" ]; then
            echo "floor_smoke: $var is set but is not a directory: $dep" >&2
            exit 1
        fi
    elif [ -d kitehost-rtp ]; then
        dep=kitehost-rtp
    elif [ -d ../kitehost.nvim ]; then
        dep=../kitehost.nvim
    elif [ -d ../live-server.nvim ]; then
        dep=../live-server.nvim
    else
        echo "floor_smoke: kitehost.nvim not found: set KITEHOST_RTP, or clone it to ./kitehost-rtp or ../kitehost.nvim" >&2
        exit 1
    fi
    case $dep in /*) ;; *) dep=$PWD/$dep ;; esac
    echo "kitehost.nvim: $dep"
    rtp="$rtp,$dep"
fi
run=$(mktemp -d) || exit 1
trap 'rm -rf "$run"' EXIT
# dash ends on HUP, INT or TERM without the EXIT trap (measured), so each
# signal cleans up and is raised again, and the caller stops at once too.
trap 'rm -rf "$run"; trap - HUP; kill -HUP $$' HUP
trap 'rm -rf "$run"; trap - INT; kill -INT $$' INT
trap 'rm -rf "$run"; trap - TERM; kill -TERM $$' TERM
cat >"$run/check.lua" <<'LUA'
local module = os.getenv("SMOKE_MODULE")
local fails = 0
-- An error message holds its line open until the next message begins, so an
-- empty echo ends it before a line of this check starts.
local function check(cond, what)
    pcall(vim.api.nvim_echo, { { "" } }, false, {})
    io.stdout:write((cond and "ok: " or "FAIL: ") .. what .. "\n")
    if not cond then
        fails = fails + 1
    end
end
local function turn_loop()
    vim.wait(200, function()
        return false
    end)
end
local found, floor = pcall(require, module .. ".floor")
local message = found and type(floor) == "table" and floor.message or nil
check(type(message) == "string" and message ~= "", "the floor module states the floor: " .. tostring(message))
message = message or "(no floor text)"
local function shown()
    local log, count, from = vim.fn.execute("messages"), 0, 1
    while true do
        local _, stop = log:find(message, from, true)
        if not stop then
            return count, log
        end
        count, from = count + 1, stop + 1
    end
end
-- On a supported Neovim the commands are the real ones, and one waits for
-- input, so the check stops here.
if not (found and type(floor) == "table" and floor.ok == false) then
    check(false, "this Neovim is below the floor: the floor module reads it as supported")
    vim.cmd("cq 1")
end
turn_loop()
check(shown() == 1, "loading the plugin shows the floor text once (" .. shown() .. ")")
-- Each command is used bare once and once with each subcommand its rows
-- name, so a refuser that takes no argument raises on a subcommand.
local uses, seen = {}, {}
for entry in os.getenv("SMOKE_COMMANDS"):gmatch("[^,]+") do
    local name = entry:match("^%S+")
    if not seen[name] then
        seen[name] = true
        uses[#uses + 1] = name
        check(vim.fn.exists(":" .. name) == 2, ":" .. name .. " is defined")
    end
    if entry ~= name then
        uses[#uses + 1] = entry
    end
end
for i, use in ipairs(uses) do
    local ran, err = pcall(vim.cmd, use)
    check(ran, ":" .. use .. " runs without raising" .. (ran and "" or (": " .. tostring(err))))
    turn_loop()
    check(shown() == i + 1, "a use of :" .. use .. " shows the floor text again (" .. shown() .. ")")
end
local set_up, set_err = pcall(function()
    return require(module).setup({})
end)
check(set_up, "setup() returns" .. (set_up and "" or (": " .. tostring(set_err))))
local field_ok, field = pcall(function()
    return require(module).statusline()
end)
check(field_ok and field == "", "a stub field answers an empty string: " .. tostring(field))
for name in os.getenv("SMOKE_GUARDED"):gmatch("%S+") do
    for _, when in ipairs({ "at load", "again" }) do
        local req_ok, req_err = pcall(require, name)
        check(
            not req_ok and req_err == message,
            ("require(%q) raises the floor text %s"):format(name, when)
                .. (req_ok and ": it loaded" or (req_err == message and "" or (": " .. tostring(req_err))))
        )
    end
end
turn_loop()
-- This plugin's modules and the server's, each by its name and, through
-- 2.x, its former one.
local prefixes = { module, "kitehost", "live_server", "mdkite", "markdown_preview" }
local loaded = {}
for name in pairs(package.loaded) do
    local watched = false
    for _, prefix in ipairs(prefixes) do
        watched = watched or name == prefix or name:sub(1, #prefix + 1) == prefix .. "."
    end
    if watched and name ~= module and name ~= module .. ".floor" then
        loaded[#loaded + 1] = name
    end
end
check(#loaded == 0, "no module past the entry and the floor module loaded: " .. table.concat(loaded, ", "))
local count, log = shown()
check(count == #uses + 1, "setup() adds no further notification (" .. count .. ")")
check(not log:find("traceback", 1, true), "no traceback in :messages")
io.stdout:write("floor smoke: " .. (fails == 0 and "pass" or (fails .. " failed")) .. "\n")
io.stdout:flush()
vim.cmd(fails == 0 and "qa!" or "cq 1")
LUA
XDG_CONFIG_HOME=$run/config XDG_DATA_HOME=$run/data XDG_STATE_HOME=$run/state XDG_CACHE_HOME=$run/cache \
    SMOKE_RTP=$rtp SMOKE_MODULE=$module SMOKE_COMMANDS=$commands SMOKE_GUARDED=$guarded \
    nvim --headless -u NONE \
    --cmd 'lua vim.o.runtimepath = os.getenv("SMOKE_RTP") .. "," .. vim.o.runtimepath' \
    -c "runtime $plugin_file" \
    -c "luafile $run/check.lua" \
    -c 'cq 2'
