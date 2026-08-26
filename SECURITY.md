# Security Policy

## Reporting a vulnerability

Please report security issues **privately**, not as a public issue.

**Preferred:** use GitHub's private reporting on this repository, under
**Security → Report a vulnerability**. The report stays visible only to the maintainers.

**Alternative:** <app.t.schnabel@posteo.de>

Please include what you need to describe the problem: affected version, what you did,
what happened, and what you expected. A proof of concept helps but is not required.

You will get an acknowledgement as soon as the report has been read. There is no
bug bounty; this is a small project maintained alongside other work.

## Supported versions

Only the latest release receives fixes. This project is in **beta**, and older
releases are not maintained.

## Scope

In scope, roughly ordered by how much they would matter:

- Anything that could make the tool change the **wrong Intune tenant** or the wrong app
- Package tampering between build and upload
- Credential or token handling, and the local session cache
- Detection or requirement rules that could be manipulated into matching wrongly
- The self-update path: asset selection, checksum verification, version comparison

Out of scope:

- Microsoft Intune, Microsoft Graph, WinGet packages and the WinTuner PowerShell module
  themselves. Report those to their respective maintainers.
- Anything that requires an attacker to already control the Windows account running the tool.
  On Windows, code running as your user can read what your user can read; the tool cannot
  defend against that and does not claim to.
- Missing code signing. The released script is deliberately unsigned, see below.

## Things you should know before reporting

Some properties are known and intentional. Reporting them is welcome, but they are not news:

- **The released script is not code signed.** Windows therefore marks it as downloaded from
  the internet, and it has to be unblocked once. Verify the published SHA-256 checksum if you
  want assurance about the file you downloaded.
- **The sign-in session is cached by the Microsoft Authentication Library** under
  `%LOCALAPPDATA%\.IdentityService` (the application's cache file is `WinTuner-PowerShell.nocae`),
  encrypted with DPAPI for your Windows user. Signing out deletes the local cache files but does
  not revoke the token at Entra ID.
- **Local logs contain tenant data**: Intune app ids, Entra group ids and assignment details in
  clear text. They live under `%LOCALAPPDATA%\WinTunerGUI\Logs` and are deleted after two weeks.
- **The performance record contains customer data**: `activity-history.json` under
  `%LOCALAPPDATA%\WinTunerGUI` holds tenant UPNs, app names and versions across the customers you
  worked on. It is kept per-user (not roamed), pruned to the same two-week window as the logs, and
  can be deleted at any time with "Clear" in the performance-record dialog.
- **Settings roam with your Windows profile**: `settings.json` under `%APPDATA%\WinTunerGUI` stores
  your preferences together with `RecentLogins` (admin UPNs) and `GroupFavorites` (customer domains
  and Entra group GUIDs). It is not size- or age-limited; clear recent logins and group favorites in
  the app if you do not want them to follow your profile.
- **"Own installers" can run an installer on the local machine** to work out a detection rule.
  That is the point of the feature, and it runs only when you start it.

## What leaves this machine

Read off the source, not from memory. Two separate lists, because the second one is not ours.

**The GUI itself contacts:**

| Host | When | Authenticated | What it carries |
|---|---|---|---|
| `graph.microsoft.com` | Every tenant read or write | Yes, your Intune sign-in | App, assignment and group data for the connected tenant |
| `api.github.com`, `github.com`, `objects.githubusercontent.com` | Update check and self-update, and only when a self-update repository is configured (`$script:githubRepo`; empty disables it) | No | Nothing about you or your tenants; it is a release lookup and a download |
| `displaycatalog.mp.microsoft.com` | Resolving a Microsoft Store app's title and publisher before deploying it | No | The Store product id plus your market and language |
| `winget.exe` (which reaches the WinGet community index, and the `msstore` source for Store searches) | Version lookups and Store search | No | The package id or the search text you typed |

Two notes on the WinGet calls: the GUI passes `--accept-source-agreements`, which accepts a source
agreement on your behalf without asking, and a Store search sends your free-text query to Microsoft.

**The required `WinTuner` PowerShell module additionally contacts** (found in the shipped assemblies
of version 1.4.1; the GUI never calls these hosts itself):

- `proxy.wintuner.app/api` — a third-party service operated by the module's author, reachable from
  `WinTuner.Proxy.Client.dll`. Whether a given action uses it depends on the module, not on this GUI.
- `github.com/microsoft/Microsoft-Win32-Content-Prep-Tool` — the module downloads
  `IntuneWinAppUtil.exe` from there **and runs it** while packaging.
- `github.com/microsoft/winget-cli` — the `Microsoft.DesktopAppInstaller` bundle.

If your environment restricts outbound traffic, those three are the ones that will surprise you, and
they are the module's behaviour rather than something this GUI can turn off. Reports about them
belong with the module's maintainer (see "Out of scope" above), but they are listed here because a
user of this GUI cannot see them any other way.
