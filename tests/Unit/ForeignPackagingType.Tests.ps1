#requires -Version 7
# Eine Fassung, die schon im Tenant liegt - aber als Paketierungstyp, den diese Anwendung nicht baut.
#
# Gemeldet am 09.09.2026 aus einem echten Fenster: die Update-Liste bot
# "Google Chrome 151.0.7922.72 -> 153.0.8010.37, neu anzulegen" an, waehrend im Tenant eine
# ZUGEWIESENE "Windows MSI line-of-business"-Fassung 152.0.7977.83 lag. Ein Lauf haette eine dritte
# Fassung gebaut, die niemand zugewiesen bekommt - die Geraete behalten die MSI.
#
# Ursache: die Auswahl des Inventars verwirft JEDEN Typ ausser win32LobApp. Der Rohbestand kennt
# alle Typen (die Protokollzeile sagt "app object(s) of any type"), aber niemand sah hin.
#
# Aktualisiert wird weiterhin nur Win32 - die andere Fassung wird nie angefasst. Neu ist, dass sie
# GESEHEN, in der Zeile genannt und vor dem Lauf gefragt wird.

BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-UiStringsText)))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '20-Version.ps1' -Name @(
    'Test-IsNewerVersion', 'Get-ComparableVersionParts', 'Get-MobileAppTypeLabel'))))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '25-WinGetData.ps1' -Name @(
    'Get-NonWin32AppIndex', 'Find-NonWin32NewerVersion'))))
  # Die Rueckfrage selbst steht seit 0.19.1 nicht mehr hier: sie ist mit den beiden anderen nicht
  # wegdrueckbaren Fragen zu EINER zusammengefasst (RiskyRunConfirm.Tests.ps1). Diese Datei prueft
  # den Weg dorthin - Index, Vergleich, Merker, Gruppierung.
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '70-Runtime.ps1' -Name @(
    'Get-RunRiskFindings'))))
  $script:runRiskClasses = @('protected', 'fuzzy', 'foreign')

  function New-RawApp {
    param([string]$Name, [string]$Version, [string]$Type, [bool]$Assigned = $false, [string]$Id = '')
    if (-not $Id) { $Id = [guid]::NewGuid().ToString() }
    [pscustomobject]@{
      'id' = $Id; 'displayName' = $Name; 'displayVersion' = $Version
      '@odata.type' = $Type; 'isAssigned' = $Assigned; 'notes' = ''
    }
  }

  # Der gemeldete Tenant, auf die relevanten Zeilen verkuerzt.
  $script:rawReported = @(
    (New-RawApp -Name 'Google Chrome' -Version '150.0.7871.125' -Type '#microsoft.graph.win32LobApp'),
    (New-RawApp -Name 'Google Chrome' -Version '151.0.7922.72'  -Type '#microsoft.graph.win32LobApp'),
    (New-RawApp -Name 'Google Chrome' -Version '152.0.7977.83'  -Type '#microsoft.graph.windowsMobileMSI' -Assigned $true -Id 'msi-chrome'),
    (New-RawApp -Name 'WatchGuard Mobile VPN with SSL client' -Version '2026.2.1' -Type '#microsoft.graph.win32LobApp' -Assigned $true),
    (New-RawApp -Name 'Adobe Acrobat Reader DC' -Version '' -Type '#microsoft.graph.winGetApp' -Assigned $true),
    (New-RawApp -Name 'Intranet' -Version '' -Type '#microsoft.graph.windowsWebApp' -Assigned $true)
  )
}

Describe 'Get-NonWin32AppIndex' {
  It 'nimmt die MSI-Fassung auf und laesst Win32 weg' {
    # Win32 gehoert in die andere Auswahl (Select-UnmanagedWin32Apps); hier ist genau das Gegenteil
    # gesucht.
    $index = Get-NonWin32AppIndex -RawApps $script:rawReported
    $index.ContainsKey('google chrome') | Should -BeTrue
    @($index['google chrome']).Count | Should -Be 1
    @($index['google chrome'])[0].Version | Should -Be '152.0.7977.83'
    @($index['google chrome'])[0].IsAssigned | Should -BeTrue
    # Die reine Win32-App darf keinen Eintrag haben.
    $index.ContainsKey('watchguard mobile vpn with ssl client') | Should -BeFalse
  }

  It 'benennt den Typ lesbar' {
    $index = Get-NonWin32AppIndex -RawApps $script:rawReported
    @($index['google chrome'])[0].TypeLabel | Should -Be 'MSI'
  }

  It 'laesst Fassungen OHNE Versionsangabe weg' {
    # Store- und Web-Apps tragen meist keine Version. Ohne Version ist kein Vergleich moeglich, und
    # eine Warnung, die nichts sagen kann, erzieht zum Wegklicken.
    $index = Get-NonWin32AppIndex -RawApps $script:rawReported
    $index.ContainsKey('adobe acrobat reader dc') | Should -BeFalse
    $index.ContainsKey('intranet') | Should -BeFalse
  }

  It 'vertraegt einen leeren Rohbestand' {
    @((Get-NonWin32AppIndex -RawApps @()).Keys).Count | Should -Be 0
    @((Get-NonWin32AppIndex -RawApps $null).Keys).Count | Should -Be 0
  }
}

