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
  `%LOCALAPPDATA%\.IdentityService`, encrypted with DPAPI for your Windows user. Signing out
  deletes the local copy but does not revoke the token at Entra ID.
- **Local logs contain tenant data**: Intune app ids, Entra group ids and assignment details in
  clear text. They live under `%LOCALAPPDATA%\WinTunerGUI\Logs` and are deleted after two weeks.
- **"Own installers" can run an installer on the local machine** to work out a detection rule.
  That is the point of the feature, and it runs only when you start it.
