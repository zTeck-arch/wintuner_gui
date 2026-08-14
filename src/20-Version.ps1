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
  }

  # No self-update repo configured (see $script:githubRepo at the top of the file) –
  # skip the check silently instead of hitting an empty URL.
  if ([string]::IsNullOrWhiteSpace($script:githubRepo)) {
    $result.NotConfigured = $true
    Write-Log "Update check skipped: no GitHub repository configured."
    return $result
  }

  try {
    Write-Log "Checking for app updates from GitHub..."

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
    Write-Log "Update check failed: $($_.Exception.Message)"
  }

  return $result
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

    Write-Log "Downloading update from: $DownloadUrl"
    Update-Status (Get-UiString 'UpdDownloadingStatus')

    $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) ("WinTunerGUI_{0}.ps1" -f [guid]::NewGuid().ToString('N'))

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
    if (-not (Test-Path $tempFile)) {
      throw "Download failed: temp file not found"
    }
    $fileSize = (Get-Item $tempFile).Length
    if ($fileSize -lt 1000) {
      throw "Download failed: file too small ($fileSize bytes)"
    }
    $content = Get-Content $tempFile -Raw -ErrorAction Stop
    if ($content -notmatch 'WinTuner GUI') {
      throw "Download validation failed: file doesn't appear to be WinTuner GUI"
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
    $actualHash = (Get-FileHash $tempFile -Algorithm SHA256).Hash.ToUpperInvariant()
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
    Copy-Item -Path $tempFile -Destination $stagedPath -Force -ErrorAction Stop
    if (Test-Path $currentPath) {
      Copy-Item -Path $currentPath -Destination $backupPath -Force -ErrorAction Stop
      Write-Log "Backup created: $backupPath"
      Remove-OldSelfUpdateBackups -ScriptPath $currentPath -Keep $script:selfUpdateBackupsToKeep
    }

    try {
      Move-Item -Path $stagedPath -Destination $currentPath -Force -ErrorAction Stop
    } catch {
      if ((Test-Path $backupPath) -and -not (Test-Path $currentPath)) {
        Copy-Item -Path $backupPath -Destination $currentPath -Force -ErrorAction SilentlyContinue
      }
      throw
    }
    Remove-Item $tempFile -Force -ErrorAction SilentlyContinue

    Write-Log "Script replaced successfully. Restart required."
    return $true

  } catch {
    Write-Log "Self-update failed: $($_.Exception.Message)"
    if ($tempFile -and (Test-Path $tempFile)) {
      Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
    }
    if ($stagedPath -and (Test-Path $stagedPath)) {
      Remove-Item $stagedPath -Force -ErrorAction SilentlyContinue
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

