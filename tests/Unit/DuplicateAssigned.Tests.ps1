#requires -Version 7
# Mehrere Versionen derselben App gleichzeitig zugewiesen.
#
# Gemeldet am 07.09.2026 mit einem Bild aus einem echten Tenant: sechs Eintraege "Google Chrome",
# davon ZWEI zugewiesen - 152.0.7977.83 als Win32 und 152.0.7977.76 als MSI-line-of-business. Zwei
# zugewiesene Fassungen derselben Software heisst, dass Geraete sie doppelt bekommen.
#
# Ein Update-Lauf loest das nicht: der greift nur, wenn es eine NEUERE Version zu bauen gibt. Ist
# die neueste schon im Tenant, verschwindet die Zeile aus der Update-Liste und der Zustand bleibt
# unsichtbar.
#
# Die Faelle unten pruefen die REGELN, nicht das Netz - und zwar in beide Richtungen. Ein zu
# eifriges Aufraeumen nimmt Geraeten eine App weg, ein zu vorsichtiges laesst den doppelten
# Zustand stehen.

BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-UiStringsText)))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '20-Version.ps1' -Name @(
    'Test-IsNewerVersion', 'Get-ComparableVersionParts'))))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '10-Settings.ps1' -Name @(
    'Test-IsProtectedApp', 'Set-ProtectedAppPatterns'))))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '45-Assignments.ps1' -Name @(
    'Get-DuplicateAssignedPlan', 'Test-ScopeSignatureHasUninstall', 'Test-IsWindowsAppType',
    'Resolve-DuplicateAssignedProbes', 'Invoke-DuplicateAssignedCleanup'))))

  function New-TenantApp {
    param(
      [string]$Name, [string]$Version, [bool]$Assigned = $false,
      [string]$Type = 'Windows app (Win32)', [string]$Id = '',
      [string]$OdataType = '#microsoft.graph.win32LobApp'
    )
    if (-not $Id) { $Id = [guid]::NewGuid().ToString() }
    [pscustomobject]@{
      Id = $Id; DisplayName = $Name; Version = $Version; IsAssigned = $Assigned
      TypeLabel = $Type; OdataType = $OdataType
    }
  }

  # Der gemeldete Fall, Zeile fuer Zeile aus dem Bild.
  $script:reported = @(
    (New-TenantApp -Name 'Google Chrome' -Version '151.0.7922.138' -Assigned $false),
    (New-TenantApp -Name 'Google Chrome' -Version '152.0.7977.76'  -Assigned $false),
    (New-TenantApp -Name 'Google Chrome' -Version '152.0.7977.76'  -Assigned $true -Type 'Windows MSI line-of-business' -Id 'msi-1' -OdataType '#microsoft.graph.windowsMobileMSI'),
    (New-TenantApp -Name 'Google Chrome' -Version '151.0.7922.174' -Assigned $false),
    (New-TenantApp -Name 'Google Chrome' -Version '152.0.7977.83'  -Assigned $true -Id 'newest-1'),
    (New-TenantApp -Name 'Google Chrome' -Version '152.0.7977.65'  -Assigned $false)
  )
}

Describe 'Get-DuplicateAssignedPlan: der gemeldete Fall' {
  It 'erkennt genau eine betroffene App und benennt Ziel und Quelle' {
    $r = Get-DuplicateAssignedPlan -Apps $script:reported -ProtectedPatterns @()
    @($r.Plans).Count | Should -Be 1
    $plan = @($r.Plans)[0]
    $plan.Name | Should -Be 'Google Chrome'
    # Ziel ist die hoechste Version - 152.0.7977.83, nicht die zuerst gefundene zugewiesene.
    $plan.Target.Version | Should -Be '152.0.7977.83'
    $plan.Target.Id | Should -Be 'newest-1'
    # Quelle ist NUR die andere zugewiesene Fassung. Die vier unzugewiesenen sind nicht das Problem
    # und werden nicht angefasst.
    @($plan.Sources).Count | Should -Be 1
    @($plan.Sources)[0].Id | Should -Be 'msi-1'
  }

  It 'nennt die gemischten App-Typen, statt sie stillschweigend zu verschieben' {
    # Eine Zuweisung von einer MSI-App auf eine Win32-App zu verschieben ist technisch moeglich,
    # aber nichts, was jemand beilaeufig tun sollte - die Rueckfrage muss es sagen.
    $plan = @((Get-DuplicateAssignedPlan -Apps $script:reported -ProtectedPatterns @()).Plans)[0]
    $plan.MixedTypes | Should -BeTrue
  }
}

