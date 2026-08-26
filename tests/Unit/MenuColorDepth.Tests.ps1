# Die Menüfarben werden rekursiv gesetzt - und das muss so bleiben.
#
# Die frühere Fassung färbte die obersten Einträge und deren direkte Kinder, also genau zwei Ebenen.
# Das reichte, solange das Menü zwei Ebenen hatte. Als „Design" und „Sprache" von der obersten Ebene
# unter „Ansicht" wanderten, lagen die Themennamen plötzlich auf Ebene DREI: nie eingefärbt, deshalb
# in der Systemfarbe - dunkelgrau auf dunklem Grund und praktisch unlesbar.
#
# Der Fehler ist nur im dunklen Design sichtbar, weil die Systemfarbe für hellen Grund gedacht ist.
# Eine Prüfung, die nur „sind Farben gesetzt" fragt, hätte ihn nicht gefunden - deshalb wird hier
# ausdrücklich eine DRITTE Ebene aufgebaut und geprüft.

BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  Add-Type -AssemblyName System.Windows.Forms, System.Drawing
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '75-UiState.ps1' -Name 'Set-MenuItemColorsDeep')))

  $script:Back     = [System.Drawing.Color]::FromArgb(34, 34, 34)
  $script:Fore     = [System.Drawing.Color]::FromArgb(237, 237, 237)
  $script:Disabled = [System.Drawing.Color]::FromArgb(150, 150, 150)

  function New-ThreeLevelMenu {
    $top = New-Object System.Windows.Forms.ToolStripMenuItem 'Ansicht'
    $mid = New-Object System.Windows.Forms.ToolStripMenuItem 'Design'
    $leafA = New-Object System.Windows.Forms.ToolStripMenuItem 'Dunkler Modus'
    $leafB = New-Object System.Windows.Forms.ToolStripMenuItem 'Windows 98'
    [void]$mid.DropDownItems.Add($leafA)
    [void]$mid.DropDownItems.Add($leafB)
    [void]$top.DropDownItems.Add($mid)
    return @{ Top = $top; Mid = $mid; LeafA = $leafA; LeafB = $leafB }
  }
}

Describe 'Set-MenuItemColorsDeep' {

  It 'färbt die dritte Ebene - der Fehler, um den es geht' {
    $m = New-ThreeLevelMenu
    Set-MenuItemColorsDeep -Item $m.Top -Back $script:Back -Fore $script:Fore -Disabled $script:Disabled
    $m.LeafA.ForeColor | Should -Be $script:Fore
    $m.LeafA.BackColor | Should -Be $script:Back
    $m.LeafB.ForeColor | Should -Be $script:Fore
  }

  It 'färbt auch die beiden Ebenen darüber' {
    $m = New-ThreeLevelMenu
    Set-MenuItemColorsDeep -Item $m.Top -Back $script:Back -Fore $script:Fore -Disabled $script:Disabled
    $m.Top.ForeColor | Should -Be $script:Fore
    $m.Mid.ForeColor | Should -Be $script:Fore
  }

  It 'geht beliebig tief, nicht nur drei Ebenen' {
    # Damit die nächste Verschachtelung nicht wieder unlesbar wird.
    $l1 = New-Object System.Windows.Forms.ToolStripMenuItem 'a'
    $cur = $l1
    $leaves = @()
    1..5 | ForEach-Object {
      $next = New-Object System.Windows.Forms.ToolStripMenuItem "e$_"
      [void]$cur.DropDownItems.Add($next)
      $leaves += $next
      $cur = $next
    }
    Set-MenuItemColorsDeep -Item $l1 -Back $script:Back -Fore $script:Fore -Disabled $script:Disabled
    foreach ($leaf in $leaves) { $leaf.ForeColor | Should -Be $script:Fore }
  }

  It 'gibt deaktivierten Einträgen die gedämpfte Farbe' {
    # Mit der normalen Vordergrundfarbe sähen sie aus wie anklickbar.
    $m = New-ThreeLevelMenu
    $m.LeafB.Enabled = $false
    Set-MenuItemColorsDeep -Item $m.Top -Back $script:Back -Fore $script:Fore -Disabled $script:Disabled
    $m.LeafB.ForeColor | Should -Be $script:Disabled
    $m.LeafA.ForeColor | Should -Be $script:Fore
  }

  It 'setzt auch die Fläche des Klappmenüs, nicht nur die Einträge darauf' {
    # Sonst bleibt der Rand um die Einträge herum in der Systemfarbe stehen.
    $m = New-ThreeLevelMenu
    Set-MenuItemColorsDeep -Item $m.Top -Back $script:Back -Fore $script:Fore -Disabled $script:Disabled
    $m.Top.DropDown.BackColor | Should -Be $script:Back
    $m.Mid.DropDown.BackColor | Should -Be $script:Back
  }

  It 'kommt mit einem Separator klar, der keine Farben trägt' {
    $top = New-Object System.Windows.Forms.ToolStripMenuItem 'Extras'
    [void]$top.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $after = New-Object System.Windows.Forms.ToolStripMenuItem 'danach'
    [void]$top.DropDownItems.Add($after)
    { Set-MenuItemColorsDeep -Item $top -Back $script:Back -Fore $script:Fore -Disabled $script:Disabled } |
      Should -Not -Throw
    # Und der Eintrag NACH dem Separator muss trotzdem gefärbt sein.
    $after.ForeColor | Should -Be $script:Fore
  }

  It 'läuft bei $null einfach durch' {
    { Set-MenuItemColorsDeep -Item $null -Back $script:Back -Fore $script:Fore -Disabled $script:Disabled } |
      Should -Not -Throw
  }
}
