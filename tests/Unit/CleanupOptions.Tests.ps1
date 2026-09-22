BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-UiStringsText)))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '10-Settings.ps1' -Name 'Resolve-CleanupOptionConflict')))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '40-Graph.ps1' -Name 'Get-UpdateCleanupNotice')))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '50-UpdateEngine.ps1' -Name 'Get-BatchSummaryStatus')))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '70-Runtime.ps1' -Name 'Test-WtConnected', 'Get-ConnectionProbeRetryVerdict')))
  $script:uiLanguage = 'de'
}

Describe 'Resolve-CleanupOptionConflict' {
  # The two options are mutually exclusive by construction: immediate removal runs inside the update
  # and always leaves exactly one version, so "keep the newest N" could never apply to the app just
  # updated. The conflict resolves towards the non-destructive option - a predecessor that is still
  # there can be deleted later, one that is gone cannot be brought back.
  It 'switches the destructive option off when both are set' {
    $script:settings = @{ AutoRemoveSuperseded = $true; AutoVersionCleanup = $true }
    Resolve-CleanupOptionConflict | Should -BeTrue
    $script:settings.AutoRemoveSuperseded | Should -BeFalse
    $script:settings.AutoVersionCleanup | Should -BeTrue
  }
  It 'leaves immediate removal alone when it is the only one' {
    $script:settings = @{ AutoRemoveSuperseded = $true; AutoVersionCleanup = $false }
    Resolve-CleanupOptionConflict | Should -BeFalse
    $script:settings.AutoRemoveSuperseded | Should -BeTrue
  }
  It 'leaves version trimming alone when it is the only one' {
    $script:settings = @{ AutoRemoveSuperseded = $false; AutoVersionCleanup = $true }
    Resolve-CleanupOptionConflict | Should -BeFalse
    $script:settings.AutoVersionCleanup | Should -BeTrue
  }
  It 'does nothing when both are off' {
    $script:settings = @{ AutoRemoveSuperseded = $false; AutoVersionCleanup = $false }
    Resolve-CleanupOptionConflict | Should -BeFalse
  }
}

Describe 'Get-UpdateCleanupNotice' {
  # The confirmation used to show one of two fixed paragraphs driven by a single option, so it never
  # said whether assignments would move or whether older versions would be trimmed afterwards -
  # both of which change the tenant.
  BeforeEach { $script:keepVersionCount = 2 }

  It 'states that assignments move when the hand-over is on' {
    $script:settings = @{ MoveAssignmentsOnUpdate = $true; AutoRemoveSuperseded = $false; AutoVersionCleanup = $false }
    Get-UpdateCleanupNotice | Should -Match 'ziehen auf die neue Version um'
  }
  It 'states that assignments stay when the hand-over is off' {
    $script:settings = @{ MoveAssignmentsOnUpdate = $false; AutoRemoveSuperseded = $false; AutoVersionCleanup = $false }
    $notice = Get-UpdateCleanupNotice
    $notice | Should -Match 'bleiben auf der alten Version'
    $notice | Should -Not -Match 'ziehen auf die neue Version um'
  }
  It 'announces deletion of assigned predecessors only when it is enabled' {
    $script:settings = @{ MoveAssignmentsOnUpdate = $true; AutoRemoveSuperseded = $true; AutoVersionCleanup = $false }
    $notice = Get-UpdateCleanupNotice
    $notice | Should -Match 'werden gelöscht'
    $notice | Should -Not -Match 'bleiben erhalten'
  }
  It 'mentions version trimming only when it will run' {
    $script:settings = @{ MoveAssignmentsOnUpdate = $true; AutoRemoveSuperseded = $false; AutoVersionCleanup = $false }
    Get-UpdateCleanupNotice | Should -Not -Match 'neuesten 2 Versionen'

    $script:settings = @{ MoveAssignmentsOnUpdate = $true; AutoRemoveSuperseded = $false; AutoVersionCleanup = $true }
    Get-UpdateCleanupNotice | Should -Match 'neuesten 2 Versionen'
  }
  It 'uses the configured keep count rather than a hard-coded 2' {
    $script:settings = @{ MoveAssignmentsOnUpdate = $true; AutoRemoveSuperseded = $false; AutoVersionCleanup = $true }
    $script:keepVersionCount = 5
    Get-UpdateCleanupNotice | Should -Match 'neuesten 5'
  }
  It 'always states the rule for unassigned predecessors' {
    $script:settings = @{ MoveAssignmentsOnUpdate = $true; AutoRemoveSuperseded = $false; AutoVersionCleanup = $false }
    Get-UpdateCleanupNotice | Should -Match 'ohne Zuweisung'
  }

  # Aus dem Betrieb (22.09.2026): das Aufraeumen entfernte Chrome mit 23 meldenden Geraeten, und
  # der Anwender hatte in genau dieser Rueckfrage gelesen, dass Installationen geprueft werden.
  # Mit VersionCapOverridesInstallations halten sie aber nichts mehr zurueck - der Satz versprach
  # das Gegenteil dessen, was der Lauf tat.
  It 'promises the installation check only when installations really hold a version back' {
    $script:settings = @{ MoveAssignmentsOnUpdate = $true; AutoRemoveSuperseded = $false
                          AutoVersionCleanup = $true; VersionCapOverridesInstallations = $false }
    $notice = Get-UpdateCleanupNotice
    $notice | Should -Match 'kein Gerät sie als installiert meldet'
    $notice | Should -Not -Match 'ACHTUNG'
  }
  It 'says outright that installations do NOT protect once the limit outweighs them' {
    $script:settings = @{ MoveAssignmentsOnUpdate = $true; AutoRemoveSuperseded = $false
                          AutoVersionCleanup = $true; VersionCapOverridesInstallations = $true }
    $notice = Get-UpdateCleanupNotice
    $notice | Should -Match 'schützen eine Version dabei NICHT'
    $notice | Should -Not -Match 'kein Gerät sie als installiert meldet'
  }
  # Gemessen an der gerenderten Rueckfrage: als vierter von vier gleich aussehenden Punkten war die
  # Warnung nicht zu finden. Sie muss ein eigener Absatz sein und zuletzt kommen - direkt ueber den
  # Knoepfen ist die Stelle, die noch gelesen wird.
  It 'puts the warning in its own paragraph at the very end, not as another bullet' {
    $script:settings = @{ MoveAssignmentsOnUpdate = $true; AutoRemoveSuperseded = $false
                          AutoVersionCleanup = $true; VersionCapOverridesInstallations = $true }
    $lines = (Get-UpdateCleanupNotice) -split "`r`n"
    $lines[-1] | Should -Match '^ACHTUNG'
    $lines[-2] | Should -BeExactly ''
    ($lines | Where-Object { $_ -match '^ACHTUNG' }).Count | Should -Be 1
  }
  # Gemeldet am 08.09.2026 fuer das Protokoll, hier fuer die Rueckfrage: das Aufraeumen ist eine
  # tenantweite Regel und kein Anhang an die eben aktualisierte App.
  It 'states the tenant-wide scope in both variants' {
    foreach ($override in @($false, $true)) {
      $script:settings = @{ MoveAssignmentsOnUpdate = $true; AutoRemoveSuperseded = $false
                            AutoVersionCleanup = $true; VersionCapOverridesInstallations = $override }
      Get-UpdateCleanupNotice | Should -Match 'im GANZEN Tenant'
    }
  }
}

