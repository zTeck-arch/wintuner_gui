# Zwei Anliegen aus derselben Rückmeldung:
#
#   1. „Welche Einstellungen sind lokal gesetzt?" — ohne diese Auskunft ist ein fremdes Protokoll nur
#      halb lesbar. Der Abdruck gehört ins Protokoll, KundenDATEN aber nicht.
#   2. „Wieso passiert beim Login so viel, obwohl die Update-Prüfung aus ist?" — es war nicht die
#      Update-Suche, sondern die Dashboard-Kachel: drei Tenant-Abfragen, bei leerem Inventar jede
#      mit Gegenprobe und langer Erklärung. Neun Anfragen und drei Absätze für einen Tenant ohne
#      WinTuner-Apps.

BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '10-Settings.ps1' -Name 'Get-SettingsSnapshotLines')))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '25-WinGetData.ps1' -Name @(
    'Get-RawWin32AppsFromGraph', 'Clear-GraphInventoryRawCache', 'Get-Win32AppInventoryViaGraph',
    'Get-PackageIdFromNotes', 'Test-IsSupersededApp'))))
}

Describe 'Abdruck der Einstellungen im Protokoll' {

  BeforeEach {
    $script:demoSettings = @{
      DefaultPackagePath = 'C:\Pakete'; ThemeName = 'Dark'; Language = 'de'
      WindowWidth = 1167; WindowHeight = 1017; WindowMaximized = $false; LogExpanded = $true
      AutoCheckUpdates = $false; RequestOptionalScopesOnLogin = $true; CheckAppUpdateOnStartup = $true
      AutoUpdateFavoritesOnStartup = $false; DashboardUpdatesFullScan = $false
      MoveAssignmentsOnUpdate = $true; AutoRemoveSuperseded = $false; AutoVersionCleanup = $true
      KeepVersionCount = 2; SaveScopeBeforeRemoval = $true
      SuppressChangeConfirmations = $true; ChangeConfirmationRiskAcceptedVersion = '0.16.0'
      ProductionWarningAcceptedVersion = '0.16.0'
      WingetFavorites = @('a', 'b', 'c', 'd')
      RecentLogins = @('admin@kunde.de', 'admin2@kunde.de')
      GroupFavorites = @{ 'kunde.de' = @(@{ Id = '1'; Name = 'Pilot Buchhaltung' }) }
      TenantDisplayNames = @{ 'admin@kunde.de' = 'Kunde GmbH' }
      WingetOverrides = @{ 'Google.Chrome' = @{} }
    }
  }

  It 'nennt die Haken, die beim Anmelden und beim Start von selbst etwas tun' {
    $text = (Get-SettingsSnapshotLines -Settings $script:demoSettings) -join "`n"
    $text | Should -Match 'onLogin: updateSearch=False optionalScopes=True'
    $text | Should -Match 'onStartup: selfUpdateCheck=True favouritesRun=False'
    $text | Should -Match 'dashboardFullScan=False'
  }

  It 'nennt die Einstellungen des Update-Laufs samt Anzahl behaltener Versionen' {
    $text = (Get-SettingsSnapshotLines -Settings $script:demoSettings) -join "`n"
    $text | Should -Match 'moveAssignments=True'
    $text | Should -Match 'versionCleanup=True keepNewest=2'
    $text | Should -Match "confirmations suppressed=True \(accepted for version '0\.16\.0'\)"
  }

  It 'schreibt KEINE Kundendaten - nur Anzahlen' {
    $text = (Get-SettingsSnapshotLines -Settings $script:demoSettings) -join "`n"
    # Adressen, Kundennamen und Gruppennamen sind Kundendaten; das Protokoll wird weitergegeben.
    $text | Should -Not -Match 'admin@kunde\.de'
    $text | Should -Not -Match 'Kunde GmbH'
    $text | Should -Not -Match 'Pilot Buchhaltung'
    $text | Should -Match 'favourites=4 recentLogins=2 groupFavouriteTenants=1 tenantDisplayNames=1 wingetOverrides=1'
  }

  It 'nennt Pfade vollstaendig - ein halber Pfad hat noch nie einen Fehler erklaert' {
    $text = (Get-SettingsSnapshotLines -Settings $script:demoSettings -SettingsPath 'C:\S\settings.json' -LogFolder 'C:\S\logs' -RetentionWeeks 4) -join "`n"
    $text | Should -Match 'file=C:\\S\\settings\.json'
    $text | Should -Match 'packageFolder=C:\\Pakete'
    $text | Should -Match 'logFolder=C:\\S\\logs \| logRetentionWeeks=4'
  }

  It 'kommt mit fehlenden Schluesseln aus (Einstellungsdatei aus einer aelteren Fassung)' {
    { Get-SettingsSnapshotLines -Settings @{ ThemeName = 'Light' } } | Should -Not -Throw
    (Get-SettingsSnapshotLines -Settings @{ ThemeName = 'Light' }) -join "`n" | Should -Match 'theme=Light'
  }

  It 'sagt es, wenn gar keine Einstellungen geladen sind' {
    (Get-SettingsSnapshotLines -Settings $null) -join "`n" | Should -Match 'no settings loaded'
  }

  It 'wird beim Start UND nach dem Speichern geschrieben' {
    (Get-SourcePartText -Part '90-Main.ps1') | Should -Match 'foreach \(\$line in \(Get-SettingsSnapshotLines\)\) \{ Write-Log \$line \}'
    (Get-SourcePartText -Part '85-Rows.ps1') | Should -Match "Get-SettingsSnapshotLines -Prefix 'Settings saved'"
  }
}

