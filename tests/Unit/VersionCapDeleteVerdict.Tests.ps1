#requires -Version 7
# Darf diese Fassung fallen, weil sie ueber der Versionsgrenze liegt?
#
# Das dritte Loeschurteil dieser Anwendung. Es entstand am 11.09.2026 aus einer Anforderung aus dem
# Betrieb: "maximal drei Fassungen gleichzeitig, auch wenn einzelne Geraete noch alte tragen". Bis
# dahin blieb eine Fassung ueber der Grenze fuer immer stehen, sobald EIN Geraet sie meldete.
#
# Die Einordnung, die das vertretbar macht und die in jeder Zeile hier mitschwingt: eine geloeschte
# Intune-App wird auf dem Geraet NICHT deinstalliert. Die Software bleibt; Intune verliert fuer
# dieses Objekt den Bericht, die Zuweisung und die Moeglichkeit zur Neuinstallation.
#
# Drei Riegel bleiben und werden hier einzeln festgehalten:
#   1. Unbekannt heisst behalten - auch mit gesetzter Grenze.
#   2. Zuweisungen schuetzen - auch mit gesetzter Grenze.
#   3. Ohne die Einstellung aendert sich gar nichts am bisherigen Verhalten.

BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '50-UpdateEngine.ps1' -Name 'Get-VersionCapDeleteVerdict')))

  # Sondierungen in der Form, die Get-AppAssignmentProbe / Get-AppInstallationProbe liefern.
  function New-AssignProbe {
    param([bool]$Succeeded = $true, [bool]$HasAssignments = $false)
    [pscustomobject]@{ Succeeded = $Succeeded; HasAssignments = $HasAssignments }
  }
  function New-InstallProbe {
    param([bool]$Succeeded = $true, [bool]$HasInstallations = $false)
    [pscustomobject]@{ Succeeded = $Succeeded; HasInstallations = $HasInstallations }
  }
  $script:frei        = New-AssignProbe
  $script:zugewiesen  = New-AssignProbe -HasAssignments $true
  $script:blindA      = New-AssignProbe -Succeeded $false
  $script:leer        = New-InstallProbe
  $script:installiert = New-InstallProbe -HasInstallations $true
  $script:blindI      = New-InstallProbe -Succeeded $false
}

Describe 'Ohne die Einstellung bleibt alles wie bisher' {

  It 'loescht, wenn nichts dagegen spricht' {
    $v = Get-VersionCapDeleteVerdict -AssignmentProbe $script:frei -InstallationProbe $script:leer
    $v.Delete | Should -BeTrue
    $v.KeepReason | Should -Be ''
    $v.OverrodeInstallations | Should -BeFalse
  }

  It 'behaelt eine Fassung, die noch installiert ist' {
    $v = Get-VersionCapDeleteVerdict -AssignmentProbe $script:frei -InstallationProbe $script:installiert
    $v.Delete | Should -BeFalse
    $v.KeepReason | Should -Be 'installations'
  }

  It 'behaelt eine Fassung, die noch zugewiesen ist' {
    $v = Get-VersionCapDeleteVerdict -AssignmentProbe $script:zugewiesen -InstallationProbe $script:leer
    $v.Delete | Should -BeFalse
    $v.KeepReason | Should -Be 'assigned'
  }
}

Describe 'Mit gesetzter Grenze wiegt sie schwerer als Installationen' {

  It 'loescht trotz gemeldeter Installationen - und sagt, dass es das getan hat' {
    # Das Melden ist wesentlich: der Aufrufer schreibt daraufhin die Protokollzeile mit der Zahl
    # der betroffenen Geraete. Ohne dieses Merkmal saehe ein Lauf, der genau das Gewollte tut,
    # hinterher aus wie ein Riss im Sicherheitsnetz.
    $v = Get-VersionCapDeleteVerdict -AssignmentProbe $script:frei -InstallationProbe $script:installiert `
      -CapOverridesInstallations $true
    $v.Delete | Should -BeTrue
    $v.OverrodeInstallations | Should -BeTrue
    $v.KeepReason | Should -Be ''
  }

  It 'meldet KEIN Ueberstimmen, wenn gar nichts installiert war' {
    # Sonst stuende die folgenreichste Protokollzeile des Laufs unter jeder harmlosen Loeschung.
    $v = Get-VersionCapDeleteVerdict -AssignmentProbe $script:frei -InstallationProbe $script:leer `
      -CapOverridesInstallations $true
    $v.Delete | Should -BeTrue
    $v.OverrodeInstallations | Should -BeFalse
  }
}

Describe 'Die drei Riegel, die auch mit gesetzter Grenze halten' {

  It 'Zuweisungen schuetzen weiterhin' {
    # Ein anderer Schaden als ein verlorener Bericht: faellt eine zugewiesene Fassung, bekommen die
    # betroffenen Geraete die App gar nicht mehr. Ausdrueckliche Entscheidung vom 11.09.2026.
    $v = Get-VersionCapDeleteVerdict -AssignmentProbe $script:zugewiesen -InstallationProbe $script:leer `
      -CapOverridesInstallations $true
    $v.Delete | Should -BeFalse
    $v.KeepReason | Should -Be 'assigned'
  }

  It 'Zuweisungen schuetzen auch dann, wenn zusaetzlich Installationen gemeldet sind' {
    # Die Reihenfolge der Pruefungen darf nicht dazu fuehren, dass das Ueberstimmen der
    # Installationen die Zuweisung gleich mit ueberstimmt.
    $v = Get-VersionCapDeleteVerdict -AssignmentProbe $script:zugewiesen -InstallationProbe $script:installiert `
      -CapOverridesInstallations $true
    $v.Delete | Should -BeFalse
    $v.KeepReason | Should -Be 'assigned'
  }

  It 'eine unlesbare Installationssondierung schuetzt weiterhin' {
    # Die Grenze ueberstimmt eine MELDUNG, nicht ihr Fehlen. Auf Unwissen hin zu loeschen ist das
    # eine, was diese Anwendung nirgends tut.
    $v = Get-VersionCapDeleteVerdict -AssignmentProbe $script:frei -InstallationProbe $script:blindI `
      -CapOverridesInstallations $true
    $v.Delete | Should -BeFalse
    $v.KeepReason | Should -Be 'unknown'
  }

  It 'eine unlesbare Zuweisungssondierung schuetzt weiterhin' {
    $v = Get-VersionCapDeleteVerdict -AssignmentProbe $script:blindA -InstallationProbe $script:leer `
      -CapOverridesInstallations $true
    $v.Delete | Should -BeFalse
    $v.KeepReason | Should -Be 'unknown'
  }

  It 'Unbekannt wiegt schwerer als Zugewiesen, damit der Zaehler stimmt' {
    # Der Aufrufer zaehlt 'unknown' als FEHLER und die anderen als bewusste Schutzwirkung. Eine
    # Sondierung, die nicht geantwortet hat, darf nicht als "sauber geschuetzt" durchgehen.
    $v = Get-VersionCapDeleteVerdict -AssignmentProbe $script:blindA -InstallationProbe $script:installiert `
      -CapOverridesInstallations $true
    $v.KeepReason | Should -Be 'unknown'
  }
}

Describe 'Fehlende Sondierungen' {

  It 'behandelt $null wie eine Sondierung ohne Antwort' {
    $v = Get-VersionCapDeleteVerdict -AssignmentProbe $null -InstallationProbe $null -CapOverridesInstallations $true
    $v.Delete | Should -BeFalse
    $v.KeepReason | Should -Be 'unknown'
  }
}
