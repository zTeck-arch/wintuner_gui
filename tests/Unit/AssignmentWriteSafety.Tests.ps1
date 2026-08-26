BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '40-Graph.ps1' -Name 'Get-ErrorHttpStatus')))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '45-Assignments.ps1' -Name 'Get-AssignmentWriteErrorText')))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '82-TenantApps.ps1' -Name 'Get-ExclusionsWithoutInclude')))

  function global:New-TestAssignment {
    param([string]$Intent = 'required', [string]$TargetType = 'groupAssignmentTarget', $RawTarget = @{ x = 1 })
    [pscustomobject]@{ Intent = $Intent; TargetType = $TargetType; RawTarget = $RawTarget }
  }
  # Mimics the shape Invoke-RestMethod throws: the status sits on .Response.StatusCode.
  function global:New-HttpError {
    param([int]$Status)
    $response = [pscustomobject]@{ StatusCode = $Status }
    $ex = [System.Exception]::new("Response status code does not indicate success: $Status.")
    $ex | Add-Member -NotePropertyName Response -NotePropertyValue $response -Force
    return [System.Management.Automation.ErrorRecord]::new($ex, 'HttpError', 'NotSpecified', $null)
  }
}

Describe 'Get-AssignmentWriteErrorText' {
  # Regression: every assignment write surfaced the raw Graph message, so a missing Intune role read
  # as "Response status code does not indicate success: 403 (Forbidden)." in the middle of a batch -
  # which sends the reader looking for a transient fault that will never clear.
  It 'explains a 403 as a permission problem that retrying will not fix' {
    $text = Get-AssignmentWriteErrorText -ErrorRecord (New-HttpError -Status 403)
    $text | Should -Match 'no permission to change assignments'
    $text | Should -Match 'retrying will not help'
  }

  It 'explains a 401 as an expired session' {
    Get-AssignmentWriteErrorText -ErrorRecord (New-HttpError -Status 401) | Should -Match 'sign in again'
  }

  It 'explains a 429 as throttling that IS worth retrying' {
    Get-AssignmentWriteErrorText -ErrorRecord (New-HttpError -Status 429) | Should -Match 'worth retrying'
  }

  It 'explains a 404 as an app that is gone' {
    Get-AssignmentWriteErrorText -ErrorRecord (New-HttpError -Status 404) | Should -Match 'no longer exists'
  }

  It 'always keeps the original Graph text so nothing is hidden' {
    Get-AssignmentWriteErrorText -ErrorRecord (New-HttpError -Status 403) | Should -Match 'Graph said'
  }

  It 'passes an error without a status through unchanged' {
    $err = $null
    try { throw 'something local went wrong' } catch { $err = $_ }
    Get-AssignmentWriteErrorText -ErrorRecord $err | Should -Be 'something local went wrong'
  }

  It 'names an unmapped status rather than staying silent about it' {
    Get-AssignmentWriteErrorText -ErrorRecord (New-HttpError -Status 500) | Should -Match 'HTTP 500'
  }
}

Describe 'Get-ExclusionsWithoutInclude' {
  # Regression: the manager let an admin keep an "exclude group X" entry after removing the last
  # include. An exclusion only narrows an include; alone it reaches nobody, so the app quietly ends
  # up assigned to no one while the list still shows a line per assignment.
  It 'counts an exclusion that has no include for the same intent' {
    $set = @(New-TestAssignment -Intent 'required' -TargetType 'exclusionGroupAssignmentTarget')
    Get-ExclusionsWithoutInclude -Assignments $set | Should -Be 1
  }

  It 'is happy when an include for the same intent exists' {
    $set = @(
      (New-TestAssignment -Intent 'required' -TargetType 'exclusionGroupAssignmentTarget'),
      (New-TestAssignment -Intent 'required' -TargetType 'groupAssignmentTarget')
    )
    Get-ExclusionsWithoutInclude -Assignments $set | Should -Be 0
  }

  It 'accepts All Users or All Devices as the include' {
    $set = @(
      (New-TestAssignment -Intent 'available' -TargetType 'exclusionGroupAssignmentTarget'),
      (New-TestAssignment -Intent 'available' -TargetType 'allLicensedUsersAssignmentTarget')
    )
    Get-ExclusionsWithoutInclude -Assignments $set | Should -Be 0
  }

  It 'judges each intent on its own - an include for another intent does not count' {
    $set = @(
      (New-TestAssignment -Intent 'required'  -TargetType 'exclusionGroupAssignmentTarget'),
      (New-TestAssignment -Intent 'available' -TargetType 'groupAssignmentTarget')
    )
    Get-ExclusionsWithoutInclude -Assignments $set | Should -Be 1
  }

  It 'counts every lonely exclusion, not just the first' {
    $set = @(
      (New-TestAssignment -Intent 'required' -TargetType 'exclusionGroupAssignmentTarget'),
      (New-TestAssignment -Intent 'required' -TargetType 'exclusionGroupAssignmentTarget')
    )
    Get-ExclusionsWithoutInclude -Assignments $set | Should -Be 2
  }

  It 'says nothing about a set without exclusions' {
    $set = @(New-TestAssignment -Intent 'required' -TargetType 'groupAssignmentTarget')
    Get-ExclusionsWithoutInclude -Assignments $set | Should -Be 0
  }

  It 'handles an empty set' {
    Get-ExclusionsWithoutInclude -Assignments @() | Should -Be 0
  }
}
