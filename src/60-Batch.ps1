
function Invoke-AppUpdateBatch {
  param(
    [Parameter(Mandatory=$true)]
    [object[]]$Apps,
    [Parameter(Mandatory=$true)]
    [string]$RootPackageFolder
  )

  $updateSelectedButton.Enabled = $false
  $updateAllButton.Enabled = $false
  $updateSearchButton.Enabled = $false
  $checkAllButton.Enabled = $false
  $uncheckAllButton.Enabled = $false

  # Real per-app progress instead of a marquee. A marquee only animates while the UI thread pumps
  # its message loop; during a long package build (60ms sleeps) it stutters and during the blocking
  # upload it freezes outright - which read as "hung". A continuous bar over the app count moves at
  # honest, observable moments (one app done), and the status line names the phase within each app.
  $script:progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
  $script:progressBar.Maximum = [Math]::Max(1, $Apps.Count)
  $script:progressBar.Value = 0
  $script:progressBar.Visible = $true

  $successCount = 0
  $failedCount = 0
  $totalCount = $Apps.Count
  $currentIndex = 0
  $failedList = [System.Collections.Generic.List[object]]::new()
  $succeededList = [System.Collections.Generic.List[object]]::new()
  # One batch may contain several historical versions of the same product. Once the first row has
  # created/reused the target version, all following rows must consolidate into that same Graph app.
  $batchTargets = @{}
  $unresolvedTargetKeys = [System.Collections.Generic.HashSet[string]]::new()

  # Batch runs synchronously on the UI thread (the WinTuner/Graph calls must stay there), so the
  # window freezes while a single app is packaged. Show the cancel button + reset the flag.
  $script:cancelBatch = $false
  if ($cancelBatchButton) { Set-CancelBatchButtonVisible $true }
  try {
    foreach ($app in $Apps) {
      # DoEvents above/below lets a queued click on "Stop" arrive – checked between apps only, so a
      # running package/upload is never torn apart mid-operation.
      if ($script:cancelBatch) {
        Write-Log ("Batch canceled by user after {0} of {1} app(s)." -f ($currentIndex), $totalCount)
        Update-Status (Get-UiString 'BatchCanceledStatus')
        break
      }
      $currentIndex++
      # Advance the bar by COMPLETED apps: it sits at currentIndex-1 while this app runs, so the fill
      # never claims an app is done before it is. The phase prefix ("(2/8) ") is picked up by the
      # packaging/upload status lines inside Update-SingleApp.
      $script:progressBar.Value = [Math]::Min([Math]::Max(0, $currentIndex - 1), $script:progressBar.Maximum)
      $script:batchProgressPrefix = "({0}/{1}) " -f $currentIndex, $totalCount
      $appStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
      Update-Status ("Updating ({0}/{1}): {2} {3}" -f $currentIndex, $totalCount, $app.Name, $app.CurrentVersion)
      [System.Windows.Forms.Application]::DoEvents()  # pumps the message loop; this work stays on the UI thread on purpose (see 70-Runtime)

      # Extract properties from WtWin32App object
      $appName = $app.Name
      $appCurrentVersion = $app.CurrentVersion
      $appLatestVersion = $app.LatestVersion
      $appGraphId = $app.GraphId

      # Scan models already contain the verified package id; only legacy callers need resolution.
      $appPackageId = if ($app.PackageId) { [string]$app.PackageId } else { Resolve-WingetIdForApp -App $app }
      # A target is unique per package id + requested version. Display names and scopes are
      # predecessor metadata and trigger a consolidation warning; they must never create a second
      # copy of the same package version.
      $lane = ([string]$appPackageId).Trim().ToLowerInvariant()
      $targetKey = ("{0}|{1}" -f $lane, $appLatestVersion).ToLowerInvariant()
      $batchTarget = if ($batchTargets.ContainsKey($targetKey)) { $batchTargets[$targetKey] } else { $null }
      $existingTargetId = if ($batchTarget) {
        [string]$batchTarget.Id
      } elseif ($app.ExistingTargetGraphId) {
        [string]$app.ExistingTargetGraphId
      } else { $null }
      $effectiveRequestedVersion = if ($batchTarget -and $batchTarget.Version) { [string]$batchTarget.Version } else { [string]$appLatestVersion }

      # Never create the same target twice merely because Intune did not expose the first upload's
      # GraphId quickly enough. Later predecessors are kept and reported for a new scan instead.
      if ($unresolvedTargetKeys.Contains($targetKey)) {
        $reason = "The newest target was deployed, but its authoritative Intune GraphId could not be resolved; skipped this predecessor to prevent a duplicate target. Run the scan again."
        $failedCount++
        $failedList.Add([pscustomobject]@{ Name = $appName; Reason = $reason })
        Write-Log ("Skipped consolidation for {0} {1}: {2}" -f $appName, $appCurrentVersion, $reason)
        continue
      }

      Write-Log "Calling Update-SingleApp with: Name='$appName', Current='$appCurrentVersion', Latest='$effectiveRequestedVersion', GraphId='$appGraphId', PackageId='$appPackageId', ExistingTarget='$existingTargetId'"

      $result = Update-SingleApp `
        -AppName $appName `
        -CurrentVersion $appCurrentVersion `
        -LatestVersion $effectiveRequestedVersion `
        -GraphId $appGraphId `
        -PackageIdentifier $appPackageId `
        -ExistingTargetGraphId $existingTargetId `
        -RootPackageFolder $RootPackageFolder

      # Per-app duration: makes it obvious afterwards WHICH app blocked the UI and for how long
      # (big installers like Teams routinely take minutes to package).
      try { Write-Log ("Duration for {0}: {1:n1}s" -f $appName, $appStopwatch.Elapsed.TotalSeconds) } catch {}
      if ($result.Success) {
        $successCount++
        $actualTargetVersion = if ($result.EffectiveVersion) { [string]$result.EffectiveVersion } else { $effectiveRequestedVersion }
        if ($result.NewAppId) { $batchTargets[$targetKey] = [pscustomobject]@{ Id = [string]$result.NewAppId; Version = $actualTargetVersion } }
        elseif (-not $batchTargets.ContainsKey($targetKey)) {
          $resolvedTarget = Resolve-DeployedUpdateTarget -PackageId $appPackageId -Version $actualTargetVersion -ExcludeGraphId $appGraphId -PreferredName $appName
          if ($resolvedTarget -and $resolvedTarget.GraphId) {
            $batchTargets[$targetKey] = [pscustomobject]@{ Id = [string]$resolvedTarget.GraphId; Version = $actualTargetVersion }
          } else {
            [void]$unresolvedTargetKeys.Add($targetKey)
          }
        }
        Write-Log "Successfully updated: $appName"
        $effVer = if ($result.EffectiveVersion) { $result.EffectiveVersion } else { $appLatestVersion }
        $succeededList.Add([pscustomobject]@{
          Name              = $appName
          FromVersion       = $appCurrentVersion
          ToVersion         = $effVer
          OldVersionRemoved = $result.OldVersionRemoved
        })
        # Also record into the session-wide log (survives tenant switches) for the on-demand
        # Leistungstext. Add-SessionActivity persists it straight away - the record is usually
        # needed for the ticket after the tool has already been closed.
        Add-SessionActivity -Kind 'Update' -Name $appName -FromVersion $appCurrentVersion `
          -ToVersion $effVer -OldVersionRemoved ([bool]$result.OldVersionRemoved)

        # Remove only this concrete Intune object. Several rows may intentionally have the same name.
        foreach ($row in @($updateListBox.Items)) {
          if ($row.Tag -and [string]::Equals([string]$row.Tag.GraphId, [string]$appGraphId, [System.StringComparison]::OrdinalIgnoreCase)) {
            $updateListBox.Items.Remove($row); break
          }
        }
        $toRemove = $script:updateApps | Where-Object { [string]::Equals([string]$_.GraphId, [string]$appGraphId, [System.StringComparison]::OrdinalIgnoreCase) }
        foreach ($item in @($toRemove)) { [void]$script:updateApps.Remove($item) }
        [System.Windows.Forms.Application]::DoEvents()
      } else {
        $failedCount++
        Write-Log "Failed to update: $appName - $($result.Message)"
        $failedList.Add([pscustomobject]@{ Name = $appName; Reason = $result.Message })
      }
    }

    if ($failedList.Count -gt 0) {
      $failLines = ($failedList | ForEach-Object { "• $($_.Name): $($_.Reason)" }) -join "`n"
      [System.Windows.Forms.MessageBox]::Show(
        ((Get-UiString 'UpdateBatchFailedSummary') -f $failedList.Count, $failLines),
        ((Get-UiString 'UpdateBatchFailedTitle') -f $failedList.Count),
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning
      )
    }

    # Optional automatic version trimming: after updating, keep only the newest N versions per app.
    # Runs silently (no prompt) because the user opted in via Settings; it still refuses to touch
    # apps whose versions cannot be compared, and never removes a lone version.
    if ($successCount -gt 0 -and $script:settings.AutoVersionCleanup) {
      try {
        Write-Log ("Auto version cleanup starting (keeping newest {0} per app)..." -f $script:keepVersionCount)
        Invoke-VersionCleanup -KeepCount $script:keepVersionCount -Silent
      } catch { Write-Log "Auto version cleanup error: $($_.Exception.Message)" }
    }

    # No automatic re-scan here. It used to run a full tenant scan after every batch - re-reading
    # all Intune apps and asking WinGet for every package again, ~10-15s of waiting that nobody had
    # asked for, on top of an update run that already took minutes. The rows of successfully updated
    # apps are removed from the list inside the loop above, so the view is already correct for what
    # happened; anything else is a deliberate decision by the user, who can press "Search Updates".
    Update-Status (Get-UiString 'BatchRescanHint')
    Update-UpdatesEmptyState

    return @{ SuccessCount = $successCount; FailedList = $failedList; SucceededList = $succeededList }
  } finally {
    $script:progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
    $script:progressBar.Visible = $false
    $script:progressBar.Value = 0
    $updateSelectedButton.Enabled = $true
    $updateAllButton.Enabled = $true
    $updateSearchButton.Enabled = $true
    $checkAllButton.Enabled = $true
    $uncheckAllButton.Enabled = $true
    if ($cancelBatchButton) { Set-CancelBatchButtonVisible $false }
    $script:cancelBatch = $false
    $script:batchProgressPrefix = ''
  }
}