Describe 'Get-DuplicateAssignedPlan: die Regeln' {
  It 'meldet nichts, wenn nur EINE Fassung zugewiesen ist' {
    # Der gewuenschte Zustand ist kein Befund. Sechs Versionen, eine zugewiesen: alles in Ordnung.
    $apps = @(
      (New-TenantApp -Name 'VLC' -Version '3.0.20' -Assigned $true),
      (New-TenantApp -Name 'VLC' -Version '3.0.18' -Assigned $false),
      (New-TenantApp -Name 'VLC' -Version '3.0.16' -Assigned $false)
    )
    $r = Get-DuplicateAssignedPlan -Apps $apps -ProtectedPatterns @()
    @($r.Plans).Count | Should -Be 0
    @($r.Skipped).Count | Should -Be 0
  }

  It 'meldet nichts, wenn gar nichts zugewiesen ist' {
    $apps = @(
      (New-TenantApp -Name '7-Zip' -Version '24.09' -Assigned $false),
      (New-TenantApp -Name '7-Zip' -Version '23.01' -Assigned $false)
    )
    @((Get-DuplicateAssignedPlan -Apps $apps -ProtectedPatterns @()).Plans).Count | Should -Be 0
  }

  It 'zieht die Zuweisung auf die neueste Fassung, auch wenn DIE noch keine hat' {
    # Genau der Auftrag: nur die aktuellste soll eine Zuweisung haben. Ist die neueste noch
    # unzugewiesen und zwei aeltere sind es, wandern beide auf sie.
    $apps = @(
      (New-TenantApp -Name 'Firefox' -Version '141.0' -Assigned $false -Id 'target'),
      (New-TenantApp -Name 'Firefox' -Version '140.0' -Assigned $true -Id 'old-1'),
      (New-TenantApp -Name 'Firefox' -Version '139.0' -Assigned $true -Id 'old-2')
    )
    $plan = @((Get-DuplicateAssignedPlan -Apps $apps -ProtectedPatterns @()).Plans)[0]
    $plan.Target.Id | Should -Be 'target'
    @($plan.Sources).Count | Should -Be 2
  }

  It 'laesst eine geschuetzte App aus und benennt den Grund' {
    # Selbst paketierte Kundensoftware: wer ihre Zuweisungen verschieben will, hebt vorher den
    # Schutz auf - dieselbe Regel wie beim Update und beim Loeschen.
    $apps = @(
      (New-TenantApp -Name 'TeamViewer Host' -Version '15.60' -Assigned $true),
      (New-TenantApp -Name 'TeamViewer Host' -Version '15.58' -Assigned $true)
    )
    $r = Get-DuplicateAssignedPlan -Apps $apps -ProtectedPatterns @('TeamViewer*')
    @($r.Plans).Count | Should -Be 0
    @($r.Skipped).Count | Should -Be 1
    @($r.Skipped)[0].Reason | Should -Be 'protected'
  }

  It 'raet nicht, wenn eine Version fehlt' {
    # Ohne vergleichbare Versionen gibt es kein "die neueste". Eine geratene Wahl waere hier eine
    # verschobene Zuweisung auf die falsche App.
    $apps = @(
      (New-TenantApp -Name 'Dell Support Assistant' -Version '' -Assigned $true),
      (New-TenantApp -Name 'Dell Support Assistant' -Version '3.2' -Assigned $true)
    )
    $r = Get-DuplicateAssignedPlan -Apps $apps -ProtectedPatterns @()
    @($r.Plans).Count | Should -Be 0
    @($r.Skipped)[0].Reason | Should -Be 'noversion'
  }

  It 'raet nicht, wenn zwei Fassungen dieselbe hoechste Version tragen' {
    # Im gemeldeten Bild gibt es genau das (152.0.7977.76 als Win32 UND als MSI) - dort nur nicht
    # als hoechste. Waere es die hoechste, ist "die neueste" nicht eindeutig.
    $apps = @(
      (New-TenantApp -Name 'Chrome' -Version '152.0' -Assigned $true -Id 'a'),
      (New-TenantApp -Name 'Chrome' -Version '152.0' -Assigned $true -Type 'Windows MSI line-of-business' -Id 'b' -OdataType '#microsoft.graph.windowsMobileMSI'),
      (New-TenantApp -Name 'Chrome' -Version '151.0' -Assigned $false)
    )
    $r = Get-DuplicateAssignedPlan -Apps $apps -ProtectedPatterns @()
    @($r.Plans).Count | Should -Be 0
    @($r.Skipped)[0].Reason | Should -Be 'ambiguous'
  }

  It 'gruppiert ueber App-Typen hinweg, aber nicht ueber verschiedene Namen' {
    $apps = @(
      (New-TenantApp -Name 'Google Chrome' -Version '152.0' -Assigned $true),
      (New-TenantApp -Name 'Google Chrome' -Version '151.0' -Assigned $true),
      (New-TenantApp -Name 'Google Chrome Beta' -Version '153.0' -Assigned $true)
    )
    $r = Get-DuplicateAssignedPlan -Apps $apps -ProtectedPatterns @()
    # "Google Chrome Beta" ist eine andere App und bleibt fuer sich - eine einzige zugewiesene
    # Fassung ist kein Befund.
    @($r.Plans).Count | Should -Be 1
    @($r.Plans)[0].Name | Should -Be 'Google Chrome'
  }

  It 'vergleicht den Namen ohne Ruecksicht auf Gross-/Kleinschreibung und Leerzeichen' {
    $apps = @(
      (New-TenantApp -Name 'Google Chrome' -Version '152.0' -Assigned $true),
      (New-TenantApp -Name '  google chrome ' -Version '151.0' -Assigned $true)
    )
    @((Get-DuplicateAssignedPlan -Apps $apps -ProtectedPatterns @()).Plans).Count | Should -Be 1
  }

  It 'vertraegt eine leere Liste und Nullwerte darin' {
    @((Get-DuplicateAssignedPlan -Apps @() -ProtectedPatterns @()).Plans).Count | Should -Be 0
    @((Get-DuplicateAssignedPlan -Apps @($null) -ProtectedPatterns @()).Plans).Count | Should -Be 0
  }
}

