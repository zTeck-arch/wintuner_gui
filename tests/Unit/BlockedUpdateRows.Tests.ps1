BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '20-Version.ps1' -Name @(
    'Test-IsNewerVersion', 'Get-ComparableVersionParts'))))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '10-Settings.ps1' -Name 'Test-IsProtectedApp')))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '30-UpdateTargets.ps1' -Name @(
    'New-UpdateCandidateModel', 'Measure-ScanReconciliation'))))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '40-Graph.ps1' -Name 'Group-UpdateCandidates')))

  $script:settings = @{ ProtectedApps = @() }

  # Die Zuweisungsprobe fragt Graph. Sie wird nur fuer Gruppen mit mehreren Vorgaengern gerufen und
  # ist hier nicht der Gegenstand - der Ersatz antwortet gleichfoermig, damit die Gruppierung selbst
  # geprueft wird und nicht das Netz.
  Set-Item -Path function:global:Get-AppAssignmentScopeProbe -Value {
    param([string]$AppId, [string]$AppName)
    [pscustomobject]@{ Succeeded = $true; Signature = 'grp-1'; Summary = 'eine Gruppe' }
  }

  function New-App {
    param([string]$Name, [string]$Id, [string]$Version = '1.0', [bool]$Unmanaged = $false)
    [pscustomobject]@{ Name = $Name; GraphId = $Id; CurrentVersion = $Version; IsUnmanaged = $Unmanaged }
  }
}

Describe 'Measure-ScanReconciliation' {
  It 'zaehlt eine App ohne WinGet-Id genau einmal' {
    # Der gemessene Fall vom 28.08.2026: 10 pruefbare Apps, 4 veraltet, 3 ohne Id. Die drei ohne Id
    # wurden zusaetzlich als "check failed" gezaehlt und zweimal abgezogen - heraus kam "0 aktuell",
    # obwohl Chrome, WebView2 und VS Code geprueft und aktuell waren.
    $r = Measure-ScanReconciliation -InventoryCount 11 -OutdatedCount 4 -NoWingetIdCount 3 -FailedCount 0 -IncompleteCount 1
    $r.UpToDate | Should -Be 3
    $r.Balanced | Should -BeTrue
  }

  It 'meldet eine Bilanz, die nicht aufgeht' {
    # Die Gegenprobe zur Regel: wird derselbe Posten doppelt eingereicht, wird die Zahl negativ -
    # und das muss auffallen, statt als "0 aktuell" durchzugehen.
    $r = Measure-ScanReconciliation -InventoryCount 11 -OutdatedCount 4 -NoWingetIdCount 3 -FailedCount 3 -IncompleteCount 1
    $r.UpToDate | Should -Be 0
    $r.Balanced | Should -BeTrue
    $worse = Measure-ScanReconciliation -InventoryCount 11 -OutdatedCount 4 -NoWingetIdCount 3 -FailedCount 5 -IncompleteCount 1
    $worse.Balanced | Should -BeFalse
  }

  It 'kommt mit einem leeren Lauf klar' {
    (Measure-ScanReconciliation -InventoryCount 0 -OutdatedCount 0 -NoWingetIdCount 0 -FailedCount 0 -IncompleteCount 0).UpToDate | Should -Be 0
  }
}

Describe 'Gesperrte Zeilen ueberstehen die Gruppierung' {
  It 'legt zwei nicht pruefbare Apps NICHT in eine Zeile zusammen' {
    # Der Gruppenschluessel ist sonst PackageId + Zielversion, und beide sind bei einer gesperrten
    # Zeile leer: aus "Keeper" und "Harmony SASE" waere eine einzige Zeile geworden und die andere
    # App waere genau so unsichtbar geblieben wie vorher im Protokoll.
    $blocked = @(
      (New-UpdateCandidateModel -App (New-App -Name 'Keeper Password Manager' -Id 'a1') -LatestVersion '' -BlockedReason 'keine Id'),
      (New-UpdateCandidateModel -App (New-App -Name 'Harmony SASE' -Id 'a2') -LatestVersion '' -BlockedReason 'keine Id'))
    $groups = @(Group-UpdateCandidates -Candidates $blocked)
    $groups.Count | Should -Be 2
    @($groups | Where-Object { $_.IsBlocked }).Count | Should -Be 2
    @($groups.Name | Sort-Object) | Should -Be @('Harmony SASE', 'Keeper Password Manager')
  }

  It 'fasst echte Update-Ziele weiterhin zusammen' {
    # Die Gegenprobe: der neue Zweig darf die bestehende Zusammenfassung nicht aushebeln - zwei
    # Vorgaenger derselben Paket-Id und Zielversion bleiben EIN Ziel.
    $candidates = @(
      (New-UpdateCandidateModel -App (New-App -Name 'Zoom Rooms' -Id 'b1' -Version '6.5.6') -LatestVersion '7.1.6' -PackageId 'Zoom.ZoomRooms'),
      (New-UpdateCandidateModel -App (New-App -Name 'Zoom Rooms' -Id 'b2' -Version '6.4.0') -LatestVersion '7.1.6' -PackageId 'Zoom.ZoomRooms'))
    $groups = @(Group-UpdateCandidates -Candidates $candidates)
    $groups.Count | Should -Be 1
    $groups[0].ConcreteCount | Should -Be 2
  }

  It 'traegt die Herkunftsmarkierung in die Gruppe' {
    # Gemessen, nicht vermutet: die Zeilen der Liste werden aus dem GRUPPENOBJEKT gebaut. Fehlte
    # IsUnmanaged dort, blieb die orange Warnung "nicht von WinTuner gebaut" unsichtbar - im Lauf
    # vom 28.08.2026 bei jeder der vier angezeigten Zeilen.
    $candidates = @(
      (New-UpdateCandidateModel -App (New-App -Name 'Docker Desktop' -Id 'c1' -Unmanaged $true) -LatestVersion '4.88.1' -PackageId 'Docker.DockerDesktop'))
    $groups = @(Group-UpdateCandidates -Candidates $candidates)
    $groups[0].IsUnmanaged | Should -BeTrue
  }

  It 'traegt den Schutz in die Gruppe, sobald EIN Vorgaenger geschuetzt ist' {
    # Der Lauf fasst die Gruppe zu einem Ziel zusammen. Ginge der Schutz beim Zusammenfassen
    # verloren, liefe genau die App ohne Rueckfrage durch, fuer die jemand den Schutz gesetzt hat.
    $script:settings = @{ ProtectedApps = @('Zoom Rooms') }
    $candidates = @(
      (New-UpdateCandidateModel -App (New-App -Name 'Zoom Rooms' -Id 'd1' -Version '6.5.6') -LatestVersion '7.1.6' -PackageId 'Zoom.ZoomRooms'),
      (New-UpdateCandidateModel -App (New-App -Name 'Zoom Rooms' -Id 'd2' -Version '6.4.0') -LatestVersion '7.1.6' -PackageId 'Zoom.ZoomRooms'))
    $groups = @(Group-UpdateCandidates -Candidates $candidates)
    $groups[0].IsProtected | Should -BeTrue
    $script:settings = @{ ProtectedApps = @() }
  }
}

