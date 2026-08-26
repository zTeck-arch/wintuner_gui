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
# --- Klarnamen von Entra-Gruppen ----------------------------------------------------------------
#
# Zuweisungen kamen ueberall als reine GUID an ("Group 1f4c...") - in Intune steht dort der Name der
# Gruppe. Die GUID ist fuer einen Menschen nicht lesbar und beantwortet die eigentliche Frage nicht:
# WER bekommt diese App.
#
# Aufgeloest wird in drei Stufen, absteigend nach Kosten:
#   1. Gruppen-Favoriten dieses Kunden - der Name, den der Techniker selbst vergeben hat, ohne jede
#      Abfrage.
#   2. Graph mit dem Token der Anwendung. Reicht, wenn dessen Berechtigungen Verzeichnisleserechte
#      enthalten.
#   3. die Graph-PowerShell-Sitzung, ABER nur wenn die Zustimmung fuer Group.Read.All in dieser
#      Sitzung schon erteilt wurde. Von hier wird NIE ein Zustimmungsdialog geoeffnet: diese
#      Funktion laeuft in einer Schleife ueber eine Liste, das waere ein Dialog je Zeile.
#
# Gemerkt wird pro Sitzung, auch das Misserfolg: eine geloeschte Gruppe wird nicht bei jeder Zeile
# erneut abgefragt, und fehlt die Berechtigung ganz, wird die Abfrage einmal abgeschaltet statt
# hundertmal in einen 403 zu laufen.
$script:entraGroupNameCache = @{}
$script:entraGroupLookupOff = $false

function Clear-EntraGroupNameCache {
  $script:entraGroupNameCache = @{}
  $script:entraGroupLookupOff = $false
}

function Get-EntraGroupDisplayName {
  param([Parameter(Mandatory)][string]$GroupId)
  if ([string]::IsNullOrWhiteSpace($GroupId) -or -not (Test-GuidString $GroupId)) { return '' }
  $key = $GroupId.Trim().ToLowerInvariant()
  if ($script:entraGroupNameCache.ContainsKey($key)) { return [string]$script:entraGroupNameCache[$key] }

  # 1. Favorit dieses Kunden
  try {
    foreach ($f in @(Get-GroupFavorites)) {
      if ($f -and [string]::Equals([string]$f.Id, $GroupId, [System.StringComparison]::OrdinalIgnoreCase)) {
        $script:entraGroupNameCache[$key] = [string]$f.Name
        return [string]$f.Name
      }
    }
  } catch { Write-LogDebug 'group favourite lookup' }

  if ($script:entraGroupLookupOff) { return '' }

  $uri = "https://graph.microsoft.com/v1.0/groups/$GroupId`?`$select=displayName"
  $name = ''
  $denied = $false
  # 2. Token der Anwendung
  try {
    $token = Get-WtToken -ErrorAction Stop
    $resp = Invoke-RestMethod -Uri $uri -Method GET -Headers @{ Authorization = "Bearer $token" } -ErrorAction Stop
    $name = [string]$resp.displayName
  } catch {
    $status = Get-ErrorHttpStatus -ErrorRecord $_
    if ($status -eq 401 -or $status -eq 403) { $denied = $true }
    elseif ($status -eq 404) {
      # Die Gruppe gibt es nicht mehr. Kein Fehler dieser Anwendung - aber die Zuweisung zeigt dann
      # auf nichts, und das ist eine Auffaelligkeit, die ins Protokoll gehoert.
      Write-Log ("Group {0} could not be found in Entra ID - an assignment points at a group that no longer exists." -f $GroupId)
      $script:entraGroupNameCache[$key] = ''
      return ''
    } else {
      Write-LogDebug ("Group name lookup for {0}: {1}" -f $GroupId, $_.Exception.Message)
    }
  }

  # 3. bereits erteilte Graph-Zustimmung
  if (-not $name) {
    $hasScope = $false
    try {
      $ctx = Get-MgContext -ErrorAction SilentlyContinue
      $hasScope = ($ctx -and ($ctx.Scopes -contains 'Group.Read.All'))
    } catch { $hasScope = $false }
    if ($hasScope) {
      try {
        $resp = Invoke-MgGraphRequest -Method GET -Uri $uri -ErrorAction Stop
        $name = if ($resp -is [hashtable]) { [string]$resp['displayName'] } else { [string]$resp.displayName }
        $denied = $false
      } catch {
        Write-LogDebug ("Group name lookup via the Graph session for {0}: {1}" -f $GroupId, $_.Exception.Message)
      }
    }
  }

  if (-not $name -and $denied) {
    # Einmal abschalten und einmal sagen, wie man es einschaltet - nicht je Zeile.
    $script:entraGroupLookupOff = $true
    Write-Log "Group names cannot be read with the current permissions, so assignments show the group's object id. Grant the optional group permission once (button 'Gruppen...' next to any 'Assign to' field) and reopen the list to see the names."
    return ''
  }
  $script:entraGroupNameCache[$key] = $name
  return $name
}

