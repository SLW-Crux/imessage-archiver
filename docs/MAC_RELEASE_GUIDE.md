# Shipping a notarized Mac DMG

Step-by-step for cutting a release that end users can download, open, and run without any Gatekeeper warnings. No App Store, no TestFlight — direct DMG download.

End-to-end script: `packaging/build_mac_dmg.sh`. This guide covers the one-time setup the script depends on, and what to do after the DMG is built.

---

## One-time setup

### 1. Create a **Developer ID Application** certificate

You already have an **Apple Development** cert in the keychain (the one signing Debug builds). You need a separate **Developer ID Application** cert for notarized release builds. They're not interchangeable.

- developer.apple.com → **Certificates, Identifiers & Profiles** → **Certificates** → **+**
- Software → **Developer ID Application** → Continue
- Generate a CSR in Keychain Access (Certificate Assistant → Request a Certificate From a Certificate Authority → save to disk)
- Upload the CSR → download the resulting `.cer` → double-click to install it into the keychain

Verify it's there:
```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```
You should see a line like:
```
1) ABCD…1234 "Developer ID Application: Stephen Williams (7V698GFQCM)"
```

### 2. Create an **App Store Connect API key** for `notarytool`

You CAN notarize with an Apple ID + app-specific password, but the API key approach is more reliable and doesn't break when your Apple ID password changes.

- appstoreconnect.apple.com → **Users and Access** → **Integrations** tab → **App Store Connect API** → **Keys** → **+**
- Name: "Honk Notary" (or whatever)
- Access: **Developer**
- Download the `.p8` file ONCE (Apple won't let you download it again)
- Note the **Key ID** (10-char string) and **Issuer ID** (UUID) shown on the page

Store the key in the keychain under a notarytool profile:
```bash
xcrun notarytool store-credentials honk-notary \
    --key  ~/Downloads/AuthKey_XXXXXXXXXX.p8 \
    --key-id XXXXXXXXXX \
    --issuer YYYYYYYY-YYYY-YYYY-YYYY-YYYYYYYYYYYY
```

(You'll be prompted for the macOS keychain password.) The script reads this profile by name; no secrets hit disk in the repo.

Verify:
```bash
xcrun notarytool history --keychain-profile honk-notary | head
```
A non-error response (even "No submissions found") means it's wired up.

### 3. Move the `.p8` somewhere safe + delete from `~/Downloads`

Apple won't re-issue it. Treat it like a private key.

---

## Cutting a release

### 1. Bump the version

`ios/project.yml`:
```yaml
MARKETING_VERSION: "0.5.0"     # the public-facing version
CURRENT_PROJECT_VERSION: "5"   # monotonically increasing build number
```

`CURRENT_PROJECT_VERSION` must strictly increase across every uploaded build, even within the same `MARKETING_VERSION`.

Commit + push:
```bash
git add ios/project.yml
git commit -m "release: 0.5.0"
git tag v0.5.0
git push --tags
```

### 2. Run the build

From the repo root:

```bash
./packaging/build_mac_dmg.sh
```

What it does, in order:
1. Sanity-check that the Developer ID cert + notarytool profile are present.
2. `xcodebuild archive` the Mac scheme.
3. `xcodebuild -exportArchive` with Developer ID export options — produces a signed `.app`.
4. Verify the signature locally (`codesign --verify --deep --strict`).
5. Submit the `.app` to Apple notarization, wait for the ticket.
6. Staple the ticket onto the `.app` (so Gatekeeper can verify offline).
7. Build a `.dmg` with the app + an Applications symlink (drag-to-install).
8. Notarize the `.dmg` too.
9. Staple the ticket onto the `.dmg`.
10. Final `spctl` Gatekeeper verification.

Total runtime: ~5–20 minutes. Most of that is Apple's notarization service.

Output: `dist/HonkiMessageArchiver-<version>.dmg`.

### 3. Publish

GitHub Releases path (recommended):
```bash
gh release create v0.5.0 \
    dist/HonkiMessageArchiver-0.5.0.dmg \
    --title "Honk iMessage Archiver 0.5.0" \
    --notes "See CHANGELOG.md."
```

Or upload the DMG to your own website and link from there. Either way, end users:
1. Download the DMG
2. Open it
3. Drag **Honk iMessage Archiver** onto the **Applications** symlink
4. Launch — no Gatekeeper warning, no "unidentified developer" dialog, because the app is signed AND notarized AND stapled.

---

## Troubleshooting

### "errSecInternalComponent" during `codesign`

Your keychain is locked. `security unlock-keychain ~/Library/Keychains/login.keychain-db`.

### Notarization fails with "errors" status

The script prints the submission ID. Fetch the detailed log:
```bash
xcrun notarytool log <SUBMISSION_ID> --keychain-profile honk-notary
```
Common causes:
- App is not signed with **Hardened Runtime**: `ENABLE_HARDENED_RUNTIME=YES` is already in `project.yml` so this shouldn't happen, but worth checking the export log if it does.
- App embeds a binary that's not signed (e.g. a Python interpreter from PyInstaller — not applicable in Plan B but would be in Plan A).

### "App is damaged and can't be opened" on a tester's Mac

The notarization ticket isn't stapled (or the DMG was modified after stapling). Re-run the build; if that doesn't help, run `xcrun stapler validate dist/*.dmg` to confirm the ticket is embedded.

### `xcodebuild archive` fails on a missing provisioning profile

The Developer ID profile is auto-generated by Xcode the first time you Archive with an Apple ID signed in. If `-allowProvisioningUpdates` doesn't pick it up, open Xcode once, do a manual Archive (Product → Archive) so Xcode creates the profile interactively, then re-run the script.

### Cert expired

Developer ID Application certs are valid for 5 years. Make a new one well before expiry; old DMGs stay notarized forever (the ticket Apple issued is permanent), but you can't sign new builds with an expired cert.

---

## Future work

- **Sparkle in-app auto-updater** — instead of users manually downloading new DMGs, the app checks an appcast XML feed and offers updates inside Honk itself. Adds a Swift Package Manager dependency on `Sparkle` and a small `SUUpdater` wiring in the Mac app target.
- **`.github/workflows/mac-release.yml`** — automated build on git-tag push, requires storing the Developer ID `.p12` and the App Store Connect API `.p8` as GitHub secrets, base64-encoded, then unpacked into a temporary keychain on the macOS runner. Doable, just more secret juggling than the local script needs.
