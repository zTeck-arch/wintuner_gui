# Warum ein Lauf so lange dauert - die drei Posten aus dem Protokoll vom 26.08.2026, 13:37.
#
#   1. Jede Installationssonde brauchte 5-8 s, weil sie in DIESEM Tenant erst zwei Quellen fragte,
#      die mit HTTP 400 antworten, und erst dann die dritte, die antwortet.
#   2. Die Frage "welche Version ist die neueste?" wurde beim Anmelden zweimal je App gestellt -
#      einmal von der Dashboard-Kachel, Sekunden spaeter von der automatischen Update-Suche.
#   3. Der automatische Favoritenlauf wartete 35 s HTTP-429-Sperre ab, waehrend er die Busy-Sperre
#      hielt - die Anmeldung und die Update-Suche warteten mit.

BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '20-Version.ps1' -Name @(
    'Test-GuidString', 'Test-IsNewerVersion', 'Get-ComparableVersionParts'))))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '40-Graph.ps1' -Name @(
    'Get-AppInstallationProbe', 'Clear-InstallProbeSource'))))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '25-WinGetData.ps1' -Name @(
    'Get-FreshLatestPackageVersion', 'Clear-LatestVersionCache'))))
  $script:latestVersionCacheSeconds = 300
}

Describe 'Installationssonde: die Quelle, die antwortet, wird zuerst gefragt' {

  BeforeEach {
    Clear-InstallProbeSource
    $global:TestCalls = @()
    Set-Item -Path function:global:Get-WtToken -Value { 'token' }
    # Der gemeldete Tenant: /deviceStatuses und installSummary antworten mit HTTP 400, nur der
    # Statusbericht liefert eine Zahl.
    Set-Item -Path function:global:Invoke-RestMethod -Value {
      param($Uri, $Method, $Headers, $ErrorAction)
      $global:TestCalls += 'deviceStatuses'
      throw 'HTTP 400 Bad Request'
    }
    Set-Item -Path function:global:Get-AppInstallSummaryCount -Value {
      param($Base, $Headers)
      $global:TestCalls += 'installSummary'
      return $null
    }
    Set-Item -Path function:global:Get-AppInstallCountsFromReport -Value {
      param($AppId, $Headers)
      $global:TestCalls += 'report'
      return [pscustomobject]@{ InstalledCount = 0; RowCount = 0 }
    }
  }

  It 'fragt beim ersten Mal alle drei Quellen der Reihe nach' {
    $probe = Get-AppInstallationProbe -AppId '3b97b055-129d-46d5-a51d-0806d4026742' -AppName 'Testapp'
    $probe.Succeeded | Should -BeTrue
    $probe.HasInstallations | Should -BeFalse
    $global:TestCalls | Should -Be @('deviceStatuses', 'installSummary', 'report')
  }

  It 'ueberspringt beim zweiten Mal die Quelle, die nicht antwortet' {
    [void](Get-AppInstallationProbe -AppId '3b97b055-129d-46d5-a51d-0806d4026742' -AppName 'Testapp')
    $global:TestCalls = @()
    $probe = Get-AppInstallationProbe -AppId '7fd7f027-56f3-40e0-804d-31c1e6fff259' -AppName 'Zweite App'
    $probe.Succeeded | Should -BeTrue
    # Kein 'deviceStatuses' mehr - und die Auskunft ist dieselbe.
    $global:TestCalls | Should -Be @('installSummary', 'report')
  }

  It 'faengt nach einem Tenant-Wechsel wieder mit der dokumentierten Reihenfolge an' {
    [void](Get-AppInstallationProbe -AppId '3b97b055-129d-46d5-a51d-0806d4026742' -AppName 'Testapp')
    Clear-InstallProbeSource
    $global:TestCalls = @()
    [void](Get-AppInstallationProbe -AppId '3b97b055-129d-46d5-a51d-0806d4026742' -AppName 'Testapp')
    $global:TestCalls | Should -Be @('deviceStatuses', 'installSummary', 'report')
  }

  It 'aendert die Sicherheitsregel nicht: eine Null braucht eine zweite Quelle' {
    # Nur deviceStatuses antwortet, und zwar mit "keine" - ohne Bestaetigung bleibt der Zustand
    # unbekannt, und unbekannt verhindert jedes Loeschen.
    Set-Item -Path function:global:Invoke-RestMethod -Value {
      param($Uri, $Method, $Headers, $ErrorAction)
      $global:TestCalls += 'deviceStatuses'
      return [pscustomobject]@{ value = @() }
    }
    Set-Item -Path function:global:Get-AppInstallSummaryCount -Value { param($Base, $Headers) $global:TestCalls += 'installSummary'; $null }
    Set-Item -Path function:global:Get-AppInstallCountsFromReport -Value { param($AppId, $Headers) throw 'no report' }
    $probe = Get-AppInstallationProbe -AppId '3b97b055-129d-46d5-a51d-0806d4026742' -AppName 'Testapp'
    $probe.Succeeded | Should -BeFalse
    $probe.HasInstallations | Should -BeTrue   # unbekannt = schuetzend
  }
}

