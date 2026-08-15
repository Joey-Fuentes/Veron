# stage-2 conformance corpus

`conformance.tsv` -- 426 C programs with their expected exit codes, run against
stage 2 inside the sealed box by `.github/workflows/stage3-hermetic-arm64.yml`.

## Format

One test per line, three fields separated by **0x1F (ASCII US)**:

    <expected-exit-code>  <runtime argv, may be empty>  <program source>

**The separator is not a tab, and that is load-bearing.** POSIX classifies tab
as IFS *white space*, so `read -r a b c` collapses a run of tabs into one
delimiter -- an empty middle field vanishes and every later field shifts left.
argv is empty on 414 of the 426 rows, so a tab-separated corpus would hand the
program text to the argv variable on almost every line. 0x1F is not IFS white
space, so empty fields survive, and it cannot occur in C source.

## Provenance

Extracted from `stage2-pico-c-demo.yml` by `tools/extract_stage2_tests.py`,
which derives each harness's printf form and runtime argv from the harness's own
definition rather than a hand-written list. That workflow is now in
`.github/workflows-archive/`.

To regenerate:

    python3 tools/extract_stage2_tests.py \
      .github/workflows-archive/stage2-pico-c-demo.yml \
      spikes/stage2-pico-c/corpus/conformance.tsv

## Why it lives here and not in the workflow

It used to be read straight out of the demo workflow, which made a data file a
dependency of a YAML file -- and archiving that YAML broke the hermetic build,
because GitHub stops *executing* an archived workflow but nothing stops another
job *reading* it. Test data is data. It belongs in the tree, under a path that
says what it is.
