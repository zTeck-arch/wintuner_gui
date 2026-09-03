BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '25-WinGetData.ps1' -Name @(
    'Get-PackageIdFromNotes', 'Test-IsSupersededApp', 'Test-Win32InventoryTruncated',
    'Test-IsTransientModuleRace', 'Invoke-WithTransientRetry', 'Get-Win32AppsResilient'))))
}

Describe 'Get-PackageIdFromNotes' {
  # The module derives its PackageId property from this marker, so reading the inventory without the
  # module means parsing it the same way. Format verified against WinTuner 1.4.1.
  It 'reads the package id out of a current marker' {
    Get-PackageIdFromNotes -Notes '[WinTuner|winget|Google.Chrome]' | Should -Be 'Google.Chrome'
  }

  It 'reads the historical WingetIntune spelling too' {
    Get-PackageIdFromNotes -Notes '[WingetIntune|winget|Mozilla.Firefox]' | Should -Be 'Mozilla.Firefox'
  }

  It 'finds the marker inside surrounding text' {
    Get-PackageIdFromNotes -Notes 'Deployed by the team. [WinTuner|winget|Adobe.Acrobat.Reader.64-bit] Do not remove.' |
      Should -Be 'Adobe.Acrobat.Reader.64-bit'
  }

  It 'copes with a package id containing dots and dashes' {
    Get-PackageIdFromNotes -Notes '[WinTuner|winget|Microsoft.Edge-WebView2.Runtime]' |
      Should -Be 'Microsoft.Edge-WebView2.Runtime'
  }

  It 'returns nothing for an app without a marker' {
    # A hand-built app has no marker, and the module would not list it either. Returning empty is
    # what keeps such apps out of the update scan and the deletion paths.
    Get-PackageIdFromNotes -Notes 'Created by hand in the portal' | Should -BeNullOrEmpty
  }

  It 'returns nothing for empty or missing notes' {
    Get-PackageIdFromNotes -Notes '' | Should -BeNullOrEmpty
    Get-PackageIdFromNotes -Notes $null | Should -BeNullOrEmpty
  }

  It 'returns nothing for a malformed marker' {
    Get-PackageIdFromNotes -Notes '[WinTuner|winget]' | Should -BeNullOrEmpty
    Get-PackageIdFromNotes -Notes '[WinTuner|winget|' | Should -BeNullOrEmpty
  }
}

Describe 'Test-IsSupersededApp' {
  # Die zwei Graph-Zaehler sind das Vertauschbarste in diesem ganzen Bereich - und sie WAREN hier
  # vertauscht, bis 0.18.0. Vertauscht heisst: aktive und abgeloeste Liste tauschen die Plaetze, und
  # die abgeloeste Liste entscheidet, was GELOESCHT wird.
  #
  # Nicht mehr aus der Dokumentation begruendet, sondern am Protokoll eines echten Laufs vom
  # 03.09.2026 (10:36:14): der Filter "supersededAppCount == 0" lieferte genau die ALTEN Versionen
  # als aktiv (Adobe 26.001.21771, Airtame 4.15.1, Chrome 151.0.7922.72, WebView2 151.0.4129.78,
  # Zoom 7.1.43453) und liess genau die NEUEN weg - also die, die je eine App abloesen. Richtig ist
  # deshalb: abgeloest = supersedingAppCount > 0.
  It 'nennt eine App abgeloest, wenn sie von etwas abgeloest wird' {
    Test-IsSupersededApp -SupersedingAppCount 1 | Should -BeTrue
    Test-IsSupersededApp -SupersedingAppCount 3 | Should -BeTrue
  }

  It 'nennt eine App aktiv, wenn sie von nichts abgeloest wird' {
    Test-IsSupersededApp -SupersedingAppCount 0 | Should -BeFalse
  }

  # Der Fall, der den Fehler festnagelt: eine NEUE Version loest eine alte ab. Sie hat damit
  # supersededAppCount > 0 und muss trotzdem AKTIV sein. Genau hier lag der Fehler.
  It 'nennt die neue Version aktiv, obwohl sie selbst eine alte abloest' {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
      (Get-SourcePartPath -Part '25-WinGetData.ps1'), [ref]$null, [ref]$null)
    $fn = $ast.Find({
      param($n)
      $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-IsSupersededApp'
    }, $true)
    # Der Rumpf darf den anderen Zaehler nicht mehr anfassen - sonst ist der Fehler zurueck.
    $fn.Extent.Text | Should -Not -Match '\$SupersededAppCount'
    $fn.Extent.Text | Should -Match '\$SupersedingAppCount'
  }

  It 'treats a missing counter as not superseded' {
    # An app the tenant did not report a counter for must not land in the superseded list, because
    # that list feeds the deletion paths.
    Test-IsSupersededApp -SupersedingAppCount $null | Should -BeFalse
  }
}

