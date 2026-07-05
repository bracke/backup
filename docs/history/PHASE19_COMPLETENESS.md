# Phase 19 Completeness Notes — Encryption Envelope

Phase 19 implements whole-archive encryption as an envelope around the ZIP
payload produced by the existing writer. The ZIP writer, verifier, restorer,
and incremental planner continue to operate on ordinary ZIP bytes after the
archive has been authenticated and decrypted.

## Implemented

- Added `Backup.Encryption`.
- Added a Phase 19 archive envelope with:
  - magic marker `BACKUP-ENC-19`,
  - cipher identifier,
  - salt,
  - nonce,
  - plaintext-size metadata,
  - authentication tag,
  - encrypted ZIP payload.
- Added CLI parsing for:
  - `--encrypt`,
  - `--password-file FILE`,
  - `--password-file=FILE`,
  - `--password-env NAME`,
  - `--password-env=NAME`,
  - `--cipher aes256-gcm`,
  - `--cipher=aes256-gcm`.
- Added validation that rejects `--encrypt --deterministic`.
- Added validation that `--encrypt` requires a password source.
- Added validation that only one password source may be selected.
- Added validation that `--cipher` is only accepted with `--encrypt`.
- Added validation that password-source options are rejected for ordinary
  unencrypted archive creation, while still allowing them for encrypted verify,
  extraction, and archive-based incremental planning.
- Wired archive creation so the normal ZIP is written to a temporary plaintext
  file and then wrapped in the encrypted envelope.
- Wired verification so encrypted input is decrypted to a temporary ZIP only
  after authentication succeeds.
- Wired extraction so encrypted input is authenticated and decrypted before any
  restored file is written.
- Wired archive-based incremental planning so encrypted prior archives are
  authenticated and decrypted before metadata is read.
- Added JSON reporting metadata for encrypted archive creation.
- Added `backup_encryption_tests.adb`.
- Added explicit wrong-password, ciphertext-tamper, and header-tamper
  authentication checks.
- Updated `backup_tests.gpr` to include the encryption tests.

## Security boundary

`Backup.Encryption` now uses the sibling `cryptolib` AES-256-GCM and
BCrypt-PBKDF implementations for the password-based archive envelope. The
backup crate owns envelope parsing, password-source plumbing, diagnostics, and
temporary-file control flow; cryptographic primitives remain in `cryptolib`.

The implementation preserves the Phase 19 operational contract:

- authenticate the envelope metadata and ciphertext before exposing plaintext
  ZIP bytes to verifier, extractor, or incremental planner;
- enforce the recorded plaintext size as authenticated metadata;
- remove stale plaintext targets before attempted decryption;
- never write restored output before authentication succeeds;
- never include password material in diagnostics or JSON output;
- reject unsupported ciphers explicitly;
- distinguish malformed envelope, missing password, and authentication failure.

## Not implemented in Phase 19

- Multiple recipient keys.
- Public-key encryption.
- Deterministic encrypted archives. This is intentionally rejected because
  deterministic encryption would be unsafe for the intended password-based
  envelope design.

## Completeness pass updates

- Restored `--ignore` parsing after the new `--cipher` parsing branch.
- Added explicit rejection of empty `--cipher=` values.
- Ensured extraction cleans up temporary decrypted ZIP files on success and on
  failure paths.
- Avoided a local `Length` variable hiding `Ada.Strings.Unbounded.Length` in
  encrypted extraction diagnostics.
- Tightened modular-byte casts in the envelope implementation and tamper test.

## Second completeness pass updates

- Bound the authentication tag to envelope metadata, including cipher name,
  salt, nonce, and plaintext-size metadata, instead of authenticating only the
  decrypted payload bytes.
- Parsed and enforced `plain-size` during decryption.
- Added malformed metadata checks for salt, nonce, tag, and `plain-size`.
- Removed stale plaintext output targets before decryption attempts so failed
  authentication cannot leave an old decrypted ZIP at the requested temporary
  path.
- Removed partial plaintext output if the final authenticated plaintext write
  fails.
- Added header-tamper test coverage.
- Added stale plaintext cleanup checks for wrong-password and header-tamper
  failures.
- Rejected password-source options for ordinary unencrypted archive creation so
  secrets are not accepted when they cannot affect the command.

## Validation status

