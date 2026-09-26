# Security

## Supported versions

The latest release and `main` between releases. The next release drops Neovim 0.8 and 0.9; from then on v1.5.0 receives no fixes.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting: <https://github.com/selimacerbas/live-server.nvim/security/advisories/new>. Do not open a public issue for a security problem.

You get a reply within seven days. A confirmed report is fixed in a release and credited in the advisory unless you ask otherwise.

## What the server exposes

live-server serves the directory you point it at, on `127.0.0.1` by default, and `token` is the boundary. The loopback bind keeps other machines out; it does not keep out a page open in the same browser, and neither does `cors = false`: any page can send the server requests, and with `cors = true` a page can also read the answers. With `host = "0.0.0.0"` every file under the root is reachable by anyone who can reach the port, as the README's Design notes say. With no `token`, the event stream and the asset route answer anyone who can reach the port, and the inject endpoint answers a request from this server's origin (the README's Design notes say how a browser's request is judged); with one, they and the paths `protected_paths` names require it, and every other file stays readable. A loopback bind answers only loopback names and the names `allowed_hosts` lists, 421 for any other, so a DNS-rebinding page cannot read it; `allowed_hosts = true` turns that off. A report that shows a way around the token gate, the Host check, the inject endpoint's origin check or the path containment is in scope.
