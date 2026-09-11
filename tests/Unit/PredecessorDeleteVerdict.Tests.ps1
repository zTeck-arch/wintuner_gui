#requires -Version 7
# Darf die Vorgaengerversion geloescht werden?
#
# Das ist die folgenreichste Entscheidung dieser Anwendung, und bis 0.19.1 war sie nicht pruefbar:
# vier Bedingungen ueber drei Sondierungen, als lose Ausdruecke mitten in Update-SingleApp (438
# Zeilen), gefolgt von einer elseif-Kette fuer den Protokolltext. Wer sie pruefen wollte, musste
# einen ganzen Update-Lauf gegen einen echten Tenant fuehren - also hat es niemand getan.
#
# Die Leitregel hinter allen Faellen unten: eine Sondierung, die NICHT geantwortet hat, zaehlt nie
# als "ist frei". Unbekannt heisst behalten. Der umgekehrte Fehler ist nicht reparierbar - eine
# geloeschte Intune-App laesst sich nicht zurueckholen, und ihre Zuweisungen sind mit weg.

BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '50-UpdateEngine.ps1' -Name @(
    'Get-ConsolidationDeleteVerdict', 'Get-UnusedPredecessorDeleteVerdict'))))

  # Eine Sondierung, wie sie Get-AppAssignmentProbe / Get-AppInstallationProbe liefern.
  function New-Probe {
    param([bool]$Succeeded = $true, [bool]$HasAssignments = $false, [bool]$HasInstallations = $false)
    [pscustomobject]@{ Succeeded = $Succeeded; HasAssignments = $HasAssignments; HasInstallations = $HasInstallations }
  }
  $script:free  = New-Probe                                  # geantwortet, nichts dran
  $script:blind = New-Probe -Succeeded $false                # keine Antwort bekommen
}

