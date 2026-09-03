
$dropdown.Add_SelectedIndexChanged({ Update-SelectedPackageVersionLabel })

# Cache for winget searches to speed up repeated searches
# (initialized at script scope; see earlier declaration)

# Session header: the log file is append-only across runs, so without a marker consecutive sessions
# blur together and there is no record of WHICH build/environment produced the lines that follow.
# One banner per start makes support diagnosis (and bug reports) far easier.
try {
  $psVer  = $PSVersionTable.PSVersion.ToString()
  # Gemessen am 31.08.2026: `Get-CimInstance Win32_OperatingSystem` kostete hier 398-425 ms - fuer
  # EINE Protokollzeile, und es war der teuerste Einzelposten des gesamten Startpfads (~5 % von
  # 7,4 s). `[Environment]::OSVersion.VersionString` kostet 0 ms und nennt die Build-Nummer, die
  # einen Support-Fall ohnehin genauer eingrenzt als der Marketingname ("10.0.26200" ist Windows 11,
  # eindeutig). Der naheliegende dritte Weg ist die Registry - und der ist FALSCH: ProductName
  # meldete auf diesem Windows 11 "Windows 10 Enterprise" (bekannte Eigenheit) und kostete trotzdem
  # 78 ms. Ein falscher Betriebssystemname in einem Protokoll, das in Tickets wandert, ist schlimmer
  # als ein unhandlicher richtiger.
  $osVer  = [Environment]::OSVersion.VersionString
  $wtVer  = try { (Get-Module -ListAvailable -Name WinTuner | Sort-Object Version -Descending | Select-Object -First 1).Version.ToString() } catch { 'n/a' }
  Write-Log ("=" * 78)
  Write-Log ("Session start | WinTuner GUI {0} | PowerShell {1} | WinTuner module {2}" -f $script:appVersion, $psVer, $wtVer)
  Write-Log ("Environment   | {0} | user {1} | lang {2} | theme {3}" -f $osVer, $env:USERNAME, $script:uiLanguage, $script:themeName)
  # Die wirksamen Einstellungen gehoeren in DIESES Protokoll: ohne sie ist jede Zeile darunter nur
  # halb lesbar ("warum sucht er beim Anmelden Updates?", "warum fragt er nicht nach?").
  foreach ($line in (Get-SettingsSnapshotLines)) { Write-Log $line }
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

  # Die Befehle sind da - tragen sie auch die Parameter, die diese Anwendung bindet?
  #
  # Gemeldet am 03.09.2026: auf einem Rechner mit deutlich aelterem Modul endete der Klick auf
  # "Suchen" in "A parameter cannot be found that matches parameter name 'SearchQuery'" - als FATAL
  # UI ERROR mit Stapelabbild. Der Befehl existierte, nur der Parameter hiess dort noch anders
  # (bis Modul 1.0.6: -PackageId). Ein solcher Bruch gehoert an den Start, wo er einmal steht und
  # den Namen nennt, nicht in einen Klick, wo er wie ein Absturz aussieht.
  $missingParameters = @(Get-MissingModuleParameters -Required $script:requiredModuleParameters `
    -CommandLookup { param($name) Get-Command $name -ErrorAction SilentlyContinue })
  if ($missingParameters.Count -gt 0) {
    Write-Log ("The installed WinTuner module is missing {0} parameter(s) this application binds: {1}" -f
      $missingParameters.Count, ($missingParameters -join '; '))
    Show-StartupDialog -Text ((Get-UiString 'ModParametersMissingDialog') -f ($missingParameters -join "`r`n")) `
      -Title (Get-UiString 'ModParametersMissingTitle') `
      -Icon ([System.Windows.Forms.MessageBoxIcon]::Warning)
  }

  # The command check above proves the cmdlets exist, not that they still behave the same way.
  # This GUI is written against the WinTuner 1.x surface and deliberately tolerates older 1.x
  # deployments, so no minimum version is enforced. A future 2.x could keep every command name
  # while changing semantics - that must surface at startup rather than halfway through an
  # upload or a cleanup run.
  $winTunerModule = Get-Module WinTuner | Sort-Object Version -Descending | Select-Object -First 1
  # Recorded on every start, not only when something looks wrong. The application's assumptions about
  # this module's parameter semantics are checked by tests/Unit/ModuleContract.Tests.ps1, and when a
  # module update breaks one of them the symptom shows up on a customer tenant - as it did in 0.15.8.
  # Having the exact version in the log is what makes that traceable afterwards.
  if ($winTunerModule) {
    Write-Log ("WinTuner module {0} loaded from {1}." -f $winTunerModule.Version, $winTunerModule.ModuleBase)
  }
  if ($winTunerModule -and $winTunerModule.Version.Major -gt 1) {
    Write-Log ("WinTuner module version {0} is newer than the 1.x line this GUI was written and tested against." -f $winTunerModule.Version)
    Show-StartupDialog -Text ((Get-UiString 'ModVersionUntestedDialog') -f $winTunerModule.Version) `
      -Title (Get-UiString 'ModVersionUntestedTitle') `
      -Icon ([System.Windows.Forms.MessageBoxIcon]::Warning)
  }

  $script:winTunerModuleImported = $true
} catch {
  $errMsg = $_.Exception.Message
  Write-Log "Failed to import WinTuner module: $errMsg"
  # Ueber Show-StartupDialog, nicht direkt: ohne installiertes Modul landet der Start immer hier, und
  # eine MessageBox an dieser Stelle laesst jeden unbeaufsichtigten Lauf haengen (CI von 0.16.0).
  Show-StartupDialog -Text ((Get-UiString 'ModImportFailedDialog') -f $errMsg) `
    -Title (Get-UiString 'ModImportFailedTitle') `
    -Icon ([System.Windows.Forms.MessageBoxIcon]::Error)
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
    # Der Nachweis haengt an DIESER Adresse, auch wenn spaeter getrennt wird (siehe 75-UiState).
    $script:activityTenantUpn = $usernameBox.Text
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

    # Erhoehte Rechte auf Wunsch sofort: EIN zusaetzlicher Anmeldevorgang jetzt statt einer Nachfrage
    # spaeter, mitten in der Arbeit. Nur wenn die Einstellung es sagt; ein Fehlschlag bleibt ohne
    # Folgen (siehe Request-LoginTimeScopes).
    try { [void](Request-LoginTimeScopes) } catch { Write-Log ("Optional scopes at sign-in: {0}" -f $_.Exception.Message) }

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
        # Nobody is watching an automatic trigger, so a message box here would block the whole
        # application until someone walks past. The handler queues the search instead.
        $script:automaticTrigger = $true
        try { $updateSearchButton.PerformClick() } finally { $script:automaticTrigger = $false }
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
  } catch {
    # Ohne diesen Zweig war eine gescheiterte Suche ein FATAL UI ERROR samt Stapelabbild - genau so
    # am 03.09.2026 gemeldet, als ein zu altes Modul den Parameter -SearchQuery nicht kannte. Eine
    # Suche, die nichts findet, ist ein Ergebnis; eine Suche, die scheitert, ist eine Meldung -
    # keins von beidem ist ein Absturz.
    Write-Log ("WinGet package search for '{0}' failed: {1}" -f $appSearchBox.Text, (Format-ErrorDetail -ErrorRecord $_))
    Update-Status ((Get-UiString 'SearchFailedStatus') -f $_.Exception.Message)
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
  if (-not (Test-Path -LiteralPath $folder)) { [void][System.IO.Directory]::CreateDirectory($folder) }
  $filePath  = Join-Path $folder "$packageID.wtpackage"

  if (Test-Path -LiteralPath $filePath) {
    $res = [System.Windows.Forms.MessageBox]::Show(((Get-UiString 'PackageExistsDialog') -f $filePath), (Get-UiString 'ConfirmOverwriteTitle'), [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($res -ne [System.Windows.Forms.DialogResult]::Yes) { Update-Status (Get-UiString 'CreationAbortedStatus'); $uploadButton.Enabled = $true; return }
    try {
      Remove-Item -LiteralPath $filePath -Force -ErrorAction Stop
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
    Show-Progress
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
      # Der Grund stand im Ergebnis und wurde weggeworfen: im Protokoll stand nur
      # "Paketerstellung fehlgeschlagen", ohne ein Wort dazu, warum. Genau diese Zeile war bei
      # KevinOttalini.SimpleMTUTest die einzige Spur.
      $pkgError = if ($resPkg -and $resPkg.ErrorMessage) { [string]$resPkg.ErrorMessage } else { 'unknown package build error' }
      Update-Status ((Get-UiString 'PackageCreationFailedDetailStatus') -f $pkgError)
      Write-Log ("Package creation failed for {0}: {1}" -f $packageID, $pkgError)
    }
  } finally {
    Hide-Progress
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
    if (-not (Test-Path -LiteralPath $folder)) { [void][System.IO.Directory]::CreateDirectory($folder) }

    $uploadSucceeded = $false
    try {
        $uploadButton.Enabled = $false
        $createButton.Enabled = $false

        Update-Status ((Get-UiString 'UploadingStatus') -f $packageID, $version)
        Show-Progress
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
        $deployedApp = Invoke-WtDeployOffThread -Arguments $deploySplat -Label ("{0} {1}" -f $packageID, $version)

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
          # Reports what the call actually achieved: Intune keeps this setting on the assignments, so
          # an app deployed without one is unchanged no matter how well the call succeeded.
          $autoUpdateOutcome = Enable-AppAutoUpdateChecked -AppId $newGraphId -AppName ([string]$packageID)
          if ($autoUpdateOutcome.Problem) {
            $assignmentProblem = if ($assignmentProblem) { "$assignmentProblem; $($autoUpdateOutcome.Problem)" } else { [string]$autoUpdateOutcome.Problem }
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
        Hide-Progress
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
  # Gesperrte Zeilen bleiben aus. "Alle auswaehlen" darf nicht das anhaken, was der Lauf gleich
  # wieder ueberspringen muss - das sieht wie Arbeit aus, die stattfindet, und es findet keine statt.
  $checkedCount = 0
  foreach ($row in $updateListBox.Items) {
    $isBlocked = [bool]($row.Tag -and $row.Tag.PSObject.Properties['IsBlocked'] -and $row.Tag.IsBlocked)
    $row.Checked = -not $isBlocked
    if (-not $isBlocked) { $checkedCount++ }
  }
  Update-Status ((Get-UiString 'AllAppsCheckedStatus') -f $checkedCount)
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
  # Read-only, so it is queued rather than refused: the login-time auto-check used to collide
  # with the start-up favourites build and was thrown away, leaving the technician waiting for a
  # scan that would never run.
  if (Test-UiBusy -DeferKey 'update-search' -DeferLabel (Get-UiString 'DeferLabelUpdateSearch') `
        -DeferAction { $updateSearchButton.PerformClick() }) { return }

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
      # Nach der Ueberlappungspruefung, nicht davor: die unmarkierten Apps werden in
      # Select-UnmanagedWin32Apps schon nach supersedingAppCount getrennt, sie duerfen also nicht
      # noch einmal gegen das Modul-Inventar der abgeloesten Apps gerechnet werden.
      $all = @(Get-ScanInventory -ManagedApps $all)
    } catch {
      # Include the exception TYPE, not just the message: a binding error, a Graph error and a module
      # race read very differently in a bug report, and the type is the fastest way to tell them apart.
      Write-Log ("Failed to load apps [{0}]: {1}" -f $_.Exception.GetType().Name, $_.Exception.Message)
      Update-Status (Get-UiString 'LoadAppsFailedStatus')
      return
    }

    if ($all.Count -eq 0) {
      # "Keine Apps in Intune gefunden" war falsch und hat in die Irre gefuehrt: im Portal STEHEN
      # Apps - nur keine, die WinTuner gebaut hat. Diese Suche kann ausschliesslich Apps mit der
      # '[WinTuner|'-Marke im Notizfeld vergleichen, weil nur die eine WinGet-Paket-Id tragen.
      # Handgebaute Apps (Skripte, Treiber, Store-Apps) gehoeren nach "Alle Tenant-Apps".
      # Ob die Null belastbar ist, hat Get-Win32AppsResilient schon geklaert (zweiter Lesevorgang
      # plus direkte Graph-Gegenprobe) - hier wird sie nur noch richtig benannt.
      $supCount = @($supersededInventory).Count
      # Ist die Suche ueber unmarkierte Apps eingeschaltet, heisst "null" etwas ANDERES: dann wurde
      # der ganze Tenant gelesen, nicht nur die markierten Apps. Die alte Erklaerung ("nur WinTuner-
      # Apps koennen hier stehen") waere hier eine falsche Auskunft.
      if ($script:settings.ScanUnmanagedWin32Apps) {
        Write-Log 'Update scan: this tenant has no active Win32 apps at all - the scan covered every win32LobApp, marked or not. Store, Microsoft 365, Edge and MSI line-of-business apps are a different app type and cannot be packaged or updated by WinTuner.'
        Update-Status (Get-UiString 'NoWin32AppsStatus')
        return
      }
      if (Test-InventoryContradiction -ActiveCount $all.Count -SupersededCount $supCount) {
        Write-Log ("Update scan: no WinTuner-managed active apps, but {0} superseded one(s). The usual cause is that the newer versions were deleted and their predecessors kept the supersedence mark." -f $supCount)
        Update-Status ((Get-UiString 'NoWinTunerAppsSupersededStatus') -f $supCount)
      } else {
        Write-Log 'Update scan: this tenant has no WinTuner-managed apps at all. Only apps carrying the [WinTuner| marker (and therefore a WinGet package id) can be compared here; hand-built apps are listed under "All tenant apps".'
        Update-Status (Get-UiString 'NoWinTunerAppsStatus')
      }
      return
    }

    # 2) Keep every concrete ACTIVE Intune app object. Earlier builds collapsed duplicate product
    # IDs to one version; 0.13.8 keeps active predecessors visible for assignment/cleanup follow-up
    # while already-superseded Graph objects stay exclusively in the superseded-apps section.
    $appsToCheck = @($all | Where-Object { $_ -and $_.CurrentVersion -and $_.GraphId })
    # An app the filter above dropped is an app that will never be compared against anything, and
    # until now nothing said so: the line below reported the ALREADY FILTERED count as "all". That is
    # the shape of the 0.15.8 defect - a candidate that never reached the comparison - so the numbers
    # are made to add up instead.
    $skippedIncomplete = @($all).Count - $appsToCheck.Count
    if ($skippedIncomplete -gt 0) {
      foreach ($bad in @($all | Where-Object { -not ($_ -and $_.CurrentVersion -and $_.GraphId) })) {
        Write-Log ("Update scan SKIPPED an app object without a version or Graph id, so it cannot be compared: name='{0}', version='{1}', graphId='{2}'." -f `
          [string]$bad.Name, [string]$bad.CurrentVersion, [string]$bad.GraphId)
      }
    }
    $resolvedIds = @{}
    $skippedNoWingetId = 0
    foreach ($a in $appsToCheck) {
      try {
        $resolvedIds[[string]$a.GraphId] = [string](Resolve-WingetIdForApp -App $a)
      } catch {
        $resolvedIds[[string]$a.GraphId] = ''
        Write-Log ("Could not resolve a WinGet id for '{0}' ({1}): {2}" -f $a.Name, $a.GraphId, $_.Exception.Message)
      }
      if ([string]::IsNullOrWhiteSpace([string]$resolvedIds[[string]$a.GraphId])) {
        $skippedNoWingetId++
        Write-Log ("Update scan cannot check '{0}' ({1}): no WinGet package id could be resolved, so there is nothing to compare its version against." -f [string]$a.Name, [string]$a.GraphId)
      }
    }
    Write-Log ("Update scan input: {0} app object(s) from the inventory -> {1} checkable, {2} without version/Graph id, {3} without a resolvable WinGet id; already-superseded Graph objects are excluded before this point." -f `
      @($all).Count, $appsToCheck.Count, $skippedIncomplete, $skippedNoWingetId)

    # Fortschritt in Prozent anzeigen. -Cancellable: die Schleife unten fragt den Merker ab. Die
    # Suche schreibt nichts, sie fragt nur Versionen ab - sie darf jederzeit zwischen zwei Apps
    # enden, das Ergebnis der bereits geprueften Apps bleibt gueltig.
    $script:cancelBatch = $false
    Show-Progress -Total ([Math]::Max(1, $appsToCheck.Count)) -Cancellable

    $candidates = [System.Collections.Generic.List[object]]::new()

    # Eine App, die nicht geprueft werden konnte, gehoert IN DIE LISTE - gesperrt und begruendet.
    # Vorher stand sie nur im Protokoll, und im Fenster sah der Tenant damit sauberer aus als er war:
    # "keine Updates gefunden" und "vier Apps konnte ich gar nicht ansehen" sind verschiedene
    # Antworten. Ohne Graph-Id laesst sich nichts anzeigen, worauf ein Klick reagieren koennte -
    # diese bleiben protokollonly.
    foreach ($bad in @($all | Where-Object { $_ -and $_.GraphId -and -not $_.CurrentVersion })) {
      $candidates.Add((New-UpdateCandidateModel -App $bad -LatestVersion '' -PackageId ([string]$bad.PackageId) -BlockedReason (Get-UiString 'UpdateStateNoVersion')))
    }

    $processedCount = 0
    $totalCount = $appsToCheck.Count
    $failedChecks = 0
    $scanCanceled = $false
    $freshByPackageId = @{}

    foreach ($app in $appsToCheck) {
      # Abbruch (Knopf, Trennen, Fensterschluss) wirkt zwischen zwei Apps. Was bis hierher geprueft
      # wurde, wird trotzdem angezeigt - eine halbe Liste ist mehr als keine.
      if ($script:cancelBatch) {
        Write-Log ("Update scan canceled by user after {0} of {1} app(s)." -f $processedCount, $totalCount)
        $scanCanceled = $true
        break
      }
      $processedCount++

      # Update progress every app
      try {
        Set-ProgressValue ($processedCount - 1)
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
            # Vom Benutzer angestossen heisst frisch; die automatische Suche nach der Anmeldung darf
            # die Antworten nehmen, die die Dashboard-Kachel Sekunden vorher schon geholt hat.
            $freshByPackageId[$cacheKey] = Get-FreshLatestPackageVersion -PackageId $wingetId -Force:(-not $script:automaticTrigger)
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
        # Sichtbar statt still: die Zeile ist gesperrt (nicht anhakbar, kein Lauf), nennt den Grund
        # und ist der Ort, an dem der Rechtsklick eine Id zuordnet. Genau diese Apps - Keeper,
        # Harmony SASE, Teams Machine-Wide Installer im Lauf vom 28.08.2026 - waren bisher unsichtbar.
        $candidates.Add((New-UpdateCandidateModel -App $app -LatestVersion '' -BlockedReason (Get-UiString 'UpdateStateNoWingetId')))
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
      # NUR wenn eine Id da war und die Pruefung trotzdem nicht zustande kam. Ohne diese Bedingung
      # wurden die Apps ohne Id ein zweites Mal gezaehlt - einmal als $skippedNoWingetId, einmal hier -
      # und die Bilanz zog sie zweimal ab: im Lauf vom 28.08.2026 stand deshalb "0 up to date +
      # 3 check failed", obwohl Chrome, WebView2 und VS Code geprueft und aktuell waren.
      if ($wingetId -and -not $verified) { $failedChecks++ }
    }
    # 3) Present one target row per PackageId + newest version. Every concrete predecessor remains
    # attached to that row for safe consolidation during the batch.
    # Gesperrte Zeilen sind KEINE Update-Ziele. Sie mitzuzaehlen haette die Bilanz unten wieder
    # verschoben und die Statuszeile Arbeit melden lassen, die es nicht gibt.
    $concreteCandidateCount = @($candidates | Where-Object { -not $_.IsBlocked }).Count
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

    $actionableGroups = @($groupedCandidates | Where-Object { -not $_.IsBlocked })
    $blockedGroups = @($groupedCandidates | Where-Object { $_.IsBlocked })
    $newUploadCount = @($actionableGroups | Where-Object { -not $_.TargetAlreadyDeployed }).Count
    $followUpCount = @($actionableGroups | Where-Object { $_.TargetAlreadyDeployed }).Count
    Write-Log ("Scan classification: {0} new upload(s), {1} follow-up item(s) with an existing target, {2} outdated active source app object(s)." -f $newUploadCount, $followUpCount, $concreteCandidateCount)
    # The reconciliation line: every app object from the inventory is accounted for exactly once.
    # If these do not add up, something was dropped silently - which is the one failure this scan
    # must never have, because a missed app looks exactly like an app that is up to date.
    $reconciliation = Measure-ScanReconciliation -InventoryCount @($all).Count -OutdatedCount $concreteCandidateCount `
      -NoWingetIdCount $skippedNoWingetId -FailedCount $failedChecks -IncompleteCount $skippedIncomplete
    $upToDateCount = $reconciliation.UpToDate
    Set-ProgressValue $processedCount
    Write-Log ("Update scan reconciliation: {0} from inventory = {1} outdated + {2} up to date + {3} no WinGet id + {4} check failed + {5} no version/Graph id." -f `
      @($all).Count, $concreteCandidateCount, $upToDateCount, $skippedNoWingetId, $failedChecks, $skippedIncomplete)
    if (-not $reconciliation.Balanced) {
      Write-Log 'Update scan reconciliation does NOT add up - an app was counted twice. The list above is still complete; the numbers are not.'
    }
    if ($blockedGroups.Count -gt 0) {
      Write-Log ("Update scan: {0} app(s) are shown as blocked rows - they cannot be updated as they stand, but they are visible and can be given a WinGet id by right-clicking the row." -f $blockedGroups.Count)
    }
    if ($skippedIncomplete -gt 0 -or $skippedNoWingetId -gt 0) {
      # Said in the window as well, not only in the log: "no updates found" and "no updates found,
      # but I could not look at four of them" are different answers.
      Write-Log ("Update scan: {0} app(s) could NOT be checked at all. Review the lines above - each one names the app." -f ($skippedIncomplete + $skippedNoWingetId))
    }
    # Nicht mehr an der Zeilenzahl gemessen, sondern an den ANHAKBAREN Zeilen: seit die nicht
    # pruefbaren Apps als gesperrte Zeilen erscheinen, waere "$count > 0" auch dann wahr, wenn es
    # nichts zu tun gibt - und die Statuszeile haette "0 neue Uploads" gemeldet statt "keine
    # Kandidaten, aber 4 Apps nicht pruefbar".
    if ($newUploadCount + $followUpCount -gt 0) {
      if ($failedChecks -gt 0) {
        Update-Status ((Get-UiString 'SearchUpdatesGroupedWithFailuresStatus') -f $newUploadCount, $followUpCount, $concreteCandidateCount, $failedChecks)
      } else {
        Update-Status ((Get-UiString 'SearchUpdatesGroupedStatus') -f $newUploadCount, $followUpCount, $concreteCandidateCount)
      }
      # Enable check/uncheck buttons
      $checkAllButton.Enabled = $true
      $uncheckAllButton.Enabled = $true
    } else {
      # Alles, was gar nicht geprueft werden konnte - egal aus welchem der drei Gruende. Vorher
      # zaehlte hier nur $failedChecks, und ausgerechnet die haeufigsten Faelle (keine Id, keine
      # Version) tauchten in der Statuszeile nicht auf.
      $uncheckableCount = $skippedNoWingetId + $skippedIncomplete + $failedChecks
      if ($uncheckableCount -gt 0) {
        Update-Status ((Get-UiString 'NoUpdateCandidatesWithFailuresStatus') -f $uncheckableCount)
      } else {
        Update-Status (Get-UiString 'NoUpdateCandidatesStatus')
      }
      $checkAllButton.Enabled = $false
      $uncheckAllButton.Enabled = $false
    }
    # The dashboard tile says "Updates available", therefore it counts only targets that still
    # require a new package/upload. Existing-target follow-up remains visible in the detailed list.
    if ($script:dashUpdatesVal) { $script:dashUpdatesVal.Text = [string]$newUploadCount }
    # Steht ZULETZT, damit die Zahlen oben die abgebrochene Suche nicht als vollstaendig ausgeben.
    if ($scanCanceled) { Update-Status (Get-UiString 'ScanCanceledStatus') }
  } finally {
    $script:updateListRefreshing = $false
    $updateSearchButton.Enabled = $true
    # Der Merker gehoert dem Lauf, nicht der Sitzung: sonst wuerde ein Abbruch der Suche noch den
    # naechsten Vorgang stoppen.
    $script:cancelBatch = $false
    Hide-Progress
    if (Get-Command Update-UpdatesEmptyState -ErrorAction SilentlyContinue) { Update-UpdatesEmptyState }
    # Der Versionscache wird EINMAL geschrieben, nicht je Paket (siehe Get-WingetVersions). Im
    # finally, damit auch eine abgebrochene oder gescheiterte Suche das behaelt, was sie schon
    # ermittelt hat - sonst kostet der naechste Lauf dieselben Abfragen noch einmal.
    Save-PendingVersionDiskCache | Out-Null
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

        if ($foundApp -and $foundApp.PSObject.Properties['IsBlocked'] -and $foundApp.IsBlocked) {
            # Der Haken laesst sich an einer ListView-Zeile nicht einzeln abschalten - also faellt die
            # Entscheidung hier. Eine gesperrte Zeile hat keine belastbare Paket-Id oder keine
            # Version; sie zu paketieren hiesse raten, und geraten wird an dieser Stelle nie.
            Write-Log ("Skipping '{0}': the row is blocked ({1}). Nothing was packaged or uploaded for it." -f [string]$foundApp.Name, [string]$foundApp.BlockedReason)
        } elseif ($foundApp) {
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

    # VOR der allgemeinen Rueckfrage: die hier ist die ernstere, und sie ist die einzige, die auch
    # bei abgeschalteten Bestaetigungen kommt. Ohne geschuetzte App kostet sie keinen Klick.
    # Drei moegliche Antworten, nicht zwei: die geschuetzten koennen AUSGELASSEN werden, dann laeuft
    # der Rest. Weitergerechnet wird mit der Liste AUS DEM ERGEBNIS - wer hier weiter $checkedApps
    # nimmt, baut genau die App, die der Benutzer gerade abgewaehlt hat.
    $protectedChoice = Confirm-ProtectedAppsInRun -Apps @($checkedApps)
    if (-not $protectedChoice.Proceed) {
        Update-Status (Get-UiString $(if ($protectedChoice.Reason -eq 'empty') { 'ProtectedRunNothingLeftStatus' } else { 'MassUpdateCanceledStatus' }))
        return
    }
    $checkedApps = @($protectedChoice.Apps)
    if (@($protectedChoice.Skipped).Count -gt 0) {
        Update-Status ((Get-UiString 'ProtectedRunSkippedStatus') -f @($protectedChoice.Skipped).Count, $checkedApps.Count)
    }

    # Confirm before touching the tenant – the selection can be larger than expected (filters,
    # "check all"), and updating apps in Intune is not something to trigger by a stray click.
    $namesPreview = (@($checkedApps | Select-Object -First 15 | ForEach-Object {
      $action = if ($_.TargetAlreadyDeployed) { Get-UiString 'UpdateActionReuse' } else { Get-UiString 'UpdateActionUpload' }
      "- $($_.Name): $($_.CurrentVersion) -> $($_.LatestVersion) [$action]"
    }) -join "`r`n")
    if ($checkedApps.Count -gt 15) { $namesPreview += "`r`n- ..." }
    if (-not (Confirm-ChangeAction `
        -Text ((Get-UiString 'UpdateSelectedConfirmDialog') -f $checkedApps.Count, $namesPreview, (Get-UpdateCleanupNotice)) `
        -Title (Get-UiString 'ConfirmTitle') `
        -LogContext ("update run for {0} selected app(s)" -f $checkedApps.Count))) {
        Update-Status (Get-UiString 'MassUpdateCanceledStatus'); return
    }

    $rootPackageFolder = try { [System.IO.Path]::GetFullPath($pathBox.Text.Trim()) } catch {
      Update-Status ((Get-UiString 'InvalidFolderDialog') -f $pathBox.Text.Trim())
      return
    }
    if (-not (Test-PackageFolderUsable -Folder $rootPackageFolder)) { return }
    if (-not (Test-Path -LiteralPath $rootPackageFolder)) {
        [void][System.IO.Directory]::CreateDirectory($rootPackageFolder)
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

    # Derselbe Riegel wie im Lauf ueber die markierten Zeilen: "Alle aktualisieren" ist genau der
    # Weg, auf dem eine geschuetzte App ungesehen mitlaeuft.
    $protectedChoice = Confirm-ProtectedAppsInRun -Apps @($updatedApps)
    if (-not $protectedChoice.Proceed) {
        Update-Status (Get-UiString $(if ($protectedChoice.Reason -eq 'empty') { 'ProtectedRunNothingLeftStatus' } else { 'MassUpdateCanceledStatus' }))
        return
    }
    $updatedApps = @($protectedChoice.Apps)
    if (@($protectedChoice.Skipped).Count -gt 0) {
        Update-Status ((Get-UiString 'ProtectedRunSkippedStatus') -f @($protectedChoice.Skipped).Count, $updatedApps.Count)
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
    $confirm = if (Confirm-ChangeAction -Text ((Get-UiString 'UpdateConfirmDialog') -f $appNames, (Get-UpdateCleanupNotice)) `
        -Title (Get-UiString 'ConfirmTitle') -LogContext 'update run for all outdated apps') {
      [System.Windows.Forms.DialogResult]::Yes
    } else {
      [System.Windows.Forms.DialogResult]::No
    }

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
    $supersededApps = @(Get-Win32AppsResilient -Superseded -Label 'superseded cleanup')
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
      Show-Progress -Total ([Math]::Max(1, @($supersededApps).Count))
      $removedCount = 0; $keptCount = 0
      $supersededDone = 0
      foreach ($app in @($supersededApps)) {
        Set-ProgressValue $supersededDone
        $supersededDone++
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
          # Stand hier zweimal hintereinander mit identischen Argumenten (und kaputter Einrueckung):
          # zwei Graph-Lesevorgaenge und zwei Schnappschuesse je geloeschter App statt einem.
          $null = Save-AppScopeSnapshot -AppId ([string]$app.GraphId) -AppName ([string]$app.Name) `
            -Version ([string]$app.CurrentVersion) -Reason (Get-UiString 'ScopeSnapshotReasonSuperseded')
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
      Set-ProgressValue $supersededDone
      Update-Status ((Get-UiString 'DeletedAllSupersededStatus') -f $removedCount, $keptCount)
      try { $supersededSearchButton.PerformClick() } catch { Write-LogDebug ("Superseded refresh: {0}" -f $_.Exception.Message) }
    } else {
      Update-Status (Get-UiString 'RemovalAbortedStatus')
    }
  } catch {
    Write-Log "Error loading superseded apps: $($_.Exception.Message)"
    Update-Status ((Get-UiString 'GenericErrorStatus') -f $_.Exception.Message)
  } finally {
    # Ohne dieses finally blieb die Fortschrittsanzeige nach dem Loeschen abgeloester Apps stehen -
    # und weil ihre Sichtbarkeit die Sperre gegen gleichzeitige Vorgaenge IST (Test-OperationRunning),
    # galt die Anwendung anschliessend dauerhaft als beschaeftigt: jeder weitere Klick wurde
    # abgewiesen oder in die Warteschlange gelegt, bis irgendein anderer Vorgang die Anzeige
    # zufaellig ausblendete. Der Fehler stammt aus der Balken-Fassung (dort blieb er auf 100 %
    # stehen) und ist erst durch die neue StaticCheck-Regel aufgefallen.
    Hide-Progress
  }
})

# Handler: Search superseded apps
$script:supersededApps = @()
$supersededSearchButton.Add_Click({
  if (-not (Test-Connected)) { return }
  # Read-only, so queued rather than discarded (see the update search above).
  if (Test-UiBusy -DeferKey 'superseded-search' -DeferLabel (Get-UiString 'DeferLabelSupersededSearch') `
        -DeferAction { $supersededSearchButton.PerformClick() }) { return }
  try {
    Update-Status (Get-UiString 'SearchingSupersededStatus')
    # @() matters here beyond the retry: a tenant with exactly one superseded app used to leave a
    # scalar in a variable that line 1184 indexes and line 1180 tests for emptiness.
    $script:supersededApps = @(Get-Win32AppsResilient -Superseded -Label 'superseded search')
    # Also pull the CURRENT (non-superseded) apps so each old entry can show the version that
    # replaced it – "Chrome — 150.x (current: 151.x)" – instead of a bare old version number.
    $currentByName = @{}
    try {
      foreach ($cur in @(Get-Win32AppsResilient -Label 'superseded search (current versions)')) {
        if ($cur -and $cur.Name) { $currentByName[[string]$cur.Name] = [string]$cur.CurrentVersion }
      }
    } catch { Write-Log "Superseded search: could not load current versions for comparison: $($_.Exception.Message)" }

    $supersededListBox.Items.Clear()
    foreach ($app in @($script:supersededApps)) {
      $name = $app.Name
      $version = $app.CurrentVersion
      $display = "$name — $version"
      $newVer = $currentByName[[string]$name]
      if ($newVer -and $newVer -ne $version) {
        $display += ("  ({0} {1})" -f (Get-UiString 'SupersededCurrentLabel'), $newVer)
      }
      # UNMARKIERT eingetragen. Ein Suchergebnis, das sich selbst zum Loeschen vormarkiert, macht
      # aus einem Blick in den Bestand einen Klick vom Loeschen entfernt.
      [void]$supersededListBox.Items.Add($display, $false)
    }
    Update-SupersededListState
    Update-Status ((Get-UiString 'SupersededSearchCompletedStatus') -f $supersededListBox.Items.Count)
  } catch {
    Write-Log "Superseded search error: $($_.Exception.Message)"
    Update-Status ((Get-UiString 'SupersededSearchErrorStatus') -f $_.Exception.Message)
  }
})




# Handler: Delete selected superseded app
$deleteSelectedAppButton.Add_Click({
  if (-not (Test-Connected)) { return }
  if (Test-UiBusy) { return }
  # Ueber die MARKIERTEN Eintraege, nicht ueber einen ausgewaehlten. Die Indizes werden vorab in
  # eine eigene Liste kopiert: der Lauf loescht in Intune und startet danach die Suche neu, die die
  # Liste leert - ueber CheckedIndices zu iterieren, waehrend sich die Quelle darunter aendert, ist
  # genau das Muster, das an anderer Stelle in diesem Programm "Collection was modified" ergab.
  $checked = @()
  try { foreach ($i in $supersededListBox.CheckedIndices) { $checked += [int]$i } } catch { }
  if (-not $script:supersededApps -or $checked.Count -eq 0) {
    Update-Status (Get-UiString 'SelectSupersededFirstStatus')
    return
  }
  $victims = @()
  foreach ($i in $checked) {
    if ($i -ge 0 -and $i -lt @($script:supersededApps).Count) { $victims += $script:supersededApps[$i] }
  }
  if ($victims.Count -eq 0) { Update-Status (Get-UiString 'SelectSupersededFirstStatus'); return }

  # Namen aller Betroffenen in die Rueckfrage - bei mehr als einer App ist "wirklich loeschen?"
  # ohne die Liste keine Frage, die man beantworten kann.
  $names = ($victims | ForEach-Object { "{0} {1}" -f $_.Name, $_.CurrentVersion }) -join "`r`n"
  $result = [System.Windows.Forms.MessageBox]::Show(
    ((Get-UiString 'RemoveSupersededConfirmDialog') -f $names),
    (Get-UiString 'ConfirmationTitle'),
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Warning,
    [System.Windows.Forms.MessageBoxDefaultButton]::Button2
  )
  if ($result -ne [System.Windows.Forms.DialogResult]::Yes) {
    Update-Status (Get-UiString 'RemovalAbortedStatus')
    return
  }

  $removed = 0; $kept = 0
  foreach ($app in $victims) {
    # Dieselbe Sicherheitspruefung wie bei jeder anderen Loeschung: null Zuweisungen UND null
    # erfolgreiche Installationen, beides bestaetigt - sonst bleibt die Version stehen.
    #
    # Die Ansage davor ist nicht Kosmetik: die beiden Sonden fragen bis zu drei Graph-Endpunkte ab,
    # und wenn die nicht antworten, dauert das mit Zeitueberlaeufen ueber zehn Sekunden. Ohne diese
    # Zeile steht das Fenster still und sieht aus, als haenge es.
    Update-Status ((Get-UiString 'SupersededProbingStatus') -f $app.Name)
    [System.Windows.Forms.Application]::DoEvents()
    $assignmentProbe = Get-AppAssignmentProbe -AppId $app.GraphId -AppName $app.Name
    $installationProbe = Get-AppInstallationProbe -AppId $app.GraphId -AppName $app.Name

    # ZWEI Faelle, die vorher in einer Meldung zusammenfielen ("vorhanden ODER nicht pruefbar").
    # Sie bedeuten voellig Verschiedenes: im einen ist die App noch in Benutzung und alles ist in
    # Ordnung, im anderen hat Intune nicht geantwortet und man weiss schlicht nichts. Wer das nicht
    # unterscheiden kann, weiss nicht, ob er warten oder etwas reparieren muss.
    $stateUnknown = (-not $assignmentProbe.Succeeded) -or (-not $installationProbe.Succeeded)
    $stillInUse = $assignmentProbe.HasAssignments -or $installationProbe.HasInstallations
    if ($stateUnknown -or $stillInUse) {
      $kept++
      if ($stateUnknown) {
        Update-Status ((Get-UiString 'SupersededKeptUnknownStatus') -f $app.Name)
        Write-Log ("Delete superseded: kept {0} {1} ({2}); the state could NOT be established (assignment probe ok={3}, installation probe ok={4}) - an unknown state never authorizes deletion." -f $app.Name, $app.CurrentVersion, $app.GraphId, $assignmentProbe.Succeeded, $installationProbe.Succeeded)
      } else {
        Update-Status ((Get-UiString 'SupersededSafetyKeptStatus') -f $app.Name)
        Write-Log ("Delete superseded: kept {0} {1} ({2}); still in use (assignments={3}, installations={4})." -f $app.Name, $app.CurrentVersion, $app.GraphId, $assignmentProbe.HasAssignments, $installationProbe.HasInstallations)
      }
      [System.Windows.Forms.Application]::DoEvents()
      continue
    }
    try {
      $null = Save-AppScopeSnapshot -AppId ([string]$app.GraphId) -AppName ([string]$app.Name) `
        -Version ([string]$app.CurrentVersion) -Reason (Get-UiString 'ScopeSnapshotReasonSuperseded')
      Invoke-WtRemoveWin32App -AppId $app.GraphId
      Add-SessionActivity -Kind 'SupersededRemoved' -Name ([string]$app.Name) -FromVersion ([string]$app.CurrentVersion)
      $removed++
      Update-Status ((Get-UiString 'DeletedStatus') -f $app.Name)
    } catch {
      $delMsg = $_.Exception.Message
      if ($delMsg -match 'parent of another app' -or $delMsg -match 'Cannot delete this app') {
        $newId = Get-SupersedingAppIdFromError $delMsg
        if ($newId -and (Remove-SupersededByUnlinking -OldAppId $app.GraphId -NewAppId $newId)) {
          $removed++
          Update-Status ((Get-UiString 'DeletedStatus') -f $app.Name)
        } else {
          $kept++
          Write-Log "Delete superseded: kept $($app.Name) - still referenced as the predecessor of a newer version."
          Update-Status ((Get-UiString 'SupersededStillReferencedStatus') -f $app.Name)
        }
      } else {
        $kept++
        Update-Status ((Get-UiString 'ErrorRemovalStatus') -f $delMsg)
      }
    }
    [System.Windows.Forms.Application]::DoEvents()
  }
  Write-Log ("Delete checked superseded apps: {0} removed, {1} kept." -f $removed, $kept)
  Update-Status ((Get-UiString 'SupersededDeleteCheckedDone') -f $removed, $kept)
  # Neu suchen, damit die Liste den Tenant zeigt und nicht den Stand von vor dem Loeschen.
  try { $supersededSearchButton.PerformClick() } catch { Write-LogDebug ("Superseded refresh: {0}" -f $_.Exception.Message) }
})

# --- Lauf stoppen -------------------------------------------------------------------------------
# Der Knopf erscheint nur, wenn Show-Progress -Cancellable gerufen wurde, also nur dort, wo der
# Merker auch abgefragt wird. Er setzt nur den Merker: abgebrochen wird am naechsten sicheren
# Punkt, ein laufender Upload nach Intune wird noch fertig gemacht.
$script:cancelRunButton.Add_Click({
  Request-RunCancel -Reason 'stop button'
  Update-Status (Get-UiString 'CancelRunRequestedStatus')
})

# Trennen und Abmelden mitten in einem Lauf: erst den Lauf stoppen, dann trennen.
#
# Vorher wurde sofort getrennt und der Lauf lief weiter - er paketierte und lud gegen eine Sitzung,
# die es nicht mehr gab. Wer waehrend eines Fehlers auf "Trennen" drueckt, will genau das nicht.
# Die Trennung wird deshalb zurueckgestellt, bis der Lauf am naechsten sicheren Punkt endet;
# Invoke-PendingDeferredActions fuehrt sie danach aus.
function Test-DeferWhileRunning {
  param([Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][scriptblock]$Action, [string]$Label = '')
  if (-not (Test-OperationRunning)) { return $false }
  Request-RunCancel -Reason $Key
  Add-DeferredAction -Key $Key -Action $Action -Label $Label
  Update-Status (Get-UiString 'DisconnectDuringRunStatus')
  return $true
}

function Disconnect-TenantSession {
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
}

$disconnectButton.Add_Click({
  if (Test-DeferWhileRunning -Key 'disconnect' -Action { Disconnect-TenantSession } -Label (Get-UiString 'DisconnectButton')) { return }
  Disconnect-TenantSession
})

function Disconnect-TenantSessionAndForgetTokens {
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
  # Abmelden beendet die Zuordnung des Nachweises; "Trennen" laesst sie absichtlich stehen, damit
  # ein noch laufender Lauf seine Eintraege weiter dem richtigen Kunden zuordnet.
  $script:activityTenantUpn = ""
  if ($loginInfoLabel) { $loginInfoLabel.Text = "" }
  $usernameBox.Text = ""
  Update-Status (Get-UiString 'LogoutSuccessStatus')
  Set-ConnectedUIState -Connected $false
}

$logoutButton.Add_Click({
  if (Test-DeferWhileRunning -Key 'logout' -Action { Disconnect-TenantSessionAndForgetTokens } -Label (Get-UiString 'LogoutButton')) { return }
  Disconnect-TenantSessionAndForgetTokens
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
    if ($discoveredEmptyLabel) {
      Set-ListEmptyText -Label $discoveredEmptyLabel -NormalKey 'DiscoveredEmptyHint'
      $discoveredEmptyLabel.Visible = $empty
    }
    $discoveredListBox.Visible = (-not $empty)
    if ($empty -and $discoveredEmptyLabel) { $discoveredEmptyLabel.BringToFront() }
}

# Toggles the updates list empty-state hint (shown until a scan has populated $script:updateApps).
function Update-UpdatesEmptyState {
  # Show EITHER the hint OR the list – never both: a native list control paints over an overlapping
  # managed label, which previously produced a garbled/mis-placed hint (same fix as Discovered).
  $empty = (@($script:updateApps).Count -eq 0)
  if ($updatesEmptyLabel) {
    Set-ListEmptyText -Label $updatesEmptyLabel -NormalKey 'UpdatesEmptyHint'
    $updatesEmptyLabel.Visible = $empty
    if ($empty) { $updatesEmptyLabel.BringToFront() }
  }
  if ($updateListBox) { $updateListBox.Visible = (-not $empty) }
  # Die Zahl gehoert in den Knopf, nicht in die Ruecksprache: "Alle 47 aktualisieren" wirkt vor dem
  # Klick, eine Rueckfrage erst danach. Ohne Ergebnis bleibt die Beschriftung ohne Zahl.
  if ($updateAllButton) {
    try {
      $count = @($script:updateApps).Count
      $updateAllButton.Text = if ($count -gt 0) {
        (Get-UiString 'UpdateAllButtonCount') -f $count
      } else {
        Get-UiString 'UpdateAllButton'
      }
    } catch { Write-LogDebug 'update-all button label' }
  }
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

    Show-Progress
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
    # The stream redirections that used to sit here (2>$null 3>$null ... 6>$null) did nothing for the
    # case they looked like they covered: -ErrorAction and stream redirection do not suppress an
    # unhandled exception from a binary cmdlet, so the module's race still reached the outer catch.
    # All they achieved was hiding the module's own verbose/warning output - including a genuine
    # permission or throttling warning - from the log.
    $existingApps = @(Get-Win32AppsResilient -Label 'discovered scan (existing apps)')
    $existingPackageIds = [System.Collections.Generic.List[object]]::new()
    foreach ($eApp in $existingApps) {
        [System.Windows.Forms.Application]::DoEvents()  # pumps the message loop; this work stays on the UI thread on purpose (see 70-Runtime)
        # No stream redirections here: Resolve-WtWingetId is our own function and does nothing but
        # read properties off an object, so it cannot write to any stream in the first place.
        $id = Resolve-WtWingetId -AppOrResult $eApp
        if ($id) { $existingPackageIds.Add($id) }
    }

    # 2. Hole ALLE Discovered Apps aus Intune (inklusive Paginierung)
    Update-Status (Get-UiString 'FetchingDetectedStatus')
    [System.Windows.Forms.Application]::DoEvents()  # pumps the message loop; this work stays on the UI thread on purpose (see 70-Runtime)

    # Erst mit dem Token, das die Anwendung ohnehin hat. Antwortet der Tenant mit 403, fehlt genau
    # eine optionale Berechtigung - dann wird sie ANGEBOTEN statt nur gemeldet, und die Abfrage
    # laeuft anschliessend ueber die Graph-PowerShell-Sitzung, die sie traegt.
    $detectedApps = $null
    try {
        $detectedApps = Get-TenantDetectedApps -Headers $discoveredHeaders
    } catch {
        $fetchError = [string]$_.Exception.Message
        if (-not ($fetchError -match '\b403\b' -or $fetchError -match '(?i)forbidden')) { throw }
        Write-Log (Get-UiString 'DiscoveredForbiddenLog')
        Update-Status (Get-UiString 'DiscoveredForbiddenStatus')
        [System.Windows.Forms.Application]::DoEvents()
        if (-not (Connect-OptionalGraphScope -Scope 'DeviceManagementManagedDevices.Read.All' -TextKey 'DiscoveredConsentDialog')) {
            Update-Status (Get-UiString 'DiscoveredForbiddenStatus')
            return
        }
        Update-Status (Get-UiString 'FetchingDetectedStatus')
        [System.Windows.Forms.Application]::DoEvents()
        $detectedApps = Get-TenantDetectedApps -UseGraphSession
    }

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
    Show-Progress -Total $(if ($queryTotal -gt 0) { $queryTotal } else { 1 })

    foreach ($searchName in $uniqueSearchNames) {
        $queryCurrent++
        Set-ProgressValue ($queryCurrent - 1)
        if (($queryCurrent -eq 1) -or ($queryCurrent % 25 -eq 0) -or ($queryCurrent -eq $queryTotal)) {
            Update-Status ((Get-UiString 'QueryingWingetStatus') -f $queryCurrent, $queryTotal, $normalizedApps.Count, $searchName)
            [System.Windows.Forms.Application]::DoEvents()  # pumps the message loop; this work stays on the UI thread on purpose (see 70-Runtime)
        }
        try {
            # The stream redirections stay HERE, deliberately, unlike the one that used to sit on the
            # inventory read above. This runs once per unique search name - hundreds of iterations in
            # a real scan - and the module writes progress and warning output on every call. Without
            # the suppression a single scan buries the log. A failed search is not lost either way:
            # the catch below records it, and an empty result simply means "no WinGet match".
            $searchResultCache[$searchName] = @(Search-WtWinGetPackage -SearchQuery $searchName -ErrorAction SilentlyContinue 2>$null 3>$null 4>$null 5>$null 6>$null)
        } catch {
            $searchResultCache[$searchName] = @()
            Write-Log "Search failed for '$searchName': $($_.Exception.Message)"
        }
    }

    # Phase 2: match normalized discovered apps against cached results
    $processTotal = $normalizedApps.Count
    $processCurrent = 0
    Show-Progress -Total $(if ($processTotal -gt 0) { $processTotal } else { 1 })

    foreach ($entry in $normalizedApps) {
        [System.Windows.Forms.Application]::DoEvents()  # pumps the message loop; this work stays on the UI thread on purpose (see 70-Runtime)
        $processCurrent++
        Set-ProgressValue ($processCurrent - 1)
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
    # 403 ist hier kein Fehler des Werkzeugs, sondern eine fehlende Berechtigung - und zwar eine,
    # die nichts mit Paketieren oder Bereitstellen zu tun hat: die Liste erkannter Apps kommt aus
    # deviceManagement/detectedApps und verlangt DeviceManagementManagedDevices.Read.All. Die rohe
    # Meldung ("Response status code does not indicate success") sagt niemandem, was zu tun ist.
    $discoveredError = [string]$_.Exception.Message
    if ($discoveredError -match '403' -or $discoveredError -match '(?i)forbidden') {
      Update-Status (Get-UiString 'DiscoveredForbiddenStatus')
      Write-Log (Get-UiString 'DiscoveredForbiddenLog')
    } else {
      Update-Status ((Get-UiString 'FetchDiscoveredErrorStatus') -f $discoveredError)
      Write-Log "Scan Discovered Error: $discoveredError"
    }
  } finally {
    $ProgressPreference = $oldProgress
    $InformationPreference = $oldInfo
    $scanDiscoveredButton.Enabled = $true
    Hide-Progress
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
    if (-not (Test-Path -LiteralPath $rootFolder)) { [void][System.IO.Directory]::CreateDirectory($rootFolder) }

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

        Show-Progress -Total ([Math]::Max(1, $checkedItems.Count))

        $successCount = 0
        $failedCount = 0
        $i = 0

        foreach ($item in $checkedItems) {
            $i++
            Set-ProgressValue ($i - 1)
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
                $freshApps = @(Get-Win32AppsResilient -Label 'discovered deploy duplicate guard')
                $alreadyThere = Find-ExistingUpdateTarget -Apps $freshApps -PackageId $packageId -Version $effVersion
                if ($alreadyThere) {
                  throw ("Package {0} {1} already exists in Intune as {2}; duplicate deployment blocked." -f $packageId, $effVersion, $alreadyThere.GraphId)
                }

                Write-Log "Uploading new app to tenant without a temporary assignment: $packageId v$effVersion"
                $discoveredDeploySplat = @{
                    PackageId         = $packageId
                    Version           = $effVersion
                    RootPackageFolder = $rootFolder
                    ErrorAction       = 'Stop'
                }
                $discoveredDeployResult = Invoke-WtDeployOffThread -Arguments $discoveredDeploySplat `
                    -Label ("{0} {1}" -f $packageId, $effVersion)
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
                  # Only a real failure of the call aborts the app. "No assignments yet" is the
                  # NORMAL outcome on this path - apps are uploaded here without a temporary
                  # assignment on purpose (see the log line above) - so it is recorded, not thrown.
                  $autoUpdateOutcome = Enable-AppAutoUpdateChecked -AppId $discoveredGraphId -AppName ([string]$packageId)
                  if ($autoUpdateOutcome.Verdict -eq 'failed') {
                    throw ("The app was uploaded, but auto-update could not be enabled: {0}" -f $autoUpdateOutcome.Problem)
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

        Set-ProgressValue $i
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
        Hide-Progress
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
# Ohne das waeren Eintraege, die nicht in die Hoehe passen, unerreichbar - keine Bildlaufleiste,
# kein Hinweis, einfach weg. Bei acht Eintraegen fiel das nie auf; mit Ueberschriften und einem
# kleinen Fenster schon.
$navFlow.AutoScroll = $true
$navFlow.Tag = 'no-theme'

$navY = 8
# Gruppentitel werden VOR dem ersten Eintrag ihrer Gruppe eingeschoben. Sie sind reine
# Beschriftungen, keine Knoepfe - anklickbar waere irrefuehrend, es gibt keine Gruppenseite.
$navGroupLabels = @{ deploy = (Get-UiString 'NavGroupDeploy'); manage = (Get-UiString 'NavGroupManage'); local = (Get-UiString 'NavGroupLocal') }
$navSeenGroups = @{}
# Gezeichnet wird in GRUPPEN-Reihenfolge, nicht in der Reihenfolge, in der die Sektionen registriert
# wurden. Die haengt davon ab, in welcher Quelldatei ein Bereich gebaut wird - und "Eigene Installer"
# entsteht in 83-, also nach "Alle Tenant-Apps" aus 82-, und landete damit unter der falschen
# Ueberschrift. Innerhalb einer Gruppe bleibt die bisherige Reihenfolge erhalten.
$navGroupOrder = @('start', 'deploy', 'manage', 'local')
# Innerhalb einer Gruppe entschied bisher die Reihenfolge der QUELLDATEIEN, in denen die Bereiche
# gebaut werden - "Alle Tenant-Apps" (Teil 82) stand deshalb vor "Erkannte Apps" (Teil 85), ohne
# dass das jemand so entschieden haette. Diese Liste ist die Entscheidung; wer einen Bereich
# verschieben will, aendert sie, nicht die Dateireihenfolge. Nicht aufgefuehrte Schluessel landen
# hinten (in ihrer Gruppe), damit ein neuer Bereich nie verschwindet.
$navKeyOrder = @('dashboard',
                 'winget', 'store', 'ownpackage',
                 'updates', 'discovered', 'tenant', 'appsettings',
                 'localpackages', 'workrecord', 'customerdata', 'settings')
$navOrdered = @($script:sections | Sort-Object -Stable `
  @{ Expression = {
      $idx = $navGroupOrder.IndexOf([string]$_.Group)
      if ($idx -lt 0) { $navGroupOrder.Count } else { $idx }
    } },
  @{ Expression = {
      $idx = $navKeyOrder.IndexOf([string]$_.Key)
      if ($idx -lt 0) { $navKeyOrder.Count } else { $idx }
    } })
foreach ($s in $navOrdered) {
  $group = [string]$s.Group
  if ($group -and $navGroupLabels.ContainsKey($group) -and -not $navSeenGroups.ContainsKey($group)) {
    $navSeenGroups[$group] = $true
    $navY += 10
    $groupLabel = New-Object System.Windows.Forms.Label
    $groupLabel.Tag = 'no-theme'
    $groupLabel.Text = ([string]$navGroupLabels[$group]).ToUpperInvariant()
    # Gruppentitel stehen auf derselben Spalte wie die Symbole der Eintraege (und wie der Titel in
    # der Kopfzeile) - siehe $script:navContentIndent in 75-UiState.
    $groupLabel.Location = New-Object System.Drawing.Point(($script:navButtonIndent + $script:navButtonTextPad), $navY)
    $groupLabel.Size = New-Object System.Drawing.Size(192, 18)
    $groupLabel.Font = New-Object System.Drawing.Font("Segoe UI", 7.5, [System.Drawing.FontStyle]::Bold)
    $groupLabel.ForeColor = $script:sidebarForeColor
    $groupLabel.BackColor = $script:sidebarBackColor
    $navFlow.Controls.Add($groupLabel)
    $script:navGroupLabelList = @($script:navGroupLabelList) + @($groupLabel)
    $navY += 20
  }
  $btn = New-Object System.Windows.Forms.Button
  $btn.Text = $s.Label
  $btn.Tag = 'no-theme'
  $btn.Location = New-Object System.Drawing.Point($script:navButtonIndent, $navY)
  $btn.Size = New-Object System.Drawing.Size(204, 40)
  $btn.Padding = New-Object System.Windows.Forms.Padding($script:navButtonTextPad, 0, 0, 0)
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
foreach ($b in @($updateSearchButton, $updateSelectedButton, $updateAllButton, $supersededSearchButton, $removeOldAppsButton, $scanDiscoveredButton, $exportDiscoveredCsvButton)) {
  if ($b) { $b.Enabled = $true }
}
# $deleteSelectedAppButton steht bewusst NICHT mehr in der Liste oben: er löscht die markierten
# Einträge der Liste darüber und ist ohne Liste sinnlos. Update-SupersededListState schaltet ihn und
# die zwei Markieren-Knöpfe mit dem Inhalt der Liste, hier einmal für den Leerzustand beim Start.
try { Update-SupersededListState } catch { Write-LogDebug 'initial superseded list state' }
Show-Section 'dashboard'

# Style the log toggle to match the current theme and set its initial label.
$logToggle.BackColor = $script:currentTheme.BackColor
$logToggle.ForeColor = $script:currentTheme.ForeColor
$logToggle.FlatAppearance.MouseOverBackColor = $script:currentTheme.TextBoxBackColor
# Der gespeicherte Zustand, nicht mehr fest aufgeklappt. -SkipSave, weil das Anwenden eines
# gespeicherten Werts kein Speichern auslösen darf - sonst schriebe jeder Start die settings.json.
Set-LogExpanded ([bool]$script:settings.LogExpanded) -SkipSave

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

    # 1a. Den Versionscache nachziehen, falls diese Sitzung etwas ermittelt hat. Er wird waehrend
    #     eines Laufs nur im Speicher gefuehrt (siehe Get-WingetVersions); ohne diese Zeile waere
    #     jede Abfrage, die nach der letzten Schleife dazukam, beim naechsten Start wieder faellig.
    try { Save-PendingVersionDiskCache | Out-Null } catch {}   # class 3: teardown

    # 2. Wenn bereits geschlossen wird, ignorieren
    if ($script:_closingInProgress) { return }
    $script:_closingInProgress = $true

    # 2a. Hintergrund-Runspace fürs Paketieren abräumen, damit kein Thread das Beenden aufhält.
    # Erst den Lauf stoppen, dann den Runspace schliessen - auch wenn es (noch) keinen gibt.
    try { Request-RunCancel -Reason 'window closing' } catch { }   # class 3: teardown
    try {
        if ($script:pkgRunspace) {
            $script:pkgRunspace.Close()
            $script:pkgRunspace.Dispose()
            $script:pkgRunspace = $null
            Write-FileLog 'Shutdown: background packaging runspace closed.'
        }
    } catch { }   # class 3: teardown
    # Seit dem Vorab-Bau gibt es einen zweiten Runspace. Wird er nicht geschlossen, haelt sein
    # Thread das Beenden auf - genau der Grund, aus dem der erste hier steht.
    try { Close-PrebuildRunspace } catch { }   # class 3: teardown
    # Seit 0.18.0 gibt es einen dritten: den fuer den Upload. Gleicher Grund.
    try { Close-DeployRunspace } catch { }   # class 3: teardown

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
  # Unbeaufsichtigt: nichts von hier. Jeder dieser Handler oeffnet ueber BeginInvoke einen MODALEN
  # Dialog, und ein Lauf ohne Benutzer wartet darauf bis zu seinem Zeitablauf. Bisher hielt das nur
  # durch Zufall: der Erstlauf-Hinweis haengt an einer Einstellung, die auf dem Rechner des
  # Entwicklers laengst gesetzt ist - auf einem frischen Profil (jeder CI-Laeufer) ist sie es nicht.
  if (Test-UnattendedRun) { return }
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
# A settings file that could not be parsed leaves the defaults in place, and the first save then
# replaces it. Say so once, and name the copy that was put aside - silently starting over with
# defaults is how a user loses their package path and their group favourites without ever knowing.
$form.Add_Shown({
  # Unbeaufsichtigt: nichts von hier - siehe der erste Add_Shown-Handler oben.
  if (Test-UnattendedRun) { return }
  if (-not $script:settingsCorruptBackupPath) { return }
  $backupPath = [string]$script:settingsCorruptBackupPath
  $script:settingsCorruptBackupPath = $null
  [void]$form.BeginInvoke([System.Action]{
    [void][System.Windows.Forms.MessageBox]::Show(
      ((Get-UiString 'SettingsCorruptDialog') -f $backupPath),
      (Get-UiString 'SettingsCorruptTitle'),
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Warning)
  })
})

# Der einmalige Hinweis auf ein umgezogenes Repository ist ENTFALLEN: die Umbenennung zu
# "Verteilwerk" ist zurueckgenommen, das Repository hiess und heisst zTeck-arch/wintuner_gui. Ein
# Hinweis auf einen Umzug, den es nicht gibt, waere schlimmer als keiner. Der Merker
# RepoMoveNoticeShown bleibt in den Einstellungen liegen und stoert dort nicht.

# Die werksseitig geschuetzten Namen einmal festschreiben. Bewusst OHNE Dialog: das ist kein
# Konflikt, den jemand entscheiden muesste, sondern eine Voreinstellung - und sie steht sichtbar
# unter "Geschuetzte Apps...". Ein Dialog hier waere zudem der vierte im Startpfad.
#
# Ohne Test-UnattendedRun-Ausstieg, weil hier nichts Modales passiert: auch ein Pruef-Lauf darf
# den Merker schreiben, und ohne das Speichern kaeme die Ergaenzung bei jedem Start erneut.
$form.Add_Shown({
  if (@($script:protectedAppsSeeded).Count -eq 0) { return }
  $added = @($script:protectedAppsSeeded)
  $script:protectedAppsSeeded = @()
  Save-Settings
  Write-Log ("Protected apps: {0} factory pattern(s) added ({1}); the app list now holds {2} entr(y/ies). They can be removed under 'Protected apps...' and will not come back." -f `
    $added.Count, ($added -join ', '), @($script:settings.ProtectedApps).Count)
  try { if (Get-Command Update-ProtectedAppsList -ErrorAction SilentlyContinue) { Update-ProtectedAppsList } } catch { Write-LogDebug 'protected apps list after seeding' }
})

$form.Add_Shown({
  # Unbeaufsichtigt: nichts von hier - siehe der erste Add_Shown-Handler oben.
  if (Test-UnattendedRun) { return }
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

# Suche nach Programm-Updates beim Start - nur wenn ein Repository konfiguriert ist UND der Nutzer
# es will. Beides hier auf dem Hauptthread geprueft, damit im abgeschalteten Fall nichts laeuft und
# keine Statusmeldung erscheint.
$form.Add_Shown({
  # Apply the native dark/rounded window chrome now that the handle exists (Win11).
  Set-WindowChrome -Form $form -Dark ([bool]$script:currentTheme.Dark)
  # Die Suche selbst geht ins Netz und ihr Ergebnis endet je nach Fall in einer MessageBox - beides
  # hat in einem Prueflauf nichts zu suchen. Das Fensterchrom oben bleibt, das ist reine Optik.
  if (Test-UnattendedRun) { return }
  if ([string]::IsNullOrWhiteSpace($script:githubRepo)) { return }
  if (-not $script:settings.CheckAppUpdateOnStartup) {
    Write-Log 'Start-up check for a newer version of this tool is switched off in the settings.'
    return
  }
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
# Die Kachel wurde als "Apps mit Update-Bedarf" missverstanden - der Tooltip sagt, was sie zaehlt.
if ($script:dashSupersededVal) { $toolTip.SetToolTip($script:dashSupersededVal, (Get-UiString 'TtDashSuperseded')) }
# Sagt vor dem Klick, was "stoppen" hier heisst - sofort oder erst nach dem laufenden Upload.
if ($script:cancelRunButton) { $toolTip.SetToolTip($script:cancelRunButton, (Get-UiString 'CancelRunTooltip')) }
# Sits in the superseded card but acts on every managed app - the tooltip spells that out, plus
# the fact that it deletes rather than supersedes.
if ($versionCleanupButton) { $toolTip.SetToolTip($versionCleanupButton, ((Get-UiString 'TtVersionCleanupButton') -f $script:keepVersionCount)) }
$toolTip.SetToolTip($versionsButton,        (Get-UiString 'TtVersionsButton'))
if ($assignTargetCombo) { $toolTip.SetToolTip($assignTargetCombo, (Get-UiString 'TtAssignTarget')) }
if ($assignGroupIdBox)  { $toolTip.SetToolTip($assignGroupIdBox,  (Get-UiString 'TtAssignGroupId')) }
# Die drei Favoriten-Knoepfe erklaeren sich nicht von selbst - und sie sind der einzige Ort, an dem
# Gruppen-Favoriten eines Kunden gepflegt werden.
foreach ($favBtn in @($assignFavButton, $storeAssignFavButton, $discoveredAssignFavButton)) {
  if ($favBtn) { $toolTip.SetToolTip($favBtn, (Get-UiString 'TtFavAdd')) }
}
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
if ($detectAutoButton)   { $toolTip.SetToolTip($detectAutoButton,   (Get-UiString 'TtDetectAuto')) }
# The card's hint stays short enough to fit its box; the full explanation of why a rule needs the
# installer and not the package lives here, where length costs nothing.
if ($detectHint)         { $toolTip.SetToolTip($detectHint,         (Get-UiString 'DetectHintTooltip')) }
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
if ($localInstallButton)       { $toolTip.SetToolTip($localInstallButton,       (Get-UiString 'TtLocalInstall')) }
if ($autoCheckUpdatesCheckbox) { $toolTip.SetToolTip($autoCheckUpdatesCheckbox, (Get-UiString 'TtAutoCheckUpdates')) }
if ($autoRemoveSupersededCheckbox) { $toolTip.SetToolTip($autoRemoveSupersededCheckbox, (Get-UiString 'TtAutoRemoveSuperseded')) }
if ($autoVersionCleanupCheckbox) { $toolTip.SetToolTip($autoVersionCleanupCheckbox, (Get-UiString 'TtAutoVersionCleanup')) }
if ($keepVersionCountInput) { $toolTip.SetToolTip($keepVersionCountInput, (Get-UiString 'TtKeepVersionCount')) }
if ($keepVersionCountLabel) { $toolTip.SetToolTip($keepVersionCountLabel, (Get-UiString 'TtKeepVersionCount')) }
if ($languageSelectorCombo) { $toolTip.SetToolTip($languageSelectorCombo, (Get-UiString 'TtLanguageSelector')) }
if ($saveSettingsButton)       { $toolTip.SetToolTip($saveSettingsButton,       (Get-UiString 'TtSaveSettings')) }
if ($clearCacheButton)         { $toolTip.SetToolTip($clearCacheButton,         (Get-UiString 'TtClearCache')) }
# Der Nachbarknopf in derselben Reihe hatte seinen Text seit jeher, aber niemand haengte ihn an -
# gefunden bei der Durchsicht der "toten" Sprachschluessel: TtPrunePackages galt als unbenutzt,
# weil der Knopf ihn nie las. Von den 38 gemeldeten Schluesseln war genau dieser kein toter Text,
# sondern eine fehlende Verdrahtung. Und gerade hier zaehlt der Hinweis: der Knopf loescht Dateien.
if ($prunePackagesButton)      { $toolTip.SetToolTip($prunePackagesButton,      (Get-UiString 'TtPrunePackages')) }
if ($checkUpdateButton)        { $toolTip.SetToolTip($checkUpdateButton,        (Get-UiString 'TtCheckUpdate')) }
if ($moveAssignmentsCheckbox)  { $toolTip.SetToolTip($moveAssignmentsCheckbox,  (Get-UiString 'TtMoveAssignments')) }
if ($openLogButton)            { $toolTip.SetToolTip($openLogButton,            (Get-UiString 'TtOpenLogFile')) }
if ($openLogFolderButton)      { $toolTip.SetToolTip($openLogFolderButton,      (Get-UiString 'TtOpenLogFolder')) }

# Stack the settings rows now that every control has its final (themed) font: the number of lines a
# wrapped explanation needs is only known then, and each card is sized to what it actually holds.
# Kopfzeile und Einstellungsseite messen sich an ihren Beschriftungen - beides erst, wenn das
# Design seine Schriftart gesetzt hat, sonst wird mit der falschen Schrift gerechnet.
try { Update-InfoBadgePositions } catch { Write-LogDebug 'initial info badge positions' }
try { Update-HeaderLayout } catch { Write-LogDebug 'initial header layout' }
try { Update-OwnPackageLayout } catch { Write-LogDebug 'initial own-package layout' }
try { Update-SettingsLayout } catch { Write-LogDebug 'initial settings layout' }



# Compact first-run window size. The explicit bottom-layout routine keeps the log/status area at the
# lower edge and gives resized or maximised windows' extra height to the main content. Skipped when
# the user has a saved size or opens maximized - their choice wins.
try {
  # This is the size that actually reaches the screen: it runs last and overrides the one set while
  # the controls were laid out. 1060 wide because the four dashboard tiles need 748px of content and
  # the sidebar plus window chrome costs 256px - at the previous 1014 the fourth tile was clipped.
  if (-not $script:settings.WindowMaximized) {
    # Groesse UND Lage aus der Arbeitsflaeche, nicht aus der Bildschirmflaeche.
    #
    # Vorher: Groesse auf die Arbeitsflaeche begrenzt, Lage aber ueber CenterScreen - und das
    # zentriert im GESAMTEN Bildschirm, Taskleiste eingerechnet. Ein 850 px hohes Fenster auf einem
    # Schirm mit hoher Skalierung landete damit unter der Taskleiste: die unterste Zeile
    # (Statuszeile, Protokoll-Umschalter) war verdeckt. Eine gespeicherte Groesse bekam ueberhaupt
    # keine Lage zugewiesen und blieb bei Windows' Vorgabe.
    #
    # Jetzt wird in der Arbeitsflaeche zentriert (die schliesst die Taskleiste aus, egal an welcher
    # Kante sie klebt) und die Groesse zusaetzlich um 8 px Luft je Achse begrenzt.
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    # Die Rechnung liegt in Get-InitialWindowSize (75-UiState) - dort ist sie pruefbar.
    $placement = Get-InitialWindowSize -WorkWidth $wa.Width -WorkHeight $wa.Height `
      -SavedWidth ([int]$script:settings.WindowWidth) -SavedHeight ([int]$script:settings.WindowHeight) `
      -MinWidth $form.MinimumSize.Width -MinHeight $form.MinimumSize.Height
    $hasSaved = ($placement.Source -eq 'settings')
    $w = [int]$placement.Width
    $h = [int]$placement.Height
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $form.Size = New-Object System.Drawing.Size($w, $h)
    $form.Location = New-Object System.Drawing.Point(
      ($wa.X + [Math]::Max(0, [int](($wa.Width - $w) / 2))),
      ($wa.Y + [Math]::Max(0, [int](($wa.Height - $h) / 2))))
    Write-Log ("Window placement: {0}x{1} at {2},{3} inside working area {4}x{5} at {6},{7} ({8})" -f `
      $w, $h, $form.Left, $form.Top, $wa.Width, $wa.Height, $wa.X, $wa.Y,
      $(if ($hasSaved) { 'restored from settings' } else { 'first run: 80 percent of the working area' }))
  }
  Update-BottomLayout
} catch {}

# Favorites are local package work and do not require a tenant login. When explicitly enabled,
# start the batch only after the form is visible so progress and status remain understandable.
$form.Add_Shown({
  # Kein Paketbau in einem Prueflauf: der laedt herunter, schreibt Pakete und kann in einer
  # Rueckfrage enden.
  if (Test-UnattendedRun) { return }
  if ($script:winTunerModuleImported -and $script:settings.AutoUpdateFavoritesOnStartup -and @($script:settings.WingetFavorites).Count -gt 0) {
    [void]$form.BeginInvoke([System.Action]{ Invoke-FavoritePackagesUpdate -Automatic })
  }
})

# Drains the deferred-action queue.
#
# There is no "operation finished" event to hook: the busy state is derived from the progress bar
# and the packaging flag, so the only way to notice the end of an operation is to look. A timer is
# the right tool here - it ticks on the UI thread, which is exactly where a queued action has to
# run, and Invoke-PendingDeferredActions is a no-op while anything is still running.
#
# 750 ms: fast enough that a queued update search starts right after the favourites build finishes,
# slow enough to be free when the queue is empty (the common case).
$deferredActionTimer = New-Object System.Windows.Forms.Timer
$deferredActionTimer.Interval = 750
$deferredActionTimer.Add_Tick({ Invoke-PendingDeferredActions })
$deferredActionTimer.Start()

# Smoke gate: stop here, before any modal dialog and before the message loop, when the build is
# being verified rather than used.
#
# Until this existed, nothing in the whole chain ever RAN the assembled script - the parser was the
# last word. A bundle could therefore be accepted while failing at load time: a part in the wrong
# order, a $script: variable read before its assignment, a control referenced before it is built.
# None of that is visible to a parser, and all of it is fatal on a user's machine.
#
# Reaching this line means every part loaded, every control was constructed and every top-level
# statement ran. The marker is what tests/SmokeTest.ps1 looks for. Gated on an environment variable
# no user would have set, and placed BEFORE the production-risk dialog so a headless run cannot hang
# on a message box waiting for a click.
if ($env:WINTUNER_SMOKE -eq '1') {
  Write-Host ("WINTUNER_SMOKE_OK version={0}" -f $script:appVersion)
  # Exit rather than return: this is the top level of the shipped single file, and a return here
  # would fall through to the message loop below.
  exit 0
}

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
