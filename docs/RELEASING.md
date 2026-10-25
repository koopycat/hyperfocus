# Releasing Hyperfocus

A stable semantic-version tag triggers `.github/workflows/release.yml`. The workflow validates the tag, builds a universal Developer ID-signed app, notarizes and staples both the app and DMG, publishes the GitHub Release, updates `koopycat/homebrew-tap`, and installs the cask on native Intel and Apple Silicon runners.

## One-time GitHub configuration

Configure these Actions secrets in `koopycat/hyperfocus`:

| Secret | Value |
|---|---|
| `DEVELOPER_ID_CERTIFICATE_P12` | Base64 representation of the exported Developer ID Application `.p12` certificate and private key |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | Password used when exporting that `.p12` |
| `DEVELOPER_ID_APPLICATION` | Full signing identity, such as `Developer ID Application: Example (TEAMID)` |
| `APP_STORE_CONNECT_API_KEY_P8` | Base64 representation of the App Store Connect API private key (`.p8`) |
| `APP_STORE_CONNECT_API_KEY_ID` | App Store Connect API key ID |
| `APP_STORE_CONNECT_ISSUER_ID` | App Store Connect API issuer ID |
| `HOMEBREW_APP_ID` | Numeric App ID of the GitHub App used to update Homebrew taps |
| `HOMEBREW_APP_PRIVATE_KEY` | Private key of that GitHub App |

The Homebrew GitHub App must be installed for `koopycat/homebrew-tap` and have **Contents: Read and write** permission. The workflow requests a short-lived token restricted to that repository; do not replace it with a personal access token.

For example, create the encoded certificate values without writing another unencrypted copy:

```bash
base64 < developer-id-application.p12 | pbcopy
base64 < AuthKey_KEYID.p8 | pbcopy
```

## Create a release

1. Choose the next stable semantic version, for example `1.1.0`.
2. Update `MARKETING_VERSION` in `Hyperfocus/AppCore/Release.xcconfig` and both generated target settings in `Hyperfocus.xcodeproj/project.pbxproj`. Keep `scripts/generate-xcodeproj.rb` aligned if regenerating the project remains supported.
3. Leave `Casks/hyperfocus.rb` at the currently published version. The release workflow updates the cask in the shared tap after calculating the final stapled DMG checksum. Update this repository's reference copy in the next normal source commit so it reflects the published release without requiring the release workflow to write back to a tag commit.
4. Run the credential-free checks:

   ```bash
   python3 -m unittest discover -s tests -p '*_test.py'
   python3 scripts/release_metadata.py --tag v1.1.0
   ruby -c Casks/hyperfocus.rb
   actionlint .github/workflows/*.yml
   ```

5. Merge the version commit to `main`.
6. Create and push an annotated tag pointing to that commit:

   ```bash
   git tag -a v1.1.0 -m "Release v1.1.0"
   git push origin v1.1.0
   ```

7. Follow the **Release** workflow through both Homebrew verification jobs.

The local unsigned packaging check requires a full Xcode installation:

```bash
scripts/build-release.sh 1.1.0 --unsigned
```

It proves the universal build and DMG mechanics but does not produce a publishable artifact.

## Failure and rollback

Failures before the `Publish GitHub release` job leave both the GitHub Releases page and Homebrew tap unchanged. A tap-authentication or cask-update failure leaves the already-published GitHub Release available but does not change the tap.

The final Homebrew verification happens after publication. If it fails, inspect the architecture-specific job before changing public state. To roll back a bad publication:

1. Revert the bot commit in `koopycat/homebrew-tap` and push the revert.
2. Delete the corresponding GitHub Release if the artifact itself is invalid.
3. Delete and recreate the tag only after fixing the release commit and version metadata; do not reuse a tag while consumers may still cache the old artifact.

Credential-dependent signing, notarization, external tap mutation, and native Homebrew installation can only be validated end to end by the first post-merge release-tag run.
