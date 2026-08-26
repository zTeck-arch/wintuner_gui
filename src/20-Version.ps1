# Returns the current-language string for $Key (falls back to English, then the key
# name itself, so a missing translation never crashes the UI).
function Get-UiString {
  param([Parameter(Mandatory=$true)][string]$Key)
  $lang = if ($script:i18n.ContainsKey($script:uiLanguage)) { $script:uiLanguage } else { 'en' }
  if ($script:i18n[$lang].ContainsKey($Key)) { return $script:i18n[$lang][$Key] }
  if ($script:i18n['en'].ContainsKey($Key)) { return $script:i18n['en'][$Key] }
  return $Key
}

function Test-GuidString {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
  $parsed = [guid]::Empty
  return [guid]::TryParse($Value.Trim(), [ref]$parsed)
}

# Version comparison helper: returns $true if Latest > Current
function Get-ComparableVersionParts {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
  $m = [regex]::Match($Value.Trim(), '^[vV]?(?<core>\d+(?:\.\d+)*)(?<suffix>.*)$')
  if (-not $m.Success) { return $null }
  $core = @($m.Groups['core'].Value -split '\.' | ForEach-Object { [uint64]$_ })
  $suffix = $m.Groups['suffix'].Value.Trim()
  [pscustomobject]@{
    Core = $core
    Suffix = $suffix
    SuffixNumbers = @([regex]::Matches($suffix, '\d+') | ForEach-Object { [uint64]$_.Value })
    IsPrerelease = [bool]($suffix -match '(?i)(^|[-_.\s])(alpha|beta|preview|pre|rc|dev)(\d|[-_.\s]|$)')
  }
}

function Test-IsNewerVersion {
    param([string]$Latest, [string]$Current)
    if (-not $Latest -or -not $Current) { return $false }
    # No [version] shortcut. .NET pads a missing component with -1, so [version]'1.2.0' is GREATER
    # than [version]'1.2' - while Test-VersionsEquivalent pads with 0 and calls the same pair equal.
    # The two answers contradicted each other for the same input, and both are used side by side in
    # the scan and in the self-update: an app could be offered an "update" to the version it already
    # had. One comparison for everything, padding with 0, matching the equivalence rule.
    $left = Get-ComparableVersionParts $Latest
    $right = Get-ComparableVersionParts $Current
    if (-not $left -or -not $right) { return $false }

    $len = [Math]::Max($left.Core.Count, $right.Core.Count)
    for ($i = 0; $i -lt $len; $i++) {
        $a = if ($i -lt $left.Core.Count) { $left.Core[$i] } else { 0 }
        $b = if ($i -lt $right.Core.Count) { $right.Core[$i] } else { 0 }
        if     ($a -gt $b) { return $true }
        elseif ($a -lt $b) { return $false }
    }
    # A stable release is newer than its alpha/beta/preview/RC, never the other way around.
    if ($left.IsPrerelease -and -not $right.IsPrerelease) { return $false }
    if (-not $left.IsPrerelease -and $right.IsPrerelease) { return $true }
    # Numeric vendor builds such as "7.1.5 (43453)" and RC counters are compared only after
    # the dotted core matched. Unknown textual suffixes do not trigger a risky update guess.
    $suffixLen = [Math]::Max($left.SuffixNumbers.Count, $right.SuffixNumbers.Count)
    for ($i = 0; $i -lt $suffixLen; $i++) {
        $a = if ($i -lt $left.SuffixNumbers.Count) { $left.SuffixNumbers[$i] } else { 0 }
        $b = if ($i -lt $right.SuffixNumbers.Count) { $right.SuffixNumbers[$i] } else { 0 }
        if     ($a -gt $b) { return $true }
        elseif ($a -lt $b) { return $false }
    }
    return $false
}

