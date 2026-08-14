# --- Own installers and in-place content replacement ---
# Everything else in this GUI starts from a WinGet package. These two actions close the two gaps
# that leaves: software that is not in WinGet at all, and updating an app WITHOUT creating a second
# Intune app object next to it.

# Wraps New-IntuneWinPackage. The setup file must live inside the source folder - Intune packages
# a whole directory and records which file inside it starts the install.
# The packager requires the setup file to live INSIDE the source folder - everything in that folder
# is what ends up in the .intunewin, and a setup file outside it simply would not be shipped.
#
# Its own function because the rule now has two callers: the build itself, and the live check in the
# card. Learning the constraint only from a failed build, after picking two folders and pressing the
# button, was the actual complaint - one implementation so the hint can never contradict the guard.
function Test-SetupFileInsideSource {
  param([string]$SourcePath, [string]$SetupFile)
  if ([string]::IsNullOrWhiteSpace($SourcePath) -or [string]::IsNullOrWhiteSpace($SetupFile)) { return $false }
  if (-not (Test-Path -LiteralPath $SourcePath -PathType Container)) { return $false }
  if (-not (Test-Path -LiteralPath $SetupFile -PathType Leaf)) { return $false }
  try {
    # Resolve both sides before comparing: a relative or differently-cased path would otherwise pass
    # a check that Intune later fails on.
    $srcFull = (Resolve-Path -LiteralPath $SourcePath).Path.TrimEnd([char]'\')
    $setupFull = (Resolve-Path -LiteralPath $SetupFile).Path
    return $setupFull.StartsWith($srcFull + '\', [System.StringComparison]::OrdinalIgnoreCase)
  } catch { return $false }
}

function New-OwnIntuneWinPackage {
  param(
    [Parameter(Mandatory)][string]$SourcePath,
    [Parameter(Mandatory)][string]$SetupFile,
    [Parameter(Mandatory)][string]$DestinationPath
  )
  $out = @{ Success = $false; ErrorMessage = $null; PackagePath = $null }
  if (-not (Test-Path -LiteralPath $SourcePath -PathType Container)) {
    $out.ErrorMessage = (Get-UiString 'OwnPkgSourceMissing'); return $out
  }
  if (-not (Test-Path -LiteralPath $SetupFile -PathType Leaf)) {
    $out.ErrorMessage = (Get-UiString 'OwnPkgSetupMissing'); return $out
  }
  if (-not (Test-SetupFileInsideSource -SourcePath $SourcePath -SetupFile $SetupFile)) {
    $out.ErrorMessage = (Get-UiString 'OwnPkgSetupNotInSource'); return $out
  }
  $srcFull = (Resolve-Path -LiteralPath $SourcePath).Path.TrimEnd([char]'\')
  $setupFull = (Resolve-Path -LiteralPath $SetupFile).Path
  try {
    if (-not (Test-Path -LiteralPath $DestinationPath -PathType Container)) {
      New-Item -ItemType Directory -Path $DestinationPath -Force -ErrorAction Stop | Out-Null
    }
    Write-Log ("Packaging own installer: source '{0}', setup '{1}' -> '{2}'" -f $srcFull, (Split-Path $setupFull -Leaf), $DestinationPath)
    New-IntuneWinPackage -SourcePath $srcFull -SetupFile $setupFull -DestinationPath $DestinationPath -ErrorAction Stop | Out-Null
    $built = Get-ChildItem -LiteralPath $DestinationPath -Filter '*.intunewin' -File -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $built) { throw (Get-UiString 'OwnPkgNoArtifact') }
    $out.Success = $true
    $out.PackagePath = $built.FullName
    Write-Log ("Own installer packaged: {0} ({1:n1} MB)" -f $built.FullName, ($built.Length / 1MB))
  } catch {
    $out.ErrorMessage = $_.Exception.Message
    Write-Log ("Packaging own installer FAILED: {0}" -f $out.ErrorMessage)
  }
  return $out
}

# Wraps Deploy-WtWin32ContentVersion: uploads a new content version INTO an existing Intune app.
# The alternative used everywhere else is "create a new app and supersede the old one", which is
# what produced five parallel Firefox objects in the test tenant. Here the app id, its assignments
# and its history stay untouched - only the payload changes.
function Update-ExistingAppContent {
  param(
    [Parameter(Mandatory)][string]$AppId,
    [Parameter(Mandatory)][string]$IntuneWinFile,
    [string]$AppName = ''
  )
  $out = @{ Success = $false; ErrorMessage = $null }
  if (-not (Test-GuidString $AppId)) { $out.ErrorMessage = 'invalid app id'; return $out }
  if (-not (Test-Path -LiteralPath $IntuneWinFile -PathType Leaf)) {
    $out.ErrorMessage = (Get-UiString 'ContentReplaceFileMissing'); return $out
  }
  try {
    Write-Log ("Replacing content of '{0}' ({1}) with '{2}'." -f $AppName, $AppId, $IntuneWinFile)
    Deploy-WtWin32ContentVersion -IntuneWinFile $IntuneWinFile -AppId $AppId -ErrorAction Stop | Out-Null
    $out.Success = $true
    Clear-Win32AppsCache   # the app changed; the next read must not serve the pre-upload state
    Write-Log ("Content replaced for '{0}' ({1})." -f $AppName, $AppId)
  } catch {
    $out.ErrorMessage = $_.Exception.Message
    Write-Log ("Replacing content FAILED for '{0}' ({1}): {2}" -f $AppName, $AppId, $out.ErrorMessage)
  }
  return $out
}

$tabOwnPackage = New-Object System.Windows.Forms.Panel
# Four stacked cards are taller than most windows; without this the lower ones are unreachable.
$tabOwnPackage.AutoScroll = $true

$ownTitle = New-Object System.Windows.Forms.Label
$ownTitle.Text = Get-UiString 'TabOwnPackage'
$ownTitle.Location = New-Object System.Drawing.Point(16, 14)
$ownTitle.AutoSize = $true
$ownTitle.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
$tabOwnPackage.Controls.Add($ownTitle)
[void](Add-SectionInfoBadge -Parent $tabOwnPackage -AfterLabel $ownTitle -TextKey 'InfoOwnPackage')

# --- Card 1: build an .intunewin from any folder ---
$cardOwnBuild = New-Card -X 16 -Y 48 -W 726 -H 268
$tabOwnPackage.Controls.Add($cardOwnBuild)

$ownBuildLabel = New-Object System.Windows.Forms.Label
$ownBuildLabel.Text = Get-UiString 'OwnPkgSectionTitle'
$ownBuildLabel.Location = New-Object System.Drawing.Point(14, 10)
$ownBuildLabel.AutoSize = $true
$ownBuildLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$cardOwnBuild.Controls.Add($ownBuildLabel)

$ownSourceLabel = New-Object System.Windows.Forms.Label
$ownSourceLabel.Text = Get-UiString 'OwnPkgSourceLabel'
$ownSourceLabel.Location = New-Object System.Drawing.Point(14, 46)
$ownSourceLabel.AutoSize = $true
$cardOwnBuild.Controls.Add($ownSourceLabel)

$ownSourceBox = New-Object System.Windows.Forms.TextBox
$ownSourceBox.Width = 400
$ownSourceBox.PlaceholderText = Get-UiString 'OwnPkgSourcePlaceholder'
$ownSourceHost = New-RoundedInput -Inner $ownSourceBox -X 160 -Y 40 -W 400 -H 32
$cardOwnBuild.Controls.Add($ownSourceHost)

$ownSourceButton = New-Object System.Windows.Forms.Button
$ownSourceButton.Tag = 'btn-secondary'
$ownSourceButton.Text = Get-UiString 'BrowsePathButton'
$ownSourceButton.Location = New-Object System.Drawing.Point(572, 40)
$ownSourceButton.Size = New-Object System.Drawing.Size(140, 32)
$cardOwnBuild.Controls.Add($ownSourceButton)

$ownSetupLabel = New-Object System.Windows.Forms.Label
$ownSetupLabel.Text = Get-UiString 'OwnPkgSetupLabel'
$ownSetupLabel.Location = New-Object System.Drawing.Point(14, 86)
$ownSetupLabel.AutoSize = $true
$cardOwnBuild.Controls.Add($ownSetupLabel)

$ownSetupBox = New-Object System.Windows.Forms.TextBox
$ownSetupBox.Width = 400
$ownSetupBox.PlaceholderText = Get-UiString 'OwnPkgSetupPlaceholder'
$ownSetupHost = New-RoundedInput -Inner $ownSetupBox -X 160 -Y 80 -W 400 -H 32
$cardOwnBuild.Controls.Add($ownSetupHost)

$ownSetupButton = New-Object System.Windows.Forms.Button
$ownSetupButton.Tag = 'btn-secondary'
$ownSetupButton.Text = Get-UiString 'BrowsePathButton'
$ownSetupButton.Location = New-Object System.Drawing.Point(572, 80)
$ownSetupButton.Size = New-Object System.Drawing.Size(140, 32)
$cardOwnBuild.Controls.Add($ownSetupButton)

$ownDestLabel = New-Object System.Windows.Forms.Label
$ownDestLabel.Text = Get-UiString 'OwnPkgDestLabel'
$ownDestLabel.Location = New-Object System.Drawing.Point(14, 126)
$ownDestLabel.AutoSize = $true
$cardOwnBuild.Controls.Add($ownDestLabel)

$ownDestBox = New-Object System.Windows.Forms.TextBox
$ownDestBox.Width = 400
$ownDestBox.Text = Get-DefaultPackagePath
$ownDestHost = New-RoundedInput -Inner $ownDestBox -X 160 -Y 120 -W 400 -H 32
$cardOwnBuild.Controls.Add($ownDestHost)

$ownDestButton = New-Object System.Windows.Forms.Button
$ownDestButton.Tag = 'btn-secondary'
$ownDestButton.Text = Get-UiString 'BrowsePathButton'
$ownDestButton.Location = New-Object System.Drawing.Point(572, 120)
$ownDestButton.Size = New-Object System.Drawing.Size(140, 32)
$cardOwnBuild.Controls.Add($ownDestButton)

$ownBuildButton = New-Object System.Windows.Forms.Button
$ownBuildButton.Text = Get-UiString 'OwnPkgBuildButton'
$ownBuildButton.Location = New-Object System.Drawing.Point(14, 166)
$ownBuildButton.Size = New-Object System.Drawing.Size(220, 32)
$cardOwnBuild.Controls.Add($ownBuildButton)

$ownBuildHint = New-Object System.Windows.Forms.Label
$ownBuildHint.Tag = 'hint'
$ownBuildHint.Text = Get-UiString 'OwnPkgHint'
$ownBuildHint.Location = New-Object System.Drawing.Point(14, 204)
$ownBuildHint.Size = New-Object System.Drawing.Size(698, 48)   # two wrapped lines; 32 px clipped the second
$cardOwnBuild.Controls.Add($ownBuildHint)

# --- Card 2: replace the content of an existing Intune app ---
$cardContentReplace = New-Card -X 16 -Y 1128 -W 726 -H 296
$tabOwnPackage.Controls.Add($cardContentReplace)

$replaceLabel = New-Object System.Windows.Forms.Label
$replaceLabel.Text = Get-UiString 'ContentReplaceSectionTitle'
$replaceLabel.Location = New-Object System.Drawing.Point(14, 10)
$replaceLabel.AutoSize = $true
$replaceLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$cardContentReplace.Controls.Add($replaceLabel)
[void](Add-SectionInfoBadge -Parent $cardContentReplace -AfterLabel $replaceLabel -TextKey 'InfoContentReplace')

$replaceAppLabel = New-Object System.Windows.Forms.Label
$replaceAppLabel.Text = Get-UiString 'ContentReplaceAppLabel'
$replaceAppLabel.Location = New-Object System.Drawing.Point(14, 46)
$replaceAppLabel.AutoSize = $true
$cardContentReplace.Controls.Add($replaceAppLabel)

$replaceAppCombo = New-Object System.Windows.Forms.ComboBox
$replaceAppCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$replaceAppCombo.Location = New-Object System.Drawing.Point(160, 42)
$replaceAppCombo.Width = 400
$cardContentReplace.Controls.Add($replaceAppCombo)

$replaceLoadButton = New-Object System.Windows.Forms.Button
$replaceLoadButton.Tag = 'btn-secondary'
$replaceLoadButton.Text = Get-UiString 'ContentReplaceLoadButton'
$replaceLoadButton.Location = New-Object System.Drawing.Point(572, 40)
$replaceLoadButton.Size = New-Object System.Drawing.Size(140, 32)
$cardContentReplace.Controls.Add($replaceLoadButton)

$replaceFileLabel = New-Object System.Windows.Forms.Label
$replaceFileLabel.Text = Get-UiString 'ContentReplaceFileLabel'
$replaceFileLabel.Location = New-Object System.Drawing.Point(14, 86)
$replaceFileLabel.AutoSize = $true
$cardContentReplace.Controls.Add($replaceFileLabel)

$replaceFileBox = New-Object System.Windows.Forms.TextBox
$replaceFileBox.Width = 400
$replaceFileBox.PlaceholderText = Get-UiString 'ContentReplaceFilePlaceholder'
$replaceFileHost = New-RoundedInput -Inner $replaceFileBox -X 160 -Y 80 -W 400 -H 32
$cardContentReplace.Controls.Add($replaceFileHost)

$replaceFileButton = New-Object System.Windows.Forms.Button
$replaceFileButton.Tag = 'btn-secondary'
$replaceFileButton.Text = Get-UiString 'BrowsePathButton'
$replaceFileButton.Location = New-Object System.Drawing.Point(572, 80)
$replaceFileButton.Size = New-Object System.Drawing.Size(140, 32)
$cardContentReplace.Controls.Add($replaceFileButton)

$replaceRunButton = New-Object System.Windows.Forms.Button
$replaceRunButton.Text = Get-UiString 'ContentReplaceRunButton'
$replaceRunButton.Location = New-Object System.Drawing.Point(14, 126)
$replaceRunButton.Size = New-Object System.Drawing.Size(260, 32)
$cardContentReplace.Controls.Add($replaceRunButton)

$replaceHint = New-Object System.Windows.Forms.Label
$replaceHint.Tag = 'hint'
$replaceHint.Text = Get-UiString 'ContentReplaceHint'
$replaceHint.Location = New-Object System.Drawing.Point(14, 166)
$replaceHint.Size = New-Object System.Drawing.Size(698, 108)   # four wrapped lines; 62 px clipped the last
$cardContentReplace.Controls.Add($replaceHint)

$script:contentReplaceApps = @()

$ownSourceButton.Add_Click({
  $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
  $dlg.Description = Get-UiString 'OwnPkgSourceLabel'
  if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $ownSourceBox.Text = $dlg.SelectedPath }
  $dlg.Dispose()
})

$ownSetupButton.Add_Click({
  $dlg = New-Object System.Windows.Forms.OpenFileDialog
  $dlg.Filter = 'Installer (*.exe;*.msi)|*.exe;*.msi|All files (*.*)|*.*'
  if ($ownSourceBox.Text.Trim() -and (Test-Path -LiteralPath $ownSourceBox.Text.Trim())) {
    $dlg.InitialDirectory = $ownSourceBox.Text.Trim()
  }
  if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $ownSetupBox.Text = $dlg.FileName }
  $dlg.Dispose()
})