Describe 'Get-Win32AppsResilient truncation fallback' {
  BeforeAll {
    $script:win32AppsModulePageSize = 3
    function global:Get-WtWin32Apps {
      [CmdletBinding()]
      [OutputType([object[]])]
      param([Nullable[bool]]$Superseded, [Nullable[bool]]$Update)
      return @($global:ModuleApps)
    }
    function global:Get-Win32AppInventoryViaGraph {
      param([switch]$Superseded)
      $global:PagedCalls++
      if ($global:PagedThrows) { throw 'Graph said no' }
      return @($global:PagedApps)
    }
  }
  AfterAll {
    Remove-Item function:global:Get-WtWin32Apps -ErrorAction SilentlyContinue
    Remove-Item function:global:Get-Win32AppInventoryViaGraph -ErrorAction SilentlyContinue
    Remove-Variable -Name ModuleApps, PagedApps, PagedCalls, PagedThrows -Scope Global -ErrorAction SilentlyContinue
  }
  BeforeEach {
    $global:TestLog.Clear()
    $global:PagedCalls = 0
    $global:PagedThrows = $false
    $script:win32InventoryTruncationWarned = @{}
    $global:ModuleApps = 1..3 | ForEach-Object { [pscustomobject]@{ Name = "App$_" } }
    $global:PagedApps  = 1..7 | ForEach-Object { [pscustomobject]@{ Name = "App$_" } }
  }

  It 'replaces a truncated module result with the complete paged one' {
    $out = @(Get-Win32AppsResilient -Label 'unit read')
    $out.Count | Should -Be 7
    $global:PagedCalls | Should -Be 1
    ($global:TestLog -join "`n") | Should -Match 'using the paged Graph result'
  }

  It 'does not read from Graph at all when the module result is short' {
    $global:ModuleApps = @([pscustomobject]@{ Name = 'OnlyOne' })
    $out = @(Get-Win32AppsResilient -Label 'unit read')
    $out.Count | Should -Be 1
    $global:PagedCalls | Should -Be 0
  }

  It 'keeps the module result when the paged read returns fewer apps' {
    # Fewer apps means the filter reproduction does not match this tenant. Too few apps in a
    # deletion path is the dangerous direction, so the conservative list wins.
    $global:PagedApps = @([pscustomobject]@{ Name = 'App1' })
    $out = @(Get-Win32AppsResilient -Label 'unit read')
    $out.Count | Should -Be 3
    ($global:TestLog -join "`n") | Should -Match 'FEWER apps'
  }

  It 'keeps the module result when the paged read fails' {
    $global:PagedThrows = $true
    $out = @(Get-Win32AppsResilient -Label 'unit read')
    $out.Count | Should -Be 3
    ($global:TestLog -join "`n") | Should -Match 'paged Graph fallback failed'
  }

  It 'still says the list looked truncated, so the log records why it swapped' {
    $null = Get-Win32AppsResilient -Label 'unit read'
    ($global:TestLog -join "`n") | Should -Match 'very likely INCOMPLETE'
  }
}
