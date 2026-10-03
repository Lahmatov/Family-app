---
name: lean-code
description: >
  Write the least code that is correct for this repo (Swift/SwiftUI iOS app,
  FamilyCore package, Supabase/Postgres with RLS). Climb a reuse ladder before
  writing anything: does it need to exist, is it already in FamilyCore or the
  app, does Swift/Foundation/SwiftUI/iOS or Postgres do it natively. Never trades
  away the security and money rules listed below. Use on ANY coding task in
  this repo: new feature, migration, view, fix, refactor, review, or choosing
  a dependency. Also when the user says "lean", "ponytail", "проще", "меньше
  кода", "без оверинжиниринга", or asks to review/audit for bloat
  ("/lean-code review", "/lean-code audit"). Not for non-coding requests.
argument-hint: "[review|audit]"
---

# Lean code

Adapted from [ponytail](https://github.com/DietrichGebert/ponytail) (MIT, © 2026 DietrichGebert)
for this project. Lazy means efficient, not careless: the best code is the code
never written. Read the task and every file it touches first, then climb.

## The ladder — stop at the first rung that holds

1. **Does it need to exist?** Speculative need → skip, say so in one line.
2. **Already in this repo?** Look before writing. The usual suspects:
   - Money & dates: `Money` (minor units, parsing, formatting), `CurrencyConverter`,
     `CurrencyCode`, `LocalDate`, `YearMonth` — `FamilyCore/Sources/FamilyCore`.
   - Budget math: `BudgetCalculator`, `BudgetStatus`, `TransactionDraft.validate`.
   - Access: `MemberRole.can(_:)`, `ApprovalPolicy` (client); `private.has_role`,
     `private.require_role`, `private.require_mfa`, `private.audit`, `request_action`
     (DB). New critical action = new `approval_action` value, not a new RPC.
   - App plumbing: `AsyncAction` + `.errorAlert`, `mapError`, `Services` protocols
     with `Live*` / `InMemory*`, `AppModel.refresh()`.
   - Tests: `tests.create_user / login / logout / add_member / create_family /
     category / set_id / id` in `supabase/tests/000_helpers.test.sql`.
3. **Swift / Foundation does it?** `Dictionary(grouping:)`, `FormatStyle`,
   `Decimal` + `NSDecimalRound`, `Codable` with `CodingKeys`.
4. **Platform does it?**
   - SwiftUI/iOS: `ContentUnavailableView`, `PhotosPicker`, `.refreshable`,
     `.textContentType(.oneTimeCode)`, `LocalAuthentication`, String Catalog,
     per-app language in iOS Settings, `@Observable`.
   - Postgres: `CHECK`, composite FK (family + kind), column-level `GRANT`, RLS
     policy, `unique nulls not distinct`, trigger — over app code. A rule the
     DB enforces needs no duplicate server check.
   - Supabase: Auth MFA, Storage policies, PostgREST filters, `upsert(onConflict:)`.
5. **Installed dependency does it?** Only FamilyCore and supabase-swift (2.x).
   No new dependency without asking the user.
6. **One line?** One line.
7. **Only then:** the minimum code that works.

**Bug fix = root cause.** Grep every caller first; one guard in the shared
function beats a guard in each caller.

## Rules

- No protocol with one implementation, unless it is a test seam we use (the
  `Services` protocols are; the in-memory backend drives UI tests).
- No config for constants, no scaffolding "for later", no wrapper that only delegates.
- Deletion over addition; fewest files; shortest correct diff.
- Domain logic goes to `FamilyCore` (testable on Linux), not into views.
- Views stay thin: state in an `@Observable` model only when a view outgrows `@State`.
- Mark a deliberate shortcut with its ceiling:
  `// lean: linear scan, index by id if lists exceed ~1k`.
- Complex ask → ship the lean version and name what was skipped in one line.

## Never simplify away (this repo's non-negotiables)

- **Every new table:** `enable row level security`, explicit `revoke all … from anon, authenticated`
  then minimal `GRANT`s (column-level for insert/update), policies via
  `private.has_role(...)` — which already enforces MFA (`aal2`).
- **Every `SECURITY DEFINER` function:** `set search_path = ''`, fully qualified
  names, `revoke all … from public, anon`, check role/MFA first.
  `001_security_baseline` fails the build otherwise.
- Membership/role changes only through RPC + `private.audit`; critical ones through
  `request_action` (second admin).
- Money is `Int64` minor units + currency; never `Double`. Server computes derived
  amounts; client mirrors the rounding in `FamilyCore`.
- Private data stays private (`is_private`, attachments follow parent visibility).
- Errors shown to users go through `mapError` → `AppError`; never server text,
  never log secrets/tokens/TOTP.
- Images re-encoded on device (strips EXIF/GPS) before upload.
- Every user-facing string in `Localizable.xcstrings` for **en, ru, pt-PT**.
- Accessibility identifiers on controls that UI tests drive.
- GitHub Actions pinned to a full commit SHA (`uses: owner/action@<sha> # vX.Y.Z`), `permissions: contents: read`.

## Tests — one runnable check, not a suite

- New policy / RPC → one pgTAP file or block: the allowed case and the
  forbidden case (other family, lower role, `aal1`). Use the helpers.
- New logic in FamilyCore → a focused XCTest. If the DB computes the same
  number, use the same numbers in both tests.
- Trivial one-liners need no test. Run before committing:
  `./scripts/db-test.sh`, `(cd FamilyCore && swift test)`.

## Output

Code first, then at most three short lines: what was skipped, when to add it.
Pattern: `[code] → skipped: X, add when Y.` Requested explanations are given in full.

## Review / audit mode

`/lean-code review` (current diff) or `/lean-code audit` (whole repo): list
complexity only, one line each, biggest cut first, apply nothing.

`<file>:L<line>: <tag> <what>. <replacement>.`

Tags: `delete:` dead/speculative · `stdlib:` hand-rolled Swift/Foundation ·
`native:` SwiftUI/iOS/Postgres/Supabase already does it · `yagni:` one-implementation
abstraction, unused config · `shrink:` same logic, fewer lines (show it) ·
`reuse:` duplicates something already in the repo (name it).

End with `net: -<N> lines possible.` or `Lean already. Ship.`
Never flag the non-negotiables or the single check as bloat. Correctness and
security bugs are out of scope here — use `/code-review` or `/security-review`.
