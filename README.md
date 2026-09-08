# techprimate Release Registry Publisher

`techprimate/publisher` is the single, serialized write path that turns a
project's GitHub Release into installable packages and publishes them to the
public techprimate release registry at `packages.techprimate.com`.

It publishes:

- signed RPM packages for dnf/yum
- DEB packages with signed apt metadata
- Homebrew formula updates
- raw, version-pinned binaries

## Model

The registry flow has three parts:

1. Project repos, such as `techprimate/apple-docs-cli`, build binaries and publish
   them to their own GitHub Release.
2. This publisher repo downloads those release assets, packages them, signs
   packages and metadata, updates indexes, syncs to Cloudflare R2, and opens a
   Homebrew tap PR.
3. Cloudflare R2 serves the passive public registry at `packages.techprimate.com`.

Project repos do not receive registry credentials. This repo is the only holder
of the GPG signing key and R2 write token.

## Repository Layout

```text
.
|-- .github/workflows/
|   |-- publish.yml       # workflow_dispatch entrypoint and serialized lock
|   |-- _registry.yml     # reusable rpm/deb/raw registry publish workflow
|   `-- _homebrew.yml     # reusable Homebrew formula publish workflow
|-- packages/
|   `-- apple-docs-cli/
|       `-- manifest.yaml   # product names, platforms, and package formats
|-- repo/
|   |-- techprimate.repo    # dnf/yum source
|   `-- techprimate.sources # apt deb822 source
|-- scripts/
|   `-- publish.sh        # build, sign, index, sync, purge
`-- templates/
    `-- apple-docs.rb     # Homebrew formula template
```

This repo must contain code and configuration only. Do not commit package
artifacts, binaries, generated registry metadata, signing keys, or secrets.

## Publish Flow

Publishing is triggered by `workflow_dispatch`:

```sh
gh workflow run publish.yml -R techprimate/publisher \
  -f source_repo=techprimate/apple-docs-cli \
  -f tag=v1.3.0
```

Inputs:

- `source_repo`: source repository containing the GitHub Release
- `tag`: release tag, for example `v1.3.0`

The top-level workflow uses `concurrency: { group: publish,
cancel-in-progress: false }`, so there is only one registry writer at a time.
The registry job runs first; the Homebrew job runs after registry publication
succeeds.

At a high level, `scripts/publish.sh` reads the source project's manifest,
downloads only its declared release assets, verifies immutable versioned paths,
and publishes raw binaries under `bin/v<version>/`. When `linux_packages` is
true, it also builds signed RPM and DEB packages, updates their indexes, and
publishes the shared repository metadata. macOS-only projects skip all Linux
packaging and GPG setup.

Homebrew publication is handled by `_homebrew.yml`: it reads the manifest and
SHA256 values from
the source release's `checksums.txt`, renders the matching formula template, and
opens an auto-merging PR against `techprimate/homebrew-tap`.

## Idempotency and Immutability

Publishing is designed to be safe to rerun for the same `(source_repo, tag)`.
Reruns converge to the same registry state when the source release is unchanged.

Published versions are immutable. Before uploading a version-pinned artifact,
the publish script checks whether that key already exists in R2. If the existing
object has different bytes, the run fails instead of overwriting it. This
protects consumers from moved tags or force-pushed releases.

Artifacts are uploaded before metadata that references them. A failed run can
leave old-but-valid metadata in place, but it should not publish metadata that
points to missing package bodies.

## Registry Layout

The public registry is served from Cloudflare R2:

```text
packages.techprimate.com/
|-- RPM-GPG-KEY-techprimate
|-- techprimate.repo
|-- techprimate.sources
`-- apple-docs/
    `-- bin/
        `-- v<version>/
            |-- apple-docs-darwin-amd64
            `-- apple-docs-darwin-arm64
```

Each project owns its own registry prefix. RPM trees split by `$basearch`, apt
uses `stable` as its suite, and raw binaries are stored under `bin/v<version>/`.

## End-User Install

Apple Docs CLI supports macOS and installs the `apple-docs` executable through
Homebrew:

```sh
brew tap techprimate/homebrew-tap
brew install apple-docs
```

## Required Secrets and Variables

The publisher workflow expects these GitHub Actions secrets:

- `TECHPRIMATE_RELEASE_BOT_PRIVATE_KEY`
- `CLOUDFLARE_ACCESS_KEY_ID`
- `CLOUDFLARE_SECRET_ACCESS_KEY`
- `CLOUDFLARE_API_TOKEN`
- `GPG_PRIVATE_KEY`
- `GPG_PASSPHRASE`

It expects this repository variable:

- `TECHPRIMATE_RELEASE_BOT_CLIENT_ID`

The GitHub App installation must grant repository contents access to source
repositories, plus contents and pull request write access to
`techprimate/homebrew-tap`. The workflows narrow each generated token to the
specific repository and permissions needed for that operation.

The registry workflow also defines the R2 bucket, R2 S3 endpoint, registry
domain, and Cloudflare zone ID in `.github/workflows/_registry.yml`.

Never commit real secret values, signing keys, or generated credentials. Refer
to secrets and variables by name only.

## Onboarding a Project

To publish another project:

1. Add `packages/<source-repo>/manifest.yaml` with its package name, binary name,
   release platforms, Linux-package flag, and Homebrew formula name.
2. Add the configured formula under `templates/`.
3. If `linux_packages` is true, add `packages/<source-repo>/nfpm.yaml`, a DNF
   section in `repo/techprimate.repo`, and an apt stanza in
   `repo/techprimate.sources`.
4. Ensure the source repo's release workflow triggers `publish.yml` with
   `source_repo` and `tag`.
5. Confirm that publishing the binary publicly is intended.

Package descriptions and changelogs must be explicit in `nfpm.yaml`. Do not
derive public package metadata from private git history.

## Local Development

Available make targets:

```sh
make help
make test
make format
```

`make format` runs `dprint fmt` over configured JSON, YAML, Markdown, TOML,
Dockerfile, CSS-like, and markup files.

Pre-commit hooks check formatting hazards, YAML and GitHub workflow syntax,
private keys, large files, and shell scripts.

Local end-to-end publishing requires real source releases, GitHub App access,
Cloudflare R2 credentials, Cloudflare cache purge credentials, and the GPG
signing key. Prefer validating workflow/script changes in GitHub Actions unless
you are intentionally testing against the real registry boundary.

## Security Rules

- Keep collaborator access to this repo tight.
- Keep the GPG private key and R2 write token in GitHub secrets only.
- Keep source project repos free of registry credentials.
- Treat all published package versions as immutable.
- Do not commit `.rpm`, `.deb`, raw binaries, `repodata/`, `dists/`, or other
  generated registry contents.
- Re-read the design spec before changing publish logic, registry layout, or
  signing behavior.