function Test-VersionsEquivalent {
  param([string]$Left, [string]$Right)
  if ([string]::IsNullOrWhiteSpace($Left) -or [string]::IsNullOrWhiteSpace($Right)) { return $false }
  if ([string]::Equals($Left.Trim(), $Right.Trim(), [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
  $lp = Get-ComparableVersionParts $Left
  $rp = Get-ComparableVersionParts $Right
  if (-not $lp -or -not $rp) { return $false }
  $length = [Math]::Max($lp.Core.Count, $rp.Core.Count)
  for ($i = 0; $i -lt $length; $i++) {
    $lv = if ($i -lt $lp.Core.Count) { $lp.Core[$i] } else { 0 }
    $rv = if ($i -lt $rp.Core.Count) { $rp.Core[$i] } else { 0 }
    if ($lv -ne $rv) { return $false }
  }
  # Treat 1.2 and 1.2.0 as the same stable version, while keeping RC/vendor-build suffixes distinct.
  if (-not $lp.Suffix -and -not $rp.Suffix) { return $true }
  return [string]::Equals($lp.Suffix, $rp.Suffix, [System.StringComparison]::OrdinalIgnoreCase)
}


function Test-AppUpdateAvailable {
  <#
  .SYNOPSIS
    Checks GitHub for a newer release of WinTuner GUI
  .OUTPUTS
    PSCustomObject with properties: UpdateAvailable, LatestVersion, DownloadUrl, ReleaseUrl, ReleaseNotes, ErrorMessage
  #>
  $result = [pscustomobject]@{
    UpdateAvailable = $false
    LatestVersion   = $null
    DownloadUrl     = $null
    HashUrl         = $null
    ReleaseUrl      = $null
    ReleaseNotes    = $null
    ErrorMessage    = $null
    NotConfigured   = $false
    # 404 ist etwas anderes als "kein Netz": das Repository heisst anders oder hat noch kein
    # Release. Ohne diese Unterscheidung stand in der Statuszeile "bitte Internetverbindung
    # pruefen", waehrend die Verbindung tadellos war.
    NotFound        = $false
  }

  # No self-update repo configured (see $script:githubRepo at the top of the file) –
  # skip the check silently instead of hitting an empty URL.
  if ([string]::IsNullOrWhiteSpace($script:githubRepo)) {
    $result.NotConfigured = $true
    Write-Log "Update check skipped: no GitHub repository configured."
    return $result
  }

  try {
    # "App updates" hiess hier das Programm selbst - im Protokoll direkt neben dem Intune-Scan
    # gelesen, war das nicht zu unterscheiden. Jetzt sagt die Zeile, worum es geht.
    Write-Log ("Checking GitHub for a newer version of WinTuner GUI itself ({0})..." -f $script:githubApiUrl)

    $headers = @{
      'Accept'     = 'application/vnd.github.v3+json'
      'User-Agent' = 'WinTuner-GUI-UpdateCheck'
    }

    $savedDefaults = $PSDefaultParameterValues.Clone()
    try {
      $PSDefaultParameterValues = @{}
      $response = Invoke-RestMethod -Uri $script:githubApiUrl -Headers $headers -TimeoutSec 10 -ErrorAction Stop
    } finally {
      $PSDefaultParameterValues = $savedDefaults
    }

    # Extract version from tag_name (strip leading "v" and any suffix like "-Beta")
    $remoteTag = $response.tag_name
    $remoteVersionStr = $remoteTag -replace '^v', ''
    $cleanVersion = $remoteVersionStr -replace '-.*$', ''  # Remove "-Beta", "-RC1" etc.

    $result.LatestVersion = $cleanVersion
    $result.ReleaseUrl    = $response.html_url
    $result.ReleaseNotes  = $response.body

    # Automatic replacement is allowed only for the two deterministic release assets produced by
    # the repository workflow. Never select an arbitrary first .ps1/.sha256 file from a release.
    $ps1Asset = $response.assets | Where-Object {
      [string]::Equals([string]$_.name, $script:updateAssetName, [System.StringComparison]::OrdinalIgnoreCase)
    } | Select-Object -First 1
    $shaAsset = $response.assets | Where-Object {
      [string]::Equals([string]$_.name, $script:updateHashAssetName, [System.StringComparison]::OrdinalIgnoreCase)
    } | Select-Object -First 1
    if ($ps1Asset -and $shaAsset) {
      $result.DownloadUrl = $ps1Asset.browser_download_url
      $result.HashUrl = $shaAsset.browser_download_url
    } elseif ($ps1Asset) {
      Write-Log ("GitHub release {0} contains the script but not the required checksum asset {1}; automatic replacement is disabled for this release." -f $remoteTag, $script:updateHashAssetName)
    } else {
      Write-Log ("GitHub release {0} does not contain the required script asset {1}; automatic replacement is disabled for this release." -f $remoteTag, $script:updateAssetName)
    }

    # Compare versions using existing function
    if (Test-IsNewerVersion -Latest $cleanVersion -Current $script:appVersion) {
      $result.UpdateAvailable = $true
      Write-Log "Update available: $($script:appVersion) -> $cleanVersion"
    } else {
      Write-Log "App is up to date (v$($script:appVersion), latest: v$cleanVersion)"
    }

  } catch {
    $result.ErrorMessage = $_.Exception.Message
    $status = 0
    try { if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode } } catch { $status = 0 }
    if ($status -eq 404 -or $_.Exception.Message -match '404') {
      $result.NotFound = $true
      Write-Log ("Update check: GitHub answered 404 for {0}. Either the repository '{1}' does not exist under that name (renamed?) or it has no published release yet." -f $script:githubApiUrl, $script:githubRepo)
    } else {
      Write-Log "Update check failed: $($_.Exception.Message)"
    }
  }

  return $result
}

# Refuses a self-update URL that is not plain HTTPS, and names the host it is about to trust.
#
# The two URLs the self-update fetches - the script and its checksum - are taken verbatim from the
# GitHub API response and were handed to Invoke-WebRequest unexamined. Nothing forced the scheme, so
# an 'http://' or a 'file://' in that response would have been followed just as happily, and the log
# never said which host the replacement of the running script came from.
#
# This is NOT presented as protection against a compromised GitHub account or a hostile release: if
# the API answer itself is untrustworthy, so is any URL in it, and the allowlist below would wave it
# through. What it does buy is real but modest: no downgrade to an unencrypted transport, no local or
# UNC path masquerading as a download, and a host recorded in the log for afterwards.
#
# Pure so it can be tested without the network.
function Test-SelfUpdateUrlAcceptable {
  param(
    [string]$Url,
    [string[]]$AllowedHosts = @('github.com', 'objects.githubusercontent.com', 'release-assets.githubusercontent.com', 'api.github.com')
  )
  $out = [pscustomobject]@{ Acceptable = $false; UrlHost = ''; Reason = '' }
  if ([string]::IsNullOrWhiteSpace($Url)) { $out.Reason = 'empty URL'; return $out }
  $uri = $null
  if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri)) { $out.Reason = 'not an absolute URL'; return $out }
  $out.UrlHost = [string]$uri.Host
  if ($uri.Scheme -ne 'https') { $out.Reason = ("scheme '{0}' is not https" -f $uri.Scheme); return $out }
  # Subdomain match is deliberate: GitHub serves release assets from hosts it changes over time.
  $isAllowed = $false
  foreach ($allowed in $AllowedHosts) {
    if ([string]::Equals($out.UrlHost, $allowed, [System.StringComparison]::OrdinalIgnoreCase) -or
        $out.UrlHost.EndsWith('.' + $allowed, [System.StringComparison]::OrdinalIgnoreCase)) {
      $isAllowed = $true; break
    }
  }
  if (-not $isAllowed) { $out.Reason = ("host '{0}' is not a known GitHub download host" -f $out.UrlHost); return $out }
  $out.Acceptable = $true
  return $out
}

