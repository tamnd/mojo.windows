# Contributing

## The one rule that matters

Every patch must leave the Linux and macOS test suites green. A patch that regresses the platforms Modular actually ships is a patch that can never go upstream, and getting this work upstream is the entire point. If your change needs to behave differently on Windows, prefer making the existing code target driven over adding a Windows special case. Generalising edits conflict less on rebase and read better to a reviewer.

## Setting up

You need git, python3, and a Linux or macOS machine. Windows as a build host does not work yet, that is milestone M6.

```sh
git clone https://github.com/tamnd/mojo.windows
cd mojo.windows
./scripts/sync.sh
```

The first run clones upstream, which is large, so give it a few minutes. You end up with a normal git checkout at `.upstream/modular` sitting on branch `windows/<pinned-tag>` with our patch series applied. That directory is gitignored. Delete it whenever you want and run `sync.sh` again.

## Making a change

Work inside `.upstream/modular` like any other git repository. When you are happy, commit there, then export the series back:

```sh
cd .upstream/modular
git add -p
git commit -s
cd ../..
./scripts/refresh.sh
```

Then commit the changed files under `patches/` in this repository and open a pull request.

## Commit messages

The commit subject becomes the patch filename and it is the first thing a reviewer sees, so it is worth a moment. Start with an area prefix and a colon:

```
build: add a windows_x86_64 platform and constraint
compiler: pick the ABI from the target triple rather than the host
stdlib: add sys.info.is_windows
```

Valid prefixes are `build`, `compiler`, `runtime`, `stdlib`, `test`, `bazel` and `docs`. CI rejects anything else, because a subject that does not follow upstream's shape is a subject somebody has to rewrite later.

Sign off your commits with `git commit -s`. CI checks for it. This is the standard Developer Certificate of Origin sign off and it is what upstream will want.

Keep commits small and self contained. One commit per logical change. A twelve file commit called "windows fixes" is impossible to review, impossible to rebase, and impossible to send upstream, so it will be sent back.

## What CI checks

Pull requests run `scripts/check-patches.sh`, which verifies that every patch has a subject line and a sign off, that the subject uses a known prefix, that no patch contains conflict markers or leftover rebase reminders, that no patch leaks private addresses or key material, and that the whole series still applies cleanly at the pinned upstream commit.

Workflow files are linted with actionlint, shell scripts with shellcheck, and markdown links are checked. CodeQL runs on the workflows.

## Rebasing onto a newer upstream

Do not do this by hand. Run `./scripts/bump-upstream.sh`, which replays the series onto the newest upstream tag and only touches `upstream.lock` if everything applied. A scheduled workflow already does this weekly and opens a pull request, so most of the time the bump will already be waiting for you.

If a bump conflicts, the script tells you which patch broke and prints the commands to resolve it by hand. Fix the patch, do not paper over it with a merge commit, because the series has to stay as a clean set of independent changes.

## Which patches can go upstream today

Modular takes standard library pull requests but is not taking compiler pull requests from outside yet. So the series splits in two.

Anything touching `Mojo/stdlib`, and any pure portability refactor that has no Windows specific content in it, can be offered upstream right now. There are four of these already identified in the backlog and they are deliberately good first issues, because getting them accepted tells us a lot about how the rest of this will go.

Everything under `Mojo/lib` and `Mojo/tools` gets banked. Write it as if you were sending it tomorrow anyway.

## Reporting bugs

If it reproduces on Linux or macOS with plain upstream Mojo, it is an upstream bug, please file it at `modular/modular`. Everything else belongs here.

## Private infrastructure

Do not put machine names, host names, IP addresses, usernames or credentials for any test machine into this repository, including in issues, pull request descriptions, workflow files and patches. Self hosted runners are referenced by opaque label only. CI checks for private addresses and key material, and for a denylist held as a repository secret so the names themselves never appear here. That is a backstop, not a substitute for paying attention.
