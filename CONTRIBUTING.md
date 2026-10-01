# Contributing

Issues and PRs are welcome. This file names the commands the CI runs so a green PR is a local run away: `make test`, `make fmt-check`, `make lint-text`, `make lint-blame` and `make shellcheck` (the POSIX scripts and hooks read as sh, which the `lint-workflows` job runs with the actionlint image's shellcheck) run here as they run in CI. The `lint-workflows` job also runs actionlint, which no make target wraps: run `actionlint .github/workflows/*.yml` locally (`brew install actionlint`, whose formula brings shellcheck; a binary from <https://github.com/rhysd/actionlint/releases> does not, and without shellcheck on PATH actionlint skips its shell checks, so a local green can differ from CI's). The `floor` (Neovim 0.10.0), `windows` and `commits` jobs run only in CI; `floor-below` (Neovim 0.9.5) runs `tests/floor_smoke.sh`, which runs locally too with a Neovim below the floor first on PATH; the commit-msg hook below runs the `commits` job's policy locally. The `nightly` workflow runs the suites weekly against Neovim nightly; GitHub disables a scheduled workflow after 60 days without a commit, and `gh workflow enable nightly` turns it back on.

You need Neovim 0.10 or newer, curl for the twelve suites that make HTTP requests, node for the injected client's rows in `tests/client_js_test.lua`, and bun for the formatter.

## Run the tests

    make test

runs every suite through `tests/run.sh`, the same loop CI runs, and then `tests/message_policy_test.sh`, which commits in a scratch repository through the hook (`sh tests/message_policy_test.sh` alone). Each suite is a plain Lua file under `tests/` that runs headless and exits 1 on any failure, so one can be run alone:

    nvim --headless -u NONE -l "$PWD/tests/token_auth_test.lua"

The absolute name is the one `tests/run.sh` passes: a relative one is made absolute against the physical directory, which loses a link the checkout is reached through (`tests/helpers.lua` says why that matters).

## Shared files

kitehost.nvim and mdkite.nvim share their test harness, their hooks, the Makefile and the PR template. `tests/parity.sh` lists every shared file and how it is compared, and `make parity SIBLING=../mdkite.nvim` compares them with a sibling checkout. This repository's copy is the source: a change to a shared file lands here first and is copied.

## Format

    make fmt        # StyLua, the version pinned in the Makefile; bun is the one prerequisite (make fmt-check is what CI runs; make lint-text, make lint-blame and make shellcheck are the other gates; make test runs the suites)

The config is `.stylua.toml`. The one-time format commit is listed in `.git-blame-ignore-revs` (`git config blame.ignoreRevsFile .git-blame-ignore-revs`).

## Commits

A subject names the area a commit touches and what now holds (`server: a /__live/ name that is no route is 404`), in at most 72 characters; the body, wrapped at 72 columns, says why. A commit names its author alone. No tool checks a commit's subject or wrapping; a pull request's title, which becomes the squash commit's subject, is checked for length below.

`.githooks/message-policy` checks three rules and refuses a message that carries any of:

- the em dash character (U+2014);
- an attribution trailer: `Co-authored-by`, `Signed-off-by`, `Co-developed-by`, `Assisted-by`, `Generated-by`, `Reviewed-by`, `Acked-by`, `Tested-by`, `Suggested-by` or `Reported-by`, in any case and with or without blanks before the colon, as git reads a trailer;
- a workflow skip instruction: `[skip ci]`, `[ci skip]`, `[no ci]`, `[skip actions]` or `[actions skip]` anywhere, or a `skip-checks: true` trailer line (`skip-checks:true` too), in any case; one on main leaves that push with no CI run.

The policy runs in three places. The commit-msg hook runs it on each commit you make. On a pull request the `commits` job refuses a title, a body or a commit that breaks it: the title and the body become the squash commit on main, and the title is at most 65 characters, since ` (#N)` is appended to it. On a push to main the same job reports what landed; it cannot refuse it. `make lint-text` refuses the em dash in the tracked files it checks.

