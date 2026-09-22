#requires -Version 7
# Was passiert mit den in der Abloese-Karte ANGEHAKTEN Apps - und warum?
#
# Aus dem Betrieb am 15.09.2026: nach einem Update standen drei abgeloeste Fassungen in der Liste,
# alle mit assignments=False - die Zuweisung war laengst auf die neue Version umgezogen. Gehalten
# hat sie allein der Installationsbericht. "Markierte loeschen" meldete Lauf um Lauf
# "0 removed, 3 kept", und im Fenster stand kein Grund dafuer.
#
# Die Einordnung, die die neue Einstellung vertretbar macht: eine geloeschte Intune-App wird auf dem
# Geraet NICHT deinstalliert, und fuer das Nachziehen braucht niemand das alte Objekt - die Geraete
# bekommen die neuere Fassung ueber DEREN Zuweisung und die Abloesebeziehung.
#
# Drei Riegel bleiben und werden hier einzeln festgehalten:
#   1. Zuweisungen schuetzen - auch mit der Einstellung.
#   2. Unbekannt heisst behalten - auch mit der Einstellung.
#   3. Ohne die Einstellung aendert sich gar nichts am bisherigen Verhalten.

BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  # Der Plan faellt kein eigenes Urteil, er ordnet das von Get-SafetyNetDeleteVerdict ein - also
  # wird beides geladen. Eine Attrappe des Urteils wuerde genau die Zusammenarbeit nicht pruefen,
  # auf die es hier ankommt.
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '50-UpdateEngine.ps1' -Name 'Get-SafetyNetDeleteVerdict')))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '50-UpdateEngine.ps1' -Name 'Get-SupersededDeletePlan')))
  # Der Mittelteil der Rueckfrage wird gegen die AUSGELIEFERTEN Texte geprueft, nicht gegen Kopien
  # davon - er ist die Grundlage, auf der jemand eine nicht rueckholbare Loeschung bestaetigt.
  . ([scriptblock]::Create((Get-UiStringsText)))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '50-UpdateEngine.ps1' -Name 'Format-SupersededDeleteDetails')))
  $script:uiLanguage = 'en'

  # Ein Eintrag in der Form, die der Knopf aus den beiden Sonden zusammensetzt.
  function New-Candidate {
    param(
      [string]$Name = 'Google Chrome',
      [string]$Version = '148.0.7778.168',
      [string]$GraphId = '22e15a08-31b2-4e59-9b48-6f2241c49916',
      [bool]$HasAssignments = $false,
      [bool]$HasInstallations = $false,
      [AllowNull()][object]$InstalledCount = $null,
      [bool]$AssignmentProbeOk = $true,
      [bool]$InstallProbeOk = $true
    )
    [pscustomobject]@{
      Name              = $Name
      CurrentVersion    = $Version
      GraphId           = $GraphId
      AssignmentProbe   = [pscustomobject]@{ Succeeded = $AssignmentProbeOk; HasAssignments = $HasAssignments }
      InstallationProbe = [pscustomobject]@{ Succeeded = $InstallProbeOk; HasInstallations = $HasInstallations; Count = $InstalledCount }
    }
  }
}

Describe 'Ohne die Einstellung bleibt alles wie bisher' {

  It 'haelt genau den gemeldeten Fall zurueck: keine Zuweisung, aber gemeldete Installationen' {
    # Das Protokoll vom 15.09.2026 in einer Zeile: assignments=False, installations=True.
    $plan = Get-SupersededDeletePlan -Candidates @((New-Candidate -HasInstallations $true -InstalledCount 2))
    @($plan.Delete).Count | Should -Be 0
    @($plan.Blocked).Count | Should -Be 1
    @($plan.Blocked)[0].Reason | Should -Be 'installations'
    $plan.OverriddenCount | Should -Be 0
  }

  It 'loescht, was ohnehin frei ist' {
    $plan = Get-SupersededDeletePlan -Candidates @((New-Candidate))
    @($plan.Delete).Count | Should -Be 1
    @($plan.Delete)[0].OverrodeInstallations | Should -BeFalse
    @($plan.Blocked).Count | Should -Be 0
  }
}

