# Audit findings #13 and #14.
#  #13: Get-AppAssignmentProbe now reports HasInstallingAssignment separately from HasAssignments,
#       and Test-SuccessorAssignmentsConfirmed requires an INSTALLING assignment before it lets a
#       predecessor be deleted (a standalone exclusion / uninstall intent installs nobody).
#  #14: the "exclude group X" include baseline honors ExcludeBaseTarget (All Devices vs All Users)
#       in BOTH writers via New-AssignmentBaseTarget.

BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '45-Assignments.ps1' `
    -Name 'New-AssignmentBaseTarget', 'Set-AppAssignmentSettings', 'Test-SuccessorAssignmentsConfirmed')))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '40-Graph.ps1' -Name 'Get-AppAssignmentProbe')))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '20-Version.ps1' -Name 'Test-GuidString')))

  $global:AppId = '11111111-1111-1111-1111-111111111111'
  function global:Get-WtToken { 'test-token' }
  function global:Add-SessionActivity { }
  function global:Get-UiString { param($k) $k }
  function global:Merge-AppAssignmentSettings { param($Existing, $Changes) $Existing }
  function global:Get-AssignmentSettingsSummary { param($s) 'x' }
  function global:Invoke-RestMethod { param($Method,$Uri,$Headers,$Body,$ErrorAction) $global:PostedBody = $Body; $null }
}

Describe 'New-AssignmentBaseTarget' {
  It 'defaults to All Users' {
    (New-AssignmentBaseTarget).'@odata.type' | Should -Be '#microsoft.graph.allLicensedUsersAssignmentTarget'
  }
  It 'honors All Devices' {
    (New-AssignmentBaseTarget -ExcludeBaseTarget 'AllDevices').'@odata.type' | Should -Be '#microsoft.graph.allDevicesAssignmentTarget'
  }
}

Describe 'Get-AppAssignmentProbe.HasInstallingAssignment [#13]' {
  It 'is false when the only assignment is a standalone exclusion' {
    function global:Get-GraphCollectionItems { param($Uri,$Headers)
      ,@([pscustomobject]@{ intent='required'; source='direct'; target=@{ '@odata.type'='#microsoft.graph.exclusionGroupAssignmentTarget'; groupId='g' } })
    }
    $p = Get-AppAssignmentProbe -AppId $global:AppId -AppName 'X'
    $p.HasAssignments | Should -BeTrue
    $p.HasInstallingAssignment | Should -BeFalse
  }
  It 'is false when the only assignment is an uninstall intent' {
    function global:Get-GraphCollectionItems { param($Uri,$Headers)
      ,@([pscustomobject]@{ intent='uninstall'; source='direct'; target=@{ '@odata.type'='#microsoft.graph.groupAssignmentTarget'; groupId='g' } })
    }
    (Get-AppAssignmentProbe -AppId $global:AppId -AppName 'X').HasInstallingAssignment | Should -BeFalse
  }
  It 'is true for a required group assignment' {
    function global:Get-GraphCollectionItems { param($Uri,$Headers)
      ,@([pscustomobject]@{ intent='required'; source='direct'; target=@{ '@odata.type'='#microsoft.graph.groupAssignmentTarget'; groupId='g' } })
    }
    (Get-AppAssignmentProbe -AppId $global:AppId -AppName 'X').HasInstallingAssignment | Should -BeTrue
  }
}

Describe 'Test-SuccessorAssignmentsConfirmed [#13]' {
  It 'does NOT confirm hand-over when the successor only has an exclusion' {
    function global:Get-GraphCollectionItems { param($Uri,$Headers)
      ,@([pscustomobject]@{ intent='required'; source='direct'; target=@{ '@odata.type'='#microsoft.graph.exclusionGroupAssignmentTarget'; groupId='g' } })
    }
    Test-SuccessorAssignmentsConfirmed -NewAppId $global:AppId -AppName 'X' -Attempts 1 | Should -BeFalse
  }
  It 'confirms hand-over when the successor has a required group assignment' {
    function global:Get-GraphCollectionItems { param($Uri,$Headers)
      ,@([pscustomobject]@{ intent='required'; source='direct'; target=@{ '@odata.type'='#microsoft.graph.groupAssignmentTarget'; groupId='g' } })
    }
    Test-SuccessorAssignmentsConfirmed -NewAppId $global:AppId -AppName 'X' -Attempts 1 | Should -BeTrue
  }
}

Describe 'Set-AppAssignmentSettings honors ExcludeBaseTarget [#14]' {
  It 'uses All Devices as the synthesized include base when asked' {
    function global:Get-GraphCollectionItems { param($Uri,$Headers)
      ,@([pscustomobject]@{ intent='required'; source='direct'; settings=@{}; target=[pscustomobject]@{ '@odata.type'='#microsoft.graph.groupAssignmentTarget'; groupId='g' } })
    }
    $changes = @{ AssignmentMode='exclude'; ExcludeBaseTarget='AllDevices' }
    $res = Set-AppAssignmentSettings -AppId $global:AppId -Settings @{} -TargetChanges $changes -AppName 'X'
    $res.ErrorMessage | Should -BeNullOrEmpty
    $targets = ($global:PostedBody | ConvertFrom-Json).mobileAppAssignments.target.'@odata.type'
    $targets | Should -Contain '#microsoft.graph.allDevicesAssignmentTarget'
    $targets | Should -Not -Contain '#microsoft.graph.allLicensedUsersAssignmentTarget'
  }
}