Describe 'Find-NonWin32NewerVersion' {
  BeforeAll { $script:index = Get-NonWin32AppIndex -RawApps $script:rawReported }

  It 'findet die MSI-Fassung, wenn sie NEUER ist als die Zielversion' {
    # Der gemeldete Fall: Ziel 153.0.8010.37... nein - die MSI 152 ist AELTER als 153. Genau
    # deshalb pruefen die zwei Faelle unten beide Richtungen.
    $hit = Find-NonWin32NewerVersion -Index $script:index -Name 'Google Chrome' -TargetVersion '152.0.7977.10'
    $hit | Should -Not -BeNullOrEmpty
    $hit.Version | Should -Be '152.0.7977.83'
  }

  It 'findet sie auch bei GLEICHER Version - dann wuerde derselbe Stand zweimal im Tenant liegen' {
    $hit = Find-NonWin32NewerVersion -Index $script:index -Name 'Google Chrome' -TargetVersion '152.0.7977.83'
    $hit | Should -Not -BeNullOrEmpty
  }

  It 'meldet NICHTS, wenn die Zielversion neuer ist als die vorhandene Fassung' {
    # Wichtig fuer die Ehrlichkeit der Warnung: ist das Ziel wirklich neuer, ist der Bau richtig
    # und die Frage waere nur Laerm. Im gemeldeten Bild war das Ziel 153.0.8010.37 - also neuer
    # als die MSI-152. Die Doppelung entsteht dort trotzdem, aber sie ist dann eine ABLOESUNG und
    # keine Wiederholung; die Zeile sagt es, die Rueckfrage ebenfalls.
    Find-NonWin32NewerVersion -Index $script:index -Name 'Google Chrome' -TargetVersion '153.0.8010.37' |
      Should -BeNullOrEmpty
  }

  It 'meldet nichts fuer eine App ohne Fassung anderen Typs' {
    Find-NonWin32NewerVersion -Index $script:index -Name 'WatchGuard Mobile VPN with SSL client' -TargetVersion '2026.2.2' |
      Should -BeNullOrEmpty
  }

  It 'vergleicht den Namen ohne Ruecksicht auf Gross-/Kleinschreibung und Leerzeichen' {
    Find-NonWin32NewerVersion -Index $script:index -Name '  GOOGLE chrome ' -TargetVersion '152.0.7977.83' |
      Should -Not -BeNullOrEmpty
  }

  It 'vertraegt leere Angaben' {
    Find-NonWin32NewerVersion -Index $script:index -Name '' -TargetVersion '1.0' | Should -BeNullOrEmpty
    Find-NonWin32NewerVersion -Index $script:index -Name 'Google Chrome' -TargetVersion '' | Should -BeNullOrEmpty
    Find-NonWin32NewerVersion -Index @{} -Name 'Google Chrome' -TargetVersion '1.0' | Should -BeNullOrEmpty
  }

  It 'bevorzugt bei gleicher Version die ZUGEWIESENE Fassung' {
    # Sie ist die, die auf den Geraeten landet - und damit die, die in der Rueckfrage stehen muss.
    $raw = @(
      (New-RawApp -Name 'Tool' -Version '2.0' -Type '#microsoft.graph.windowsMobileMSI' -Id 'unassigned'),
      (New-RawApp -Name 'Tool' -Version '2.0' -Type '#microsoft.graph.winGetApp' -Assigned $true -Id 'assigned')
    )
    $hit = Find-NonWin32NewerVersion -Index (Get-NonWin32AppIndex -RawApps $raw) -Name 'Tool' -TargetVersion '2.0'
    $hit.GraphId | Should -Be 'assigned'
  }

  It 'nimmt die HOECHSTE vorhandene Fassung, nicht die erste gefundene' {
    $raw = @(
      (New-RawApp -Name 'Tool' -Version '2.0' -Type '#microsoft.graph.windowsMobileMSI'),
      (New-RawApp -Name 'Tool' -Version '3.0' -Type '#microsoft.graph.windowsMobileMSI' -Id 'highest'),
      (New-RawApp -Name 'Tool' -Version '2.5' -Type '#microsoft.graph.windowsMobileMSI')
    )
    $hit = Find-NonWin32NewerVersion -Index (Get-NonWin32AppIndex -RawApps $raw) -Name 'Tool' -TargetVersion '1.0'
    $hit.GraphId | Should -Be 'highest'
  }
}