# Monochrome design: no hue. The "primary" action is an INVERTED fill (white-on-dark in the
# dark theme, black-on-white in the light theme) defined per-theme below. This global accent
# is a neutral grey fallback for a few not-yet-rebuilt spots; hover/press step darker.
$script:accentColor      = [System.Drawing.Color]::FromArgb(82, 82, 82)   # #525252
$script:accentColorHover = [System.Drawing.Color]::FromArgb(64, 64, 64)
$script:accentColorPress = [System.Drawing.Color]::FromArgb(48, 48, 48)

# Monochrome dark theme: near-black canvas, greyscale elevation, white primary fill.
$script:darkTheme = @{
  BackColor       = [System.Drawing.Color]::FromArgb(20, 20, 20)     # canvas  #141414
  ForeColor       = [System.Drawing.Color]::FromArgb(237, 237, 237)  # primary text
  SecondaryForeColor = [System.Drawing.Color]::FromArgb(160, 160, 160)  # muted text
  ButtonBackColor = [System.Drawing.Color]::FromArgb(240, 240, 240)  # primary = white fill
  ButtonForeColor = [System.Drawing.Color]::FromArgb(17, 17, 17)     # …with dark text
  ButtonHoverColor = [System.Drawing.Color]::FromArgb(214, 214, 214)
  ButtonPressColor = [System.Drawing.Color]::FromArgb(190, 190, 190)
  ButtonFlatStyle = [System.Windows.Forms.FlatStyle]::Flat
  ButtonSecondaryBackColor   = [System.Drawing.Color]::FromArgb(38, 38, 38)   # raised surface #262626
  ButtonSecondaryForeColor   = [System.Drawing.Color]::FromArgb(237, 237, 237)
  ButtonSecondaryBorderColor = [System.Drawing.Color]::FromArgb(64, 64, 64)   # neutral outline #404040
  TextBoxBackColor= [System.Drawing.Color]::FromArgb(38, 38, 38)
  TextBoxForeColor= [System.Drawing.Color]::FromArgb(237, 237, 237)
  TabBackColor    = [System.Drawing.Color]::FromArgb(20, 20, 20)
  TabForeColor    = [System.Drawing.Color]::FromArgb(237, 237, 237)
  FontName        = "Segoe UI"
  Rounded         = $true
  Dark            = $true    # drives the native title-bar dark mode (DWM)
}