$ownDestButton.Add_Click({
  $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
  $dlg.Description = Get-UiString 'OwnPkgDestLabel'
  if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $ownDestBox.Text = $dlg.SelectedPath }
  $dlg.Dispose()
})

$ownBuildButton.Add_Click({
  if (Test-UiBusy) { return }
  try {
    $ownBuildButton.Enabled = $false
    Update-Status (Get-UiString 'OwnPkgBuildingStatus')
    [System.Windows.Forms.Application]::DoEvents()  # pumps the message loop; this work stays on the UI thread on purpose (see 70-Runtime)
    $result = New-OwnIntuneWinPackage -SourcePath $ownSourceBox.Text.Trim() -SetupFile $ownSetupBox.Text.Trim() -DestinationPath $ownDestBox.Text.Trim()
    if ($result.ErrorMessage) {
      Update-Status ((Get-UiString 'OwnPkgBuildFailedStatus') -f $result.ErrorMessage)
      return
    }
    Update-Status ((Get-UiString 'OwnPkgBuiltStatus') -f $result.PackagePath)
    # Hand the fresh package straight to the replace card - that is the usual next step.
    $replaceFileBox.Text = [string]$result.PackagePath
  } catch {
    Write-Log ("Own package build error: {0}" -f $_.Exception.Message)
    Update-Status ((Get-UiString 'OwnPkgBuildFailedStatus') -f $_.Exception.Message)
  } finally {
    $ownBuildButton.Enabled = $true
  }
})

