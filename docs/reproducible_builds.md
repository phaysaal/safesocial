# Reproducible Builds

**Status: pinned and checkable, not yet demonstrated.**

The toolchain is pinned, releases publish hashes, CI compares two builds of the
same commit, and anyone can rebuild a release and diff it. What has *not*
happened is anybody observing all of that come out green — the CI check is new
and has never run, and no release has yet been published with hashes. Read the
claims below as "this is set up", not "this is proven".

## Why it matters here

The rest of this project is about not having to trust an operator. That argument
collapses at the binary: if you cannot check that the APK you installed was built
from this source, every other property is a promise rather than a fact.

## What is pinned

`FLUTTER_TOOLCHAIN` records every version that changes the output bytes:

| Component | Version |
|---|---|
| Flutter | 3.41.5 (revision 2c9eb20739) |
| Dart | 3.11.3 |
| Gradle | 8.14, pinned by SHA-256 in `gradle-wrapper.properties` |
| Android Gradle Plugin | 8.11.1 |
| Kotlin | 2.2.20 |
| JDK | 17 (Temurin in CI) |

`.flutter-version` is what CI reads, so the pin cannot drift from what is
documented. `pubspec.lock` is committed, so dependency resolution is fixed.

Bump these deliberately, in their own commit, and record new hashes in the
release that follows.

> The Gradle distribution hash was computed from a local cache rather than
> fetched from gradle.org. Cross-check it against
> <https://gradle.org/release-checksums/> before relying on it.

## Verifying a release

```bash
scripts/verify_build.sh 0.4.8
```

It checks your toolchain matches, downloads the release's `SHA256SUMS.txt`,
checks out that tag, rebuilds, and reports MATCH or DIFFERS per APK. No keys and
no special access required.

## The CI check

The `reproducible` job builds the same commit twice on one runner and fails if
the bytes differ. That tests **determinism** — that the build does not bake in a
timestamp, an absolute path, or a random iteration order.

It does not by itself prove that a *different* machine produces the same bytes.
That additionally requires the pinned toolchain above to actually be honoured,
which is why it is pinned rather than floating, and ultimately wants a container
image — see below.

## Known and expected causes of a mismatch

If a comparison fails, these are the usual reasons, roughly in order:

1. **A different Flutter or Dart version.** By far the most common. Check
   `flutter --version` against `FLUTTER_TOOLCHAIN`.
2. **Signing.** Release APKs are signed with a keystore only the maintainer
   holds, so a rebuild is unsigned and the signature block differs. Compare the
   unsigned contents, or use `apksigner verify --print-certs` to separate the
   two questions. This is a known limitation of the current script.
3. **Absolute paths.** Dart AOT and native builds can embed the build directory.
   Building from the same relative path avoids it; `--split-debug-info` reduces
   what is embedded.
4. **A different NDK or build-tools revision** pulled by the Android SDK
   manager, which resolves versions rather than pinning them.
5. **Timestamps** in the APK zip. AGP normalises these, but a plugin that writes
   its own archive may not.

## Not done

- **No container image.** Cross-machine reproducibility realistically needs a
  pinned Docker image with the exact SDK, NDK and JDK. That is the next step and
  is the difference between "deterministic on one runner" and "anyone can
  independently reproduce this".
- **Signed-vs-unsigned comparison** is not handled by `verify_build.sh`; it
  compares whole APKs, so a signed release will always differ from a local
  rebuild. Comparing the unsigned artifact, or diffing zip entries excluding
  `META-INF/`, is the fix.
- **No F-Droid metadata.** F-Droid builds from source and would give independent
  verification by a third party, which is worth more than self-attestation.
