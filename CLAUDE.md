# Family App — notes for Claude

- Write code with the `lean-code` skill (`.claude/skills/lean-code`): reuse ladder first, security rules never simplified.
- Layout: `FamilyCore/` domain logic (Linux-testable), `ios/` SwiftUI app (XcodeGen), `supabase/` migrations + pgTAP tests, `docs/` (Russian).
- Before committing: `./scripts/db-test.sh` and `(cd FamilyCore && swift test)`. iOS builds/tests run in CI (`.github/workflows/ios.yml`).
- Talk to the user in Russian; code, comments and commit messages in English.