Describe 'New-UpdateCandidateModel fuer eine gesperrte Zeile' {
  It 'nimmt eine leere Zielversion an' {
    # Eine gesperrte Zeile hat keine Zielversion - sie existiert ja, weil nichts zu vergleichen war.
    # Als Pflichtparameter ohne AllowEmptyString hat der Aufruf den Leerstring abgelehnt und die App
    # waere wieder nur im Protokoll gelandet.
    $m = New-UpdateCandidateModel -App (New-App -Name 'Steam' -Id 'e1' -Version '') -LatestVersion '' -BlockedReason 'keine Version'
    $m.IsBlocked | Should -BeTrue
    $m.BlockedReason | Should -Be 'keine Version'
    $m.LatestVersion | Should -Be ''
  }

  It 'bleibt fuer eine normale Zeile ungesperrt' {
    $m = New-UpdateCandidateModel -App (New-App -Name 'Chrome' -Id 'e2') -LatestVersion '152.0' -PackageId 'Google.Chrome'
    $m.IsBlocked | Should -BeFalse
  }
}

Describe 'Der Suchlauf zeigt und schuetzt die gesperrten Zeilen' {
  # Der Klick-Handler ist keine Funktion und laesst sich nicht einzeln laden - geprueft wird die
  # Stelle im Quelltext. Ohne diese Regeln waeren die Zeilen zwar baubar, aber niemand baute sie.
  BeforeAll {
    $script:mainText = Get-SourcePartText -Part '90-Main.ps1'
    $script:viewsText = Get-SourcePartText -Part '80-Views.ps1'
  }

  It 'legt fuer eine App ohne WinGet-Id eine gesperrte Zeile an' {
    $script:mainText | Should -Match "BlockedReason \(Get-UiString 'UpdateStateNoWingetId'\)"
  }

  It 'legt fuer eine App ohne Version in Intune eine gesperrte Zeile an' {
    $script:mainText | Should -Match "BlockedReason \(Get-UiString 'UpdateStateNoVersion'\)"
  }

  It 'zaehlt eine App ohne Id nicht zusaetzlich als fehlgeschlagene Pruefung' {
    $script:mainText | Should -Match 'if \(\$wingetId -and -not \$verified\) \{ \$failedChecks\+\+ \}'
  }

  It 'haakt bei "Alle auswaehlen" keine gesperrte Zeile an' {
    $script:mainText | Should -Match '\$row\.Checked = -not \$isBlocked'
  }

  It 'ueberspringt eine angehakte gesperrte Zeile im Lauf' {
    # Der Haken laesst sich an einer ListView-Zeile nicht einzeln abschalten. Bliebe diese Pruefung
    # aus, ginge eine App ohne belastbare Paket-Id in den Paketbau - also genau das Raten, das die
    # strengen Zuordnungsregeln verhindern sollen.
    $script:mainText | Should -Match "the row is blocked"
  }

  It 'bietet die Zuordnung einer WinGet-Id an der Zeile an' {
    $script:viewsText | Should -Match '\$updateAssignIdItem\.Add_Click'
    $script:viewsText | Should -Match 'Test-IsPlausiblePackageId -Value \$value'
    $script:viewsText | Should -Match '\$script:settings\.WingetOverrides\[\$name\] = \$value'
  }
}
