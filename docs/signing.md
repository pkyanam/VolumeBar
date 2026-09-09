# Apple signing setup

The public release pipeline uses a **Developer ID Application** certificate plus an **App Store Connect team API key** for notarization. An Apple Development certificate or App Store distribution certificate is not sufficient. Apple Developer Program membership is required.

## One-time setup

### 1. Create/export the Developer ID identity

In [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/certificates/list), create a **Developer ID Application** certificate using the **G2 Sub-CA** and a CSR from a key you control. Download the certificate and pair it with its matching private key. Export the identity as a password-protected `.p12`.

If using Keychain Access, select the Developer ID Application identity under **My Certificates**, expand it to confirm the private key exists, and export it as PKCS#12. Downloading a `.cer` alone does not include the private key.

Keep the P12 and its password in a secure backup outside your checkout. Do not revoke existing certificates used by other apps to make room without assessing the impact.

### 2. Create a notarization API key

Open [App Store Connect → Users and Access → Integrations → App Store Connect API](https://appstoreconnect.apple.com/access/integrations/api). Use a **team key** with the **Developer** role, named `VolumeBar CI Notarization` (or the least role permitted by Apple's current UI). Record its **Key ID** and **Issuer ID**, then download the `.p8` private key. Apple offers the private key download only once.

The workflow uses `notarytool --key ... --key-id ... --issuer ...`. It does not need your Apple Account password, browser session, or a two-factor code on GitHub. Check Apple's [API key guidance](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api) when choosing a key type.

### 3. Configure GitHub

Create an environment named **release** in repository Settings → Environments. Restrict deployment to branch `main` and tags `v*`. Add these **environment secrets**:

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | Base64-encoded certificate **and matching private key**, exported as P12 |
| `DEVELOPER_ID_P12_PASSWORD` | P12 export password |
| `APPLE_API_KEY_P8` | Entire contents of the downloaded `.p8` file |
| `APPLE_API_KEY_ID` | App Store Connect key ID |
| `APPLE_API_ISSUER_ID` | App Store Connect team issuer UUID |
| `APPLE_TEAM_ID` | Developer Program team ID |

Use `gh` without putting secret values in shell history:

```sh
# Run these from the repository. Files live outside the checkout.
base64 < /secure/path/DeveloperID.p12 | gh secret set DEVELOPER_ID_P12_BASE64 --env release
gh secret set DEVELOPER_ID_P12_PASSWORD --env release # hidden interactive input
gh secret set APPLE_API_KEY_P8 --env release < /secure/path/AuthKey.p8
gh secret set APPLE_API_KEY_ID --env release
gh secret set APPLE_API_ISSUER_ID --env release
gh secret set APPLE_TEAM_ID --env release
```

Alternatively, `./Scripts/setup-github-signing.py` imports all six from local files with hidden password input and restricts the environment automatically. It verifies the target repo before uploading.

### 4. Enable and verify

```sh
gh secret list --env release
gh variable set SIGNING_ENABLED --body true
gh workflow run ci.yml --ref main
gh run list --workflow ci.yml
gh run watch RUN_ID --exit-status
```

Check the **Sign, notarize, and publish** job, download its prerelease DMG, and verify the app opens normally on a Mac. Stable tags matching `version.env` publish regular releases.

## Rotation and troubleshooting

- **No valid identity:** the P12 lacks the private key, has the wrong password, is expired, or is not Developer ID Application.
- **Wrong team:** the certificate's TeamIdentifier must match `APPLE_TEAM_ID`.
- **401/403 from Apple:** check key type, key/issuer IDs, access role, active membership, and updated agreements.
- **Notarization timeout:** preserve the submission ID from the diagnostic artifact. Query that submission before creating another; Apple may still be processing it.
- **Certificate rotation:** create a replacement, update the P12/password secrets, and verify a signed build before retiring the old certificate.
- **API key rotation:** create/download a replacement, update all three API secrets, verify CI, then revoke the old key only after checking other consumers.
- **Pause releases:** set `SIGNING_ENABLED=false`. Tests and development artifacts continue.

GitHub never reveals stored secret values. Keep a secure local backup for recovery. Runner keychains and temporary private files are removed after success/failure; never put them in workflow artifacts.