Describe 'Test-ScopeSignatureHasUninstall' {
  It 'erkennt eine Deinstallations-Zuweisung' {
    Test-ScopeSignatureHasUninstall -Signature 'uninstall|grp-1|none|-|source:direct|settings:none' | Should -BeTrue
  }

  It 'erkennt sie auch, wenn sie nicht an erster Stelle steht' {
    $sig = 'available|grp-1|none|-|source:direct|settings:none;uninstall|grp-2|none|-|source:direct|settings:none'
    Test-ScopeSignatureHasUninstall -Signature $sig | Should -BeTrue
  }

  It 'meldet required/available NICHT als Deinstallation' {
    Test-ScopeSignatureHasUninstall -Signature 'required|grp-1|none|-|source:direct|settings:none' | Should -BeFalse
    Test-ScopeSignatureHasUninstall -Signature '<none>' | Should -BeFalse
    Test-ScopeSignatureHasUninstall -Signature '' | Should -BeFalse
  }

  It 'faellt nicht auf das WORT "uninstall" an anderer Stelle herein' {
    # Ein Gruppenname oder Filter, in dem "uninstall" vorkommt, ist keine Deinstallation. Geprueft
    # wird der Intent am ANFANG des Teils, nicht ein enthaltener Text.
    Test-ScopeSignatureHasUninstall -Signature 'required|uninstall-test-group|none|-|source:direct|settings:none' |
      Should -BeFalse
  }
}