$replaceLoadButton.Add_Click({
  if (-not (Test-Connected)) { return }
  if (Test-UiBusy) { return }
  try {
    $replaceLoadButton.Enabled = $false
    Update-Status (Get-UiString 'ContentReplaceLoadingStatus')
    [System.Windows.Forms.Application]::DoEvents()  # pumps the message loop; this work stays on the UI thread on purpose (see 70-Runtime)
    # Only Win32 apps: a content version cannot be pushed into a Store or Office app.
    $script:contentReplaceApps = @(Get-CachedWin32Apps | Sort-Object Name)
    $replaceAppCombo.Items.Clear()
    foreach ($a in $script:contentReplaceApps) {
      [void]$replaceAppCombo.Items.Add(('{0}  ({1})' -f [string]$a.Name, [string]$a.CurrentVersion))
    }
    if ($replaceAppCombo.Items.Count -gt 0) { $replaceAppCombo.SelectedIndex = 0 }
    Update-Status ((Get-UiString 'ContentReplaceLoadedStatus') -f $replaceAppCombo.Items.Count)
  } catch {
    Write-Log ("Loading Win32 apps for content replacement failed: {0}" -f $_.Exception.Message)
    Update-Status ((Get-UiString 'ContentReplaceLoadFailedStatus') -f $_.Exception.Message)
  } finally {
    $replaceLoadButton.Enabled = $true
  }
})

$replaceFileButton.Add_Click({
  $dlg = New-Object System.Windows.Forms.OpenFileDialog
  $dlg.Filter = 'Intune package (*.intunewin)|*.intunewin|All files (*.*)|*.*'
  if ($ownDestBox.Text.Trim() -and (Test-Path -LiteralPath $ownDestBox.Text.Trim())) {
    $dlg.InitialDirectory = $ownDestBox.Text.Trim()
  }
  if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $replaceFileBox.Text = $dlg.FileName }
  $dlg.Dispose()
})

$replaceRunButton.Add_Click({
  if (-not (Test-Connected)) { return }
  if (Test-UiBusy) { return }
  $index = [int]$replaceAppCombo.SelectedIndex
  if ($index -lt 0 -or $index -ge $script:contentReplaceApps.Count) {
    Update-Status (Get-UiString 'ContentReplaceNoApp'); return
  }
  $app = $script:contentReplaceApps[$index]
  $file = $replaceFileBox.Text.Trim()
  if (-not $file) { Update-Status (Get-UiString 'ContentReplaceNoFile'); return }

  $confirm = [System.Windows.Forms.MessageBox]::Show(
    ((Get-UiString 'ContentReplaceConfirm') -f $app.Name, $app.CurrentVersion, (Split-Path $file -Leaf)),
    (Get-UiString 'ConfirmTitle'),
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Warning)
  if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

  try {
    $replaceRunButton.Enabled = $false
    Update-Status ((Get-UiString 'ContentReplaceRunningStatus') -f $app.Name)
    [System.Windows.Forms.Application]::DoEvents()  # pumps the message loop; this work stays on the UI thread on purpose (see 70-Runtime)
    $result = Update-ExistingAppContent -AppId ([string]$app.GraphId) -IntuneWinFile $file -AppName ([string]$app.Name)
    if ($result.ErrorMessage) {
      Update-Status ((Get-UiString 'ContentReplaceFailedStatus') -f $result.ErrorMessage)
    } else {
      Update-Status ((Get-UiString 'ContentReplaceDoneStatus') -f $app.Name)
    }
  } catch {
    Write-Log ("Content replacement error: {0}" -f $_.Exception.Message)
    Update-Status ((Get-UiString 'ContentReplaceFailedStatus') -f $_.Exception.Message)
  } finally {
    $replaceRunButton.Enabled = $true
  }
})

