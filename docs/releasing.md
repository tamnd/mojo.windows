# Releasing

## What a version number means here

This project does not ship a product with its own feature set. It ships a set of changed files against a pinned upstream Mojo, so a version number needs to answer one question: how far through the roadmap is this. The scheme is built around the milestones rather than around semver's usual promises about API compatibility.

The rule is that `v0.x.0` marks the completion of milestone `Mx`, and `v0.x.y` for `y` greater than zero marks incremental progress made while working toward `M(x+1)`.

Read a version as "milestone x is finished, plus y batches of work since". So `v0.1.3` means M1 is done and three batches of M2 work have landed on top. That reads naturally and it sorts correctly, which are the only two things a version number has to do.

| Tag | Meaning |
|---|---|
| `v0.0.0` | M0 complete, the pin and the tooling work |
| `v0.0.1`, `v0.0.2` | progress during M1 |
| `v0.1.0` | M1 complete, a Windows targeted build passes analysis |
| `v0.1.1`, `v0.1.2` | progress during M2 |
| `v0.2.0` | M2 complete, the C++ compiles for Windows |
| `v0.3.0` | M3 complete, hello.exe runs |
| `v0.4.0` | M4 complete, tier 0 and 1 stdlib green |
| `v0.5.0` | M5 complete, first public release |
| `v0.6.0` | M6 complete, tier 2 and native hosting |
| `v0.7.0` | M7, which does not complete, so this one is not used |
| `v0.8.0` | M8 complete, handover or wind down |

There is deliberately no `v1.0.0`. Version 1 of Mojo on Windows is Modular's to ship, not ours, and claiming the number would be misleading about what this repository is.

## Patch releases

Cut one after a batch of pull requests has landed and the overlay still applies cleanly. There is no fixed cadence and no minimum number of pull requests. The test is whether somebody tracking the project would find the tag useful, which usually means a few related changes finishing something nameable rather than one change on its own.

Do not cut one when the only change is documentation or CI. Those land on `main` and get picked up by the next real release.

## Minor releases

Cut one when every issue in a milestone is closed and the milestone tracking issue's checklist is fully ticked. The milestone's exit criteria, written in the tracking issue under "Done when", have to actually be met and not just nearly met. If one item is outstanding, it is a patch release and the minor waits.

## What is in a release

Until M5 there are no binaries. A release is the overlay plus the pin, so the artifact is the source tarball that GitHub generates automatically plus the release notes. From M5 there is a zip with checksums and build provenance, which is issue #27.

The point of tagging before there are binaries is that `upstream.lock` plus `overlay/` at a tag is a complete and reproducible description of a tree. Anybody can check out the tag, run `./scripts/sync.sh` and get exactly what we had.

## Cutting one

Tag on `main`, push the tag, and the release workflow drafts the release. Fill in the notes and publish.

```sh
git tag -a v0.1.0 -m "M1 complete, a Windows targeted build passes analysis"
git push origin v0.1.0
```

## Release notes

Write them for somebody who has not read the pull requests. Lead with what changed about what the project can do, not with a list of commit subjects, and be honest about what still does not work. A release that says "the build now gets through analysis and immediately fails to compile, which is the next milestone" is more useful than one that lists eleven Bazel changes.

Always state which upstream commit the release is pinned to, because that is the thing that makes the tag reproducible.