Describe 'Versionsabfragen: einmal je Paket, nicht zweimal je Anmeldung' {

  BeforeEach {
    Clear-LatestVersionCache
    $global:TestLookups = 0
    Set-Item -Path function:global:Initialize-WingetPackageIndex -Value { }
    Set-Item -Path function:global:Complete-WingetPackageIndexWarmup -Value { }
    Set-Item -Path function:global:Get-WtPackageIndexLatestVersion -Value {
      param($PackageId)
      $global:TestLookups++
      return '151.0.7922.174'
    }
    Set-Item -Path function:global:Get-WingetVersions -Value { param($PackageId, [switch]$ForceRefresh) @('151.0.7922.174') }
  }

  It 'fragt dieselbe Version innerhalb des Zeitfensters nur einmal ab' {
    (Get-FreshLatestPackageVersion -PackageId 'Google.Chrome').Latest | Should -Be '151.0.7922.174'
    (Get-FreshLatestPackageVersion -PackageId 'Google.Chrome').Latest | Should -Be '151.0.7922.174'
    (Get-FreshLatestPackageVersion -PackageId 'google.chrome').Latest | Should -Be '151.0.7922.174'
    $global:TestLookups | Should -Be 1
  }

  It 'liest auf ausdruecklichen Wunsch frisch' {
    [void](Get-FreshLatestPackageVersion -PackageId 'Google.Chrome')
    [void](Get-FreshLatestPackageVersion -PackageId 'Google.Chrome' -Force)
    $global:TestLookups | Should -Be 2
  }

  It 'merkt sich auch ein leeres Ergebnis' {
    # Ein Paket ohne auffindbare Version findet auch die zweite Abfrage nicht - genau die kostete Zeit.
    Set-Item -Path function:global:Get-WtPackageIndexLatestVersion -Value { param($PackageId) $global:TestLookups++; $null }
    Set-Item -Path function:global:Get-WingetVersions -Value { param($PackageId, [switch]$ForceRefresh) @() }
    (Get-FreshLatestPackageVersion -PackageId 'Gibt.Es.Nicht').Latest | Should -BeNullOrEmpty
    (Get-FreshLatestPackageVersion -PackageId 'Gibt.Es.Nicht').Latest | Should -BeNullOrEmpty
    $global:TestLookups | Should -Be 1
  }

  It 'vergisst alles beim Tenant-Wechsel' {
    [void](Get-FreshLatestPackageVersion -PackageId 'Google.Chrome')
    Clear-LatestVersionCache
    [void](Get-FreshLatestPackageVersion -PackageId 'Google.Chrome')
    $global:TestLookups | Should -Be 2
  }
}

Describe 'Wer die Caches leert und wer frisch liest' {

  It 'leert beide Zwischenspeicher beim Tenant-Wechsel' {
    $fn = Get-SourceFunctionText -Part '85-Rows.ps1' -Name 'Clear-TenantViews'
    $fn | Should -Match 'Clear-LatestVersionCache'
    $fn | Should -Match 'Clear-InstallProbeSource'
  }

  It 'liest in der Update-Suche frisch, wenn der Benutzer sie angestossen hat' {
    $main = Get-SourcePartText -Part '90-Main.ps1'
    $main | Should -Match 'Get-FreshLatestPackageVersion -PackageId \$wingetId -Force:\(-not \$script:automaticTrigger\)'
  }

  It 'wartet im automatischen Favoritenlauf nur eine 429-Sperre ab' {
    $views = Get-SourcePartText -Part '80-Views.ps1'
    $views | Should -Match '-ThrottleRetries \$\(if \(\$Automatic\) \{ 1 \} else \{ 3 \}\)'
    $pack = Get-SourceFunctionText -Part '35-Packaging.ps1' -Name 'New-WingetPackageWithFallback'
    $pack | Should -Match '\[int\]\$ThrottleRetries = 3'
    $pack | Should -Match '-MaxRetries \$ThrottleRetries'
  }
}

Describe 'Zuweisungen fragen immer nach' {

  BeforeAll {
    . ([scriptblock]::Create((Get-SourceFunctionText -Part '70-Runtime.ps1' -Name 'Confirm-ChangeAction')))
  }

  It 'laesst die Einstellung "Rueckfragen abschalten" eine -AlwaysAsk-Frage nicht schlucken' {
    Set-Item -Path function:global:Test-ChangeConfirmationsSuppressed -Value { $true }
    # Ohne -AlwaysAsk: durchgewinkt (das ist der Zweck der Einstellung).
    Confirm-ChangeAction -Text 'x' -Title 'y' -LogContext 'update run' | Should -BeTrue
    # Mit -AlwaysAsk muesste ein Dialog aufgehen - im Test faengt der Fehler das ab, statt zu haengen.
    Set-Item -Path function:global:Test-ChangeConfirmationsSuppressed -Value { $true }
    $fn = Get-SourceFunctionText -Part '70-Runtime.ps1' -Name 'Confirm-ChangeAction'
    $fn | Should -Match 'if \(-not \$AlwaysAsk -and \(Test-ChangeConfirmationsSuppressed\)\)'
  }

  It 'benutzt -AlwaysAsk beim Schreiben der Zuweisungen einer Tenant-App' {
    $fn = Get-SourceFunctionText -Part '82-TenantApps.ps1' -Name 'Show-AssignmentManagerDialog'
    $fn | Should -Match '-AlwaysAsk -LogContext'
  }
}