Describe 'Resolve-DuplicateAssignedProbes' {
  # Diese Stufe gibt es, weil 'isAssigned' aus dem Inventar nur "irgendeine Zuweisung" heisst -
  # auch eine reine DEINSTALLATION zaehlt dort mit. Sie laeuft VOR der Rueckfrage, damit der Dialog
  # dasselbe sagt wie das Ergebnis. Genau so macht es der Loeschpfad in "Alle Tenant-Apps" auch.
  BeforeAll {
    $script:plan = @(@{
      Name = 'Chrome'
      Target = (New-TenantApp -Name 'Chrome' -Version '152.0' -Id 'target')
      Sources = @((New-TenantApp -Name 'Chrome' -Version '151.0' -Id 'old'))
      MixedTypes = $false
    })
    function New-Probe {
      param([bool]$Ok = $true, [string]$Signature = 'required|grp-1|none|-|source:direct|settings:none')
      [pscustomobject]@{ Succeeded = $Ok; Signature = $Signature; Count = 1 }
    }
  }

  It 'behaelt eine Quelle mit echter Zuweisung' {
    $r = Resolve-DuplicateAssignedProbes -Plans $script:plan -Probes @{ 'old' = (New-Probe) }
    @($r.Plans).Count | Should -Be 1
    @($r.Skipped).Count | Should -Be 0
  }

  It 'laesst eine Deinstallations-Zuweisung aus und benennt den Grund' {
    $r = Resolve-DuplicateAssignedProbes -Plans $script:plan -Probes @{
      'old' = (New-Probe -Signature 'uninstall|grp-1|none|-|source:direct|settings:none') }
    @($r.Plans).Count | Should -Be 0
    @($r.Skipped)[0].Reason | Should -Be 'uninstall'
  }

  It 'laesst eine nicht lesbare Quelle aus' {
    $r = Resolve-DuplicateAssignedProbes -Plans $script:plan -Probes @{ 'old' = (New-Probe -Ok $false) }
    @($r.Plans).Count | Should -Be 0
    @($r.Skipped)[0].Reason | Should -Be 'unreadable'
  }

  It 'laesst eine Quelle aus, die GAR KEINE Zuweisung mehr hat' {
    # Das Inventar kann veraltet sein - jemand hat die Zuweisung im Portal entfernt, waehrend die
    # Liste im Fenster stand. Dann ist es kein Befund mehr.
    $r = Resolve-DuplicateAssignedProbes -Plans $script:plan -Probes @{ 'old' = (New-Probe -Signature '<none>') }
    @($r.Plans).Count | Should -Be 0
    @($r.Skipped)[0].Reason | Should -Be 'gone'
  }

  It 'behandelt eine fehlende Sonde als nicht lesbar' {
    $r = Resolve-DuplicateAssignedProbes -Plans $script:plan -Probes @{}
    @($r.Plans).Count | Should -Be 0
    @($r.Skipped)[0].Reason | Should -Be 'unreadable'
  }

  It 'behaelt die geprueften Quellen einer Gruppe und laesst nur die auffaelligen aus' {
    $mixed = @(@{
      Name = 'Chrome'
      Target = (New-TenantApp -Name 'Chrome' -Version '152.0' -Id 'target')
      Sources = @((New-TenantApp -Name 'Chrome' -Version '151.0' -Id 'ok'),
                  (New-TenantApp -Name 'Chrome' -Version '150.0' -Id 'uninst'))
      MixedTypes = $false
    })
    $r = Resolve-DuplicateAssignedProbes -Plans $mixed -Probes @{
      'ok' = (New-Probe)
      'uninst' = (New-Probe -Signature 'uninstall|grp-2|none|-|source:direct|settings:none')
    }
    @($r.Plans).Count | Should -Be 1
    @(@($r.Plans)[0].Sources).Count | Should -Be 1
    @(@($r.Plans)[0].Sources)[0].Id | Should -Be 'ok'
    @($r.Skipped).Count | Should -Be 1
  }
}

Describe 'Test-IsWindowsAppType' {
  It 'erkennt die Windows-Typen' {
    foreach ($t in @('#microsoft.graph.win32LobApp', '#microsoft.graph.winGetApp',
                     '#microsoft.graph.windowsMobileMSI', '#microsoft.graph.windowsUniversalAppX',
                     '#microsoft.graph.officeSuiteApp', '#microsoft.graph.microsoftStoreForBusinessApp')) {
      Test-IsWindowsAppType -OdataType $t | Should -BeTrue -Because "$t ist eine Windows-App"
    }
  }

  It 'schliesst iOS, Android, macOS und Weblinks aus' {
    # "Alle Tenant-Apps" listet jeden Typ. Eine Zuweisung von einer Android-App auf eine
    # Windows-App zu verschieben waere Unsinn, selbst wenn beide gleich heissen.
    foreach ($t in @('#microsoft.graph.iosLobApp', '#microsoft.graph.androidStoreApp',
                     '#microsoft.graph.macOSLobApp', '#microsoft.graph.webApp')) {
      Test-IsWindowsAppType -OdataType $t | Should -BeFalse -Because "$t ist keine Windows-App"
    }
  }

  It 'behandelt einen leeren Typ als NICHT Windows' {
    # Fail-safe in die vorsichtige Richtung: lieber eine App nicht anfassen.
    Test-IsWindowsAppType -OdataType '' | Should -BeFalse
    Test-IsWindowsAppType -OdataType $null | Should -BeFalse
  }

  It 'gruppiert eine Android-App nicht mit einer gleichnamigen Windows-App' {
    $apps = @(
      (New-TenantApp -Name 'Zoom' -Version '7.1' -Assigned $true),
      (New-TenantApp -Name 'Zoom' -Version '7.0' -Assigned $true -OdataType '#microsoft.graph.androidStoreApp')
    )
    # Nur eine Windows-Fassung bleibt uebrig - und eine einzige zugewiesene ist kein Befund.
    @((Get-DuplicateAssignedPlan -Apps $apps -ProtectedPatterns @()).Plans).Count | Should -Be 0
  }
}

