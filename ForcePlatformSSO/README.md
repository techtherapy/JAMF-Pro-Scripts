# ForcePlatformSSO_Okta.sh

A Jamf Pro script that deploys and enforces **Platform Single Sign-on (PSSO) via Okta Verify** on managed macOS devices. It handles the full registration lifecycle: installing Okta Verify, adding the device to the correct Jamf static group to trigger the SSO configuration profile, prompting the user to complete registration, and verifying the outcome.

Adapted from the original `ForcePlatformSSO.sh` (Microsoft Entra ID) by Scott Kendall.

---

## Table of Contents

- [Requirements](#requirements)
- [How It Works](#how-it-works)
- [Prerequisites](#prerequisites)
  - [Jamf Pro Setup](#jamf-pro-setup)
  - [Okta Admin Setup](#okta-admin-setup)
  - [Support Files](#support-files)
- [Script Parameters](#script-parameters)
- [Deployment](#deployment)
- [Customisation](#customisation)
- [Troubleshooting](#troubleshooting)
- [Change Log](#change-log)

---

## Requirements

| Component | Minimum version |
|---|---|
| macOS | 13 Ventura |
| Jamf Pro | 10.49 or later |
| SwiftDialog | 2.5.0 or later |
| Okta Verify | Latest available via your Jamf policy |
| Shell | zsh (built-in on macOS 10.15+) |

---

## How It Works

1. Verifies SwiftDialog is installed and up to date; installs it via Jamf if not.
2. Checks that required support files and icons are present; pulls them from Jamf if not.
3. Optionally enforces TouchID enrollment before proceeding.
4. Retrieves the Jamf static group ID and device ID via the Jamf Pro API.
5. Adds the device to the Platform SSO static group, which triggers delivery of the `extensiblesso` MDM configuration profile.
6. If the profile is already installed, the device is removed then re-added to force the registration prompt to reappear.
7. Enables the Okta Verify SSO extension (`com.okta.mobile.auth-service-extension`) via `pluginkit` if not already active.
8. Checks current registration status via `app-sso platform -s`. If already registered, exits cleanly.
9. Displays a SwiftDialog prompt to the user explaining what to do when the macOS registration notification appears.
10. Kills and restarts the Platform SSO agent (`AppSSOAgent`) to force the registration prompt.
11. Polls every 10 seconds (up to 5 minutes) until registration is confirmed.
12. Verifies the final registration state via `app-sso platform -s`. If it still does not report as registered and `RUN_OKTA_ON_ERROR` is set to `yes`, re-triggers the Okta Verify Jamf install policy as a remediation step.

---

## Prerequisites

### Jamf Pro Setup

#### 1. API Role and Client

Create a dedicated API role with the following minimum privileges:

- **Computers** - Read
- **Computer Groups** - Read, Update
- **Static Computer Groups** - Read, Update

Then create an API client using that role and note the **Client ID** and **Client Secret**. If you are using Classic API credentials (username/password), these map to the same parameters - the script detects which type to use based on the length of the Client ID.

#### 2. Policies

The script expects the following Jamf policy **trigger names** to exist. You can change these names in the variable block at the top of the script if needed.

| Variable | Default trigger name | Purpose |
|---|---|---|
| `PORTAL_APP_POLICY` | `install_okta_verify` | Installs or reinstalls Okta Verify |
| `DIALOG_INSTALL_POLICY` | `install_SwiftDialog` | Installs SwiftDialog |
| `SUPPORT_FILE_INSTALL_POLICY` | `install_SymFiles` | Installs banner image and support files |
| `PSSO_ICON_POLICY` | `install_psso_icon` | Installs the SSO icon used in dialogs |
| `SSO_GRAPHIC_POLICY` | `install_sso_graphic` | Installs the notification graphic |

#### 3. Static Group

Create a **Static Computer Group** in Jamf Pro. This is the group that devices are added to in order to receive the Platform SSO configuration profile via a scoped policy or configuration profile. Note the exact group name - it is passed in as a script parameter.

#### 4. Configuration Profile

Create a **Configuration Profile** scoped to the static group above. The profile must contain a **Single Sign-On Extensions** (`com.apple.extensiblesso`) payload configured as follows:

| Field | Value |
|---|---|
| Extension Identifier | `com.okta.mobile.auth-service-extension` |
| Team Identifier | `B7F62B65BN` |
| Type | Redirect |
| URLs | `https://intenthq.okta.com`, `https://intenthq.okta.com/device-access/api/v1/nonce`, `https://intenthq.okta.com/oauth2/v1/token` |

Refer to [Okta's macOS Platform SSO documentation](https://help.okta.com/en-us/content/topics/mobile/apple-platform-sso.htm) for full payload configuration options.

Note the **exact profile name** as it appears in Jamf - this is passed in as a script parameter.

---

### Okta Admin Setup

1. In the Okta Admin Console, navigate to **Security > Device Integrations > Platform Single Sign-on**.
2. Enable **macOS Platform SSO**.
3. Set the authentication method to match your org's requirements (Password, Secure Enclave key, or Smart Card).
4. Ensure Okta Verify is configured as a managed app in your Jamf/MDM integration.

Okta's official setup guide: [Configure macOS Platform SSO](https://help.okta.com/en-us/content/topics/mobile/apple-platform-sso.htm)

---

### Support Files

The script expects the following files to be present on disk. If they are missing, it will attempt to install them via the corresponding Jamf policies listed above.

| File | Default path |
|---|---|
| Banner image | `/Library/Application Support/GiantEagle/SupportFiles/GE_SD_BannerImage.png` |
| SSO icon | `/Library/Application Support/GiantEagle/SupportFiles/sso.png` |
| Notification graphic | `/Library/Application Support/GiantEagle/SupportFiles/pSSO_Notification.png` |

These paths can be overridden by deploying a managed preferences file at:

```
/Library/Managed Preferences/com.gianteaglescript.defaults.plist
```

With keys: `SupportFiles` (base path), `BannerImage` (relative path), `BannerPadding` (integer).

---

## Script Parameters

Configure these in the Jamf policy under **Scripts > Parameters**.

| Parameter | Label | Required | Description |
|---|---|---|---|
| `$4` | API Client ID | Yes | Jamf API Client ID (modern OAuth) or username (Classic API). The script determines which type to use based on string length. |
| `$5` | API Client Secret | Yes | Jamf API Client Secret or password. |
| `$6` | MDM Profile Name | Yes | Exact name of the Platform SSO configuration profile in Jamf. Must match precisely. |
| `$7` | Jamf Static Group Name | Yes | Exact name of the static group that scopes the SSO profile. |
| `$8` | Run Okta remediation on error | No | `yes` or `no`. If registration is not confirmed after completion, re-triggers the Okta Verify install policy. Defaults to `yes`. |
| `$9` | Force TouchID enrollment | No | `yes` or `no`. If TouchID hardware is present but no fingerprints are enrolled, the user is prompted to add one before registration proceeds. Defaults to `yes`. |

---

## Deployment

1. Upload `ForcePlatformSSO_Okta.sh` to **Jamf Pro > Settings > Computer Management > Scripts**.
2. Set the script's **Parameter Labels** to match the table above (for clarity in the policy UI).
3. Create a new **Policy** in Jamf Pro:
   - **Trigger:** Recurring Check-in, or a custom event trigger if you prefer to call it manually.
   - **Frequency:** Once per computer (or Once per user per computer if you need per-user enforcement).
   - **Scope:** Target the computers or groups that need PSSO deployed.
   - **Scripts:** Add `ForcePlatformSSO_Okta.sh` and fill in Parameters 4-9.
4. **Test on a single device** before broad deployment - see the Troubleshooting section below.

---

## Customisation

**Changing support file paths**
Deploy a `com.gianteaglescript.defaults.plist` managed preferences file via Jamf to override default paths without editing the script.

**Forcing Okta Verify reinstall**
Uncomment this line in the Main section of the script:

```zsh
#reinstall_okta_verify
```

This will remove the existing Okta Verify installation and reinstall it fresh before proceeding. Useful if you suspect a corrupted install is causing registration failures.

**Adjusting the registration timeout**
Change `max_wait` in the polling loop (default: 300 seconds):

```zsh
max_wait=300    # total seconds before timeout
```

**Adjusting the dialog display duration**
Change `SD_TIMER` (default: 300 seconds):

```zsh
SD_TIMER=300
```

---

## Troubleshooting

**Log file location**

```
/Library/Application Support/GiantEagle/logs/ForcePlatformSSO_Okta.log
```

Tail the log in real time during testing:

```zsh
tail -f "/Library/Application Support/GiantEagle/logs/ForcePlatformSSO_Okta.log"
```

---

**Common issues**

| Symptom | Likely cause | Resolution |
|---|---|---|
| Script exits with "Missing Group name or MDM profile name" | Parameters 6 or 7 are blank in the Jamf policy | Check the script parameters in the Jamf policy configuration |
| "JSS connection not active" | Device cannot reach Jamf Pro | Check network connectivity and Jamf Pro server availability |
| "Check the API Client credentials" | Incorrect Client ID or Secret in parameters 4/5 | Verify API client credentials in Jamf Pro and re-enter in the policy |
| "Group ID came back empty" | Static group name in parameter 7 does not match exactly | Copy the group name directly from Jamf Pro; check for trailing spaces |
| Registration prompt never appears | Configuration profile not delivered, or SSO agent did not restart | Verify profile scope in Jamf, check that Okta Verify is installed, run `app-sso platform -s` as the user to inspect state |
| "Timed out after 300s" | User did not complete registration within 5 minutes, or prompt was not seen | Check Focus mode status in the log; increase `max_wait` if needed; verify the Okta registration prompt appeared |
| Extension not found in pluginkit | Okta Verify is not installed or is an incompatible version | Confirm Okta Verify installs successfully via the `install_okta_verify` policy trigger |
| TouchID loop does not exit | `touch_id_status` comparison mismatch | The function returns `"Enabled"` (capital E) - verify no local modifications changed the case |

---

**Manually checking Platform SSO status**

Run the following as the logged-in user to inspect current registration state:

```zsh
app-sso platform -s
```

Key fields to look for in the output:

- `registrationCompleted : true` - device is registered
- `loginFrequency` - how often re-authentication is required
- `extensionIdentifier` - should show `com.okta.mobile.auth-service-extension`

---

**Checking the SSO extension is enabled**

```zsh
pluginkit -m | grep okta.mobile.auth-service-extension
```

A `+` prefix indicates the extension is enabled. A `-` prefix means it is disabled - the script will enable it automatically, but you can do so manually with:

```zsh
pluginkit -e use -i com.okta.mobile.auth-service-extension
```

---

## Change Log

| Version | Date | Notes |
|---|---|---|
| 1.1 | 2026-03-10 | Corrected `APP_EXTENSIONS` bundle ID from `com.okta.mobile.app.ssoextension` to `com.okta.mobile.auth-service-extension` to match the actual Platform SSO extension identifier used in the Jamf configuration profile. Updated all README references and diagnostic commands accordingly. Added base org URL to recommended extensiblesso URL list. |
| 1.0 | 2026-03-10 | Initial Okta adaptation from ForcePlatformSSO.sh v2.0 (Entra ID). Replaced Company Portal with Okta Verify, removed jamfAAD dependency, replaced JAMF_check_AAD with JAMF_check_Okta using native app-sso, updated app extensions array, updated all display strings. |