# Name wenn moeglich, sonst die GUID - der Aufrufer bekommt immer etwas Anzeigbares.
function Get-EntraGroupLabel {
  param([Parameter(Mandatory)][string]$GroupId)
  $name = ''
  try { $name = Get-EntraGroupDisplayName -GroupId $GroupId } catch { $name = '' }
  if ([string]::IsNullOrWhiteSpace($name)) { return [string]$GroupId }
  return $name
}

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
      'exclusionGroupAssignmentTarget'   { 'Excluded group {0}' -f (Get-EntraGroupLabel -GroupId ([string]$a.target.groupId)) }
      'groupAssignmentTarget'            { 'Group {0}' -f (Get-EntraGroupLabel -GroupId ([string]$a.target.groupId)) }
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

# Der Sammel-Editor, bisher nur ueber "Extras" erreichbar. Er gehoert neben den Einzelfall: hier
# steht die Liste der vorhandenen Apps, hier sucht man Einstellungen fuer vorhandene Apps.
$tenantBulkEditButton = New-Object System.Windows.Forms.Button
$tenantBulkEditButton.Tag = 'btn-secondary'
$tenantBulkEditButton.Text = Get-UiString 'TenantAppBulkEditButton'
$tenantBulkEditButton.Location = New-Object System.Drawing.Point(558, 510)
$tenantBulkEditButton.Size = New-Object System.Drawing.Size(260, 32)
$cardTenant.Controls.Add($tenantBulkEditButton)
$tenantBulkEditButton.Add_Click({
  if (-not (Test-Connected)) { return }
  if (Test-UiBusy) { return }
  try { Show-AppSettingsDialog } catch { Write-Log ("App settings dialog failed: {0}" -f $_.Exception.Message) }
})

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