# How many previous versions stay recoverable next to the script. Two is enough to step back past a
# bad release without turning the folder into an archive.
$script:selfUpdateBackupsToKeep = 2

# Prunes the backups the self-update leaves behind, newest first. Also catches the single
# "<script>.backup" that older versions wrote, so upgrading does not strand it forever.
#
# Best effort by design: a backup that cannot be deleted (locked, read-only, no permission) is
# logged and skipped. Failing the update over a leftover file would be the worse outcome - the new
# version is already in place by then.
function Remove-OldSelfUpdateBackups {
  param(
    [Parameter(Mandatory)][string]$ScriptPath,
    [int]$Keep = 2
  )
  if ($Keep -lt 1) { $Keep = 1 }
  try {
    $folder = Split-Path -Parent $ScriptPath
    $leaf = Split-Path -Leaf $ScriptPath
    if ([string]::IsNullOrWhiteSpace($folder)) { return }
    $backups = @(Get-ChildItem -LiteralPath $folder -File -ErrorAction Stop |
      Where-Object {
        $_.Name.StartsWith("$leaf.", [System.StringComparison]::OrdinalIgnoreCase) -and
        $_.Name.EndsWith('.backup', [System.StringComparison]::OrdinalIgnoreCase)
      } | Sort-Object LastWriteTime -Descending)
    if ($backups.Count -le $Keep) { return }
    foreach ($old in $backups[$Keep..($backups.Count - 1)]) {
      try {
        Remove-Item -LiteralPath $old.FullName -Force -ErrorAction Stop
        Write-Log ("Removed old update backup: {0}" -f $old.Name)
      } catch {
        Write-Log ("Could not remove old update backup {0}: {1}" -f $old.Name, $_.Exception.Message)
      }
    }
  } catch {
    Write-Log ("Backup cleanup skipped: {0}" -f $_.Exception.Message)
  }
}

