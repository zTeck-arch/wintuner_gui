BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '45-Assignments.ps1' -Name @(
    'Get-AutoUpdateEffectVerdict', 'Enable-AppAutoUpdateChecked'))))
}

Describe 'Get-AutoUpdateEffectVerdict' {
  # Regression: Intune stores the per-app auto-update flag on the app's EXISTING assignments (the
  # module's -EnableAutoUpdate reaches EnableAppAutoUpdateOnExistingAssignmentsAsync). An app
  # deployed without an assignment is therefore unchanged, while the call still reports success -
  # and the GUI used to log "Enabled Intune auto-update" regardless.
  It 'reports applied when the app has assignments to write the flag onto' {
    Get-AutoUpdateEffectVerdict -ProbeSucceeded $true -HasAssignments $true | Should -Be 'applied'
  }

  It 'reports noAssignments when there is nothing for the flag to live on' {
    Get-AutoUpdateEffectVerdict -ProbeSucceeded $true -HasAssignments $false | Should -Be 'noAssignments'
  }

  It 'reports unknown when the probe failed, instead of guessing either way' {
    # Claiming certainty here is exactly how a silent no-op survives a release.
    Get-AutoUpdateEffectVerdict -ProbeSucceeded $false -HasAssignments $false | Should -Be 'unknown'
    Get-AutoUpdateEffectVerdict -ProbeSucceeded $false -HasAssignments $true | Should -Be 'unknown'
  }
}

Describe 'Enable-AppAutoUpdateChecked' {
  BeforeEach {
    $global:TestLog.Clear()
    $global:AutoUpdateCalls = [System.Collections.Generic.List[object]]::new()
    $global:ProbeResult = [pscustomobject]@{ Succeeded = $true; HasAssignments = $true; Count = 2 }
    $global:ThrowOnUpdate = $false

    function global:Get-AppAssignmentProbe {
      param([string]$AppId, [string]$AppName)
      return $global:ProbeResult
    }
    function global:Update-WtIntuneApp {
      param([string]$AppId, [switch]$EnableAutoUpdate, $ErrorAction)
      $global:AutoUpdateCalls.Add($AppId)
      if ($global:ThrowOnUpdate) { throw 'Graph said no' }
    }
  }
  AfterAll {
    Remove-Item function:global:Get-AppAssignmentProbe -ErrorAction SilentlyContinue
    Remove-Item function:global:Update-WtIntuneApp -ErrorAction SilentlyContinue
    Remove-Variable -Name AutoUpdateCalls, ProbeResult, ThrowOnUpdate -Scope Global -ErrorAction SilentlyContinue
  }

  It 'says nothing to the user when the flag really landed on assignments' {
    $out = Enable-AppAutoUpdateChecked -AppId 'app-1' -AppName 'ACME Client'
    $out.Verdict | Should -Be 'applied'
    $out.Problem | Should -BeNullOrEmpty
    $global:AutoUpdateCalls.Count | Should -Be 1
    ($global:TestLog -join "`n") | Should -Match 'on 2 existing assignment'
  }

  It 'tells the user nothing changed when the app has no assignment' {
    $global:ProbeResult = [pscustomobject]@{ Succeeded = $true; HasAssignments = $false; Count = 0 }
    $out = Enable-AppAutoUpdateChecked -AppId 'app-2' -AppName 'ACME Client'
    $out.Verdict | Should -Be 'noAssignments'
    $out.Problem | Should -Match 'no assignment yet'
    $out.Problem | Should -Match 'nothing was changed'
    # The call still happened - the point is the honest report, not skipping the work.
    $global:AutoUpdateCalls.Count | Should -Be 1
  }

  It 'admits it does not know when the assignments could not be read' {
    $global:ProbeResult = [pscustomobject]@{ Succeeded = $false; HasAssignments = $true; Count = $null }
    $out = Enable-AppAutoUpdateChecked -AppId 'app-3'
    $out.Verdict | Should -Be 'unknown'
    $out.Problem | Should -Match 'unknown whether the setting took effect'
  }

  It 'reports a real failure of the call as failed' {
    $global:ThrowOnUpdate = $true
    $out = Enable-AppAutoUpdateChecked -AppId 'app-4' -AppName 'ACME Client'
    $out.Verdict | Should -Be 'failed'
    $out.Problem | Should -Match 'Graph said no'
  }

  It 'falls back to the app id in messages when no name is known' {
    $global:ThrowOnUpdate = $true
    $out = Enable-AppAutoUpdateChecked -AppId 'app-5'
    $out.Problem | Should -Match 'app-5'
  }
}
