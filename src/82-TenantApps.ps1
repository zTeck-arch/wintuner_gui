# --- Section: every app in the tenant ---
# The other sections deliberately look at WinGet-manageable apps only. This one lists the tenant
# EXACTLY as Intune holds it - every @odata.type, including apps this GUI can never package - so
# assignments can be reviewed and changed in one place instead of switching to the portal.

# Turns "#microsoft.graph.win32LobApp" into something readable. Unknown types keep their raw name
# rather than being hidden: an app the GUI does not understand must still be visible here.
function Get-MobileAppTypeLabel {
  param([string]$ODataType)
  $bare = ([string]$ODataType).TrimStart([char]'#') -replace '^microsoft\.graph\.', ''
  switch -Regex ($bare) {
    '^win32LobApp$'                 { return 'Win32' }
    '^winGetApp$'                   { return 'Store (WinGet)' }
    '^windowsMobileMSI$'            { return 'MSI' }
    '^windowsUniversalAppX'         { return 'UWP / MSIX' }
    '^officeSuiteApp$'              { return 'Microsoft 365 Apps' }
    '^windowsWebApp$|^webApp$'      { return 'Web link' }
    '^windowsStoreApp$'             { return 'Store (legacy)' }
    '^windowsAppX'                  { return 'AppX' }
    default                         { return $bare }
  }
}