# --- Working out a detection rule ---
# Intune needs to know how to tell "installed" from "not installed". For an MSI that is simply the
# product code. For an EXE there is no such thing, so the practical route is: record the uninstall
# registry before, install, and look at what appeared. That is exactly what an admin would do by
# hand with regedit - just without missing an entry.

$script:detectionSnapshot = $null

# The three places Windows registers uninstall entries. WOW6432Node matters because a 32-bit
# installer on 64-bit Windows lands there, and that is the path the detection rule has to use.
$script:uninstallHives = @(
  'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
  'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
  'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
)

function Get-UninstallSnapshot {
  $entries = @{}
  foreach ($hive in $script:uninstallHives) {
    if (-not (Test-Path -LiteralPath $hive)) { continue }
    foreach ($key in (Get-ChildItem -LiteralPath $hive -ErrorAction SilentlyContinue)) {
      try {
        $props = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
        $entries[$key.PSPath] = [pscustomobject]@{
          RegistryPath    = ($hive + '\' + $key.PSChildName)
          KeyName         = [string]$key.PSChildName
          DisplayName     = [string]$props.DisplayName
          DisplayVersion  = [string]$props.DisplayVersion
          Publisher       = [string]$props.Publisher
          InstallLocation = [string]$props.InstallLocation
        }
      } catch { }   # class 3: an unreadable key must not abort the snapshot
    }
  }
  return $entries
}

# Turns the newly appeared entries into text that can be pasted into an Intune detection rule.
function Format-DetectionSuggestion {
  param([Parameter(Mandatory)][AllowEmptyCollection()][array]$NewEntries)
  if ($NewEntries.Count -eq 0) { return (Get-UiString 'DetectNoChange') }
  $lines = [System.Collections.Generic.List[string]]::new()
  foreach ($e in $NewEntries) {
    $lines.Add('--- {0} ---' -f ([string]$e.DisplayName))
    if ($e.Publisher)       { $lines.Add(('  {0}: {1}' -f (Get-UiString 'DetectPublisher'), $e.Publisher)) }
    if ($e.DisplayVersion)  { $lines.Add(('  {0}: {1}' -f (Get-UiString 'DetectVersion'), $e.DisplayVersion)) }
    if ($e.InstallLocation) { $lines.Add(('  {0}: {1}' -f (Get-UiString 'DetectInstallLocation'), $e.InstallLocation)) }
    $lines.Add('')
    $lines.Add('  ' + (Get-UiString 'DetectRuleHeading'))
    $lines.Add(('    {0}: {1}' -f (Get-UiString 'DetectRuleKeyPath'), $e.RegistryPath))
    $lines.Add(('    {0}: DisplayVersion' -f (Get-UiString 'DetectRuleValueName')))
    if ($e.DisplayVersion) {
      $lines.Add(('    {0}: {1}' -f (Get-UiString 'DetectRuleComparison'), $e.DisplayVersion))
    }
    # A 32-bit installer registers under WOW6432Node; Intune needs that flag set explicitly or the
    # rule silently never matches on 64-bit clients.
    if ($e.RegistryPath -like '*WOW6432Node*') { $lines.Add('    ' + (Get-UiString 'DetectRule32Bit')) }
    $lines.Add('')
  }
  return ($lines -join "`r`n")
}

$cardDetect = New-Card -X 16 -Y 328 -W 726 -H 330
$tabOwnPackage.Controls.Add($cardDetect)

$detectLabel = New-Object System.Windows.Forms.Label
$detectLabel.Text = Get-UiString 'DetectSectionTitle'
$detectLabel.Location = New-Object System.Drawing.Point(14, 10)
$detectLabel.AutoSize = $true
$detectLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$cardDetect.Controls.Add($detectLabel)

$detectStep1Button = New-Object System.Windows.Forms.Button
$detectStep1Button.Tag = 'btn-secondary'
$detectStep1Button.Text = Get-UiString 'DetectSnapshotButton'
$detectStep1Button.Location = New-Object System.Drawing.Point(14, 40)
$detectStep1Button.Size = New-Object System.Drawing.Size(220, 32)
$cardDetect.Controls.Add($detectStep1Button)

$detectStep2Button = New-Object System.Windows.Forms.Button
$detectStep2Button.Tag = 'btn-secondary'
$detectStep2Button.Text = Get-UiString 'DetectInstallButton'
$detectStep2Button.Location = New-Object System.Drawing.Point(246, 40)
$detectStep2Button.Size = New-Object System.Drawing.Size(220, 32)
$detectStep2Button.Enabled = $false
$cardDetect.Controls.Add($detectStep2Button)

$detectStep3Button = New-Object System.Windows.Forms.Button
$detectStep3Button.Text = Get-UiString 'DetectCompareButton'
$detectStep3Button.Location = New-Object System.Drawing.Point(478, 40)
$detectStep3Button.Size = New-Object System.Drawing.Size(234, 32)
$detectStep3Button.Enabled = $false
$cardDetect.Controls.Add($detectStep3Button)

$detectMsiButton = New-Object System.Windows.Forms.Button
$detectMsiButton.Tag = 'btn-secondary'
$detectMsiButton.Text = Get-UiString 'DetectMsiButton'
$detectMsiButton.Location = New-Object System.Drawing.Point(14, 80)
$detectMsiButton.Size = New-Object System.Drawing.Size(220, 32)
$cardDetect.Controls.Add($detectMsiButton)

$detectSandboxButton = New-Object System.Windows.Forms.Button
$detectSandboxButton.Tag = 'btn-secondary'
$detectSandboxButton.Text = Get-UiString 'DetectSandboxButton'
$detectSandboxButton.Location = New-Object System.Drawing.Point(246, 80)
$detectSandboxButton.Size = New-Object System.Drawing.Size(220, 32)
$cardDetect.Controls.Add($detectSandboxButton)

$detectArgsLabel = New-Object System.Windows.Forms.Label
$detectArgsLabel.Text = Get-UiString 'DetectArgsLabel'
$detectArgsLabel.Location = New-Object System.Drawing.Point(478, 87)
$detectArgsLabel.AutoSize = $true
$cardDetect.Controls.Add($detectArgsLabel)

$detectArgsBox = New-Object System.Windows.Forms.TextBox
$detectArgsBox.Width = 150
$detectArgsBox.PlaceholderText = Get-UiString 'DetectArgsPlaceholder'
$detectArgsHost = New-RoundedInput -Inner $detectArgsBox -X 562 -Y 80 -W 150 -H 32
$cardDetect.Controls.Add($detectArgsHost)

$detectResultBox = New-Object System.Windows.Forms.TextBox
$detectResultBox.Multiline = $true
$detectResultBox.ReadOnly = $true
$detectResultBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$detectResultBox.Font = New-Object System.Drawing.Font("Consolas", 9)
$detectResultBox.Location = New-Object System.Drawing.Point(14, 122)
$detectResultBox.Size = New-Object System.Drawing.Size(698, 150)
$cardDetect.Controls.Add($detectResultBox)

$detectHint = New-Object System.Windows.Forms.Label
$detectHint.Tag = 'hint'
$detectHint.Text = Get-UiString 'DetectHint'
$detectHint.Location = New-Object System.Drawing.Point(14, 280)
$detectHint.Size = New-Object System.Drawing.Size(698, 44)
$cardDetect.Controls.Add($detectHint)

$detectStep1Button.Add_Click({
  try {
    Update-Status (Get-UiString 'DetectSnapshotRunning')
    [System.Windows.Forms.Application]::DoEvents()  # pumps the message loop; this work stays on the UI thread on purpose (see 70-Runtime)
    $script:detectionSnapshot = Get-UninstallSnapshot
    $detectResultBox.Text = (Get-UiString 'DetectSnapshotDone') -f $script:detectionSnapshot.Count
    $detectStep2Button.Enabled = $true
    $detectStep3Button.Enabled = $true
    Write-Log ("Detection snapshot taken: {0} uninstall entries." -f $script:detectionSnapshot.Count)
    Update-Status ((Get-UiString 'DetectSnapshotDone') -f $script:detectionSnapshot.Count)
  } catch {
    Write-Log ("Detection snapshot failed: {0}" -f $_.Exception.Message)
    Update-Status ((Get-UiString 'DetectFailed') -f $_.Exception.Message)
  }
})

$detectStep2Button.Add_Click({
  $setup = $ownSetupBox.Text.Trim()
  if (-not $setup -or -not (Test-Path -LiteralPath $setup -PathType Leaf)) {
    Update-Status (Get-UiString 'OwnPkgSetupMissing'); return
  }
  # Runs a real installer on THIS machine. Nothing here is undone automatically, so it is asked
  # for explicitly rather than being a side effect of the snapshot step.
  $confirm = [System.Windows.Forms.MessageBox]::Show(
    ((Get-UiString 'DetectInstallConfirm') -f $setup),
    (Get-UiString 'ConfirmTitle'),
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Warning)
  if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }
  try {
    $detectStep2Button.Enabled = $false
    Update-Status ((Get-UiString 'DetectInstallRunning') -f (Split-Path $setup -Leaf))
    [System.Windows.Forms.Application]::DoEvents()  # pumps the message loop; this work stays on the UI thread on purpose (see 70-Runtime)
    $arguments = $detectArgsBox.Text.Trim()
    Write-Log ("Running installer locally for detection analysis: '{0}' {1}" -f $setup, $arguments)
    if ($arguments) {
      $proc = Start-Process -FilePath $setup -ArgumentList $arguments -Wait -PassThru -ErrorAction Stop
    } else {
      $proc = Start-Process -FilePath $setup -Wait -PassThru -ErrorAction Stop
    }
    Write-Log ("Installer finished with exit code {0}." -f $proc.ExitCode)
    Update-Status ((Get-UiString 'DetectInstallDone') -f $proc.ExitCode)
  } catch {
    Write-Log ("Local installer run failed: {0}" -f $_.Exception.Message)
    Update-Status ((Get-UiString 'DetectFailed') -f $_.Exception.Message)
  } finally {
    $detectStep2Button.Enabled = $true
  }
})

