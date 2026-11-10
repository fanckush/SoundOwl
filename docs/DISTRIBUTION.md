# Distribution and release runbook

Everything needed to sign, notarize, release, and publish SoundOwl to Homebrew. This is the
operator guide. The automation lives in `.github/workflows/` and `scripts/build-release.sh`.

## One-time setup

### Repositories

1. Create `fanckush/SoundOwl` (public) and push `main`. Enable **Discussions** and **Private
   vulnerability reporting** (Settings › Security).
2. Create `fanckush/homebrew-soundowl` (public) with:
   - `packaging/homebrew/soundowl.rb` at `Casks/soundowl.rb`
   - `packaging/homebrew/bump.yml` at `.github/workflows/bump.yml`
   - `packaging/homebrew/README.md` as its README
3. Settings › Pages: source **GitHub Actions**. The site is served at
   `https://fanckush.github.io/SoundOwl/`; its links are relative, so it works under that path.
   To move it to a domain later, add `site/CNAME` with the domain, set it under Settings › Pages,
   and replace `https://fanckush.github.io/SoundOwl/` in `site/index.html`, `README.md` and the
   cask's `homepage`.

### The model package

The app downloads the model from a release on this repository. Publish it once per package
version, before the first app release. It must not become the "latest" release, because the
app's update feed and the README's download button both resolve `/releases/latest/`:

```sh
cd tools/model-export && uv run python export.py && cd ../..
shasum -a 256 tools/model-export/build/lavasr-v2-1.zip   # must match ModelRelease.swift
gh release create model-lavasr-v2-1 tools/model-export/build/lavasr-v2-1.zip \
  --repo fanckush/SoundOwl --prerelease --latest=false \
  --title "Model: LavaSR v2 (package 1)" \
  --notes "The voice model SoundOwl downloads on first launch. Built by tools/model-export from the pinned upstream LavaSR v2. Licenses inside the zip. You don't need to download this yourself."
```

The export is deterministic, so rebuilding it from the same pins gives the same checksum. Moving
the package to Hugging Face later is a URL change in `ModelRelease.swift`; the checksum stays.

### Apple (needs the abaka UG Developer account)

1. **Developer ID Application certificate.** Already in the login keychain as
   `Developer ID Application: Abaka UG (haftungsbeschrankt) (VS9RJDSTF7)`. Export it as a `.p12`
   with a password for CI.
2. **App Store Connect API key.** Users and Access › Integrations › Keys: generate a Developer
   key. Download the `.p8` once. Note the Key ID and Issuer ID. The SoloDisplay key works too.
3. **Team ID:** `VS9RJDSTF7`.

### Update signing key (Sparkle)

SoundOwl gets its own key. Installed apps check `appcast.xml` on the latest GitHub Release and
only install an update whose zip is signed by it.

