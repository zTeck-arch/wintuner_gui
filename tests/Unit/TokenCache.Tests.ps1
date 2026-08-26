# Regression guard for the logout-hygiene bug (Opus-5 audit finding #2):
# Clear-GraphTokenCache filtered for 'mg.msal.cache*', but the WinTuner session cache is actually
# named 'WinTuner-PowerShell.nocae', so logout left the previous customer's refresh token on disk
# while SECURITY.md promised it was deleted. These tests keep that promise honest.

BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '10-Settings.ps1' -Name 'Remove-TokenCacheFiles')))

  # The patterns the shipped code uses, asserted here so a future edit to them shows up as a diff.
  $global:Patterns = @('WinTuner-PowerShell*', 'msal.cache*', 'mg.msal.cache*')

  function New-CacheDir {
    param([string[]]$Files)
    $dir = Join-Path ([IO.Path]::GetTempPath()) ("tokencache-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    foreach ($f in $Files) { Set-Content -LiteralPath (Join-Path $dir $f) -Value 'x' -NoNewline }
    return $dir
  }
}

Describe 'Remove-TokenCacheFiles' {
  It 'deletes the real WinTuner session cache file' {
    $dir = New-CacheDir -Files @('WinTuner-PowerShell.nocae', 'msal.cache.cae')
    try {
      $n = Remove-TokenCacheFiles -Directory $dir -Patterns $global:Patterns
      $n | Should -Be 2
      Test-Path -LiteralPath (Join-Path $dir 'WinTuner-PowerShell.nocae') | Should -BeFalse
      Test-Path -LiteralPath (Join-Path $dir 'msal.cache.cae')            | Should -BeFalse
    } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
  }

  It 'leaves unrelated files untouched' {
    $dir = New-CacheDir -Files @('WinTuner-PowerShell.nocae', 'other-app.cache')
    try {
      $n = Remove-TokenCacheFiles -Directory $dir -Patterns $global:Patterns
      $n | Should -Be 1
      Test-Path -LiteralPath (Join-Path $dir 'other-app.cache') | Should -BeTrue
    } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
  }

  It 'counts a file that matches two patterns only once' {
    # Both patterns match the same file; it must be deleted and counted exactly once.
    $dir = New-CacheDir -Files @('mg.msal.cache')
    try {
      $n = Remove-TokenCacheFiles -Directory $dir -Patterns @('mg.msal.cache*', 'mg.msal.*')
      $n | Should -Be 1
    } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
  }

  It 'returns 0 for a missing directory without throwing' {
    Remove-TokenCacheFiles -Directory (Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid())) -Patterns $global:Patterns | Should -Be 0
  }
}
