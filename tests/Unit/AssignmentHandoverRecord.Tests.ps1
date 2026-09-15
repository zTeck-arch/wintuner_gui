#requires -Version 7
# Was darf der Leistungsnachweis ueber die Zuweisungs-Uebergabe behaupten?
#
# Bis 0.20.0 stand im Update-Motor die verdrehte Bedingung
#
#     if ($result.PredecessorHadAssignments -and -not $result.AssignmentsMoved) { ... HandedOver }
#
# Move-AppAssignments meldet aber auch "es gab nichts zu uebertragen" als Erfolg, also war
# AssignmentsMoved in jedem normalen Lauf $true und der Eintrag blieb aus. Gesetzt wurde er GENAU
# DANN, wenn die Uebergabe gescheitert war - der Nachweis, den der Kunde bekommt, nannte die
# Uebergabe also ausschliesslich in den Laeufen, in denen sie nicht stattgefunden hat.
#
# Die Entscheidung liegt seitdem in einer reinen Rechnung, damit sie ohne Tenant pruefbar ist.

BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '50-UpdateEngine.ps1' `
    -Name 'Get-AssignmentHandoverRecord')))
}

Describe 'Get-AssignmentHandoverRecord' {

  It 'nennt die Uebergabe NICHT, wenn sie gescheitert ist' {
    Get-AssignmentHandoverRecord -PredecessorHadAssignments $true -MoveSucceeded $false -MoveWrote $false |
      Should -Be 'failed'
  }

  # Die Gegenprobe zum eigentlichen Fehler: frueher war genau das der Fall, in dem der Nachweis
  # "Zuweisung an die neue Version uebergeben" schrieb.
  It 'nennt sie auch dann nicht, wenn der Vorgaenger zugewiesen war und der Umzug scheiterte' {
    Get-AssignmentHandoverRecord -PredecessorHadAssignments $true -MoveSucceeded $false -MoveWrote $true |
      Should -Be 'failed'
  }

  It 'schweigt, wenn es nichts zu uebergeben gab' {
    Get-AssignmentHandoverRecord -PredecessorHadAssignments $false -MoveSucceeded $true -MoveWrote $false |
      Should -Be 'nothing'
  }

  # Move-AppAssignments vermerkt seinen eigenen Schreibvorgang bereits selbst
  # (ActivityAssignmentMoved). Ein zweiter Eintrag waere dieselbe Arbeit doppelt im Nachweis.
  It 'ueberlaesst den Eintrag Move-AppAssignments, wenn dort geschrieben wurde' {
    Get-AssignmentHandoverRecord -PredecessorHadAssignments $true -MoveSucceeded $true -MoveWrote $true |
      Should -Be 'movedByUs'
  }

  # Der Vorgaenger trug Zuweisungen, der Umzug gelang, geschrieben wurde trotzdem nichts: dann war
  # die Quelle beim Hinsehen schon leer. Ein aelteres Modul oder eine Hand im Portal hat uebergeben
  # - der Nachweis soll die Arbeit trotzdem nennen.
  It 'nennt eine Uebergabe, die woanders passiert ist' {
    Get-AssignmentHandoverRecord -PredecessorHadAssignments $true -MoveSucceeded $true -MoveWrote $false |
      Should -Be 'handedOverElsewhere'
  }
}
