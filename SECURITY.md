# Security

## Supported versions

The latest release and `main` between releases: a fix lands on `main` and ships in the release after it, never as a patch to an older release. v1.5.0 is the last release that runs on Neovim 0.8 and 0.9 and receives no fixes; `main` and every release after v1.5.0 need Neovim 0.10.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting: <https://github.com/selimacerbas/live-server.nvim/security/advisories/new>. Do not open a public issue for a security problem.

You get a reply within seven days. A confirmed report is fixed in a release and credited in the advisory unless you ask otherwise.

## What the server exposes

live-server serves the directory you point it at, on `127.0.0.1` by default, and `token` is the boundary.

Who can reach it. The loopback bind keeps other machines out, and its Host check answers 421 to a request under any name but `localhost`, a `*.localhost` name, a loopback address or a name `allowed_hosts` lists, which keeps out a page that reaches the port through DNS rebinding; `allowed_hosts = true` turns the check off, and a bind to any other address, `0.0.0.0` included, has none. Neither keeps out a page that addresses a loopback address itself: any page can send the server requests. No bind keeps out another program on this machine, which can read every file the server answers without the token. The server speaks plain HTTP with no TLS, so on a network bind the token and every answer cross the network readable.

Who can read its answers. With `cors = true` or `"*"` any page can read the root route's answers, and with a list or one origin the pages it names can; no `/__live/` route carries a CORS header, so no page reads the event stream's or the asset route's. With `cors = false`, an `Access-Control-Allow-Origin` you set in `headers` is still sent on the root route, so a `"*"` there lets every site read it.

What the root route serves. Every file under the root, but a dot path unless `serve_dotfiles` is set and a file in the `__live` directory at the root (its name read in any letter case), which it never serves; and the file you started on, which is served at `/` even when it is a dot file (a `.draft.html`); with `host = "0.0.0.0"` all of it is reachable by anyone who can reach the port, as the README's Design notes say. The directory listing, on by default, names every file and directory the dot rule leaves visible, the `__live` directory excepted, to anyone who can reach the port, the files `protected_paths` gates included; turn it off (`directory_listing.enabled = false`) where a file's name is itself a secret. An HTML or SVG document the root route serves runs its script in the server's origin, where it can read the token the injected client keeps in `sessionStorage` and request every gated path with it, so serve only documents you trust.

What the asset route serves. `/__live/asset`, which a plugin turns on with `asset_root`, serves any regular file under `asset_root`, which may lie outside the root, dot files included, and a `__live` directory too: the dot rule and `serve_dotfiles` do not apply there. It refuses a list of names (credential files such as `.env` and `id_rsa`, key and certificate files by extension, paths through `.git`, `.ssh`, `.aws` and the like), and that list is no guarantee: a secret under another name is served. It sends an HTML, SVG or XML file with `Content-Security-Policy: sandbox`, so a document there runs no script in the server's origin.

The token. With no `token`, the event stream and the asset route answer anyone who can reach the port; the inject endpoint refuses a browser request from another site and answers the rest, on a loopback bind any program on this machine and on a network bind any peer that sends a browser's same-origin mark, so `token` is the boundary against a peer that is not a browser; with one, they and the paths `protected_paths` names require it, the injected client `/__live/script.js` excepted, and every other file but a dot path stays readable. A `protected_paths` pattern matches the request path and the file's path under the root as the disk spells its name: on a case-insensitive file system, a pattern cased otherwise than the name on disk leaves the file readable without the token, and a hard link to a protected file under another name is not gated. The token also travels beyond the server: the start notice prints the URL that carries it, which `:messages` keeps; the browser is opened with that URL as a command argument, which other accounts on this machine can list; the browser keeps the URL in its history; and every response carries `Referrer-Policy: strict-origin` (or `no-referrer`, when you set that in `headers`), so a Referer names the server's origin at most, which a page's own `<meta name="referrer">` can widen to the whole URL, token included.

Connections. `max_connections` is one pool for every peer, and a connection holds its place until its socket closes: `header_timeout_ms` frees one whose request head never arrives, but a response a peer reads slowly and an event stream hold theirs for as long as the peer keeps them open, so anyone who can reach the port can hold every place without the token and keep a token holder out.

The start probe. On a wildcard bind, `start` refuses when another socket holds the loopback address its own URL names; it checks that address once, at start, and no other, so a program that binds it later takes the requests sent to the URL, token included, and a URL another plugin builds on another address (a LAN address on a `0.0.0.0` bind) is not covered.

A report that shows a way around the token gate or the path containment, a name the loopback Host check admits that this machine does not answer to, or a page on another site that fires events, is in scope.