Describe 'New-UpdateCandidateModel: der Merker' {
  BeforeAll {
    . ([scriptblock]::Create((Get-SourceFunctionText -Part '30-UpdateTargets.ps1' -Name 'New-UpdateCandidateModel')))
    function Test-IsProtectedApp { param([string]$Name, $Patterns) return $false }
    $script:settings = @{ ProtectedApps = @() }
  }

  It 'traegt Version, Typ und Zuweisungszustand der anderen Fassung' {
    $foreign = [pscustomobject]@{ Version = '152.0.7977.83'; TypeLabel = 'MSI'; IsAssigned = $true }
    $m = New-UpdateCandidateModel -App ([pscustomobject]@{ Name = 'Google Chrome'; CurrentVersion = '151.0'; GraphId = 'g' }) `
      -LatestVersion '152.0.7977.83' -PackageId 'Google.Chrome' -ForeignNewer $foreign
    $m.HasForeignNewer | Should -BeTrue
    $m.ForeignNewerVersion | Should -Be '152.0.7977.83'
    $m.ForeignNewerType | Should -Be 'MSI'
    $m.ForeignNewerAssigned | Should -BeTrue
  }

  It 'setzt den Merker nicht, wenn es keine andere Fassung gibt' {
    $m = New-UpdateCandidateModel -App ([pscustomobject]@{ Name = 'A'; CurrentVersion = '1'; GraphId = 'g' }) `
      -LatestVersion '2' -PackageId 'X.Y'
    $m.HasForeignNewer | Should -BeFalse
    $m.ForeignNewerVersion | Should -Be ''
  }
}

Describe 'Group-UpdateCandidates traegt den Merker mit' {
  BeforeAll {
    . ([scriptblock]::Create((Get-SourceFunctionText -Part '40-Graph.ps1' -Name 'Group-UpdateCandidates')))
    function Write-Log { param([string]$Message) }
    function Get-AppAssignmentScopeProbe {
      param([string]$AppId, [string]$AppName)
      return @{ Succeeded = $true; Signature = '<none>'; Summary = 'no assignment' }
    }
  }

  It 'meldet die Gruppe, sobald EIN Vorgaenger eine Fassung anderen Typs hat' {
    # Dieselbe Falle wie bei IsUnmanaged, IsProtected, PackageIdFromNotes und PackageIdFuzzy: die
    # Zeile und die Rueckfrage werden AUS DEM GRUPPENOBJEKT gebaut.
    $members = @(
      [pscustomobject]@{ Name = 'Chrome'; CurrentVersion = '150.0'; LatestVersion = '153.0'; GraphId = 'a'
                         PackageId = 'Google.Chrome'; HasForeignNewer = $false; ForeignNewerVersion = ''; ForeignNewerType = ''; ForeignNewerAssigned = $false },
      [pscustomobject]@{ Name = 'Chrome'; CurrentVersion = '151.0'; LatestVersion = '153.0'; GraphId = 'b'
                         PackageId = 'Google.Chrome'; HasForeignNewer = $true; ForeignNewerVersion = '152.0'; ForeignNewerType = 'MSI'; ForeignNewerAssigned = $true }
    )
    $groups = @(Group-UpdateCandidates -Candidates $members)
    @($groups).Count | Should -Be 1
    $groups[0].HasForeignNewer | Should -BeTrue
    $groups[0].ForeignNewerVersion | Should -Be '152.0'
    $groups[0].ForeignNewerType | Should -Be 'MSI'
    $groups[0].ForeignNewerAssigned | Should -BeTrue
  }
}

Describe 'Die Einordnung sieht den Merker' {
  BeforeAll {
    function New-App {
      param([string]$Name, [bool]$Foreign = $false, [bool]$Protected = $false)
      [pscustomobject]@{
        Name = $Name; CurrentVersion = '1.0'; LatestVersion = '2.0'
        HasForeignNewer = $Foreign; IsProtected = $Protected
      }
    }
    $script:mixed = @((New-App -Name 'Chrome' -Foreign $true), (New-App -Name '7-Zip'), (New-App -Name 'VLC'))
  }

  It 'fuehrt genau die betroffene App als Befund' {
    $f = Get-RunRiskFindings -Apps $script:mixed
    @($f.Foreign).Count | Should -Be 1
    @($f.Foreign)[0].Name | Should -Be 'Chrome'
    @($f.Rest).Count | Should -Be 2
  }

  It 'fragt eine GESCHUETZTE App nicht zweimal' {
    # Fuer die zaehlt der ernstere Grund; genannt wird die fremde Fassung in ihrer Zeile trotzdem.
    $f = Get-RunRiskFindings -Apps @((New-App -Name 'TeamViewer' -Foreign $true -Protected $true))
    $f.Total | Should -Be 1
    @($f.Foreign).Count | Should -Be 0
    @($f.Protected).Count | Should -Be 1
  }
}

