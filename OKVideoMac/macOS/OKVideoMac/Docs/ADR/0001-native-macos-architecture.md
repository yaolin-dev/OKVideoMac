# ADR 0001: Native macOS Architecture

- Status: Accepted
- Date: 2026-07-29

## Decision

Use SwiftUI with focused AppKit wrappers. Keep protocol, persistence, network,
site, live, resolver, spider, and player abstractions in the local
`OKVideoKit` Swift Package. The App target owns feature state and view
composition.

Use `NavigationSplitView` on macOS 13 or newer and a state-compatible
`NavigationView` column layout on macOS 12.

## Consequences

Core behavior can be tested without launching the App. Platform integrations
remain replaceable behind protocols. Supporting macOS 12 requires explicit
availability branches and excludes newer-only SwiftUI APIs from shared paths.
