# The patch series

This directory is the actual product of the project. Everything else is scaffolding.

Each file is one `git format-patch` output, one logical change, applied in filename order on top of the commit pinned in `../upstream.lock`.

It is empty right now. The first patches land in milestone M1.

## Working on it

Do not edit these files by hand. Use the scripts.

```sh
../scripts/sync.sh       # apply the series onto a fresh upstream checkout
../scripts/refresh.sh    # export commits from that checkout back into here
```

## Rules

Every patch needs a subject line starting with an area prefix and a colon, one of `build`, `compiler`, `runtime`, `stdlib`, `test`, `bazel` or `docs`. Every patch needs a `Signed-off-by` line. CI enforces both.

Prefer patches that make existing code target driven over patches that add a Windows special case. They conflict less on rebase and they read better to a reviewer, which matters because the whole point is that these eventually become upstream commits.

Keep them small. A patch touching twelve files called "windows fixes" cannot be reviewed, cannot be rebased and cannot be sent upstream.

## Two kinds of patch

Anything under `Mojo/stdlib`, and any pure portability refactor with no Windows specific content in it, can be offered to Modular right now. They take standard library pull requests.

Anything under `Mojo/lib` or `Mojo/tools` gets banked, because compiler pull requests from outside are not being accepted yet. Write them as if you were sending them tomorrow anyway.
