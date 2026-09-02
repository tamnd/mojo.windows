# Contributing

## The one rule that matters

Every change must leave the Linux and macOS test suites green. Linux is the baseline we develop against and it is the only thing that distinguishes "this broke Windows" from "this broke everything", so a change that regresses it is a change nobody can evaluate. If your change needs to behave differently on Windows, prefer making the existing code target driven over adding a Windows special case. Generalising edits conflict far less when the pin moves, which is the cost you pay over and over.

## Setting up

You need git, python3, and a Linux or macOS machine. Windows as a build host does not work yet, that is milestone M6.

```sh
git clone https://github.com/tamnd/mojo.windows
cd mojo.windows
./scripts/sync.sh
```

The first run clones upstream, which is large, so give it a few minutes. You end up with a normal git checkout at `.upstream/modular` sitting on branch `windows/<pinned-tag>` with our overlay applied as a single commit on top of the pin. That directory is gitignored. Delete it whenever you want and run `sync.sh` again.

## Making a change

Work inside `.upstream/modular` like any other git repository. Edit real files with your real editor. When you are happy:

```sh
./scripts/refresh.sh
```

That copies everything that differs from the pin into `overlay/`. You do not have to say which files you touched. Commit the changed files under `overlay/` in this repository and open a pull request.

To see what the overlay actually changes, as a diff against upstream:

```sh
./scripts/overlay-diff.sh
./scripts/overlay-diff.sh bazel/config.bzl
```

## Commit messages

The commit subject is the first thing a reviewer sees, so it is worth a moment. Start with an area prefix and a colon:

```
build: add a windows_x86_64 platform and constraint
compiler: pick the ABI from the target triple rather than the host
stdlib: add sys.info.is_windows
```

Use `build`, `compiler`, `runtime`, `stdlib`, `test`, `bazel` or `docs`. This is upstream's shape and there is no reason to invent our own.

Keep commits small and self contained. One commit per logical change. A twelve file commit called "windows fixes" is impossible to review and impossible to bisect, so it will be sent back.

The overlay stores whole files, so the commit message is now the only place the reason for a change is written down in a form you can search. Say why, not what. The diff already says what.

## What CI checks

Pull requests run `scripts/check-overlay.sh`, which verifies that the manifest and the files under `overlay/` agree with each other, that every path is a plain relative path listed once, that nothing contains conflict markers, private addresses or key material, that the overlay still applies at the pinned upstream commit, and that upstream has not changed any of the files the overlay owns.

Workflow files are linted with actionlint, shell scripts with shellcheck, and markdown links are checked. CodeQL runs on the workflows.

## Rebasing onto a newer upstream

Do not do this by hand. Run `./scripts/bump-upstream.sh`, which merges every overlay file onto the newer upstream and only touches `upstream.lock` if everything merged. A scheduled workflow already does this weekly and opens a pull request, so most of the time the bump will already be waiting for you.

If a bump conflicts, the script leaves conflict markers in the file under `overlay/` and names the three sides: ours, upstream at the old pin, upstream at the new one. Resolve them the way you would resolve any merge conflict and rerun the script.

A clean merge is not proof of a correct one. Git merges lines, not meaning, so when upstream reworks the code around one of our changes the merge succeeds and the result can be nonsense. Read the overlay diff on a bump pull request rather than trusting that it went green.

## Upstreaming

This project does not send anything to `modular/modular`. Not the standard library changes, not the portability refactors, none of it. That decision is recorded in #35 along with what it costs.

If you were about to open a pull request upstream carrying work from here, do not. If Modular wants any of this, they can take it, and the licence already lets them.

## Reporting bugs

If it reproduces on Linux or macOS with plain upstream Mojo, it is an upstream bug, please file it at `modular/modular`. Everything else belongs here.

## Private infrastructure

Do not put machine names, host names, IP addresses, usernames or credentials for any test machine into this repository, including in issues, pull request descriptions, workflow files and the overlay. Self hosted runners are referenced by opaque label only. CI checks for private addresses and key material, and for a denylist held as a repository secret so the names themselves never appear here. That is a backstop, not a substitute for paying attention.
