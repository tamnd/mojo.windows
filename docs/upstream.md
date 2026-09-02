# Tracking upstream

## The problem

We need to modify roughly a million lines of somebody else's C++, Bazel and Mojo, keep our changes reviewable and separable, and keep taking their updates. Upstream releases often, so the changes have to survive a moving base.

One constraint that used to be here has been dropped. This project does not send anything to `modular/modular`. That was a real design input once and it is not any more, and it changed the answer below. See #35.

## What we rejected

**A GitHub fork.** The obvious answer and the wrong one. It drags a million lines we never touch into our repository, so `git log` and `git diff` stop being useful for seeing what this project actually did. It inherits upstream's six workflows, which then fire on our pushes and either fail or burn minutes. Issues are off by default in a fork and the whole thing sits inside upstream's fork network, which makes the relationship look closer than it is. Worst of all, a fork encourages you to just commit on top and let the divergence grow, which is exactly the failure mode that turns a port into abandonware.

**A git submodule.** Better, and it does give you a pinned commit. But a submodule wants a clean checkout and we need to modify the thing it points at, so you immediately end up with a permanently dirty submodule and no clean way to express "our changes" as a reviewable set. Submodules are for dependencies you consume, not for source you patch.

**A git subtree, or vendoring the tree.** Same million lines in our history as a fork, with more ceremony and worse merge behaviour. No.

**A rebasing long lived branch.** This is the fork failure mode with extra steps. The changes exist only as branch state, so there is no way to look at "the fifteen things we changed" and no way to hand any one of them to a reviewer.

**A `git format-patch` series.** This is what the project did first, and it is what Debian, Alpine, Yocto and every downstream kernel tree use. It is a good design and it was the right call given the constraint it was chosen under, which was that every change should be in the shape a maintainer wants to receive.

It stopped being the right call when upstreaming came off the table. What a series buys you is that each change stays a self contained thing with a subject line and a sign off that you can hand to somebody. What it costs you is that the file you edit is not the file you commit. You edit source in `.upstream/modular`, then export hunks, and the thing under review is a diff of a diff. Adding one line to a `select()` means reading a patch file to work out where you are. Reordering two changes means rewriting both. Nothing has syntax highlighting.

That trade is worth making when the patches are the product. When they are not, you are paying the whole cost for none of the benefit.

## What we do instead

A pinned commit plus a file overlay.

Three pieces:

`upstream.lock` records the upstream repository, the tag, and the exact commit our changes are written against. It is machine written by `scripts/bump-upstream.sh`, not edited by hand.

`overlay/` holds whole files at their upstream paths, plus `overlay/MANIFEST` listing them. A file in there is a normal file. Open it, edit it, and your editor knows what language it is in. This is the actual product of the project.

`scripts/` puts them together. No upstream source we have not changed is ever committed here, and the overlay is currently about 130 kilobytes.

### The manifest

`overlay/MANIFEST` is three columns:

```
edit	586cd6589ac54d9adfa57362c41dc733abe08071	bazel/config.bzl
new	-	Support/lib/WindowsSomething.cpp
delete	d4e5f6...	some/file/we/removed.cpp
```

The blob hash is the whole reason the manifest exists rather than being inferred from a directory listing. It records what upstream had at the moment we took the file over. Without it, moving the pin forward would lay our version of a file on top of upstream's newer version and silently throw their changes away, and nothing would tell you. With it, `sync.sh` compares and says which of our files upstream has moved underneath us, and `bump-upstream.sh` does a real three way merge instead of a copy.

### The commands

```sh
./scripts/sync.sh            # get a working tree: upstream at the pin, overlay applied
./scripts/refresh.sh         # copy your edits back into overlay/
./scripts/overlay-diff.sh    # show the overlay as a diff against the pin
./scripts/bump-upstream.sh   # move the pin forward, merge the overlay onto it
./scripts/check-overlay.sh   # what CI runs
```

`sync.sh` does a blobless clone (`--filter=blob:none`) into `.upstream/modular`, which is gitignored, checks out the pinned commit onto a branch named after the pinned tag, copies the overlay in and commits it. You get an ordinary git checkout with one commit on top of upstream. Use your normal tools in it.

`refresh.sh` takes everything in that checkout that differs from the pin, whatever state it is in, and writes it back to `overlay/`. You do not tell it which files you touched, so taking over a file you have never edited before is just editing it.