# Replaces the running script at $CurrentPath with the already-staged file at $StagedPath, keeping a
# timestamped backup, then VERIFIES the on-disk result carries $ExpectedVersion before returning.
#
# Two things this guards against, learned the hard way:
#   * [IO.File] methods take literal paths for source AND destination. Copy-Item/Move-Item still glob
#     '[' and ']' in -Path/-Destination, so a script in a folder like 'WinTuner [test]' had its move
#     silently skipped while the caller reported success.
#   * Reading the file back and checking the version turns ANY silent non-replacement (bracket path,
#     locked file, a move that failed without throwing) into a thrown error instead of a false
#     "update installed" that leaves the user on the old version.
function Install-SelfUpdateFile {
  param(
    [Parameter(Mandatory)][string]$StagedPath,
    [Parameter(Mandatory)][string]$CurrentPath,
    [Parameter(Mandatory)][string]$BackupPath,
    [Parameter(Mandatory)][string]$ExpectedVersion
  )
  if (Test-Path -LiteralPath $CurrentPath) {
    [System.IO.File]::Copy($CurrentPath, $BackupPath, $true)
    Write-Log "Backup created: $BackupPath"
    Remove-OldSelfUpdateBackups -ScriptPath $CurrentPath -Keep $script:selfUpdateBackupsToKeep
  }

  try {
    [System.IO.File]::Move($StagedPath, $CurrentPath, $true)
  } catch {
    if ((Test-Path -LiteralPath $BackupPath) -and -not (Test-Path -LiteralPath $CurrentPath)) {
      try { [System.IO.File]::Copy($BackupPath, $CurrentPath, $true) } catch { }
    }
    throw
  }

  $installed = Get-Content -LiteralPath $CurrentPath -Raw -ErrorAction Stop
  $installedMatch = [regex]::Match($installed, '(?m)^\s*\$script:appVersion\s*=\s*["''](?<version>[^"'']+)["'']\s*$')
  if (-not $installedMatch.Success -or
      -not (Test-VersionsEquivalent -Left ([string]$installedMatch.Groups['version'].Value) -Right $ExpectedVersion)) {
    throw "Self-update verification failed: the script on disk does not report version $ExpectedVersion after replacement."
  }
}