Describe 'Weniger Schritte beim Anmelden' {

  BeforeEach {
    $script:graphInventoryRawSeconds = 30
    Clear-GraphInventoryRawCache
    $global:TestGraphPages = 0
    Set-Item -Path function:global:Get-WtToken -Value { 'token' }
    Set-Item -Path function:global:Invoke-RestMethod -Value {
      param($Uri, $Method, $Headers, $ErrorAction)
      $global:TestGraphPages++
      return [pscustomobject]@{ value = @(
        [pscustomobject]@{ id = 'a'; '@odata.type' = '#microsoft.graph.win32LobApp'; displayName = 'App A'
                           displayVersion = '1.0'; notes = '[WinTuner|winget|App.A]'; supersedingAppCount = 0; isAssigned = $true },
        [pscustomobject]@{ id = 'b'; '@odata.type' = '#microsoft.graph.win32LobApp'; displayName = 'App B'
                           displayVersion = '0.9'; notes = '[WinTuner|winget|App.B]'; supersedingAppCount = 1; isAssigned = $false },
        [pscustomobject]@{ id = 'c'; '@odata.type' = '#microsoft.graph.win32LobApp'; displayName = 'Handarbeit'
                           displayVersion = '1'; notes = ''; supersedingAppCount = 0; isAssigned = $true }
      ) }
    }
  }

  It 'liest die App-Liste fuer aktiv UND abgeloest nur einmal aus dem Netz' {
    # Bei jeder Dashboard-Aktualisierung mit leerem Modul-Ergebnis wurde derselbe Durchlauf zweimal
    # gemacht - bei einem grossen Tenant zweimal neun Seiten.
    @(Get-Win32AppInventoryViaGraph).Count | Should -Be 1                 # nur App A ist aktiv
    @(Get-Win32AppInventoryViaGraph -Superseded).Count | Should -Be 1     # nur App B ist abgeloest
    $global:TestGraphPages | Should -Be 1
  }

  It 'laesst die handgebaute App aussen vor - die traegt keine WinTuner-Marke' {
    @(Get-Win32AppInventoryViaGraph | ForEach-Object { $_.Name }) | Should -Be @('App A')
  }

  It 'liest nach einem Tenant-Wechsel wieder frisch' {
    [void](Get-Win32AppInventoryViaGraph)
    Clear-GraphInventoryRawCache
    [void](Get-Win32AppInventoryViaGraph)
    $global:TestGraphPages | Should -Be 2
  }

  It 'fragt ohne Apps im Umfang nicht nach gekennzeichneten Updates' {
    # Der dritte Schritt beim Anmelden: eine Abfrage, deren Antwort ohne Apps zwingend 0 ist.
    # Seit die Suche auch unmarkierte Win32-Apps prueft, entscheidet nicht mehr $all darueber,
    # sondern $scanScope - $all waere hier zu klein und wuerde die Abfrage auslassen, obwohl es
    # sehr wohl Apps gibt, die ein Update haben koennen.
    $fn = Get-SourceFunctionText -Part '80-Views.ps1' -Name 'Refresh-Dashboard'
    $fn | Should -Match 'if \(\$scanScope\.Count -eq 0\) \{'
    $fn | Should -Match 'skipping the update query'
  }

  It 'zaehlt die Kachel ueber denselben Umfang, den die Update-Suche prueft' {
    # Kachel und Suche haben schon einmal zwei verschiedene Fragen mit demselben Wort beantwortet -
    # dafuer gibt es Measure-AvailableUpdates ueberhaupt. Wird hier wieder $all uebergeben, zeigt die
    # Kachel weniger als die Suche findet, und das liest sich wie ein Fehler in der Suche.
    $fn = Get-SourceFunctionText -Part '80-Views.ps1' -Name 'Refresh-Dashboard'
    $fn | Should -Match '\$scanScope = if \(\$script:settings\.DashboardUpdatesFullScan\) \{ @\(Get-ScanInventory -ManagedApps \$all\) \}'
    $fn | Should -Match 'Measure-AvailableUpdates -Apps \$scanScope'
  }

  It 'erklaert ein leeres Inventar einmal ausfuehrlich, danach in einer Zeile' {
    $fn = Get-SourceFunctionText -Part '25-WinGetData.ps1' -Name 'Get-Win32AppsResilient'
    # Der Merker muss die Entscheidung TRAGEN, nicht nur irgendwo vorkommen - die erste Fassung
    # dieser Regel blieb gruen, als der Merker aus der Bedingung genommen wurde (gegengeprueft).
    $fn | Should -Match 'elseif \(-not \$script:emptyInventoryExplained\)'
    $fn | Should -Match '\$script:emptyInventoryExplained = \$true'
    $fn | Should -Match 'Said once per session'
  }
}
