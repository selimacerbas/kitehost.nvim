-- tests/client_js_test.lua
-- The reload client. A token server gates its event stream, and the
-- client opened it without the token, got 401 and never reconnected, so
-- live reload died in the README's network setup. The token client's
-- behaviour runs in node against stubs of the page around it: the tab
-- keeps the token it was given, a page whose own URL uses t never replaces
-- it, a refused token is tried once and named, and a page with no token
-- waits for one and is told why.
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
    eq(#r.body, 1393, "1393 bytes, pinned as the tokenless client is")
    eq(vim.fn.sha256(r.body), "c231d968b9fe4b91ea71bec429fc2d9a7ad80b12b0dda282b834d60ada4e8ae4", "and by its sha256")
    ok(r.body:find("location.search", 1, true) ~= nil, "it reads t from the page's query")
    ok(r.body:find("sessionStorage", 1, true) ~= nil, "and keeps it for reloads that drop the query")
    ok(r.body:find("'/__live/events?t='+encodeURIComponent(t)", 1, true) ~= nil, "and puts it on the event stream")
    ok(
        r.body:find("no token: open the page with ?t=<token> in its URL", 1, true) ~= nil
            and not r.body:find("printed", 1, true),
        "a page with no token is told where it goes, naming no printed URL"
    )
    ok(not r.body:find("localStorage", 1, true), "the token is never kept in localStorage, which outlives the tab")
    ok(not r.body:find("tok123", 1, true), "the token itself is never in the script")
end)