This pass updated the supplied Phase 18 source tree directly and then performed
additional Phase 19 completeness passes. The container still lacks `gprbuild`,
and GCC cannot invoke `gnat1`, so Ada compilation and AUnit execution could not
be verified here. The package ZIP was verified with `unzip -tq`.

## Third completeness pass updates

- Fixed a syntax regression in `backup_encryption_tests.adb` where the first
  CLI parse fixture had duplicated positional arguments outside the `Args`
  call.
- Replaced predictable decrypted/plaintext temporary archive names with
  collision-avoiding names that select an unused suffixed path before writing.
  This avoids deleting unrelated sibling files that happen to use the old
  `.phase19-decrypted.zip` or `.phase19-plain.zip` names.
- Changed encrypted archive creation to write the encrypted envelope to a
  temporary file first, then move it to the requested output path only after
  envelope creation succeeds. This avoids truncating an existing output archive
  during failed envelope generation.

## Correctness pass updates

- Changed `Decrypt_File` so ordinary non-envelope files return
  `Envelope_Not_Encrypted` before requiring a password source and before
  touching the requested plaintext target.
- Preserved stale plaintext targets for the not-encrypted case while still
  deleting stale plaintext targets for encrypted-envelope decrypt attempts that
  fail authentication or metadata validation.
- Tightened envelope header-field parsing so metadata is only read from actual
  line-start fields, not from arbitrary substrings inside another header line.
- Added a non-envelope decrypt regression test that verifies an existing target
  is not deleted.
- Added explicit non-empty validation for the separate-argument
  `--password-file FILE` form.
- Included the full calendar date in the original Phase 19 salt/nonce time
  material instead of using only seconds within the current day.

Correctness pass 2 notes
------------------------

This pass tightened encrypted output replacement and temporary plaintext cleanup:

* encrypted archive replacement now preserves an existing output archive by first
  moving it aside, then restoring it if the final rename of the encrypted
  temporary file fails;
* failed final replacement no longer deletes the encrypted temporary file, so the
  newly produced encrypted archive is not silently discarded on rename failure;
* verification now deletes the temporary decrypted ZIP even if verification raises
  unexpectedly after decryption succeeds.

Correctness pass 3 notes
------------------------

This pass tightened envelope detection and temporary cleanup:

* encrypted archive detection now requires the exact Phase 19 magic line
  `BACKUP-ENC-19\n`, not merely a file whose contents begin with the magic
  bytes;
* `Decrypt_File` now applies the same exact magic-line check before treating a
  file as an encrypted envelope, preserving ordinary files that merely share the
  magic prefix;
* zero-length plaintext reads are handled explicitly by the envelope file reader
  instead of depending on null-array `Stream_IO.Read` behavior;
* archive-based incremental planning now removes temporary decrypted ZIP files
  if prior-archive verification raises unexpectedly after decryption succeeds;
* added regression coverage for magic-prefix non-envelope files and empty
  plaintext envelope round trips.

Correctness pass 4 notes
------------------------

This pass tightened envelope metadata correctness:

* decryption now requires the serialized Phase 19 header to match the canonical
  header layout exactly after parsing `cipher`, `salt`, `nonce`, `plain-size`,
  and `tag` fields;
* unexpected inserted header metadata, duplicate/reordered header lines, or
  equivalent non-canonical serialization are rejected as malformed before any
  plaintext is written;
* added regression coverage for an unexpected inserted header line and stale
  plaintext target cleanup on that failure path.

Correctness pass 5 notes
------------------------

This pass fixed a compile-blocking regression introduced in the encrypted
verification helper:

* `Prepare_Archive_For_Read` in `backup-workflow.adb` no longer contains a
  duplicated, incomplete `Status := Backup.Encryption.Decrypt_File` statement;
  the helper now has a single complete decrypt call before cleanup/error
  handling.

## Missing-tests pass

This pass added focused Phase 19 regression coverage for implemented behavior that was not previously tested:

- CLI equals-form password and cipher options.
- CLI rejection of missing encryption password source.
- CLI rejection of duplicate password sources.
- CLI rejection of empty equals-form password/cipher options and unsupported cipher values.
- Direct password resolution failures for missing source, empty password file, and missing environment variable.
- Malformed envelope header terminator cleanup behavior.
- Malformed metadata rejection for non-hex salt and non-decimal plain-size.
- Unsupported envelope cipher rejection and stale plaintext cleanup.

This coverage originally guarded the Phase 19 stand-in primitive; the envelope
has since been moved to `cryptolib` AES-256-GCM with BCrypt-PBKDF.