$detectStep3Button.Add_Click({
  if (-not $script:detectionSnapshot) { Update-Status (Get-UiString 'DetectNoSnapshot'); return }
  try {
    Update-Status (Get-UiString 'DetectCompareRunning')
    [System.Windows.Forms.Application]::DoEvents()  # pumps the message loop; this work stays on the UI thread on purpose (see 70-Runtime)
    $after = Get-UninstallSnapshot
    $new = [System.Collections.Generic.List[object]]::new()
    foreach ($k in $after.Keys) {
      if (-not $script:detectionSnapshot.ContainsKey($k)) { $new.Add($after[$k]) }
    }
    # Entries without a display name are components, not the application itself.
    $named = @($new | Where-Object { $_.DisplayName })
    $detectResultBox.Text = Format-DetectionSuggestion -NewEntries $named
    Write-Log ("Detection comparison: {0} new uninstall entr(y/ies), {1} with a display name." -f $new.Count, $named.Count)
    Update-Status ((Get-UiString 'DetectCompareDone') -f $named.Count)
  } catch {
    Write-Log ("Detection comparison failed: {0}" -f $_.Exception.Message)
    Update-Status ((Get-UiString 'DetectFailed') -f $_.Exception.Message)
  }
})

$detectMsiButton.Add_Click({
  $setup = $ownSetupBox.Text.Trim()
  if (-not $setup -or -not (Test-Path -LiteralPath $setup -PathType Leaf)) {
    Update-Status (Get-UiString 'OwnPkgSetupMissing'); return
  }
  if ([IO.Path]::GetExtension($setup) -ne '.msi') { Update-Status (Get-UiString 'DetectNotMsi'); return }
  try {
    Update-Status (Get-UiString 'DetectMsiRunning')
    [System.Windows.Forms.Application]::DoEvents()  # pumps the message loop; this work stays on the UI thread on purpose (see 70-Runtime)
    $info = Show-MsiInfo -MsiPath $setup -ErrorAction Stop
    $detectResultBox.Text = ((Get-UiString 'DetectMsiHeading') + "`r`n`r`n" + (($info | Format-List | Out-String).Trim()))
    Write-Log ("MSI information read for '{0}'." -f $setup)
    Update-Status (Get-UiString 'DetectMsiDone')
  } catch {
    Write-Log ("Reading MSI information failed: {0}" -f $_.Exception.Message)
    Update-Status ((Get-UiString 'DetectFailed') -f $_.Exception.Message)
  }
})