# Opens the shared app-settings dialog with the selected app pre-checked. That dialog writes only
# deployment SETTINGS (notifications, availability, deadline, restart) and never rewrites assignment
# targets - so exclusions and assignment filters on the app are left untouched. Changing the actual
# targets of a tenant app is the separate "Zuweisungs-Manager" button below.
$tenantEditButton.Add_Click({
  if (-not (Test-Connected)) { return }
  if (Test-UiBusy) { return }
  if ($tenantListView.SelectedItems.Count -eq 0) { return }
  $app = $tenantListView.SelectedItems[0].Tag
  if (-not (Confirm-ChangeAction -Text ((Get-UiString 'TenantAppEditConfirm') -f $app.DisplayName) `
      -Title (Get-UiString 'ConfirmTitle') `
      -LogContext ("assignment settings of '{0}'" -f $app.DisplayName))) { return }

  try { Show-AppSettingsDialog -PreselectApp $app } catch { Write-Log ("App settings dialog failed: {0}" -f $_.Exception.Message); return }

  # The dialog applies its own changes; just refresh the detail view for the selected app.
  try { $tenantDetailBox.Text = Get-TenantAppAssignmentText -AppId ([string]$app.Id) } catch { }
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

Add-Section -Key 'tenant' -Panel $tabTenant -Label (Get-UiString 'TabTenantApps') -Group 'manage'

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
    # A failed clone used to be swallowed here and then quietly skipped by the writer - which,
    # because the writer POSTs the COMPLETE desired set, deleted that assignment from Intune for
    # good. Record it instead so the writer can refuse rather than lose it.
    try { $rawTarget = ($a.target | ConvertTo-Json -Depth 12 | ConvertFrom-Json -AsHashtable) } catch {
      $rawTarget = $null
      Write-Log ("Assignment {0} on app {1}: its target could not be read ({2}). The assignment set cannot be rewritten safely while this one is unreadable." -f [string]$a.id, $AppId, $_.Exception.Message)
    }
    if ($a.settings) {
      try { $rawSettings = ($a.settings | ConvertTo-Json -Depth 12 | ConvertFrom-Json -AsHashtable) } catch {
        $rawSettings = $null
        Write-Log ("Assignment {0} on app {1}: its settings could not be read ({2}); Intune defaults would be applied if it were rewritten." -f [string]$a.id, $AppId, $_.Exception.Message)
      }
    }
    $out.Add([pscustomobject]@{
      Id          = [string]$a.id
      Intent      = [string]$a.intent
      TargetType  = $targetType
      GroupId     = [string]$a.target.groupId
      # Carried so the manager can SHOW the filter. An assignment filter decides which devices an
      # assignment actually reaches; a list that hides it invites an admin to remove or re-add an
      # assignment believing it is unfiltered.
      FilterType  = [string]$a.target.deviceAndAppManagementAssignmentFilterType
      FilterId    = [string]$a.target.deviceAndAppManagementAssignmentFilterId
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
    'exclusionGroupAssignmentTarget'   { (Get-UiString 'TargetExcludedGroup') -f (Get-EntraGroupLabel -GroupId ([string]$Assignment.GroupId)) }
    'groupAssignmentTarget'            { (Get-UiString 'TargetGroup') -f (Get-EntraGroupLabel -GroupId ([string]$Assignment.GroupId)) }
    default                            { [string]$Assignment.TargetType }
  }
  # Name the assignment filter when there is one. 'none' is Intune's own value for "no filter" and
  # is left off rather than shown as noise.
  $filter = ''
  $filterType = [string]$Assignment.FilterType
  if ($filterType -and $filterType -ne 'none') {
    $filterName = if ([string]$Assignment.FilterId) { [string]$Assignment.FilterId } else { '?' }
    $filter = ' ' + ((Get-UiString 'TargetFilterSuffix') -f $filterType, $filterName)
  }
  return ('{0,-10} {1}{2}' -f [string]$Assignment.Intent, $scope, $filter)
}

# Counts exclusions that nothing includes.
#
# An "exclude group X" assignment only means something next to an include for the same intent - it
# narrows that include. On its own it reaches nobody, so an admin who removed the last include and
# kept the exclusion has silently unassigned the app while the list still shows an entry per line.
# Pure so the rule can be tested without a dialog.
function Get-ExclusionsWithoutInclude {
  param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Assignments)
  $lonely = 0
  foreach ($intent in @($Assignments | ForEach-Object { [string]$_.Intent } | Sort-Object -Unique)) {
    $sameIntent = @($Assignments | Where-Object { [string]$_.Intent -eq $intent })
    $exclusions = @($sameIntent | Where-Object { [string]$_.TargetType -match 'exclusionGroupAssignmentTarget' })
    if ($exclusions.Count -eq 0) { continue }
    $includes = @($sameIntent | Where-Object { -not ([string]$_.TargetType -match 'exclusionGroupAssignmentTarget') })
    if ($includes.Count -eq 0) { $lonely += $exclusions.Count }
  }
  return $lonely
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
    # An assignment whose target could not be read must STOP the write, not be skipped.
    #
    # This function posts the complete desired set, so every entry left out of $payload is deleted
    # in Intune. Skipping the unreadable ones therefore turned "one assignment I could not parse"
    # into "that assignment is gone", permanently, with a success message and a count that looked
    # plausible. Refusing costs the user one dialog; the old behaviour cost them an assignment.
    $unreadable = @($Assignments | Where-Object { -not $_.RawTarget })
    if ($unreadable.Count -gt 0) {
      $writable = @($Assignments).Count - $unreadable.Count
      $out.ErrorMessage = (Get-UiString 'AssignRewriteUnreadable') -f $unreadable.Count, $writable
      Write-Log ("Rewriting assignments REFUSED for '{0}' ({1}): {2} of {3} assignment(s) have an unreadable target; writing would have deleted them." -f $AppName, $AppId, $unreadable.Count, @($Assignments).Count)
      return $out
    }
    $payload = @()
    foreach ($a in $Assignments) {
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
    $out.ErrorMessage = Get-AssignmentWriteErrorText -ErrorRecord $_
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

  # Say it before writing, not after: an exclusion with no include left reaches nobody, so the app
  # ends up effectively unassigned while the list still shows a line per assignment.
  $confirmText = (Get-UiString 'AssignManagerConfirm') -f $AppName, $script:assignWorking.Count
  $lonelyExclusions = Get-ExclusionsWithoutInclude -Assignments @($script:assignWorking.ToArray())
  if ($lonelyExclusions -gt 0) {
    $confirmText = $confirmText + "`r`n`r`n" + ((Get-UiString 'AssignManagerExclusionWarning') -f $lonelyExclusions)
  }
  # -AlwaysAsk: siehe Confirm-ChangeAction. Wer die Zuweisung aendert, aendert die Reichweite der
  # App im Kundentenant - diese Frage darf die Einstellung "Rueckfragen abschalten" nicht schlucken.
  if (-not (Confirm-ChangeAction -Text $confirmText -Title (Get-UiString 'ConfirmTitle') `
      -AlwaysAsk -LogContext ("assignment set of '{0}'" -f $AppName))) { return $false }

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
    # Auch die HOEHE. Bisher wuchs nur die Breite mit, die Liste blieb bei 300 px - auf einem
    # grossen Bildschirm eine schmale Zeile Inhalt in einer halbleeren Karte.
    $avail = $tabTenant.ClientSize.Height
    if ($avail -ge 400) {
      $topY = 48; $bottomPad = 6
      $cardTenant.Height = $avail - $topY - $bottomPad
      # Alles unter der Liste wird gemessen, nicht gezaehlt. Die frueheren Konstanten stimmten fuer
      # eine Schriftart: die Beschriftung ragte ein Pixel ins Detailfeld, das Detailfeld ragte in
      # den dritten Knopf (der ueberhaupt nicht mitverschoben wurde), und der Hinweis lag MITTEN in
      # der Knopfreihe - drei Ueberlappungen, alle im Bild sichtbar, keine im Code zu sehen.
      $labelH = [Math]::Max(18, $tenantDetailLabel.Height)
      $buttonH = [Math]::Max(28, $tenantAssignButton.Height)
      $hintH = [Math]::Max(20, $tenantHintLabel.Height)
      $below = ($labelH + 4) + $tenantDetailBox.Height + 12 + $buttonH + 10 + $hintH + 16
      $listH = $cardTenant.ClientSize.Height - 58 - 30 - $below
      if ($listH -lt 150) { $listH = 150 }
      $tenantListView.Height = $listH
      $detailTop = 58 + $listH + 30
      if ($tenantDetailLabel) { $tenantDetailLabel.Top = $detailTop - $labelH - 4 }
      $tenantDetailBox.Top = $detailTop
      # ALLE drei Knoepfe. Der Sammel-Editor blieb auf seiner Entwurfshoehe stehen und lag deshalb
      # unter dem gewachsenen Detailfeld.
      foreach ($b in @($tenantAssignButton, $tenantEditButton, $tenantBulkEditButton)) {
        if ($b) { $b.Top = $tenantDetailBox.Bottom + 12 }
      }
      if ($tenantHintLabel) { $tenantHintLabel.Top = $tenantAssignButton.Bottom + 10 }
    }
    # Der Hinweis bekommt die volle Breite - er steht jetzt unter der Knopfreihe, nicht daneben.
    $tenantHintLabel.Width = $inner
    # Extra width goes mostly to the app name, by far the longest value in this list.
    $extra = $inner - [System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth - 2 - 698
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
# The ANSWER is remembered per tenant domain, not merely the fact that we asked. Storing only "asked"
# meant a second click skipped the prompt and connected anyway - and, because the flag survived a
# tenant switch, it did so in the NEXT customer's tenant where no one had ever been asked. Keying by
# domain both remembers a "No" and starts fresh for every new customer.
$script:groupLookupConsent = @{}   # tenant domain -> $true | $false (die Antwort auf den Dialog)
# Tenant-Domaene -> die Zustimmung wurde in dieser Sitzung erteilt, egal mit welchem Konto.
$script:groupLookupGranted = @{}

# Holt eine OPTIONALE Graph-Berechtigung auf Zuruf. Verwendet fuer die Gruppensuche
# (Group.Read.All) und fuer die erkannten Apps (DeviceManagementManagedDevices.Read.All): beide
# gehoeren nicht zu dem, was Paketieren und Bereitstellen braucht, und werden deshalb bei der
# Anmeldung bewusst nicht angefordert.
function Connect-OptionalGraphScope {
  param(
    [Parameter(Mandatory)][string[]]$Scope,
    [string]$TextKey = 'GroupLookupConsentDialog',
    # Fuer den Weg ueber die Einstellung "direkt mit erhoehten Rechten anmelden": der Benutzer hat
    # die Frage dort schon beantwortet, hier darf kein Dialog mehr aufgehen - und ein Fehlschlag
    # ist kein Grund fuer eine Meldung, weil die Anwendung ohne diese Berechtigungen weiterlaeuft.
    [switch]$NoPrompt
  )
  # Mehrere Berechtigungen in EINEM Anmeldevorgang: zwei Fenster hintereinander waeren bei der
  # Anmeldung zwei Unterbrechungen fuer dieselbe Entscheidung.
  $scope = @($Scope | Where-Object { $_ }) -join ' '
  $context = $null
  try { $context = Get-MgContext -ErrorAction SilentlyContinue } catch { $context = $null }
  $tenantDomain = $script:currentUserUpn.Split('@')[1]
  # Die Berechtigung darf mit einem ANDEREN Konto erteilt worden sein - beim Dienstleister liegen die
  # Administratorrechte regelmaessig auf einem zweiten Konto. Die frueher hier stehende Bedingung
  # verlangte, dass die Graph-Sitzung auf demselben Konto laeuft wie die Tenant-Verbindung; nach dem
  # Weg "anderes Konto" traf das nie zu, und der Zustimmungsdialog erschien bei JEDER Suche erneut.
  # Gemerkt wird deshalb pro Tenant-Domaene, dass die Zustimmung dort schon erteilt wurde; die
  # Sitzung selbst muss den Scope aber weiterhin wirklich tragen.
  # Gemerkt wird je Tenant UND je Berechtigung - "Gruppen darf ich lesen" sagt nichts darueber, ob
  # auch erkannte Apps erlaubt sind.
  $memoryKey = ("{0}|{1}" -f $tenantDomain, $scope)
  $wanted = @($Scope | Where-Object { $_ })
  $hasAll = $true
  foreach ($s in $wanted) { if (-not ($context -and ($context.Scopes -contains $s))) { $hasAll = $false } }
  $granted = ($hasAll -and
              ([bool]$script:groupLookupGranted[$memoryKey] -or ($context -and $context.Account -eq $script:currentUserUpn)))
  if ($granted) { return $true }
  # Ein "Abbrechen" wird pro Tenant-Domaene gemerkt, damit nicht jeder Klick erneut fragt. Ein
  # frueheres Ja fuehrt hingegen wieder durch die Auswahl: das Konto kann sich geaendert haben, und
  # genau dort steht die Wahl "anderes Konto".
  if ($script:groupLookupConsent.ContainsKey($memoryKey) -and -not $script:groupLookupConsent[$memoryKey]) {
    Update-Status (Get-UiString 'GroupLookupDeclinedStatus')
    return $false
  }

  $choice = if ($NoPrompt) { 'self' } else { Show-GraphScopeConsentDialog -TextKey $TextKey }
  if ($choice -eq 'cancel') {
    $script:groupLookupConsent[$memoryKey] = $false
    Update-Status (Get-UiString 'GroupLookupDeclinedStatus')
    return $false
  }
  $script:groupLookupConsent[$memoryKey] = $true

  if ($choice -eq 'other') {
    # Nur die Caches der Graph-PowerShell, NICHT 'WinTuner-PowerShell*': sonst waere die
    # Tenant-Verbindung der Anwendung gleich mit weg, und die Gruppensuche haette den Anwender
    # ausgeloggt, um eine Leseberechtigung zu holen.
    try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch { }   # class 3
    $removed = 0
    $names = @()
    try {
      $cacheDir = Join-Path $env:LOCALAPPDATA '.IdentityService'
      # Welche Datei die Graph-PowerShell benutzt, haengt von ihrer Version ab ('mg.msal.cache' in
      # aelteren, die gemeinsame 'msal.cache' in neueren). Deshalb beide - und die Namen ins
      # Protokoll, damit hinterher nachvollziehbar ist, was geleert wurde. 'WinTuner-PowerShell*'
      # steht bewusst NICHT dabei: das ist die Tenant-Sitzung der Anwendung.
      $names = @(Get-ChildItem -LiteralPath $cacheDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'mg.msal.cache*' -or $_.Name -like 'msal.cache*' } |
        ForEach-Object { $_.Name })
      $removed = Remove-TokenCacheFiles -Directory $cacheDir -Patterns @('mg.msal.cache*', 'msal.cache*')
    } catch { Write-LogDebug 'graph cache clear' }
    Write-Log ("Group lookup: cleared {0} Graph PowerShell token cache file(s) [{1}] so the sign-in asks which account to use. The WinTuner token cache was left alone, so the tenant connection stays; other Microsoft tools sharing that cache may ask to sign in again." -f `
      $removed, $(if ($names.Count) { $names -join ', ' } else { 'none' }))
    Update-Status (Get-UiString 'GroupLookupOtherAccountStatus')
  }

  try {
    Update-Status (Get-UiString 'GroupLookupAuthStatus')
    $null = Connect-MgGraph -TenantId $tenantDomain -Scopes $wanted -NoWelcome -ErrorAction Stop *>&1
    $ctx = try { Get-MgContext -ErrorAction SilentlyContinue } catch { $null }
    $script:groupLookupGranted[$memoryKey] = $true
    Write-Log ("Optional Graph scope(s) granted: {0} (account {1}, app id {2})." -f ($wanted -join ', '), `
      $(if ($ctx) { [string]$ctx.Account } else { '?' }), $(if ($ctx) { [string]$ctx.ClientId } else { '?' }))
    return $true
  } catch {
    $failure = [string]$_.Exception.Message
    # Ein FEHLGESCHLAGENER Versuch ist kein "Nein": vielleicht war das falsche Konto gewaehlt.
    # Der Merker wird deshalb entfernt statt auf $false gesetzt - der naechste Klick fragt wieder,
    # und dort steht die Wahl "anderes Konto". Nur ein ausdrueckliches Abbrechen sperrt die Sitzung.
    [void]$script:groupLookupConsent.Remove($memoryKey)
    # "Darf nicht selbst zustimmen" ist kein Fehler des Werkzeugs und keine Netzstoerung. AADSTS65001
    # = noch keine Zustimmung erteilt, AADSTS90094 = Zustimmung braucht einen Administrator.
    $needsAdmin = ($failure -match 'AADSTS90094' -or $failure -match 'AADSTS65001' -or
                   $failure -match '(?i)admin(istrator)?\s+(approval|consent)' -or $failure -match '(?i)consent_required')
    if ($NoPrompt) {
      # Bei der Anmeldung angefordert: nur protokollieren. Wer die Berechtigung spaeter wirklich
      # braucht, bekommt an dieser Stelle den ausfuehrlichen Dialog.
      Write-Log ("Optional Graph scope(s) {0} could not be obtained at sign-in ({1}). The application continues without them; they are requested again when a feature actually needs them." -f ($wanted -join ', '), $failure)
      return $false
    }
    if ($needsAdmin) {
      Write-Log ("Group lookup: this account may not grant Group.Read.All itself. An administrator has to consent to it for the app 'Microsoft Graph Command Line Tools'. Detail: {0}" -f $failure)
      [void][System.Windows.Forms.MessageBox]::Show(
        ((Get-UiString 'GroupLookupAdminNeededDialog') -f $failure),
        (Get-UiString 'GroupLookupConsentTitle'),
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information)
    } else {
      Write-Log ("Group name lookup could not obtain Group.Read.All: {0}" -f $failure)
      [void][System.Windows.Forms.MessageBox]::Show(
        ((Get-UiString 'GroupLookupDeniedDialog') -f $failure),
        (Get-UiString 'GroupLookupConsentTitle'),
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning)
    }
    return $false
  }
}

# Liest die erkannten Apps des Tenants, paginiert. Zwei Wege, eine Stelle:
#   - mit dem Token der Anwendung (Standard): dasselbe Token wie fuer alles andere, kein zweiter
#     Anmeldevorgang. Fehlt die Berechtigung, antwortet Graph mit 403 - der Aufrufer faengt das.
#   - ueber die Graph-PowerShell-Sitzung (-UseGraphSession): nach einer erteilten Zustimmung, die
#     ausdruecklich fuer diese Liste geholt wurde.
function Get-TenantDetectedApps {
  param(
    [hashtable]$Headers,
    [switch]$UseGraphSession,
    [int]$MaxPages = 100
  )
  $uri = 'https://graph.microsoft.com/beta/deviceManagement/detectedApps?$top=500&$orderby=deviceCount desc'
  $out = [System.Collections.Generic.List[object]]::new()
  $pageCount = 0
  do {
    $response = if ($UseGraphSession) {
      Invoke-MgGraphRequest -Method GET -Uri $uri -ErrorAction Stop
    } else {
      Invoke-RestMethod -Uri $uri -Method GET -Headers $Headers -ErrorAction Stop
    }
    $values = if ($UseGraphSession) { @($response['value']) } else { @($response.value) }
    if ($values -and $values.Count -gt 0) { $out.AddRange([object[]]$values) }
    $uri = if ($UseGraphSession) { [string]$response['@odata.nextLink'] } else { [string]$response.'@odata.nextLink' }
    $pageCount++
    if ($pageCount -ge $MaxPages) {
      Write-Log ("Warning: Graph API pagination limit ({0} pages) reached. Some detected apps may not be shown." -f $MaxPages)
      break
    }
  } while ($uri)
  Write-Log ("Detected apps read: {0} entr(y/ies) over {1} page(s) via {2}." -f $out.Count, $pageCount, $(if ($UseGraphSession) { 'the Graph PowerShell session' } else { 'the WinTuner token' }))
  return @($out.ToArray())
}

# Die Gruppensuche fragt genau eine Berechtigung ab - der Aufrufer bleibt dadurch lesbar.
function Connect-GroupLookupScope {
  return (Connect-OptionalGraphScope -Scope 'Group.Read.All' -TextKey 'GroupLookupConsentDialog')
}

# Die zwei optionalen Leseberechtigungen auf einmal, direkt bei der Anmeldung - fuer die Einstellung
# "mit erhoehten Rechten anmelden". Danach zeigen Zuweisungen sofort Gruppennamen und die erkannten
# Apps laden ohne Nachfrage. Ohne die Einstellung passiert hier nichts: beide werden weiterhin erst
# angefordert, wenn sie wirklich gebraucht werden.
$script:loginScopes = @('Group.Read.All', 'DeviceManagementManagedDevices.Read.All')
function Request-LoginTimeScopes {
  if (-not $script:settings.RequestOptionalScopesOnLogin) { return $false }
  if ([string]::IsNullOrWhiteSpace([string]$script:currentUserUpn)) { return $false }
  Update-Status (Get-UiString 'ElevatedLoginRequestingStatus')
  [System.Windows.Forms.Application]::DoEvents()
  $ok = Connect-OptionalGraphScope -Scope $script:loginScopes -NoPrompt
  if ($ok) {
    Update-Status ((Get-UiString 'ElevatedLoginGrantedStatus') -f ($script:loginScopes -join ', '))
  } else {
    Update-Status (Get-UiString 'ElevatedLoginFailedStatus')
  }
  return $ok
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
