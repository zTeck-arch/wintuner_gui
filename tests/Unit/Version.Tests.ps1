BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '20-Version.ps1' `
    -Name 'Get-ComparableVersionParts', 'Test-IsNewerVersion', 'Test-VersionsEquivalent')))
}

Describe 'Test-IsNewerVersion' {
  Context 'plain numeric versions' {
    It 'recognises a higher component' {
      Test-IsNewerVersion -Latest '2.0.0' -Current '1.9.9' | Should -BeTrue
      Test-IsNewerVersion -Latest '1.10.0' -Current '1.9.0' | Should -BeTrue
    }
    It 'does not report an older version as newer' {
      Test-IsNewerVersion -Latest '1.0.0' -Current '2.0.0' | Should -BeFalse
    }
    It 'does not report an identical version as newer' {
      Test-IsNewerVersion -Latest '1.2.3' -Current '1.2.3' | Should -BeFalse
    }
    It 'compares component-wise, not as text' {
      # "10" sorts before "9" as a string
      Test-IsNewerVersion -Latest '1.10' -Current '1.9' | Should -BeTrue
    }
    It 'handles the four-part versions Intune apps use' {
      Test-IsNewerVersion -Latest '151.0.7922.138' -Current '151.0.7922.109' | Should -BeTrue
      Test-IsNewerVersion -Latest '26.001.21789' -Current '26.001.21771' | Should -BeTrue
    }
  }

  Context 'trailing zeros - the two comparisons must not contradict each other' {
    # Regression: Test-IsNewerVersion used [version] first, where a missing component counts as -1,
    # making [version]'1.2.0' greater than [version]'1.2'. Test-VersionsEquivalent pads with 0 and
    # calls the same pair equal. Both are used side by side in the scan and in the self-update, so
    # an app could be offered an "update" to the version it already had.
    It 'does not consider 1.2.0 newer than 1.2' {
      Test-IsNewerVersion -Latest '1.2.0' -Current '1.2' | Should -BeFalse
    }
    It 'does not consider 1.2 newer than 1.2.0' {
      Test-IsNewerVersion -Latest '1.2' -Current '1.2.0' | Should -BeFalse
    }
    It 'agrees with Test-VersionsEquivalent on every padded pair' {
      foreach ($pair in @(@('1.2', '1.2.0'), @('1.2.0.0', '1.2'), @('3', '3.0.0'), @('7.1.0', '7.1'))) {
        $equivalent = Test-VersionsEquivalent -Left $pair[0] -Right $pair[1]
        $forwards = Test-IsNewerVersion -Latest $pair[0] -Current $pair[1]
        $backwards = Test-IsNewerVersion -Latest $pair[1] -Current $pair[0]
        # Equivalent means neither direction may be "newer".
        ($equivalent -and ($forwards -or $backwards)) | Should -BeFalse -Because "$($pair[0]) / $($pair[1]) must not be equal AND newer at the same time"
      }
    }
  }

  Context 'pre-release suffixes' {
    It 'treats a stable release as newer than its pre-release' {
      Test-IsNewerVersion -Latest '2.0.0' -Current '2.0.0-beta' | Should -BeTrue
    }
    It 'never treats a pre-release as newer than the stable release' {
      Test-IsNewerVersion -Latest '2.0.0-beta' -Current '2.0.0' | Should -BeFalse
    }
  }

  Context 'vendor build numbers' {
    It 'compares the number in a suffix once the dotted core matches' {
      Test-IsNewerVersion -Latest '7.1.5 (43453)' -Current '7.1.5 (41345)' | Should -BeTrue
      Test-IsNewerVersion -Latest '7.1.5 (41345)' -Current '7.1.5 (43453)' | Should -BeFalse
    }
  }

  Context 'unusable input' {
    It 'returns false instead of guessing' {
      Test-IsNewerVersion -Latest '' -Current '1.0' | Should -BeFalse
      Test-IsNewerVersion -Latest '1.0' -Current '' | Should -BeFalse
      Test-IsNewerVersion -Latest 'not-a-version' -Current '1.0' | Should -BeFalse
    }
  }
}

Describe 'Test-VersionsEquivalent' {
  It 'treats padded versions as the same' {
    Test-VersionsEquivalent -Left '1.2' -Right '1.2.0' | Should -BeTrue
    Test-VersionsEquivalent -Left '26.001.21789' -Right '26.1.21789' | Should -BeTrue
  }
  It 'keeps different versions apart' {
    Test-VersionsEquivalent -Left '1.2.1' -Right '1.2.0' | Should -BeFalse
  }
  It 'keeps a pre-release apart from its stable release' {
    Test-VersionsEquivalent -Left '2.0.0-rc1' -Right '2.0.0' | Should -BeFalse
  }
  It 'rejects empty input rather than calling it a match' {
    Test-VersionsEquivalent -Left '' -Right '' | Should -BeFalse
  }
}

Describe 'Get-ComparableVersionParts' {
  It 'splits the dotted core into numbers' {
    (Get-ComparableVersionParts '1.2.3').Core | Should -Be @(1, 2, 3)
  }
  It 'accepts a leading v' {
    (Get-ComparableVersionParts 'v0.15.4').Core | Should -Be @(0, 15, 4)
  }
  It 'keeps leading zeros numerically' {
    (Get-ComparableVersionParts '26.001.21789').Core | Should -Be @(26, 1, 21789)
  }
  It 'flags pre-releases' {
    (Get-ComparableVersionParts '1.0.0-beta2').IsPrerelease | Should -BeTrue
    (Get-ComparableVersionParts '1.0.0').IsPrerelease | Should -BeFalse
  }
  It 'returns nothing for input that is not a version' {
    Get-ComparableVersionParts 'abc' | Should -BeNullOrEmpty
    Get-ComparableVersionParts '' | Should -BeNullOrEmpty
  }
}
