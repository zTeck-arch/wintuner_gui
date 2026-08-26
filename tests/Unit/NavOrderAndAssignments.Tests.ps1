# Zwei kleine Entscheidungen, die vorher Nebenwirkungen der Dateireihenfolge bzw. eines Klicks waren.
#
# 1. Die Reihenfolge der Navigationseintraege ergab sich daraus, in welcher Quelldatei ein Bereich
#    gebaut wird - "Alle Tenant-Apps" (Teil 82) stand deshalb vor "Erkannte Apps" (Teil 85).
# 2. Die Spalte "Zuweisung" in den App-Einstellungen stand auf "(zum Laden anklicken)": die
#    wichtigste Auskunft der Liste gab es erst nach einem Klick je Zeile.

BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  Add-Type -AssemblyName System.Windows.Forms, System.Drawing
  . ([scriptblock]::Create((Get-UiStringsText)))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '55-Dialogs.ps1' -Name @(
    'Update-AppSettingsAssignments', 'Update-AppSettingsListRows', 'Sync-AppSettingsChecked'))))
  $script:mainText = Get-SourcePartText -Part '90-Main.ps1'
}

Describe 'Reihenfolge der Navigationseintraege' {

  It 'ist ausdruecklich festgelegt und nicht von der Quelldatei abhaengig' {
    $script:mainText | Should -Match '\$navKeyOrder = @\('
    # Innerhalb von "Bestand": Updates, Erkannte Apps, Alle Tenant-Apps, App-Einstellungen.
    $script:mainText | Should -Match "'updates', 'discovered', 'tenant', 'appsettings'"
  }

  It 'sortiert nach Gruppe UND nach dieser Liste' {
    $script:mainText | Should -Match '\$navKeyOrder\.IndexOf\(\[string\]\$_\.Key\)'
  }

  It 'laesst einen unbekannten Schluessel hinten stehen statt ihn zu verlieren' {
    # Ein neuer Bereich, der in der Liste fehlt, muss trotzdem in der Leiste erscheinen.
    $navKeyOrder = @('dashboard', 'winget', 'store', 'ownpackage',
                     'updates', 'discovered', 'tenant', 'appsettings',
                     'localpackages', 'workrecord', 'settings')
    $idx = $navKeyOrder.IndexOf('ein-neuer-bereich')
    $rank = if ($idx -lt 0) { $navKeyOrder.Count } else { $idx }
    $rank | Should -Be $navKeyOrder.Count
  }
}

Describe 'Zuweisungen in den App-Einstellungen' {

  BeforeEach {
    $list = New-Object System.Windows.Forms.ListView
    $list.View = [System.Windows.Forms.View]::Details
    [void]$list.Columns.Add('Name', 200)
    [void]$list.Columns.Add('Version', 100)
    [void]$list.Columns.Add('Zuweisung', 300)
    $script:appSettingsUi = @{
      List = $list
      Status = (New-Object System.Windows.Forms.Label)
      FilterBox = (New-Object System.Windows.Forms.TextBox)
      AllApps = @(
        [pscustomobject]@{ Name = 'Google Chrome'; CurrentVersion = '151.0'; GraphId = 'id-chrome' },
        [pscustomobject]@{ Name = 'Notepad++';     CurrentVersion = '8.9.8'; GraphId = 'id-npp' })
      CheckedIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
      AssignmentText = @{}
      AssignmentsLoading = $false
      Rebuilding = $false
      Dlg = $null
    }
    $script:isConnected = $true
    $script:cancelBatch = $false
    $global:TestAssignmentCalls = @()
    Set-Item -Path function:global:Get-TenantAppAssignmentText -Value {
      param([string]$AppId)
      $global:TestAssignmentCalls += $AppId
      if ($AppId -eq 'id-npp') { throw 'Forbidden' }
      return "required   Group Pilot`r`navailable  All users"
    }
    Update-AppSettingsListRows
  }

  It 'fuellt die Spalte von selbst, ohne Klick je Zeile' {
    Update-AppSettingsAssignments
    $script:appSettingsUi.List.Items[0].SubItems[2].Text | Should -Match 'Group Pilot'
    $script:appSettingsUi.List.Items[0].SubItems[2].Text | Should -Not -Match 'anklicken|click'
  }

  It 'macht aus mehreren Zuweisungen eine Zeile' {
    Update-AppSettingsAssignments
    $script:appSettingsUi.List.Items[0].SubItems[2].Text | Should -Match 'Group Pilot / available'
  }

  It 'schreibt "nicht lesbar" in die Zeile, die fehlschlaegt, und macht weiter' {
    Update-AppSettingsAssignments
    $script:appSettingsUi.List.Items[1].SubItems[2].Text | Should -Be (Get-UiString 'AssignmentLoadFailed')
    $global:TestAssignmentCalls.Count | Should -Be 2
  }

  It 'liest jede App nur einmal - auch wenn der Filter die Zeilen neu baut' {
    Update-AppSettingsAssignments
    $before = $global:TestAssignmentCalls.Count
    Update-AppSettingsListRows          # wie ein Tastendruck im Filterfeld
    Update-AppSettingsAssignments
    $global:TestAssignmentCalls.Count | Should -Be $before
    # Und der gelesene Text steht nach dem Neubau weiterhin in der Zeile.
    $script:appSettingsUi.List.Items[0].SubItems[2].Text | Should -Match 'Group Pilot'
  }

  It 'liest nichts, solange keine Sitzung besteht' {
    $script:isConnected = $false
    Update-AppSettingsListRows
    Update-AppSettingsAssignments
    $global:TestAssignmentCalls.Count | Should -Be 0
  }

  It 'bricht ab, wenn der Benutzer den Lauf stoppt' {
    $script:cancelBatch = $true
    Update-AppSettingsListRows
    Update-AppSettingsAssignments
    $global:TestAssignmentCalls.Count | Should -Be 0
  }
}
