# „Keine Apps in Intune gefunden" bei einem Kunden mit 11 Apps.
#
# Aus dem Protokoll vom 26.08.2026, 10:27: die Anmeldung lief in den bekannten Modul-Wettlauf
# („Collection was modified"), danach meldete das Dashboard `managed=0 updates=0 superseded=6` und
# die Update-Suche „Keine Apps in Intune gefunden".
#
# Drei Fehler zusammen:
#   1. Eine LEERE Antwort ist keine Ausnahme - der Wiederhol-Mechanismus sah nichts, was er
#      wiederholen könnte, und glaubte der Null.
#   2. Die leere Liste wurde in den Cache geschrieben und von der Update-Suche weiterverwendet.
#   3. 0 aktive Apps bei 6 abgelösten ist unmöglich - niemand hat nachgerechnet.

BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '25-WinGetData.ps1' -Name @(
    'Test-IsTransientModuleRace', 'Invoke-WithTransientRetry', 'Get-Win32AppsResilient',
    'Test-Win32InventoryTruncated', 'Test-InventoryContradiction',
    'Get-CachedWin32Apps', 'Clear-Win32AppsCache', 'Clear-GraphInventoryRawCache'))))
  $script:win32AppsModulePageSize = 999
  $script:win32InventoryTruncationWarned = @{}
  $script:win32AppsCacheSeconds = 30
}

Describe 'Test-InventoryContradiction' {
  It 'nennt 0 aktive bei vorhandenen abgeloesten Apps einen Widerspruch' {
    Test-InventoryContradiction -ActiveCount 0 -SupersededCount 6 | Should -BeTrue
  }
  It 'haelt einen wirklich leeren Tenant fuer moeglich' {
    Test-InventoryContradiction -ActiveCount 0 -SupersededCount 0 | Should -BeFalse
  }
  It 'sieht in einem normalen Inventar keinen Widerspruch' {
    Test-InventoryContradiction -ActiveCount 11 -SupersededCount 8 | Should -BeFalse
  }
}

Describe 'Leere Inventar-Antwort' {

  BeforeEach {
    $script:win32AppsCache = @{}
    $script:win32InventoryTruncationWarned = @{}
    $global:TestReadCount = 0
    $global:TestGraphApps = @()
    $global:TestGraphReads = 0
    # Die zweite Meinung: Graph direkt, paginiert, mit demselben Filter wie das Modul.
    Set-Item -Path function:global:Get-Win32AppInventoryViaGraph -Value {
      param([switch]$Superseded)
      $global:TestGraphReads++
      @($global:TestGraphApps)
    }
  }

  It 'liest einmal gegen, bevor sie geglaubt wird - und nimmt das zweite Ergebnis' {
    # Genau der beobachtete Fall: erste Antwort leer (Wettlauf), zweite Antwort vollstaendig.
    Set-Item -Path function:global:Get-WtWin32Apps -Value {
      $global:TestReadCount++
      if ($global:TestReadCount -eq 1) { return @() }
      return @(1..11 | ForEach-Object { [pscustomobject]@{ Name = "App $_"; GraphId = "id-$_" } })
    }
    $apps = @(Get-Win32AppsResilient -Label 'test')
    $apps.Count | Should -Be 11
    $global:TestReadCount | Should -Be 2
    ($global:TestLog -join ' ') | Should -Match 'came back EMPTY'
  }

  It 'glaubt "leer" erst, wenn Modul UND Graph es sagen' {
    Set-Item -Path function:global:Get-WtWin32Apps -Value { $global:TestReadCount++; @() }
    $apps = @(Get-Win32AppsResilient -Label 'test')
    $apps.Count | Should -Be 0
    $global:TestReadCount | Should -Be 2
    $global:TestGraphReads | Should -Be 1
    ($global:TestLog -join ' ') | Should -Match 'confirmed empty by the module AND by a direct Graph read'
    # Und sagt gleich, was die Null wirklich bedeutet.
    ($global:TestLog -join ' ') | Should -Match "no WinTuner-managed"
  }

  It 'nimmt die Apps, die Graph findet, wenn das Modul nichts liefert' {
    # Der Fall aus dem Protokoll: das Modul antwortete zweimal leer, im Portal standen Apps.
    Set-Item -Path function:global:Get-WtWin32Apps -Value { $global:TestReadCount++; @() }
    $global:TestGraphApps = @(1..11 | ForEach-Object { [pscustomobject]@{ Name = "App $_"; GraphId = "id-$_" } })
    $apps = @(Get-Win32AppsResilient -Label 'test')
    $apps.Count | Should -Be 11
    ($global:TestLog -join ' ') | Should -Match 'a direct paged Graph read found 11'
  }

  It 'bleibt bei der leeren Antwort, wenn auch die Gegenprobe scheitert' {
    Set-Item -Path function:global:Get-WtWin32Apps -Value { $global:TestReadCount++; @() }
    Set-Item -Path function:global:Get-Win32AppInventoryViaGraph -Value { param([switch]$Superseded) throw 'no token' }
    @(Get-Win32AppsResilient -Label 'test').Count | Should -Be 0
    ($global:TestLog -join ' ') | Should -Match 'cross-check failed'
  }

  It 'liest nicht gegen, wenn der Aufrufer keine Wiederholungen will' {
    # Resolve-DeployedUpdateTarget wartet in seiner EIGENEN Schleife darauf, dass eine App auftaucht -
    # dort ist "noch leer" die erwartete Antwort und darf keine zweite Abfrage kosten.
    Set-Item -Path function:global:Get-WtWin32Apps -Value { $global:TestReadCount++; @() }
    [void](Get-Win32AppsResilient -Label 'test' -MaxRetries 0)
    $global:TestReadCount | Should -Be 1
  }
}