# Monochrome light theme: soft off-white canvas, white surfaces, black primary fill.
$script:lightTheme = @{
  BackColor       = [System.Drawing.Color]::FromArgb(236, 237, 239)   # canvas (softened, less glare)
  ForeColor       = [System.Drawing.Color]::FromArgb(24, 24, 27)      # primary text
  SecondaryForeColor = [System.Drawing.Color]::FromArgb(107, 114, 128)  # muted text
  ButtonBackColor = [System.Drawing.Color]::FromArgb(24, 24, 27)      # primary = black fill
  ButtonForeColor = [System.Drawing.Color]::White                     # …with white text
  ButtonHoverColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
  ButtonPressColor = [System.Drawing.Color]::FromArgb(63, 63, 70)
  ButtonFlatStyle = [System.Windows.Forms.FlatStyle]::Flat
  ButtonSecondaryBackColor   = [System.Drawing.Color]::FromArgb(250, 250, 251)
  ButtonSecondaryForeColor   = [System.Drawing.Color]::FromArgb(24, 24, 27)
  ButtonSecondaryBorderColor = [System.Drawing.Color]::FromArgb(212, 212, 216)
  TextBoxBackColor= [System.Drawing.Color]::FromArgb(250, 250, 251)
  TextBoxForeColor= [System.Drawing.Color]::FromArgb(24, 24, 27)
  TabBackColor    = [System.Drawing.Color]::FromArgb(244, 244, 245)
  TabForeColor    = [System.Drawing.Color]::FromArgb(24, 24, 27)
  FontName        = "Segoe UI"
  Rounded         = $true
  Dark            = $false
}

