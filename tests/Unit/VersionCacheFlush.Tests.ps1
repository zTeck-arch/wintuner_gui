BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '25-WinGetData.ps1' -Name 'Save-PendingVersionDiskCache')))

  # Der Schreibvorgang selbst wird abgefangen: geprueft wird die Regel "einmal je Schleife statt
  # einmal je Paket", nicht das Serialisieren. Global, damit die dot-gesourcte Funktion sie findet.
  $global:TestCacheWrites = [System.Collections.Generic.List[int]]::new()
  Set-Item -Path function:global:Save-VersionDiskCache -Value {
    param([hashtable]$Cache)
    $global:TestCacheWrites.Add(@($Cache.Keys).Count)
  }
}

Describe 'Save-PendingVersionDiskCache' {
  BeforeEach {
    $global:TestCacheWrites.Clear()
    $script:diskCache = @{ 'google.chrome' = @{ versions = @('1.0'); timestamp = [datetime]::UtcNow } }
    $script:diskCacheDirty = $false
  }

  It 'schreibt nichts, wenn sich nichts geaendert hat' {
    Save-PendingVersionDiskCache | Should -BeFalse
    $global:TestCacheWrites.Count | Should -Be 0
  }

  It 'schreibt einmal, wenn etwas dazugekommen ist' {
    $script:diskCacheDirty = $true
    Save-PendingVersionDiskCache | Should -BeTrue
    $global:TestCacheWrites.Count | Should -Be 1
  }

  # Der eigentliche Punkt der Aenderung vom 31.08.2026. Vorher stand der Schreibvorgang IN
  # Get-WingetVersions: eine Suche ueber 100 Apps schrieb 100 Mal die ganze Tabelle. Jetzt darf ein
  # zweiter Aufruf ohne neue Daten nichts mehr tun.
  It 'schreibt beim zweiten Aufruf ohne neue Daten nicht erneut' {
    $script:diskCacheDirty = $true
    $null = Save-PendingVersionDiskCache
    $null = Save-PendingVersionDiskCache
    $global:TestCacheWrites.Count | Should -Be 1
  }

  It 'schreibt wieder, sobald erneut etwas dazukommt' {
    $script:diskCacheDirty = $true
    $null = Save-PendingVersionDiskCache
    $script:diskCache['mozilla.firefox'] = @{ versions = @('2.0'); timestamp = [datetime]::UtcNow }
    $script:diskCacheDirty = $true
    $null = Save-PendingVersionDiskCache
    $global:TestCacheWrites.Count | Should -Be 2
    # Und mit dem vollstaendigen Inhalt, nicht nur mit dem Zuwachs.
    $global:TestCacheWrites[1] | Should -Be 2
  }

  It 'raeumt den Merker auf, damit das Beenden nicht noch einmal schreibt' {
    $script:diskCacheDirty = $true
    $null = Save-PendingVersionDiskCache
    $script:diskCacheDirty | Should -BeFalse
  }
}
