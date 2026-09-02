# Tracking upstream

## The problem

We need to modify roughly a million lines of somebody else's C++, Bazel and Mojo, keep our changes reviewable and separable, keep taking their updates, and end up with something we can hand back to them. Upstream releases often and is not currently accepting compiler pull requests, so "just send it upstream" is not available yet and the changes have to live somewhere in the meantime.

## What we rejected

**A GitHub fork.** The obvious answer and the wrong one. It drags a million lines we never touch into our repository, so `git log` and `git diff` stop being useful for seeing what this project actually did. It inherits upstream's six workflows, which then fire on our pushes and either fail or burn minutes. Issues are off by default in a fork and the whole thing sits inside upstream's fork network, which makes the relationship look closer than it is. Worst of all, a fork encourages you to just commit on top and let the divergence grow, which is exactly the failure mode that turns a port into abandonware.

**A git submodule.** Better, and it does give you a pinned commit. But a submodule wants a clean checkout and we need to modify the thing it points at, so you immediately end up with a permanently dirty submodule and no clean way to express "our changes" as a reviewable set. Submodules are for dependencies you consume, not for source you patch.

**A git subtree, or vendoring the tree.** Same million lines in our history as a fork, with more ceremony and worse merge behaviour. No.

**A rebasing long lived branch.** This is the fork failure mode with extra steps. The changes exist only as branch state, so there is no way to look at "the fifteen things we changed" and no way to hand any one of them to a reviewer.

## What we do instead

A pinned commit plus a patch series, which is how Debian, Alpine, Yocto, Chromium and every downstream kernel tree have handled this for decades. It is not novel and that is a feature.

Three pieces:

`upstream.lock` records the upstream repository, the tag, and the exact commit our patches are written against. It is machine written by `scripts/bump-upstream.sh`, not edited by hand.

`patches/` holds the series as `git format-patch` output, one file per logical change, ordered. This is the actual product of the project. Everything else is scaffolding.

`scripts/` puts them together. No upstream source is ever committed here.

### The commands

```sh
./scripts/sync.sh            # get a working tree: upstream at the pin, series applied
./scripts/refresh.sh         # export your commits back into patches/
./scripts/bump-upstream.sh   # move the pin forward, replay the series
./scripts/check-patches.sh   # what CI runs
```

`sync.sh` does a blobless clone (`--filter=blob:none`) into `.upstream/modular`, which is gitignored, checks out the pinned commit onto a branch named after the pinned tag, and runs `git am --3way` over the series. You get an ordinary git checkout. Use your normal tools in it.

### Why this shape is good

Our diff is our diff. `git log` in this repository shows fifteen commits about Windows, not a million lines of somebody else's work.

Every patch is already in the format a maintainer wants to receive. When Modular opens the compiler up, upstreaming is sending the file, not archaeology on a branch. That is why `check-patches.sh` insists on a real subject line, a known area prefix and a sign off. A patch that is not submittable has already lost most of its value.

Rebasing is a scripted operation with a pass or fail answer, not an afternoon of merge conflict resolution. When it fails it names the patch that broke.

Clone size stays in kilobytes. Contributors get the interesting part immediately and pay for the big checkout once, in the background, on first `sync.sh`.

Patches drop out of the series by deleting a file. When upstream fixes something themselves, our version of the fix disappears in one commit and the bump proves it was not needed.

### The cost, honestly

`git am` is less forgiving than a merge. When upstream reworks a file we patch, we fix the patch by hand rather than letting a three way merge guess. In exchange the result is always a clean series rather than a tree with a merge history nobody can read. For a project whose output is meant to become upstream commits, that is the right trade.

There is also a real risk that the series rots if nobody looks at it. That is why the bump is automated and noisy rather than a chore somebody is supposed to remember.

## Staying current

`.github/workflows/upstream-sync.yml` runs every Monday and can be triggered by hand. It fetches upstream, finds the newest `mojo/v*` release tag, and replays the series onto it.

If the series applies cleanly, it opens a pull request that updates `upstream.lock` and any patch files that shifted. Review it like any other change, check CI, merge it.

If the series conflicts, it does not touch anything. It opens or updates a single tracking issue labelled `upstream-drift` naming the tag it tried and the first patch that failed. One issue, updated in place, so a month of failed bumps is one notification and not four.

The pin follows release tags rather than `main` on purpose. Chasing nightlies means constant small breakage for no benefit while the port is still being built. `bump-upstream.sh --branch main` exists for when you specifically want to test against the tip.

## What is pinned right now

See `upstream.lock`. As of writing, `mojo/v1.0.0`.

One caveat worth knowing. The source audit that produced these documents and the issue backlog was done against upstream `main` at `9aba62be`, not against the `mojo/v1.0.0` tag, and it is recorded in the lock as `audit_commit`. Line numbers quoted in issues and documents are relative to that commit and will drift. File paths and quoted code are the durable part, so if a line number does not match, search for the quoted snippet.
