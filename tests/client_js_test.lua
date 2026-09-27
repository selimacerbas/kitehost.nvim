-- tests/client_js_test.lua
-- The reload client. A token server gates its event stream, and the
-- client opened it without the token, got 401 and never reconnected, so
-- live reload died in the README's network setup. The token client's
-- behaviour runs in node against stubs of the page around it: a page whose
-- own URL uses t keeps the working token, a refused query value gives way
-- to the kept token, and a page with no token is told why.
--
-- Run: nvim --headless -u NONE -l "$PWD/tests/client_js_test.lua"

local H = dofile(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "helpers.lua"))
H.isolate()
H.rtp()

local server = require("live_server.server")
local eq, ok = H.eq, H.ok

local root = H.tmpdir()
H.write_file(root .. "/index.html", "<html><body>ok</body></html>")

local function script(cfg)
    local inst = server.start(vim.tbl_extend("keep", cfg or {}, {
        port = 0,
        root = root,
        live = { enabled = false, inject_script = true },
        features = { dirlist = { enabled = false } },
    }))
    H.defer(function()
        server.stop(inst)
    end)
    return H.http_get(("http://127.0.0.1:%d/__live/script.js"):format(inst.port))
end

H.case("Section 1: a tokenless server's client is the one it always served", function()
    local r = script()
    eq(r.status, 200, "the client is served")
    eq(#r.body, 576, "576 bytes, as v1.5.0 served")
    eq(
        vim.fn.sha256(r.body),
        "376cf1554a8830f105cc712512d33e040427288a9c94b9bcb19707627c3023b6",
        "the same bytes as v1.5.0 served"
    )
end)

local HINT = "[live-server.nvim] no token: open the page with ?t=<token> in its URL"

H.case("Section 2: a token server's client carries the page's token to the stream", function()
    local r = script({ token = "tok123" })
    eq(r.status, 200, "the client is served without the token")
    -- Substrings alone passed a client with a syntax error, which dies on
    -- every token server, so its bytes are pinned as the tokenless one's
    -- are; the rows after the pin say what those bytes must hold.
    eq(#r.body, 1151, "1151 bytes, pinned as the tokenless client is")
    eq(vim.fn.sha256(r.body), "2598b033c04af41760bda5643243d383cf313649f77f72710002a0a6b567e28d", "and by its sha256")
    ok(r.body:find("location.search", 1, true) ~= nil, "it reads t from the page's query")
    ok(r.body:find("sessionStorage", 1, true) ~= nil, "and keeps it for reloads that drop the query")
    ok(
        r.body:find("'/__live/events'+(t?'?t='+encodeURIComponent(t):'')", 1, true) ~= nil,
        "and puts it on the event stream"
    )
    ok(
        r.body:find("no token: open the page with ?t=<token> in its URL", 1, true) ~= nil
            and not r.body:find("printed", 1, true),
        "a page with no token is told where it goes, naming no printed URL"
    )
    ok(not r.body:find("localStorage", 1, true), "the token is never kept in localStorage, which outlives the tab")
    ok(not r.body:find("tok123", 1, true), "the token itself is never in the script")
end)

-- The served client runs as a page would run it: location, sessionStorage,
-- EventSource and console are stubs, and each page drives its streams'
-- open and error events by hand. Every page prints what it saw, and the
-- rows below rule on it.
local RUNNER = [==[
'use strict';
const src = require('fs').readFileSync(process.argv[2], 'utf8');
const K = 'live-server.nvim:t';
function page(search, store, throws) {
  const warns = [], streams = [];
  const sessionStorage = {
    getItem(k) { if (throws) throw new Error(throws); return Object.hasOwn(store, k) ? store[k] : null; },
    setItem(k, v) { if (throws) throw new Error(throws); store[k] = String(v); },
  };
  class EventSource {
    constructor(url) { this.url = url; this.readyState = 0; this.on = {}; streams.push(this); }
    addEventListener(type, fn) { (this.on[type] = this.on[type] || []).push(fn); }
    close() { this.readyState = 2; }
  }
  const console = { log() {}, warn(...a) { warns.push(a.map(String).join(' ')); } };
  const location = { search, reload() {} };
  new Function('location', 'sessionStorage', 'EventSource', 'console', 'URLSearchParams', 'document', src)(
    location, sessionStorage, EventSource, console, URLSearchParams, {});
  const fire = (i, type, state) => {
    const es = streams[i];
    es.readyState = state;
    (es.on[type] || []).forEach((f) => f({}));
    if (es['on' + type]) es['on' + type]({});
  };
  const urls = () => streams.map((es) => es.url);
  const kept = () => (Object.hasOwn(store, K) ? store[K] : null);
  return { warns, streams, fire, urls, kept };
}
const pages = {
  foreign() {
    const p = page('?t=30', { [K]: 'REAL' });
    p.fire(0, 'error', 2);
    const reload = p.streams[1] ? (p.streams[1].on.reload || []).length : 0;
    if (p.streams[1]) p.fire(1, 'open', 1);
    return { urls: p.urls(), kept: p.kept(), reload };
  },
  fresh() {
    const p = page('?t=REAL', {});
    const before = p.kept();
    p.fire(0, 'open', 1);
    return { urls: p.urls(), before, kept: p.kept(), warns: p.warns };
  },
  refused() {
    const p = page('?t=30', {});
    p.fire(0, 'error', 2);
    return { urls: p.urls(), kept: p.kept() };
  },
  once() {
    const p = page('?t=30', { [K]: 'OLD' });
    p.fire(0, 'error', 2);
    if (p.streams[1]) p.fire(1, 'error', 2);
    return { urls: p.urls(), kept: p.kept() };
  },
  stale() {
    const p = page('?t=NEW', { [K]: 'OLD' });
    p.fire(0, 'open', 1);
    return { urls: p.urls(), kept: p.kept() };
  },
  connecting() {
    const p = page('?t=30', { [K]: 'REAL' });
    p.fire(0, 'error', 0);
    return { urls: p.urls(), kept: p.kept() };
  },
  kept() {
    const p = page('', { [K]: 'REAL' });
    return { urls: p.urls(), warns: p.warns };
  },
  hint() {
    const p = page('', {});
    return { urls: p.urls(), warns: p.warns };
  },
  blocked() {
    const p = page('', {}, 'SecurityError: storage refused');
    return { urls: p.urls(), warns: p.warns };
  },
  blocked_open() {
    const p = page('?t=REAL', {}, 'SecurityError: storage refused');
    const early = p.warns.length;
    p.fire(0, 'open', 1);
    return { urls: p.urls(), early, warns: p.warns };
  },
};
const out = {};
for (const [name, run] of Object.entries(pages)) {
  try { out[name] = run(); } catch (e) { out[name] = { raised: String(e && e.stack || e) }; }
}
process.stdout.write(JSON.stringify(out));
]==]

-- Runs the token client's pages in node and returns what each one saw, or
-- nil and why the run gave nothing to rule on.
local function run_pages(body)
    if vim.fn.executable("node") ~= 1 then
        return nil, "node runs these rows and is not on PATH"
    end
    local dir = H.tmpdir()
    H.write_file(dir .. "/client.js", body)
    H.write_file(dir .. "/run.cjs", RUNNER)
    local res = vim.system({ "node", dir .. "/run.cjs", dir .. "/client.js" }, { text = true, timeout = 10000 }):wait()
    local code = H.exit_code(res)
    if code ~= 0 then
        return nil, ("node exited %d: %s"):format(code, (res.stderr or ""):sub(1, 400))
    end
    local read, pages = pcall(vim.json.decode, res.stdout or "")
    if not read or type(pages) ~= "table" then
        return nil, "node printed no result: " .. (res.stdout or ""):sub(1, 200)
    end
    return pages
end

local EVENTS = "/__live/events"

H.case("Section 3: a page's own t never replaces a working token", function()
    local r = script({ token = "REAL" })
    local pages, why = run_pages(r.body)
    ok(pages ~= nil, "the client's pages ran: " .. tostring(why or "yes"))
    pages = pages or {}
    local function seen(name)
        local p = pages[name] or {}
        ok(p.raised == nil, name .. " ran: " .. tostring(p.raised or "no raise"))
        return p
    end
    local function urls(p)
        return table.concat(p.urls or {}, " ")
    end

    -- An application parameter named t (a time, a tab) replaced the kept
    -- token, and every later page in the tab opened its stream with it and
    -- got 401 with no word.
    local p = seen("foreign")
    eq(
        urls(p),
        EVENTS .. "?t=30 " .. EVENTS .. "?t=REAL",
        "a page at ?t=30 tries 30, and once the stream is closed, the kept token"
    )
    eq(p.kept, "REAL", "the kept token is still the real one after both streams")
    eq(p.reload, 1, "the second stream reloads the page as the first would")

    p = seen("fresh")
    eq(urls(p), EVENTS .. "?t=REAL", "a page at ?t=<token> opens the stream with it")
    eq(p.before, vim.NIL, "and keeps nothing before the stream opens")
    eq(p.kept, "REAL", "then keeps it once the stream opens")
    eq(#(p.warns or { "unread" }), 0, "and warns of nothing")

    p = seen("stale")
    eq(p.kept, "NEW", "a query value the stream opens with replaces a stale kept token")

    p = seen("refused")
    eq(urls(p), EVENTS .. "?t=30", "a refused query value with nothing kept opens no second stream")
    eq(p.kept, vim.NIL, "and is never kept")

    p = seen("once")
    eq(urls(p), EVENTS .. "?t=30 " .. EVENTS .. "?t=OLD", "the kept token is tried once, never a third stream")
    eq(p.kept, "OLD", "and a refused query value is not kept after it")

    -- A stream still connecting reports an error on a network blip and
    -- retries itself; only a stream the server closed is given the kept one.
    p = seen("connecting")
    eq(urls(p), EVENTS .. "?t=30", "an error while the stream reconnects opens no second stream")

    p = seen("kept")
    eq(urls(p), EVENTS .. "?t=REAL", "a page with no t opens the stream with the kept token")
    eq(#(p.warns or { "unread" }), 0, "and warns of nothing")
end)

-- The hint named "the URL the server printed", which a server.start caller
-- never prints, and a storage error was dropped, so a user who had opened
-- the page with its token was told to open it again.
H.case("Section 4: a page with no token is told why", function()
    local r = script({ token = "REAL" })
    local pages, why = run_pages(r.body)
    ok(pages ~= nil, "the client's pages ran: " .. tostring(why or "yes"))
    pages = pages or {}
    local p = pages.hint or {}
    eq(table.concat(p.warns or {}, " | "), HINT, "no t and nothing kept: the hint alone")
    eq(table.concat(p.urls or {}, " "), EVENTS, "and the stream opens without a token, which says 401")

    p = pages.blocked or {}
    local warned = table.concat(p.warns or {}, " | ")
    ok(
        warned:find("the token could not be kept", 1, true) ~= nil
            and warned:find("SecurityError: storage refused", 1, true) ~= nil,
        "storage that throws with no t is named as the cause, with its error: " .. warned
    )
    ok(not warned:find("open the page", 1, true), "and no hint to open the page again is given")

    p = pages.blocked_open or {}
    warned = table.concat(p.warns or {}, " | ")
    eq(p.early, 0, "a page at ?t=<token> whose storage throws warns of nothing before the stream opens")
    ok(
        warned:find("the token could not be kept", 1, true) ~= nil
            and warned:find("SecurityError: storage refused", 1, true) ~= nil,
        "and says the token could not be kept once it opens: " .. warned
    )
end)

H.finish()
