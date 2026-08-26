# Drei Rückmeldungen aus derselben Runde: das Fenster soll sich nach dem Bildschirm richten, die
# Liste der abgelösten Versionen war zu klein (zwei sichtbare Zeilen von sechs Einträgen), und die
# optionalen Leseberechtigungen sollen sich schon bei der Anmeldung holen lassen.

BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  Add-Type -AssemblyName System.Windows.Forms, System.Drawing
  . ([scriptblock]::Create((Get-UiStringsText)))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '75-UiState.ps1' -Name 'Get-InitialWindowSize')))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '85-Rows.ps1' -Name @(
    'Get-SupersededCardHeight', 'Update-SupersededListState'))))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '82-TenantApps.ps1' -Name 'Request-LoginTimeScopes')))
}

Describe 'Get-InitialWindowSize' {

  It 'nimmt beim ersten Start 80 % der Arbeitsflaeche' {
    $s = Get-InitialWindowSize -WorkWidth 3840 -WorkHeight 2160
    $s.Width  | Should -Be 3072
    $s.Height | Should -Be 1728
    $s.Source | Should -Be 'screen'
  }

  It 'faellt nie unter die Entwurfsgroesse, solange der Schirm sie hergibt' {
    # 80 % von 1600x1000 waeren 1280x800 - unter den 850 px, fuer die die Kacheln entworfen sind.
    $s = Get-InitialWindowSize -WorkWidth 1600 -WorkHeight 1000
    $s.Width  | Should -Be 1280
    $s.Height | Should -Be 850
  }

  It 'passt auf einen kleinen Schirm, ohne unter das Minimum zu fallen' {
    $s = Get-InitialWindowSize -WorkWidth 1366 -WorkHeight 728
    $s.Width  | Should -Be 1093      # 80 % von 1366 - passt, also keine Begrenzung noetig
    $s.Height | Should -Be 720       # 80 % waeren 582; die Entwurfshoehe 850 passt nicht, also
                                     # Arbeitsflaeche minus 8 px Luft
    # Und niemals kleiner als das Fenster-Minimum, auch auf einem winzigen Schirm nicht.
    $tiny = Get-InitialWindowSize -WorkWidth 800 -WorkHeight 600
    $tiny.Width  | Should -Be 1010
    $tiny.Height | Should -Be 680
  }

  It 'laesst eine gespeicherte Groesse gewinnen' {
    $s = Get-InitialWindowSize -WorkWidth 3840 -WorkHeight 2160 -SavedWidth 1200 -SavedHeight 900
    $s.Width  | Should -Be 1200
    $s.Height | Should -Be 900
    $s.Source | Should -Be 'settings'
  }

  It 'ignoriert eine gespeicherte Groesse unter dem Minimum' {
    # So etwas steht in Einstellungsdateien aus aelteren Fassungen - und wuerde die vierte
    # Dashboard-Kachel abschneiden.
    $s = Get-InitialWindowSize -WorkWidth 1920 -WorkHeight 1080 -SavedWidth 940 -SavedHeight 600
    $s.Source | Should -Be 'screen'
    $s.Width  | Should -Be 1536
  }
}

Describe 'Hoehe der Karte "Abgeloeste Versionen"' {

  BeforeEach {
    $script:supersededRowsMin = 3
    $script:supersededRowsWithContent = 5
    $script:supersededRowsMax = 10
    $global:supersededListBox = New-Object System.Windows.Forms.CheckedListBox
    Set-Variable -Name supersededListBox -Scope Script -Value $global:supersededListBox
  }

  It 'bleibt im Leerzustand klein, damit die Update-Liste den Platz bekommt' {
    (Get-SupersededCardHeight) | Should -Be (72 + 3 * 18 + 4 + 10 + 30 + 16)
  }

  It 'zeigt bei Inhalt mindestens fuenf Zeilen - gemeldet waren zwei von sechs' {
    foreach ($n in 1..2) { [void]$supersededListBox.Items.Add("App $n") }
    (Get-SupersededCardHeight) | Should -Be (72 + 5 * 18 + 4 + 10 + 30 + 16)
  }

  It 'waechst mit dem Inhalt' {
    foreach ($n in 1..7) { [void]$supersededListBox.Items.Add("App $n") }
    (Get-SupersededCardHeight) | Should -Be (72 + 7 * 18 + 4 + 10 + 30 + 16)
  }

  It 'hoert bei zehn Zeilen auf, damit die Karte nicht die Sektion frisst' {
    foreach ($n in 1..40) { [void]$supersededListBox.Items.Add("App $n") }
    (Get-SupersededCardHeight) | Should -Be (72 + 10 * 18 + 4 + 10 + 30 + 16)
  }
}

