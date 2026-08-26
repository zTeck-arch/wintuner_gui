# Der Datenteil steht in BeforeDiscovery, nicht in BeforeAll - und das ist hier kein Stilfrage.
#
# Pester laeuft in zwei Phasen: erst Discovery (Describe/It werden aufgesammelt, -Skip und -ForEach
# werden AUSGEWERTET), dann Run (BeforeAll und die It-Rumpfe laufen). Eine Tabelle, die BeforeAll
# fuellt, ist zur Auswertung von -ForEach also noch leer: die sieben Parameterpruefungen wurden
# stillschweigend zu NULL Tests, und die Datei meldete gruen, ohne den Vertrag ueberhaupt angesehen
# zu haben - genau das "gruene Haekchen, das nichts beweist", vor dem der Kommentar unten warnt.
# Auf dem CI-Laeufer (neuere Pester-Fassung) brach die Discovery daran ganz ab: "Container failed".
BeforeDiscovery {
  # The contract this suite guards. Every entry is an assumption the application makes about the
  # WinTuner module, and every one of them is invisible to the parser, to PSScriptAnalyzer and to
  # every other unit test in this folder - because those all run against stand-ins we wrote
  # ourselves. 0.15.8 is what that costs: -Update was assumed to mean "also evaluate updates" when
  # the module declares it as Nullable[bool] and treats it as a FILTER on the update state. Nothing
  # failed until a customer tenant reported no updates at all.
  #
  # A Nullable[bool] parameter is the dangerous shape: "not bound" and "$false" mean two different
  # things, so binding a [switch] through it silently changes the result set.
  $ModuleContract = @(
    @{ Command = 'Get-WtWin32Apps'; Parameter = 'Update';      Type = 'System.Nullable`1[System.Boolean]' }
    @{ Command = 'Get-WtWin32Apps'; Parameter = 'Superseded';  Type = 'System.Nullable`1[System.Boolean]' }
    @{ Command = 'Get-WtWin32Apps'; Parameter = 'Superseding'; Type = 'System.Nullable`1[System.Boolean]' }
    @{ Command = 'Get-WtWin32Apps'; Parameter = 'IsAssigned';  Type = 'System.Nullable`1[System.Boolean]' }
    @{ Command = 'Get-WtWin32Apps'; Parameter = 'NameContains'; Type = 'System.String' }
    @{ Command = 'Deploy-WtWin32App'; Parameter = 'KeepAssignments'; Type = 'System.Management.Automation.SwitchParameter' }
    @{ Command = 'Deploy-WtWin32App'; Parameter = 'GraphId';         Type = 'System.String' }
  )
  # Commands the application calls at all. A rename or removal in a module update has to be loud.
  $ModuleCommands = @(
    'Get-WtWin32Apps', 'Deploy-WtWin32App', 'New-WtWingetPackage', 'Remove-WtWin32App',
    'Update-WtIntuneApp', 'Get-WtToken', 'Connect-WtWinTuner', 'Disconnect-WtWinTuner'
  )
  # Ob der Vertrag ueberhaupt geprueft werden kann, entscheidet sich ebenfalls in der Discovery:
  # -Skip wird dort ausgewertet. Nichts darf hier fliegen, sonst faellt die ganze Datei aus.
  $ContractModule = $null
  try {
    $ContractModule = Get-Module -ListAvailable -Name WinTuner |
      Sort-Object Version -Descending | Select-Object -First 1
  } catch { $ContractModule = $null }
  $SkipContract = -not $ContractModule
}

Describe 'WinTuner module contract' -Skip:$SkipContract {
  # Skipped rather than failed when the module is absent: this suite must stay runnable on a machine
  # that has never installed it. CI installs the module, so the contract is checked there.

  BeforeAll {
    # Der Import gehoert in die Run-Phase: die Discovery soll nur nachsehen, ob das Modul da ist,
    # und kein fremdes Modul laden. Fehler werden gefangen und als Testfehler gemeldet, nicht als
    # Container-Absturz - eine Datei, die in der Discovery oder in BeforeAll fliegt, nimmt ihre
    # eigenen Pruefungen mit ins Grab und meldet nur "Container failed".
    $ImportError = $null
    try { Import-Module WinTuner -ErrorAction Stop } catch { $ImportError = $_.Exception.Message }
    $ContractModule = Get-Module WinTuner | Sort-Object Version -Descending | Select-Object -First 1
  }

  It 'imports the module the contract is checked against' {
    $ImportError | Should -BeNullOrEmpty -Because 'the application imports this module at startup'
    $ContractModule | Should -Not -BeNullOrEmpty
  }

  It 'exposes every command the application calls' -ForEach $ModuleCommands {
    # Ein Test JE Befehl statt einer Schleife: eine Schleife bricht beim ersten fehlenden Namen ab
    # und verschweigt die uebrigen. $_ ist der Name aus -ForEach.
    #
    # -Module ist hier Pflicht, nicht Kosmetik: mehrere andere Testdateien in diesem Ordner
    # definieren globale Attrappen mit genau diesen Namen (Get-WtWin32Apps und Co.). Ohne die
    # Einschraenkung prueft der Vertrag im Gesamtlauf die Attrappe statt das Modul - allein
    # aufgerufen gruen, im Verbund rot, und in beiden Faellen ohne Aussage.
    (Get-Command -Module WinTuner -Name $_ -ErrorAction SilentlyContinue) |
      Should -Not -BeNullOrEmpty -Because "the application calls $_"
  }

  It 'still declares <Parameter> on <Command> as <Type>' -ForEach $ModuleContract {
    # -Module: siehe oben, sonst schaut der Vertrag im Gesamtlauf auf eine Test-Attrappe.
    $resolved = Get-Command -Module WinTuner -Name $Command -ErrorAction SilentlyContinue
    $resolved | Should -Not -BeNullOrEmpty -Because "the application calls $Command"
    $resolved.Parameters.ContainsKey($Parameter) |
      Should -BeTrue -Because "the application binds -$Parameter on $Command"
    # .ToString() und nicht .FullName: bei einem generischen Typ liefert FullName den voll
    # qualifizierten Namen samt Assembly und .NET-Fassung ("System.Nullable`1[[System.Boolean,
    # System.Private.CoreLib, Version=10.0.0.0, ...]]"). Der Vergleich konnte damit nie stimmen -
    # aufgefallen ist das erst, als diese Pruefungen ueberhaupt zu laufen anfingen. .ToString() ist
    # die kurze, ueber .NET-Fassungen hinweg stabile Form.
    $resolved.Parameters[$Parameter].ParameterType.ToString() |
      Should -Be $Type -Because 'a changed parameter type silently changes what the application asks for; see 0.15.8'
  }

  It 'reports which module version the contract was checked against' {
    # Not an assertion so much as a record: the version ends up in the CI log next to the result, so
    # a contract that starts failing can be traced to a specific module upgrade.
    Write-Host ("WinTuner module under test: {0} at {1}" -f $ContractModule.Version, $ContractModule.ModuleBase)
    $ContractModule.Version | Should -Not -BeNullOrEmpty
  }
}

Describe 'WinTuner module contract (module missing)' -Skip:(-not $SkipContract) {
  It 'is skipped, and says so, rather than passing quietly' {
    Write-Host 'WinTuner module is not installed; the module contract was NOT verified in this run.'
    $true | Should -BeTrue
  }
}
