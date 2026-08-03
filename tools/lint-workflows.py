#!/usr/bin/env python3
# lint-workflows.py -- rules about workflows that are cheap to check and
# expensive to rediscover.
#
# RULE 1: every `on: push` MUST filter branches.
#
#   Without it, a `push:` trigger fires on TAG pushes too -- a `paths:` filter
#   does not help, because a tag carries the whole commit and its paths match.
#   Creating one source-mirror release (`gh release create src/<tarball>`)
#   therefore started 19 workflows at once, including the full ladder.
#
#   `branches: ['**']` matches every branch and no tag, which preserves the
#   behaviour these workflows were written for.
#
# RULE 2: no build logic in workflow `run:` blocks.
#
#   Advisory only, and deliberately crude -- it flags literal sha256 digests
#   and configure/make invocations in YAML. DERIVATIONS.md Decision 3: the
#   workflow is a caller, `tools/veron` is the build. This was not theoretical
#   either: a hardcoded sha256 in stage5-spike meant the second package was
#   never fetched once its pin became real.

import os
import re
import sys

WF = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                  ".github", "workflows")

SHA256 = re.compile(r"\b[0-9a-f]{64}\b")
BUILDISH = re.compile(r"^\s*(\./configure|make\s+-j|make\s+install|tar\s+-x)", re.M)


def push_block(text):
    """The lines indented under `  push:` in the `on:` mapping."""
    lines = text.splitlines()
    for i, ln in enumerate(lines):
        if re.match(r"^  push:\s*$", ln):
            block, j = [], i + 1
            while j < len(lines) and (not lines[j].strip() or lines[j].startswith("    ")):
                block.append(lines[j])
                j += 1
            return "\n".join(block)
    return None


def main():
    errors, warnings = [], []
    for fn in sorted(os.listdir(WF)):
        if not fn.endswith((".yml", ".yaml")):
            continue
        text = open(os.path.join(WF, fn)).read()

        blk = push_block(text)
        if blk is not None and "branches" not in blk and "tags" not in blk:
            errors.append(
                f"{fn}: `on: push` has no branches/tags filter -- a TAG push "
                f"will fire it. Add `branches: ['**']`.")

        for m in SHA256.finditer(text):
            line = text[:m.start()].count("\n") + 1
            warnings.append(f"{fn}:{line}: literal sha256 in a workflow -- "
                            f"pins belong in a recipe, not in YAML")
        for m in BUILDISH.finditer(text):
            line = text[:m.start()].count("\n") + 1
            warnings.append(f"{fn}:{line}: build command in a workflow -- "
                            f"the workflow is a caller ({m.group(1).strip()})")

    for w in warnings:
        print(f"  warn  {w}")
    for e in errors:
        print(f"  ERROR {e}")
    print(f"\n  {len(errors)} error(s), {len(warnings)} warning(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
