# FongMi/TV `catvod` Source and Changes

- Upstream repository: <https://github.com/FongMi/TV>
- Fixed upstream commit: `5fdff00a602dc56e8ba756174daef20edab024f2`
- Original path: `catvod/src/main`
- Local copied path: `Helpers/AndroidDexBridge/catvod/src/main`
- Original and local license: `GPL-3.0-only`
- Copy/change baseline: OKVideoMac 0.3.20, committed 2026-08-08
- Source availability: the complete local corresponding source is tracked at
  the local path above; the fixed original is available at the upstream commit.

## Actual differences from upstream

`catvod/src/main/java/com/github/catvod/net/Proxy.java` changes the initial
proxy port from `-1` to `9978`. A four-line local comment explains that the
macOS Android bridge requires a stable emulator port and that runtime startup
may later override the value. `catvod/src/main/AndroidManifest.xml` differs
only by a final newline.

No upstream copyright or license header is replaced. The directory is copied
and modified FongMi/TV source and remains governed by `GPL-3.0-only`.
