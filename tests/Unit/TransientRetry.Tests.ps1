BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '25-WinGetData.ps1' -Name @(
    'Test-IsTransientModuleRace', 'Invoke-WithTransientRetry'))))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '30-UpdateTargets.ps1' -Name 'Remove-SupersededInventoryOverlap')))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '70-Runtime.ps1' -Name 'Format-ErrorDetail')))
}

Describe 'Format-ErrorDetail' {
  It 'includes the exception type, the message and any inner exception' {
    $err = $null
    try {
      throw [System.InvalidOperationException]::new(
        'outer failed', [System.ArgumentNullException]::new('key', 'inner was null'))
    } catch { $err = $_ }

    $detail = Format-ErrorDetail $err
    $detail | Should -Match '\[InvalidOperationException\]'
    $detail | Should -Match 'outer failed'
    $detail | Should -Match 'inner\[ArgumentNullException\]'
    $detail | Should -Match 'inner was null'
  }

  It 'never throws, even on a bare error without an inner exception' {
    $err = $null
    try { throw 'plain message' } catch { $err = $_ }
    { Format-ErrorDetail $err } | Should -Not -Throw
    (Format-ErrorDetail $err) | Should -Match 'plain message'
  }
}

Describe 'Test-IsTransientModuleRace' {
  It 'recognises the module race and throttle shapes as transient' {
    foreach ($m in @(
      'Collection was modified; enumeration operation may not execute.',
      'Value cannot be null. (Parameter ''key'')',
      'The operation has timed out',
      'ServiceUnavailable',
      'Response status code 503',
      'Too Many Requests')) {
      Test-IsTransientModuleRace $m | Should -BeTrue -Because "'$m' is a known transient race/throttle"
    }
  }

  It 'does NOT treat real errors as transient' {
    foreach ($m in @(
      'Request not applicable to target tenant.',
      'Cannot bind argument to parameter ''ActiveApps'' because it is an empty array.',
      'Forbidden: application is not authorized',
      '',
      $null)) {
      Test-IsTransientModuleRace $m | Should -BeFalse -Because "'$m' must fail immediately, not retry"
    }
  }
}

Describe 'Invoke-WithTransientRetry' {
  It 'retries a transient failure and then returns the eventual result' {
    $script:calls = 0
    $result = Invoke-WithTransientRetry -Label 'test' -Action {
      $script:calls++
      if ($script:calls -lt 3) { throw 'Collection was modified; enumeration operation may not execute.' }
      'ok'
    }
    $result | Should -Be 'ok'
    $script:calls | Should -Be 3
  }

  It 'rethrows a non-transient error immediately without retrying' {
    $script:calls = 0
    { Invoke-WithTransientRetry -Action {
        $script:calls++
        throw 'Request not applicable to target tenant.'
      } } | Should -Throw '*not applicable to target tenant*'
    $script:calls | Should -Be 1
  }

  It 'gives up after MaxRetries and rethrows the transient error' {
    $script:calls = 0
    { Invoke-WithTransientRetry -MaxRetries 2 -Action {
        $script:calls++
        throw 'Collection was modified; enumeration operation may not execute.'
      } } | Should -Throw '*Collection was modified*'
    # one initial attempt plus two retries
    $script:calls | Should -Be 3
  }
}

Describe 'Remove-SupersededInventoryOverlap with an empty active inventory' {
  # Regression: a tenant whose apps are all superseded (managed=0, superseded>0) handed an empty
  # array here. The Mandatory parameter rejected it - "Cannot bind argument to parameter
  # 'ActiveApps' because it is an empty array" - which aborted the whole "load apps" step.
  It 'accepts an empty array and returns nothing instead of throwing a binding error' {
    $out = @(Remove-SupersededInventoryOverlap -ActiveApps @() -SupersededApps @(
      [pscustomobject]@{ GraphId = '11111111-1111-1111-1111-111111111111' }))
    $out.Count | Should -Be 0
  }

  It 'still filters overlapping superseded ids out of a non-empty active list' {
    $active = @(
      [pscustomobject]@{ Name = 'Keep'; GraphId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' },
      [pscustomobject]@{ Name = 'Drop'; GraphId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' })
    $superseded = @([pscustomobject]@{ GraphId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' })
    $out = @(Remove-SupersededInventoryOverlap -ActiveApps $active -SupersededApps $superseded)
    $out.Count | Should -Be 1
    $out[0].Name | Should -Be 'Keep'
  }
}