# --- Colourful retro-inspired themes (Win98/XP/Vista/7) -------------------------------------
# Same key set as Dark/Light so everything (cards, inputs, owner-drawn combos, menu, sidebar)
# adapts automatically. Kept Rounded=$true so they stay visually consistent with the layout;
# the "retro" is expressed through the era's colour palette + accent, not square corners.
$script:win98Theme = @{
  BackColor       = [System.Drawing.Color]::FromArgb(195, 199, 203)   # 98 silver
  ForeColor       = [System.Drawing.Color]::FromArgb(20, 20, 20)
  SecondaryForeColor = [System.Drawing.Color]::FromArgb(92, 94, 98)
  ButtonBackColor = [System.Drawing.Color]::FromArgb(0, 0, 128)       # navy primary
  ButtonForeColor = [System.Drawing.Color]::White
  ButtonHoverColor = [System.Drawing.Color]::FromArgb(16, 16, 150)
  ButtonPressColor = [System.Drawing.Color]::FromArgb(0, 0, 92)
  ButtonFlatStyle = [System.Windows.Forms.FlatStyle]::Flat
  ButtonSecondaryBackColor   = [System.Drawing.Color]::FromArgb(214, 214, 210)
  ButtonSecondaryForeColor   = [System.Drawing.Color]::FromArgb(20, 20, 20)
  ButtonSecondaryBorderColor = [System.Drawing.Color]::FromArgb(128, 128, 128)
  TextBoxBackColor= [System.Drawing.Color]::White
  TextBoxForeColor= [System.Drawing.Color]::FromArgb(20, 20, 20)
  TabBackColor    = [System.Drawing.Color]::FromArgb(195, 199, 203)
  TabForeColor    = [System.Drawing.Color]::FromArgb(20, 20, 20)
  FontName        = "Tahoma"
  Rounded         = $true
  Dark            = $false
}
$script:winXpTheme = @{
  BackColor       = [System.Drawing.Color]::FromArgb(236, 233, 216)   # XP Luna tan
  ForeColor       = [System.Drawing.Color]::FromArgb(20, 20, 20)
  SecondaryForeColor = [System.Drawing.Color]::FromArgb(110, 108, 96)
  ButtonBackColor = [System.Drawing.Color]::FromArgb(49, 101, 196)    # Luna blue primary
  ButtonForeColor = [System.Drawing.Color]::White
  ButtonHoverColor = [System.Drawing.Color]::FromArgb(62, 120, 220)
  ButtonPressColor = [System.Drawing.Color]::FromArgb(36, 80, 160)
  ButtonFlatStyle = [System.Windows.Forms.FlatStyle]::Flat
  ButtonSecondaryBackColor   = [System.Drawing.Color]::FromArgb(245, 243, 233)
  ButtonSecondaryForeColor   = [System.Drawing.Color]::FromArgb(20, 20, 20)
  ButtonSecondaryBorderColor = [System.Drawing.Color]::FromArgb(127, 157, 185)
  TextBoxBackColor= [System.Drawing.Color]::White
  TextBoxForeColor= [System.Drawing.Color]::FromArgb(20, 20, 20)
  TabBackColor    = [System.Drawing.Color]::FromArgb(236, 233, 216)
  TabForeColor    = [System.Drawing.Color]::FromArgb(20, 20, 20)
  FontName        = "Tahoma"
  Rounded         = $true
  Dark            = $false
}
$script:winVistaTheme = @{
  BackColor       = [System.Drawing.Color]::FromArgb(231, 239, 249)   # Aero light blue
  ForeColor       = [System.Drawing.Color]::FromArgb(25, 30, 40)
  SecondaryForeColor = [System.Drawing.Color]::FromArgb(95, 105, 120)
  ButtonBackColor = [System.Drawing.Color]::FromArgb(44, 137, 220)    # Aero blue primary
  ButtonForeColor = [System.Drawing.Color]::White
  ButtonHoverColor = [System.Drawing.Color]::FromArgb(60, 155, 235)
  ButtonPressColor = [System.Drawing.Color]::FromArgb(30, 110, 185)
  ButtonFlatStyle = [System.Windows.Forms.FlatStyle]::Flat
  ButtonSecondaryBackColor   = [System.Drawing.Color]::FromArgb(238, 244, 251)
  ButtonSecondaryForeColor   = [System.Drawing.Color]::FromArgb(25, 30, 40)
  ButtonSecondaryBorderColor = [System.Drawing.Color]::FromArgb(126, 160, 200)
  TextBoxBackColor= [System.Drawing.Color]::White
  TextBoxForeColor= [System.Drawing.Color]::FromArgb(25, 30, 40)
  TabBackColor    = [System.Drawing.Color]::FromArgb(231, 239, 249)
  TabForeColor    = [System.Drawing.Color]::FromArgb(25, 30, 40)
  FontName        = "Segoe UI"
  Rounded         = $true
  Dark            = $false
}
$script:win7Theme = @{
  BackColor       = [System.Drawing.Color]::FromArgb(238, 242, 247)   # Win7 Aero light
  ForeColor       = [System.Drawing.Color]::FromArgb(25, 28, 34)
  SecondaryForeColor = [System.Drawing.Color]::FromArgb(100, 108, 120)
  ButtonBackColor = [System.Drawing.Color]::FromArgb(43, 108, 196)    # refined Aero blue
  ButtonForeColor = [System.Drawing.Color]::White
  ButtonHoverColor = [System.Drawing.Color]::FromArgb(55, 125, 215)
  ButtonPressColor = [System.Drawing.Color]::FromArgb(32, 88, 165)
  ButtonFlatStyle = [System.Windows.Forms.FlatStyle]::Flat
  ButtonSecondaryBackColor   = [System.Drawing.Color]::FromArgb(245, 247, 250)
  ButtonSecondaryForeColor   = [System.Drawing.Color]::FromArgb(25, 28, 34)
  ButtonSecondaryBorderColor = [System.Drawing.Color]::FromArgb(138, 165, 196)
  TextBoxBackColor= [System.Drawing.Color]::White
  TextBoxForeColor= [System.Drawing.Color]::FromArgb(25, 28, 34)
  TabBackColor    = [System.Drawing.Color]::FromArgb(238, 242, 247)
  TabForeColor    = [System.Drawing.Color]::FromArgb(25, 28, 34)
  FontName        = "Segoe UI"
  Rounded         = $true
  Dark            = $false
}