Describe 'Mit der Einstellung faellt genau der Installationsriegel' {

  It 'loescht trotz gemeldeter Installationen - und haelt fest, dass es das getan hat' {
    # Das Merkmal traegt bis in die Rueckfrage und die Protokollzeile. Ohne es saehe ein Lauf, der
    # genau das Gewollte tut, hinterher aus wie ein Riss im Sicherheitsnetz.
    $plan = Get-SupersededDeletePlan -IgnoreInstallations $true -Candidates @((New-Candidate -HasInstallations $true -InstalledCount 2))
    @($plan.Delete).Count | Should -Be 1
    @($plan.Delete)[0].OverrodeInstallations | Should -BeTrue
    @($plan.Blocked).Count | Should -Be 0
    $plan.OverriddenCount | Should -Be 1
  }

  It 'zaehlt nur die wirklich uebersteuerten, nicht die ohnehin freien' {
    # Sonst stuende die Warnung ueber die Installationen auch dann in der Rueckfrage, wenn keine
    # einzige App noch gemeldet war.
    $plan = Get-SupersededDeletePlan -IgnoreInstallations $true -Candidates @(
      (New-Candidate -Name 'Frei' -GraphId '11111111-1111-1111-1111-111111111111'),
      (New-Candidate -Name 'Gemeldet' -GraphId '22222222-2222-2222-2222-222222222222' -HasInstallations $true -InstalledCount 3))
    @($plan.Delete).Count | Should -Be 2
    $plan.OverriddenCount | Should -Be 1
    @(@($plan.Delete) | Where-Object { $_.OverrodeInstallations })[0].App.Name | Should -Be 'Gemeldet'
  }
}

Describe 'Die Riegel, die auch mit der Einstellung halten' {

  It 'eine noch zugewiesene App bleibt stehen' {
    # Ein anderer Schaden als ein verlorener Bericht: faellt eine zugewiesene App, bekommen die
    # betroffenen Geraete sie gar nicht mehr.
    $plan = Get-SupersededDeletePlan -IgnoreInstallations $true -Candidates @((New-Candidate -HasAssignments $true))
    @($plan.Delete).Count | Should -Be 0
    @($plan.Blocked)[0].Reason | Should -Be 'assigned'
  }

  It 'eine zugewiesene App bleibt auch dann stehen, wenn zusaetzlich Installationen gemeldet sind' {
    # Das Uebersteuern der Installationen darf die Zuweisung nicht gleich mit uebersteuern.
    $plan = Get-SupersededDeletePlan -IgnoreInstallations $true -Candidates @((New-Candidate -HasAssignments $true -HasInstallations $true -InstalledCount 4))
    @($plan.Delete).Count | Should -Be 0
    @($plan.Blocked)[0].Reason | Should -Be 'assigned'
  }

  It 'eine unlesbare Installationssondierung haelt die App' {
    # Uebersteuert wird eine MELDUNG, nicht ihr Fehlen.
    $plan = Get-SupersededDeletePlan -IgnoreInstallations $true -Candidates @((New-Candidate -InstallProbeOk $false -HasInstallations $true))
    @($plan.Delete).Count | Should -Be 0
    @($plan.Blocked)[0].Reason | Should -Be 'unknown'
  }

  It 'eine unlesbare Zuweisungssondierung haelt die App' {
    $plan = Get-SupersededDeletePlan -IgnoreInstallations $true -Candidates @((New-Candidate -AssignmentProbeOk $false))
    @($plan.Delete).Count | Should -Be 0
    @($plan.Blocked)[0].Reason | Should -Be 'unknown'
  }
}

Describe 'Eine gemischte Auswahl wird Zeile fuer Zeile eingeordnet' {

  It 'trennt loeschbar und zurueckgehalten und ordnet jeden Grund der richtigen App zu' {
    # Die Rueckfrage nennt beide Bloecke namentlich. Eine Verwechslung hier hiesse: der Benutzer
    # bestaetigt eine Loeschung fuer die falsche App.
    $plan = Get-SupersededDeletePlan -IgnoreInstallations $true -Candidates @(
      (New-Candidate -Name 'Chrome alt'  -GraphId 'aaaaaaaa-0000-0000-0000-000000000001' -HasInstallations $true -InstalledCount 2),
      (New-Candidate -Name 'Notepad alt' -GraphId 'aaaaaaaa-0000-0000-0000-000000000002' -HasAssignments $true),
      (New-Candidate -Name '7-Zip alt'   -GraphId 'aaaaaaaa-0000-0000-0000-000000000003'))
    @($plan.Delete).Count | Should -Be 2
    @($plan.Blocked).Count | Should -Be 1
    @($plan.Blocked)[0].App.Name | Should -Be 'Notepad alt'
    @($plan.Blocked)[0].Reason | Should -Be 'assigned'
    (@($plan.Delete) | ForEach-Object { $_.App.Name }) | Should -Be @('Chrome alt', '7-Zip alt')
  }
}

