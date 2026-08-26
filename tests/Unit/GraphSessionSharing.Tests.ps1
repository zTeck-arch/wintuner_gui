# Die Messung hinter Befund F24, als Test statt als Behauptung.
#
# Jahrelang stand im Quelltext, der Graph-Kontext lebe nur im Haupt-Runspace und Nebenläufigkeit sei
# deshalb unmöglich. Das war die falsche Lehre aus einem echten Fehler: der entfernte
# BackgroundWorker scheiterte am fehlenden PowerShell-RUNSPACE, nicht am Graph-Kontext.
#
# Tatsächlich ist [Microsoft.Graph.PowerShell.Authentication.GraphSession]::Instance ein statisches
# Singleton - ein zweiter Runspace im selben Prozess sieht dieselbe Anmeldung. Genau darauf baut
# Get-Win32AppsOffThread. Sollte eine künftige Version des Moduls das ändern, muss dieser Test
# fehlschlagen, bevor jemand im Kundentenant eine leere Inventarliste bekommt.
#
# Bewusst OHNE Anmeldung: geprüft wird das Teilen der Sitzung, nicht die Sitzung selbst.

BeforeAll {
  $script:graphModule = Get-Module -ListAvailable -Name Microsoft.Graph.Authentication |
    Sort-Object Version -Descending | Select-Object -First 1
}

Describe 'Graph-Sitzung über Runspaces hinweg' -Skip:(-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {

  It 'hält GraphSession.Instance als statisches Singleton' {
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    $type = [Microsoft.Graph.PowerShell.Authentication.GraphSession]
    $prop = $type.GetProperty('Instance', [Reflection.BindingFlags]'Public,Static')
    $prop | Should -Not -BeNullOrEmpty -Because 'ein instanzgebundenes Feld wäre je Runspace ein eigenes'
  }

  It 'zeigt einem zweiten Runspace dieselbe Instanz' {
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    $mainId = [Microsoft.Graph.PowerShell.Authentication.GraphSession]::Instance.GetHashCode()

    # Derselbe Aufbau wie Get-PackageRunspace: eigener Runspace, MTA, Modul dort importiert.
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = [Threading.ApartmentState]::MTA
    $rs.ThreadOptions  = [Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $rs.Open()
    try {
      $ps = [powershell]::Create()
      $ps.Runspace = $rs
      [void]$ps.AddScript(@'
Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
[Microsoft.Graph.PowerShell.Authentication.GraphSession]::Instance.GetHashCode()
'@)
      $workerId = @($ps.Invoke())[0]
      $errors = @($ps.Streams.Error)
      $ps.Dispose()

      $errors.Count | Should -Be 0 -Because 'der zweite Runspace muss das Modul laden können'
      $workerId | Should -Be $mainId -Because 'nur dann trägt die Anmeldung in den zweiten Runspace'
    } finally {
      $rs.Dispose()
    }
  }

  It 'führt ein Scriptblock im zweiten Runspace überhaupt aus' {
    # Das ist der Unterschied zum entfernten BackgroundWorker: dort lief gar nichts, und der
    # Aufrufer bekam $null, ohne es von einem echten Ergebnis unterscheiden zu können.
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    try {
      $ps = [powershell]::Create()
      $ps.Runspace = $rs
      [void]$ps.AddScript('param($a, $b) $a + $b').AddArgument(40).AddArgument(2)
      @($ps.Invoke())[0] | Should -Be 42
      $ps.Dispose()
    } finally {
      $rs.Dispose()
    }
  }
}
