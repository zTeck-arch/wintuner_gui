
$dropdown.Add_SelectedIndexChanged({ Update-SelectedPackageVersionLabel })

# Cache for winget searches to speed up repeated searches
# (initialized at script scope; see earlier declaration)

# Session header: the log file is append-only across runs, so without a marker consecutive sessions
# blur together and there is no record of WHICH build/environment produced the lines that follow.
# One banner per start makes support diagnosis (and bug reports) far easier.
try {
  $psVer  = $PSVersionTable.PSVersion.ToString()
  $osVer  = try { (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Caption } catch { [Environment]::OSVersion.VersionString }
  $wtVer  = try { (Get-Module -ListAvailable -Name WinTuner | Sort-Object Version -Descending | Select-Object -First 1).Version.ToString() } catch { 'n/a' }
  Write-Log ("=" * 78)
  Write-Log ("Session start | WinTuner GUI {0} | PowerShell {1} | WinTuner module {2}" -f $script:appVersion, $psVer, $wtVer)
  Write-Log ("Environment   | {0} | user {1} | lang {2} | theme {3}" -f $osVer, $env:USERNAME, $script:uiLanguage, $script:themeName)
  # Housekeeping first, so an old log is gone before this session appends to a fresh one. Logged
  # rather than silent: deleting a customer-related record without saying so would be worse than
  # keeping it.
  $expired = Remove-ExpiredLogs
  if ($expired -gt 0) {
    Write-Log ("Log housekeeping: {0} weekly log(s) older than {1} week(s) removed from {2}." -f $expired, $script:logRetentionWeeks, $script:logDirectory)
  }

  # Never silent: the package folder is where .intunewin files are built before they go to Intune,
  # so the user has to know it moved - and where their existing packages still are.
  # Read BEFORE this session can overwrite it, so "previous session" really is the previous one.
  Import-PreviousSessionActivity
  if ($script:packagePathMigrated) {
    Write-Log ("Package folder moved from {0} to {1}: the old location is writable by every signed-in user of this machine. Existing packages were NOT moved." -f $script:legacyPackagePath, $script:settings.DefaultPackagePath)
  }
} catch {}

# Module check
Update-Status (Get-UiString 'ModCheckingStatus')
try {
  if (Get-Module -ListAvailable -Name WinTuner) {
    Update-Status (Get-UiString 'ModFoundStatus')

    # Check if update is available (optional - don't force update every time)
    # Uncomment the following block if you want automatic updates:
    <#
    try {
      $installedVersion = (Get-Module -ListAvailable -Name WinTuner | Sort-Object Version -Descending | Select-Object -First 1).Version
      $onlineVersion = (Find-Module -Name WinTuner -ErrorAction SilentlyContinue).Version

      if ($onlineVersion -and $onlineVersion -gt $installedVersion) {
        Update-Status "Module update available ($installedVersion → $onlineVersion). Updating..."

        # Temporarily disable PSDefaultParameterValues for Update-Module
        $savedDefaults = $PSDefaultParameterValues.Clone()
        $PSDefaultParameterValues.Clear()

        Update-Module -Name WinTuner -ErrorAction Stop

        # Restore defaults
        foreach ($key in $savedDefaults.Keys) {
          $PSDefaultParameterValues[$key] = $savedDefaults[$key]
        }

        Update-Status "Module updated to $onlineVersion"
      } else {
        Update-Status "Module is up to date (v$installedVersion)"
      }
    } catch {
      Write-Log "Module update check failed: $($_.Exception.Message)"
      Update-Status "Module update skipped (using existing version)"
    }
    #>
  } else {
    Update-Status (Get-UiString 'ModNotFoundStatus')
    Write-Log 'WinTuner module is not installed; the startup installation offer was declined or failed.'
  }
} catch {
  Update-Status ((Get-UiString 'ModInstallErrorStatus') -f $_.Exception.Message)
}
$script:winTunerModuleImported = $false
try {
  Import-Module WinTuner -ErrorAction Stop
  $requiredCommands = @(
    'Connect-WtWinTuner', 'Disconnect-WtWinTuner', 'Search-WtWinGetPackage',
    'New-WtWingetPackage', 'Deploy-WtWin32App', 'Get-WtWin32Apps', 'Remove-WtWin32App',
    'Deploy-WtMsStoreApp', 'Update-WtIntuneApp', 'Get-WtToken'
  )
  $missingCommands = @($requiredCommands | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
  if ($missingCommands.Count -gt 0) {
    throw ("The installed WinTuner module is missing required commands: {0}. Update the module and restart the GUI." -f ($missingCommands -join ', '))
  }

  # The command check above proves the cmdlets exist, not that they still behave the same way.
  # This GUI is written against the WinTuner 1.x surface and deliberately tolerates older 1.x
  # deployments, so no minimum version is enforced. A future 2.x could keep every command name
  # while changing semantics - that must surface at startup rather than halfway through an
  # upload or a cleanup run.
  $winTunerModule = Get-Module WinTuner | Sort-Object Version -Descending | Select-Object -First 1
  if ($winTunerModule -and $winTunerModule.Version.Major -gt 1) {
    Write-Log ("WinTuner module version {0} is newer than the 1.x line this GUI was written and tested against." -f $winTunerModule.Version)
    [void][System.Windows.Forms.MessageBox]::Show(
      ((Get-UiString 'ModVersionUntestedDialog') -f $winTunerModule.Version),
      (Get-UiString 'ModVersionUntestedTitle'),
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Warning)
  }

  $script:winTunerModuleImported = $true
} catch {
  $errMsg = $_.Exception.Message
  Write-Log "Failed to import WinTuner module: $errMsg"
  [System.Windows.Forms.MessageBox]::Show(
    ((Get-UiString 'ModImportFailedDialog') -f $errMsg),
    (Get-UiString 'ModImportFailedTitle'),
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Error
  )
  # Disable all functional sections except Settings so the user can still fix the module path.
  foreach ($s in $script:sections) {
    if ($s.Key -ne 'settings') { $s.Panel.Enabled = $false }
  }
  if ($loginButton) { $loginButton.Enabled = $false }
}
if ($script:winTunerModuleImported) { Update-Status (Get-UiString 'ModImportedStatus') }

# Login button
$loginButton = New-Object System.Windows.Forms.Button
$loginButton.Text = Get-UiString 'LoginButton'
$loginButton.Location = New-Object System.Drawing.Point(848, 22)
$loginButton.Size = New-Object System.Drawing.Size(120, 36)
$loginButton.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$headerPanel.Controls.Add($loginButton)

# initialize login button enabled state based on username validation
$loginButton.Enabled = ($script:winTunerModuleImported -and (Test-ValidM365UserName -UserName $usernameBox.Text))

$usernameBox.Text = ""

# Initialize pathBox with saved default package path
if ($pathBox) {
  if ($script:settings.DefaultPackagePath) {
    $pathBox.Text = $script:settings.DefaultPackagePath
  } else {
    $pathBox.Text = Get-DefaultPackagePath
  }
}

$loginButton.Add_Click({
  if (-not (Test-ValidM365UserName -UserName $usernameBox.Text)) {
    [void][System.Windows.Forms.MessageBox]::Show(
      (Get-UiString 'LoginInvalidUpnDialog'),
      (Get-UiString 'LoginInvalidUpnTitle'),
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    return
  }
  # Tenant-switch nudge: if a previous session is still cached (Disconnect, not Logout) and
  # we're now signing in to a DIFFERENT customer domain, offer a clean logout first.
  try { $newDomain = ($usernameBox.Text -split '@')[-1].Trim().ToLower() } catch { $newDomain = "" }
  if ($script:lastTenantDomain -and $newDomain -and ($newDomain -ne $script:lastTenantDomain)) {
    $answer = [System.Windows.Forms.MessageBox]::Show(
      ((Get-UiString 'TenantSwitchNudge') -f $script:lastTenantDomain, $newDomain),
      (Get-UiString 'TenantSwitchTitle'),
      [System.Windows.Forms.MessageBoxButtons]::YesNo,
      [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
      try { Disconnect-WtWinTuner -ErrorAction SilentlyContinue } catch { }   # class 3: best-effort teardown
      try { Disconnect-MgGraph -ErrorAction SilentlyContinue } catch { }   # class 3: best-effort teardown
      Clear-GraphTokenCache
    }
  }
  $loginButton.Enabled = $false
  $loginButton.Text = Get-UiString 'LoginButtonConnecting'
  [System.Windows.Forms.Application]::DoEvents()
  try {
    Update-Status (Get-UiString 'LoginConnectingStatus')
    $script:isConnected = $false
    if ($script:forceFreshLogin) {
      # Logout requested a real re-authentication: skip the Windows broker (WAM) so the
      # cached SSO session can't silently sign us back in without user interaction.
      $null = Connect-WtWinTuner -Username $usernameBox.Text -NoBroker -ErrorAction Stop
      $script:forceFreshLogin = $false
    } else {
      $null = Connect-WtWinTuner -Username $usernameBox.Text -ErrorAction Stop
    }
    # Connect-WtWinTuner above already succeeded, so a failure here is NOT an authentication
    # problem - it is the first Intune query failing (Graph outage, throttling, missing scope).
    # Reporting it as an auth error used to hide the real cause completely.
    if (-not (Test-WtConnected)) {
      $probeDetail = if ($script:lastConnectionProbeError) { $script:lastConnectionProbeError } else { '-' }
      # "Request not applicable to target tenant" (and the "no active Intune license" shapes) are NOT
      # transient: the Graph Intune API requires an active Intune license in the target tenant, and
      # the account must be permitted there. Telling the user to "try again in a few minutes" sent
      # them chasing a Graph outage that was never the cause. Name the real, permanent condition.
      $noIntune = (
        $probeDetail -match '(?i)not applicable to target tenant' -or
        $probeDetail -match '(?i)not onboarded' -or
        ($probeDetail -match '(?i)Intune' -and $probeDetail -match '(?i)licen[sc]e'))
      $errKey = if ($noIntune) { 'LoginNoIntuneError' } else { 'LoginProbeFailedError' }
      Write-Log ("First Intune query failed after sign-in ({0}): {1}" -f $(if ($noIntune) { 'tenant has no usable Intune / no permission' } else { 'transient or unknown' }), $probeDetail)
      throw ((Get-UiString $errKey) -f $probeDetail)
    }
    $script:isConnected = $true
    # Before anything tenant-specific is shown again: whatever is still on screen belongs to the
    # PREVIOUS session and may be a different customer entirely.
    Clear-TenantViews
    Update-Status (Get-UiString 'LoginSuccessStatus')
    $script:currentUserUpn = $usernameBox.Text
    # Remember the tenant domain so a later login to a DIFFERENT customer can nudge toward Logout.
    try { $script:lastTenantDomain = ($usernameBox.Text -split '@')[-1].Trim().ToLower() } catch { $script:lastTenantDomain = "" }
    # Record this login for quick re-selection next time, and refresh the recent list.
    Add-RecentLogin -Upn $usernameBox.Text
    Update-RecentLoginsUI
    # Group favorites are per customer, so the target lists have to be rebuilt for THIS tenant -
    # otherwise the previous customer's groups would still be on offer after a switch.
    try { Update-AllAssignTargetCombos } catch { Write-Log ("Could not load group favorites: {0}" -f $_.Exception.Message) }
    if ($loginInfoLabel) { $loginInfoLabel.Text = (Get-UiString 'LoggedInAs') -f $script:currentUserUpn }
    Set-ConnectedUIState -Connected $true

    # Land on the dashboard rather than wherever the previous session happened to stop. Its tiles
    # are the first thing that states which tenant is actually loaded - staying in, say, the update
    # list of the last customer is disorienting even once the rows have been cleared. Skipped when
    # the auto-check takes over below, which navigates to the updates section on purpose.
    if (-not $script:settings.AutoCheckUpdates -and $script:activeSection -ne 'dashboard') {
      try { Show-Section 'dashboard' } catch { }
    }

    # Auto-check for updates if enabled
    if ($script:settings.AutoCheckUpdates) {
      Write-Log "Auto-check for updates enabled - triggering update search"
      Update-Status (Get-UiString 'LoginAutoCheckStatus')
      try {
        # Switch to the Updates section first so PerformClick works
        Show-Section 'updates'
        Start-Sleep -Milliseconds 100
        $updateSearchButton.PerformClick()
      } catch {
        Write-Log "Auto-check for updates failed: $($_.Exception.Message)"
      }
    }
  } catch {
    $msg = $_.Exception.Message
    # Full detail to the log (type, inner exception, HTTP status, line); the dialog keeps the short
    # message. A login failure is exactly the kind of report that needs the type, not just the text.
    Write-Log ("Login failed: {0}" -f (Format-ErrorDetail $_))
    # 401/403 is an authentication/permission answer no matter how the message is worded or
    # localized; the text patterns below are only the fallback for exceptions without a status.
    $loginStatus = Get-ErrorHttpStatus -ErrorRecord $_
    if ($loginStatus -eq 401 -or $loginStatus -eq 403) {
      [void][System.Windows.Forms.MessageBox]::Show(
        ((Get-UiString 'LoginAuthErrorDialog') -f $msg),
        (Get-UiString 'LoginAuthErrorTitle'),
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
      )
    } elseif ($msg -imatch 'network|connection|timeout|unreachable') {
      [void][System.Windows.Forms.MessageBox]::Show(
        ((Get-UiString 'LoginNetworkErrorDialog') -f $msg),
        (Get-UiString 'LoginNetworkErrorTitle'),
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
      )
    } elseif ($msg -imatch 'unauthorized|authentication|credential|access') {
      [void][System.Windows.Forms.MessageBox]::Show(
        ((Get-UiString 'LoginAuthErrorDialog') -f $msg),
        (Get-UiString 'LoginAuthErrorTitle'),
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
      )
    } else {
      [void][System.Windows.Forms.MessageBox]::Show(
        ((Get-UiString 'LoginFailedDialog') -f $msg),
        (Get-UiString 'LoginFailedTitle'),
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
      )
    }
    Update-Status ((Get-UiString 'LoginCanceledStatus') -f $msg)
    Set-ConnectedUIState -Connected $false
  } finally {
    $loginButton.Text = Get-UiString 'LoginButton'
    $loginButton.Enabled = ($script:winTunerModuleImported -and (Test-ValidM365UserName -UserName $usernameBox.Text))
  }
})

$searchButton.Add_Click({
  if (Test-UiBusy) { return }
  if ([string]::IsNullOrWhiteSpace($appSearchBox.Text)) {
    [void][System.Windows.Forms.MessageBox]::Show(
      (Get-UiString 'SearchEmptyDialog'),
      (Get-UiString 'ValidationTitle'),
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Information
    )
    return
  }
  try {
    $searchButton.Enabled = $false
    Update-Status (Get-UiString 'SearchingStatus')
    $results = Search-WtWinGetPackage -SearchQuery $appSearchBox.Text
    $dropdown.Items.Clear()
    Update-SelectedPackageVersionLabel
    $script:packageMap.Clear()
    foreach ($result in @($results)) {
      $displayText = "$($result.Name) — $($result.PackageID)"
      [void]$dropdown.Items.Add($displayText)
      $script:packageMap[$displayText] = @{
        Name      = [string]$result.Name
        PackageID = $result.PackageID
        Version   = $result.Version
      }
    }
    if ($dropdown.Items.Count -gt 0) { $dropdown.SelectedIndex = 0 }
    if ($dropdown.Items.Count -eq 0) {
      Update-Status ((Get-UiString 'SearchNoResultsStatus') -f $appSearchBox.Text)
    } else {
      Update-Status (Get-UiString 'SearchCompletedStatus')
    }
  } finally {
    $searchButton.Enabled = $true
  }
})

$versionsButton.Add_Click({
  if (Test-UiBusy) { return }
  if (-not $dropdown.SelectedItem) { Update-Status (Get-UiString 'SelectPackageFirstStatus'); return }
  $appName  = $dropdown.SelectedItem
  $package  = $script:packageMap[$appName]
  if (-not $package -or -not $package.PackageID) { Update-Status (Get-UiString 'InvalidSelectionStatus'); return }
  $packageID = $package.PackageID
  $versions = @(Get-WingetVersions -PackageId $packageID)
  if (-not $versions -or $versions.Count -eq 0) { Update-Status (Get-UiString 'NoVersionsStatus'); return }
  $chosen = Show-VersionPickerDialog -Title ((Get-UiString 'VersionPickerTitle') -f $packageID) -Versions $versions
  if ($chosen) {
    $script:selectedPackageVersions[$packageID] = $chosen
    Update-SelectedPackageVersionLabel
    Update-Status ((Get-UiString 'SelectedVersionStatus') -f $packageID, $chosen)
  } else {
    Update-Status (Get-UiString 'VersionSelectionCanceledStatus')
  }
})

$createButton.Add_Click({
  if (Test-UiBusy) { return }
  if (-not $dropdown.SelectedItem) { Update-Status (Get-UiString 'SelectPackageStatus'); return }
  $appName  = $dropdown.SelectedItem
  $package  = $script:packageMap[$appName]
  if (-not $package -or -not $package.PackageID) { Update-Status (Get-UiString 'InvalidSelectionStatus'); return }
  $packageID = $package.PackageID
  $folder = try { [System.IO.Path]::GetFullPath($pathBox.Text.Trim()) } catch { Update-Status ((Get-UiString 'InvalidFolderDialog') -f $pathBox.Text.Trim()); return }
  if (-not (Test-PackageFolderUsable -Folder $folder)) { return }
  if (-not (Test-Path $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
  $filePath  = Join-Path $folder "$packageID.wtpackage"

  if (Test-Path $filePath) {
    $res = [System.Windows.Forms.MessageBox]::Show(((Get-UiString 'PackageExistsDialog') -f $filePath), (Get-UiString 'ConfirmOverwriteTitle'), [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($res -ne [System.Windows.Forms.DialogResult]::Yes) { Update-Status (Get-UiString 'CreationAbortedStatus'); $uploadButton.Enabled = $true; return }
    try {
      Remove-Item -Path $filePath -Force -ErrorAction Stop
    } catch {
      Write-Log "Warning: Failed to delete existing package file ${filePath}: $($_.Exception.Message)"
      Update-Status (Get-UiString 'DeleteExistingWarnStatus')
    }
  }

  try {
    $createButton.Enabled = $false
    $searchButton.Enabled = $false
    $versionsButton.Enabled = $false

    Update-Status ((Get-UiString 'CreatingPackageStatus') -f $packageID)
    $script:progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
    $script:progressBar.MarqueeAnimationSpeed = 30
    $script:progressBar.Visible = $true
    [System.Windows.Forms.Application]::DoEvents()  # pumps the message loop; this work stays on the UI thread on purpose (see 70-Runtime)

    $desired = $null
    if ($script:selectedPackageVersions.ContainsKey($packageID)) {
      $desired = $script:selectedPackageVersions[$packageID]
    }

    # Advanced options (index 0 = Default = keep module default → pass nothing).
    $advArch = if ($script:archCombo    -and $script:archCombo.SelectedIndex    -gt 0) { [string]$script:archCombo.SelectedItem }    else { $null }
    $advCtx  = if ($script:contextCombo -and $script:contextCombo.SelectedIndex -gt 0) { [string]$script:contextCombo.SelectedItem } else { $null }
    $advLoc  = if ($script:localeBox -and $script:localeBox.Text.Trim()) { $script:localeBox.Text.Trim() } else { $null }
    $advType = if ($script:installerTypeCombo -and $script:installerTypeCombo.SelectedIndex -gt 0) { [string]$script:installerTypeCombo.SelectedItem } else { $null }
    $advArgs = if ($script:installerArgsBox -and $script:installerArgsBox.Text.Trim()) { $script:installerArgsBox.Text.Trim() } else { $null }
    $advPackageScript = [bool]($script:packageScriptCheckbox -and $script:packageScriptCheckbox.Checked)

    $resPkg = New-WingetPackageWithFallback `
      -PackageId $packageID `
      -PackageFolder $folder `
      -DesiredVersion $desired `
      -LatestVersion $package.Version `
      -Architecture $advArch `
      -InstallerContext $advCtx `
      -Locale $advLoc `
      -PreferredInstaller $advType `
      -InstallerArguments $advArgs `
      -PackageScript:$advPackageScript `
      -AllowUserRetry `
      -ErrorAction SilentlyContinue

    if ($resPkg -and $resPkg.Succeeded) {
      $effectiveVersion = $resPkg.EffectiveVersion
      if (-not $effectiveVersion) { $effectiveVersion = $package.Version }
      Update-Status ((Get-UiString 'PackageCreatedStatus') -f $effectiveVersion)
      $uploadButton.Enabled = $true
      if ($effectiveVersion) {
        $script:builtVersions[$packageID] = $effectiveVersion
        Update-SelectedPackageVersionLabel
      }
    } else {
      Update-Status (Get-UiString 'PackageCreationFailedStatus')
    }
  } finally {
    $script:progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
    $script:progressBar.Visible = $false
    $script:progressBar.Value = 0
    $createButton.Enabled = $true
    $searchButton.Enabled = $true
    $versionsButton.Enabled = $true
  }
})

$uploadButton.Add_Click({
    if (Test-UiBusy) { return }
    if (-not $script:isConnected) {
        [void][System.Windows.Forms.MessageBox]::Show(
            (Get-UiString 'LoginFirstDialog'),
            (Get-UiString 'InfoTitle'),
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
        return
    }
    if (-not $dropdown.SelectedItem) { Update-Status (Get-UiString 'SelectPackageStatus'); return }
    $appName  = $dropdown.SelectedItem
    $package  = $script:packageMap[$appName]
    if (-not $package) { Update-Status (Get-UiString 'InvalidSelectionStatus'); return }
    $packageID = $package.PackageID
    $version   = $null
    if ($script:builtVersions -and $script:builtVersions.ContainsKey($packageID)) {
        $version = $script:builtVersions[$packageID]
    } else {
        $version = $package.Version
    }
    if ([string]::IsNullOrWhiteSpace($packageID)) {
        try { $packageID = ($appName -split '—')[-1].Trim() } catch { Write-Log ("Could not derive a package id from '{0}': {1}" -f $appName, $_.Exception.Message) }
    }
    if ([string]::IsNullOrWhiteSpace($version))   { Update-Status (Get-UiString 'VersionUndeterminedStatus'); return }
    if ([string]::IsNullOrWhiteSpace($packageID)) { Update-Status (Get-UiString 'CannotResolvePackageIdStatus'); return }
    $folder = try { [System.IO.Path]::GetFullPath($pathBox.Text.Trim()) } catch { Update-Status ((Get-UiString 'InvalidFolderDialog') -f $pathBox.Text.Trim()); return }
    if (-not (Test-PackageFolderUsable -Folder $folder)) { return }
    if (-not (Test-Path $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }

    $uploadSucceeded = $false
    try {
        $uploadButton.Enabled = $false
        $createButton.Enabled = $false

        Update-Status ((Get-UiString 'UploadingStatus') -f $packageID, $version)
        $script:progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
        $script:progressBar.MarqueeAnimationSpeed = 30
        $script:progressBar.Visible = $true
        [System.Windows.Forms.Application]::DoEvents()  # pumps the message loop; this work stays on the UI thread on purpose (see 70-Runtime)

        $assignTarget = Get-SelectedAssignmentTarget -TargetCombo $assignTargetCombo -GroupIdBox $assignGroupIdBox
        $targetChanges = Get-DeployAssignmentTargetChanges
        # Build this before uploading so assignment-only choices can never be silently ignored
        # when "Not assigned" is still selected. Default/background/ASAP produces no settings
        # object and therefore remains valid for an intentionally unassigned upload.
        $plannedDeploySettings = Get-DeployAssignmentSettings
        $intentNeedsTarget = ($script:assignIntentCombo -and $script:assignIntentCombo.SelectedIndex -ne 0)
        if (-not $assignTarget -and ($plannedDeploySettings -or $intentNeedsTarget)) {
          [void][System.Windows.Forms.MessageBox]::Show((Get-UiString 'DeployAssignmentTargetRequired'), (Get-UiString 'ValidationTitle'),
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
          return
        }
        if (-not $assignTarget -and ($targetChanges.AssignmentMode -eq 'exclude' -or $targetChanges.FilterType -ne 'none')) {
          [void][System.Windows.Forms.MessageBox]::Show((Get-UiString 'DeployAssignmentTargetRequired'), (Get-UiString 'ValidationTitle'),
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
          return
        }
        if ($assignTargetCombo.SelectedIndex -eq 3 -and -not (Test-GuidString ([string]$assignTarget))) {
          [void][System.Windows.Forms.MessageBox]::Show((Get-UiString 'DeployGroupIdRequired'), (Get-UiString 'ValidationTitle'),
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
          return
        }
        if ($assignTarget -and $targetChanges.AssignmentMode -eq 'exclude' -and -not (Test-IsGroupSelection -TargetCombo $assignTargetCombo)) {
          [void][System.Windows.Forms.MessageBox]::Show((Get-UiString 'DeployExcludedRequiresGroup'), (Get-UiString 'ValidationTitle'),
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
          return
        }
        if ($targetChanges.AssignmentMode -eq 'exclude' -and $targetChanges.FilterType -ne 'none') {
          [void][System.Windows.Forms.MessageBox]::Show((Get-UiString 'DeployExcludeFilterConflict'), (Get-UiString 'ValidationTitle'),
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
          return
        }
        if ($targetChanges.FilterType -ne 'none' -and -not (Test-GuidString ([string]$targetChanges.FilterId))) {
          [void][System.Windows.Forms.MessageBox]::Show((Get-UiString 'DeployFilterIdRequired'), (Get-UiString 'ValidationTitle'),
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
          return
        }

        # A normal "Add app" upload must not create a second identical PackageId+Version. Resolve
        # directly before the mutation, just like the Microsoft Store duplicate guard.
        $deployDisplayName = if ($script:overrideAppNameBox -and $script:overrideAppNameBox.Text.Trim()) {
          $script:overrideAppNameBox.Text.Trim()
        } elseif ($package.Name) { [string]$package.Name } else { [string]$appName }
        $tenantApps = @(Get-CachedWin32Apps)
        # PackageId + version is the tenant-wide duplicate identity. Display-name differences are
        # scope metadata, not permission to create the same target twice.
        $duplicate = Find-ExistingUpdateTarget -Apps $tenantApps -PackageId $packageID -Version $version -PreferredName $deployDisplayName
        if ($duplicate) {
          [void][System.Windows.Forms.MessageBox]::Show(
            ((Get-UiString 'UploadDuplicateDialog') -f $duplicate.Name, $duplicate.CurrentVersion, $duplicate.GraphId),
            (Get-UiString 'UploadDuplicateTitle'), [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information)
          Write-Log ("Upload blocked: {0} {1} already exists as {2}." -f $packageID, $version, $duplicate.GraphId)
          return
        }
        $deploySplat = @{ PackageId = $packageID; Version = $version; RootPackageFolder = $folder; ErrorAction = 'Stop' }
        # Upload unassigned, then create the complete assignment (mode/filter/settings) in one
        # Graph call after the authoritative app id is known. This avoids a temporary wrong scope.
        $intentIdx = if ($script:assignIntentCombo) { [int]$script:assignIntentCombo.SelectedIndex } else { 0 }
        $assignmentIntent = switch ($intentIdx) {
          1 { 'required' }
          2 { 'uninstall' }
          default { 'available' }
        }
        # Optional Intune categories (comma-separated) from the Advanced options.
        if ($script:categoriesBox -and -not [string]::IsNullOrWhiteSpace($script:categoriesBox.Text)) {
          $cats = @($script:categoriesBox.Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
          if ($cats.Count -gt 0) { $deploySplat.Categories = $cats }
        }
        if ($script:overrideAppNameBox -and -not [string]::IsNullOrWhiteSpace($script:overrideAppNameBox.Text)) {
          $deploySplat.OverrideAppName = $script:overrideAppNameBox.Text.Trim()
        }
        if ($script:roleScopeTagsBox -and -not [string]::IsNullOrWhiteSpace($script:roleScopeTagsBox.Text)) {
          $scopeTags = @($script:roleScopeTagsBox.Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
          if ($scopeTags.Count -gt 0) { $deploySplat.RoleScopeTags = $scopeTags }
        }
        $deployedApp = Deploy-WtWin32App @deploySplat

        $returnedId = $null
        try { if ($deployedApp -and $deployedApp.Id) { $returnedId = [string]$deployedApp.Id } } catch {}
        $resolvedApp = Resolve-DeployedUpdateTarget -PackageId $packageID -Version $version -PreferredName $deployDisplayName -ReturnedId $returnedId
        $newGraphId = if ($resolvedApp -and $resolvedApp.GraphId) { [string]$resolvedApp.GraphId } else { $null }
        $assignmentProblem = $null

        # Assignment settings and optional target filter/group mode are written only against the
        # authoritative Graph mobileApp id resolved back from Intune, never the module result id.
        if ($assignTarget -and $newGraphId) {
          $deploySettings = $plannedDeploySettings
          if (-not $deploySettings) { $deploySettings = @{ '@odata.type' = '#microsoft.graph.win32LobAppAssignmentSettings' } }
          $r = New-AppAssignmentConfiguration -AppId $newGraphId -TargetValue $assignTarget -Intent $assignmentIntent `
            -AssignmentMode ([string]$targetChanges.AssignmentMode) -ExcludeBaseTarget ([string]$targetChanges.ExcludeBaseTarget) -FilterType ([string]$targetChanges.FilterType) `
            -FilterId ([string]$targetChanges.FilterId) -Settings $deploySettings -AppName $packageID
          if ($r.ErrorMessage) {
            $assignmentProblem = [string]$r.ErrorMessage
            Write-Log ("Assignment settings for {0} could not be applied: {1}" -f $packageID, $r.ErrorMessage)
            [void][System.Windows.Forms.MessageBox]::Show(((Get-UiString 'DeployAssignmentApplyFailed') -f $r.ErrorMessage),
              (Get-UiString 'UploadFailedTitle'), [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
          }
        } elseif ($assignTarget -and -not $newGraphId) {
          $warning = 'The authoritative Intune app ID could not be resolved. No optional assignment settings were written.'
          $assignmentProblem = $warning
          Write-Log $warning
          [void][System.Windows.Forms.MessageBox]::Show(((Get-UiString 'DeployAssignmentApplyFailed') -f $warning),
            (Get-UiString 'UploadFailedTitle'), [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        }

        # Optionally turn on Intune's built-in auto-update for the just-deployed app.
        if ($script:autoUpdateCheckbox -and $script:autoUpdateCheckbox.Checked -and $newGraphId) {
          try {
            Update-WtIntuneApp -AppId $newGraphId -EnableAutoUpdate -ErrorAction Stop | Out-Null
            Write-Log "Enabled Intune auto-update for $packageID (app $newGraphId)."
          } catch {
            $autoUpdateError = "Auto-update enable failed for ${packageID}: $($_.Exception.Message)"
            Write-Log $autoUpdateError
            $assignmentProblem = if ($assignmentProblem) { "$assignmentProblem; $autoUpdateError" } else { $autoUpdateError }
          }
        } elseif ($script:autoUpdateCheckbox -and $script:autoUpdateCheckbox.Checked -and -not $newGraphId) {
          $autoUpdateError = 'Auto-update was requested, but the authoritative Intune app ID could not be resolved.'
          Write-Log $autoUpdateError
          $assignmentProblem = if ($assignmentProblem) { "$assignmentProblem; $autoUpdateError" } else { $autoUpdateError }
        }

        if ($assignmentProblem) {
          Update-Status ((Get-UiString 'UploadPartialStatus') -f $assignmentProblem)
        } else {
          Update-Status (Get-UiString 'UploadCompletedStatus')
        }
        # Record the deployment for the performance text. The assignment itself is recorded inside
        # New-AppAssignmentConfiguration above, so it is not double-counted here.
        $deployedName = if ($deployDisplayName) { [string]$deployDisplayName } else { [string]$packageID }
        try { Add-SessionActivity -Kind 'Deployed' -Name $deployedName -FromVersion ([string]$version) -Detail (Get-UiString 'ActivityDeployed') } catch { }
        $uploadSucceeded = $true
        $uploadButton.Enabled = $false
        $appSearchBox.Text = ""
        $dropdown.Items.Clear()

        # Clear version cache for this package so updates will use latest version
        if ($script:selectedPackageVersions.ContainsKey($packageID)) {
            $script:selectedPackageVersions.Remove($packageID)
            Write-Log "Cleared cached version for $packageID after upload"
        }
    } catch {
        $errorMsg = $_.Exception.Message
        Update-Status (Get-UiString 'UploadFailedStatus')
        Write-Log "Upload error: $errorMsg"

        [System.Windows.Forms.MessageBox]::Show(
            ((Get-UiString 'UploadFailedDialog') -f $packageID, $version, $errorMsg),
            (Get-UiString 'UploadFailedTitle'),
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
    } finally {
        $script:progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
        $script:progressBar.Visible = $false
        $script:progressBar.Value = 0
        $uploadButton.Enabled = (-not $uploadSucceeded)
        $createButton.Enabled = $true
    }
})


# ----------------------------------------------
# Check All / Uncheck All Buttons
# ----------------------------------------------
# Check/Uncheck All deliberately act on the VISIBLE rows only. Marking every app in the model while
# a filter is active was dangerous: the hidden apps stayed checked, reappeared checked once the
# filter was cleared, and "Update checked apps" would then update far more apps than intended.
# The ItemChecked handler mirrors each row into the model, so no separate model loop is needed.
$checkAllButton.Add_Click({
  foreach ($row in $updateListBox.Items) { $row.Checked = $true }
  Update-Status ((Get-UiString 'AllAppsCheckedStatus') -f $updateListBox.Items.Count)
})

$uncheckAllButton.Add_Click({
  foreach ($row in $updateListBox.Items) { $row.Checked = $false }
  Update-Status (Get-UiString 'AllAppsUncheckedStatus')
})

# Save checked state when user checks/unchecks an item in the update list
# ListView raises ItemChecked AFTER the state changed (unlike CheckedListBox's ItemCheck, which
# reports the pending value), so read the final state straight off the row.
$updateListBox.Add_ItemChecked({
  param($sender, $e)
  try {
    if ($script:updateListRefreshing) { return }
    $appObj = $e.Item.Tag
    if ($appObj) { $appObj.Checked = [bool]$e.Item.Checked }
  } catch {
    # The row/model sync decides WHICH apps an update run touches - a silent failure here could
    # mean updating an app the user did not tick.
    Write-Log ("Update list selection sync failed: {0}" -f $_.Exception.Message)
  }
})

# ----------------------------------------------
# Update List Filter - filters as you type (debounced 200ms)
# ----------------------------------------------
$updateFilterDebounceTimer = New-Object System.Windows.Forms.Timer
$updateFilterDebounceTimer.Interval = 200
$updateFilterDebounceTimer.Add_Tick({
  $updateFilterDebounceTimer.Stop()
  $filterText = $updateFilterBox.Text.Trim()

  # Clear and repopulate list with filtered items
  $script:updateListRefreshing = $true
  $updateListBox.BeginUpdate()
  try {
    $updateListBox.Items.Clear()

    if ([string]::IsNullOrWhiteSpace($filterText)) {
      # No filter - show all apps
      foreach ($app in @($script:updateApps)) {
        if ($app -and $app.Name) { [void]$updateListBox.Items.Add((New-UpdateRow -App $app)) }
      }
    } else {
      # Filter by name, package id or either visible version.
      $filtered = $script:updateApps | Where-Object {
        $_.Name -like "*$filterText*" -or $_.PackageId -like "*$filterText*" -or
        $_.CurrentVersion -like "*$filterText*" -or $_.LatestVersion -like "*$filterText*"
      }
      foreach ($app in @($filtered)) {
        if ($app -and $app.Name) { [void]$updateListBox.Items.Add((New-UpdateRow -App $app)) }
      }
    }
  } finally {
    $updateListBox.EndUpdate()
    $script:updateListRefreshing = $false
  }
  # Update status with filter info
  if (-not [string]::IsNullOrWhiteSpace($filterText)) {
    Update-Status ((Get-UiString 'FilterMatchStatus') -f $updateListBox.Items.Count, $filterText)
  }
})

$updateFilterBox.Add_TextChanged({
  $updateFilterDebounceTimer.Stop()
  $updateFilterDebounceTimer.Start()
})


# ----------------------------------------------
# UPDATED: Robust & verbose "Search Updates"
# ----------------------------------------------
$updateSearchButton.Add_Click({
  if (-not (Test-Connected)) { return }
  if (Test-UiBusy) { return }

  try {
    $updateSearchButton.Enabled = $false
    Update-Status (Get-UiString 'LoadingAppsStatus')

    # Reset UI / cache
    $updateFilterBox.Text = ""  # Clear filter
    $updateListBox.Items.Clear()
    $script:updateApps = @()

    # 1) Load active and superseded inventories. A recently superseded app can temporarily be
    # returned by both module queries; GraphId overlap is removed before update evaluation.
    $all = @()
    try {
      $activeInventory = @(Get-Win32AppsResilient -Label 'updates load (active)')
      $supersededInventory = @()
      try {
        $supersededInventory = @(Get-Win32AppsResilient -Superseded -Label 'updates load (superseded)')
      } catch {
        Write-Log ("Could not load the superseded inventory for scan classification: {0}. Active items remain visible, but the pre-upload guard will still block unsafe mutations." -f $_.Exception.Message)
      }
      $all = @(Remove-SupersededInventoryOverlap -ActiveApps $activeInventory -SupersededApps $supersededInventory)
      Write-Log ("Loaded {0} active app object(s) from Intune after excluding {1} superseded overlap(s)." -f $all.Count, ($activeInventory.Count - $all.Count))
    } catch {
      # Include the exception TYPE, not just the message: a binding error, a Graph error and a module
      # race read very differently in a bug report, and the type is the fastest way to tell them apart.
      Write-Log ("Failed to load apps [{0}]: {1}" -f $_.Exception.GetType().Name, $_.Exception.Message)
      Update-Status (Get-UiString 'LoadAppsFailedStatus')
      return
    }

    if ($all.Count -eq 0) {
      Update-Status (Get-UiString 'NoAppsInIntuneStatus')
      return
    }

    # 2) Keep every concrete ACTIVE Intune app object. Earlier builds collapsed duplicate product
    # IDs to one version; 0.13.8 keeps active predecessors visible for assignment/cleanup follow-up
    # while already-superseded Graph objects stay exclusively in the superseded-apps section.
    $appsToCheck = @($all | Where-Object { $_ -and $_.CurrentVersion -and $_.GraphId })
    $resolvedIds = @{}
    foreach ($a in $appsToCheck) {
      try {
        $resolvedIds[[string]$a.GraphId] = [string](Resolve-WingetIdForApp -App $a)
      } catch {
        $resolvedIds[[string]$a.GraphId] = ''
        Write-Log ("Could not resolve a WinGet id for '{0}' ({1}): {2}" -f $a.Name, $a.GraphId, $_.Exception.Message)
      }
    }
    Write-Log ("Checking all {0} concrete active Intune app version(s); already-superseded Graph objects are excluded." -f $appsToCheck.Count)

    # Show progress bar
    $script:progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
    $script:progressBar.Value = 0
    $script:progressBar.Maximum = [Math]::Max(1, $appsToCheck.Count)
    $script:progressBar.Visible = $true

    $candidates = [System.Collections.Generic.List[object]]::new()
    $processedCount = 0
    $totalCount = $appsToCheck.Count
    $failedChecks = 0
    $freshByPackageId = @{}

    foreach ($app in $appsToCheck) {
      $processedCount++

      # Update progress every app
      try {
        $script:progressBar.Value = $processedCount
        Update-Status ((Get-UiString 'CheckingAppStatus') -f $processedCount, $totalCount, $app.Name)
        [System.Windows.Forms.Application]::DoEvents()  # pumps the message loop; this work stays on the UI thread on purpose (see 70-Runtime)
      } catch { Write-LogDebug ("Progress update: {0}" -f $_.Exception.Message) }

      # Try to resolve winget ID
      $wingetId = [string]$resolvedIds[[string]$app.GraphId]
      $verified = $false

      if ($wingetId) {
        # Query BOTH WinTuner's online package index and the local WinGet source. A manual scan
        # bypasses every GUI cache and uses the newer version if the two channels disagree.
        try {
          $cacheKey = $wingetId.ToLowerInvariant()
          if (-not $freshByPackageId.ContainsKey($cacheKey)) {
            $freshByPackageId[$cacheKey] = Get-FreshLatestPackageVersion -PackageId $wingetId
          }
          $fresh = $freshByPackageId[$cacheKey]
          if ($fresh -and $fresh.Latest) {
            $latest = [string]$fresh.Latest
            if (Test-IsNewerVersion $latest $app.CurrentVersion) {
              $tenantNewer = Find-NewerTenantPackageTarget -Apps $all -PackageId $wingetId -Version $latest -ExcludeGraphId ([string]$app.GraphId) -ResolvedIds $resolvedIds
              if ($tenantNewer -and $tenantNewer.GraphId) {
                Write-Log ("Update row skipped: {0} {1} has source target {2}, but Intune already contains newer active version {3} ({4})." -f $app.Name, $app.CurrentVersion, $latest, $tenantNewer.CurrentVersion, $tenantNewer.GraphId)
              } else {
                $existingTarget = Find-ExistingUpdateTarget -Apps $all -PackageId $wingetId -Version $latest -ExcludeGraphId ([string]$app.GraphId) -PreferredName ([string]$app.Name) -ResolvedIds $resolvedIds
                $targetId = if ($existingTarget) { [string]$existingTarget.GraphId } else { $null }
                $targetName = if ($existingTarget) { [string]$existingTarget.Name } else { $null }
                $showCandidate = (-not $existingTarget) -or (Test-RequiresExistingTargetFollowUp -SourceApp $app -ExistingTarget $existingTarget)
                if ($showCandidate) {
                  $candidates.Add((New-UpdateCandidateModel -App $app -LatestVersion $latest -PackageId $wingetId -ExistingTargetGraphId $targetId -ExistingTargetName $targetName))
                }
                if ($targetId -and $showCandidate) {
                  Write-Log ("Follow-up only: {0} ({1}, GraphId {2}) has existing target {3} ({4}); no package or upload is required." -f $app.Name, $app.CurrentVersion, $app.GraphId, $latest, $targetId)
                } elseif (-not $targetId) {
                  Write-Log ("Update available: {0} ({1}, GraphId {2}) -> {3} (source: {4}); package/upload required." -f $app.Name, $app.CurrentVersion, $app.GraphId, $latest, $fresh.Source)
                }
              }
            }
            $verified = $true
          }
        } catch {
          Write-Log ("Fresh version check failed for {0} ({1}): {2} - falling back to the app metadata" -f $app.Name, $wingetId, $_.Exception.Message)
        }
      } else {
        Write-Log ("Skipping update check for '{0}': no safe WinGet package id could be resolved." -f $app.Name)
      }

      # Fallback only when a safe package id exists; otherwise the later packaging step could not
      # update the app anyway and must not guess a different product.
      if ($wingetId -and -not $verified -and $app.LatestVersion) {
        try {
          $verified = $true
          if (Test-IsNewerVersion $app.LatestVersion $app.CurrentVersion) {
            $fallbackLatest = [string]$app.LatestVersion
            $tenantNewer = Find-NewerTenantPackageTarget -Apps $all -PackageId $wingetId -Version $fallbackLatest -ExcludeGraphId ([string]$app.GraphId) -ResolvedIds $resolvedIds
            if ($tenantNewer -and $tenantNewer.GraphId) {
              Write-Log ("Fallback update row skipped: {0} {1} has source target {2}, but Intune already contains newer active version {3} ({4})." -f $app.Name, $app.CurrentVersion, $fallbackLatest, $tenantNewer.CurrentVersion, $tenantNewer.GraphId)
            } else {
              $existingTarget = Find-ExistingUpdateTarget -Apps $all -PackageId $wingetId -Version $fallbackLatest -ExcludeGraphId ([string]$app.GraphId) -PreferredName ([string]$app.Name) -ResolvedIds $resolvedIds
              $targetId = if ($existingTarget) { [string]$existingTarget.GraphId } else { $null }
              $targetName = if ($existingTarget) { [string]$existingTarget.Name } else { $null }
              $showCandidate = (-not $existingTarget) -or (Test-RequiresExistingTargetFollowUp -SourceApp $app -ExistingTarget $existingTarget)
              if ($showCandidate) {
                $candidates.Add((New-UpdateCandidateModel -App $app -LatestVersion $fallbackLatest -PackageId $wingetId -ExistingTargetGraphId $targetId -ExistingTargetName $targetName))
              }
              if ($targetId -and $showCandidate) {
                Write-Log ("Follow-up only (metadata fallback): {0} ({1}, GraphId {2}) has existing target {3} ({4}); no package or upload is required." -f $app.Name, $app.CurrentVersion, $app.GraphId, $fallbackLatest, $targetId)
              } elseif (-not $targetId) {
                Write-Log ("Update available (metadata fallback): {0} ({1}, GraphId {2}) -> {3}; package/upload required." -f $app.Name, $app.CurrentVersion, $app.GraphId, $fallbackLatest)
              }
            }
          }
        } catch {
          $verified = $false
          # An ambiguous target means the tenant already holds two apps with the same package id
          # AND version. Updating is genuinely unsafe, but silently dropping the row hid the
          # problem: the app vanished from the list with no way to act on it. Show it read-only.
          if ($_.Exception.Message -like '*Ambiguous existing target*') {
            $candidates.Add((New-UpdateCandidateModel -App $app -LatestVersion ([string]$app.LatestVersion) -PackageId $wingetId -BlockedReason (Get-UiString 'UpdateStateDuplicateTarget')))
            Write-Log ("Duplicate target in Intune for {0}: {1}. Row is shown read-only; remove the duplicate app version in Intune first." -f $app.Name, $_.Exception.Message)
          } else {
            Write-Log ("Fallback target resolution failed for {0}: {1}. No update row was created to avoid a duplicate target." -f $app.Name, $_.Exception.Message)
          }
        }
      }
      if (-not $verified) { $failedChecks++ }
    }
    # 3) Present one target row per PackageId + newest version. Every concrete predecessor remains
    # attached to that row for safe consolidation during the batch.
    $concreteCandidateCount = $candidates.Count
    $groupedCandidates = @(Group-UpdateCandidates -Candidates @($candidates))
    $count = 0
    $script:updateListRefreshing = $true
    $updateListBox.BeginUpdate()
    try {
      $script:updateApps = [System.Collections.Generic.List[object]]::new()
      foreach ($app in $groupedCandidates) {
        if (-not $app -or -not $app.Name) { continue }
        if (-not ($app | Get-Member -Name Checked -MemberType NoteProperty)) {
          $app | Add-Member -NotePropertyName Checked -NotePropertyValue $false -Force
        }
        [void]$updateListBox.Items.Add((New-UpdateRow -App $app))
        $script:updateApps.Add($app)
        $count++
      }
    } finally {
      $updateListBox.EndUpdate()
      $script:updateListRefreshing = $false
    }

    $newUploadCount = @($groupedCandidates | Where-Object { -not $_.TargetAlreadyDeployed }).Count
    $followUpCount = @($groupedCandidates | Where-Object { $_.TargetAlreadyDeployed }).Count
    Write-Log ("Scan classification: {0} new upload(s), {1} follow-up item(s) with an existing target, {2} outdated active source app object(s)." -f $newUploadCount, $followUpCount, $concreteCandidateCount)
    if ($count -gt 0) {
      if ($failedChecks -gt 0) {
        Update-Status ((Get-UiString 'SearchUpdatesGroupedWithFailuresStatus') -f $newUploadCount, $followUpCount, $concreteCandidateCount, $failedChecks)
      } else {
        Update-Status ((Get-UiString 'SearchUpdatesGroupedStatus') -f $newUploadCount, $followUpCount, $concreteCandidateCount)
      }
      # Enable check/uncheck buttons
      $checkAllButton.Enabled = $true
      $uncheckAllButton.Enabled = $true
    } else {
      if ($failedChecks -gt 0) {
        Update-Status ((Get-UiString 'NoUpdateCandidatesWithFailuresStatus') -f $failedChecks)
      } else {
        Update-Status (Get-UiString 'NoUpdateCandidatesStatus')
      }
      $checkAllButton.Enabled = $false
      $uncheckAllButton.Enabled = $false
    }
    # The dashboard tile says "Updates available", therefore it counts only targets that still
    # require a new package/upload. Existing-target follow-up remains visible in the detailed list.
    if ($script:dashUpdatesVal) { $script:dashUpdatesVal.Text = [string]$newUploadCount }
  } finally {
    $script:updateListRefreshing = $false
    $updateSearchButton.Enabled = $true
    $script:progressBar.Maximum = 100
    $script:progressBar.Value = 0
    $script:progressBar.Visible = $false
    if (Get-Command Update-UpdatesEmptyState -ErrorAction SilentlyContinue) { Update-UpdatesEmptyState }
  }
})

# -----------------------------
# UPDATED: Update Checked Apps flow
# -----------------------------
$updateSelectedButton.Add_Click({
    if (-not (Test-Connected)) { return }
  if (Test-UiBusy) { return }
    # Get checked items
    $checkedApps = [System.Collections.Generic.List[object]]::new()

    Write-Log "Processing $($updateListBox.CheckedItems.Count) checked items from UI"
    Write-Log "global:updateApps cache has $($script:updateApps.Count) apps"

    foreach ($row in $updateListBox.CheckedItems) {
        $itemName = $row.Text
        $foundApp = $row.Tag
        Write-Log "Looking for app: '$itemName' (GraphId: $($foundApp.GraphId))"

        if ($foundApp) {
            Write-Log "Found: $($foundApp.Name) (Current: $($foundApp.CurrentVersion), Latest: $($foundApp.LatestVersion), GraphId: $($foundApp.GraphId))"
            $checkedApps.Add($foundApp)
        } else {
          Write-Log "WARNING: Could not find '$itemName' in cache!"
            Write-Log "The selected row no longer has an update model; run the scan again."
        }
    }

    if ($checkedApps.Count -eq 0) {
        Update-Status (Get-UiString 'NoValidAppsStatus')
        Write-Log "ERROR: 0 apps matched from $($updateListBox.CheckedItems.Count) checked items"
        return
    }

    Write-Log "Successfully matched $($checkedApps.Count) apps for update"

    if (-not (Confirm-UpdateScopeConsolidation -Groups @($checkedApps))) {
        Update-Status (Get-UiString 'MassUpdateCanceledStatus'); return
    }

    # Confirm before touching the tenant – the selection can be larger than expected (filters,
    # "check all"), and updating apps in Intune is not something to trigger by a stray click.
    $namesPreview = (@($checkedApps | Select-Object -First 15 | ForEach-Object {
      $action = if ($_.TargetAlreadyDeployed) { Get-UiString 'UpdateActionReuse' } else { Get-UiString 'UpdateActionUpload' }
      "- $($_.Name): $($_.CurrentVersion) -> $($_.LatestVersion) [$action]"
    }) -join "`r`n")
    if ($checkedApps.Count -gt 15) { $namesPreview += "`r`n- ..." }
    $confirmSel = [System.Windows.Forms.MessageBox]::Show(
        ((Get-UiString 'UpdateSelectedConfirmDialog') -f $checkedApps.Count, $namesPreview, (Get-UpdateCleanupNotice)),
        (Get-UiString 'ConfirmTitle'),
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($confirmSel -ne [System.Windows.Forms.DialogResult]::Yes) {
        Update-Status (Get-UiString 'MassUpdateCanceledStatus'); return
    }

    $rootPackageFolder = try { [System.IO.Path]::GetFullPath($pathBox.Text.Trim()) } catch {
      Update-Status ((Get-UiString 'InvalidFolderDialog') -f $pathBox.Text.Trim())
      return
    }
    if (-not (Test-PackageFolderUsable -Folder $rootPackageFolder)) { return }
    if (-not (Test-Path $rootPackageFolder)) {
        New-Item -ItemType Directory -Path $rootPackageFolder -Force | Out-Null
    }

    try {
        Update-Status ((Get-UiString 'StartingUpdateStatus') -f $checkedApps.Count)
        $concreteApps = @(Expand-UpdateCandidateGroups -Groups @($checkedApps))
        $batchResult = Invoke-AppUpdateBatch -Apps $concreteApps -RootPackageFolder $rootPackageFolder
        Update-Status ((Get-UiString 'CheckedAppsUpdatedStatus') -f $batchResult.SuccessCount, $batchResult.FailedList.Count)
    } catch {
        Update-Status ((Get-UiString 'UpdateErrorStatus') -f $_.Exception.Message)
        Write-Log "updateSelectedButton error: $($_.Exception.Message)"
    }
})


# -------------------------
# UPDATED: Update All flow
# -------------------------
$updateAllButton.Add_Click({
    if (-not (Test-Connected)) { return }
  if (Test-UiBusy) { return }
    # "Update all" must use the same fresh, dual-source scan as the visible list. Calling the
    # module's cached -Update filter here produced a different answer from "Search Updates".
    try {
        $updateSearchButton.PerformClick()
        $updatedApps = @($script:updateApps | Sort-Object Name)
    } catch {
        Write-Log "Fresh update-all scan threw: $($_)"
        $updatedApps = @()
    }

    if (-not $updatedApps -or $updatedApps.Count -eq 0) {
        return
    }

    if (-not (Confirm-UpdateScopeConsolidation -Groups @($updatedApps))) {
        Update-Status (Get-UiString 'MassUpdateCanceledStatus'); return
    }

    $rootPackageFolder = try { [System.IO.Path]::GetFullPath($pathBox.Text.Trim()) } catch {
      Update-Status ((Get-UiString 'InvalidFolderDialog') -f $pathBox.Text.Trim())
      return
    }
    if (-not (Test-PackageFolderUsable -Folder $rootPackageFolder)) { return }

    # Show confirmation dialog
    $appNames = ($updatedApps | ForEach-Object {
      $action = if ($_.TargetAlreadyDeployed) { Get-UiString 'UpdateActionReuse' } else { Get-UiString 'UpdateActionUpload' }
      "$($_.Name): $($_.CurrentVersion) -> $($_.LatestVersion) [$action]"
    }) -join "`r`n"
    $confirm = [System.Windows.Forms.MessageBox]::Show(
        ((Get-UiString 'UpdateConfirmDialog') -f $appNames, (Get-UpdateCleanupNotice)),
        (Get-UiString 'ConfirmTitle'),
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )

    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) {
        Update-Status (Get-UiString 'MassUpdateCanceledStatus')
        return
    }

    try {
        Update-Status ((Get-UiString 'StartingMassUpdateStatus') -f $updatedApps.Count)
        $concreteApps = @(Expand-UpdateCandidateGroups -Groups @($updatedApps))
        $batchResult = Invoke-AppUpdateBatch -Apps $concreteApps -RootPackageFolder $rootPackageFolder
        Update-Status ((Get-UiString 'AllUpdatesCompletedStatus') -f $batchResult.SuccessCount, $batchResult.FailedList.Count)
    } catch {
        Update-Status ((Get-UiString 'MassUpdateErrorStatus') -f $_.Exception.Message)
        Write-Log "updateAllButton error: $($_.Exception.Message)"
    }
})


$removeOldAppsButton.Add_Click({
  if (-not (Test-Connected)) { return }
  if (Test-UiBusy) { return }
  try {
    $supersededApps = @(Get-WtWin32Apps -Superseded:$true -ErrorAction Stop)
  } catch {
    Update-Status ((Get-UiString 'SupersededFetchErrorStatus') -f $_.Exception.Message)
    Write-Log "removeOldApps error: $($_.Exception.Message)"
    return
  }
  try {
    if ($supersededApps.Count -eq 0) { Update-Status (Get-UiString 'NoSupersededFoundStatus'); return }
    $appNames = ($supersededApps | ForEach-Object { "{0} {1} ({2})" -f $_.Name, $_.CurrentVersion, $_.GraphId }) -join "`r`n"
    $result = [System.Windows.Forms.MessageBox]::Show(
      ((Get-UiString 'RemoveSupersededConfirmDialog') -f $appNames),
      (Get-UiString 'ConfirmationTitle'),
      [System.Windows.Forms.MessageBoxButtons]::YesNo,
      [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
      $script:progressBar.Value = 0
      $script:progressBar.Visible = $true
      $removedCount = 0; $keptCount = 0
      foreach ($app in @($supersededApps)) {
        $assignmentProbe = Get-AppAssignmentProbe -AppId $app.GraphId -AppName $app.Name
        $installationProbe = Get-AppInstallationProbe -AppId $app.GraphId -AppName $app.Name
        if (-not $assignmentProbe.Succeeded -or -not $installationProbe.Succeeded -or
            $assignmentProbe.HasAssignments -or $installationProbe.HasInstallations) {
          $keptCount++
          Update-Status ((Get-UiString 'SupersededSafetyKeptStatus') -f $app.Name)
          Write-Log ("Superseded cleanup: kept {0} {1} ({2}); assignments/installations are present or unknown." -f $app.Name, $app.CurrentVersion, $app.GraphId)
          continue
        }
        try {
          Invoke-WtRemoveWin32App -AppId $app.GraphId
          Add-SessionActivity -Kind 'SupersededRemoved' -Name ([string]$app.Name) -FromVersion ([string]$app.CurrentVersion)
          $removedCount++
          Update-Status ((Get-UiString 'RemovedStatus') -f $app.Name)
        } catch {
          $rmMsg = $_.Exception.Message
          if (Test-IsNotFoundError -ErrorRecord $_ -Context ([string]$app.Name)) {
            $removedCount++
            Write-Log "App already removed or not found in Intune: $($app.Name)"
            Update-Status ((Get-UiString 'AlreadyRemovedStatus') -f $app.Name)
          } elseif ($rmMsg -match 'parent of another app' -or $rmMsg -match 'Cannot delete this app') {
            # Still referenced as the predecessor of a newer version. Try to unlink the supersedence
            # on the newer app (id from the error) and delete again; otherwise keep it.
            $newId = Get-SupersedingAppIdFromError $rmMsg
            if ($newId -and (Remove-SupersededByUnlinking -OldAppId $app.GraphId -NewAppId $newId)) {
              $removedCount++
              Update-Status ((Get-UiString 'RemovedStatus') -f $app.Name)
            } else {
              $keptCount++
              Write-Log "Superseded cleanup: kept $($app.Name) - still referenced as the predecessor of a newer version (devices not fully migrated yet)."
              Update-Status ((Get-UiString 'SupersededStillReferencedStatus') -f $app.Name)
            }
          } else {
            $keptCount++
            Update-Status ((Get-UiString 'ErrorRemovingStatus') -f $app.Name, $rmMsg)
            Write-Log "Error while removal: $rmMsg"
          }
        }
      }
      $script:progressBar.Maximum = 100
      $script:progressBar.Value = 100
      Update-Status ((Get-UiString 'DeletedAllSupersededStatus') -f $removedCount, $keptCount)
      try { $supersededSearchButton.PerformClick() } catch { Write-LogDebug ("Superseded refresh: {0}" -f $_.Exception.Message) }
    } else {
      Update-Status (Get-UiString 'RemovalAbortedStatus')
    }
  } catch {
    Write-Log "Error loading superseded apps: $($_.Exception.Message)"
    Update-Status ((Get-UiString 'GenericErrorStatus') -f $_.Exception.Message)
  }
})

# Handler: Search superseded apps
$script:supersededApps = @()
$supersededSearchButton.Add_Click({
  if (-not (Test-Connected)) { return }
  if (Test-UiBusy) { return }
  try {
    Update-Status (Get-UiString 'SearchingSupersededStatus')
    $script:supersededApps = Get-WtWin32Apps -Superseded $true
    # Also pull the CURRENT (non-superseded) apps so each old entry can show the version that
    # replaced it – "Chrome — 150.x (current: 151.x)" – instead of a bare old version number.
    $currentByName = @{}
    try {
      foreach ($cur in @(Get-WtWin32Apps -Superseded:$false -ErrorAction SilentlyContinue)) {
        if ($cur -and $cur.Name) { $currentByName[[string]$cur.Name] = [string]$cur.CurrentVersion }
      }
    } catch { Write-Log "Superseded search: could not load current versions for comparison: $($_.Exception.Message)" }

    $supersededDropdown.Items.Clear()
    foreach ($app in @($script:supersededApps)) {
      $name = $app.Name
      $version = $app.CurrentVersion
      $display = "$name — $version"
      $newVer = $currentByName[[string]$name]
      if ($newVer -and $newVer -ne $version) {
        $display += ("  ({0} {1})" -f (Get-UiString 'SupersededCurrentLabel'), $newVer)
      }
      [void]$supersededDropdown.Items.Add($display)
    }
    if ($supersededDropdown.Items.Count -gt 0) { $supersededDropdown.SelectedIndex = 0 }
    Update-Status ((Get-UiString 'SupersededSearchCompletedStatus') -f $supersededDropdown.Items.Count)
  } catch {
    Write-Log "Superseded search error: $($_.Exception.Message)"
    Update-Status ((Get-UiString 'SupersededSearchErrorStatus') -f $_.Exception.Message)
  }
})




# Handler: Delete selected superseded app
$deleteSelectedAppButton.Add_Click({
  if (-not (Test-Connected)) { return }
  if (Test-UiBusy) { return }
  if (-not $script:supersededApps -or $supersededDropdown.SelectedIndex -lt 0) {
    Update-Status (Get-UiString 'SelectSupersededFirstStatus')
    return
  }
  $app = $script:supersededApps[$supersededDropdown.SelectedIndex]
  $result = [System.Windows.Forms.MessageBox]::Show(
    ((Get-UiString 'DeleteAppConfirmDialog') -f $app.Name),
    (Get-UiString 'ConfirmationTitle'),
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Question
  )
  if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
    $assignmentProbe = Get-AppAssignmentProbe -AppId $app.GraphId -AppName $app.Name
    $installationProbe = Get-AppInstallationProbe -AppId $app.GraphId -AppName $app.Name
    if (-not $assignmentProbe.Succeeded -or -not $installationProbe.Succeeded -or
        $assignmentProbe.HasAssignments -or $installationProbe.HasInstallations) {
      Update-Status ((Get-UiString 'SupersededSafetyKeptStatus') -f $app.Name)
      Write-Log ("Delete superseded: kept {0} {1} ({2}); assignments/installations are present or unknown." -f $app.Name, $app.CurrentVersion, $app.GraphId)
      return
    }
    try {
      Invoke-WtRemoveWin32App -AppId $app.GraphId
      Add-SessionActivity -Kind 'SupersededRemoved' -Name ([string]$app.Name) -FromVersion ([string]$app.CurrentVersion)
      Update-Status ((Get-UiString 'DeletedStatus') -f $app.Name)
      try { $supersededSearchButton.PerformClick() } catch { Write-LogDebug ("Superseded refresh: {0}" -f $_.Exception.Message) }
    } catch {
      $delMsg = $_.Exception.Message
      if ($delMsg -match 'parent of another app' -or $delMsg -match 'Cannot delete this app') {
        $newId = Get-SupersedingAppIdFromError $delMsg
        if ($newId -and (Remove-SupersededByUnlinking -OldAppId $app.GraphId -NewAppId $newId)) {
          Update-Status ((Get-UiString 'DeletedStatus') -f $app.Name)
          try { $supersededSearchButton.PerformClick() } catch { Write-LogDebug ("Superseded refresh: {0}" -f $_.Exception.Message) }
        } else {
          Write-Log "Delete superseded: kept $($app.Name) - still referenced as the predecessor of a newer version."
          Update-Status ((Get-UiString 'SupersededStillReferencedStatus') -f $app.Name)
        }
      } else {
        Update-Status ((Get-UiString 'ErrorRemovalStatus') -f $delMsg)
      }
    }
  } else {
    Update-Status (Get-UiString 'RemovalAbortedStatus')
  }
})

$disconnectButton.Add_Click({
  # Lightweight disconnect: ends the current session only. The Windows auth broker (WAM)
  # and the Microsoft.Graph disk token cache are left untouched on purpose, so the next
  # login reconnects silently without a new sign-in prompt.
  try {
    Disconnect-WtWinTuner -ErrorAction Stop
  } catch {
    Write-Log "Disconnect warning: $($_.Exception.Message)"
  }
  try { Disconnect-MgGraph -ErrorAction SilentlyContinue } catch { }   # class 3: best-effort teardown
  $script:isConnected = $false
  $script:currentUserUpn = ""
  if ($loginInfoLabel) { $loginInfoLabel.Text = "" }
  Update-Status (Get-UiString 'DisconnectedStatus')
  Set-ConnectedUIState -Connected $false
})

$logoutButton.Add_Click({
  try {
    Disconnect-WtWinTuner -ErrorAction Stop
  } catch {
    Write-Log "Logout warning: $($_.Exception.Message)"
  }
  try { Disconnect-MgGraph -ErrorAction SilentlyContinue } catch { }   # class 3: best-effort teardown

  # Disconnect-WtWinTuner/-MgGraph only clear the in-memory session; this also wipes the
  # on-disk Graph token cache and forces a real sign-in next time.
  Clear-GraphTokenCache

  $script:isConnected = $false
  $script:currentUserUpn = ""
  if ($loginInfoLabel) { $loginInfoLabel.Text = "" }
  $usernameBox.Text = ""
  Update-Status (Get-UiString 'LogoutSuccessStatus')
  Set-ConnectedUIState -Connected $false
})
# ==================================================
# ==================================================
# Discovered Apps Handlers
# ==================================================

# Handler für das Filtern / Sortieren
function Update-DiscoveredListUI {
    $discoveredListBox.BeginUpdate()
    $discoveredListBox.Items.Clear()

    $searchText = $discoveredAppSearchBox.Text
    $pubText = $discoveredPublisherBox.Text
    $sortType = $discoveredSortBox.Text

    # Use a List for efficient collection building
    $newFiltered = [System.Collections.Generic.List[object]]::new()

    foreach ($item in $script:discoveredRaw) {
        $match = $true

        # 1. Filtern nach Textfeld (DisplayName oder Winget-Name)
        if (-not [string]::IsNullOrWhiteSpace($searchText)) {
            $escapedSearch = [regex]::Escape($searchText)
            # Wenn der Text weder im Anzeigenamen noch im Winget-Namen vorkommt, ist es kein Match
            if (($item.DisplayName -notmatch "(?i)$escapedSearch") -and ($item.WingetApp.Name -notmatch "(?i)$escapedSearch") -and ($item.WingetApp.PackageID -notmatch "(?i)$escapedSearch")) {
                $match = $false
            }
        }

        # 2. Filtern nach Publisher (Dropdown)
        if ($match -and -not [string]::IsNullOrWhiteSpace($pubText) -and $pubText -ne "<All Publishers>") {
            $escapedPub = [regex]::Escape($pubText)
            if ($item.Publisher -notmatch "(?i)$escapedPub") {
                $match = $false
            }
        }

        # Wenn die App beide Filter übersteht, zum neuen Array hinzufügen
        if ($match) {
            $newFiltered.Add($item)
        }
    }

    # 3. Sortieren
    if ($sortType -eq "Alphabetical") {
        $newFiltered = $newFiltered | Sort-Object DisplayName
    } else {
        $newFiltered = $newFiltered | Sort-Object DeviceCount -Descending
    }

    # 4. In die sichtbare ListBox einfügen
    if ($newFiltered) {
        foreach ($obj in $newFiltered) {
            # New-DiscoveredRow restores the checked state from the model, so it survives filtering.
            [void]$discoveredListBox.Items.Add((New-DiscoveredRow -Obj $obj))
        }
    }
    $discoveredListBox.EndUpdate()
    # Show EITHER the hint (nothing scanned yet) OR the list – never both, so the native list HWND
    # can't paint over the hint. "Empty" = nothing scanned (raw list empty), not merely filtered to 0.
    $empty = (-not $script:discoveredRaw -or @($script:discoveredRaw).Count -eq 0)
    if ($discoveredEmptyLabel) { $discoveredEmptyLabel.Visible = $empty }
    $discoveredListBox.Visible = (-not $empty)
    if ($empty -and $discoveredEmptyLabel) { $discoveredEmptyLabel.BringToFront() }
}

# Toggles the updates list empty-state hint (shown until a scan has populated $script:updateApps).
function Update-UpdatesEmptyState {
  # Show EITHER the hint OR the list – never both: a native list control paints over an overlapping
  # managed label, which previously produced a garbled/mis-placed hint (same fix as Discovered).
  $empty = (@($script:updateApps).Count -eq 0)
  if ($updatesEmptyLabel) {
    $updatesEmptyLabel.Visible = $empty
    if ($empty) { $updatesEmptyLabel.BringToFront() }
  }
  if ($updateListBox) { $updateListBox.Visible = (-not $empty) }
}

# Listener für das Suchfeld (Text-Eingabe) – debounced 200ms
$discoveredSearchDebounceTimer = New-Object System.Windows.Forms.Timer
$discoveredSearchDebounceTimer.Interval = 200
$discoveredSearchDebounceTimer.Add_Tick({
  $discoveredSearchDebounceTimer.Stop()
  Update-DiscoveredListUI
})

$discoveredAppSearchBox.Add_TextChanged({
  $discoveredSearchDebounceTimer.Stop()
  $discoveredSearchDebounceTimer.Start()
})

# Listener für das Publisher-Dropdown
$discoveredPublisherBox.Add_SelectedIndexChanged({ Update-DiscoveredListUI })

# Listener für das Sortierungs-Dropdown
$discoveredSortBox.Add_SelectedIndexChanged({ Update-DiscoveredListUI })

# Wenn ein Haken gesetzt/entfernt wird, Zustand im Array speichern (überlebt Filterung!)
$discoveredListBox.Add_ItemChecked({
    param($sender, $e)
    try {
        # .Tag holds the source object – no text matching needed, and it survives filtering/sorting.
        $obj = $e.Item.Tag
        if ($obj) { $obj.Checked = [bool]$e.Item.Checked }
    } catch {
        # Class 1: "Deploy checked" reads this model, so a lost sync could deploy the wrong apps.
        Write-Log ("Discovered list selection sync failed: {0}" -f $_.Exception.Message)
    }
})

# VISIBLE rows only – see the note on the updates list. This one mattered even more here: deploy
# reads the model ($script:discoveredRaw | Where Checked), so checking "all" behind an active filter
# would have deployed every scanned app instead of the handful the user was looking at.
$checkAllDiscoveredButton.Add_Click({
    foreach ($row in $discoveredListBox.Items) { $row.Checked = $true }   # .Tag mirrors into the model
    Update-Status ((Get-UiString 'AllDiscoveredCheckedStatus') -f $discoveredListBox.Items.Count)
})

$uncheckAllDiscoveredButton.Add_Click({
    foreach ($row in $discoveredListBox.Items) { $row.Checked = $false }
    Update-Status (Get-UiString 'AllDiscoveredUncheckedStatus')
})

$scanDiscoveredButton.Add_Click({
  if (-not (Test-Connected)) { return }
  if (Test-UiBusy) { return }

  # Speichere die originalen Streams und schalte sie stumm, um Threading-Crashes zu vermeiden
  $oldProgress = $ProgressPreference
  $oldInfo = $InformationPreference
  $ProgressPreference = 'SilentlyContinue'
  $InformationPreference = 'SilentlyContinue'

  try {
    $scanDiscoveredButton.Enabled = $false
    $deployDiscoveredButton.Enabled = $false
    $exportDiscoveredCsvButton.Enabled = $false
    $discoveredListBox.Items.Clear()
    $script:discoveredRaw = [System.Collections.Generic.List[object]]::new()

    $script:progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
    $script:progressBar.Visible = $true
    [System.Windows.Forms.Application]::DoEvents()  # pumps the message loop; this work stays on the UI thread on purpose (see 70-Runtime)

# --- GRAPH-AUTH BLOCK (FIXED) ---
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        Update-Status (Get-UiString 'GraphModuleNotFoundStatus')
        [System.Windows.Forms.MessageBox]::Show(
            (Get-UiString 'GraphModuleNotFoundDialog'),
            (Get-UiString 'GraphModuleNotFoundTitle'),
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        return
    }

    # No second sign-in. This scan used to call Connect-MgGraph and query through Invoke-MgRestMethod,
    # which keeps its own session - so every user had to authenticate a SECOND time just to look at
    # discovered apps, even though the tenant connection was already established. The token from
    # Get-WtToken carries the same permissions and is what every other Graph call in this GUI uses.
    $discoveredToken = Get-WtToken -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace([string]$discoveredToken)) { throw 'WinTuner returned an empty access token.' }
    $discoveredHeaders = @{ Authorization = "Bearer $discoveredToken"; 'Content-Type' = 'application/json' }

    # 1. Vorhandene Apps checken (EXTREM SCHNELL DURCH "Resolve" STATT "Try-Resolve")
    Update-Status (Get-UiString 'LoadingManagedAppsStatus')
    [System.Windows.Forms.Application]::DoEvents()  # pumps the message loop; this work stays on the UI thread on purpose (see 70-Runtime)
    $existingApps = @(Get-WtWin32Apps -Superseded:$false -ErrorAction SilentlyContinue 2>$null 3>$null 4>$null 5>$null 6>$null)
    $existingPackageIds = [System.Collections.Generic.List[object]]::new()
    foreach ($eApp in $existingApps) {
        [System.Windows.Forms.Application]::DoEvents()  # pumps the message loop; this work stays on the UI thread on purpose (see 70-Runtime)
        $id = Resolve-WtWingetId -AppOrResult $eApp 2>$null 3>$null 4>$null 5>$null 6>$null
        if ($id) { $existingPackageIds.Add($id) }
    }

    # 2. Hole ALLE Discovered Apps aus Intune (inklusive Paginierung)
    Update-Status (Get-UiString 'FetchingDetectedStatus')
    [System.Windows.Forms.Application]::DoEvents()  # pumps the message loop; this work stays on the UI thread on purpose (see 70-Runtime)

    $uri = "https://graph.microsoft.com/beta/deviceManagement/detectedApps?`$top=500&`$orderby=deviceCount desc"
    $detectedApps = [System.Collections.Generic.List[object]]::new()
    $maxPages = 100
    $pageCount = 0

    do {
        $response = Invoke-RestMethod -Uri $uri -Method GET -Headers $discoveredHeaders -ErrorAction Stop
        if ($response.value) { $detectedApps.AddRange([object[]]$response.value) }
        $uri = $response.'@odata.nextLink'
        $pageCount++
        if ($pageCount -ge $maxPages) {
            Write-Log "Warning: Graph API pagination limit ($maxPages pages) reached. Some apps may not be shown."
            break
        }
    } while ($uri)

    if (-not $detectedApps -or $detectedApps.Count -eq 0) {
        Update-Status (Get-UiString 'NoDiscoveredFoundStatus')
        return
    }

    $filteredApps = @($detectedApps | Where-Object {
        $_.publisher -notmatch "(?i)Intel|HP|Dell|Lenovo|AMD|NVIDIA|Realtek|Synaptics|VMware"
    })

    $total = $filteredApps.Count
    $matchCount = 0              # unique PackageIDs shown in UI
    $matchedRawCount = 0         # total matched detected apps (before dedupe)

    # Prepare normalized list first (phase 1) so matching can run with cached query results (phase 2)
    $normalizedApps = [System.Collections.Generic.List[object]]::new()
    $skippedNonCandidateCount = 0
    foreach ($app in $filteredApps) {
        # 1. Entfernt restlos alles, was in Klammern steht (z.B. "(x64 de)", "(x86 en-US)")
        $searchName = $app.displayName -replace '\s*\([^)]*\)', ''
        # 2. Entfernt typische Versionsnummern, die aus Zahlen und Punkten bestehen
        $searchName = $searchName -replace '\s+[\d\.]+', ''
        $searchName = $searchName.Trim()
        if ([string]::IsNullOrWhiteSpace($searchName)) { continue }
        if (-not (Test-WingetSearchCandidate -DisplayName $searchName)) {
            if ($script:skipLowValueWingetCandidates) {
                $skippedNonCandidateCount++
                continue
            }
        }
        $normalizedApps.Add([pscustomobject]@{
            App        = $app
            SearchName = $searchName
        })
    }

    # Cache Search-WtWinGetPackage results by normalized search term
    # to reduce expensive/repetitive module calls in large environments
    $searchResultCache = @{}
    # Fast lookup for already created discovered entries by PackageID
    $discoveredByPackageId = @{}

    $uniqueSearchNames = @($normalizedApps | Select-Object -ExpandProperty SearchName -Unique)
    $queryTotal = $uniqueSearchNames.Count
    $queryCurrent = 0
    Update-Status ((Get-UiString 'PreparedAppsStatus') -f $normalizedApps.Count, $queryTotal, $skippedNonCandidateCount, $script:skipLowValueWingetCandidates)
    Write-Log "Discovery prep -> Filtered apps: $total, Normalized apps: $($normalizedApps.Count), Unique search terms: $queryTotal, Skipped non-candidates: $skippedNonCandidateCount, Skip-mode: $($script:skipLowValueWingetCandidates)"

    # Phase 1: fetch/search all unique terms
    $script:progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
    $script:progressBar.Maximum = if ($queryTotal -gt 0) { $queryTotal } else { 1 }
    $script:progressBar.Value = 0

    foreach ($searchName in $uniqueSearchNames) {
        $queryCurrent++
        $script:progressBar.Value = $queryCurrent
        if (($queryCurrent -eq 1) -or ($queryCurrent % 25 -eq 0) -or ($queryCurrent -eq $queryTotal)) {
            Update-Status ((Get-UiString 'QueryingWingetStatus') -f $queryCurrent, $queryTotal, $normalizedApps.Count, $searchName)
            [System.Windows.Forms.Application]::DoEvents()  # pumps the message loop; this work stays on the UI thread on purpose (see 70-Runtime)
        }
        try {
            $searchResultCache[$searchName] = @(Search-WtWinGetPackage -SearchQuery $searchName -ErrorAction SilentlyContinue 2>$null 3>$null 4>$null 5>$null 6>$null)
        } catch {
            $searchResultCache[$searchName] = @()
            Write-Log "Search failed for '$searchName': $($_.Exception.Message)"
        }
    }

    # Phase 2: match normalized discovered apps against cached results
    $processTotal = $normalizedApps.Count
    $processCurrent = 0
    $script:progressBar.Maximum = if ($processTotal -gt 0) { $processTotal } else { 1 }
    $script:progressBar.Value = 0

    foreach ($entry in $normalizedApps) {
        [System.Windows.Forms.Application]::DoEvents()  # pumps the message loop; this work stays on the UI thread on purpose (see 70-Runtime)
        $processCurrent++
        $script:progressBar.Value = $processCurrent
        if (($processCurrent -eq 1) -or ($processCurrent % 25 -eq 0) -or ($processCurrent -eq $processTotal)) {
            Update-Status ((Get-UiString 'MatchingAppsStatus') -f $processCurrent, $processTotal, $entry.App.displayName)
            [System.Windows.Forms.Application]::DoEvents()  # pumps the message loop; this work stays on the UI thread on purpose (see 70-Runtime)
        }

        try {
            $app = $entry.App
            $searchName = $entry.SearchName
            $wingetResults = if ($searchResultCache.ContainsKey($searchName)) { @($searchResultCache[$searchName]) } else { @() }

            $bestMatch = $null
            $highestScore = 0
            $runnerUpScore = 0
            $exactMatches = @($wingetResults | Where-Object {
              $_.Name -and [string]::Equals(([string]$_.Name).Trim(), $searchName, [System.StringComparison]::OrdinalIgnoreCase)
            })
            if ($exactMatches.Count -eq 1) {
              $bestMatch = $exactMatches[0]
              $highestScore = 100
            } else {
              $scoredMatches = @($wingetResults | ForEach-Object {
                [pscustomobject]@{ Item = $_; Score = (Get-StringSimilarity $searchName ([string]$_.Name)) }
              } | Sort-Object Score -Descending)
              if ($scoredMatches.Count -gt 0) {
                $bestMatch = $scoredMatches[0].Item
                $highestScore = [int]$scoredMatches[0].Score
                if ($scoredMatches.Count -gt 1) { $runnerUpScore = [int]$scoredMatches[1].Score }
              }
            }

            # Discovery can create a new tenant app, so a merely plausible 50% word overlap is not
            # sufficient. Require either one exact name or a dominant high-confidence result.
            if ($bestMatch -and $highestScore -ge 80 -and ($highestScore - $runnerUpScore) -ge 15) {
                $matchedRawCount++
                if ($existingPackageIds -contains $bestMatch.PackageID) { continue }

                # Prüfen, ob diese Winget-App (PackageID) bereits vorhanden ist
                $existingEntry = $null
                if ($discoveredByPackageId.ContainsKey($bestMatch.PackageID)) {
                    $existingEntry = $discoveredByPackageId[$bestMatch.PackageID]
                }

                if ($existingEntry) {
                    # App existiert bereits in der Liste: Wir addieren die Geräteanzahl (DeviceCount)
                    $existingEntry.DeviceCount += $app.deviceCount
                    # Den Anzeigetext mit der neuen, kombinierten Anzahl aktualisieren
                    $existingEntry.DisplayText = "[$($existingEntry.DeviceCount) PCs] $($existingEntry.DisplayName) ($($existingEntry.Publisher))  -->  Winget: $($existingEntry.WingetApp.Name) [$($existingEntry.WingetApp.PackageID)]"
                } else {
                    # App ist neu: Wir nutzen den sauberen Winget-Namen (ohne Versionsnummern aus Intune)
                    $cleanName = $bestMatch.Name
                    $itemObj = [pscustomobject]@{
                        DisplayName = $cleanName
                        Publisher   = $app.publisher
                        DeviceCount = $app.deviceCount
                        WingetApp   = $bestMatch
                        Checked     = $false
                        DisplayText = "[$($app.deviceCount) PCs] $cleanName ($($app.publisher))  -->  Winget: $($bestMatch.Name) [$($bestMatch.PackageID)]"
                    }
                    $script:discoveredRaw.Add($itemObj)
                    $discoveredByPackageId[$bestMatch.PackageID] = $itemObj
                    $matchCount++
                }
            } elseif ($wingetResults.Count -gt 0) {
              Write-Log ("Discovery skipped ambiguous match for '{0}' (best={1}, runner-up={2}); no package was selected automatically." -f $app.displayName, $highestScore, $runnerUpScore)
            }
        } catch {
            Write-Log "Failed to process '$($entry.App.displayName)': $($_.Exception.Message)"
        }
    }

# --- NEU: Befülle das Publisher-Dropdown mit eindeutigen Werten ---
    $uniquePublishers = $script:discoveredRaw | Select-Object -ExpandProperty Publisher -Unique | Sort-Object

    $discoveredPublisherBox.BeginUpdate()
    $discoveredPublisherBox.Items.Clear()
    [void]$discoveredPublisherBox.Items.Add("<All Publishers>")
    foreach ($pub in $uniquePublishers) {
        if (-not [string]::IsNullOrWhiteSpace($pub)) {
            [void]$discoveredPublisherBox.Items.Add($pub)
        }
    }
    $discoveredPublisherBox.SelectedIndex = 0
    $discoveredPublisherBox.EndUpdate()

    # Befüllt die Liste initial mit Sortierung
    Update-DiscoveredListUI

    if ($matchCount -gt 0) {
        Update-Status ((Get-UiString 'ScannedSummaryStatus') -f $detectedApps.Count, $total, $matchedRawCount, $matchCount)
        Write-Log "Discovery summary -> Scanned: $($detectedApps.Count), Filtered: $total, Matched apps: $matchedRawCount, Unique packages: $matchCount"
        $deployDiscoveredButton.Enabled = $true
        $exportDiscoveredCsvButton.Enabled = $true
        $checkAllDiscoveredButton.Enabled = $true
        $uncheckAllDiscoveredButton.Enabled = $true
    } else {
        Update-Status (Get-UiString 'NoWingetMatchesStatus')
        $exportDiscoveredCsvButton.Enabled = $false
    }

  } catch {
    Update-Status ((Get-UiString 'FetchDiscoveredErrorStatus') -f $_.Exception.Message)
    Write-Log "Scan Discovered Error: $($_.Exception.Message)"
  } finally {
    $ProgressPreference = $oldProgress
    $InformationPreference = $oldInfo
    $scanDiscoveredButton.Enabled = $true
    $script:progressBar.Maximum = 100
    $script:progressBar.Value = 0
    $script:progressBar.Visible = $false
  }
})

$deployDiscoveredButton.Add_Click({
    # Deploys to the tenant – must be gated, since the action buttons are always enabled now.
    if (-not (Test-Connected)) { return }
  if (Test-UiBusy) { return }
    $checkedItems = @($script:discoveredRaw | Where-Object { $_.Checked })
    if ($checkedItems.Count -eq 0) {
        Update-Status (Get-UiString 'NoAppsCheckedStatus')
        return
    }

    # Packaging + deploying creates NEW apps in Intune – always confirm, showing what and how many.
    $dNames = (@($checkedItems | Select-Object -First 15 | ForEach-Object { "- $($_.DisplayName)" }) -join "`r`n")
    if ($checkedItems.Count -gt 15) { $dNames += "`r`n- ..." }
    $confirmDep = [System.Windows.Forms.MessageBox]::Show(
        ((Get-UiString 'DeployDiscoveredConfirmDialog') -f $checkedItems.Count, $dNames),
        (Get-UiString 'ConfirmTitle'),
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($confirmDep -ne [System.Windows.Forms.DialogResult]::Yes) {
        Update-Status (Get-UiString 'DeploymentAbortedStatus'); return
    }

    $rootFolder = $script:settings.DefaultPackagePath
    if (-not $rootFolder) { $rootFolder = Get-DefaultPackagePath }
    try { $rootFolder = [System.IO.Path]::GetFullPath($rootFolder) } catch {
      Update-Status ((Get-UiString 'InvalidFolderDialog') -f $rootFolder); return
    }
    if (-not (Test-PackageFolderUsable -Folder $rootFolder)) { return }
    if (-not (Test-Path $rootFolder)) { New-Item -ItemType Directory -Path $rootFolder -Force | Out-Null }

    $assignTarget = Get-SelectedAssignmentTarget -TargetCombo $discoveredAssignTargetCombo -GroupIdBox $discoveredAssignGroupIdBox
    $discoveredTargetChanges = Get-DeployAssignmentTargetChanges
    $discoveredDeploySettings = Get-DeployAssignmentSettings
    $discoveredIntentIndex = if ($script:assignIntentCombo) { [int]$script:assignIntentCombo.SelectedIndex } else { 0 }
    $discoveredIntent = switch ($discoveredIntentIndex) { 1 { 'required' }; 2 { 'uninstall' }; default { 'available' } }
    if (-not $assignTarget -and ($discoveredDeploySettings -or $discoveredIntentIndex -ne 0 -or $discoveredTargetChanges.AssignmentMode -eq 'exclude' -or $discoveredTargetChanges.FilterType -ne 'none')) {
      [void][System.Windows.Forms.MessageBox]::Show((Get-UiString 'DeployAssignmentTargetRequired'), (Get-UiString 'ValidationTitle'),
        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
      return
    }
    if ($discoveredAssignTargetCombo.SelectedIndex -eq 3 -and -not (Test-GuidString ([string]$assignTarget))) {
      [void][System.Windows.Forms.MessageBox]::Show((Get-UiString 'DeployGroupIdRequired'), (Get-UiString 'ValidationTitle'),
        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
      return
    }
    if ($assignTarget -and $discoveredTargetChanges.AssignmentMode -eq 'exclude' -and -not (Test-IsGroupSelection -TargetCombo $discoveredAssignTargetCombo)) {
      [void][System.Windows.Forms.MessageBox]::Show((Get-UiString 'DeployExcludedRequiresGroup'), (Get-UiString 'ValidationTitle'),
        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
      return
    }
    if ($discoveredTargetChanges.AssignmentMode -eq 'exclude' -and $discoveredTargetChanges.FilterType -ne 'none') {
      [void][System.Windows.Forms.MessageBox]::Show((Get-UiString 'DeployExcludeFilterConflict'), (Get-UiString 'ValidationTitle'),
        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
      return
    }
    if ($discoveredTargetChanges.FilterType -ne 'none' -and -not (Test-GuidString ([string]$discoveredTargetChanges.FilterId))) {
      [void][System.Windows.Forms.MessageBox]::Show((Get-UiString 'DeployFilterIdRequired'), (Get-UiString 'ValidationTitle'),
        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
      return
    }

    $oldProgress = $ProgressPreference
    $oldInfo = $InformationPreference
    $ProgressPreference = 'SilentlyContinue'
    $InformationPreference = 'SilentlyContinue'

    try {
        $deployDiscoveredButton.Enabled = $false
        $scanDiscoveredButton.Enabled = $false
        $checkAllDiscoveredButton.Enabled = $false
        $uncheckAllDiscoveredButton.Enabled = $false

        $script:progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
        $script:progressBar.Maximum = $checkedItems.Count
        $script:progressBar.Value = 0
        $script:progressBar.Visible = $true

        $successCount = 0
        $failedCount = 0
        $i = 0

        foreach ($item in $checkedItems) {
            $i++
            $script:progressBar.Value = $i
            $wingetApp = $item.WingetApp

            Update-Status ((Get-UiString 'PackagingDeployingStatus') -f $i, $checkedItems.Count, $wingetApp.Name)
            [System.Windows.Forms.Application]::DoEvents()  # pumps the message loop; this work stays on the UI thread on purpose (see 70-Runtime)

            try {
                $packageId = $wingetApp.PackageID
                $version = $wingetApp.Version

                Write-Log "Creating package for discovered app: $packageId v$version"
                $pkgRes = New-WingetPackageWithFallback `
                    -PackageId $packageId `
                    -PackageFolder $rootFolder `
                    -LatestVersion $version `
                    -ErrorAction Stop
                if (-not $pkgRes -or -not $pkgRes.Succeeded) {
                  $pkgError = if ($pkgRes -and $pkgRes.ErrorMessage) { [string]$pkgRes.ErrorMessage } else { 'unknown package build error' }
                  throw "Package creation failed; deployment was not attempted: $pkgError"
                }
                $effVersion = if ($pkgRes.EffectiveVersion) { $pkgRes.EffectiveVersion } else { $version }

                # The tenant may have changed since the discovery scan. Recheck immediately before
                # upload so another administrator's deployment cannot result in a duplicate app.
                $freshApps = @(Get-WtWin32Apps -Superseded:$false -ErrorAction Stop)
                $alreadyThere = Find-ExistingUpdateTarget -Apps $freshApps -PackageId $packageId -Version $effVersion
                if ($alreadyThere) {
                  throw ("Package {0} {1} already exists in Intune as {2}; duplicate deployment blocked." -f $packageId, $effVersion, $alreadyThere.GraphId)
                }

                Write-Log "Uploading new app to tenant without a temporary assignment: $packageId v$effVersion"
                $discoveredDeployResult = Deploy-WtWin32App `
                    -PackageId $packageId `
                    -Version $effVersion `
                    -RootPackageFolder $rootFolder `
                    -ErrorAction Stop
                $returnedDiscoveredId = $null
                try { if ($discoveredDeployResult -and $discoveredDeployResult.Id) { $returnedDiscoveredId = [string]$discoveredDeployResult.Id } } catch {}
                $resolvedDiscovered = Resolve-DeployedUpdateTarget -PackageId $packageId -Version $effVersion -PreferredName ([string]$wingetApp.Name) -ReturnedId $returnedDiscoveredId
                $discoveredGraphId = if ($resolvedDiscovered -and $resolvedDiscovered.GraphId) { [string]$resolvedDiscovered.GraphId } else { $null }
                if (($assignTarget -or ($script:autoUpdateCheckbox -and $script:autoUpdateCheckbox.Checked)) -and -not $discoveredGraphId) {
                  throw 'The app was uploaded, but its authoritative Intune GraphId could not be resolved. Assignment and auto-update were not applied.'
                }
                if ($assignTarget) {
                  $settings = if ($discoveredDeploySettings) { $discoveredDeploySettings } else { @{ '@odata.type' = '#microsoft.graph.win32LobAppAssignmentSettings' } }
                  $assignmentResult = New-AppAssignmentConfiguration -AppId $discoveredGraphId -TargetValue $assignTarget -Intent $discoveredIntent `
                    -AssignmentMode ([string]$discoveredTargetChanges.AssignmentMode) -ExcludeBaseTarget ([string]$discoveredTargetChanges.ExcludeBaseTarget) -FilterType ([string]$discoveredTargetChanges.FilterType) `
                    -FilterId ([string]$discoveredTargetChanges.FilterId) -Settings $settings -AppKind win32 -AppName $packageId
                  if ($assignmentResult.ErrorMessage) {
                    throw ("The app was uploaded, but assignment failed: {0}" -f $assignmentResult.ErrorMessage)
                  }
                }
                if ($script:autoUpdateCheckbox -and $script:autoUpdateCheckbox.Checked) {
                  try {
                    Update-WtIntuneApp -AppId $discoveredGraphId -EnableAutoUpdate -ErrorAction Stop | Out-Null
                  } catch {
                    throw ("The app was uploaded, but auto-update could not be enabled: {0}" -f $_.Exception.Message)
                  }
                }
                $successCount++
                Write-Log "Successfully deployed new app: $packageId"
                try { Add-SessionActivity -Kind 'Deployed' -Name ([string]$wingetApp.Name) -FromVersion ([string]$effVersion) -Detail (Get-UiString 'ActivityDeployed') } catch { }
            } catch {
                $failedCount++
                Write-Log "Failed to deploy $($wingetApp.Name): $($_.Exception.Message)"
            }
        }

        Update-Status ((Get-UiString 'DeploymentCompleteStatus') -f $successCount, $failedCount)
        [System.Windows.Forms.MessageBox]::Show(
            ((Get-UiString 'DeploymentFinishedDialog') -f $successCount, $failedCount),
            (Get-UiString 'DeployCompleteTitle'),
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )

    } catch {
        Update-Status ((Get-UiString 'DeploymentErrorStatus') -f $_.Exception.Message)
        Write-Log "Deploy Discovered Apps Error: $($_.Exception.Message)"
    } finally {
        $ProgressPreference = $oldProgress
        $InformationPreference = $oldInfo
        $deployDiscoveredButton.Enabled = $true
        $scanDiscoveredButton.Enabled = $true
        $checkAllDiscoveredButton.Enabled = $true
        $uncheckAllDiscoveredButton.Enabled = $true
        $script:progressBar.Maximum = 100
        $script:progressBar.Value = 0
        $script:progressBar.Visible = $false
    }
})

$exportDiscoveredCsvButton.Add_Click({
    if (-not $script:discoveredRaw -or $script:discoveredRaw.Count -eq 0) {
        Update-Status (Get-UiString 'NoWingetExportStatus')
        return
    }

    $sfd = New-Object System.Windows.Forms.SaveFileDialog
    $sfd.Title = Get-UiString 'ExportCsvDialogTitle'
    $sfd.Filter = "CSV files (*.csv)|*.csv|All files (*.*)|*.*"
    $sfd.FileName = ("Discovered_WingetIDs_{0}.csv" -f (Get-Date -Format "yyyyMMdd_HHmmss"))

    if ($sfd.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        Update-Status (Get-UiString 'CsvExportCanceledStatus')
        return
    }

    try {
        $rows = @($script:discoveredRaw | Sort-Object DisplayName | ForEach-Object {
            [pscustomobject]@{
                DisplayName   = $_.DisplayName
                Publisher     = $_.Publisher
                DeviceCount   = $_.DeviceCount
                WingetName    = $_.WingetApp.Name
                WingetId      = $_.WingetApp.PackageID
                WingetVersion = $_.WingetApp.Version
            }
        })

        $rows | Export-Csv -Path $sfd.FileName -NoTypeInformation -Encoding utf8
        Write-Log "Exported discovered Winget IDs: $($rows.Count) row(s) -> $($sfd.FileName)"
        Update-Status ((Get-UiString 'ExportCompletedStatus') -f $rows.Count, $sfd.FileName)
    } catch {
        Write-Log "Export discovered Winget IDs failed: $($_.Exception.Message)"
        Update-Status ((Get-UiString 'CsvExportFailedStatus') -f $_.Exception.Message)
    }
})
# --- Build the sidebar navigation now that every section is registered ---
# Nav buttons are manually stacked in a plain Panel (NOT a FlowLayoutPanel – that turned out
# to swallow the button clicks in this layout; a plain Panel behaves like the working
# dashboard quick-action buttons).
$navFlow = New-Object System.Windows.Forms.Panel
$navFlow.Dock = [System.Windows.Forms.DockStyle]::Fill
$navFlow.Tag = 'no-theme'

$navY = 8
foreach ($s in $script:sections) {
  $btn = New-Object System.Windows.Forms.Button
  $btn.Text = $s.Label
  $btn.Tag = 'no-theme'
  $btn.Location = New-Object System.Drawing.Point(8, $navY)
  $btn.Size = New-Object System.Drawing.Size(204, 40)
  $btn.Padding = New-Object System.Windows.Forms.Padding(12, 0, 0, 0)
  $btn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
  $btn.FlatAppearance.BorderSize = 0
  $btn.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
  $btn.ImageAlign = [System.Drawing.ContentAlignment]::MiddleLeft
  $btn.TextImageRelation = [System.Windows.Forms.TextImageRelation]::ImageBeforeText
  $btn.Font = New-Object System.Drawing.Font("Segoe UI", 10)
  $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
  Enable-RoundedPaint -Button $btn -Radius 9   # DPI-safe rounded pill (paint, not region)
  # Carry the section key on the button itself and read it from the sender in a plain (non-closure)
  # handler. A loop-created {...}.GetNewClosure() handler proved unreliable at firing on real mouse
  # clicks here (the working dashboard quick-action buttons use plain, non-closure handlers), which
  # is why the sidebar navigation didn't switch. This closure-free form fires reliably.
  $btn.Name = "nav_" + $s.Key
  # Navigation fires from BOTH the native Click and an explicit left mouse-up. On this real system
  # the native Button.Click sometimes did not fire from a real mouse-up on the sidebar buttons
  # (hover + press showed, but no Click), so the sidebar didn't switch. Because the button captures
  # the mouse on press, the mouse-up is always delivered here – handling it makes navigation
  # reliable. Both paths guard on the active section so they never double-navigate.
  $btn.Add_Click({
    param($sender, $e)
    try {
      $k = $sender.Name.Substring(4)   # strip the "nav_" prefix
      if ($script:activeSection -ne $k) { Show-Section $k }
    } catch { try { Write-Log ("Nav click error: {0}" -f $_.Exception.Message) } catch {} }
  })
  $btn.Add_MouseUp({
    param($sender, $e)
    try {
      if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $k = $sender.Name.Substring(4)
        if ($script:activeSection -ne $k) { Show-Section $k }
      }
    } catch {}
  })
  $s.NavButton = $btn
  $navFlow.Controls.Add($btn)
  $navY += 44
}

# Performance record now lives in the top menu bar (next to Tools/Help); theme + language
# live in Settings. The sidebar is just the section navigation.
$sidebarPanel.Controls.Add($navFlow)

# Apply the theme selected in settings (Dark by default)
Set-GuiTheme -control $form -theme $script:currentTheme
# Colour the header from the active theme (elevated bar) from the very first render.
if ($headerPanel) {
  Set-GuiTheme -control $headerPanel -theme $script:currentTheme
  $headerPanel.BackColor = Get-HeaderBackColor $script:currentTheme
}
# Colour the sidebar + nav buttons from the active theme, and open the first section.
Update-SidebarTheme
Update-MenuTheme
Update-StatusStripTheme
# Tenant-action buttons look the same signed in or out (they were created disabled). Force them
# enabled once here; the handlers gate themselves via Test-Connected (sign-in popup when needed).
foreach ($b in @($updateSearchButton, $updateSelectedButton, $updateAllButton, $supersededSearchButton, $deleteSelectedAppButton, $removeOldAppsButton, $scanDiscoveredButton, $exportDiscoveredCsvButton)) {
  if ($b) { $b.Enabled = $true }
}
Show-Section 'dashboard'

# Style the log toggle to match the current theme and set its initial (expanded) label.
$logToggle.BackColor = $script:currentTheme.BackColor
$logToggle.ForeColor = $script:currentTheme.ForeColor
$logToggle.FlatAppearance.MouseOverBackColor = $script:currentTheme.TextBoxBackColor
Set-LogExpanded $true

# Safe logger for closing context
function Write-FileLog {
  param([string]$message)
  try { Write-Log $message } catch {}
}

# Re-entrancy protection for closing
$script:_closingInProgress = $false
$form.Add_FormClosing({
    param($sender, [System.Windows.Forms.FormClosingEventArgs]$e)

    # 1. Einstellungen speichern (inkl. Fenstergröße – RestoreBounds liefert die Größe des
    #    nicht-maximierten Fensters, damit ein maximiertes Fenster nicht die Bildschirmmaße speichert)
    try {
        if ($script:settings) {
            try {
                $isMax = ($sender.WindowState -eq [System.Windows.Forms.FormWindowState]::Maximized)
                $bounds = if ($isMax) { $sender.RestoreBounds } else { $sender.Bounds }
                if ($bounds.Width -ge 940 -and $bounds.Height -ge 680) {
                    $script:settings.WindowWidth  = [int]$bounds.Width
                    $script:settings.WindowHeight = [int]$bounds.Height
                }
                $script:settings.WindowMaximized = [bool]$isMax
            } catch {
                Write-Log ("Could not capture the window size on close: {0}" -f $_.Exception.Message)
            }
            Save-Settings
        }
    } catch {}

    # 2. Wenn bereits geschlossen wird, ignorieren
    if ($script:_closingInProgress) { return }
    $script:_closingInProgress = $true

    # 2a. Hintergrund-Runspace fürs Paketieren abräumen, damit kein Thread das Beenden aufhält.
    try {
        if ($script:pkgRunspace) {
            $script:cancelBatch = $true    # lässt eine laufende Paketierung abbrechen
            $script:pkgRunspace.Close()
            $script:pkgRunspace.Dispose()
            $script:pkgRunspace = $null
            Write-FileLog 'Shutdown: background packaging runspace closed.'
        }
    } catch { }   # class 3: teardown

    # 3. Falls verbunden, regulär abmelden
    if ($script:isConnected) {
        try {
            $form.Enabled = $false
            if ($script:statusLabel) {
                Update-Status (Get-UiString 'ClosingSignOutStatus')
                # Zwingt die UI, sich noch einmal schnell zu aktualisieren, bevor sie blockiert wird
                [System.Windows.Forms.Application]::DoEvents()  # pumps the message loop; this work stays on the UI thread on purpose (see 70-Runtime)
            }
        } catch {}

        Write-FileLog 'Shutdown: starting tenant disconnect.'

        try {
            # Use Start-ThreadJob (PS 7+) so the WinTuner module is available in the same process
            $job = Start-ThreadJob { Disconnect-WtWinTuner }
            $null = Wait-Job $job -Timeout 5
            if ($job.State -ne 'Completed') {
                Write-FileLog 'Shutdown: disconnect timed out after 5s, closing anyway.'
            }
            Remove-Job $job -Force -ErrorAction SilentlyContinue
        } catch {
            Write-FileLog "FormClosing disconnect warning: $($_.Exception.Message)"
        }

        Write-FileLog 'Shutdown: disconnect finished. Closing form.'
        $script:isConnected = $false
    }
})

# ==================================================
# Globale Fehlererfassung (Crashes & unhandled Exceptions)
# ==================================================
try {
    # Fängt Abstürze ab, die direkt durch die Benutzeroberfläche (Klicks etc.) passieren
    # Shown, not just logged. This is a tool that deletes Intune apps; carrying on in an undefined
    # state without telling anyone is the wrong default. Only the FIRST crash raises a dialog -
    # a fault inside a paint handler repeats with every redraw and would bury the screen in boxes -
    # everything after it goes to the log alone, which the dialog points at.
    $script:fatalErrorShown = $false
    [System.Windows.Forms.Application]::add_ThreadException({
        param($sender, $e)
        $ex = $e.Exception
        $errMsg = "FATAL UI ERROR: $($ex.Message)`n$($ex.StackTrace)"
        Write-FileLog $errMsg
        try {
          if (-not $script:fatalErrorShown) {
            $script:fatalErrorShown = $true
            [void][System.Windows.Forms.MessageBox]::Show(
              ((Get-UiString 'FatalErrorDialog') -f $ex.Message, $script:logFilePath),
              (Get-UiString 'FatalErrorTitle'),
              [System.Windows.Forms.MessageBoxButtons]::OK,
              [System.Windows.Forms.MessageBoxIcon]::Error)
          }
        } catch { }   # class 3: the crash notice must never itself crash the handler
    })

    # Fängt tieferliegende System- und PowerShell-Abstürze ab
    [System.AppDomain]::CurrentDomain.add_UnhandledException({
        param($sender, $e)
        $ex = $e.ExceptionObject
        $errMsg = "FATAL APP ERROR: $($ex.Message)`n$($ex.StackTrace)"
        Write-FileLog $errMsg
    })
} catch {
    # Ignoriere Fehler, falls die Event-Registrierung in älteren PS-Versionen zickt
}

# First-use safety notice. Persist the flag before showing the dialog so a crash/forced close does
# not trap the user in a repeated prompt loop. The deletion option itself ships disabled.
$form.Add_Shown({
  if (-not $script:settings.CleanupNoticeShown) {
    $script:settings.CleanupNoticeShown = $true
    Save-Settings
    [void]$form.BeginInvoke([System.Action]{
      $answer = [System.Windows.Forms.MessageBox]::Show(
        (Get-UiString 'FirstRunCleanupDialog'),
        (Get-UiString 'FirstRunCleanupTitle'),
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Information)
      if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
        Show-Section 'settings'
        try { $autoRemoveSupersededCheckbox.Focus() } catch {}
      }
    })
  }
})

# A settings file written by an older version could hold both cleanup options at once - the state
# in which the predecessor was deleted although "keep the newest versions" was ticked too.
# Load-Settings has already resolved it; say so once instead of changing a user's choice silently,
# and persist the corrected state so the notice does not return on every start.
$form.Add_Shown({
  if (-not $script:cleanupConflictResolved) { return }
  $script:cleanupConflictResolved = $false
  Save-Settings
  Write-Log 'Cleanup option conflict from the saved settings was resolved and persisted.'
  [void]$form.BeginInvoke([System.Action]{
    [void][System.Windows.Forms.MessageBox]::Show(
      (Get-UiString 'CleanupExclusiveDialog'),
      (Get-UiString 'CleanupExclusiveTitle'),
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Information)
  })
})

# Async update check on startup so it doesn't block the UI – only when a self-update repo
# is configured (see $script:githubRepo). Gated here on the main thread so nothing runs
# and no status noise appears when the feature is unconfigured.
$form.Add_Shown({
  # Apply the native dark/rounded window chrome now that the handle exists (Win11).
  Set-WindowChrome -Form $form -Dark ([bool]$script:currentTheme.Dark)
  if ([string]::IsNullOrWhiteSpace($script:githubRepo)) { return }
  # BeginInvoke so the window paints before the check runs, then synchronously on the UI thread:
  # the former BackgroundWorker route never executed the scriptblock (no runspace on that thread),
  # so the startup check silently reported "up to date" for every version ever shipped.
  [void]$form.BeginInvoke([System.Action]{
    Update-Status (Get-UiString 'UpdCheckingStatus')
    [System.Windows.Forms.Application]::DoEvents()
    Invoke-UpdateCheckFeedback -UpdateResult (Test-AppUpdateAvailable) -Context 'Startup'
  })
})

# Tooltips for main buttons
$toolTip = New-Object System.Windows.Forms.ToolTip
$toolTip.AutoPopDelay = 5000
$toolTip.InitialDelay = 500
$toolTip.ReshowDelay  = 500
$toolTip.ShowAlways   = $true

# Section info badges: attached here because $toolTip only exists now. These texts are long
# (several paragraphs), so this tooltip gets a much larger AutoPopDelay than the button hints.
$toolTipInfo = New-Object System.Windows.Forms.ToolTip
$toolTipInfo.AutoPopDelay = 32767
$toolTipInfo.InitialDelay = 200
$toolTipInfo.ReshowDelay  = 200
$toolTipInfo.ShowAlways   = $true
foreach ($b in $script:infoBadges) {
  try { $toolTipInfo.SetToolTip($b.Badge, (Get-UiString $b.Key)) } catch { Write-LogDebug ("Info tooltip {0}: {1}" -f $b.Key, $_.Exception.Message) }
}

$toolTip.SetToolTip($searchButton,          (Get-UiString 'TtSearchButton'))
# Sits in the superseded card but acts on every managed app - the tooltip spells that out, plus
# the fact that it deletes rather than supersedes.
if ($versionCleanupButton) { $toolTip.SetToolTip($versionCleanupButton, ((Get-UiString 'TtVersionCleanupButton') -f $script:keepVersionCount)) }
$toolTip.SetToolTip($versionsButton,        (Get-UiString 'TtVersionsButton'))
if ($assignTargetCombo) { $toolTip.SetToolTip($assignTargetCombo, (Get-UiString 'TtAssignTarget')) }
if ($assignGroupIdBox)  { $toolTip.SetToolTip($assignGroupIdBox,  (Get-UiString 'TtAssignGroupId')) }
$toolTip.SetToolTip($browseButton,          (Get-UiString 'TtBrowseButton'))
if ($createButton)          { $toolTip.SetToolTip($createButton,          (Get-UiString 'TtCreateButton')) }
if ($uploadButton)          { $toolTip.SetToolTip($uploadButton,          (Get-UiString 'TtUploadButton')) }
if ($favoriteAllLocalButton){ $toolTip.SetToolTip($favoriteAllLocalButton,(Get-UiString 'TtFavoriteAllLocal')) }
if ($updateSearchButton)    { $toolTip.SetToolTip($updateSearchButton,    (Get-UiString 'TtUpdateSearch')) }
if ($updateAllButton)       { $toolTip.SetToolTip($updateAllButton,       (Get-UiString 'TtUpdateAll')) }
if ($updateSelectedButton)  { $toolTip.SetToolTip($updateSelectedButton,  (Get-UiString 'TtUpdateSelected')) }
if ($scanDiscoveredButton)  { $toolTip.SetToolTip($scanDiscoveredButton,  (Get-UiString 'TtScanDiscovered')) }
if ($disconnectButton)      { $toolTip.SetToolTip($disconnectButton,      (Get-UiString 'TooltipDisconnect')) }
if ($logoutButton)          { $toolTip.SetToolTip($logoutButton,          (Get-UiString 'TooltipLogout')) }

# tabOwnPackage
if ($detectMsiButton)    { $toolTip.SetToolTip($detectMsiButton,    (Get-UiString 'TtDetectMsi')) }
if ($win32PackageButton) { $toolTip.SetToolTip($win32PackageButton, (Get-UiString 'TtWin32Package')) }

# Header / Login area
if ($loginButton)           { $toolTip.SetToolTip($loginButton,           (Get-UiString 'TooltipLogin')) }

# tabUpdate
if ($checkAllButton)        { $toolTip.SetToolTip($checkAllButton,        (Get-UiString 'TtCheckAll')) }
if ($uncheckAllButton)      { $toolTip.SetToolTip($uncheckAllButton,      (Get-UiString 'TtUncheckAll')) }
if ($supersededSearchButton){ $toolTip.SetToolTip($supersededSearchButton,(Get-UiString 'TtSupersededSearch')) }
if ($deleteSelectedAppButton){ $toolTip.SetToolTip($deleteSelectedAppButton, (Get-UiString 'TtDeleteSelectedApp')) }
if ($removeOldAppsButton)   { $toolTip.SetToolTip($removeOldAppsButton,   (Get-UiString 'TtRemoveOldApps')) }

# tabDiscovered
if ($deployDiscoveredButton){ $toolTip.SetToolTip($deployDiscoveredButton,(Get-UiString 'TtDeployDiscovered')) }
if ($exportDiscoveredCsvButton){ $toolTip.SetToolTip($exportDiscoveredCsvButton,(Get-UiString 'TtExportCsv')) }
if ($discoveredAssignTargetCombo) { $toolTip.SetToolTip($discoveredAssignTargetCombo, (Get-UiString 'TtAssignTarget')) }
if ($discoveredAssignGroupIdBox)  { $toolTip.SetToolTip($discoveredAssignGroupIdBox,  (Get-UiString 'TtAssignGroupIdMulti')) }
if ($checkAllDiscoveredButton)  { $toolTip.SetToolTip($checkAllDiscoveredButton,   (Get-UiString 'TtCheckAllDiscovered')) }
if ($uncheckAllDiscoveredButton){ $toolTip.SetToolTip($uncheckAllDiscoveredButton, (Get-UiString 'TtUncheckAllDiscovered')) }

# tabSettings
if ($browsePathButton)         { $toolTip.SetToolTip($browsePathButton,         (Get-UiString 'TtBrowsePath')) }
if ($autoCheckUpdatesCheckbox) { $toolTip.SetToolTip($autoCheckUpdatesCheckbox, (Get-UiString 'TtAutoCheckUpdates')) }
if ($autoRemoveSupersededCheckbox) { $toolTip.SetToolTip($autoRemoveSupersededCheckbox, (Get-UiString 'TtAutoRemoveSuperseded')) }
if ($autoVersionCleanupCheckbox) { $toolTip.SetToolTip($autoVersionCleanupCheckbox, (Get-UiString 'TtAutoVersionCleanup')) }
if ($keepVersionCountInput) { $toolTip.SetToolTip($keepVersionCountInput, (Get-UiString 'TtKeepVersionCount')) }
if ($keepVersionCountLabel) { $toolTip.SetToolTip($keepVersionCountLabel, (Get-UiString 'TtKeepVersionCount')) }
if ($languageSelectorCombo) { $toolTip.SetToolTip($languageSelectorCombo, (Get-UiString 'TtLanguageSelector')) }
if ($saveSettingsButton)       { $toolTip.SetToolTip($saveSettingsButton,       (Get-UiString 'TtSaveSettings')) }
if ($clearCacheButton)         { $toolTip.SetToolTip($clearCacheButton,         (Get-UiString 'TtClearCache')) }
if ($checkUpdateButton)        { $toolTip.SetToolTip($checkUpdateButton,        (Get-UiString 'TtCheckUpdate')) }
if ($moveAssignmentsCheckbox)  { $toolTip.SetToolTip($moveAssignmentsCheckbox,  (Get-UiString 'TtMoveAssignments')) }
if ($openLogButton)            { $toolTip.SetToolTip($openLogButton,            (Get-UiString 'TtOpenLogFile')) }
if ($openLogFolderButton)      { $toolTip.SetToolTip($openLogFolderButton,      (Get-UiString 'TtOpenLogFolder')) }



# Compact first-run window size. The explicit bottom-layout routine keeps the log/status area at the
# lower edge and gives resized or maximised windows' extra height to the main content. Skipped when
# the user has a saved size or opens maximized - their choice wins.
try {
  # This is the size that actually reaches the screen: it runs last and overrides the one set while
  # the controls were laid out. 1060 wide because the four dashboard tiles need 748px of content and
  # the sidebar plus window chrome costs 256px - at the previous 1014 the fourth tile was clipped.
  if (-not $script:settings.WindowMaximized -and
      -not ([int]$script:settings.WindowWidth -ge $form.MinimumSize.Width -and [int]$script:settings.WindowHeight -ge $form.MinimumSize.Height)) {
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $form.Size = New-Object System.Drawing.Size([Math]::Min(1060, $wa.Width), [Math]::Min(850, $wa.Height))
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
  }
  Update-BottomLayout
} catch {}

# Favorites are local package work and do not require a tenant login. When explicitly enabled,
# start the batch only after the form is visible so progress and status remain understandable.
$form.Add_Shown({
  if ($script:winTunerModuleImported -and $script:settings.AutoUpdateFavoritesOnStartup -and @($script:settings.WingetFavorites).Count -gt 0) {
    [void]$form.BeginInvoke([System.Action]{ Invoke-FavoritePackagesUpdate -Automatic })
  }
})

# Run the form mit finalem Sicherheitsnetz
if ([string]$script:settings.ProductionWarningAcceptedVersion -ne $script:appVersion) {
  $riskAnswer = [System.Windows.Forms.MessageBox]::Show(
    (Get-UiString 'ProductionWarningDialog'),
    (Get-UiString 'ProductionWarningTitle'),
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Warning,
    [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
  if ($riskAnswer -ne [System.Windows.Forms.DialogResult]::Yes) {
    Write-FileLog "Startup canceled: production-risk warning was not accepted."
    return
  }
  $script:settings.ProductionWarningAcceptedVersion = $script:appVersion
  Save-Settings
}

try {
    [System.Windows.Forms.Application]::Run($form)
} catch {
    # Fängt ab, falls das Skript als Ganzes unerwartet beendet wird
    Write-FileLog "FATAL SCRIPT CRASH: $($_.Exception.Message)`n$($_.ScriptStackTrace)"
}