function Invoke-AppSelfUpdate {
  param(
    [Parameter(Mandatory=$true)]
    [string]$DownloadUrl,
    [Parameter(Mandatory=$true)]
    [string]$HashUrl,
    [Parameter(Mandatory=$true)]
    [string]$ExpectedVersion
  )

  try {
    # Determine current script path
    $currentPath = $null
    if ($PSCommandPath) {
      $currentPath = $PSCommandPath
    } elseif ($MyInvocation.ScriptName) {
      $currentPath = $MyInvocation.ScriptName
    } else {
      # No second question. There used to be a Save-As dialog here, which was wrong twice over: it
      # asked the user something the tool has to know by itself, and saving a copy somewhere else
      # does not update the script that is actually running. If the running path is unknown, the
      # in-place update cannot be done - say so and point at the manual download.
      Write-Log "Self-update aborted: the path of the running script could not be determined."
      throw (Get-UiString 'UpdPathUnknown')
    }

    # Both URLs are checked before either is fetched: the checksum is what makes the script
    # trustworthy, so a checksum from somewhere else is worth no more than no checksum at all.
    foreach ($candidate in @(
      @{ Label = 'script';   Url = $DownloadUrl },
      @{ Label = 'checksum'; Url = $HashUrl })) {
      $verdict = Test-SelfUpdateUrlAcceptable -Url ([string]$candidate.Url)
      if (-not $verdict.Acceptable) {
        Write-Log ("Self-update aborted: the {0} URL was rejected ({1}). URL: {2}" -f $candidate.Label, $verdict.Reason, $candidate.Url)
        throw ((Get-UiString 'UpdUrlRejected') -f $candidate.Label, $verdict.Reason)
      }
    }

    Write-Log "Downloading update from: $DownloadUrl"
    Write-Log ("Self-update hosts: script from '{0}', checksum from '{1}'." -f
      (Test-SelfUpdateUrlAcceptable -Url $DownloadUrl).UrlHost,
      (Test-SelfUpdateUrlAcceptable -Url $HashUrl).UrlHost)
    Update-Status (Get-UiString 'UpdDownloadingStatus')

    $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) ("WinTuner_GUI_ntg_{0}.ps1" -f [guid]::NewGuid().ToString('N'))

    # Temporarily clear PSDefaultParameterValues to prevent parameter binding conflicts
    # (wildcard entries like '*:ProgressAction' can corrupt URI resolution in some PS7 builds)
    $savedDefaults = $PSDefaultParameterValues.Clone()
    try {
      $PSDefaultParameterValues = @{}
      $headers = @{ 'User-Agent' = 'WinTuner-GUI-UpdateCheck' }
      Invoke-WebRequest -Uri $DownloadUrl -OutFile $tempFile -Headers $headers -TimeoutSec 60 -UseBasicParsing -ErrorAction Stop
    } finally {
      $PSDefaultParameterValues = $savedDefaults
    }

    # Validate download
    if (-not (Test-Path -LiteralPath $tempFile)) {
      throw "Download failed: temp file not found"
    }
    $fileSize = (Get-Item -LiteralPath $tempFile).Length
    if ($fileSize -lt 1000) {
      throw "Download failed: file too small ($fileSize bytes)"
    }
    $content = Get-Content -LiteralPath $tempFile -Raw -ErrorAction Stop
    # Beide Namen gelten: der heruntergeladene Stand kann aus der Zeit vor der Umbenennung
    # stammen (dann steht "WinTuner GUI" darin) oder danach. Nur einen zu akzeptieren, laesst
    # genau den einen Ubergang scheitern, der die Umbenennung ueberhaupt ausliefert.
    if ($content -notmatch 'WinTuner GUI' -and $content -notmatch 'WinTuner GUI') {
      throw "Download validation failed: file appears to be neither WinTuner GUI nor its predecessor WinTuner GUI"
    }

    # A checksum is mandatory for in-place updates. Network errors and malformed checksum files are
    # failures, not reasons to silently install an unverified script.
    Write-Log "Verifying SHA256 integrity..."
    $savedDefaults2 = $PSDefaultParameterValues.Clone()
    try {
      $PSDefaultParameterValues = @{}
      $hashText = [string](Invoke-RestMethod -Uri $HashUrl -TimeoutSec 15 -ErrorAction Stop)
    } finally {
      $PSDefaultParameterValues = $savedDefaults2
    }
    $expectedHash = (($hashText.Trim() -split '\s+')[0]).ToUpperInvariant()
    if ($expectedHash -notmatch '^[A-F0-9]{64}$') { throw 'The release checksum asset is malformed.' }
    $actualHash = (Get-FileHash -LiteralPath $tempFile -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($actualHash -ne $expectedHash) {
      throw "SHA256 mismatch: download may be corrupt or tampered! Expected: $expectedHash, Got: $actualHash"
    }
    Write-Log "SHA256 verified OK: $actualHash"

    # The release tag and the downloaded script must describe the same version. This prevents an
    # accidentally stale asset from being installed under a newer GitHub tag.
    $versionMatch = [regex]::Match($content, '(?m)^\s*\$script:appVersion\s*=\s*["''](?<version>[^"'']+)["'']\s*$')
    if (-not $versionMatch.Success) { throw 'Downloaded script does not contain a readable appVersion.' }
    $downloadedVersion = [string]$versionMatch.Groups['version'].Value
    if (-not (Test-VersionsEquivalent -Left $downloadedVersion -Right $ExpectedVersion)) {
      throw "Release version mismatch: GitHub reports $ExpectedVersion, downloaded script contains $downloadedVersion."
    }

    Write-Log "Download complete ($fileSize bytes). Replacing script..."

    # Stage the verified bytes beside the running script so replacement happens on the same volume.
    # Keep a recoverable backup; if replacement fails, the original remains available.
    #
    # The backup carries the version it holds and is kept alongside the previous one, so a bad
    # release can be rolled back to a KNOWN version rather than to "whatever .backup happened to
    # contain". Older ones are pruned - see Remove-OldSelfUpdateBackups.
    $backupPath = "{0}.{1}.backup" -f $currentPath, (Get-Date -Format 'yyyyMMdd-HHmmss')
    $stagedPath = "$currentPath.update"
    # Stage the verified bytes beside the running script (same volume), then replace-and-verify.
    [System.IO.File]::Copy($tempFile, $stagedPath, $true)
    Install-SelfUpdateFile -StagedPath $stagedPath -CurrentPath $currentPath -BackupPath $backupPath -ExpectedVersion $ExpectedVersion
    Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue

    Write-Log "Script replaced and verified ($ExpectedVersion). Restart required."
    return $true

  } catch {
    Write-Log "Self-update failed: $($_.Exception.Message)"
    if ($tempFile -and (Test-Path -LiteralPath $tempFile)) {
      Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
    }
    if ($stagedPath -and (Test-Path -LiteralPath $stagedPath)) {
      Remove-Item -LiteralPath $stagedPath -Force -ErrorAction SilentlyContinue
    }
    [System.Windows.Forms.MessageBox]::Show(
      ((Get-UiString 'UpdSelfUpdateFailedDialog') -f $_.Exception.Message, "https://github.com/$($script:githubRepo)/releases/latest"),
      (Get-UiString 'UpdSelfUpdateFailedTitle'),
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Error
    )
    return $false
  }
}