$detectSandboxButton.Add_Click({
  $setup = $ownSetupBox.Text.Trim()
  if (-not $setup -or -not (Test-Path -LiteralPath $setup -PathType Leaf)) {
    Update-Status (Get-UiString 'OwnPkgSetupMissing'); return
  }
  try {
    Update-Status (Get-UiString 'DetectSandboxRunning')
    [System.Windows.Forms.Application]::DoEvents()  # pumps the message loop; this work stays on the UI thread on purpose (see 70-Runtime)
    $arguments = $detectArgsBox.Text.Trim()
    Write-Log ("Testing setup file in Windows Sandbox: '{0}' {1}" -f $setup, $arguments)
    if ($arguments) {
      Test-WtSetupFile -SetupFile $setup -InstallerArguments $arguments -ErrorAction Stop
    } else {
      Test-WtSetupFile -SetupFile $setup -ErrorAction Stop
    }
    Update-Status (Get-UiString 'DetectSandboxStarted')
  } catch {
    Write-Log ("Sandbox test failed: {0}" -f $_.Exception.Message)
    $detectResultBox.Text = (Get-UiString 'DetectSandboxFailed') -f $_.Exception.Message
    Update-Status ((Get-UiString 'DetectFailed') -f $_.Exception.Message)
  }
})


# --- Creating a Win32 app from an own installer ---
# Closes the gap that packaging alone left: an .intunewin file is useless until an Intune app object
# carries the install command and a detection rule. Built on the same two proven pieces as the rest
# of this GUI - a plain Graph POST for the object, then Deploy-WtWin32ContentVersion for the payload.

# Intune wants the registry hive spelled out. The detection card above reports PowerShell drive
# notation (HKLM:\...), which Graph silently never matches.
function Convert-ToGraphRegistryPath {
  param([Parameter(Mandatory)][string]$Path)
  $p = $Path.Trim()
  $map = @{
    'HKLM:\' = 'HKEY_LOCAL_MACHINE\'
    'HKCU:\' = 'HKEY_CURRENT_USER\'
    'HKCR:\' = 'HKEY_CLASSES_ROOT\'
    'HKU:\'  = 'HKEY_USERS\'
  }
  foreach ($k in $map.Keys) {
    if ($p.StartsWith($k, [System.StringComparison]::OrdinalIgnoreCase)) {
      return ($map[$k] + $p.Substring($k.Length))
    }
  }
  return $p
}

# Builds the single detection rule. Intune accepts several; one covers the cases this card offers
# and keeps the rule comprehensible - a wrong detection rule is the classic reason an app installs
# over and over or never reports success.
function New-Win32DetectionRule {
  param(
    [Parameter(Mandatory)][ValidateSet('msi', 'registry', 'file')][string]$Kind,
    [string]$Value1,
    [string]$Value2,
    [string]$Value3,
    [bool]$Is32BitOn64 = $false
  )
  switch ($Kind) {
    'msi' {
      if (-not $Value1) { throw (Get-UiString 'Win32DetectMsiMissing') }
      return @{
        '@odata.type'            = '#microsoft.graph.win32LobAppProductCodeDetection'
        productCode              = $Value1.Trim()
        productVersionOperator   = 'notConfigured'
      }
    }
    'registry' {
      if (-not $Value1) { throw (Get-UiString 'Win32DetectRegistryMissing') }
      $rule = @{
        '@odata.type'         = '#microsoft.graph.win32LobAppRegistryDetection'
        check32BitOn64System  = $Is32BitOn64
        keyPath               = Convert-ToGraphRegistryPath -Path $Value1
        valueName             = $Value2
      }
      if ($Value3) {
        # A version comparison also proves the app is current enough, which a mere "exists" cannot.
        $rule.detectionType  = 'version'
        $rule.operator       = 'greaterThanOrEqual'
        $rule.detectionValue = $Value3.Trim()
      } else {
        # Both branches were 'exists' - the condition read as if it mattered and did nothing.
        # It genuinely does not: Intune documents 'exists' as "the specified registry key OR value
        # exists", and which of the two is checked is decided by valueName being set or empty,
        # not by the detection type.
        $rule.detectionType = 'exists'
        $rule.operator      = 'notConfigured'
      }
      return $rule
    }
    default {
      if (-not $Value1 -or -not $Value2) { throw (Get-UiString 'Win32DetectFileMissing') }
      return @{
        '@odata.type'         = '#microsoft.graph.win32LobAppFileSystemDetection'
        check32BitOn64System  = $Is32BitOn64
        path                  = $Value1.Trim()
        fileOrFolderName      = $Value2.Trim()
        detectionType         = 'exists'
        operator              = 'notConfigured'
      }
    }
  }
}

# Creates the app object. The content is uploaded separately afterwards - Intune needs the object
# to exist before it accepts a content version.
function New-Win32AppViaGraph {
  param(
    [Parameter(Mandatory)][string]$DisplayName,
    [Parameter(Mandatory)][string]$Publisher,
    [string]$Description,
    [Parameter(Mandatory)][string]$InstallCommandLine,
    [Parameter(Mandatory)][string]$UninstallCommandLine,
    [Parameter(Mandatory)][hashtable]$DetectionRule,
    [ValidateSet('system', 'user')][string]$RunAsAccount = 'system',
    [string]$SetupFileName,
    [string]$PackageFileName
  )
  $token = Get-WtToken -ErrorAction Stop
  if ([string]::IsNullOrWhiteSpace([string]$token)) { throw 'WinTuner returned an empty access token.' }
  $headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }

  $body = @{
    '@odata.type'                   = '#microsoft.graph.win32LobApp'
    displayName                     = $DisplayName
    publisher                       = $Publisher
    description                     = $(if ($Description) { $Description } else { $DisplayName })
    installCommandLine              = $InstallCommandLine
    uninstallCommandLine            = $UninstallCommandLine
    applicableArchitectures         = 'x64'
    minimumSupportedWindowsRelease  = '1607'
    setupFilePath                   = $SetupFileName
    fileName                        = $PackageFileName
    installExperience               = @{
      runAsAccount          = $RunAsAccount
      deviceRestartBehavior = 'basedOnReturnCode'
    }
    detectionRules = @($DetectionRule)
    # The Intune defaults. Without them every non-zero exit code counts as a failure, including the
    # reboot codes that a normal installer returns on success.
    returnCodes = @(
      @{ returnCode = 0;    type = 'success' },
      @{ returnCode = 1707; type = 'success' },
      @{ returnCode = 3010; type = 'softReboot' },
      @{ returnCode = 1641; type = 'hardReboot' },
      @{ returnCode = 1618; type = 'retry' }
    )
  }

  $json = $body | ConvertTo-Json -Depth 10
  Write-Log ("Creating Win32 app over Graph: '{0}' ({1}), runAs {2}, detection {3}." -f $DisplayName, $Publisher, $RunAsAccount, $DetectionRule['@odata.type'])
  $created = Invoke-RestMethod -Method POST -Uri 'https://graph.microsoft.com/beta/deviceAppManagement/mobileApps' -Headers $headers -Body $json -ErrorAction Stop
  Clear-Win32AppsCache   # a new app exists; a cached inventory would not contain it
  Write-Log ("Win32 app created: {0}" -f [string]$created.id)
  return $created
}

$cardWin32 = New-Card -X 16 -Y 670 -W 726 -H 446
$tabOwnPackage.Controls.Add($cardWin32)

