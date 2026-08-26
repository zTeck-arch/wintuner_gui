# Audit findings #4 and #5.
#  #4: Find-ExistingUpdateTarget / Find-NewerTenantPackageTarget must accept an empty -Apps array,
#      or the very first upload into a brand-new tenant fails at parameter binding.
#  #5: Get-StringSimilarity used [math]::Min as the denominator, so a name that is a SUBSET of
#      another scored 100 - a shorter, wrong candidate could be auto-resolved as the WinGet package.

BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '30-UpdateTargets.ps1' `
    -Name 'Find-ExistingUpdateTarget', 'Find-NewerTenantPackageTarget', 'Get-StringSimilarity')))
}

Describe 'Find-ExistingUpdateTarget / Find-NewerTenantPackageTarget accept an empty inventory' {
  It 'Find-ExistingUpdateTarget binds @() and returns null' {
    { Find-ExistingUpdateTarget -Apps @() -PackageId 'Foo.Bar' -Version '1.0.0' } | Should -Not -Throw
    (Find-ExistingUpdateTarget -Apps @() -PackageId 'Foo.Bar' -Version '1.0.0') | Should -BeNullOrEmpty
  }
  It 'Find-NewerTenantPackageTarget binds @() and returns null' {
    { Find-NewerTenantPackageTarget -Apps @() -PackageId 'Foo.Bar' -Version '1.0.0' } | Should -Not -Throw
    (Find-NewerTenantPackageTarget -Apps @() -PackageId 'Foo.Bar' -Version '1.0.0') | Should -BeNullOrEmpty
  }
}

Describe 'Get-StringSimilarity (Jaccard)' {
  It 'scores identical names 100' {
    Get-StringSimilarity 'Google Chrome' 'Google Chrome' | Should -Be 100
  }
  It 'scores fully disjoint names 0' {
    Get-StringSimilarity 'Firefox' 'Chrome' | Should -Be 0
  }
  It 'no longer scores a subset name 100' {
    # Was 100 under the old Min denominator; must now be well below.
    Get-StringSimilarity 'Adobe Acrobat' 'Adobe Acrobat Reader DC' | Should -BeLessThan 100
    Get-StringSimilarity 'Notepad' 'Notepad Plus Plus' | Should -BeLessThan 100
  }
  It 'is symmetric' {
    (Get-StringSimilarity 'Adobe Acrobat' 'Adobe Acrobat Reader DC') |
      Should -Be (Get-StringSimilarity 'Adobe Acrobat Reader DC' 'Adobe Acrobat')
  }
  It 'returns 0 for empty input' {
    Get-StringSimilarity '' 'Chrome' | Should -Be 0
    Get-StringSimilarity 'Chrome' $null | Should -Be 0
  }
}

Describe 'Auto-resolve decision rule (score >= 80 AND >= 15 ahead of runner-up)' {
  # Mirrors src/25-WinGetData.ps1: the rule that decides whether a name match is used unattended.
  # Global so It blocks can see it (functions declared in a Describe body cannot).
  BeforeAll {
    function global:Test-AutoResolve {
      param([string]$AppName, [string[]]$Candidates)
      $scored = @($Candidates | ForEach-Object { [int](Get-StringSimilarity $AppName $_) } | Sort-Object -Descending)
      $runnerUp = if ($scored.Count -gt 1) { $scored[1] } else { 0 }
      return ($scored[0] -ge 80 -and ($scored[0] - $runnerUp) -ge 15)
    }
  }

  It 'does NOT auto-resolve the ambiguous Adobe case (regression)' {
    Test-AutoResolve 'Adobe Acrobat Reader DC' @('Adobe Acrobat', 'Adobe Acrobat Reader (64-bit)', 'Adobe Creative Cloud') |
      Should -BeFalse
  }
  It 'still auto-resolves a clearly dominant match' {
    Test-AutoResolve 'Mozilla Firefox' @('Mozilla Firefox', 'Mozilla Thunderbird') | Should -BeTrue
  }
}