## Second missing-tests pass

This pass added additional Phase 19 regression coverage for behavior that was
implemented but still under-tested:

- End-to-end encrypted archive creation through `Backup.Workflow.Execute`.
- Encrypted workflow output is detected as a Phase 19 envelope and does not
  expose ZIP filenames in cleartext.
- Encrypted archive verification succeeds with the correct password source.
- Encrypted archive verification without a password source fails through the
  encryption failure path before ZIP parsing.
- Encrypted archive extraction succeeds with the correct password source and
  restores regular files.
- Encrypted `--list-json` archive creation reports only encryption metadata
  (`enabled`, `cipher`, and password source kind) and does not leak password file
  paths or password contents.
- CLI rejection of empty equals-form `--password-file=`.
- CLI rejection of empty separate-form `--password-env NAME` when `NAME` is
  empty in the argument vector.
- Successful password resolution from a present environment variable.
- Malformed envelope metadata rejection for non-hex nonce and non-hex tag.
- Duplicate envelope header field rejection and stale plaintext cleanup.

## Third missing-tests pass

This pass added additional test coverage for Phase 19 behavior that was already
implemented but still lacked direct regression tests:

- encrypted workflow verification with a wrong password fails through the
  encryption/authentication path;
- encrypted workflow extraction without a password source fails before payload
  files are restored;
- encrypted `--list-json` creation using `--password-env` reports only the
  source kind `env` and does not leak the environment variable name or value;
- workflow-level archive-based incremental planning can read an encrypted prior
  archive when the correct password source is supplied;
- workflow-level archive-based incremental planning rejects an encrypted prior
  archive when no password source is supplied and does not create the successor
  archive;
- direct password resolution rejects an environment variable that exists but has
  an empty value;
- direct encryption of a missing plaintext file reports an open failure and does
  not create an envelope output;
- direct decryption of a missing encrypted file reports an open failure and does
  not delete an existing plaintext target.

These tests predate the AES-256-GCM/BCrypt-PBKDF replacement and continue to
guard the same authentication-before-use behavior.

## Fourth missing-tests pass

This pass added further Phase 19 regression coverage for behavior that was
implemented but still lacked direct tests:

- separate-form supported `--cipher aes256-gcm` parsing;
- equals-form unsupported `--cipher=bogus` rejection;
- parse-time rejection of `--verify --encrypt` and `--extract --encrypt`;
- allowing password sources with `--incremental-from` for encrypted prior
  archives;
- CRLF trimming for password files;
- `Is_Encrypted` returning false for missing files;
- direct encryption with no password source preserving an existing output file;
- direct decryption of encrypted input with no password source removing stale
  plaintext targets;
- malformed/missing envelope metadata field rejection and stale cleanup;
- plaintext-size metadata tamper rejection;
- encrypted dry-run JSON reporting without archive creation;
- encrypted archive creation replacing an existing output path with an envelope;
- encrypted manifest archive creation and verification;
- encrypted extraction with a wrong password not restoring payload files;
- encrypted archive-based incremental planning with a wrong password not
  creating the successor archive.

The validation boundary is unchanged: this package was repacked and ZIP-tested,
but Ada compilation and AUnit execution still require a GNAT/gprbuild-enabled
environment.

## Fifth missing-tests pass

This pass added further regression coverage for Phase 19 behavior that was
implemented but still lacked direct tests:

- encrypted verification with `--list-json` and a correct password source;
- successful encrypted verification cleanup of the temporary decrypted ZIP;
- encrypted extraction in `--dry-run --list-json` mode without restoring payload
  files;
- successful encrypted extraction cleanup of the temporary decrypted ZIP;
- unencrypted archive verification with an unused password source;
- unencrypted archive extraction with an unused password source;
- unencrypted archive-based incremental planning with an unused password source.

These tests specifically guard the intended compatibility behavior: password
sources are accepted for read-side operations because the archive may be
encrypted, but they must not break ordinary unencrypted archives.

## Sixth missing-tests pass

This pass added further Phase 19 regression coverage for behavior that was
implemented but still lacked direct tests:

- direct decryption of an empty non-envelope file reports `Envelope_Not_Encrypted`
  and preserves an existing plaintext target;
- a file containing only the Phase 19 magic line is classified as an encrypted
  envelope, then rejected as malformed and stale plaintext is removed;