### Why this shape is good

Our diff is our diff. `git log` in this repository shows commits about Windows, not a million lines of somebody else's work, and `overlay/` is a short list you can read in a sitting.

You edit source, not hunks. This is the entire reason for the change and it is worth more than it sounds.

A pull request here shows a normal diff of source code. Reviewing an added `select()` arm means reading the arm, not reconstructing it from `@@` markers.

Rebasing is a real three way merge, per file, with upstream's version at the old pin as the base. When it cannot resolve something it leaves conflict markers in a source file, which is a thing every developer already knows how to fix, rather than a failed `git am` that has to be replayed patch by patch.

Changes drop out by deleting a file from `overlay/` and rerunning `refresh.sh`. When upstream fixes something themselves, our version disappears and the next bump proves it was not needed.

Clone size stays in kilobytes. Contributors get the interesting part immediately and pay for the big checkout once, in the background, on first `sync.sh`.

### The cost, honestly

We lose per change granularity. Six patches with six commit messages became thirteen files, and the reason a particular line exists now lives in a code comment and in this repository's git history rather than in a patch header. That is a real loss and the mitigation is that comments in the overlay have to explain themselves, which they mostly did already.

We also lose the ability to hand one change to somebody as a file. Given that we are not sending anything upstream, that costs nothing today, and if it ever matters again `scripts/overlay-diff.sh` plus `git log` reconstructs it.

The genuinely risky part is that a clean three way merge is not the same as a correct one. Git merges lines, not meaning, so if upstream reworks the code around one of our changes the merge succeeds and the result is wrong. A patch series has exactly the same problem and hides it slightly less well. The mitigation is that the bump opens a pull request with the overlay diff in it and somebody reads it, which is why the workflow says so in the body rather than implying the merge is proof of anything.

## Staying current

`.github/workflows/upstream-sync.yml` runs every Monday and can be triggered by hand. It fetches upstream, merges the overlay onto the newer commit, and either opens a pull request or files one drift issue.

If every file merges cleanly, it opens a pull request that updates `upstream.lock` and whichever overlay files upstream moved underneath us. Review it like any other change, and actually read the overlay diff rather than trusting the merge, for the reason in the cost section above.

If a file conflicts, it does not touch anything. It opens or updates a single tracking issue labelled `upstream-drift` naming what it tried and what did not merge. One issue, updated in place, so a month of failed bumps is one notification and not four.

## Why the pin follows main and not release tags

It should follow release tags. Chasing nightlies means constant small breakage for no benefit while the port is still being built, and a tag is a much better thing to reproduce against than a moving branch. That was the original design and it is what this document used to say.

It cannot, for now, and the reason is worth writing down because it is not obvious and it wasted a real amount of time.

Mojo was open sourced in stages. The `mojo/v1.0.0` tag is from 11 August 2026 and its tree contains `mojo/stdlib`, docs, examples and the integration tests. It does not contain the compiler. `Mojo/lib`, `Mojo/tools`, `Support`, `AsyncRT` and the rest of the C++ landed on `main` after that tag, some time before 2 September 2026. There is no release tag carrying the compiler yet, and `mojo/v1.0.0` is still the newest one.

Almost everything this project does is compiler work, so a pin at `mojo/v1.0.0` is a pin at a tree where the files we change do not exist. The overlay lands on nothing and the error tells you nothing about why.

So the default for `bump-upstream.sh` is the tip of `main`, and `scripts/common.sh` now refuses any pin whose tree is missing `Support/BUILD.bazel`, `Mojo/lib/KGENToLLVM/CABILowering.cpp`, `Mojo/tools/mojo/Build/mojo-build.cpp` or `Mojo/stdlib`. That guard exists so this specific mistake cannot be made twice, including by the scheduled workflow.

Switch the default back to release tags the moment upstream tags one that carries the compiler. The tag path in the script still works and is still the better answer.

## What is pinned right now

See `upstream.lock`. As of writing, upstream `main` at `9aba62be`.

That is the same commit the source audit behind these documents was done against, which is a happy accident rather than a plan. It does mean the line numbers quoted in the issues and documents are accurate as of the pin rather than approximately right. They will still drift as the pin moves, so if a line number does not match, search for the quoted snippet. File paths and quoted code are the durable part.
