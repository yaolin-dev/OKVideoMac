# ADR 0002: Storage and Input Boundaries

- Status: Accepted
- Date: 2026-07-29

## Decision

Use system SQLite3 behind an actor and repository interfaces. Enable WAL,
foreign keys, parameter binding, transactions, and `PRAGMA user_version`
migrations.

Treat every configuration, HTTP response, playlist, XMLTV document, and
Spider result as untrusted. Apply byte limits and timeouts before decoding,
retain unknown configuration fields as recursive `JSONValue`, and redact
sensitive headers from logs.

## Consequences

The application has no ORM dependency and owns its migration behavior.
Callers cannot bypass the input and persistence policies without crossing an
explicit protocol boundary.
