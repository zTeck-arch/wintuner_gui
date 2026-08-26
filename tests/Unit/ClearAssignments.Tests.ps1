# Audit finding #6: with "move assignments on update" switched OFF, the WinTuner module still copies
# the predecessor's assignments onto the new version, so both ended up assigned while the UI promised
# the new one would be unassigned. The update engine now calls Clear-AppAssignments on the new app to
# make that promise true. These tests cover the clearing primitive.

BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '45-Assignments.ps1' -Name 'Clear-AppAssignments')))

  $global:AppId = '11111111-1111-1111-1111-111111111111'
  function global:Get-WtToken { 'test-token' }
  function global:Add-SessionActivity { }
  function global:Get-UiString { param($k) $k }

  function global:Reset-Capture {
    $global:PostedBody = $null
    $global:PostCount = 0
  }
  function global:Invoke-RestMethod {
    param($Method, $Uri, $Headers, $Body, $ErrorAction)
    $global:PostCount++
    $global:PostedBody = $Body
    $null
  }
}

Describe 'Clear-AppAssignments' {
  BeforeEach { Reset-Capture }

  It 'posts an empty assignment list when the app has direct assignments' {
    function global:Get-GraphCollectionItems { param($Uri,$Headers)
      ,@([pscustomobject]@{ intent='required'; source='direct'; target=@{ '@odata.type'='#microsoft.graph.groupAssignmentTarget'; groupId='g' } })
    }
    Clear-AppAssignments -AppId $global:AppId -AppName 'Adobe Reader' | Should -BeTrue
    $global:PostCount | Should -Be 1
    ($global:PostedBody | ConvertFrom-Json).mobileAppAssignments | Should -BeNullOrEmpty
  }

  It 'does not post when the app already has no assignments' {
    function global:Get-GraphCollectionItems { param($Uri,$Headers) [object[]]@() }
    Clear-AppAssignments -AppId $global:AppId -AppName 'Adobe Reader' | Should -BeTrue
    $global:PostCount | Should -Be 0
  }

  It 'refuses to clear policy-set / inherited assignments' {
    function global:Get-GraphCollectionItems { param($Uri,$Headers)
      ,@([pscustomobject]@{ intent='required'; source='policySets'; target=@{ groupId='g' } })
    }
    Clear-AppAssignments -AppId $global:AppId -AppName 'Adobe Reader' | Should -BeFalse
    $global:PostCount | Should -Be 0
  }

  It 'rejects an invalid app id without calling Graph' {
    function global:Get-GraphCollectionItems { param($Uri,$Headers) throw 'should not be called' }
    Clear-AppAssignments -AppId 'not-a-guid' -AppName 'x' | Should -BeFalse
  }
}