Install the hook with `make hooks`, which copies it and `.githooks/message-policy` into this clone's hooks directory; the hook runs that copy, never the working tree's, since git runs the hook for a merge with the merged branch checked out. Run `make hooks` again after a change to `.githooks/`: the hook refuses with a line naming it when its copy is missing, and the `commits` job judges the recorded message either way. `git config core.hooksPath .githooks` is not the way: a hooks path inside the tracked tree runs whatever hooks a checked-out branch carries, a fork's included, during the checkout itself, before anyone has read them. `make hooks` refuses while `core.hooksPath` is set; `git config --unset core.hooksPath` clears it, and `git config --global --unset core.hooksPath` where it is set globally. The hook reproduces git's cleanup by reading the message file (`commit.cleanup` included, a `--cleanup=` option not), so a refusal the maintainer judges false, the hook's reading of an unusual message file, is passed with `git commit --no-verify`; the `commits` job then judges what git recorded. It judges the skip instructions on the message with its comment lines kept, so an editor session whose status lines name one (a staged file called `[skip ci].txt`) is refused.

When the `commits` job is red on your pull request, reword the commit (`git commit --amend` for the last one, `git rebase -i` for an earlier one) or edit the title or the body, then force-push the branch. A red report on main is a record and is left alone; the next push judges only its own range. Accepting a review suggestion in GitHub's web UI adds a `Co-authored-by` line for the suggester, so apply suggestions locally instead.

A pull request Dependabot opens is machine-authored, keyed on the pull request's author as GitHub sets it: the `commits` job accepts Dependabot's own `Signed-off-by` line on its commits and does not judge its body, release notes that may break the policy, while the title is judged as any other. Merging one keeps the title (edited down when it runs over 65 characters) and replaces the squash commit's body with one line, because that body lands on main, where the push arm judges it.

## Pull requests

`main` takes squash merges only: the pull request's title becomes the commit's subject, with ` (#N)` appended, and its description the body. A merge needs `ci-ok` green on the branch's latest commit with the branch up to date with `main`, and one approving review; the maintainer's own pull requests merge through the administrator bypass, which the protection leaves open to administrators. An approval survives a later push (stale approvals are not dismissed), so re-read what changed since it before merging. A manual run (`workflow_dispatch`) of the same commit posts the same `ci-ok` context: it judges that commit's message, while the title and the body are judged only on a pull request run.

## Releases (maintainer)

1. Move the `Unreleased` section of `CHANGELOG.md` under the new version and date, add the version's link definition under `[Unreleased]`'s (newest first), and start the `[Unreleased]` compare link at the new tag.
2. Tag only a commit whose `ci-ok` is green (`gh run list --commit <sha>`): `git tag -a vX.Y.Z -m "vX.Y.Z"`, `git push origin vX.Y.Z`. The tags v1.0.0 and v1.1.0 are annotated and v1.2.0 to v1.5.0 are lightweight, so `git describe` needs `--tags` until the next annotated tag.
   The `release tags` ruleset refuses moving or deleting a `v*` tag, so a mistaken tag is fixed by editing the ruleset once (Settings, Rules), and every new `v*` tag is covered from its push. mdkite.nvim pins its kitehost floor by tag and commit (`KITEHOST_FLOOR` and `KITEHOST_FLOOR_SHA` in its `ci.yml`, beside `H.kitehost_floor` in its `tests/helpers.lua`): a release that moves that floor edits the three there in one change.
3. `gh release create vX.Y.Z --verify-tag --title "vX.Y.Z" --notes-file <the section as a file>`.

### Moving the floor

A release that moves the Neovim floor edits every place that states it, together (`git grep -n '0\.10'` and `git grep -n 'v1\.5\.0'` find them, beside what states no floor: harness comments that name a version they were measured on, the CHANGELOG's release links and past release notes, and the tag history in the release steps):

- `lua/kitehost/floor.lua`: the check and the message, which the plugin file, the module and the smoke read;
- `plugin/kitehost.lua`: the header comment and the refusers' description;
- the README's requirements line and its plugin-author note (the floor message `kitehost.server` and `kitehost.util` raise), the vimdoc's REQUIREMENTS, SECURITY.md's supported versions and a CHANGELOG entry;
- this file's prerequisites and job list;
- `.github/workflows/ci.yml`: the `floor` job's version and name, `floor-below`'s version and name (the newest release below the floor), and the comments above both;
- `tests/floor_guard_test.lua`, which pins the text, and the comments of `tests/floor_smoke.sh`;
- the bug template's version placeholder;
- mdkite.nvim, when its kitehost floor moves with the release: `KITEHOST_FLOOR` and `KITEHOST_FLOOR_SHA` in its `ci.yml`, `H.kitehost_floor` in its `tests/helpers.lua`, and its AGENTS.md and CHANGELOG.