Describe 'Eintraege, die gar keine App bezeichnen' {

  It 'ueberspringt einen Eintrag ohne Graph-Id, statt ihn zu loeschen' {
    # Ohne Id gibt es nichts zu loeschen - und ein leerer Loeschauftrag an Graph waere das
    # Gefaehrlichste, was aus dieser Liste herauskommen koennte.
    $plan = Get-SupersededDeletePlan -IgnoreInstallations $true -Candidates @(
      (New-Candidate -Name 'Ohne Id' -GraphId '  '),
      (New-Candidate -Name 'Mit Id'  -GraphId 'bbbbbbbb-0000-0000-0000-000000000001'))
    @($plan.Delete).Count | Should -Be 1
    @($plan.Delete)[0].App.Name | Should -Be 'Mit Id'
    @($plan.Blocked).Count | Should -Be 0
  }

  It 'kommt mit einer leeren Auswahl zurecht' {
    $plan = Get-SupersededDeletePlan -Candidates @()
    @($plan.Delete).Count | Should -Be 0
    @($plan.Blocked).Count | Should -Be 0
    $plan.OverriddenCount | Should -Be 0
  }
}

Describe 'Der Mittelteil der Rueckfrage' {

  It 'nennt jede zurueckgehaltene App mit ihrem Grund und jede uebersteuerte mit ihrer Geraetezahl' {
    $plan = Get-SupersededDeletePlan -IgnoreInstallations $true -Candidates @(
      (New-Candidate -Name 'Google Chrome' -Version '148.0.7778.168' -GraphId 'cccccccc-0000-0000-0000-000000000001' -HasInstallations $true -InstalledCount 2),
      (New-Candidate -Name 'Notepad++'     -Version '8.9.4'          -GraphId 'cccccccc-0000-0000-0000-000000000002' -HasAssignments $true),
      (New-Candidate -Name 'VLC Player'    -Version '3.0.20'         -GraphId 'cccccccc-0000-0000-0000-000000000003' -AssignmentProbeOk $false))
    $text = Format-SupersededDeleteDetails -Plan $plan
    $text | Should -BeLike '*Google Chrome 148.0.7778.168: still reported as installed on 2 device(s)*'
    $text | Should -BeLike '*Notepad++ 8.9.4: still assigned to at least one group*'
    $text | Should -BeLike '*VLC Player 3.0.20: Intune did not answer*'
  }

  It 'sagt "mindestens ein Geraet" statt "1", wenn die Sonde gar nicht gezaehlt hat' {
    # Ueber deviceStatuses bricht die Sonde beim ERSTEN Treffer ab. Eine "1" waere dort eine Zahl,
    # die niemand gemessen hat - und sie stuende in der Rueckfrage vor einer Loeschung.
    $plan = Get-SupersededDeletePlan -IgnoreInstallations $true `
      -Candidates @((New-Candidate -Name '7-Zip' -Version '26.01' -HasInstallations $true -InstalledCount $null))
    $text = Format-SupersededDeleteDetails -Plan $plan
    $text | Should -BeLike '*at least one device*'
    $text | Should -Not -BeLike '*on 1 device(s)*'
  }

  It 'haengt keinen leeren Block an, wenn nichts zurueckgehalten und nichts uebersteuert wurde' {
    # Mit drei Platzhaltern in EINEM Textbaustein hinterliess ein leerer Block eine haengende
    # Leerzeile und eine Ueberschrift ohne Abstand davor.
    $plan = Get-SupersededDeletePlan -Candidates @((New-Candidate -Name '7-Zip' -Version '26.01'))
    $text = Format-SupersededDeleteDetails -Plan $plan
    $text | Should -Be '  - 7-Zip 26.01 (22e15a08-31b2-4e59-9b48-6f2241c49916)'
  }

  It 'trennt die Bloecke durch genau eine Leerzeile' {
    $plan = Get-SupersededDeletePlan -Candidates @(
      (New-Candidate -Name 'Frei'      -GraphId 'dddddddd-0000-0000-0000-000000000001'),
      (New-Candidate -Name 'Zugewiesen' -GraphId 'dddddddd-0000-0000-0000-000000000002' -HasAssignments $true))
    $text = Format-SupersededDeleteDetails -Plan $plan
    $text | Should -Not -BeLike "*`r`n`r`n`r`n*"
    ($text -split "`r`n")[1] | Should -Be ''
    ($text -split "`r`n")[2] | Should -Be 'NOT deleted, and left in the list:'
  }
}