# Reads the whole mobileApps collection. Get-TenantStoreApps filters this down to winGetApp; here
# every type is kept, which is the entire point of the section.
function Get-TenantAllApps {
  $token = Get-WtToken -ErrorAction Stop
  if ([string]::IsNullOrWhiteSpace([string]$token)) { throw 'WinTuner returned an empty access token.' }
  $headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
  $uri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?`$top=100"
  $raw = @(Get-GraphCollectionItems -Uri $uri -Headers $headers)
  $result = [System.Collections.Generic.List[object]]::new()
  foreach ($app in $raw) {
    if (-not $app -or -not $app.id) { continue }
    $result.Add([pscustomobject]@{
      Id          = [string]$app.id
      DisplayName = [string]$app.displayName
      TypeLabel   = Get-MobileAppTypeLabel ([string]$app.'@odata.type')
      Version     = [string]$app.displayVersion
      Publisher   = [string]$app.publisher
      IsAssigned  = [bool]$app.isAssigned
    })
  }
  return @($result.ToArray() | Sort-Object DisplayName)
}

# Human-readable assignment list for one app. Kept separate from Get-AppAssignmentProbe, which only
# answers the yes/no question the cleanup logic needs.
function Get-TenantAppAssignmentText {
  param([Parameter(Mandatory)][string]$AppId)
  $token = Get-WtToken -ErrorAction Stop
  $headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
  $uri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$AppId/assignments"
  $items = @(Get-GraphCollectionItems -Uri $uri -Headers $headers)
  if ($items.Count -eq 0) { return (Get-UiString 'TenantAppNoAssignments') }
  $lines = [System.Collections.Generic.List[string]]::new()
  foreach ($a in $items) {
    $targetType = ([string]$a.target.'@odata.type').TrimStart([char]'#') -replace '^microsoft\.graph\.', ''
    $scope = switch -Regex ($targetType) {
      'allDevicesAssignmentTarget'       { 'All devices' }
      'allLicensedUsersAssignmentTarget' { 'All users' }
      'exclusionGroupAssignmentTarget'   { 'Excluded group {0}' -f [string]$a.target.groupId }
      'groupAssignmentTarget'            { 'Group {0}' -f [string]$a.target.groupId }
      default                            { $targetType }
    }
    $filterId = [string]$a.target.deviceAndAppManagementAssignmentFilterId
    $filterType = [string]$a.target.deviceAndAppManagementAssignmentFilterType
    $filterText = if ($filterId -and $filterType -and $filterType -ne 'none') { " | filter: $filterType $filterId" } else { '' }
    $lines.Add(('{0,-10} {1}{2}' -f [string]$a.intent, $scope, $filterText))
  }
  return ($lines -join "`r`n")
}

$tabTenant = New-Object System.Windows.Forms.Panel
# The card is tall; a short window would otherwise cut off the buttons at its bottom.
$tabTenant.AutoScroll = $true

$tenantTitle = New-Object System.Windows.Forms.Label
$tenantTitle.Text = Get-UiString 'TabTenantApps'
$tenantTitle.Location = New-Object System.Drawing.Point(16, 14)
$tenantTitle.AutoSize = $true
$tenantTitle.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
$tabTenant.Controls.Add($tenantTitle)
[void](Add-SectionInfoBadge -Parent $tabTenant -AfterLabel $tenantTitle -TextKey 'InfoTenantApps')

$cardTenant = New-Card -X 16 -Y 48 -W 726 -H 604
$tabTenant.Controls.Add($cardTenant)

$tenantLoadButton = New-Object System.Windows.Forms.Button
$tenantLoadButton.Text = Get-UiString 'TenantAppsLoadButton'
$tenantLoadButton.Location = New-Object System.Drawing.Point(14, 14)
$tenantLoadButton.Size = New-Object System.Drawing.Size(200, 32)
$cardTenant.Controls.Add($tenantLoadButton)

$tenantFilterLabel = New-Object System.Windows.Forms.Label
$tenantFilterLabel.Text = Get-UiString 'UpdateFilterLabel'
$tenantFilterLabel.Location = New-Object System.Drawing.Point(228, 21)
$tenantFilterLabel.AutoSize = $true
$cardTenant.Controls.Add($tenantFilterLabel)

$tenantFilterBox = New-Object System.Windows.Forms.TextBox
$tenantFilterBox.Width = 424
$tenantFilterBox.PlaceholderText = Get-UiString 'UpdateFilterPlaceholder'
$tenantFilterHost = New-RoundedInput -Inner $tenantFilterBox -X 288 -Y 14 -W 424 -H 32
$cardTenant.Controls.Add($tenantFilterHost)

$tenantListView = New-Object System.Windows.Forms.ListView
$tenantListView.Location = New-Object System.Drawing.Point(14, 58)
$tenantListView.Size = New-Object System.Drawing.Size(698, 300)
$tenantListView.View = [System.Windows.Forms.View]::Details
$tenantListView.FullRowSelect = $true
$tenantListView.MultiSelect = $false
$tenantListView.HideSelection = $false
$tenantListView.HeaderStyle = [System.Windows.Forms.ColumnHeaderStyle]::Nonclickable
[void]$tenantListView.Columns.Add((Get-UiString 'TenantColName'), 300)
[void]$tenantListView.Columns.Add((Get-UiString 'TenantColType'), 130)
[void]$tenantListView.Columns.Add((Get-UiString 'TenantColVersion'), 110)
[void]$tenantListView.Columns.Add((Get-UiString 'TenantColAssigned'), 90)
$cardTenant.Controls.Add($tenantListView)

# Same recovery path as the update list: app names and type labels are routinely wider than their
# column, and the value is only readable on hover.
$tenantListTooltip = New-Object System.Windows.Forms.ToolTip
$tenantListTooltip.InitialDelay = 350
$tenantListTooltip.ReshowDelay = 80
$tenantListTooltip.AutoPopDelay = 20000
$script:tenantListTipRow = $null

$tenantListView.Add_MouseMove({
  param($listSender, $e)
  try {
    $hit = $listSender.HitTest($e.X, $e.Y)
    $row = if ($hit) { $hit.Item } else { $null }
    if ($script:tenantListTipRow -eq $row) { return }
    $script:tenantListTipRow = $row
    if (-not $row) { $tenantListTooltip.Hide($listSender); return }

    $lines = @([string]$row.Text)
    $labels = @('TenantColType', 'TenantColVersion', 'TenantColAssigned')
    for ($i = 0; $i -lt $labels.Count; $i++) {
      $subIndex = $i + 1
      if ($row.SubItems.Count -le $subIndex) { break }
      $value = [string]$row.SubItems[$subIndex].Text
      if ($value) { $lines += ('{0}: {1}' -f (Get-UiString $labels[$i]), $value) }
    }
    $tenantListTooltip.Show(($lines -join "`r`n"), $listSender, ($e.X + 16), ($e.Y + 20), 20000)
  } catch { }   # class 3: a failed tooltip must never disturb the list
})

$tenantListView.Add_MouseLeave({
  try { $script:tenantListTipRow = $null; $tenantListTooltip.Hide($tenantListView) } catch { }
})

$tenantDetailLabel = New-Object System.Windows.Forms.Label
$tenantDetailLabel.Text = Get-UiString 'TenantAppAssignmentsLabel'
$tenantDetailLabel.Location = New-Object System.Drawing.Point(14, 366)
$tenantDetailLabel.AutoSize = $true
$cardTenant.Controls.Add($tenantDetailLabel)

$tenantDetailBox = New-Object System.Windows.Forms.TextBox
$tenantDetailBox.Multiline = $true
$tenantDetailBox.ReadOnly = $true
$tenantDetailBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$tenantDetailBox.Location = New-Object System.Drawing.Point(14, 388)
$tenantDetailBox.Size = New-Object System.Drawing.Size(698, 110)
$cardTenant.Controls.Add($tenantDetailBox)

# Two distinct actions on purpose: the left one changes WHO gets the app (groups, exclusions,
# intent), the right one changes HOW it is delivered (notifications, deadlines, restart behaviour).
$tenantAssignButton = New-Object System.Windows.Forms.Button
$tenantAssignButton.Text = Get-UiString 'TenantAppAssignButton'
$tenantAssignButton.Location = New-Object System.Drawing.Point(14, 510)
$tenantAssignButton.Size = New-Object System.Drawing.Size(260, 32)
$tenantAssignButton.Enabled = $false
$cardTenant.Controls.Add($tenantAssignButton)

$tenantEditButton = New-Object System.Windows.Forms.Button
$tenantEditButton.Tag = 'btn-secondary'
$tenantEditButton.Text = Get-UiString 'TenantAppEditButton'
$tenantEditButton.Location = New-Object System.Drawing.Point(286, 510)
$tenantEditButton.Size = New-Object System.Drawing.Size(260, 32)
$tenantEditButton.Enabled = $false
$cardTenant.Controls.Add($tenantEditButton)

$tenantHintLabel = New-Object System.Windows.Forms.Label
$tenantHintLabel.Text = Get-UiString 'TenantAppsHint'
$tenantHintLabel.Location = New-Object System.Drawing.Point(14, 552)
$tenantHintLabel.Size = New-Object System.Drawing.Size(698, 40)
$cardTenant.Controls.Add($tenantHintLabel)

$script:tenantApps = @()

function Update-TenantAppsList {
  param([string]$Filter = '')
  $tenantListView.BeginUpdate()
  try {
    $tenantListView.Items.Clear()
    $needle = $Filter.Trim()
    foreach ($app in $script:tenantApps) {
      if ($needle -and ([string]$app.DisplayName) -notlike "*$needle*" -and ([string]$app.Publisher) -notlike "*$needle*") { continue }
      $row = New-Object System.Windows.Forms.ListViewItem([string]$app.DisplayName)
      [void]$row.SubItems.Add([string]$app.TypeLabel)
      [void]$row.SubItems.Add([string]$app.Version)
      $assignedText = if ($app.IsAssigned) { Get-UiString 'StoreAssignedYes' } else { Get-UiString 'StoreAssignedNo' }
      [void]$row.SubItems.Add([string]$assignedText)
      $row.Tag = $app
      [void]$tenantListView.Items.Add($row)
    }
  } finally { $tenantListView.EndUpdate() }
  Update-Status ((Get-UiString 'TenantAppsShownStatus') -f $tenantListView.Items.Count, $script:tenantApps.Count)
}

$tenantLoadButton.Add_Click({
  if (-not (Test-Connected)) { return }
  if (Test-UiBusy) { return }
  try {
    $tenantLoadButton.Enabled = $false
    Update-Status (Get-UiString 'TenantAppsLoadingStatus')
    [System.Windows.Forms.Application]::DoEvents()  # pumps the message loop; this work stays on the UI thread on purpose (see 70-Runtime)
    $script:tenantApps = @(Get-TenantAllApps)
    Write-Log ("Tenant app inventory loaded: {0} app object(s) of any type." -f $script:tenantApps.Count)
    Update-TenantAppsList -Filter $tenantFilterBox.Text
  } catch {
    Write-Log ("Tenant app inventory failed: {0}" -f $_.Exception.Message)
    Update-Status ((Get-UiString 'TenantAppsLoadFailedStatus') -f $_.Exception.Message)
  } finally {
    $tenantLoadButton.Enabled = $true
  }
})

$tenantFilterBox.Add_TextChanged({
  if ($script:tenantApps.Count -gt 0) { Update-TenantAppsList -Filter $tenantFilterBox.Text }
})

$tenantListView.Add_SelectedIndexChanged({
  if ($tenantListView.SelectedItems.Count -eq 0) {
    $tenantDetailBox.Text = ''
    $tenantEditButton.Enabled = $false
    $tenantAssignButton.Enabled = $false
    return
  }
  $app = $tenantListView.SelectedItems[0].Tag
  $tenantEditButton.Enabled = $true
  $tenantAssignButton.Enabled = $true
  try {
    $tenantDetailBox.Text = Get-TenantAppAssignmentText -AppId ([string]$app.Id)
  } catch {
    $tenantDetailBox.Text = (Get-UiString 'TenantAppAssignmentsFailed') -f $_.Exception.Message
    Write-Log ("Reading assignments for '{0}' failed: {1}" -f $app.DisplayName, $_.Exception.Message)
  }
})

# Reuses the very same settings dialog and writer as the deployment path, so an app configured here
# ends up with exactly the payload a fresh deployment would produce - no second implementation.
$tenantEditButton.Add_Click({
  if (-not (Test-Connected)) { return }
  if (Test-UiBusy) { return }
  if ($tenantListView.SelectedItems.Count -eq 0) { return }
  $app = $tenantListView.SelectedItems[0].Tag
  $confirm = [System.Windows.Forms.MessageBox]::Show(
    ((Get-UiString 'TenantAppEditConfirm') -f $app.DisplayName),
    (Get-UiString 'ConfirmTitle'),
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Warning)
  if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

  try { Show-AppSettingsDialog } catch { Write-Log ("App settings dialog failed: {0}" -f $_.Exception.Message); return }

  try {
    $settings = Get-DeployAssignmentSettings
    if (-not $settings) { $settings = @{} }
    $changes = Get-DeployAssignmentTargetChanges
    $result = Set-AppAssignmentSettings -AppId ([string]$app.Id) -Settings $settings -TargetChanges $changes -AppName ([string]$app.DisplayName)
    if ($result.ErrorMessage) {
      Update-Status ((Get-UiString 'TenantAppEditFailedStatus') -f $result.ErrorMessage)
    } else {
      Update-Status ((Get-UiString 'TenantAppEditDoneStatus') -f $app.DisplayName, $result.Changed)
      $tenantDetailBox.Text = Get-TenantAppAssignmentText -AppId ([string]$app.Id)
    }
  } catch {
    Write-Log ("Applying assignment settings to '{0}' failed: {1}" -f $app.DisplayName, $_.Exception.Message)
    Update-Status ((Get-UiString 'TenantAppEditFailedStatus') -f $_.Exception.Message)
  }
})

$tenantAssignButton.Add_Click({
  if (-not (Test-Connected)) { return }
  if (Test-UiBusy) { return }
  if ($tenantListView.SelectedItems.Count -eq 0) { return }
  $app = $tenantListView.SelectedItems[0].Tag
  $changed = Show-AssignmentManagerDialog -AppId ([string]$app.Id) -AppName ([string]$app.DisplayName)
  if ($changed) {
    try { $tenantDetailBox.Text = Get-TenantAppAssignmentText -AppId ([string]$app.Id) } catch { }
  }
})

Add-Section -Key 'tenant' -Panel $tabTenant -Label (Get-UiString 'TabTenantApps')

# Structured counterpart to Get-TenantAppAssignmentText. Keeps the RAW target and settings so an
# unchanged assignment can be written back unaltered: Graph's /assign endpoint REPLACES the whole
# set, so anything not sent back would be deleted.
function Get-TenantAppAssignments {
  param([Parameter(Mandatory)][string]$AppId)
  $token = Get-WtToken -ErrorAction Stop
  $headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
  $uri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$AppId/assignments"
  $items = @(Get-GraphCollectionItems -Uri $uri -Headers $headers)
  $out = [System.Collections.Generic.List[object]]::new()
  foreach ($a in $items) {
    $targetType = ([string]$a.target.'@odata.type').TrimStart([char]'#') -replace '^microsoft\.graph\.', ''
    $rawTarget = $null
    $rawSettings = $null
    try { $rawTarget = ($a.target | ConvertTo-Json -Depth 12 | ConvertFrom-Json -AsHashtable) } catch { $rawTarget = $null }
    if ($a.settings) {
      try { $rawSettings = ($a.settings | ConvertTo-Json -Depth 12 | ConvertFrom-Json -AsHashtable) } catch { $rawSettings = $null }
    }
    $out.Add([pscustomobject]@{
      Id          = [string]$a.id
      Intent      = [string]$a.intent
      TargetType  = $targetType
      GroupId     = [string]$a.target.groupId
      RawTarget   = $rawTarget
      RawSettings = $rawSettings
    })
  }
  return @($out.ToArray())
}

# Readable one-liner for a single assignment.
function Get-AssignmentDisplayText {
  param([Parameter(Mandatory)]$Assignment)
  $scope = switch -Regex ([string]$Assignment.TargetType) {
    'allDevicesAssignmentTarget'       { Get-UiString 'TargetAllDevices' }
    'allLicensedUsersAssignmentTarget' { Get-UiString 'TargetAllUsers' }
    'exclusionGroupAssignmentTarget'   { (Get-UiString 'TargetExcludedGroup') -f [string]$Assignment.GroupId }
    'groupAssignmentTarget'            { (Get-UiString 'TargetGroup') -f [string]$Assignment.GroupId }
    default                            { [string]$Assignment.TargetType }
  }
  return ('{0,-10} {1}' -f [string]$Assignment.Intent, $scope)
}

# Writes the COMPLETE desired assignment set. Nothing is merged here on purpose - the dialog owns
# the list, and what it passes in is exactly what the app has afterwards.
function Set-TenantAppAssignments {
  param(
    [Parameter(Mandatory)][string]$AppId,
    [Parameter(Mandatory)][AllowEmptyCollection()][array]$Assignments,
    [string]$AppName = ''
  )
  $out = @{ Changed = 0; ErrorMessage = $null }
  if (-not (Test-GuidString $AppId)) { $out.ErrorMessage = 'invalid app id'; return $out }
  try {
    $token = Get-WtToken -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace([string]$token)) { throw 'WinTuner returned an empty access token.' }
    $headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
    $payload = @()
    foreach ($a in $Assignments) {
      if (-not $a.RawTarget) { continue }
      $entry = @{
        '@odata.type' = '#microsoft.graph.mobileAppAssignment'
        intent        = [string]$a.Intent
        target        = $a.RawTarget
      }
      # Settings are sent only when the existing assignment had them. A newly added assignment is
      # left without, so Intune applies its own defaults rather than us guessing a payload that
      # differs per app type.
      if ($a.RawSettings) { $entry.settings = $a.RawSettings }
      $payload += $entry
    }
    $body = @{ mobileAppAssignments = @($payload) } | ConvertTo-Json -Depth 14
    Invoke-RestMethod -Method POST -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$AppId/assign" -Headers $headers -Body $body -ErrorAction Stop | Out-Null
    $out.Changed = $payload.Count
    Write-Log ("Assignment set rewritten for '{0}' ({1}): {2} assignment(s)." -f $AppName, $AppId, $payload.Count)
  } catch {
    $out.ErrorMessage = $_.Exception.Message
    Write-Log ("Rewriting assignments FAILED for '{0}' ({1}): {2}" -f $AppName, $AppId, $out.ErrorMessage)
  }
  return $out
}

# Add/remove dialog for one app's assignments. Every change is held in memory and written only
# after an explicit confirmation, so a mis-click can never reach Intune.
function Show-AssignmentManagerDialog {
  param([Parameter(Mandatory)][string]$AppId, [string]$AppName = '')

  $script:assignWorking = [System.Collections.Generic.List[object]]::new()
  try {
    foreach ($a in @(Get-TenantAppAssignments -AppId $AppId)) { [void]$script:assignWorking.Add($a) }
  } catch {
    [void][System.Windows.Forms.MessageBox]::Show(
      ((Get-UiString 'TenantAppAssignmentsFailed') -f $_.Exception.Message),
      (Get-UiString 'InfoTitle'),
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Warning)
    return $false
  }

  $dlg = New-Object System.Windows.Forms.Form
  $dlg.Text = (Get-UiString 'AssignManagerTitle') -f $AppName
  $dlg.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
  $dlg.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
  $dlg.MinimizeBox = $false
  $dlg.MaximizeBox = $false
  $dlg.ShowIcon = $false
  $dlg.ClientSize = New-Object System.Drawing.Size(640, 474)

  $listLabel = New-Object System.Windows.Forms.Label
  $listLabel.Text = Get-UiString 'AssignManagerCurrentLabel'
  $listLabel.Location = New-Object System.Drawing.Point(14, 12)
  $listLabel.AutoSize = $true
  $dlg.Controls.Add($listLabel)

  $assignList = New-Object System.Windows.Forms.ListBox
  $assignList.Location = New-Object System.Drawing.Point(14, 34)
  $assignList.Size = New-Object System.Drawing.Size(612, 170)
  $dlg.Controls.Add($assignList)

  foreach ($a in $script:assignWorking) { [void]$assignList.Items.Add((Get-AssignmentDisplayText -Assignment $a)) }

  $removeButton = New-Object System.Windows.Forms.Button
  $removeButton.Tag = 'btn-secondary'
  $removeButton.Text = Get-UiString 'AssignManagerRemoveButton'
  $removeButton.Location = New-Object System.Drawing.Point(14, 212)
  $removeButton.Size = New-Object System.Drawing.Size(220, 30)
  $removeButton.Add_Click({
    $i = $assignList.SelectedIndex
    if ($i -ge 0 -and $i -lt $script:assignWorking.Count) {
      $script:assignWorking.RemoveAt($i)
      $assignList.Items.RemoveAt($i)
    }
  })
  $dlg.Controls.Add($removeButton)

  $addLabel = New-Object System.Windows.Forms.Label
  $addLabel.Text = Get-UiString 'AssignManagerAddLabel'
  $addLabel.Location = New-Object System.Drawing.Point(14, 254)
  $addLabel.AutoSize = $true
  $addLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
  $dlg.Controls.Add($addLabel)

  $intentLabel = New-Object System.Windows.Forms.Label
  $intentLabel.Text = Get-UiString 'AssignManagerIntentLabel'
  $intentLabel.Location = New-Object System.Drawing.Point(14, 286)
  $intentLabel.AutoSize = $true
  $dlg.Controls.Add($intentLabel)

  $intentCombo = New-Object System.Windows.Forms.ComboBox
  $intentCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
  $intentCombo.Location = New-Object System.Drawing.Point(160, 282)
  $intentCombo.Width = 200
  [void]$intentCombo.Items.AddRange(@('available', 'required', 'uninstall'))
  $intentCombo.SelectedIndex = 0
  $dlg.Controls.Add($intentCombo)

  $targetLabel = New-Object System.Windows.Forms.Label
  $targetLabel.Text = Get-UiString 'AssignManagerTargetLabel'
  $targetLabel.Location = New-Object System.Drawing.Point(14, 320)
  $targetLabel.AutoSize = $true
  $dlg.Controls.Add($targetLabel)

  $targetCombo = New-Object System.Windows.Forms.ComboBox
  $targetCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
  $targetCombo.Location = New-Object System.Drawing.Point(160, 316)
  $targetCombo.Width = 200
  [void]$targetCombo.Items.AddRange(@(
    (Get-UiString 'TargetAllUsers'),
    (Get-UiString 'TargetAllDevices'),
    (Get-UiString 'AssignManagerTargetGroup'),
    (Get-UiString 'AssignManagerTargetExclude')))
  $targetCombo.SelectedIndex = 0
  $dlg.Controls.Add($targetCombo)

  $groupLabel = New-Object System.Windows.Forms.Label
  $groupLabel.Text = Get-UiString 'AssignManagerGroupIdLabel'
  $groupLabel.Location = New-Object System.Drawing.Point(14, 354)
  $groupLabel.AutoSize = $true
  $dlg.Controls.Add($groupLabel)

  $groupIdBox = New-Object System.Windows.Forms.TextBox
  $groupIdBox.Location = New-Object System.Drawing.Point(160, 350)
  $groupIdBox.Width = 226
  $groupIdBox.PlaceholderText = Get-UiString 'AssignManagerGroupIdPlaceholder'
  $dlg.Controls.Add($groupIdBox)

  # OPTIONAL convenience: look the group up by name instead of pasting an object ID. Needs the
  # extra Group.Read.All consent, which is why it only happens when this button is pressed - the
  # rest of the dialog works without that permission.
  $groupSearchButton = New-Object System.Windows.Forms.Button
  $groupSearchButton.Tag = 'btn-secondary'
  $groupSearchButton.Text = Get-UiString 'AssignManagerGroupSearchButton'
  $groupSearchButton.Location = New-Object System.Drawing.Point(394, 348)
  $groupSearchButton.Size = New-Object System.Drawing.Size(100, 30)
  $groupSearchButton.Add_Click({
    $needle = $groupIdBox.Text.Trim()
    if (-not $needle) {
      [void][System.Windows.Forms.MessageBox]::Show(
        (Get-UiString 'AssignManagerGroupSearchEmpty'),
        (Get-UiString 'InfoTitle'),
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information)
      return
    }
    if (-not (Connect-GroupLookupScope)) { return }
    try {
      $found = @(Find-EntraGroup -NameContains $needle)
      if ($found.Count -eq 0) {
        Update-Status ((Get-UiString 'GroupLookupNoResults') -f $needle)
        return
      }
      $picked = Show-StorePickerDialog -Results $found -TitleKey 'GroupPickerTitle' -HintKey 'GroupPickerHint' -NameColumnKey 'GroupColName' -IdColumnKey 'GroupColId'
      if ($picked) {
        $groupIdBox.Text = [string]$picked.PackageIdentifier
        Update-Status ((Get-UiString 'GroupLookupPicked') -f $picked.Name, $picked.PackageIdentifier)
      }
    } catch {
      Write-Log ("Entra group lookup failed: {0}" -f $_.Exception.Message)
      Update-Status ((Get-UiString 'GroupLookupFailed') -f $_.Exception.Message)
    }
  })
  $dlg.Controls.Add($groupSearchButton)

  $addButton = New-Object System.Windows.Forms.Button
  $addButton.Tag = 'btn-secondary'
  $addButton.Text = Get-UiString 'AssignManagerAddButton'
  $addButton.Location = New-Object System.Drawing.Point(502, 348)
  $addButton.Size = New-Object System.Drawing.Size(124, 30)
  $addButton.Add_Click({
    $kindIndex = [int]$targetCombo.SelectedIndex
    $needsGroup = ($kindIndex -ge 2)
    $gid = $groupIdBox.Text.Trim()
    if ($needsGroup -and -not (Test-GuidString $gid)) {
      [void][System.Windows.Forms.MessageBox]::Show(
        (Get-UiString 'AssignManagerGroupIdInvalid'),
        (Get-UiString 'InfoTitle'),
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning)
      return
    }
    $target = @{}
    $typeName = 'groupAssignmentTarget'
    if ($kindIndex -eq 0) {
      $target['@odata.type'] = '#microsoft.graph.allLicensedUsersAssignmentTarget'
      $typeName = 'allLicensedUsersAssignmentTarget'
    } elseif ($kindIndex -eq 1) {
      $target['@odata.type'] = '#microsoft.graph.allDevicesAssignmentTarget'
      $typeName = 'allDevicesAssignmentTarget'
    } elseif ($kindIndex -eq 2) {
      $target['@odata.type'] = '#microsoft.graph.groupAssignmentTarget'
      $target['groupId'] = $gid
      $typeName = 'groupAssignmentTarget'
    } else {
      $target['@odata.type'] = '#microsoft.graph.exclusionGroupAssignmentTarget'
      $target['groupId'] = $gid
      $typeName = 'exclusionGroupAssignmentTarget'
    }
    $target['deviceAndAppManagementAssignmentFilterType'] = 'none'
    $entry = [pscustomobject]@{
      Id          = ''
      Intent      = [string]$intentCombo.SelectedItem
      TargetType  = $typeName
      GroupId     = $gid
      RawTarget   = $target
      RawSettings = $null
    }
    [void]$script:assignWorking.Add($entry)
    [void]$assignList.Items.Add((Get-AssignmentDisplayText -Assignment $entry))
    $groupIdBox.Text = ''
  })
  $dlg.Controls.Add($addButton)

  $warnLabel = New-Object System.Windows.Forms.Label
  $warnLabel.Text = Get-UiString 'AssignManagerWarning'
  $warnLabel.Location = New-Object System.Drawing.Point(14, 388)
  $warnLabel.Size = New-Object System.Drawing.Size(612, 42)
  $dlg.Controls.Add($warnLabel)

  $saveButton = New-Object System.Windows.Forms.Button
  $saveButton.Text = Get-UiString 'AssignManagerSaveButton'
  $saveButton.Location = New-Object System.Drawing.Point(394, 436)
  $saveButton.Size = New-Object System.Drawing.Size(116, 30)
  $saveButton.Add_Click({
    $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $dlg.Close()
  })
  $dlg.Controls.Add($saveButton)

  $cancelButton = New-Object System.Windows.Forms.Button
  $cancelButton.Tag = 'btn-secondary'
  $cancelButton.Text = Get-UiString 'CancelButton'
  $cancelButton.Location = New-Object System.Drawing.Point(516, 436)
  $cancelButton.Size = New-Object System.Drawing.Size(110, 30)
  $cancelButton.Add_Click({
    $dlg.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dlg.Close()
  })
  $dlg.Controls.Add($cancelButton)

  $dlg.CancelButton = $cancelButton
  Set-GuiTheme -control $dlg -theme $script:currentTheme
  $answer = $dlg.ShowDialog()
  $dlg.Dispose()
  if ($answer -ne [System.Windows.Forms.DialogResult]::OK) { return $false }

  $confirm = [System.Windows.Forms.MessageBox]::Show(
    ((Get-UiString 'AssignManagerConfirm') -f $AppName, $script:assignWorking.Count),
    (Get-UiString 'ConfirmTitle'),
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Warning)
  if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return $false }

  $applied = Set-TenantAppAssignments -AppId $AppId -Assignments @($script:assignWorking.ToArray()) -AppName $AppName
  if ($applied.ErrorMessage) {
    Update-Status ((Get-UiString 'TenantAppEditFailedStatus') -f $applied.ErrorMessage)
    return $false
  }
  Update-Status ((Get-UiString 'TenantAppEditDoneStatus') -f $AppName, $applied.Changed)
  return $true
}

# Grows list, filter and detail pane with the card, which itself grows with the window.
function Update-TenantAppsLayout {
  try {
    if (-not $cardTenant -or -not $tenantListView) { return }
    $inner = $cardTenant.ClientSize.Width - 28
    if ($inner -lt 400) { return }
    $tenantFilterHost.Width = [Math]::Max(200, $inner - 274)
    $tenantFilterBox.Width = [Math]::Max(180, $tenantFilterHost.Width - 12)
    $tenantListView.Width = $inner
    $tenantDetailBox.Width = $inner
    $tenantHintLabel.Width = [Math]::Max(200, $inner - 288)
    # Extra width goes mostly to the app name, by far the longest value in this list.
    $extra = $inner - 698
    if ($extra -gt 0 -and $tenantListView.Columns.Count -ge 4) {
      $tenantListView.Columns[0].Width = 300 + [int]($extra * 0.55)
      $tenantListView.Columns[1].Width = 130 + [int]($extra * 0.20)
      $tenantListView.Columns[2].Width = 110 + [int]($extra * 0.15)
      $tenantListView.Columns[3].Width = 90 + [int]($extra * 0.10)
    }
  } catch { }   # class 3: layout must never break the section
}

# --- OPTIONAL: look up Entra ID groups by name ---
# Group.Read.All is deliberately NOT part of the scopes requested at sign-in. The update scan
# learned that lesson the hard way: any scope missing from the returned token triggers a second
# sign-in prompt on every click, so a tenant without consent gets punished for a permission it
# never needed. This one is therefore requested on first use only, and only when the user asks
# for it - everything else in the GUI keeps working without it.
$script:groupLookupConsentAsked = $false

function Connect-GroupLookupScope {
  $scope = 'Group.Read.All'
  $context = $null
  try { $context = Get-MgContext -ErrorAction SilentlyContinue } catch { $context = $null }
  if ($context -and $context.Scopes -contains $scope -and $context.Account -eq $script:currentUserUpn) { return $true }

  if (-not $script:groupLookupConsentAsked) {
    $script:groupLookupConsentAsked = $true
    $answer = [System.Windows.Forms.MessageBox]::Show(
      (Get-UiString 'GroupLookupConsentDialog'),
      (Get-UiString 'GroupLookupConsentTitle'),
      [System.Windows.Forms.MessageBoxButtons]::YesNo,
      [System.Windows.Forms.MessageBoxIcon]::Information)
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return $false }
  }

  try {
    $tenantDomain = $script:currentUserUpn.Split('@')[1]
    Update-Status (Get-UiString 'GroupLookupAuthStatus')
    $null = Connect-MgGraph -TenantId $tenantDomain -Scopes @($scope) -NoWelcome -ErrorAction Stop *>&1
    Write-Log 'Group.Read.All granted for the optional group name lookup.'
    return $true
  } catch {
    Write-Log ("Group name lookup could not obtain Group.Read.All: {0}" -f $_.Exception.Message)
    [void][System.Windows.Forms.MessageBox]::Show(
      ((Get-UiString 'GroupLookupDeniedDialog') -f $_.Exception.Message),
      (Get-UiString 'GroupLookupConsentTitle'),
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Warning)
    return $false
  }
}

# Name search across Entra ID groups. Returns objects with DisplayName and Id.
function Find-EntraGroup {
  param([Parameter(Mandatory)][string]$NameContains)
  $needle = $NameContains.Trim()
  if (-not $needle) { return @() }
  # Single quotes are the OData string delimiter and must be doubled, otherwise a group name like
  # "Timo's Devices" would break the filter - or alter it.
  # Two separate escapes, both required. Doubling the apostrophe keeps the OData string intact;
  # EscapeDataString keeps the URL intact. Without the second one a group name containing & or #
  # ended the query string early or appended a parameter of the searcher's choosing.
  $escaped = [uri]::EscapeDataString($needle.Replace("'", "''"))
  $uri = "https://graph.microsoft.com/v1.0/groups?`$filter=startswith(displayName,'$escaped')&`$select=id,displayName,mailNickname&`$top=50"
  $response = Invoke-MgGraphRequest -Method GET -Uri $uri -ErrorAction Stop
  $out = [System.Collections.Generic.List[object]]::new()
  foreach ($g in @($response.value)) {
    if (-not $g -or -not $g.id) { continue }
    $out.Add([pscustomobject]@{ Name = [string]$g.displayName; PackageIdentifier = [string]$g.id })
  }
  return @($out.ToArray())
}
