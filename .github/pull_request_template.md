Fixes #<issue>

## Summary
- describe the user-visible change
- call out the root cause or architecture delta when relevant

## Testing
- [ ] `swift test`
- [ ] Additional validation noted below when needed

## Validation Status
- [x] Not runtime-sensitive
- [ ] macOS runtime validation pending
- [ ] macOS runtime validation complete

## Docs Sync Check (issue #230)
- [ ] If this PR touches toggle / activation / event tap / persistence behavior, the relevant `AGENTS.md` and `docs/architecture.md` sections still describe the new behavior accurately (or have been updated in this PR).
- [ ] No new references to `docs/archive/` as a current source of truth.

## Notes
- Keep exactly one `Validation Status` checkbox selected.
- If the PR touches runtime-sensitive files, the PR metadata workflow will reject `Not runtime-sensitive`.
