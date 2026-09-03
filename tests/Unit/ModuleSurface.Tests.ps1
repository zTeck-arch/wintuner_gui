# Das fremde WinTuner-Modul kann Parameter umbenennen, und es hat es getan.
#
# Gemeldet am 03.09.2026 vom Rechner eines Kollegen: der Klick auf "Suchen" endete in
#   "A parameter cannot be found that matches parameter name 'SearchQuery'"
# als FATAL UI ERROR samt Stapelabbild. Nachgesehen in der Modulquelle (svrooij/WingetIntune):
# `Search-WtWinGetPackage` heisst der Parameter erst ab Modulversion 1.1.0 `-SearchQuery`, bis 1.0.6
# hiess er `-PackageId`. Der bestehende Startcheck sah das nicht - er prueft, ob die BEFEHLE da sind,
# und der Befehl war da.
#
# Diese Faelle halten zwei Entscheidungen fest: WAS beim Start geprueft wird (die tatsaechlich
# installierte Oberflaeche, nicht eine geratene Mindestversion), und dass ein fehlender Parameter
# eine Meldung beim Start ist statt eines Absturzes mitten im Klick.

BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '05-Config.ps1' -Name 'Get-MissingModuleParameters')))

  # Die ausgelieferte Liste aus der QUELLE lesen, nicht hier nachbauen - eine Kopie liefe
  # auseinander, und dann prueften diese Faelle einen Vertrag, den niemand benutzt.
  $ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Get-SourcePartPath -Part '05-Config.ps1'), [ref]$null, [ref]$null)
  $assign = $ast.Find({
    param($n)
    $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $n.Left.Extent.Text -eq '$script:requiredModuleParameters'
  }, $true)
  if (-not $assign) { throw '$script:requiredModuleParameters nicht gefunden - umbenannt?' }
  . ([scriptblock]::Create($assign.Extent.Text))

  # Eine Attrappe fuer Get-Command: Befehl -> vorhandene Parameter.
  function New-CommandLookup {
    param([hashtable]$Commands)
    return {
      param($name)
      if (-not $Commands.ContainsKey($name)) { return $null }
      $keys = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
      foreach ($p in $Commands[$name]) { $keys[$p] = $true }
      return [pscustomobject]@{ Parameters = $keys }
    }.GetNewClosure()
  }
}