-- The served client runs as a page would run it: location, sessionStorage,
-- EventSource, console, the window's addEventListener and setTimeout are
-- stubs, and each page drives its streams' open and error events and its
-- clock by hand. The pages of one tab share one store, and a write there
-- queues a storage event for every other document of the tab, delivered
-- when the tab is flushed, as a browser delivers it once the writing
-- script has run. Every page prints what it saw, and the rows below rule
-- on it.
local RUNNER = [==[
'use strict';
const src = require('fs').readFileSync(process.argv[2], 'utf8');
const K = 'live-server.nvim:t';
const has = (o, k) => Object.prototype.hasOwnProperty.call(o, k);
function tab(store) {
  const t = { store: store || {}, docs: [], queue: [] };
  t.flush = () => { while (t.queue.length) t.queue.shift()(); };
  return t;
}
function page(search, where, throws) {
  const t = where && where.docs ? where : tab(where);
  const store = t.store;
  const warns = [], streams = [], timers = [], on = {};
  let clock = 0;
  t.docs.push(on);
  const sessionStorage = {
    getItem(k) { if (throws) throw new Error(throws); return has(store, k) ? store[k] : null; },
    setItem(k, v) {
      if (throws) throw new Error(throws);
      const old = has(store, k) ? store[k] : null;
      store[k] = String(v);
      if (old === store[k]) return;
      const e = { key: k, oldValue: old, newValue: store[k] };
      t.docs.forEach((d) => { if (d !== on) t.queue.push(() => (d.storage || []).forEach((f) => f(e))); });
    },
  };
  const addEventListener = (type, fn) => { (on[type] = on[type] || []).push(fn); };
  const setTimeout = (fn, ms) => { timers.push({ fn, at: clock + ms }); };
  const tick = (ms) => {
    clock += ms;
    timers.filter((x) => !x.done && x.at <= clock).forEach((x) => { x.done = true; x.fn(); });
  };
  class EventSource {
    constructor(url) { this.url = url; this.readyState = 0; this.on = {}; streams.push(this); }
    addEventListener(type, fn) { (this.on[type] = this.on[type] || []).push(fn); }
  }
  const console = { log() {}, warn(...a) { warns.push(a.map(String).join(' ')); } };
  const location = { search };
  new Function('location', 'sessionStorage', 'EventSource', 'console', 'URLSearchParams', 'document',
    'addEventListener', 'setTimeout', src)(
    location, sessionStorage, EventSource, console, URLSearchParams, {}, addEventListener, setTimeout);
  const fire = (i, type, state) => {
    const es = streams[i];
    es.readyState = state;
    (es.on[type] || []).forEach((f) => f({}));
    if (es['on' + type]) es['on' + type]({});
  };
  // Every stream the server closes, the ones its errors open included,
  // bounded so a client that never stops shows as a count, not a hang.
  const refuse = () => { for (let i = 0; i < 5 && streams[i]; i++) fire(i, 'error', 2); };
  const urls = () => streams.map((es) => es.url);
  const kept = () => (has(store, K) ? store[K] : null);
  return { warns, streams, fire, refuse, urls, kept, tick };
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
  left() {
    const t = tab();
    const first = page('?t=REAL', t);
    const next = page('', t);
    next.tick(2000);
    return { first: first.urls(), urls: next.urls(), warns: next.warns };
  },
  arrives() {
    const t = tab();
    const frame = page('', t);
    const early = frame.urls().length;
    page('?t=REAL', t);
    t.flush();
    frame.tick(2000);
    const later = page('?t=NEW', t);
    later.fire(0, 'open', 1);
    t.flush();
    return { early, urls: frame.urls(), warns: frame.warns, kept: later.kept() };
  },
  refused() {
    const p = page('?t=30', {});
    p.refuse();
    return { urls: p.urls(), warns: p.warns };
  },
  same() {
    const p = page('?t=OLD', { [K]: 'OLD' });
    p.refuse();
    return { urls: p.urls(), warns: p.warns };
  },
  once() {
    const p = page('?t=30', { [K]: 'OLD' });
    p.refuse();
    return { urls: p.urls(), kept: p.kept(), warns: p.warns };
  },
  restart() {
    const p = page('', { [K]: 'OLD' });
    p.refuse();
    return { urls: p.urls(), warns: p.warns };
  },
  stale() {
    const p = page('?t=NEW', { [K]: 'OLD' });
    const before = p.kept();
    p.fire(0, 'open', 1);
    return { urls: p.urls(), before, kept: p.kept() };
  },
  connecting() {
    const p = page('?t=30', { [K]: 'REAL' });
    p.fire(0, 'error', 0);
    return { urls: p.urls(), kept: p.kept(), warns: p.warns };
  },
  kept() {
    const p = page('', { [K]: 'REAL' });
    return { urls: p.urls(), warns: p.warns };
  },
  hint() {
    const p = page('', {});
    p.tick(1999);
    const early = p.warns.slice();
    p.tick(1);
    p.tick(5000);
    return { urls: p.urls(), early, warns: p.warns };
  },
  blocked() {
    const p = page('', {}, 'SecurityError: storage refused');
    p.tick(2000);
    return { urls: p.urls(), warns: p.warns };
  },
  blocked_open() {
    const p = page('?t=REAL', {}, 'SecurityError: storage refused');
    p.fire(0, 'open', 1);
    return { urls: p.urls(), warns: p.warns };
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

-- One node run over a token server's client, read by both sections below.
local token_run
local function token_pages()
    if not token_run then
        token_run = { run_pages(script({ token = "REAL" }).body) }
    end
    return token_run[1], token_run[2]
end

local EVENTS = "/__live/events"
local REFUSED = "[live-server.nvim] the token was refused: open the page with the server's ?t=<token>"

-- Every page of the node run, each checked for a raise, its stream URLs as
-- one line, and its own warnings: the SSE error line every closed stream
-- logs is the tokenless client's too, so the rows rule on the others.
local function reader()
    local pages, why = token_pages()
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
    local function warned(p)
        local own = {}
        for _, line in ipairs(p.warns or { "unread" }) do
            if not vim.startswith(line, "[live-server.nvim] SSE error") then
                table.insert(own, line)
            end
        end
        return table.concat(own, " | "), #own
    end
    return seen, urls, warned
end

H.case("Section 3: the tab keeps the token it was given, never a page's own t", function()
    local seen, urls, warned = reader()

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

    p = seen("stale")
    eq(p.before, "OLD", "a query value that differs from a kept token leaves it kept until its stream opens")
    eq(p.kept, "NEW", "and replaces it once the stream opens with it")

    -- Kept only once its stream opened, the token was lost by a page that
    -- left first (a meta refresh index) and was missing for an iframe or
    -- the next page read before that; with nothing kept there is no token
    -- to lose.
    p = seen("fresh")
    eq(urls(p), EVENTS .. "?t=REAL", "a page at ?t=<token> opens the stream with it")
    eq(p.before, "REAL", "and keeps it at once when the tab holds none")
    eq(p.kept, "REAL", "still kept once the stream opens")
    eq(warned(p), "", "and warns of nothing")

    p = seen("left")
    eq(urls(p), EVENTS .. "?t=REAL", "a page left before its stream opened: the tab's next page opens with its token")
    eq(warned(p), "", "and warns of nothing")

    p = seen("arrives")
    eq(p.early, 0, "a document with nothing to read opens no stream yet")
    eq(urls(p), EVENTS .. "?t=REAL", "and opens it with the token another document of the tab keeps")
    eq(warned(p), "", "and prints no hint")
    eq(p.kept, "NEW", "a later page's token replaces the kept one")
    eq(#(p.urls or {}), 1, "and opens no second stream in a document already connected")

    -- A stream still connecting reports an error on a network blip and
    -- retries itself; only a stream the server closed is given the kept one.
    p = seen("connecting")
    eq(urls(p), EVENTS .. "?t=30", "an error while the stream reconnects opens no second stream")
    eq(warned(p), "", "and warns of nothing")

    p = seen("kept")
    eq(urls(p), EVENTS .. "?t=REAL", "a page with no t opens the stream with the kept token")
    eq(warned(p), "", "and warns of nothing")
end)

-- A refused token ended in the SSE error line alone: a tab reopened at its
-- old ?t= after a restart with a new token, or a page whose own t the
-- server refused, was never told why. A refused query value equal to the
-- kept token has nothing to give way to, and a retry with it looped.
H.case("Section 4: a refused token is tried once, never a third stream, and is named", function()
    local seen, urls, warned = reader()
    local p = seen("once")
    eq(urls(p), EVENTS .. "?t=30 " .. EVENTS .. "?t=OLD", "the kept token is tried once, never a third stream")
    eq(p.kept, "OLD", "and a refused query value is not kept after it")
    eq(warned(p), REFUSED, "then the refusal is named once")

    p = seen("same")
    eq(urls(p), EVENTS .. "?t=OLD", "a refused query value equal to the kept token opens exactly one stream")
    eq(warned(p), REFUSED, "then the refusal is named once")

    p = seen("refused")
    eq(urls(p), EVENTS .. "?t=30", "a refused query value with nothing else kept opens no second stream")
    eq(warned(p), REFUSED, "then the refusal is named once")

    p = seen("restart")
    eq(urls(p), EVENTS .. "?t=OLD", "a refused kept token opens no second stream")
    eq(warned(p), REFUSED, "then the refusal is named once")
end)

-- The hint named "the URL the server printed", which a server.start caller
-- never prints, and a storage error was dropped, so a user who had opened
-- the page with its token was told to open it again. A document that runs
-- before another in the tab keeps the token waits for it, so the hint
-- waits too.
H.case("Section 5: a page with no token is told why", function()
    local seen, urls, warned = reader()
    local p = seen("hint")
    eq(urls(p), "", "no t and nothing kept: no stream opens without a token")
    eq(table.concat(p.early or { "unread" }, " | "), "", "and no hint before two seconds")
    eq(warned(p), HINT, "then the hint, once")

    p = seen("blocked")
    local said = warned(p)
    ok(
        said:find("the token could not be kept", 1, true) ~= nil
            and said:find("SecurityError: storage refused", 1, true) ~= nil,
        "storage that throws with no t is named as the cause, with its error: " .. said
    )
    ok(not said:find("open the page", 1, true), "and no hint to open the page again is given")
    eq(select(2, warned(p)), 1, "once")

    p = seen("blocked_open")
    said = warned(p)
    eq(urls(p), EVENTS .. "?t=REAL", "a page at ?t=<token> whose storage throws opens the stream with it")
    ok(
        said:find("the token could not be kept", 1, true) ~= nil
            and said:find("SecurityError: storage refused", 1, true) ~= nil,
        "and says the token could not be kept, with the error: " .. said
    )
    eq(select(2, warned(p)), 1, "once, the stream's open included")
end)

H.finish()