Describe 'Verdrahtung' {
  BeforeAll {
    $script:main = Get-SourcePartText -Part '90-Main.ps1'
    $script:winget = Get-SourcePartText -Part '25-WinGetData.ps1'
  }

  It 'nennt Typ, Version und Zuweisung in der Vorschau der Rueckfrage' {
    # Ohne diese drei Angaben ist die Frage nicht entscheidbar: "es gibt schon eine andere Fassung"
    # sagt nicht, ob sie neuer ist und ob sie ueberhaupt jemand bekommt.
    $fn = Get-SourceFunctionText -Part '70-Runtime.ps1' -Name 'Get-RunRiskAppLine'
    $fn | Should -Match '\$App\.ForeignNewerType'
    $fn | Should -Match '\$App\.ForeignNewerVersion'
    $fn | Should -Match 'ForeignNewerAssignedTag'
  }

  It 'liest den Rohbestand nur EINMAL fuer beide Auswertungen' {
    # Sonst kostet der Hinweis einen zweiten Lauf ueber alle Apps des Tenants.
    $fn = Get-SourceFunctionText -Part '25-WinGetData.ps1' -Name 'Get-ScanInventory'
    ([regex]::Matches($fn, 'Get-RawWin32AppsFromGraph')).Count | Should -Be 1
    $fn | Should -Match 'Get-NonWin32AppIndex'
    $fn | Should -Match 'Get-UnmanagedWin32Apps -RawApps \$raw'
  }

  It 'sagt es, wenn der Index wegen der Einstellung fehlt' {
    # Ohne den Schalter fuer unmarkierte Win32-Apps wird der Rohbestand nicht gelesen - dann gibt es
    # keinen Hinweis. Das Ausbleiben darf nicht wie "es gibt keine" aussehen.
    $fn = Get-SourceFunctionText -Part '25-WinGetData.ps1' -Name 'Get-ScanInventory'
    $fn | Should -Match 'cannot be detected in this run'
  }

  It 'setzt den Index je Lauf zurueck' {
    # Der Tenant kann zwischen zwei Laeufen ein anderer sein.
    $fn = Get-SourceFunctionText -Part '25-WinGetData.ps1' -Name 'Get-ScanInventory'
    $fn | Should -Match '\$script:nonWin32AppIndex = @\{\}'
  }

  It 'benutzt in beiden Kandidatenpfaden die richtige Zielversion' {
    # Im Metadaten-Zweig heisst sie $fallbackLatest; mit $latest waere der Vergleich gegen einen
    # Leerstring gelaufen und der Befund immer ausgeblieben.
    $script:main | Should -Match '-ForeignNewer \(Find-NonWin32NewerVersion -Index \$script:nonWin32AppIndex -Name \(\[string\]\$app\.Name\) -TargetVersion \$latest\)'
    $script:main | Should -Match '-ForeignNewer \(Find-NonWin32NewerVersion -Index \$script:nonWin32AppIndex -Name \(\[string\]\$app\.Name\) -TargetVersion \$fallbackLatest\)'
  }

  It 'zeigt es in der Zeile, vor dem Haken' {
    $rows = Get-SourceFunctionText -Part '85-Rows.ps1' -Name 'New-UpdateRow'
    $rows | Should -Match 'HasForeignNewer'
    $rows | Should -Match 'UpdateStateForeignNewerAssigned'
  }

  It 'hat jeden neuen Text in BEIDEN Sprachbloecken' {
    $strings = Get-SourcePartText -Part '15-Strings.ps1'
    foreach ($key in @('UpdateStateForeignNewer', 'UpdateStateForeignNewerAssigned', 'ForeignNewerAssignedTag',
                       'RiskyRunHeadForeign', 'RiskyRunNoteForeign')) {
      ([regex]::Matches($strings, ("(?m)^\s*{0}\s*=" -f [regex]::Escape($key)))).Count |
        Should -Be 2 -Because "$key muss einmal in EN und einmal in DE stehen"
    }
  }

  It 'sagt der gesperrten Zeile nicht mehr "Konflikt", wo keiner ist' {
    # Sieben Zeilen im gemeldeten Fenster trugen "conflict" - keine einzige war einer.
    $script:uiLanguage = 'en'
    (Get-UiString 'UpdateStateBlocked') | Should -Be 'not possible'
    $script:uiLanguage = 'de'
    (Get-UiString 'UpdateStateBlocked') | Should -Be 'nicht möglich'
  }
}