Describe 'Nach dem Fuellen wird neu angeordnet' {

  BeforeEach {
    $global:supersededListBox = New-Object System.Windows.Forms.CheckedListBox
    Set-Variable -Name supersededListBox -Scope Script -Value $global:supersededListBox
    $global:supersededEmptyLabel = New-Object System.Windows.Forms.Label
    Set-Variable -Name supersededEmptyLabel -Scope Script -Value $global:supersededEmptyLabel
    foreach ($n in @('supersededCheckAllButton','supersededUncheckAllButton','deleteSelectedAppButton')) {
      Set-Variable -Name $n -Scope Global -Value (New-Object System.Windows.Forms.Button)
      Set-Variable -Name $n -Scope Script -Value (Get-Variable -Name $n -Scope Global -ValueOnly)
    }
    Set-Item -Path function:global:Set-ListEmptyText -Value { param($Label, $NormalKey) }
    $global:TestLayoutCalls = 0
    Set-Item -Path function:global:Update-UpdatesLayout -Value { $global:TestLayoutCalls++ }
  }

  It 'rechnet die Kartenhoehe neu, sobald Eintraege da sind' {
    # Der eigentliche Fehler: die Karte behielt die Hoehe des Leerzustands, weil nach dem Fuellen
    # niemand die Anordnung anstiess. Von sechs gefundenen Apps waren zwei zu sehen.
    foreach ($n in 1..6) { [void]$supersededListBox.Items.Add("App $n") }
    Update-SupersededListState
    $global:TestLayoutCalls | Should -Be 1
  }

  It 'schaltet die Knoepfe nach dem Inhalt' {
    Update-SupersededListState
    $script:deleteSelectedAppButton.Enabled | Should -BeFalse
    [void]$supersededListBox.Items.Add('App 1')
    Update-SupersededListState
    $script:deleteSelectedAppButton.Enabled | Should -BeTrue
  }
}

Describe 'Anmeldung mit erhoehten Rechten' {

  BeforeEach {
    $script:settings = @{ RequestOptionalScopesOnLogin = $false }
    $script:currentUserUpn = 'admin@kunde.de'
    $script:loginScopes = @('Group.Read.All', 'DeviceManagementManagedDevices.Read.All')
    $global:TestScopeCalls = @()
    Set-Item -Path function:global:Connect-OptionalGraphScope -Value {
      param([string[]]$Scope, [string]$TextKey, [switch]$NoPrompt)
      $global:TestScopeCalls += [pscustomobject]@{ Scope = @($Scope); NoPrompt = [bool]$NoPrompt }
      return $true
    }
  }

  It 'fragt nichts an, solange die Einstellung aus ist' {
    Request-LoginTimeScopes | Should -BeFalse
    $global:TestScopeCalls.Count | Should -Be 0
  }

  It 'holt beide Berechtigungen in EINEM Anmeldevorgang, ohne Dialog' {
    $script:settings.RequestOptionalScopesOnLogin = $true
    Request-LoginTimeScopes | Should -BeTrue
    $global:TestScopeCalls.Count | Should -Be 1
    $global:TestScopeCalls[0].Scope | Should -Be @('Group.Read.All', 'DeviceManagementManagedDevices.Read.All')
    $global:TestScopeCalls[0].NoPrompt | Should -BeTrue
    $global:TestStatus | Should -Match 'erteilt|granted'
  }

  It 'fragt ohne Anmeldung gar nicht' {
    $script:settings.RequestOptionalScopesOnLogin = $true
    $script:currentUserUpn = ''
    Request-LoginTimeScopes | Should -BeFalse
    $global:TestScopeCalls.Count | Should -Be 0
  }

  It 'bleibt bei einem Fehlschlag folgenlos und sagt es nur' {
    $script:settings.RequestOptionalScopesOnLogin = $true
    Set-Item -Path function:global:Connect-OptionalGraphScope -Value { param([string[]]$Scope, [string]$TextKey, [switch]$NoPrompt) $false }
    Request-LoginTimeScopes | Should -BeFalse
    $global:TestStatus | Should -Be (Get-UiString 'ElevatedLoginFailedStatus')
  }
}

Describe 'Der Weg mit -NoPrompt oeffnet keinen Dialog' {

  It 'ruft Show-GraphScopeConsentDialog nur ohne -NoPrompt' {
    $fn = Get-SourceFunctionText -Part '82-TenantApps.ps1' -Name 'Connect-OptionalGraphScope'
    $fn | Should -Match "if \(\`$NoPrompt\) \{ 'self' \} else \{ Show-GraphScopeConsentDialog"
    # Und ein Fehlschlag darf in diesem Weg keine MessageBox zeigen.
    $fn | Should -Match 'if \(\$NoPrompt\) \{[\s\S]{0,400}return \$false'
  }
}
