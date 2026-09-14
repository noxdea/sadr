# ADR 001: Keep editor documents outside Sadr

- Status: Accepted
- Date: 2026-09-14

## Context

An LSP client needs document text, versions, and UTF-16 positions. Depending on
an editor buffer or rope would couple protocol transport to one application.

## Decision

Accept immutable URI-based documents and changes. Accept text indexes through
the five operations required for UTF-16 conversion, without a runtime gem
dependency.

## Consequences

Sadr can be embedded in any Ruby application. Callers remain responsible for
their editor model and for applying server text edits.