# Die Abschlussmeldung eines Laufs. Aus dem Betrieb (22.09.2026): ein Lauf entfernte sieben alte
# Versionen und endete sichtbar mit "4 erfolgreich, 0 fehlgeschlagen" - die Loeschungen standen nur
# im Protokoll und im Leistungsnachweis. Genannt wurde bis dahin nur der FEHLSCHLAG des Aufraeumens.
Describe 'Get-BatchSummaryStatus' {
  It 'names only the run when the cleanup did nothing' {
    $text = Get-BatchSummaryStatus -SuccessCount 4 -FailedCount 0
    $text | Should -Match '4 erfolgreich, 0 fehlgeschlagen'
    $text | Should -Not -Match 'Versionsbereinigung'
  }
  It 'names removed versions even when nothing failed' {
    $text = Get-BatchSummaryStatus -SuccessCount 4 -FailedCount 0 -CleanupRemoved 7
    $text | Should -Match 'hat 7 alte Version\(en\) entfernt'
  }
  It 'still names a failure on its own' {
    $text = Get-BatchSummaryStatus -SuccessCount 3 -FailedCount 0 -CleanupFailed 1
    $text | Should -Match 'nicht entfernen'
    $text | Should -Not -Match 'hat 0 alte'
  }
  It 'names both numbers when both happened' {
    $text = Get-BatchSummaryStatus -SuccessCount 3 -FailedCount 0 -CleanupRemoved 1 -CleanupFailed 2
    $text | Should -Match 'hat 1 alte Version\(en\) entfernt'
    $text | Should -Match 'und 2 nicht entfernen können'
  }
  It 'keeps the four cases apart' {
    $seen = @(
      (Get-BatchSummaryStatus -SuccessCount 1 -FailedCount 0),
      (Get-BatchSummaryStatus -SuccessCount 1 -FailedCount 0 -CleanupRemoved 2),
      (Get-BatchSummaryStatus -SuccessCount 1 -FailedCount 0 -CleanupFailed 2),
      (Get-BatchSummaryStatus -SuccessCount 1 -FailedCount 0 -CleanupRemoved 2 -CleanupFailed 3)
    )
    (@($seen | Select-Object -Unique)).Count | Should -Be 4
  }
}

