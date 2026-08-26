BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '25-WinGetData.ps1' -Name 'Test-WingetIndexCacheCold')))
  $script:workDir = Join-Path ([IO.Path]::GetTempPath()) ("wt-index-" + [Guid]::NewGuid().ToString('N'))
  [void][IO.Directory]::CreateDirectory($script:workDir)
}

AfterAll {
  if ($script:workDir -and (Test-Path -LiteralPath $script:workDir)) {
    Remove-Item -LiteralPath $script:workDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}

Describe 'Test-WingetIndexCacheCold' {
  BeforeEach {
    $script:cacheFile = Join-Path $script:workDir ([Guid]::NewGuid().ToString('N') + '.json')
  }

  It 'calls a missing cache cold' {
    $state = Test-WingetIndexCacheCold -CachePath $script:cacheFile
    $state.Cold | Should -BeTrue
    $state.Reason | Should -Be 'missing'
  }

  It 'calls an empty cache cold' {
    Set-Content -LiteralPath $script:cacheFile -Value '' -NoNewline
    $state = Test-WingetIndexCacheCold -CachePath $script:cacheFile
    $state.Cold | Should -BeTrue
    $state.Reason | Should -Be 'empty'
  }

  It 'calls a fresh cache warm and reports its age' {
    Set-Content -LiteralPath $script:cacheFile -Value '{"x":1}'
    $state = Test-WingetIndexCacheCold -CachePath $script:cacheFile
    $state.Cold | Should -BeFalse
    $state.Reason | Should -Be 'fresh'
    $state.AgeHours | Should -BeLessThan 1
  }

  # The measured field case: the file existed since 2025 but had just been rewritten, so age is what
  # decides, not presence. A day-old index is what made the window freeze for 130 seconds.
  It 'calls a cache older than the limit stale' {
    Set-Content -LiteralPath $script:cacheFile -Value '{"x":1}'
    (Get-Item -LiteralPath $script:cacheFile).LastWriteTime = [datetime]::Now.AddHours(-30)
    $state = Test-WingetIndexCacheCold -CachePath $script:cacheFile
    $state.Cold | Should -BeTrue
    $state.Reason | Should -Be 'stale'
    $state.AgeHours | Should -BeGreaterThan 29
  }

  It 'honours a custom age limit in both directions' {
    Set-Content -LiteralPath $script:cacheFile -Value '{"x":1}'
    (Get-Item -LiteralPath $script:cacheFile).LastWriteTime = [datetime]::Now.AddHours(-6)
    (Test-WingetIndexCacheCold -CachePath $script:cacheFile -MaxAgeHours 12).Cold | Should -BeFalse
    (Test-WingetIndexCacheCold -CachePath $script:cacheFile -MaxAgeHours 3).Cold  | Should -BeTrue
  }

  It 'reports the path it looked at' {
    (Test-WingetIndexCacheCold -CachePath $script:cacheFile).Path | Should -Be $script:cacheFile
  }
}