1. Build the app once so the Sparkle package is fetched, then run `generate_keys`. It stores
   the private key in the login keychain (under a SoundOwl account name, so it doesn't collide
   with SoloDisplay's) and prints the public key:

   ```sh
   GK="$(find ~/Library/Developer/Xcode/DerivedData build -path '*artifacts/sparkle/Sparkle/bin/generate_keys' 2>/dev/null | head -1)"
   "$GK" --account soundowl
   ```

2. Put the printed public key in `Config/SoundOwl-Info.plist` as `SUPublicEDKey`, replacing
   `SPARKLE_PUBLIC_KEY_NOT_SET`, and commit it. A release build refuses to run while the
   placeholder is there, and the app keeps its updater switched off without a real key.
3. Export the private key with `"$GK" --account soundowl -x sparkle-private-key.txt`, store
   its contents as the `SPARKLE_PRIVATE_KEY` secret, and delete the file.

Keep a backup of the private key. If it is lost, installed copies can never verify an update
again, and everyone has to download the next version by hand.

### GitHub secrets (Settings › Secrets and variables › Actions)

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_CERT_P12` | base64 of the `.p12` (`base64 -i cert.p12 \| pbcopy`) |
| `DEVELOPER_ID_CERT_PASSWORD` | the `.p12` export password |
| `APPLE_TEAM_ID` | `VS9RJDSTF7` |
| `AC_API_KEY_ID` | App Store Connect Key ID |
| `AC_API_ISSUER_ID` | App Store Connect Issuer ID |
| `AC_API_KEY_P8` | base64 of the `.p8` key file |
| `SPARKLE_PRIVATE_KEY` | SoundOwl's update signing key from `generate_keys -x` |
| `TAP_REPO_TOKEN` | fine-grained PAT with Actions: write on `fanckush/homebrew-soundowl` |

`TAP_REPO_TOKEN` must be able to dispatch into the tap. A token scoped to the wrong repo lets a
release build, sign and publish, then fail on its last step.

## Building by hand

Dry run (archive, export, sign with Developer ID, verify nested code; no Apple round-trip):

```sh
VERSION=0.1.0 DEVELOPMENT_TEAM=VS9RJDSTF7 scripts/build-release.sh --skip-notarize
```

Full local release (notarized):

```sh
xcrun notarytool store-credentials soundowl-notary \
  --key /path/AuthKey_XXXX.p8 --key-id KEYID --issuer ISSUER-UUID
VERSION=0.1.0 DEVELOPMENT_TEAM=VS9RJDSTF7 NOTARY_PROFILE=soundowl-notary \
  SPARKLE_PRIVATE_KEY="$(cat sparkle-private-key.txt)" scripts/build-release.sh
```

Local Debug and Release builds are ad-hoc signed without the hardened runtime: an ad-hoc app
under the hardened runtime refuses to load the embedded ONNX Runtime and Sparkle frameworks.
`build-release.sh` turns the hardened runtime on together with the Developer ID identity and then
checks that every nested binary carries the team ID.

## Cutting a release

**The first release** has no earlier tag to count from, so it is tagged by hand:

```sh
git tag -a v0.1.0 -m "v0.1.0"
git push origin v0.1.0
```

**Every release after that:**

1. Land Conventional Commits on `main`.
2. Open **Actions › Release › Run workflow**, select `main`, and run it. There is no version input.
3. The workflow calculates the next version from commits since the latest `vMAJOR.MINOR.PATCH`
   tag. It runs the package tests and the parity check against the published model, builds,
   signs, notarizes and staples the app, and uploads:
   - the `.zip` and `.dmg` with their checksums;
   - an unversioned `SoundOwl.dmg`, which is what the README and website download buttons point
     at;
   - `appcast.xml`, the update feed installed apps read.
4. It creates the tag and GitHub Release only after the artifacts are ready, then dispatches the
   Homebrew tap bump. The Pages workflow redeploys the site with the new version.

Version changes follow Conventional Commits:

| Commit | Release change |
| --- | --- |
| `fix:` or `perf:` | Patch |
| `feat:` | Minor |
| `docs:` or `chore:` | None by themselves |
| A `!` suffix or `BREAKING CHANGE:` footer | Minor before 1.0; major afterward |

If no releasable commit exists, the workflow succeeds without creating a tag and says why in its
summary. A failed run before publication can be rerun with the same version. If a release was
created but an asset is missing, running the workflow again from that commit repairs it.

## Release notes and changelog

[git-cliff](https://git-cliff.org) builds the notes from the commits, using `cliff.toml`.
`feat:`, `fix:` and `perf:` commits are listed; `docs:`, `chore:`, merges and unconventional
commits are left out. Edit the published release on GitHub to add highlights; a repair run keeps
the body. `CHANGELOG.md` is regenerated and committed by hand with `git cliff -o CHANGELOG.md`.

## Homebrew

```sh
brew install --cask fanckush/soundowl/soundowl
```

The cask sets `auto_updates true`, so `brew upgrade` leaves updates to Sparkle. Getting into the
main `homebrew/cask` needs a notable project (roughly 75 stars or 30 forks if someone else submits
it, 225 stars or 90 forks to self-submit).

## Verifying a build

```sh
spctl -a -vvv --type exec build/export/SoundOwl.app   # "accepted, source=Notarized Developer ID"
xcrun stapler validate build/export/SoundOwl.app
codesign -dv build/export/SoundOwl.app                # flags=0x10000(runtime), TeamIdentifier=VS9RJDSTF7
```
