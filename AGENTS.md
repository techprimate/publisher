# AGENTS.md

`techprimate/publisher` — the single, serialized write path that turns a project's
GitHub Release into signed rpm/deb/Homebrew/raw packages and publishes them to
the R2-backed registry at `packages.techprimate.com`.

## Hard constraints

- **Code and config only — never artifacts.** Do not commit `.rpm`, `.deb`,
  binaries, or registry metadata (`repodata/`, `dists/`). Those live in R2.
- **This is the org's most sensitive repo.** It holds the GPG signing key and
  the R2 write token. Never commit secrets or keys — they live in GitHub repo
  secrets and are referenced by name only.
- **Published versions are immutable.** Keep publish steps convergent and
  overwrite-safe; on a checksum mismatch for an already-published version, fail
  loudly rather than overwriting (see spec § Idempotency).
- **No metadata bleed.** Package descriptions/changelogs are templated
  explicitly in `nfpm.yaml`, never auto-derived from private git history.

## Onboarding a project

Add `packages/<source-repo>/manifest.yaml` and the configured Homebrew formula
template. For projects that publish Linux packages, also add `nfpm.yaml`, a
section to `repo/techprimate.repo`, and a stanza to `repo/techprimate.sources`.
Have the project's release workflow trigger this workflow. No registry access is
granted to project repos.
