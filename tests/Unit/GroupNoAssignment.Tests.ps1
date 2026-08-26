# Audit finding #30: Group-UpdateCandidates compared the localized Summary text against the '<none>'
# sentinel, so the "no assignment" flag was NEVER set. It must test the Signature, which carries the
# sentinel. This flag decides whether the UI shows "no assignment" - the state a cleanup acts on.

BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '40-Graph.ps1' -Name 'Group-UpdateCandidates')))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '20-Version.ps1' -Name 'Test-IsNewerVersion', 'Get-ComparableVersionParts')))

  function global:New-Member {
    param([string]$Ver, [string]$GraphId)
    [pscustomobject]@{ Name='Adobe Reader'; PackageId='Adobe.Reader'; LatestVersion='2.0'
      CurrentVersion=$Ver; GraphId=$GraphId; ExistingTargetGraphId=$null; ExistingTargetName=$null }
  }
}

Describe 'Group-UpdateCandidates NoAssignment [#30]' {
  It 'sets NoAssignment when every grouped predecessor probes as <none>' {
    function global:Get-AppAssignmentScopeProbe { param($AppId,$AppName)
      [pscustomobject]@{ Succeeded=$true; Signature='<none>'; Summary='no assignment'; Count=0; ErrorMessage=$null }
    }
    $rows = @(Group-UpdateCandidates -Candidates @((New-Member '1.0' 'a'), (New-Member '1.5' 'b')))
    $rows.Count | Should -Be 1
    $rows[0].NoAssignment | Should -BeTrue
  }

  It 'does NOT set NoAssignment when a predecessor carries an assignment' {
    function global:Get-AppAssignmentScopeProbe { param($AppId,$AppName)
      [pscustomobject]@{ Succeeded=$true; Signature='required|grp|none|-|source:direct|settings:none'; Summary='required, grp'; Count=1; ErrorMessage=$null }
    }
    $rows = @(Group-UpdateCandidates -Candidates @((New-Member '1.0' 'a'), (New-Member '1.5' 'b')))
    $rows[0].NoAssignment | Should -BeFalse
  }

  It 'does NOT set NoAssignment when a probe failed (unknown must not read as none)' {
    function global:Get-AppAssignmentScopeProbe { param($AppId,$AppName)
      [pscustomobject]@{ Succeeded=$false; Signature=$null; Summary='unknown'; Count=$null; ErrorMessage='boom' }
    }
    $rows = @(Group-UpdateCandidates -Candidates @((New-Member '1.0' 'a'), (New-Member '1.5' 'b')))
    $rows[0].NoAssignment | Should -BeFalse
  }
}
