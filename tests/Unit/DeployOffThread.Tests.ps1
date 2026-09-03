# Der Upload laeuft im Hintergrund-Runspace.
#
# Gemeldet am 02.09.2026 aus dem Betrieb: waehrend eines Uploads steht das Fenster auf "Keine
# Rueckmeldung", und die Konsole fuellt sich mit "[ERROR] Write log to PowerShell failed: ... same
# thread". Beides hatte EINE Ursache - Deploy-WtWin32App lief auf dem UI-Faden.
#
# Was hier geprueft wird, ist nicht die Nebenlaeufigkeit selbst (die braucht das Modul und einen
# echten Tenant), sondern die drei Zusicherungen, an denen ein Upload teuer scheitern wuerde:
#   * ohne Runspace wird inline hochgeladen statt gar nicht,
#   * der Fehler des Moduls kommt unveraendert beim Aufrufer an (dessen Textpruefungen haengen dran),
#   * der Upload wird NIE abgebrochen - ein halber Upload laesst eine halb angelegte App im Tenant.

BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '35-Packaging.ps1' -Name @(
    'Invoke-WtModuleCallOffThread', 'Invoke-WtDeployOffThread'))))

  # Kein Runspace: damit laeuft in jedem Fall der Inline-Zweig, und die Attrappe unten wird wirklich
  # gerufen. Der Runspace-Zweig wuerde das WinTuner-Modul importieren - das ist Sache des
  # Modulvertrags, nicht dieser Datei.
  Set-Item -Path function:global:Get-DeployRunspace -Value { $null }

  $global:DeployCalls = [System.Collections.Generic.List[hashtable]]::new()
  Set-Item -Path function:global:Deploy-WtWin32App -Value {
    param(
      [string]$PackageId, [string]$Version, [string]$RootPackageFolder, [string]$GraphId,
      [switch]$KeepAssignments, [string]$OverrideAppName, $Categories, $RoleScopeTags,
      $ErrorAction
    )
    $global:DeployCalls.Add(@{ PackageId = $PackageId; Version = $Version; GraphId = $GraphId })
    if ($PackageId -eq 'Fail.App') { throw 'Forbidden. Insufficient privileges to complete the operation.' }
    return [pscustomobject]@{ Id = 'graph-id-from-module' }
  }
}

Describe 'Invoke-WtDeployOffThread' {

  # Pester 5 laesst BeforeEach nur INNERHALB eines Blocks zu; auf oberster Ebene bricht der ganze
  # Container mit "Each test setup is not supported in root" ab - und dann laeuft keiner der Faelle.
  BeforeEach {
    $global:DeployCalls.Clear()
    $global:TestLog.Clear()
  }

  It 'laedt ohne Hintergrund-Runspace inline hoch, statt aufzugeben' {
    $r = Invoke-WtDeployOffThread -Arguments @{ PackageId = 'Google.Chrome'; Version = '1.2.3'; ErrorAction = 'Stop' } -Label 'Chrome'
    $global:DeployCalls.Count | Should -Be 1
    $global:DeployCalls[0].PackageId | Should -Be 'Google.Chrome'
    $r.Id | Should -Be 'graph-id-from-module'
  }

  # Ein stiller Rueckfall waere hier das Schlimmste: der Anwender sieht ein eingefrorenes Fenster und
  # nichts erklaert es. Genau das war die Meldung.
  It 'protokolliert den Inline-Rueckfall samt Folge fuer das Fenster' {
    [void](Invoke-WtDeployOffThread -Arguments @{ PackageId = 'Google.Chrome'; ErrorAction = 'Stop' } -Label 'Chrome 1.2.3')
    ($global:TestLog -join "`n") | Should -Match 'on the UI thread'
    ($global:TestLog -join "`n") | Should -Match 'Chrome 1\.2\.3'
  }

  # Die Aufrufer pruefen den Fehlertext (403, Duplikat). Wird er umgeformt, greift keine dieser
  # Pruefungen mehr - und der Anwender bekommt statt der Klartextmeldung den rohen Graph-Text.
  It 'reicht den Fehler des Moduls unveraendert weiter' {
    { Invoke-WtDeployOffThread -Arguments @{ PackageId = 'Fail.App'; ErrorAction = 'Stop' } -Label 'Fail' } |
      Should -Throw -ExpectedMessage '*Insufficient privileges*'
  }

  It 'gibt den Argumentsatz vollstaendig weiter' {
    [void](Invoke-WtDeployOffThread -Arguments @{ PackageId = 'X.Y'; Version = '9'; GraphId = 'abc'; ErrorAction = 'Stop' } -Label 'X')
    $global:DeployCalls[0].Version | Should -Be '9'
    $global:DeployCalls[0].GraphId | Should -Be 'abc'
  }
}

