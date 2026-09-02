#!/usr/bin/env python3
"""Render the body of the upstream drift issue.

Called by .github/workflows/upstream-sync.yml when a scheduled bump fails. It lives
here rather than inline in the workflow because the body is markdown full of code
fences, and getting backticks through YAML and shell quoting intact is more trouble
than it is worth.

Usage: drift-body.py <previous-tag> <run-url> [log-file]
"""

import sys
from pathlib import Path

TAIL_LINES = 40


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2

    before, run_url = sys.argv[1], sys.argv[2]
    log_path = Path(sys.argv[3] if len(sys.argv) > 3 else "bump.log")

    if log_path.exists():
        tail = log_path.read_text(errors="replace").splitlines()[-TAIL_LINES:]
    else:
        tail = [f"({log_path} was not written, so there is no output to show)"]

    fence = "`" * 3
    out = [
        f"The scheduled bump from `{before}` failed. The pin has not been changed.",
        "",
        f"Last {TAIL_LINES} lines of the attempt:",
        "",
        fence,
        *tail,
        fence,
        "",
        "To work it out locally:",
        "",
        fence + "sh",
        "./scripts/bump-upstream.sh",
        fence,
        "",
        "This issue is updated in place rather than reopened, so a month of failed bumps",
        "stays one notification rather than four.",
        "",
        f"Run: {run_url}",
    ]
    print("\n".join(out))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