Describe 'Get-ConsolidationDeleteVerdict' {

  It 'gibt frei, wenn nichts dagegen spricht' {
    $v = Get-ConsolidationDeleteVerdict -AssignmentProbe $script:free -PostAssignmentProbe $script:free `
      -PreInstallProbe $script:free -PostInstallProbe $script:free -AutoRemoveSuperseded $false
    $v.SafeExceptHandover | Should -BeTrue
    $v.KeepReason | Should -Be ''
  }

  It 'verlangt die Uebergabepruefung NUR, wenn die alte App Zuweisungen hatte' {
    # Sie kostet Graph-Aufrufe und eine Wartezeit. Eine App, die nie zugewiesen war, hat nichts zu
    # uebergeben - da waere die Frage nur Zeit.
    $ohne = Get-ConsolidationDeleteVerdict -AssignmentProbe $script:free -PostAssignmentProbe $script:free `
      -PreInstallProbe $script:free -PostInstallProbe $script:free -AutoRemoveSuperseded $false
    $ohne.NeedsHandoverCheck | Should -BeFalse

    $mit = Get-ConsolidationDeleteVerdict -AssignmentProbe (New-Probe -HasAssignments $true) `
      -PostAssignmentProbe $script:free -PreInstallProbe $script:free -PostInstallProbe $script:free `
      -AutoRemoveSuperseded $true
    $mit.SafeExceptHandover | Should -BeTrue
    $mit.NeedsHandoverCheck | Should -BeTrue
  }

  It 'fragt die Uebergabe nicht, wenn ohnehin nicht geloescht wird' {
    # Sonst kostet ein Lauf die teure Sondierung fuer eine App, die danach doch stehen bleibt.
    $v = Get-ConsolidationDeleteVerdict -AssignmentProbe (New-Probe -HasAssignments $true) `
      -PostAssignmentProbe $script:free -PreInstallProbe (New-Probe -HasInstallations $true) `
      -PostInstallProbe $script:free -AutoRemoveSuperseded $true
    $v.SafeExceptHandover | Should -BeFalse
    $v.NeedsHandoverCheck | Should -BeFalse
  }

  It 'behaelt, wenn eine Installationssondierung nicht geantwortet hat' {
    foreach ($fall in @(
      @{ Pre = $script:blind; Post = $script:free },
      @{ Pre = $script:free;  Post = $script:blind })) {
      $v = Get-ConsolidationDeleteVerdict -AssignmentProbe $script:free -PostAssignmentProbe $script:free `
        -PreInstallProbe $fall.Pre -PostInstallProbe $fall.Post -AutoRemoveSuperseded $true
      $v.SafeExceptHandover | Should -BeFalse
      $v.KeepReason | Should -Be 'unverifiable'
    }
  }

  It 'behaelt, wenn die Zuweisungssondierung nicht geantwortet hat' {
    $v = Get-ConsolidationDeleteVerdict -AssignmentProbe $script:free -PostAssignmentProbe $script:blind `
      -PreInstallProbe $script:free -PostInstallProbe $script:free -AutoRemoveSuperseded $true
    $v.SafeExceptHandover | Should -BeFalse
    $v.KeepReason | Should -Be 'unverifiable'
  }

  It 'behaelt und SAGT ES, wenn die alte App noch zugewiesen ist' {
    # Bis 0.19.1 fiel genau dieser Fall durch die elseif-Kette: die App blieb stehen, und im
    # Protokoll stand kein Wort dazu. Wer danach suchte, warum nichts passiert ist, fand nichts.
    $v = Get-ConsolidationDeleteVerdict -AssignmentProbe $script:free `
      -PostAssignmentProbe (New-Probe -HasAssignments $true) `
      -PreInstallProbe $script:free -PostInstallProbe $script:free -AutoRemoveSuperseded $true
    $v.SafeExceptHandover | Should -BeFalse
    $v.KeepReason | Should -Be 'assigned'
  }

  It 'behaelt bei gemeldeten Installationen - davor wie danach' {
    foreach ($fall in @(
      @{ Pre = (New-Probe -HasInstallations $true); Post = $script:free },
      @{ Pre = $script:free; Post = (New-Probe -HasInstallations $true) })) {
      $v = Get-ConsolidationDeleteVerdict -AssignmentProbe $script:free -PostAssignmentProbe $script:free `
        -PreInstallProbe $fall.Pre -PostInstallProbe $fall.Post -AutoRemoveSuperseded $true
      $v.SafeExceptHandover | Should -BeFalse
      $v.KeepReason | Should -Be 'installations'
    }
  }

  It 'behaelt eine EINST zugewiesene App, solange die Einstellung das Loeschen nicht erlaubt' {
    $v = Get-ConsolidationDeleteVerdict -AssignmentProbe (New-Probe -HasAssignments $true) `
      -PostAssignmentProbe $script:free -PreInstallProbe $script:free -PostInstallProbe $script:free `
      -AutoRemoveSuperseded $false
    $v.SafeExceptHandover | Should -BeFalse
    $v.KeepReason | Should -Be 'policy'
  }

  It 'loescht eine NIE zugewiesene App auch bei abgeschalteter Einstellung' {
    # Die Einstellung heisst "abgeloeste ZUGEWIESENE Vorgaenger automatisch entfernen". Eine App,
    # die niemand bekommen hat, faellt nicht darunter.
    $v = Get-ConsolidationDeleteVerdict -AssignmentProbe $script:free -PostAssignmentProbe $script:free `
      -PreInstallProbe $script:free -PostInstallProbe $script:free -AutoRemoveSuperseded $false
    $v.SafeExceptHandover | Should -BeTrue
  }

  It 'behandelt eine fehlende Sondierung wie eine, die nicht geantwortet hat' {
    # $null kommt vor: der Aufrufer sondiert die Installationen nur auf bestimmten Wegen.
    $v = Get-ConsolidationDeleteVerdict -AssignmentProbe $script:free -PostAssignmentProbe $script:free `
      -PreInstallProbe $null -PostInstallProbe $script:free -AutoRemoveSuperseded $true
    $v.SafeExceptHandover | Should -BeFalse
    $v.KeepReason | Should -Be 'unverifiable'
  }

  It 'nennt bei mehreren Gruenden den nicht nachweisbaren zuerst' {
    # Wer den Protokolltext liest, soll den schwersten Grund sehen und nicht den zufaellig zuletzt
    # geprueften: "konnte nicht geprueft werden" ist eine andere Aussage als "ist noch in Benutzung".
    $v = Get-ConsolidationDeleteVerdict -AssignmentProbe $script:free -PostAssignmentProbe $script:blind `
      -PreInstallProbe (New-Probe -HasInstallations $true) -PostInstallProbe $script:blind `
      -AutoRemoveSuperseded $false
    $v.KeepReason | Should -Be 'unverifiable'
  }
}

Describe 'Get-UnusedPredecessorDeleteVerdict' {

  It 'loescht nur bei drei bestaetigten Nullbefunden' {
    $v = Get-UnusedPredecessorDeleteVerdict -PostAssignmentProbe $script:free `
      -PreInstallProbe $script:free -PostInstallProbe $script:free
    $v.Delete | Should -BeTrue
    $v.KeepReason | Should -Be ''
  }

  It 'behaelt, wenn die alte App waehrend des Laufs eine Zuweisung bekommen hat' {
    # Der Grund fuer die Nachpruefung ueberhaupt: zwischen Paketbau und Ende des Uploads liegen
    # Minuten, und in dieser Zeit kann jemand im Portal zugewiesen haben.
    $v = Get-UnusedPredecessorDeleteVerdict -PostAssignmentProbe (New-Probe -HasAssignments $true) `
      -PreInstallProbe $script:free -PostInstallProbe $script:free
    $v.Delete | Should -BeFalse
    $v.KeepReason | Should -Be 'assigned'
  }

  It 'behaelt bei Installationen davor wie danach' {
    foreach ($fall in @(
      @{ Pre = (New-Probe -HasInstallations $true); Post = $script:free },
      @{ Pre = $script:free; Post = (New-Probe -HasInstallations $true) })) {
      $v = Get-UnusedPredecessorDeleteVerdict -PostAssignmentProbe $script:free `
        -PreInstallProbe $fall.Pre -PostInstallProbe $fall.Post
      $v.Delete | Should -BeFalse
      $v.KeepReason | Should -Be 'installations'
    }
  }

  It 'behaelt, wenn eine Sondierung nicht geantwortet hat oder fehlt' {
    foreach ($fall in @(
      @{ A = $script:blind; Pre = $script:free;  Post = $script:free },
      @{ A = $script:free;  Pre = $script:blind; Post = $script:free },
      @{ A = $script:free;  Pre = $script:free;  Post = $script:blind },
      @{ A = $script:free;  Pre = $null;         Post = $script:free })) {
      $v = Get-UnusedPredecessorDeleteVerdict -PostAssignmentProbe $fall.A `
        -PreInstallProbe $fall.Pre -PostInstallProbe $fall.Post
      $v.Delete | Should -BeFalse
      $v.KeepReason | Should -Be 'unverifiable'
    }
  }

  It 'nennt "unverifiable" und nicht "assigned", wenn die Zuweisung gar nicht lesbar war' {
    # Eine Sondierung ohne Antwort darf nicht als "hat eine Zuweisung" erklaert werden - das waere
    # eine Behauptung ueber etwas, das niemand gesehen hat.
    $v = Get-UnusedPredecessorDeleteVerdict -PostAssignmentProbe (New-Probe -Succeeded $false -HasAssignments $true) `
      -PreInstallProbe $script:free -PostInstallProbe $script:free
    $v.KeepReason | Should -Be 'unverifiable'
  }
}

Describe 'Verdrahtung: der Motor benutzt die Urteile' {
  BeforeAll {
    # Der Zusammenfuehrungsweg steht seit 0.19.1 in einer eigenen Funktion; der Upload-Weg blieb in
    # Update-SingleApp. Geprueft wird deshalb der Teil als Ganzes und zusaetzlich jede Stelle dort,
    # wo sie tatsaechlich sitzt.
    $script:engine = Get-SourcePartText -Part '50-UpdateEngine.ps1'
    $script:consolidation = Get-SourceFunctionText -Part '50-UpdateEngine.ps1' -Name 'Invoke-ExistingTargetConsolidation'
    $script:single = Get-SourceFunctionText -Part '50-UpdateEngine.ps1' -Name 'Update-SingleApp'
  }

  It 'rechnet die Loeschentscheidung in KEINEM der beiden Wege mehr selbst' {
    # Sonst laufen die geprueften Regeln und die tatsaechlich angewandten auseinander - der
    # gefaehrlichste Ausgang eines solchen Umbaus, weil die Tests dann gruen bleiben.
    #
    # Geprueft werden die zwei AUFRUFER, nicht der ganze Teil: in Get-ConsolidationDeleteVerdict
    # selbst stehen diese Ausdruecke natuerlich weiterhin - dort gehoeren sie hin. Ein Test gegen
    # den ganzen Teil schlug genau daran fehl.
    foreach ($code in @($script:consolidation, $script:single)) {
      $code | Should -Not -Match '\$safeExceptHandover = \('
      $code | Should -Not -Match '\$safeToDeleteUnusedPredecessor = \('
      $code | Should -Not -Match '\$zeroInstallationsConfirmed = \('
      $code | Should -Not -Match '\$mayDeleteByPolicy = '
    }
  }

  It 'faellt das Urteil im Zusammenfuehrungsweg ueber Get-ConsolidationDeleteVerdict' {
    $script:consolidation | Should -Match 'Get-ConsolidationDeleteVerdict'
    $script:consolidation | Should -Match 'if \(\$verdict\.NeedsHandoverCheck\)'
  }

  It 'loescht dort weiterhin nur nach bestaetigter Uebergabe' {
    # Das Urteil allein genuegt nicht: SafeExceptHandover heisst "alles ausser der Uebergabe".
    $script:consolidation | Should -Match '\$safeToDelete = \(\$verdict\.SafeExceptHandover -and \$handoverConfirmed\)'
  }

  It 'faellt das Urteil nach dem Upload ueber Get-UnusedPredecessorDeleteVerdict' {
    $script:single | Should -Match 'Get-UnusedPredecessorDeleteVerdict'
    $script:single | Should -Match 'if \(\$unusedVerdict\.Delete\)'
  }

  It 'ruft den Zusammenfuehrungsweg genau einmal auf und gibt sein Ergebnis zurueck' {
    # Ohne das `return` liefe der Lauf danach in den Paketbau - er wuerde also bauen, obwohl die
    # Zielversion schon im Tenant liegt. Genau das soll dieser Weg verhindern.
    ([regex]::Matches($script:single, 'Invoke-ExistingTargetConsolidation')).Count | Should -Be 1
    $script:single | Should -Match 'return \(Invoke-ExistingTargetConsolidation'
  }
}