Describe 'Zusicherungen im Quelltext' {

  BeforeAll {
    # Die Politik (kein Abbruch, kein Zeitablauf, DoEvents, Fehler auspacken) sitzt seit dem
    # Loesch-Fix im gemeinsamen Rumpf: Upload UND Loeschen teilen sie sich, und zweimal
    # geschrieben waere sie beim naechsten Mal einmal geaendert.
    $script:fnText = Get-SourceFunctionText -Part '35-Packaging.ps1' -Name @(
      'Invoke-WtModuleCallOffThread', 'Invoke-WtDeployOffThread')
  }

  # Der Unterschied zum Paketbau, und der Grund, aus dem der Trichter nicht von ihm abgeleitet ist:
  # der Paketbau schreibt lokale Dateien und darf gestoppt werden, ein Upload legt eine App im
  # Kundentenant an. Ein Stop mitten darin laesst eine halbe App zurueck, die niemand sucht.
  It 'bricht den Upload nie ab und kennt keinen Zeitablauf' {
    $script:fnText | Should -Not -Match '\.Stop\(\)'
    $script:fnText | Should -Not -Match 'TimeoutMinutes'
    $script:fnText | Should -Not -Match 'cancelBatch'
  }

  # Zwei Pipelines in einem Runspace laufen in "Pipelines cannot be run concurrently" - dasselbe
  # Bild, das die Inventar-Abfrage am 26.08.2026 als "Laden der Apps fehlgeschlagen" zeigte. Ist der
  # Runspace besetzt, ist inline richtig; gewartet wird nicht. Geprueft am Quelltext, weil der
  # Merker im Skript-Bereich der Anwendung liegt und aus dem Testbereich nicht sichtbar ist.
  It 'fragt den Runspace nur, wenn er nicht besetzt ist' {
    $script:fnText | Should -Match 'if \(-not \$script:deployRunspaceInUse\)'
    $script:fnText | Should -Match '\$script:deployRunspaceInUse = \$true'
  }

  # Ohne DoEvents waere die ganze Auslagerung wirkungslos: das Fenster stuende weiter still.
  It 'pumpt die Nachrichtenschleife, waehrend der Upload laeuft' {
    $script:fnText | Should -Match 'DoEvents'
  }

  # BeginInvoke/EndInvoke verpacken den Modulfehler. Ohne das Auspacken kaeme bei den Aufrufern
  # "Exception calling ..." an statt der Meldung, auf die sie pruefen.
  It 'packt den verpackten Modulfehler aus' {
    $script:fnText | Should -Match 'InnerException'
  }

  # Ein eigener Runspace, nicht der des Paketbaus: waehrend des Uploads baut der Vorab-Bau schon die
  # naechste App. Geteilt waere genau das dahin.
  It 'benutzt einen eigenen Runspace, nicht den des Paketbaus oder des Vorab-Baus' {
    $script:fnText | Should -Match 'Get-DeployRunspace'
    $script:fnText | Should -Not -Match 'Get-PackageRunspace'
    $script:fnText | Should -Not -Match 'Get-PrebuildRunspace'
    (Get-SourcePartText -Part '35-Packaging.ps1') | Should -Match '\$script:deployRunspace = New-PackagingRunspace'
  }

  # Ein offener Runspace haelt mit seinem Thread das Beenden auf - derselbe Grund, aus dem die
  # anderen zwei dort geschlossen werden.
  It 'wird beim Beenden abgeraeumt' {
    (Get-SourcePartText -Part '90-Main.ps1') | Should -Match 'Close-DeployRunspace'
  }
}
