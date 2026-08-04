# Contributing

Contributions are welcomed and encouraged, within a deliberately narrow scope.

## Scope

**This package is a reimplementation, not a new encoder.** It follows Google's
reference implementation — [libjxl-tiny](https://github.com/libjxl/libjxl-tiny),
and full [libjxl](https://github.com/libjxl/libjxl) for the JPEG recompression
path — in Swift, reproducing its algorithms and its bitstream decisions. It
makes **no novel contributions** to the JPEG XL format or to the coding
techniques it uses.

Where this port and the reference disagree, the reference is right and this is a
bug. Every stage was gated byte-for-byte against `cjxl_tiny`, which depends on
nothing here inventing anything.

So the contributions that fit are:

- **Closing gaps against the reference** — a stage not yet ported, a case it
  handles and this does not, a place the output diverges.
- **Correctness, safety and portability** — bugs, memory behaviour, keeping the
  core free of platform dependencies, keeping output deterministic across
  architectures.
- **Tests, tooling and documentation**, especially anything that makes a
  divergence from the reference easier to find.

What does not fit is a new coding technique, a heuristic the reference does not
have, or an optimisation that changes the bitstream. Those belong upstream in
libjxl, where they can be reviewed by the people who own the format; this
package can then follow. An improvement that leaves the bitstream identical —
speed, memory, clarity — is welcome and is not affected by any of this.

If you are unsure which side of that line a change sits on, open an issue before
writing it.


To give clarity of what is expected of our members, Germ has adopted the
code of conduct defined by the Contributor Covenant. This document is used
across many open source communities, and we think it articulates our values
well. For more, see the [Code of Conduct](./CODE_OF_CONDUCT.md)

## Reporting Bugs

Reporting bugs is a great way for anyone to help improve these libraries.
Please report them using [Github Issues](./issues)
The open source Swift project uses GitHub Issues for tracking bugs.

Because these libraries are under very active development, we receive a lot of bug reports.
Before opening a new issue, take a moment to [browse our existing issues](./issues) to reduce the chance of reporting a duplicate.

## Linting
The repo has a .editorconfig and .swift-format setup. We use both swift
formatter and linter:
```
swift format . -ri && swift format lint . -r
```

## Static Analyzer
We also use the [periphery static analyzer](https://github.com/peripheryapp/periphery) and have a configured `periphery.yml`


## Changesets
We use [Changesets](https://github.com/changesets/changesets) to document changes and releases.
Please [generate a changeset](https://github.com/changesets/changesets/blob/main/docs/adding-a-changeset.md) for your pull requests.