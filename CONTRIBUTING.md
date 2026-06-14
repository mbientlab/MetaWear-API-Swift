# Contributing to MetaWear-API-Swift

Thanks for your interest in contributing! This document explains how to set up
the project, the workflow we follow, and the conventions we expect in pull
requests.

By contributing, you agree that your contributions are licensed under the terms
in [`LICENSE.md`](LICENSE.md).

## Code of conduct

Be respectful and constructive. Harassment or abuse of any kind is not
tolerated. Report concerns to [hello@mbientlab.com](mailto:hello@mbientlab.com).

## Ways to contribute

- **Report a bug** — open an issue with steps to reproduce, the board model
  (MetaMotion S / RL) and firmware revision, the SDK version, and what you
  expected vs. what happened.
- **Request a feature** — open an issue describing the use case before sending a
  large PR, so we can agree on the approach first.
- **Send a pull request** — small, focused PRs are easiest to review. For
  anything substantial, open an issue first.

### Reporting a security issue

**Do not open a public issue for security vulnerabilities.** Use GitHub's private
vulnerability reporting (the **Security** tab → *Report a vulnerability*) or
email [hello@mbientlab.com](mailto:hello@mbientlab.com).

## Development setup

Requirements:

- macOS with a recent **Xcode** (matching the project's Swift toolchain)
- **Swift 6** (the package builds with strict concurrency enabled)
- A physical **MetaMotion S** or **MetaMotion RL** board to run the hardware test
  suite (not required for the unit tests)

Clone and build:

```bash
git clone git@github.com:mbientlab/MetaWear-API-Swift.git
cd MetaWear-API-Swift
swift build --build-tests
```

## Building and testing

The unit suite runs entirely against a mock transport — no hardware or
Bluetooth needed. **Run it before every PR:**

```bash
swift test --filter MetaWearTests
```

The **hardware suite** (`MetaWearHardwareTests`) talks to a real board over
Bluetooth and is intended to be run manually from Xcode with a board powered on
and in range. It is **not** run in CI.

CI runs `swift build --build-tests` and `swift test --filter MetaWearTests` on
every pull request via [`.github/workflows/ci.yml`](.github/workflows/ci.yml).
**Your PR must be green before it can merge.**

## Pull request workflow

1. Create a topic branch off `main` (e.g. `your-name/short-description`).
   `main` is protected — don't push to it directly.
2. Make your change. Add or update tests for any behavior change.
3. Run `swift test --filter MetaWearTests` locally.
4. Open a PR against `main` with a clear description of *what* and *why*.
5. Make sure the `build-and-test` check passes and address review feedback.

Keep each PR scoped to a single concern. Unrelated changes (formatting sweeps,
renames) belong in their own PR.

## Commit messages

- Write a concise summary line in the imperative mood
  (e.g. "Fix logger cleanup on download timeout").
- Add a body explaining the reasoning when the change isn't self-evident.
- Reference issues where relevant (e.g. `Fixes #123`).

## Code style

- Follow the
  [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/).
- Match the style, naming, and comment density of the surrounding code.
- Prefer Swift concurrency (`actor`, `async`/`await`, `AsyncThrowingStream`) over
  GCD or Combine, consistent with the existing architecture.
- **The library must never crash a host app on bad input.** Validate caller
  input with a thrown `MWError` rather than `precondition`/`fatalError`.
- Keep one primary type per file; group files by feature.
- Document public API with `///` doc comments, including `- Throws:` for throwing
  initializers and methods.

## Protocol changes

This SDK is a clean-room implementation of the MetaWear BLE protocol. When you
change anything that touches the wire format, cite the authoritative source for
the byte layout (the protocol spec and/or the reference C++ SDK) in the code or
PR, and add a byte-exact regression test under `Tests/MetaWearTests`.

## Questions

Open a discussion or issue, or email
[hello@mbientlab.com](mailto:hello@mbientlab.com). Thanks for contributing!
