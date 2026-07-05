# CLI Compatibility Policy

`backup` treats `docs/CLI_SURFACE.md` as the generated public command-line
contract. The contract is generated from `tools/cli_surface.conf` and checked by
`tools/bin/check_cli_surface`; update the model first, then regenerate derived
files.

## Stable Surface

Released long options, command modes, value names, and conflict-group behavior
are stable within a major version. Scripts may rely on documented options in
`docs/CLI_SURFACE.md`, the installed man page, and shell completions agreeing
with each other.

## Additions

New options, command modes, enum values, and completion values may be added in a
minor release when they do not change the meaning of existing invocations. New
options must be added to `tools/cli_surface.conf` so help, man page,
completions, and the generated surface contract stay in sync.

## Deprecations

Renaming or removing a released option requires a deprecation period. Keep the
old spelling accepted by the parser, document the replacement, and keep shell
completion coverage for the old spelling until the next major release. Diagnostic
text may change, but diagnostics should keep the same failure class and should
continue to name the conflicting option family.

## Breaking Changes

A major release is required to remove a released option, change positional
semantics for a command mode, remove an enum value, or weaken a documented
conflict-group guarantee. The release notes must identify the affected rows in
`docs/CLI_SURFACE.md`.

## Non-Contractual Behavior

Debug wording, ordering of JSON object fields not documented elsewhere, local
filesystem error text from the runtime, and skipped optional local completion
smokes are not compatibility guarantees. CI completion checks are part of release
readiness.