Describe 'Get-MissingModuleParameters' {

  It 'meldet nichts, wenn das Modul alles mitbringt' {
    $lookup = New-CommandLookup -Commands @{ 'Search-WtWinGetPackage' = @('SearchQuery', 'All') }
    $r = @(Get-MissingModuleParameters -Required @(
      @{ Command = 'Search-WtWinGetPackage'; Parameter = 'SearchQuery'; Since = '1.1.0' }) -CommandLookup $lookup)
    $r.Count | Should -Be 0
  }

  # Genau der gemeldete Fall: bis Modul 1.0.6 hiess der Parameter -PackageId.
  It 'findet den umbenannten Parameter und nennt die Version, ab der es ihn gibt' {
    $lookup = New-CommandLookup -Commands @{ 'Search-WtWinGetPackage' = @('PackageId', 'All') }
    $r = @(Get-MissingModuleParameters -Required @(
      @{ Command = 'Search-WtWinGetPackage'; Parameter = 'SearchQuery'; Since = '1.1.0' }) -CommandLookup $lookup)
    $r.Count | Should -Be 1
    $r[0] | Should -Be 'Search-WtWinGetPackage -SearchQuery (needs module 1.1.0 or newer)'
  }

  # Ein FEHLENDER Befehl ist eine andere Meldung und hat schon ihren eigenen Check. Hier doppelt
  # gemeldet zu werden macht die Startmeldung nur unlesbar.
  It 'schweigt zu einem Befehl, den das Modul gar nicht hat' {
    $lookup = New-CommandLookup -Commands @{}
    $r = @(Get-MissingModuleParameters -Required @(
      @{ Command = 'Gibts-Nicht'; Parameter = 'Irgendwas'; Since = '' }) -CommandLookup $lookup)
    $r.Count | Should -Be 0
  }

  It 'laesst die Versionsangabe weg, wenn keine hinterlegt ist' {
    $lookup = New-CommandLookup -Commands @{ 'Get-WtWin32Apps' = @('Update') }
    $r = @(Get-MissingModuleParameters -Required @(
      @{ Command = 'Get-WtWin32Apps'; Parameter = 'Superseded'; Since = '' }) -CommandLookup $lookup)
    $r[0] | Should -Be 'Get-WtWin32Apps -Superseded'
  }

  It 'kommt mit einer leeren Liste und mit unvollstaendigen Eintraegen zurecht' {
    $lookup = New-CommandLookup -Commands @{ 'X' = @('Y') }
    @(Get-MissingModuleParameters -Required @() -CommandLookup $lookup).Count | Should -Be 0
    @(Get-MissingModuleParameters -Required $null -CommandLookup $lookup).Count | Should -Be 0
    @(Get-MissingModuleParameters -Required @(@{ Command = 'X' }) -CommandLookup $lookup).Count | Should -Be 0
  }

  # Ein Lookup, der fliegt, darf den Start nicht mitnehmen - er laeuft in der Startsequenz.
  It 'verschluckt einen fliegenden Lookup, statt den Start abzubrechen' {
    { Get-MissingModuleParameters -Required @(@{ Command = 'A'; Parameter = 'B' }) `
        -CommandLookup { param($n) throw 'kaputt' } } | Should -Not -Throw
  }
}

Describe 'Die ausgelieferte Vertragsliste' {

  It 'nennt den Parameter, an dem der Fehler auftrat' {
    $pair = @($script:requiredModuleParameters | Where-Object {
      $_.Command -eq 'Search-WtWinGetPackage' -and $_.Parameter -eq 'SearchQuery' })
    $pair.Count | Should -Be 1
    $pair[0].Since | Should -Be '1.1.0' -Because 'ab dieser Modulversion gibt es ihn (Quelle: svrooij/WingetIntune)'
  }

  It 'nennt jeden Eintrag mit Befehl und Parameter' {
    foreach ($e in @($script:requiredModuleParameters)) {
      $e.Command   | Should -Not -BeNullOrEmpty
      $e.Parameter | Should -Not -BeNullOrEmpty
      $e.Command   | Should -BeLike '*-Wt*' -Because 'es geht um das fremde WinTuner-Modul'
    }
  }

  It 'enthaelt keinen Eintrag doppelt' {
    $pairs = @($script:requiredModuleParameters | ForEach-Object { '{0} -{1}' -f $_.Command, $_.Parameter })
    @($pairs | Sort-Object -Unique).Count | Should -Be $pairs.Count
  }
}

Describe 'Verdrahtung im Quelltext' {

  It 'prueft die Modul-Oberflaeche beim Start, nicht beim Klick' {
    $main = Get-SourcePartText -Part '90-Main.ps1'
    $main | Should -Match 'Get-MissingModuleParameters'
    # Ueber Show-StartupDialog, sonst haengt jeder unbeaufsichtigte Lauf an der MessageBox.
    $main | Should -Match 'ModParametersMissingDialog[\s\S]{0,400}?ModParametersMissingTitle'
  }

  # Ohne catch war eine gescheiterte Suche ein FATAL UI ERROR mit Stapelabbild.
  It 'faengt einen Fehler der Paketsuche ab und macht daraus eine Meldung' {
    $main = Get-SourcePartText -Part '90-Main.ps1'
    $main | Should -Match "SearchFailedStatus"
    $idxSearch = $main.IndexOf('Search-WtWinGetPackage -SearchQuery $appSearchBox.Text')
    $idxSearch | Should -BeGreaterThan 0
    # Zwischen dem Aufruf und dem finally muss ein catch liegen.
    $tail = $main.Substring($idxSearch, [Math]::Min(2500, $main.Length - $idxSearch))
    $tail | Should -Match '\}\s*catch\s*\{'
    ($tail.IndexOf('} catch {')) | Should -BeLessThan ($tail.IndexOf('} finally {'))
  }
}