Describe 'Invoke-DuplicateAssignedCleanup' {
  BeforeEach {
    $global:TestLog.Clear()
    $global:MoveCalls = [System.Collections.Generic.List[string]]::new()
    Set-Item -Path function:global:Move-AppAssignments -Value {
      param([string]$OldAppId, [string]$NewAppId, [string]$AppName = '')
      $global:MoveCalls.Add(("{0}->{1}" -f $OldAppId, $NewAppId))
      return $true
    }
  }
  AfterAll {
    Remove-Item function:global:Move-AppAssignments -ErrorAction SilentlyContinue
    Remove-Variable -Name MoveCalls -Scope Global -ErrorAction SilentlyContinue
  }

  It 'verschiebt die Zuweisungen der Quelle auf das Ziel' {
    $plans = @(@{
      Name = 'Chrome'
      Target = (New-TenantApp -Name 'Chrome' -Version '152.0' -Id 'target')
      Sources = @((New-TenantApp -Name 'Chrome' -Version '151.0' -Id 'old'))
    })
    $r = Invoke-DuplicateAssignedCleanup -Plans $plans
    $r.Moved | Should -Be 1
    @($global:MoveCalls) | Should -Be @('old->target')
  }

  It 'meldet den Fortschritt je Quelle' {
    # Ohne diesen Rueckruf stand das Fenster bei zwanzig Quellen minutenlang still: jede
    # Verschiebung sind mehrere Graph-Aufrufe, und die laufen auf dem UI-Faden.
    $plans = @(@{
      Name = 'Chrome'
      Target = (New-TenantApp -Name 'Chrome' -Version '152.0' -Id 'target')
      Sources = @((New-TenantApp -Name 'Chrome' -Version '151.0' -Id 'a'),
                  (New-TenantApp -Name 'Chrome' -Version '150.0' -Id 'b'))
    })
    $seen = [System.Collections.Generic.List[string]]::new()
    $null = Invoke-DuplicateAssignedCleanup -Plans $plans -OnProgress {
      param($done, $label) $seen.Add(("{0}:{1}" -f $done, $label))
    }
    @($seen).Count | Should -Be 2
    @($seen)[0] | Should -Match '^0:Chrome 151\.0'
    @($seen)[1] | Should -Match '^1:Chrome 150\.0'
  }

  It 'laeuft weiter, wenn der Fortschritts-Rueckruf wirft' {
    # Eine kaputte Anzeige darf keine halbe Verschiebung hinterlassen.
    $plans = @(@{
      Name = 'Chrome'
      Target = (New-TenantApp -Name 'Chrome' -Version '152.0' -Id 'target')
      Sources = @((New-TenantApp -Name 'Chrome' -Version '151.0' -Id 'old'))
    })
    # Direkt aufgerufen, nicht in einem { } -Should -Not -Throw: eine Zuweisung dort bleibt im
    # Scope des Blocks, und $r waere hier $null. Wirft die Funktion, scheitert dieser Fall ohnehin.
    $r = Invoke-DuplicateAssignedCleanup -Plans $plans -OnProgress { param($done, $label) throw 'UI kaputt' }
    $r.Moved | Should -Be 1
  }

  It 'zaehlt eine gescheiterte Verschiebung als Fehler, statt sie zu verschweigen' {
    Set-Item -Path function:global:Move-AppAssignments -Value {
      param([string]$OldAppId, [string]$NewAppId, [string]$AppName = '')
      return $false
    }
    $plans = @(@{
      Name = 'Chrome'
      Target = (New-TenantApp -Name 'Chrome' -Version '152.0' -Id 'target')
      Sources = @((New-TenantApp -Name 'Chrome' -Version '151.0' -Id 'old'))
    })
    (Invoke-DuplicateAssignedCleanup -Plans $plans).Failed | Should -Be 1
  }

  It 'ueberlebt eine werfende Verschiebung' {
    Set-Item -Path function:global:Move-AppAssignments -Value {
      param([string]$OldAppId, [string]$NewAppId, [string]$AppName = '')
      throw 'Graph exploded'
    }
    $plans = @(@{
      Name = 'Chrome'
      Target = (New-TenantApp -Name 'Chrome' -Version '152.0' -Id 'target')
      Sources = @((New-TenantApp -Name 'Chrome' -Version '151.0' -Id 'old'))
    })
    { Invoke-DuplicateAssignedCleanup -Plans $plans } | Should -Not -Throw
  }

  It 'vertraegt eine leere Planliste' {
    (Invoke-DuplicateAssignedCleanup -Plans @()).Moved | Should -Be 0
  }
}