$win32Label = New-Object System.Windows.Forms.Label
$win32Label.Text = Get-UiString 'Win32SectionTitle'
$win32Label.Location = New-Object System.Drawing.Point(14, 10)
$win32Label.AutoSize = $true
$win32Label.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$cardWin32.Controls.Add($win32Label)

# --- identity ---
$win32NameLabel = New-Object System.Windows.Forms.Label
$win32NameLabel.Text = Get-UiString 'Win32NameLabel'
$win32NameLabel.Location = New-Object System.Drawing.Point(14, 46)
$win32NameLabel.AutoSize = $true
$cardWin32.Controls.Add($win32NameLabel)

$win32NameBox = New-Object System.Windows.Forms.TextBox
$win32NameBox.Width = 250
$win32NameHost = New-RoundedInput -Inner $win32NameBox -X 160 -Y 40 -W 250 -H 32
$cardWin32.Controls.Add($win32NameHost)

$win32PublisherLabel = New-Object System.Windows.Forms.Label
$win32PublisherLabel.Text = Get-UiString 'Win32PublisherLabel'
$win32PublisherLabel.Location = New-Object System.Drawing.Point(424, 46)
$win32PublisherLabel.AutoSize = $true
$cardWin32.Controls.Add($win32PublisherLabel)

$win32PublisherBox = New-Object System.Windows.Forms.TextBox
$win32PublisherBox.Width = 180
$win32PublisherHost = New-RoundedInput -Inner $win32PublisherBox -X 532 -Y 40 -W 180 -H 32
$cardWin32.Controls.Add($win32PublisherHost)

# --- commands ---
$win32InstallLabel = New-Object System.Windows.Forms.Label
$win32InstallLabel.Text = Get-UiString 'Win32InstallLabel'
$win32InstallLabel.Location = New-Object System.Drawing.Point(14, 86)
$win32InstallLabel.AutoSize = $true
$cardWin32.Controls.Add($win32InstallLabel)

$win32InstallBox = New-Object System.Windows.Forms.TextBox
$win32InstallBox.Width = 552
$win32InstallBox.PlaceholderText = Get-UiString 'Win32InstallPlaceholder'
$win32InstallHost = New-RoundedInput -Inner $win32InstallBox -X 160 -Y 80 -W 552 -H 32
$cardWin32.Controls.Add($win32InstallHost)

$win32UninstallLabel = New-Object System.Windows.Forms.Label
$win32UninstallLabel.Text = Get-UiString 'Win32UninstallLabel'
$win32UninstallLabel.Location = New-Object System.Drawing.Point(14, 126)
$win32UninstallLabel.AutoSize = $true
$cardWin32.Controls.Add($win32UninstallLabel)

$win32UninstallBox = New-Object System.Windows.Forms.TextBox
$win32UninstallBox.Width = 552
$win32UninstallBox.PlaceholderText = Get-UiString 'Win32UninstallPlaceholder'
$win32UninstallHost = New-RoundedInput -Inner $win32UninstallBox -X 160 -Y 120 -W 552 -H 32
$cardWin32.Controls.Add($win32UninstallHost)

# --- context ---
$win32ContextLabel = New-Object System.Windows.Forms.Label
$win32ContextLabel.Text = Get-UiString 'Win32ContextLabel'
$win32ContextLabel.Location = New-Object System.Drawing.Point(14, 166)
$win32ContextLabel.AutoSize = $true
$cardWin32.Controls.Add($win32ContextLabel)

$win32ContextCombo = New-Object System.Windows.Forms.ComboBox
$win32ContextCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$win32ContextCombo.Location = New-Object System.Drawing.Point(160, 162)
$win32ContextCombo.Width = 250
[void]$win32ContextCombo.Items.AddRange(@((Get-UiString 'Win32ContextSystem'), (Get-UiString 'Win32ContextUser')))
$win32ContextCombo.SelectedIndex = 0
$cardWin32.Controls.Add($win32ContextCombo)

# --- detection ---
$win32DetectTypeLabel = New-Object System.Windows.Forms.Label
$win32DetectTypeLabel.Text = Get-UiString 'Win32DetectTypeLabel'
$win32DetectTypeLabel.Location = New-Object System.Drawing.Point(14, 206)
$win32DetectTypeLabel.AutoSize = $true
$cardWin32.Controls.Add($win32DetectTypeLabel)

$win32DetectTypeCombo = New-Object System.Windows.Forms.ComboBox
$win32DetectTypeCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$win32DetectTypeCombo.Location = New-Object System.Drawing.Point(160, 202)
$win32DetectTypeCombo.Width = 250
[void]$win32DetectTypeCombo.Items.AddRange(@(
  (Get-UiString 'Win32DetectRegistry'),
  (Get-UiString 'Win32DetectMsi'),
  (Get-UiString 'Win32DetectFile')))
$win32DetectTypeCombo.SelectedIndex = 0
$cardWin32.Controls.Add($win32DetectTypeCombo)

$win32Detect32Check = New-Object System.Windows.Forms.CheckBox
$win32Detect32Check.Text = Get-UiString 'Win32Detect32Bit'
$win32Detect32Check.Location = New-Object System.Drawing.Point(424, 204)
$win32Detect32Check.AutoSize = $true
$cardWin32.Controls.Add($win32Detect32Check)

$win32Field1Label = New-Object System.Windows.Forms.Label
$win32Field1Label.Location = New-Object System.Drawing.Point(14, 246)
$win32Field1Label.AutoSize = $true
$cardWin32.Controls.Add($win32Field1Label)

$win32Field1Box = New-Object System.Windows.Forms.TextBox
$win32Field1Box.Width = 552
$win32Field1Host = New-RoundedInput -Inner $win32Field1Box -X 160 -Y 240 -W 552 -H 32
$cardWin32.Controls.Add($win32Field1Host)

$win32Field2Label = New-Object System.Windows.Forms.Label
$win32Field2Label.Location = New-Object System.Drawing.Point(14, 286)
$win32Field2Label.AutoSize = $true
$cardWin32.Controls.Add($win32Field2Label)

$win32Field2Box = New-Object System.Windows.Forms.TextBox
$win32Field2Box.Width = 250
$win32Field2Host = New-RoundedInput -Inner $win32Field2Box -X 160 -Y 280 -W 250 -H 32
$cardWin32.Controls.Add($win32Field2Host)

$win32Field3Label = New-Object System.Windows.Forms.Label
$win32Field3Label.Location = New-Object System.Drawing.Point(424, 286)
$win32Field3Label.AutoSize = $true
$cardWin32.Controls.Add($win32Field3Label)