function Invoke-UpdateCheckFeedback {
  param(
    [object]$UpdateResult,
    [ValidateSet('Manual','Startup')]
    [string]$Context = 'Manual'
  )

  $isManual = ($Context -eq 'Manual')

  # No update source configured – tell the user (only if they clicked the button), then stop.
  if ($UpdateResult -and $UpdateResult.NotConfigured) {
    if ($isManual) {
      [System.Windows.Forms.MessageBox]::Show(
        (Get-UiString 'UpdNotConfiguredDialog'),
        (Get-UiString 'UpdNotConfiguredTitle'),
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
      )
    }
    Update-Status ((Get-UiString 'UpdNotConfiguredStatus') -f $script:appVersion)
    return
  }

  $errorDetail = if ($UpdateResult -and $UpdateResult.Error) { $UpdateResult.Error } `
                 elseif ($UpdateResult -and $UpdateResult.ErrorMessage) { $UpdateResult.ErrorMessage } `
                 else { $null }

  # 404: kein Netzproblem. Eigene Meldung, die den Repository-Namen nennt.
  if ($UpdateResult -and $UpdateResult.NotFound) {
    if ($isManual) {
      [void][System.Windows.Forms.MessageBox]::Show(
        ((Get-UiString 'UpdRepoNotFoundDialog') -f $script:githubRepo),
        (Get-UiString 'UpdCheckFailedTitle'),
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information)
    }
    Update-Status ((Get-UiString 'UpdRepoNotFoundStatus') -f $script:githubRepo)
    return
  }

  if ($errorDetail) {
    if ($isManual) {
      [System.Windows.Forms.MessageBox]::Show(
        ((Get-UiString 'UpdCheckFailedDialog') -f $errorDetail),
        (Get-UiString 'UpdCheckFailedTitle'),
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning
      )
    }
    Update-Status ((Get-UiString 'UpdCheckFailedStatus') -f $script:appVersion)
    return
  }

  # No version means the check did not reach GitHub - or never ran at all. That is a FAILED check,
  # not a verdict. It used to fall through to the "up to date" branch at the bottom and print
  # "GitHub: vunknown", so a permanently broken check looked exactly like being current and no
  # release could ever be offered. Everything below this point may assume a real version.
  if (-not $UpdateResult -or [string]::IsNullOrWhiteSpace([string]$UpdateResult.LatestVersion)) {
    Write-Log "Update check produced no version; reporting a failed check instead of 'up to date'."
    if ($isManual) {
      [System.Windows.Forms.MessageBox]::Show(
        ((Get-UiString 'UpdCheckFailedDialog') -f (Get-UiString 'UpdCheckNoVersion')),
        (Get-UiString 'UpdCheckFailedTitle'),
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning
      )
    }
    Update-Status ((Get-UiString 'UpdCheckFailedStatus') -f $script:appVersion)
    return
  }

  if ($UpdateResult -and $UpdateResult.UpdateAvailable) {
    Update-Status ((Get-UiString 'UpdAvailableStatus') -f $UpdateResult.LatestVersion)
    try {
      $msg = (Get-UiString 'UpdAvailableMsgHeader') -f $script:appVersion, $UpdateResult.LatestVersion

      if ($UpdateResult.DownloadUrl) {
        $msg += (Get-UiString 'UpdAvailableMsgDownloadPrompt')

        $answer = [System.Windows.Forms.MessageBox]::Show(
          $msg,
          (Get-UiString 'UpdAvailableTitle'),
          [System.Windows.Forms.MessageBoxButtons]::YesNo,
          [System.Windows.Forms.MessageBoxIcon]::Information
        )

        if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
          Update-Status (Get-UiString 'UpdDownloadingStatus')
          [System.Windows.Forms.Application]::DoEvents()

          $success = Invoke-AppSelfUpdate -DownloadUrl $UpdateResult.DownloadUrl -HashUrl $UpdateResult.HashUrl -ExpectedVersion $UpdateResult.LatestVersion

          if ($success) {
            Update-Status (Get-UiString 'UpdInstalledStatus')

            [System.Windows.Forms.MessageBox]::Show(
              (Get-UiString 'UpdRestartMsg'),
              (Get-UiString 'UpdCompleteTitle'),
              [System.Windows.Forms.MessageBoxButtons]::OK,
              [System.Windows.Forms.MessageBoxIcon]::Information
            )

            $form.Close()
          } else {
            Update-Status (Get-UiString 'UpdInstallFailedStatus')
          }
        } else {
          if ($isManual) {
            Update-Status (Get-UiString 'UpdPostponedStatus')
          } else {
            Update-Status ((Get-UiString 'UpdAvailableLaterStatus') -f $UpdateResult.LatestVersion)
          }
        }
      } else {
        Update-Status ((Get-UiString 'UpdAvailableManualStatus') -f $UpdateResult.LatestVersion)
        $msg += (Get-UiString 'UpdAvailableMsgManual') -f $UpdateResult.ReleaseUrl

        [System.Windows.Forms.MessageBox]::Show(
          $msg,
          (Get-UiString 'UpdAvailableTitle'),
          [System.Windows.Forms.MessageBoxButtons]::OK,
          [System.Windows.Forms.MessageBoxIcon]::Information
        )
      }
    } catch {
      Write-Log "$Context update dialog error: $($_.Exception.Message)"
      Update-Status (Get-UiString 'UpdDialogErrorStatus')
    }
    return
  }

  $latestVer = if ($UpdateResult -and $UpdateResult.LatestVersion) { $UpdateResult.LatestVersion } else { (Get-UiString 'UpdUnknownVersion') }
  Update-Status ((Get-UiString 'UpdUpToDateStatus') -f $script:appVersion, $latestVer)

  if ($isManual) {
    [System.Windows.Forms.MessageBox]::Show(
      ((Get-UiString 'UpdUpToDateDialog') -f $script:appVersion, $latestVer),
      (Get-UiString 'UpdUpToDateTitle'),
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Information
    )
  }
}

