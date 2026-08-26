# Regression guard for the critical Tenant-Apps data-loss bug (Opus-5 audit finding #1):
# the tenant "edit assignment settings" path used to pass the deploy card's default TargetChanges
# into Set-AppAssignmentSettings, silently turning an exclusion into a normal group assignment and
# stripping the assignment filter. The fix routes that path through Show-AppSettingsDialog, which
# only ever writes SETTINGS - i.e. it calls Set-AppAssignmentSettings WITHOUT -TargetChanges.
#
# These tests lock in the contract the fix relies on:
#   * no -TargetChanges  -> targets (exclusion, filter) are written back verbatim
#   * deploy TargetChanges -> targets are rewritten (documents the deploy path's intended behaviour)

BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '45-Assignments.ps1' -Name 'Set-AppAssignmentSettings')))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '20-Version.ps1' -Name 'Test-GuidString')))

  $global:AppId    = '11111111-1111-1111-1111-111111111111'
  $global:GroupId  = '22222222-2222-2222-2222-222222222222'
  $global:FilterId = '33333333-3333-3333-3333-333333333333'

  # Ambient helpers the function reaches for. Kept trivial so the test isolates target handling.
  function global:Get-WtToken { 'test-token' }
  function global:Merge-AppAssignmentSettings { param($Existing, $Changes) $Existing }
  function global:Get-AssignmentSettingsSummary { param($s) 'x' }
  function global:Add-SessionActivity { }
  function global:Get-UiString { param($k) $k }

  # The one existing assignment: an EXCLUSION for a concrete group, carrying an assignment filter.
  function global:Get-GraphCollectionItems {
    param($Uri, $Headers)
    ,@(
      [pscustomobject]@{
        intent   = 'required'
        source   = 'direct'
        settings = @{ notificationSetting = 'showAll' }
        target   = [pscustomobject]@{
          '@odata.type' = '#microsoft.graph.exclusionGroupAssignmentTarget'
          groupId       = $global:GroupId
          deviceAndAppManagementAssignmentFilterType = 'include'
          deviceAndAppManagementAssignmentFilterId   = $global:FilterId
        }
      }
    )
  }

  # Capture what would be POSTed to /assign.
  function global:Invoke-RestMethod {
    param($Method, $Uri, $Headers, $Body, $ErrorAction)
    $global:PostedBody = $Body
    $null
  }

  function global:Get-PostedTarget {
    ($global:PostedBody | ConvertFrom-Json).mobileAppAssignments[0].target
  }
}

Describe 'Set-AppAssignmentSettings target handling' {
  BeforeEach { $global:PostedBody = $null }

  Context 'called WITHOUT -TargetChanges (the tenant settings path)' {
    It 'keeps the exclusion target and its filter untouched' {
      $res = Set-AppAssignmentSettings -AppId $global:AppId -Settings @{ notificationSetting = 'showAll' } -AppName 'Adobe Reader'
      $res.ErrorMessage | Should -BeNullOrEmpty
      $t = Get-PostedTarget
      $t.'@odata.type' | Should -Be '#microsoft.graph.exclusionGroupAssignmentTarget'
      $t.deviceAndAppManagementAssignmentFilterType | Should -Be 'include'
      $t.deviceAndAppManagementAssignmentFilterId   | Should -Be $global:FilterId
    }
  }

  Context 'called WITH deploy-style -TargetChanges (the deployment path)' {
    It 'rewrites the exclusion to a group target and drops the filter' {
      $changes = @{ AssignmentMode = 'include'; ExcludeBaseTarget = 'AllUsers'; FilterType = 'none' }
      $res = Set-AppAssignmentSettings -AppId $global:AppId -Settings @{ notificationSetting = 'showAll' } -TargetChanges $changes -AppName 'Adobe Reader'
      $res.ErrorMessage | Should -BeNullOrEmpty
      $t = Get-PostedTarget
      $t.'@odata.type' | Should -Be '#microsoft.graph.groupAssignmentTarget'
      $t.deviceAndAppManagementAssignmentFilterType | Should -Be 'none'
      $t.PSObject.Properties.Name | Should -Not -Contain 'deviceAndAppManagementAssignmentFilterId'
    }
  }
}