$win32Field3Box = New-Object System.Windows.Forms.TextBox
$win32Field3Box.Width = 180
$win32Field3Host = New-RoundedInput -Inner $win32Field3Box -X 532 -Y 280 -W 180 -H 32
$cardWin32.Controls.Add($win32Field3Host)

$win32CreateButton = New-Object System.Windows.Forms.Button
$win32CreateButton.Text = Get-UiString 'Win32CreateButton'
$win32CreateButton.Location = New-Object System.Drawing.Point(14, 326)
$win32CreateButton.Size = New-Object System.Drawing.Size(260, 32)
$cardWin32.Controls.Add($win32CreateButton)

$win32Hint = New-Object System.Windows.Forms.Label
$win32Hint.Tag = 'hint'
$win32Hint.Text = Get-UiString 'Win32Hint'
$win32Hint.Location = New-Object System.Drawing.Point(14, 366)
$win32Hint.Size = New-Object System.Drawing.Size(698, 68)
$cardWin32.Controls.Add($win32Hint)

# The three detection kinds need different inputs; relabelling three fields keeps the card compact
# and avoids three near-identical control groups fighting for space.
function Update-Win32DetectionFields {
  try {
    switch ([int]$win32DetectTypeCombo.SelectedIndex) {
      1 {  # MSI product code
        $win32Field1Label.Text = Get-UiString 'Win32FieldProductCode'
        $win32Field1Box.PlaceholderText = '{12345678-1234-1234-1234-123456789012}'
        $win32Field2Label.Text = ''
        $win32Field3Label.Text = ''
        $win32Field2Host.Visible = $false
        $win32Field3Host.Visible = $false
        $win32Detect32Check.Visible = $false
      }
      2 {  # file or folder
        $win32Field1Label.Text = Get-UiString 'Win32FieldPath'
        $win32Field1Box.PlaceholderText = 'C:\Program Files\Example'
        $win32Field2Label.Text = Get-UiString 'Win32FieldFileName'
        $win32Field3Label.Text = ''
        $win32Field2Host.Visible = $true
        $win32Field3Host.Visible = $false
        $win32Detect32Check.Visible = $true
      }
      default {  # registry
        $win32Field1Label.Text = Get-UiString 'Win32FieldKeyPath'
        $win32Field1Box.PlaceholderText = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Example'
        $win32Field2Label.Text = Get-UiString 'Win32FieldValueName'
        $win32Field3Label.Text = Get-UiString 'Win32FieldVersion'
        $win32Field2Host.Visible = $true
        $win32Field3Host.Visible = $true
        $win32Detect32Check.Visible = $true
      }
    }
  } catch { }   # class 3: relabelling must never block the card
}
$win32DetectTypeCombo.Add_SelectedIndexChanged({ Update-Win32DetectionFields })
Update-Win32DetectionFields

$win32CreateButton.Add_Click({
  if (-not (Test-Connected)) { return }
  if (Test-UiBusy) { return }

  $packageFile = $replaceFileBox.Text.Trim()
  $displayName = $win32NameBox.Text.Trim()
  $publisher = $win32PublisherBox.Text.Trim()
  $installCmd = $win32InstallBox.Text.Trim()
  $uninstallCmd = $win32UninstallBox.Text.Trim()

  if (-not $packageFile -or -not (Test-Path -LiteralPath $packageFile -PathType Leaf)) {
    Update-Status (Get-UiString 'Win32NoPackage'); return
  }
  if (-not $displayName -or -not $publisher) { Update-Status (Get-UiString 'Win32NoIdentity'); return }
  if (-not $installCmd -or -not $uninstallCmd) { Update-Status (Get-UiString 'Win32NoCommands'); return }

  $kind = switch ([int]$win32DetectTypeCombo.SelectedIndex) { 1 { 'msi' }; 2 { 'file' }; default { 'registry' } }
  $rule = $null
  try {
    $rule = New-Win32DetectionRule -Kind $kind -Value1 $win32Field1Box.Text -Value2 $win32Field2Box.Text -Value3 $win32Field3Box.Text -Is32BitOn64 ([bool]$win32Detect32Check.Checked)
  } catch {
    Update-Status ((Get-UiString 'Win32DetectInvalid') -f $_.Exception.Message); return
  }

  $confirm = [System.Windows.Forms.MessageBox]::Show(
    ((Get-UiString 'Win32CreateConfirm') -f $displayName, (Split-Path $packageFile -Leaf)),
    (Get-UiString 'ConfirmTitle'),
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Warning)
  if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

  try {
    $win32CreateButton.Enabled = $false
    Update-Status ((Get-UiString 'Win32CreatingStatus') -f $displayName)
    [System.Windows.Forms.Application]::DoEvents()  # pumps the message loop; this work stays on the UI thread on purpose (see 70-Runtime)

    $runAs = if ([int]$win32ContextCombo.SelectedIndex -eq 1) { 'user' } else { 'system' }
    $setupName = Split-Path $ownSetupBox.Text.Trim() -Leaf
    if (-not $setupName) { $setupName = 'setup.exe' }

    $app = New-Win32AppViaGraph -DisplayName $displayName -Publisher $publisher `
      -InstallCommandLine $installCmd -UninstallCommandLine $uninstallCmd `
      -DetectionRule $rule -RunAsAccount $runAs `
      -SetupFileName $setupName -PackageFileName (Split-Path $packageFile -Leaf)

    $appId = [string]$app.id
    if (-not $appId) { throw (Get-UiString 'Win32NoAppId') }

    # The object exists but is empty until the payload is attached; without this the app would be
    # visible in Intune and fail on every device.
    Update-Status ((Get-UiString 'Win32UploadingStatus') -f $displayName)
    [System.Windows.Forms.Application]::DoEvents()  # pumps the message loop; this work stays on the UI thread on purpose (see 70-Runtime)
    $upload = Update-ExistingAppContent -AppId $appId -IntuneWinFile $packageFile -AppName $displayName
    if ($upload.ErrorMessage) {
      Update-Status ((Get-UiString 'Win32UploadFailed') -f $upload.ErrorMessage)
      [void][System.Windows.Forms.MessageBox]::Show(
        ((Get-UiString 'Win32UploadFailedDialog') -f $displayName, $appId, $upload.ErrorMessage),
        (Get-UiString 'InfoTitle'),
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning)
      return
    }
    Update-Status ((Get-UiString 'Win32CreatedStatus') -f $displayName)
    Write-Log ("Win32 app '{0}' ({1}) created and content uploaded." -f $displayName, $appId)
  } catch {
    Write-Log ("Creating the Win32 app failed: {0}" -f $_.Exception.Message)
    Update-Status ((Get-UiString 'Win32CreateFailed') -f $_.Exception.Message)
  } finally {
    $win32CreateButton.Enabled = $true
  }
})


Add-Section -Key 'ownpackage' -Panel $tabOwnPackage -Label (Get-UiString 'TabOwnPackage')
