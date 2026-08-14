BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-UiStringsText)))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '10-Settings.ps1' -Name 'Resolve-CleanupOptionConflict')))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '40-Graph.ps1' -Name 'Get-UpdateCleanupNotice')))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '70-Runtime.ps1' -Name 'Test-WtConnected')))
  $script:uiLanguage = 'de'
}

Describe 'Resolve-CleanupOptionConflict' {
  # The two options are mutually exclusive by construction: immediate removal runs inside the update
  # and always leaves exactly one version, so "keep the newest N" could never apply to the app just
  # updated. The conflict resolves towards the non-destructive option - a predecessor that is still
  # there can be deleted later, one that is gone cannot be brought back.
  It 'switches the destructive option off when both are set' {
    $script:settings = @{ AutoRemoveSuperseded = $true; AutoVersionCleanup = $true }
    Resolve-CleanupOptionConflict | Should -BeTrue
    $script:settings.AutoRemoveSuperseded | Should -BeFalse
    $script:settings.AutoVersionCleanup | Should -BeTrue
  }
  It 'leaves immediate removal alone when it is the only one' {
    $script:settings = @{ AutoRemoveSuperseded = $true; AutoVersionCleanup = $false }
    Resolve-CleanupOptionConflict | Should -BeFalse
    $script:settings.AutoRemoveSuperseded | Should -BeTrue
  }
  It 'leaves version trimming alone when it is the only one' {
    $script:settings = @{ AutoRemoveSuperseded = $false; AutoVersionCleanup = $true }
    Resolve-CleanupOptionConflict | Should -BeFalse
    $script:settings.AutoVersionCleanup | Should -BeTrue
  }
  It 'does nothing when both are off' {
    $script:settings = @{ AutoRemoveSuperseded = $false; AutoVersionCleanup = $false }
    Resolve-CleanupOptionConflict | Should -BeFalse
  }
}

Describe 'Get-UpdateCleanupNotice' {
  # The confirmation used to show one of two fixed paragraphs driven by a single option, so it never
  # said whether assignments would move or whether older versions would be trimmed afterwards -
  # both of which change the tenant.
  BeforeEach { $script:keepVersionCount = 2 }

  It 'states that assignments move when the hand-over is on' {
    $script:settings = @{ MoveAssignmentsOnUpdate = $true; AutoRemoveSuperseded = $false; AutoVersionCleanup = $false }
    Get-UpdateCleanupNotice | Should -Match 'ziehen auf die neue Version um'
  }
  It 'states that assignments stay when the hand-over is off' {
    $script:settings = @{ MoveAssignmentsOnUpdate = $false; AutoRemoveSuperseded = $false; AutoVersionCleanup = $false }
    $notice = Get-UpdateCleanupNotice
    $notice | Should -Match 'bleiben auf der alten Version'
    $notice | Should -Not -Match 'ziehen auf die neue Version um'
  }
  It 'announces deletion of assigned predecessors only when it is enabled' {
    $script:settings = @{ MoveAssignmentsOnUpdate = $true; AutoRemoveSuperseded = $true; AutoVersionCleanup = $false }
    $notice = Get-UpdateCleanupNotice
    $notice | Should -Match 'werden gelöscht'
    $notice | Should -Not -Match 'bleiben erhalten'
  }
  It 'mentions version trimming only when it will run' {
    $script:settings = @{ MoveAssignmentsOnUpdate = $true; AutoRemoveSuperseded = $false; AutoVersionCleanup = $false }
    Get-UpdateCleanupNotice | Should -Not -Match 'neuesten 2 Versionen'

    $script:settings = @{ MoveAssignmentsOnUpdate = $true; AutoRemoveSuperseded = $false; AutoVersionCleanup = $true }
    Get-UpdateCleanupNotice | Should -Match 'neuesten 2 Versionen'
  }
  It 'uses the configured keep count rather than a hard-coded 2' {
    $script:settings = @{ MoveAssignmentsOnUpdate = $true; AutoRemoveSuperseded = $false; AutoVersionCleanup = $true }
    $script:keepVersionCount = 5
    Get-UpdateCleanupNotice | Should -Match 'neuesten 5'
  }
  It 'always states the rule for unassigned predecessors' {
    $script:settings = @{ MoveAssignmentsOnUpdate = $true; AutoRemoveSuperseded = $false; AutoVersionCleanup = $false }
    Get-UpdateCleanupNotice | Should -Match 'ohne Zuweisung'
  }
}

Describe 'Test-WtConnected' {
  BeforeEach {
    $global:WtCalls = 0
    Set-Item -Path function:global:Get-WtWin32Apps -Value {
      param($Update, $Superseded, $ErrorAction)
      $global:WtCalls++
      & $global:WtHandler $global:WtCalls
    }
  }

  # These shapes mean "ask again", not "you are not signed in": races inside the module's inventory
  # call, throttling, or a momentary service blip. Reporting them as an authentication error sent
  # troubleshooting after credentials that were never the problem.
  It 'retries "Collection was modified" and then succeeds' {
    $global:WtHandler = { param($n) if ($n -lt 2) { throw 'Collection was modified; enumeration operation may not execute.' }; @() }
    Test-WtConnected | Should -BeTrue
    $global:WtCalls | Should -Be 2
  }
  It 'retries "Value cannot be null" as well' {
    $global:WtHandler = { param($n) if ($n -lt 2) { throw "Value cannot be null. (Parameter 'value')" }; @() }
    Test-WtConnected | Should -BeTrue
    $global:WtCalls | Should -Be 2
  }
  It 'gives up after the configured number of attempts' {
    $global:WtHandler = { param($n) throw 'Collection was modified; enumeration operation may not execute.' }
    Test-WtConnected -Attempts 2 | Should -BeFalse
    $global:WtCalls | Should -Be 2
  }
  It 'fails immediately on a permission error, because retrying cannot fix it' {
    $global:WtHandler = { param($n) throw 'Forbidden. Required permission scope DeviceManagementApps.ReadWrite.All is missing.' }
    Test-WtConnected | Should -BeFalse
    $global:WtCalls | Should -Be 1
  }
  It 'treats an empty tenant as a valid answer' {
    $global:WtHandler = { param($n) @() }
    Test-WtConnected | Should -BeTrue
    $global:WtCalls | Should -Be 1
  }
}