Describe 'Verdrahtung in der Tenant-Ansicht' {
  BeforeAll { $script:tenantText = Get-SourcePartText -Part '82-TenantApps.ps1' }

  It 'hat den Knopf und ruft Plan UND Ausfuehrung' {
    $script:tenantText | Should -Match '\$tenantDedupeButton'
    $script:tenantText | Should -Match 'Get-DuplicateAssignedPlan'
    $script:tenantText | Should -Match 'Invoke-DuplicateAssignedCleanup'
  }

  It 'prueft die Zuweisungen VOR der Rueckfrage, nicht erst beim Ausfuehren' {
    # Sonst kuendigt der Dialog Verschiebungen an, die hinterher ausgelassen werden. Der
    # Loeschpfad daneben macht es genauso: erst fragen, was Intune weiss, dann den Zustand nennen.
    $block = [regex]::Match($script:tenantText, '(?s)\$tenantDedupeButton\.Add_Click\(\{.*?\n\}\)').Value
    $probePos = $block.IndexOf('Get-AppAssignmentScopeProbe')
    $refinePos = $block.IndexOf('Resolve-DuplicateAssignedProbes')
    $askPos = $block.IndexOf('TenantDedupeConfirmDialog')
    $probePos | Should -BeGreaterThan 0
    $refinePos | Should -BeGreaterThan $probePos
    $askPos | Should -BeGreaterThan $refinePos
  }

  It 'zeigt Fortschritt beim Lesen UND beim Verschieben' {
    # Beides sind mehrere Graph-Aufrufe je App auf dem UI-Faden. Ohne Fortschritt und DoEvents
    # sieht die Anwendung eingefroren aus - dieselbe Lehre wie beim Loeschpfad.
    $block = [regex]::Match($script:tenantText, '(?s)\$tenantDedupeButton\.Add_Click\(\{.*?\n\}\)').Value
    ([regex]::Matches($block, 'Set-ProgressValue')).Count | Should -BeGreaterOrEqual 2
    ([regex]::Matches($block, 'DoEvents')).Count | Should -BeGreaterOrEqual 2
    $block | Should -Match 'TenantDedupeProbingStatus'
    $block | Should -Match 'TenantDedupeMovingStatus'
    # Und jede Fortschrittsanzeige hat ihr Hide-Progress - die Sichtbarkeit IST die Busy-Sperre.
    ([regex]::Matches($block, 'Show-Progress')).Count | Should -Be ([regex]::Matches($block, 'Hide-Progress')).Count
  }

  It 'betrachtet nur Windows-Apps' {
    $script:tenantText | Should -Match 'OdataType'
    (Get-SourceFunctionText -Part '45-Assignments.ps1' -Name 'Get-DuplicateAssignedPlan') |
      Should -Match 'Test-IsWindowsAppType'
  }

  It 'fragt IMMER - die Rueckfrage haengt nicht an Confirm-ChangeAction' {
    # Hier werden Zuweisungen in Intune verschoben; danach bekommt eine andere App-Fassung die
    # Gruppen. Das darf "Rueckfragen abschalten" nicht wegdruecken.
    $block = [regex]::Match($script:tenantText, '(?s)\$tenantDedupeButton\.Add_Click\(\{.*?\n\}\)').Value
    $block | Should -Not -BeNullOrEmpty
    $block | Should -Not -Match 'Confirm-ChangeAction'
    $block | Should -Match 'MessageBoxDefaultButton\]::Button2'
  }

  It 'laedt die Liste danach neu - sonst zeigt die Zuweisungsspalte den alten Stand' {
    $block = [regex]::Match($script:tenantText, '(?s)\$tenantDedupeButton\.Add_Click\(\{.*?\n\}\)').Value
    $block | Should -Match 'Clear-Win32AppsCache'
    $block | Should -Match 'Update-TenantAppsList'
  }

  It 'rechnet die Knopfbreite, statt sie zu setzen' {
    $script:tenantText | Should -Match 'Get-ControlTextWidth -Control \$tenantDedupeButton'
  }
}