- encrypted verification can read the password from `--password-env`;
- encrypted extraction can read the password from `--password-env` and restores
  the expected payload files;
- encrypted archive-based incremental planning can read the prior archive
  password from `--password-env` and writes the successor archive.

The validation boundary is unchanged for this historical pass: the package was
repacked and ZIP-tested, but Ada compilation and AUnit execution still required
a GNAT/gprbuild-enabled environment.

## AES-GCM replacement pass

- Replaced the Phase 19 FNV/XOR stand-in transform with `cryptolib`
  AES-256-GCM sealing/opening and `cryptolib` BCrypt-PBKDF key derivation.
- Added production random salt and nonce generation through `cryptolib`.
- Extended the envelope header with explicit `kdf` and `rounds` metadata while
  preserving the existing `aes256-gcm` CLI cipher name.
- Kept metadata tamper, ciphertext tamper, wrong-password, empty-payload, and
  stale-output cleanup behavior under the existing encryption tests.
- Fixed `cryptolib` AES-GCM opening of tag-only packets so empty plaintext
  envelopes round-trip through the reviewed primitive path.

## Missing-tests pass 7

Added direct envelope write-failure regression coverage:

- encrypting to an output path that is a directory reports `Envelope_Write_Failed`;
- the failed encrypted write does not remove the existing directory at the requested output path;
- decrypting to a plaintext output path that is a directory reports `Envelope_Write_Failed`;
- the failed decrypted write does not remove the existing directory at the requested plaintext path.

This covers the direct envelope I/O failure branches that were previously only indirectly represented by broader workflow ZIP writer failures.

## Missing-tests pass 8

Added further direct regression coverage for Phase 19 behavior that was
implemented but still lacked focused tests:

- direct helper coverage for `Cipher_Name`, `Parse_Cipher`, and selected
  `Status_Text` strings used in workflow diagnostics;
- non-canonical cipher spelling rejection through the direct cipher parser;
- encrypted archive creation when the configured password file is unreadable;
- preservation of an existing output archive when encrypted creation fails
  during password resolution;
- cleanup of plaintext/encrypted temporary files after that failed encrypted
  creation path;
- collision handling for the first generated `.phase19-plain.zip.0` and
  `.phase19-encrypted.tmp.0` temporary names;
- preservation of preexisting files that merely look like Phase 19 temporary
  candidates;
- cleanup/move behavior for alternate temporary names selected after a collision.

The validation boundary is unchanged: the package was repacked and ZIP-tested,
but Ada compilation and AUnit execution still require a GNAT/gprbuild-enabled
environment.

## Ada correctness pass

This pass focused on Ada source-level correctness rather than adding Phase 19
features or tests.

- corrected the `Ada.Calendar.Split` seconds actual in `Backup.Encryption` to
  use `Ada.Calendar.Day_Duration`, matching the standard `Split` profile;
- updated the corresponding image conversion to use
  `Ada.Calendar.Day_Duration'Image` instead of `Duration'Image`;
- repacked the project and verified ZIP container integrity.

The validation boundary is unchanged: the package was repacked and ZIP-tested,
but Ada compilation and AUnit execution still require a GNAT/gprbuild-enabled
environment.

## Ada keyword identifier pass

Performed an Ada reserved-word identifier scan across `src/*.ads`, `src/*.adb`, and `tests/*.adb`.

Scope checked:

- local object declarations
- formal parameters
- comma-separated declarations
- loop parameters
- subprogram declarations
- type and subtype declarations

Result:

- No Ada reserved words were found being used as variable names, parameter names, loop variables, type names, subtype names, or subprogram names.
- Existing reserved words observed by the scan were normal Ada syntax, such as `package body`, `when others`, and string literal text, not identifiers.

## Conditional expression formatting pass

Performed a formatting pass over Ada conditional expressions in `src/*.ads`,
`src/*.adb`, and `tests/*.adb`.

Result:

- Reflowed one-line conditional expressions so the `then` token in each
  conditional expression is followed immediately by a line feed.
- Reflowed existing multi-line conditional expressions whose first branch
  expression previously appeared on the same line as `then`.
- Verified by scan that no remaining source or test line contains a conditional
  expression introducer with `then` followed by branch text on the same line.

This was a formatting-only pass. The validation boundary is unchanged: the
package was repacked and ZIP-tested, but Ada compilation and AUnit execution
still require a GNAT/gprbuild-enabled environment.
