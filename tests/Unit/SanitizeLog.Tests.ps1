# Audit finding #43: there was no safe way to attach a log to a bug report. Get-SanitizedLogText
# replaces UPNs, GUIDs, the Windows user name and the profile path with STABLE placeholders so the
# relationships needed for diagnosis survive while the customer identifiers do not.

BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '70-Runtime.ps1' -Name 'Get-SanitizedLogText')))
}

Describe 'Get-SanitizedLogText' {
  It 'replaces UPNs and keeps them stable' {
    $t = "login admin@kunde.de ... later admin@kunde.de ... other chef@firma.com"
    $s = Get-SanitizedLogText -Text $t -UserName 'someone' -UserProfile 'C:\Users\someone'
    $s | Should -Not -Match 'admin@kunde\.de'
    $s | Should -Not -Match 'chef@firma\.com'
    # same UPN -> same placeholder; two distinct UPNs -> two placeholders
    ($s | Select-String -Pattern 'user-1' -AllMatches).Matches.Count | Should -Be 2
    $s | Should -Match 'user-2'
  }

  It 'replaces GUIDs' {
    $g = '11111111-2222-3333-4444-555555555555'
    $s = Get-SanitizedLogText -Text "app id $g done" -UserName 'x' -UserProfile 'C:\Users\x'
    $s | Should -Not -Match $g
    $s | Should -Match 'id-1'
  }

  It 'replaces the user name and profile path' {
    $s = Get-SanitizedLogText -Text 'path C:\Users\Timo.Schnabel\AppData and user Timo.Schnabel' -UserName 'Timo.Schnabel' -UserProfile 'C:\Users\Timo.Schnabel'
    $s | Should -Not -Match 'Timo\.Schnabel'
    $s | Should -Match 'user-profile'
    $s | Should -Match 'user-name'
  }

  It 'leaves ordinary text untouched' {
    Get-SanitizedLogText -Text 'Deploying Google Chrome 1.2.3' -UserName 'x' -UserProfile 'C:\Users\x' |
      Should -Be 'Deploying Google Chrome 1.2.3'
  }
}
