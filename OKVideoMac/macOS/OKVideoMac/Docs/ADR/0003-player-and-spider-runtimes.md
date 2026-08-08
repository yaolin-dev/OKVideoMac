# ADR 0003: Player and Spider Runtimes

- Status: Accepted, integration pending
- Date: 2026-07-29

## Decision

Use libmpv v0.41.0 through the render API and an `NSOpenGLView` host. Use
QuickJS 2025-09-13-2 for JavaScript Spider execution with a 64 MiB memory
limit, ten-second interrupt deadline, isolated runtime per site, and a
whitelisted HTTP bridge.

The SwiftUI feature layer depends only on `PlayerClient`, `SpiderEngine`, and
`SpiderRuntime`. It must not call native C APIs directly.

## Consequences

Native wrappers can be built and verified independently. Until those wrappers
are linked, the application exposes explicit unavailable/unsupported states
instead of claiming playback or Spider compatibility.
