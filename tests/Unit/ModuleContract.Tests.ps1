BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

  # The contract this suite guards. Every entry is an assumption the application makes about the
  # WinTuner module, and every one of them is invisible to the parser, to PSScriptAnalyzer and to
  # every other unit test in this folder - because those all run against stand-ins we wrote
  # ourselves. 0.15.8 is what that costs: -Update was assumed to mean "also evaluate updates" when
  # the module declares it as Nullable[bool] and treats it as a FILTER on the update state. Nothing
  # failed until a customer tenant reported no updates at all.
  #
  # A Nullable[bool] parameter is the dangerous shape: "not bound" and "$false" mean two different
  # things, so binding a [switch] through it silently changes the result set.
  $global:ModuleContract = @(
    @{ Command = 'Get-WtWin32Apps'; Parameter = 'Update';      Type = 'System.Nullable`1[System.Boolean]' }
    @{ Command = 'Get-WtWin32Apps'; Parameter = 'Superseded';  Type = 'System.Nullable`1[System.Boolean]' }
    @{ Command = 'Get-WtWin32Apps'; Parameter = 'Superseding'; Type = 'System.Nullable`1[System.Boolean]' }
    @{ Command = 'Get-WtWin32Apps'; Parameter = 'IsAssigned';  Type = 'System.Nullable`1[System.Boolean]' }
    @{ Command = 'Get-WtWin32Apps'; Parameter = 'NameContains'; Type = 'System.String' }
    @{ Command = 'Deploy-WtWin32App'; Parameter = 'KeepAssignments'; Type = 'System.Management.Automation.SwitchParameter' }
    @{ Command = 'Deploy-WtWin32App'; Parameter = 'GraphId';         Type = 'System.String' }
  )
  # Commands the application calls at all. A rename or removal in a module update has to be loud.
  $global:ModuleCommands = @(
    'Get-WtWin32Apps', 'Deploy-WtWin32App', 'New-WtWingetPackage', 'Remove-WtWin32App',
    'Update-WtIntuneApp', 'Get-WtToken', 'Connect-WtWinTuner', 'Disconnect-WtWinTuner'
  )

  $global:WinTunerModule = Get-Module -ListAvailable -Name WinTuner | Sort-Object Version -Descending | Select-Object -First 1
  if ($global:WinTunerModule) {
    try { Import-Module WinTuner -ErrorAction Stop } catch { $global:WinTunerModule = $null }
  }
  $global:SkipContract = -not $global:WinTunerModule
}

Describe 'WinTuner module contract' -Skip:($global:SkipContract) {
  # Skipped rather than failed when the module is absent: this suite must stay runnable on a machine
  # that has never installed it. CI installs the module, so the contract is checked there.

  It 'exposes every command the application calls' {
    foreach ($name in $global:ModuleCommands) {
      (Get-Command -Name $name -ErrorAction SilentlyContinue) |
        Should -Not -BeNullOrEmpty -Because "the application calls $name"
    }
  }

  It 'still declares <Parameter> on <Command> as <Type>' -ForEach $global:ModuleContract {
    $command = Get-Command -Name $Command -ErrorAction SilentlyContinue
    $command | Should -Not -BeNullOrEmpty -Because "the application calls $Command"
    $command.Parameters.ContainsKey($Parameter) |
      Should -BeTrue -Because "the application binds -$Parameter on $Command"
    $command.Parameters[$Parameter].ParameterType.FullName |
      Should -Be $Type -Because 'a changed parameter type silently changes what the application asks for; see 0.15.8'
  }

  It 'reports which module version the contract was checked against' {
    # Not an assertion so much as a record: the version ends up in the CI log next to the result, so
    # a contract that starts failing can be traced to a specific module upgrade.
    Write-Host ("WinTuner module under test: {0} at {1}" -f $global:WinTunerModule.Version, $global:WinTunerModule.ModuleBase)
    $global:WinTunerModule.Version | Should -Not -BeNullOrEmpty
  }
}

Describe 'WinTuner module contract (module missing)' -Skip:(-not $global:SkipContract) {
  It 'is skipped, and says so, rather than passing quietly' {
    Write-Host 'WinTuner module is not installed; the module contract was NOT verified in this run.'
    $true | Should -BeTrue
  }
}
