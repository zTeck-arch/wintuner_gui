# WinTuner GUI

**English** · [Deutsch](README.de.md)

A Windows desktop interface for managing WinGet, Win32 and Microsoft Store apps in Microsoft Intune.

Packaging, deployment, version comparison, assignments and the controlled retirement of old app versions in one place, with a bilingual interface (English and German). Built on the [WinTuner](https://github.com/svrooij/WinTuner) PowerShell module, WinGet and Microsoft Graph.

> [!WARNING]
> **Beta. Not released for production use.** See [Project status](#project-status).

> [!IMPORTANT]
> Depending on the action you choose, WinTuner GUI changes apps and assignments in Microsoft Intune. Verify packages, detection rules, requirement rules and assignments in a test tenant or against a test group before you use it productively.

---

## Contents

- [Quick start](#quick-start)
- [What it does](#what-it-does)
- [How each section behaves](#how-each-section-behaves)
- [Security model](#security-model)
- [Sign-in and session](#sign-in-and-session)
- [Requirements](#requirements)
- [Account and permissions](#account-and-permissions)
- [A typical run](#a-typical-run)
- [A fresh customer tenant, and the steady state](#a-fresh-customer-tenant-and-the-steady-state)
- [Limits and responsibility](#limits-and-responsibility)
- [Project status](#project-status)
- [License and origin](#license-and-origin)

---

## Quick start

You do **not** need to clone this repository. One file is enough:

```text
WinTuner_GUI_ntg.ps1
```

1. Open the [latest release](../../releases/latest).
2. Expand **Assets**.
3. Download **`WinTuner_GUI_ntg.ps1`** only. The source code and the GitHub ZIP archives are not needed to run the tool.
4. Open PowerShell 7 in your download folder and start it:

   ```powershell
   Unblock-File -LiteralPath '.\WinTuner_GUI_ntg.ps1'
   & '.\WinTuner_GUI_ntg.ps1'
   ```

> [!NOTE]
> Windows blocks scripts downloaded from the internet on first run. `Unblock-File` clears that mark. You can also do it manually: right-click the file, **Properties**, then tick **Unblock**.

The second asset, `WinTuner_GUI_ntg.ps1.sha256`, is optional and only lets you verify the checksum of your download.

**Missing prerequisites are handled for you.** If PowerShell 7 is absent, the script offers to install or update it through WinGet. The required `WinTuner` module can be installed from the PowerShell Gallery for the current user after you confirm. The `Microsoft.Graph` module has to be available; if it is missing, the application tells you how to install it.

**Updating.** The application can look for new releases at start-up and replace its own file; the start-up check can be switched off under "Settings > Updates of this tool", leaving the button there as the only route. Before replacing, it writes a backup next to the script (`WinTuner_GUI_ntg.ps1.<timestamp>.backup`) and keeps the two most recent ones.

---

## What it does

**Find and package WinGet apps**
Search the public WinGet catalogue, pick a version and build it locally as an Intune Win32 package.

**Deploy to Microsoft Intune**
Upload new Win32 apps and optionally assign them as available, required or uninstall. Target groups, filters, notifications, deadlines and further assignment settings are all available in the interface.

**Manage Microsoft Store apps**
Resolve Store apps by name or package identifier, search the tenant and deploy. Apps that already exist are recognised, so nothing gets deployed twice.

**Deploy macOS packages (Beta)**
Bring a macOS `.pkg` into Intune as a "macOS app (PKG)". Nothing has to be packaged: Intune takes the vendor's file as it is. Pick an application from a catalogue built from Homebrew — filtered to the entries that really ship a `.pkg`, with the published checksum where there is one — or choose a file yourself. Bundle identifier, version, included bundles and the minimum macOS version are read out of the package. Deploying the same application again replaces the content of the existing app instead of creating a second one, so its assignments and statistics stay. See the warning under [macOS packages are Beta](#macos-packages-are-beta).

**Check deployed apps for updates**
Compare Win32 apps in Intune against current WinGet versions. The result list distinguishes between a required new upload, reuse of a target that already exists, and follow-up work still to be done.

**Roll updates out under control**
Package a new target version or reuse an existing one, carry assignments across, and retire predecessors through Intune supersedence.

**Clean up old versions safely**
Find superseded or unused app objects. Automatic deletion only happens after assignments and successful installations have been re-checked. The risky cleanup options are off by default.

You can also cap how many versions of one package are kept. On its own, that cap yields to reported installations: a version beyond it stays as long as a single device still reports it. An optional setting lets the cap win instead, in the manual and the automatic clean-up alike. Assignments still protect a version, and one whose state cannot be read is never deleted. Worth knowing before switching it on: **deleting an app object does not uninstall the software from the device** — Intune loses the reporting, the assignment and the option to reinstall from that object, the software itself stays.

**Package your own installers and replace app content**
Turn any EXE or MSI installer into an `.intunewin` package, including software that is not in WinGet. You can also replace the content of an existing Intune app in place: the app ID, its assignments and its history stay as they are, no second app object appears and nothing is superseded.

**Work out a detection rule**
For an MSI, one click reads the product code and version. For an EXE, the uninstall registry is compared before and after an installation, which produces a ready-made Intune detection rule with key path, value name and comparison value. Silent switches can be tried in Windows Sandbox first, without touching your own machine.

**See and assign every app in the tenant**
List all app objects of any type, including the ones this interface does not package (MSI, UWP/MSIX, Microsoft 365 Apps, web links). Assignments are shown in plain language and can be managed: add or remove groups and exclusions, set the intent, adjust notifications, deadlines and restart behaviour. Groups can optionally be searched by name.

**Evaluate discovered software**
Load the Intune inventory of discovered apps, filter out the usual driver and OEM noise, and map suitable applications to WinGet packages. Selected matches can then be taken under management.

**Keep local packages and favourites current**
Save frequently used WinGet packages as favourites and optionally check them for updates at startup. Missing versions are downloaded or built locally. **Update all local apps** checks the whole package folder and brings it up to date in one go, without rebuilding versions that are already current.

**Tenant overview and logging**
A dashboard for managed apps, available updates and superseded versions. Actions and errors are recorded in a local weekly log.

**Adjustable interface**
English and German interface, several display modes, plus locally stored settings and recently used sign-ins.

---

## How each section behaves

| Section | Data source | Effect |
|---|---|---|
| Dashboard | Microsoft Intune | Read-only overview of apps, updates and superseded versions. The fourth tile measures the local package folder |
| WinGet apps | WinGet and the local package folder | Searches packages, builds them locally and uploads to Intune after confirmation. Also holds the local package favourites: optionally checked at startup, and all valid local packages can be updated on request |
| Microsoft Store | Microsoft Store and Intune | Searches the Store catalogue, shows matches to pick from, deploys after confirmation, plus an overview of Store apps already deployed |
| Updates | Intune, WinGet and the WinTuner index | Compares versions, creates or reuses a target app, and hands assignments across on request. Also holds the version cleanup, which deletes old app objects only when the configured safety conditions are met |
| Discovered apps | Intune inventory and WinGet | Maps installed software to possible WinGet packages. The scan itself is read-only |
| All tenant apps | Intune | Lists every app object of every type. Assignments are read and can be changed, which writes to Intune. Selected apps can be **deleted** from here - permanently, after a question that names each app and says which of them are assigned or installed |
| Own installers | Local files and Intune | Packages any EXE or MSI locally into `.intunewin`. Replacing the content of an existing app writes to Intune |
| macOS (PKG) – Beta | Homebrew, the vendor's download and Intune | Downloads a macOS `.pkg` and creates it in Intune, or replaces the content of an app deployed earlier. Reads the package metadata locally; no catalogue entry is deployed without confirmation |
| Local packages | WinGet and the local package folder | Maintains package copies on this computer: check the saved list and download newer ones. Creates nothing in Intune |
| Settings | Local settings file and Intune | Package and log folder, language, theme, cleanup options and saved group favourites. Nothing here changes the tenant by itself; the options decide what the other sections are allowed to do |

The interface does not install software on endpoints. It creates and manages app objects and assignments in Intune; the actual distribution and reporting is then done by Microsoft Intune.

### macOS packages are Beta

Everything on the Windows side of that path is covered by tests. The result is not: whether a package actually installs can only be seen on a Mac, and no Mac takes part in this project's checks. Treat the first deployment as an experiment rather than as routine, and start without an assignment so nothing reaches a device.

Three things decide whether it works, and this interface cannot check any of them for you:

- The `.pkg` must be **signed and notarized** by its vendor. macOS blocks anything else on the device, no matter what Intune reports.
- **Install scripts inside a package run as root.** You are uploading more than an application, so check where the file came from.
- Intune detects the app by bundle identifier and version, and a package carries **two** versions (`CFBundleShortVersionString` and `CFBundleVersion`). Both are read out and you choose which one is used. If it is the wrong one, the app is reinstalled on every check instead of being recognised.

The catalogue only lists entries that really ship a `.pkg` — a minority of Homebrew, because most applications ship a DMG, which is a different Intune app type and not supported here. For a few applications where the vendor publishes a `.pkg` although Homebrew points at a DMG, a short hand-checked list of vendor addresses is built in.

---

## Security model

- Intune is only changed after a deliberate user action.
- Duplicate uploads of the same package version are detected and blocked before deployment.
- Before any cleanup, assignments and reported successful installations are queried again.
- Assigned predecessors are only removed under conditions you explicitly enabled.
- Passwords, tokens and other secrets are stored neither in the script nor in the settings file. Authentication goes through Microsoft Entra ID and Microsoft Graph.
- Settings, recently used account names and logs stay local, in your Windows user profile or next to the application.
- Packages are built under `%LOCALAPPDATA%\WinTunerGUI\Packages` by default. That directory belongs to the signed-in user. A shared writable location such as `C:\Temp` is deliberately no longer the default, because any user of the machine could alter a finished package there between build and upload.
- Deleting under **All tenant apps** is permanent and cannot be undone from here. Every selected app is checked for assignments and successful installations first, and the answer is part of the question. Two classes are never deleted there and are named instead: apps on the **protection list** (remove the protection first if you really mean it) and apps whose state Intune did not report - an unknown state is not permission. That question is always asked, even with confirmations switched off.
- Changing assignments under **All tenant apps** always replaces an app's complete assignment set, because Microsoft Graph has no partial update. The dialog shows the list it is about to write and asks first.
- **Clean up duplicate assignments** under **All tenant apps** looks for apps with **more than one assigned version** — the state where devices get the same software twice and nobody can say which one wins. Grouping is by **display name** across all app types: a copy stored as MSI line-of-business usually carries the same name but neither a publisher nor a WinGet id, and would otherwise never be found. The cleanup **moves** rather than removes: the assignments of the older versions are written onto the newest one with group, intent, filter and settings, and only then cleared on the old one, so no group loses the app. The apps themselves stay. Left alone and named: protected apps, versions carrying an **uninstall assignment**, groups where two copies share the same highest version number, apps without a readable version, and anything whose assignments cannot be read. This question cannot be dismissed either.
- Replacing the content of an existing app does **not** touch its detection and requirement rules. They have to match the new version, so check them beforehand.
- The built-in self-update only accepts releases with a matching script asset, SHA-256 checksum and a plausible internal version number. A backup is written before the replacement. After you confirm, the exchange runs without further prompts and the two most recent backups are kept.

### Disconnect and Sign out

| Action | Current session | Cached session | Next sign-in |
|---|---|---|---|
| **Disconnect** | ends | kept | immediate, no prompt |
| **Sign out** | ends | deleted (the Windows broker is bypassed, the username field is cleared) | a real, interactive sign-in |

**Rule of thumb:** switching customer, or a shared machine, means **Sign out**. Everything else, **Disconnect**.

The section below explains why that distinction matters.

---

## Sign-in and session

This explains why no password is asked after the first sign-in, where that session lives, and what it means for security. The same text is available in the application under **Help → "Sign-in and session explained"**.

### What is stored, and what is not

Your password and MFA are **not** stored. Sign-in goes through Microsoft Entra ID, which issues two tokens after a successful interactive sign-in:

- an **access token**, short-lived at around one hour, sent with every Graph call;
- a **refresh token**, longer-lived, used to obtain a fresh access token in the background without asking you again.

The refresh token is the part worth protecting. Whoever holds it can keep minting new access tokens until it expires or is revoked centrally.

### Where the session lives

The cache is managed by the underlying Microsoft Authentication Library (MSAL) and sits in your Windows user profile:

```text
%LOCALAPPDATA%\.IdentityService\   (files named mg.msal.cache*)
```

On Windows, MSAL encrypts this cache with the **Data Protection API (DPAPI)** in the user's context. Only **the same Windows user on the same device** can decrypt it. Another local user can see the file but not read it. The cache cannot be moved to another device or account, and it expires. Conditional Access or MFA policies can end it sooner.

### Why the next connection needs no prompt

On reconnecting, MSAL finds the refresh token in the cache and silently exchanges it for a new access token. The Windows broker (WAM) can additionally reuse an account already signed in on the device. That is why the password and MFA prompt usually does not reappear.

### What this means for security

DPAPI protects the session against *other users* of the machine. It does not protect against code running **as the signed-in user**. Malware or a script running under the same Windows account can call DPAPI just as well and read the refresh token.

For a tool that manages customer tenants, a cache left behind on a shared technician machine is therefore potential silent access to a customer tenant until the token expires or is revoked. That is exactly why you should sign out, not just disconnect, before switching customers and on shared machines.

### Two things that are easy to miss

- The cache belongs to the `Microsoft.Graph` module and is **shared**, not private to this application. Signing out therefore also ends the cached session of **other** PowerShell tools used by the same Windows user.
- Signing out only deletes the **local** copy. The refresh token stays valid at Entra ID and is **not revoked**. If you genuinely suspect an account or device is compromised, signing out is not enough: revoke the sessions centrally in the Entra portal as well.

### How many sign-in addresses are remembered

The dropdown next to the address field offers the addresses used before, most recent first. It keeps **20** of them by default; beyond that the oldest drops off the end. The list is pure convenience — it suggests an address, it holds no session open.

If you look after more customers than that, raise `MaxRecentLogins` in the settings file (1 to 50, anything outside falls back to 20):

```text
%APPDATA%\WinTunerGUI\settings.json
```

```powershell
# close the application first - it writes this file when it exits
$p = "$env:APPDATA\WinTunerGUI\settings.json"
$s = Get-Content -Raw -LiteralPath $p | ConvertFrom-Json
$s.MaxRecentLogins = 30
$s | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $p -Encoding utf8
```

> [!NOTE]
> An installation that has been in use for a while carried `MaxRecentLogins = 8` or `15` — the default of earlier versions, because an existing settings file keeps its value. Since 0.19.0 such a value is raised **once**, on the next start, to today's 20; the log names the previous value. Once means once: set the list shorter after that and your value is kept. A value **above** 20 is left alone.

---

## Requirements

- Windows 10, Windows 11 or Windows Server with a desktop interface
- PowerShell 7.4 or newer
- WinGet / App Installer, for WinGet and Microsoft Store queries
- The `WinTuner` and `Microsoft.Graph` PowerShell modules
- A Microsoft Intune license in the **target tenant** you want to manage
- An account permitted in that **target tenant**, with the permissions listed below
- Internet access to the Microsoft, WinGet and optional GitHub endpoints

> [!NOTE]
> License and permission requirements always refer to the **target tenant** you select. What counts is the account you sign in with and its permissions in exactly the tenant whose Intune apps you want to manage.

### The WinTuner module: keep it current, and what the start checks

Everything this interface does — packaging, uploading, superseding, deleting, signing in — runs through the third-party **`WinTuner`** PowerShell module (the `*-Wt*` cmdlets). Its version therefore matters as much as this application's own.

**Keep it current.** The module renames parameters between versions, and a rename shows up as a failure in exactly the feature that uses it:

```powershell
Install-Module WinTuner -Scope CurrentUser -Force    # or: Update-Module WinTuner -Scope CurrentUser
Get-Module WinTuner -ListAvailable | Select-Object Version, ModuleBase
```

**What the start checks, and what it tells you:**

| Check | Message |
|---|---|
| Module installed? | Offers to install it, and names the command |
| All required commands present? | Names the missing ones and stops |
| Do those commands carry the **parameters** this application binds? | Names each missing parameter, says from which module version it exists, and gives you the update command |
| Are commands missing that affect only **one section**? | Warns and names them without stopping the start. The section is *Own installers*: building a package, replacing app content, reading MSI properties |
| Is the module installed **more than once**, with an older copy running? | Warns and names the loaded version, the newest one, and every location with its path |
| Module version 2.x or newer? | Warns that this interface is written against the 1.x line and has not been tested with it |

The lower three warnings in this table can be switched off with **Do not show this message again** — for exactly that content: if a *different* parameter goes missing later, or a *different* old version runs, the message comes back. Hidden messages still go to the activity log, and **Settings → Confirmations → Show all again** brings them back. The **failed module import** deliberately cannot be hidden: after it, everything but Settings is switched off, and that message is the only place the reason appears.

The parameter check exists because of a real report: a click on **Search** in *WinGet Apps* ended in an error dialog with a stack trace, `A parameter cannot be found that matches parameter name 'SearchQuery'`. That machine ran module **1.0.4**, where the search parameter was still called `-PackageId`; it is `-SearchQuery` from **1.1.0** on. The command existed, so the old check saw nothing — the failure surfaced at the click instead of at the start. Now it is named at the start, and a failed search is a status line rather than a crash.

> [!WARNING]
> **If several module versions are installed, the newest one does NOT win — the first one in `PSModulePath` does.** This said the opposite until 0.18.1; measured on 2026-09-07 on a machine carrying 1.4.1 in the user profile and 1.3.2 under `C:\Program Files\WindowsPowerShell\Modules`, the same machine loads either one depending on the path order. An old copy installed for **all users** can therefore mask a newer one in your own profile — and the symptoms look like bugs in this application.
>
> The start now checks for it: if an older copy is running while a newer one is installed, a message names both versions and every path. To look and clean up yourself:
>
> ```powershell
> Get-Module WinTuner -ListAvailable | Select-Object Version, ModuleBase
> Uninstall-Module WinTuner -RequiredVersion <the old version>
> ```
>
> The log carries both numbers: the highest **installed** one in the session header, and the actually **loaded** one in the line `WinTuner module … loaded from …`.

The application's **own** update check is separate from this: it looks at the GitHub releases of WinTuner GUI at start (switchable off in Settings) and offers to replace the script. It says nothing about the module.

---

## Account and permissions

### Use a dedicated account, not a Global Administrator

**Global Administrator is not required to run this application, and we recommend against using one.** The tool creates Intune apps, changes assignments and deletes app objects. More rights than that only widen the damage a mistake or a compromised account can do.

Use a **dedicated administration account** for this task alone, with multi-factor authentication and no mailbox or end-user function. In Intune, the built-in role is enough:

| Task | Matching Intune role |
|---|---|
| Deploy, update, assign and delete apps | **Application Manager** |
| Evaluate only, change nothing | **Read Only Operator** |

**Application Manager** covers exactly what this tool does: read, create, modify, assign, delete and relate mobile apps (supersedence), plus read managed devices. Microsoft itself recommends using these Intune roles for day-to-day Intune administration and avoiding Entra ID roles with Intune access, because most of those count as privileged.

You can narrow the reach further with **scope tags** and scope groups, so an account may only manage certain apps or device groups.

> [!IMPORTANT]
> The **one-time** consent to the Microsoft Graph permissions needs an account allowed to grant it, for example Application Administrator or Cloud Application Administrator. That happens once per tenant during initial setup. Day-to-day operation then only needs the account with the Intune role.

### Microsoft Graph permissions (delegated)

Sign-in uses the `WinTuner` module and its app registration, requesting `https://graph.microsoft.com/.default`, which is exactly the scope the tenant has consented to. Functionally, the application needs:

| Permission | Used for | Type |
|---|---|---|
| `DeviceManagementApps.ReadWrite.All` | Reading and writing Intune apps: deploy, update, supersede, delete, assignments and assignment settings, installation reports | Write |
| `DeviceManagementManagedDevices.Read.All` | The "Discovered apps" inventory (`/deviceManagement/detectedApps`) | Read |
| `Group.Read.All` | **Optional.** Only to search Entra ID groups *by name* under "All tenant apps" | Read |

`Group.Read.All` is deliberately **not** requested at sign-in. The application asks for it separately, with an explanation, only when you actually use the name search. Without it everything else works unchanged and groups can be assigned by object ID.

If you use the application **for evaluation only** (dashboard, update scan, tenant overview, discovered apps), `DeviceManagementApps.Read.All` is functionally sufficient instead of `.ReadWrite.All`. A dedicated read-only mode that requests just that scope is planned but not implemented yet.

Depending on the tenant, administrator consent, Conditional Access policies or further organisational approvals may also be required.

---

## A typical run

1. Connect to the Microsoft 365 tenant you want to work on.
2. Pick new apps from WinGet or the Microsoft Store, package your own installer, or check existing Intune apps for updates.
3. Review the package version, target group, intent and advanced assignment settings.
4. Confirm packaging or deployment explicitly.
5. Check the result in Intune and in the local activity log.

For an update there are two routes. Deploy the new version as its own app and supersede the old one (the default under **Updates**), or replace the content of the existing app (**Own installers**). The second route avoids ending up with several app objects per product, but it assumes the detection rules still fit.

---

## A fresh customer tenant, and the steady state

The tool is built for a **steady state**: set up once, a recurring run keeps a tenant's apps current without hand work. That state does not establish itself on the first run, though. A tenant that has not been managed with WinTuner or WinGet before needs a closer look **once**. After that, never again.

### The steady state: a few switches, and supersedence runs by itself

Routine operation rests on three settings. Together they close the loop: package the new version → upload → supersede the predecessor → move the assignment → clean up the old version. Nothing is left behind, and nobody has to finish the job in the portal.

| Setting | What it does for routine operation |
|---|---|
| **Move the group assignment to the new version (unassign the old one)** | Without it **both** versions carry the assignment after an update, and someone has to unassign the old one by hand in the portal. This is the switch that turns "an update was deployed" into "the new version is actually in use". |
| **Delete the predecessor version right after a successful update** *or* **Keep only the newest N versions per package and delete the rest** | Both clear away the superseded app objects — otherwise the **Superseded versions** tile grows with every single update. The two options are mutually exclusive: delete immediately, or keep a number. Either way nothing is deleted until assignments and successful installations have been checked again. |
| **Also check Win32 apps that carry no WinTuner marker** | The marker in the notes field only says **who** created an app — not whether a newer version exists. Without this switch, everything created by hand or with another tool stays invisible, and in an inherited tenant that is the majority. |

With these switches set and the mappings verified once, a run via **Update all** can go through without a single click (**Skip the confirmation prompts before changes in Intune**). Protected apps still ask — that one question deliberately cannot be suppressed.

#### When ancient versions simply never go away

An old version is kept as long as Intune reports it installed **somewhere**. That report never expires: a device that stopped checking in eight months ago blocks the version on it forever. In a tenant that has grown over years, copies pile up that nobody needs and no cleanup can remove.

That is what **Ignore installations on devices quiet for (days)** is for. With a value there, an installation only counts if the device synced within that time. Four things about it are deliberately narrow:

- The default is **0**, i.e. unchanged behaviour — a setting that authorises deletions does not switch itself on.
- It applies to the **manual** cleanup only. The automatic cleanup after an update always keeps the strict rule: nothing should be deleted without a click and without a look while Intune still reports it installed.
- A **single active device** still blocks, even next to twenty quiet ones. That is why a plain count threshold ("only block from X installations upwards") is the weaker criterion.
- A device whose sync date is unknown always counts as **active**.

> [!IMPORTANT]
> Deleting an app does **not** uninstall it from the device. The software stays installed; Intune loses the reporting, the assignment and the option to reinstall from that app object. So the safety net protects manageability, not the devices — which is exactly why relaxing it for long-quiet devices makes sense.

The log now gives the reason in both directions: when a version is kept, the newest device contact ("newest device contact 214 day(s) ago"), and when one is deleted despite reported installations, that all of them were on quiet devices.

### It gets easier once every app has gone through this tool once

The mapping "which Intune app is which WinGet package" is the one thing this tool cannot guess reliably. It does not have to guess when the answer is written down — and it is written down as soon as an app has been created or superseded through WinTuner: the app's **notes** field in Intune then carries a marker of the form

```
[WinTuner|winget|Google.Chrome]
```

That marker holds the **package id**, and reading it is exact — no name comparison, no similarity score, no ambiguity. So the first round is the expensive one, and every app that has been superseded once through this tool leaves the guessing behind for good. In a tenant where every app has gone through once, the update scan is simply a lookup.

Two consequences worth knowing:

- **Leave the notes field alone.** Clearing or overwriting it in the Intune portal throws the package id away. The app does not disappear from the scan — it falls back to matching by display name (see the first round below), and if that stays ambiguous, it shows up as a **blocked row** instead of as an update. If you use the notes field for your own comments, write them **next to** the marker, not over it.
- **A hand-written note counts too.** A notes field that just says `installed with WinGet: Google.Chrome` or `WinTuner - Zoom.ZoomRooms` is read as well, as long as the id looks like `Publisher.Product`. That is a deliberate second chance for apps whose marker has been removed at some point. It only ever **adds** an id, though: such an app stays in the unmarked list and is still checked there.

None of this replaces the **Also check Win32 apps that carry no WinTuner marker** switch — that one decides whether unmarked apps are looked at at all. The marker decides how precisely a looked-at app can be mapped.

### Why the first round is different

In a freshly inherited tenant, **no** app came from this tool. Four consequences follow that do not exist later on:

- **There is no mapping to WinGet.** No marker, no package id in the notes field; only a display name somebody chose freely. Mapping name → WinGet id is therefore the critical step of the first round. It is only accepted on an **exact** name match, a clearly dominant match, or a stored mapping — anything ambiguous is skipped. A wrong id would package the wrong product and supersede the real app.
- **Apps that could not be checked appear as blocked rows** with a reason ("no WinGet id could be mapped safely", "Intune reports no version"). They cannot be ticked and a run leaves them out. Where it makes sense, the id can be set by hand via right-click → **Assign WinGet id...**; the rest stays blocked on purpose.
- **Not all self-packaged apps are known yet.** Remote support, RMM and the common password managers are protected out of the box (the full list is below). **Customer-specific** installers are known to nobody but you — those belong on the protection list **before** the first run. An update on one of them builds a new app from the public catalogue, supersedes the hand-built one and moves its assignments; for a package built by hand, no second run brings that back.
- **Supersedence is not yet proven here.** Whether the assignment really moved to the new version only shows on a real run in this tenant.

### The protection list: what is protected out of the box, and how to get past it

These patterns are on the list from the first start, because their installers carry something a package built from the public catalogue does not have: the assignment to whoever maintains the machine (tenant id, customer key, a generated installer), or a policy file and SSO binding.

| Group | Patterns |
|---|---|
| Remote support and RMM | `TeamViewer*`, `AnyDesk*`, `Splashtop*`, `ScreenConnect*`, `ConnectWise*`, `N-able*`, `N-central*`, `Datto*`, `NinjaOne*`, `NinjaRMM*`, `Atera*`, `Action1*`, `BeyondTrust*`, `Jamf*`, `Kaseya*`, `TacticalRMM*`, `Tactical RMM*`, `Level.io*`, `Syncro`, `Syncro *`, `Pulseway*`, `ImmyBot*`, `SuperOps*`, `Naverisk*`, `CentraStage*`, `Bomgar*` |
| Password managers | `Keeper*`, `1Password*`, `Bitwarden*`, `LastPass*`, `KeePass*` |

Replacing one of these with the plain vendor build installs the same product "empty": the machine stops reporting to anybody, and the very access you would need to repair it is the thing that is gone.

**Protected does not mean blocked.** The app stays visible in the update list, stays tickable, and still shows that a newer version exists. The only difference is that a run asks about it explicitly — and that question is asked even with **Skip the confirmation prompts before changes in Intune** switched on.

> [!NOTE]
> **It is one question, not three.** This section and the two that follow describe three kinds of finding — marked as self-packaged, package id merely guessed, a copy of another packaging type already in the tenant. Before a run they arrive **together in one dialog**, grouped by kind, each app with its version and every reason that applies. Up to 0.19.0 these were three dialogs in a row, and an app carrying two findings was asked about twice. The three ways, and the fact that this question cannot be switched off, are unchanged.

Three ways past it, from the most local to the most permanent:

1. **For this one run:** the question offers **Run all of them anyway**. The other buttons are **Continue without these** (the default) and Cancel. Closing the dialog without clicking always means cancel, never "run everything".
2. **For this one app, permanently:** right-click its row in the update list and remove the protection. The status line confirms with **Protection removed: ...**.
3. **For a whole pattern:** **Protected apps...** in the update view, or the same list under **Settings → Self-packaged apps**. Select the entry, **Remove selected**. Changes take effect and are saved immediately; the **Save Settings** button is not involved.

Two properties of the list that matter in day-to-day use:

- **A pattern you remove does not come back.** The tool remembers which factory patterns it has offered you once, so your decision stands across restarts — and a pattern added to the factory list in a later version still reaches an **existing** installation.
- **The list is global, not per customer.** A per-tenant list would start out empty in every new environment, and that is exactly where the accident happens.

An entry without `*` or `?` matches the app name exactly; with a wildcard it is a pattern — `Zoom Rooms` protects one app, `Zoom*` protects all of them.

### When the same software already exists as a different packaging type

This application packages **Win32** only (`.intunewin`). In a tenant that has grown over years, the same software often also exists as **MSI line-of-business**, a **Store app** or **AppX** — created long ago, by another tool, or by hand.

Up to 0.18.1 the update scan did **not** see those: it discarded every app type but Win32. In the reported case that produced "Google Chrome 151.0.7922.72 → 153.0.8010.37, to be created" while the tenant held an **assigned** MSI version 152.0.7977.83. A run would have built a third copy that nobody is assigned to — the devices would have kept installing the MSI.

Now:

- The row says so **before** you tick it, in the warning colour: *the tenant already has 152.0.7977.83 as MSI* — and if that copy is assigned, it says that explicitly.
- Before the run, the question lists every affected app with its target version, the existing version and its type. It cannot be dismissed by **Skip confirmations**.
- Three ways: **Continue without these** (default), **Run all of them anyway**, Cancel.

**The other copy is never touched** — neither updated nor deleted, because this application cannot take responsibility for a type it does not build. "Run all of them anyway" is the right choice when you deliberately want to move to Win32 packaging: the new version is created, you assign it, and the old copy's assignment can then be moved via **All tenant apps → Clean up duplicate assignments**.

> [!NOTE]
> This hint depends on the setting **Also check Win32 apps that carry no WinTuner marker**: only then is the tenant read in full, and only then can foreign packaging types be seen at all. With it off, the log says explicitly that the hint was not possible in this run — so its absence does not mean "there are none".

### The second guard: when the package id is only a guess

The protected list works on the app **name**. There is a second case that costs just as much and that no name reveals: the app is in Intune, but nobody recorded which WinGet package belongs to it.

The application then looks for the id in this order, and only the first three are dependable:

| Where the id comes from | Dependable? |
|---|---|
| You recorded it yourself (`WingetOverrides` in `settings.json`) | yes, your statement |
| The id is in the app itself (WinTuner marker in the notes field) | yes, written down |
| The display name matches a WinGet name **exactly** | yes |
| **No exact match, only a similarity match** (name similarity ≥ 80 and at least 15 points ahead of the runner-up) | **no — a guess** |

In that last case a run may package the **wrong product**, supersede the existing app with it and move its assignments. Example: Intune holds a self-built app *Acrobat Reader DC (netgo)*, WinGet does not know it, but *Adobe Acrobat Reader DC* is close enough — and afterwards your tenant carries the bare vendor build while your own package has been superseded.

So since 0.19.0:

- The row in the update list says so **before** you tick it: *package id guessed from the name*, in the warning colour.
- Before the run, the question lists **every** guessed id with its app name and package id. It cannot be dismissed by **Skip confirmations before changes in Intune** — same as for protected apps.
- The same three ways: **Continue without these** (default), **Run all of them anyway**, Cancel.
- No app is asked about twice. If it carries several findings it appears once — under the most serious one — and its line names every reason.

To fix a guessed mapping for good, record the id: right-click the row in the update list and assign it. From then on it counts as your statement and the question stays away.

### Suggested order for the first round

1. Connect and run the update scan with **Also check Win32 apps that carry no WinTuner marker** switched on. Only then does the list see what is actually there.
2. Walk the **blocked rows**: read the reason, map the WinGet id where it is unambiguous, leave the rest. An unmapped app is inconvenient; a wrongly mapped one is expensive.
3. **Protect self-packaged apps** while nothing is running yet.
4. Start the first run with **confirmations on** and **cleanup off**, on two or three uncritical apps — not on all of them.
5. Check in Intune: does the new app carry the assignments? Is the predecessor listed as superseded? The activity log records both.
6. **Only then** switch on routine operation: cleanup, and confirmations off if you want that.

> [!IMPORTANT]
> The risky options are off by default for a reason. Switching them on in a tenant nobody has verified yet means automating deletions before anyone has seen whether the mappings in this tenant are correct.

---

## Limits and responsibility

- Package quality depends on the available WinGet metadata and installers, and on the detection and requirement rules WinTuner produces.
- Apps without a reliable WinGet match cannot be updated or managed automatically.
- Tenant-specific policies, filters, restart behaviour, dependencies and installation contexts have to be checked beforehand.
- Use in production environments is at your own risk. No warranty is given for effects caused by WinTuner, Microsoft Graph, WinGet packages or tenant-specific configuration.
- WinTuner GUI is not a Microsoft product and is neither provided nor supported by Microsoft.

---

## Project status

> [!WARNING]
> **Beta.** WinTuner GUI is not released as stable. Features, workflows and settings can change between versions, including without a migration path. It is not yet approved for production use in customer environments.

What that means in practice:

- Run any action that changes Intune in a test tenant or against a test group first.
- Verify results in Intune and in the activity log rather than relying on what the interface reports.
- Versions are marked as pre-releases. An update can change behaviour.

Current versions and their checksums are on the [releases page](../../releases). Bug reports and suggestions are welcome through [GitHub Issues](../../issues), particularly during the beta.

---

## License and origin

WinTuner GUI is licensed under the [GNU General Public License v3.0](LICENSE).

This is an independent project. At runtime it requires the [WinTuner](https://github.com/svrooij/WinTuner) PowerShell module by Stephan van Rooij, which is also licensed under GPL-3.0. The module is not bundled; it is installed from the PowerShell Gallery when needed. WinTuner GUI was deliberately placed under the same license so that the close coupling to that module stays legally unambiguous.

WinGet and Microsoft Graph are only called, not redistributed.

WinTuner GUI is not affiliated with Microsoft or with the WinTuner project, and is not endorsed by either.