Describe 'Test-WtConnected' {
  BeforeEach {
    $global:WtCalls = 0
    Set-Item -Path function:global:Get-WtWin32Apps -Value {
      param($Update, $Superseded, $ErrorAction)
      $global:WtCalls++
      & $global:WtHandler $global:WtCalls
    }
  }

  # These shapes mean "ask again", not "you are not signed in": races inside the module's inventory
  # call, throttling, or a momentary service blip. Reporting them as an authentication error sent
  # troubleshooting after credentials that were never the problem.
  It 'retries "Collection was modified" and then succeeds' {
    $global:WtHandler = { param($n) if ($n -lt 2) { throw 'Collection was modified; enumeration operation may not execute.' }; @() }
    Test-WtConnected | Should -BeTrue
    $global:WtCalls | Should -Be 2
  }
  It 'retries "Value cannot be null" as well' {
    $global:WtHandler = { param($n) if ($n -lt 2) { throw "Value cannot be null. (Parameter 'value')" }; @() }
    Test-WtConnected | Should -BeTrue
    $global:WtCalls | Should -Be 2
  }
  It 'gives up after the configured number of attempts' {
    $global:WtHandler = { param($n) throw 'Collection was modified; enumeration operation may not execute.' }
    Test-WtConnected -Attempts 2 | Should -BeFalse
    $global:WtCalls | Should -Be 2
  }
  It 'fails immediately on a permission error, because retrying cannot fix it' {
    $global:WtHandler = { param($n) throw 'Forbidden. Required permission scope DeviceManagementApps.ReadWrite.All is missing.' }
    Test-WtConnected | Should -BeFalse
    $global:WtCalls | Should -Be 1
  }
  It 'treats an empty tenant as a valid answer' {
    $global:WtHandler = { param($n) @() }
    Test-WtConnected | Should -BeTrue
    $global:WtCalls | Should -Be 1
  }

  # Aus dem Betrieb (22.09.2026): zwei Anmeldungen scheiterten mit einem 403, die dritte 27 s
  # spaeter lief durch - dasselbe Konto, derselbe Tenant, danach 149 gelesene App-Objekte. Bis
  # 0.21.1 gab die Sonde nach dem ERSTEN Versuch auf, weil "Forbidden" in keiner transienten Form
  # stand. Der Anwender musste von Hand nachklicken, und das Protokoll sagte trotzdem "attempt 1/3".
  It 'retries a bare 403 right after sign-in, because the token may not be usable yet' {
    $global:WtHandler = {
      param($n)
      if ($n -lt 2) { throw '{"ErrorCode":"Forbidden","Message":"An error has occurred - Activity ID: c5f5100c","HttpHeaders":"{\"WWW-Authenticate\":\"Bearer\"}"}' }
      @()
    }
    Test-WtConnected | Should -BeTrue
    $global:WtCalls | Should -Be 2
  }
}

Describe 'Get-ConnectionProbeRetryVerdict' {
  It 'retries the known transient shapes' {
    foreach ($shape in @('Collection was modified', "Value cannot be null. (Parameter 'value')",
                         'The operation timed out', 'ServiceUnavailable', 'Too Many Requests', 'HTTP 503')) {
      (Get-ConnectionProbeRetryVerdict -Message $shape).Retry | Should -BeTrue -Because $shape
    }
  }
  # Die Unterscheidung, um die es geht: ein 403 ist nicht gleich ein 403.
  It 'retries a 403 that names no permission' {
    $verdict = Get-ConnectionProbeRetryVerdict -Message '{"ErrorCode":"Forbidden","Message":"An error has occurred"}'
    $verdict.Retry | Should -BeTrue
    $verdict.Reason | Should -Match 'token'
  }
  It 'does NOT retry a 403 that names a missing permission - retrying cannot fix that' {
    foreach ($text in @('Forbidden. Required permission scope DeviceManagementApps.ReadWrite.All is missing.',
                        '403 Forbidden - insufficient privilege',
                        'Forbidden: access denied')) {
      (Get-ConnectionProbeRetryVerdict -Message $text).Retry | Should -BeFalse -Because $text
    }
  }
  It 'does not retry an unknown shape' {
    (Get-ConnectionProbeRetryVerdict -Message 'Something else entirely').Retry | Should -BeFalse
  }
  It 'does not retry an empty message' {
    (Get-ConnectionProbeRetryVerdict -Message '').Retry | Should -BeFalse
  }
  It 'always gives a reason, so the log never has to guess' {
    foreach ($text in @('', 'Collection was modified', 'Forbidden', 'Forbidden: permission missing', 'weird')) {
      (Get-ConnectionProbeRetryVerdict -Message $text).Reason | Should -Not -BeNullOrEmpty
    }
  }
}