Describe 'Cache mit leerer Antwort' {

  BeforeEach {
    $script:win32AppsCache = @{}
    $script:win32InventoryTruncationWarned = @{}
    $global:TestReadCount = 0
  }

  It 'schreibt keine leere Liste ueber ein gefuelltes Inventar desselben Kunden' {
    Set-Item -Path function:global:Get-WtWin32Apps -Value {
      $global:TestReadCount++
      if ($global:TestReadCount -le 1) { return @(1..11 | ForEach-Object { [pscustomobject]@{ Name = "App $_" } }) }
      return @()
    }
    @(Get-CachedWin32Apps).Count | Should -Be 11        # erster Lauf fuellt den Cache
    @(Get-CachedWin32Apps -Force).Count | Should -Be 11  # kaputte, leere Antwort -> alte Liste bleibt
    ($global:TestLog -join ' ') | Should -Match 'NOT caching the empty answer'
  }

  It 'akzeptiert eine leere Antwort, wenn zu diesem Kunden noch nichts bekannt ist' {
    Set-Item -Path function:global:Get-WtWin32Apps -Value { $global:TestReadCount++; @() }
    @(Get-CachedWin32Apps).Count | Should -Be 0
  }

  It 'faengt nach einem Tenant-Wechsel wieder bei null an' {
    Set-Item -Path function:global:Get-WtWin32Apps -Value {
      $global:TestReadCount++
      if ($global:TestReadCount -le 1) { return @([pscustomobject]@{ Name = 'App A' }) }
      return @()
    }
    @(Get-CachedWin32Apps).Count | Should -Be 1
    Clear-Win32AppsCache
    # Anderer Kunde: eine leere Antwort ist hier eine gueltige Auskunft, keine Regression.
    @(Get-CachedWin32Apps).Count | Should -Be 0
  }
}

Describe 'Wer den Widerspruch prueft' {

  It 'prueft ihn im Dashboard, bevor eine Zahl in die Kachel geschrieben wird' {
    $refresh = Get-SourceFunctionText -Part '80-Views.ps1' -Name 'Refresh-Dashboard'
    $refresh | Should -Match 'Test-InventoryContradiction'
    # Und behauptet im Zweifel keine Zahl.
    $refresh | Should -Match "LoadAppsFailedStatus"
  }

  It 'sagt in der Update-Suche, was wirklich fehlt - nicht "keine Apps in Intune"' {
    # Im Portal STEHEN Apps; es fehlen nur solche mit der '[WinTuner|'-Marke. Die alte Meldung hat
    # deshalb in die Irre gefuehrt (Screenshot des Kunden: Dutzende handgebaute Win32-Apps).
    $main = Get-SourcePartText -Part '90-Main.ps1'
    $main | Should -Match 'NoWinTunerAppsStatus'
    $main | Should -Match 'NoWinTunerAppsSupersededStatus'
    $main | Should -Not -Match 'NoAppsInIntuneStatus'
    # Und die abgeloesten Versionen entscheiden, welche der zwei Meldungen es ist.
    $idxGuard = $main.IndexOf('Test-InventoryContradiction')
    $idxMsg = $main.IndexOf('NoWinTunerAppsSupersededStatus')
    $idxGuard | Should -BeGreaterThan 0
    $idxGuard | Should -BeLessThan $idxMsg
  }

  It 'holt bei einer leeren Antwort eine zweite Meinung direkt von Graph' {
    $fn = Get-SourceFunctionText -Part '25-WinGetData.ps1' -Name 'Get-Win32AppsResilient'
    $fn | Should -Match 'Get-Win32AppInventoryViaGraph -Superseded:\$Superseded'
  }
}

Describe 'Ein Runspace, eine Pipeline' {

  BeforeAll {
    . ([scriptblock]::Create((Get-SourceFunctionText -Part '25-WinGetData.ps1' -Name 'Get-Win32AppsOffThread')))
  }

  BeforeEach {
    $script:pkgRunspaceInUse = $false
    $script:packagingBusy = $false
    $global:TestRunspaceAsked = 0
    Set-Item -Path function:global:Get-PackageRunspace -Value { $global:TestRunspaceAsked++; $null }
  }

  It 'arbeitet inline, wenn der Runspace schon eine Abfrage faehrt' {
    # Sonst: "The pipeline was not run because a pipeline is already running" - und die Oberflaeche
    # meldete "Laden der Apps aus Intune fehlgeschlagen", obwohl nur zwei Abfragen kollidierten.
    $script:pkgRunspaceInUse = $true
    Get-Win32AppsOffThread -Query @{ Superseded = $false } -Label 'test' | Should -Be $null
    $global:TestRunspaceAsked | Should -Be 0
  }

  It 'arbeitet inline, waehrend ein Paket gebaut wird' {
    $script:packagingBusy = $true
    Get-Win32AppsOffThread -Query @{ Superseded = $false } -Label 'test' | Should -Be $null
    $global:TestRunspaceAsked | Should -Be 0
  }

  It 'fragt den Runspace, wenn er frei ist' {
    Get-Win32AppsOffThread -Query @{ Superseded = $false } -Label 'test' | Should -Be $null
    $global:TestRunspaceAsked | Should -Be 1
  }
}
