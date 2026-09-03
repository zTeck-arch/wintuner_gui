BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient

  # Die ECHTE Tabelle aus 75-UiState, nicht eine Kopie davon. Der Teil selbst laesst sich nicht
  # dot-sourcen (er baut das Fenster), also wird genau die eine Zuweisung ueber den Parser
  # herausgeholt und ausgefuehrt. Eine abgeschriebene Tabelle im Test wuerde genau das nicht pruefen,
  # worum es hier geht - dass Anwendung und Test dieselbe Zuordnung benutzen.
  $partText = Get-SourcePartText -Part '75-UiState.ps1'
  $partAst = [System.Management.Automation.Language.Parser]::ParseInput($partText, [ref]$null, [ref]$null)
  $assignment = @($partAst.FindAll({
      param($node)
      $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
      $node.Left.Extent.Text -eq '$script:sectionLayoutFunctions'
    }, $true))
  if ($assignment.Count -ne 1) { throw "Expected exactly one assignment to `$script:sectionLayoutFunctions in 75-UiState.ps1, found $($assignment.Count)." }
  . ([scriptblock]::Create($assignment[0].Extent.Text))

  . ([scriptblock]::Create((Get-SourceFunctionText -Part '75-UiState.ps1' `
    -Name 'Update-SectionLayout', 'Update-AllSectionLayouts')))

  # Jede Layout-Funktion der Tabelle durch eine Attrappe ersetzen, die nur ihren Namen notiert.
  $global:TestLayoutCalls = [System.Collections.Generic.List[string]]::new()
  foreach ($fnName in @($script:sectionLayoutFunctions.Values)) {
    Set-Item -Path ("function:global:" + $fnName) -Value ([scriptblock]::Create(
      "`$global:TestLayoutCalls.Add('$fnName')"))
  }
}

Describe 'Die Zuordnung Bereich -> Layout-Funktion' {
  It 'nennt fuer jeden Eintrag einen Funktionsnamen im Update-*Layout-Muster' {
    foreach ($entry in $script:sectionLayoutFunctions.GetEnumerator()) {
      $entry.Value | Should -Match '^Update-[A-Za-z]+Layout$' -Because "Bereich '$($entry.Key)' zeigt auf '$($entry.Value)'"
    }
  }
  It 'benutzt jede Layout-Funktion nur fuer EINEN Bereich' {
    $values = @($script:sectionLayoutFunctions.Values)
    @($values | Group-Object | Where-Object Count -gt 1).Count | Should -Be 0
  }
}

Describe 'Update-SectionLayout' {
  BeforeEach { $global:TestLayoutCalls.Clear() }

  It 'ruft genau die Funktion des genannten Bereichs' {
    Update-SectionLayout -Key 'updates'
    @($global:TestLayoutCalls) | Should -Be @('Update-UpdatesLayout')
  }

  # Der Kern der Aenderung vom 31.08.2026: der Resize-Handler rief vorher ALLE Layout-Funktionen,
  # auch die der unsichtbaren Bereiche - bei jedem Ereignis eines Ziehvorgangs, und jede davon
  # vermisst Text. Jetzt genau eine.
  It 'ruft fuer einen Bereich nur eine einzige Funktion' {
    Update-SectionLayout -Key 'store'
    $global:TestLayoutCalls.Count | Should -Be 1
  }

  It 'tut nichts fuer das Dashboard, das keine eigene Layout-Funktion hat' {
    Update-SectionLayout -Key 'dashboard'
    $global:TestLayoutCalls.Count | Should -Be 0
  }

  It 'tut nichts bei einem unbekannten Bereich und fliegt nicht' {
    { Update-SectionLayout -Key 'gibtesnicht' } | Should -Not -Throw
    $global:TestLayoutCalls.Count | Should -Be 0
  }

  # $script:activeSection ist beim Start $null, und der Resize-Handler reicht sie direkt durch.
  It 'tut nichts bei leerem Bereich - der Startzustand von $script:activeSection' {
    { Update-SectionLayout -Key '' } | Should -Not -Throw
    { Update-SectionLayout -Key $null } | Should -Not -Throw
    $global:TestLayoutCalls.Count | Should -Be 0
  }

  It 'faengt einen Fehler der Layout-Funktion ab, statt das Fenster mitzunehmen' {
    Set-Item -Path function:global:Update-UpdatesLayout -Value { throw 'kaputt' }
    { Update-SectionLayout -Key 'updates' } | Should -Not -Throw
    Set-Item -Path function:global:Update-UpdatesLayout -Value { $global:TestLayoutCalls.Add('Update-UpdatesLayout') }
  }
}

Describe 'Update-AllSectionLayouts' {
  BeforeEach { $global:TestLayoutCalls.Clear() }

  # Nur der Designwechsel darf das: eine andere Schriftart aendert die Zeilenhoehe in jedem Bereich.
  It 'ruft jede Layout-Funktion der Tabelle genau einmal' {
    Update-AllSectionLayouts
    $expected = @($script:sectionLayoutFunctions.Values | Sort-Object)
    @($global:TestLayoutCalls | Sort-Object) | Should -Be $expected
  }
}
