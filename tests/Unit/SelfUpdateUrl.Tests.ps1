BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '20-Version.ps1' -Name 'Test-SelfUpdateUrlAcceptable')))
}

Describe 'Test-SelfUpdateUrlAcceptable' {
  # Regression: the self-update took both URLs - the script and its checksum - verbatim from the
  # GitHub API answer and handed them to Invoke-WebRequest without looking at them. Nothing forced
  # https, so a downgraded or local URL in that answer would have been fetched and used to replace
  # the running script, and the log never recorded which host it came from.
  #
  # This is explicitly NOT a defence against a hostile GitHub release: if the API answer cannot be
  # trusted, neither can any URL inside it. It rules out an unencrypted transport and a local path
  # dressed up as a download.

  It 'accepts the normal GitHub release asset host' {
    $out = Test-SelfUpdateUrlAcceptable -Url 'https://objects.githubusercontent.com/github-production-release-asset/1/WinTuner_GUI_ntg.ps1'
    $out.Acceptable | Should -BeTrue
    $out.UrlHost | Should -Be 'objects.githubusercontent.com'
  }

  It 'accepts github.com itself' {
    (Test-SelfUpdateUrlAcceptable -Url 'https://github.com/owner/repo/releases/download/v1.0.0/x.ps1').Acceptable |
      Should -BeTrue
  }

  It 'accepts a subdomain of an allowed host, because GitHub changes those over time' {
    (Test-SelfUpdateUrlAcceptable -Url 'https://release-assets.githubusercontent.com/x/y.ps1').Acceptable |
      Should -BeTrue
  }

  It 'refuses plain http' {
    $out = Test-SelfUpdateUrlAcceptable -Url 'http://github.com/owner/repo/releases/download/v1/x.ps1'
    $out.Acceptable | Should -BeFalse
    $out.Reason | Should -Match "scheme 'http' is not https"
  }

  It 'refuses a local file path dressed up as a download' {
    $out = Test-SelfUpdateUrlAcceptable -Url 'file:///C:/temp/evil.ps1'
    $out.Acceptable | Should -BeFalse
    $out.Reason | Should -Match 'not https'
  }

  It 'refuses a UNC path' {
    (Test-SelfUpdateUrlAcceptable -Url '\\fileserver\share\evil.ps1').Acceptable | Should -BeFalse
  }

  It 'refuses an unrelated https host' {
    $out = Test-SelfUpdateUrlAcceptable -Url 'https://example.invalid/WinTuner_GUI_ntg.ps1'
    $out.Acceptable | Should -BeFalse
    $out.Reason | Should -Match 'not a known GitHub download host'
  }

  It 'refuses a host that merely ends with the allowed name' {
    # 'notgithub.com' must not pass because it ends in 'github.com' as a substring; only a real
    # subdomain (a leading dot) counts.
    (Test-SelfUpdateUrlAcceptable -Url 'https://notgithub.com/x.ps1').Acceptable | Should -BeFalse
  }

  It 'refuses an empty or relative URL' {
    (Test-SelfUpdateUrlAcceptable -Url '').Acceptable | Should -BeFalse
    (Test-SelfUpdateUrlAcceptable -Url $null).Acceptable | Should -BeFalse
    (Test-SelfUpdateUrlAcceptable -Url '/releases/download/x.ps1').Acceptable | Should -BeFalse
  }

  It 'reports the host even when it rejects, so the log can name it' {
    (Test-SelfUpdateUrlAcceptable -Url 'https://example.invalid/x.ps1').UrlHost | Should -Be 'example.invalid'
  }
}