# Orange theme: warm light canvas with a strong orange accent (#E67E22).
$script:orangeTheme = @{
  BackColor       = [System.Drawing.Color]::FromArgb(251, 243, 234)   # warm cream canvas
  ForeColor       = [System.Drawing.Color]::FromArgb(42, 32, 22)
  SecondaryForeColor = [System.Drawing.Color]::FromArgb(138, 123, 106)
  ButtonBackColor = [System.Drawing.Color]::FromArgb(230, 126, 34)    # orange primary accent
  ButtonForeColor = [System.Drawing.Color]::White
  ButtonHoverColor = [System.Drawing.Color]::FromArgb(239, 140, 54)
  ButtonPressColor = [System.Drawing.Color]::FromArgb(201, 106, 24)
  ButtonFlatStyle = [System.Windows.Forms.FlatStyle]::Flat
  ButtonSecondaryBackColor   = [System.Drawing.Color]::FromArgb(253, 248, 242)
  ButtonSecondaryForeColor   = [System.Drawing.Color]::FromArgb(42, 32, 22)
  ButtonSecondaryBorderColor = [System.Drawing.Color]::FromArgb(224, 201, 174)
  TextBoxBackColor= [System.Drawing.Color]::White
  TextBoxForeColor= [System.Drawing.Color]::FromArgb(42, 32, 22)
  TabBackColor    = [System.Drawing.Color]::FromArgb(251, 243, 234)
  TabForeColor    = [System.Drawing.Color]::FromArgb(42, 32, 22)
  FontName        = "Segoe UI"
  Rounded         = $true
  Dark            = $false
}

# Themes offered in the top-menu "Theme" picker. Light is the default.
$script:availableThemes = [ordered]@{
  'Light'  = $script:lightTheme
  'Dark'   = $script:darkTheme
  'Orange' = $script:orangeTheme
  'Win98'  = $script:win98Theme
  'WinXP'  = $script:winXpTheme
  'Vista'  = $script:winVistaTheme
  'Win7'   = $script:win7Theme
}
$script:themeDisplayNames = [ordered]@{
  'Light'  = (Get-UiString 'ThemeLight')
  'Dark'   = (Get-UiString 'ThemeDark')
  'Orange' = (Get-UiString 'ThemeOrange')
  'Win98'  = (Get-UiString 'ThemeWin98')
  'WinXP'  = (Get-UiString 'ThemeWinXP')
  'Vista'  = (Get-UiString 'ThemeVista')
  'Win7'   = (Get-UiString 'ThemeWin7')
}

$script:themeName    = if ($script:settings.ThemeName -and $script:availableThemes.Contains($script:settings.ThemeName)) { $script:settings.ThemeName } else { 'Light' }
$script:currentTheme = $script:availableThemes[$script:themeName]

