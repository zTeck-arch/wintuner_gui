BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '20-Version.ps1' -Name 'Get-ComparableVersionParts')))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '50-UpdateEngine.ps1' `
    -Name 'Add-SessionActivity', 'Get-SessionLeistungstext')))

  # The record is persisted by the caller; here only the in-memory list matters.
  function global:Save-SessionActivity { }
}

Describe 'Performance record' {
  BeforeEach {
    $script:sessionActivity = [System.Collections.Generic.List[object]]::new()
    $script:currentUserUpn = 'admin@kunde.de'
    $script:leistungLang = 'de'
    $script:leistungShowPrevious = $false
  }

  Context 'a session that only cleaned up' {
    # This is what prompted the change: a run that deleted eight old versions reported
    # "no apps updated yet", because only updates were ever recorded.
    BeforeEach {
      Add-SessionActivity -Kind 'VersionRemoved' -Name 'Adobe Acrobat Reader (64-bit)' -FromVersion '26.001.21529'
      Add-SessionActivity -Kind 'VersionRemoved' -Name 'Airtame' -FromVersion '4.14.0'
      Add-SessionActivity -Kind 'VersionRemoved' -Name 'Zoom Workplace' -FromVersion '7.0.34412'
    }

    It 'does not claim that nothing happened' {
      Get-SessionLeistungstext -Lang 'de' | Should -Not -Match 'noch nichts erfasst'
    }
    It 'lists the removed versions under their own heading' {
      $text = Get-SessionLeistungstext -Lang 'de'
      $text | Should -Match 'Alte Versionen entfernt:'
      $text | Should -Match '26\.001\.21529'
      $text | Should -Match '4\.14\.0'
      $text | Should -Match '7\.0\.34412'
    }
    It 'counts them in the summary' {
      Get-SessionLeistungstext -Lang 'de' | Should -Match '3 alte Version\(en\) entfernt'
    }
    It 'does not print an empty update section' {
      Get-SessionLeistungstext -Lang 'de' | Should -Not -Match 'Aktualisiert:'
    }
  }

  Context 'a mixed session' {
    BeforeEach {
      Add-SessionActivity -Kind 'Update' -Name 'Google Chrome' -FromVersion '151.0.7922.109' -ToVersion '151.0.7922.138' -OldVersionRemoved $true
      Add-SessionActivity -Kind 'Deployed' -Name 'Notepad++' -ToVersion '8.9.7'
      Add-SessionActivity -Kind 'SupersededRemoved' -Name 'Webex' -FromVersion '46.7.0.35472'
      Add-SessionActivity -Kind 'AssignmentsChanged' -Name 'Microsoft Teams' -Detail 'Required -> Alle Geraete'
    }

    It 'prints every section that happened' {
      $text = Get-SessionLeistungstext -Lang 'de'
      $text | Should -Match 'Aktualisiert:'
      $text | Should -Match 'Neu bereitgestellt:'
      $text | Should -Match 'gelöscht:'
      $text | Should -Match 'Zuweisungen geändert:'
    }
    It 'marks an update whose predecessor was superseded' {
      Get-SessionLeistungstext -Lang 'de' | Should -Match 'alte Version abgelöst'
    }
    It 'keeps the free-text detail of an assignment change' {
      Get-SessionLeistungstext -Lang 'de' | Should -Match 'Required -> Alle Geraete'
    }
  }

  Context 'entries written by older versions' {
    It 'reads an entry without a Kind as an update' {
      $script:sessionActivity.Add([pscustomobject]@{
        Tenant = 'admin@kunde.de'; Name = 'Legacy App'; FromVersion = '1.0'; ToVersion = '2.0'
        OldVersionRemoved = $true; Timestamp = (Get-Date)
      })
      $text = Get-SessionLeistungstext -Lang 'de'
      $text | Should -Match 'Aktualisiert:'
      $text | Should -Match 'Legacy App: 1\.0 -> 2\.0'
    }
  }

  Context 'tenant separation' {
    # A record for customer A must never appear while customer B is signed in.
    It 'hides entries recorded for a different tenant' {
      Add-SessionActivity -Kind 'VersionRemoved' -Name 'Fremd-App' -FromVersion '1.0'
      $script:currentUserUpn = 'anderer@kunde.de'
      Get-SessionLeistungstext -Lang 'de' | Should -Not -Match 'Fremd-App'
    }
  }

  Context 'nothing recorded' {
    It 'says so plainly' {
      Get-SessionLeistungstext -Lang 'de' | Should -Match 'noch nichts erfasst'
    }
  }

  Context 'language' {
    It 'uses the English headings when asked' {
      Add-SessionActivity -Kind 'VersionRemoved' -Name 'Airtame' -FromVersion '4.14.0'
      Get-SessionLeistungstext -Lang 'en' | Should -Match 'Old versions removed:'
    }
  }

  Context 'several old versions updated to the same new one' {
    # This is one update with two predecessors, not two updates. Printed line by line it read as if
    # the app had been updated twice - a customer reading the record could not tell the difference
    # between "two old versions were replaced" and "we did this job twice".
    It 'writes one line per app and target version' {
      Add-SessionActivity -Kind 'Update' -Name 'Google Chrome' -FromVersion '151.0.7922.109' -ToVersion '151.0.7922.138'
      Add-SessionActivity -Kind 'Update' -Name 'Google Chrome' -FromVersion '151.0.7922.72'  -ToVersion '151.0.7922.138'
      $text = Get-SessionLeistungstext -Lang 'de'
      @($text -split "`r`n" | Where-Object { $_ -like '- Google Chrome*' }).Count | Should -Be 1
    }

    It 'lists the predecessors oldest first' {
      Add-SessionActivity -Kind 'Update' -Name 'Google Chrome' -FromVersion '151.0.7922.109' -ToVersion '151.0.7922.138'
      Add-SessionActivity -Kind 'Update' -Name 'Google Chrome' -FromVersion '151.0.7922.72'  -ToVersion '151.0.7922.138'
      Get-SessionLeistungstext -Lang 'de' | Should -Match '151\.0\.7922\.72, 151\.0\.7922\.109 -> 151\.0\.7922\.138'
    }

    # Numeric ordering, not lexical: as text "72" sorts after "109", which would print the newer
    # predecessor first and make the line read backwards.
    It 'orders the predecessors numerically' {
      Add-SessionActivity -Kind 'Update' -Name 'App' -FromVersion '1.0.10' -ToVersion '2.0'
      Add-SessionActivity -Kind 'Update' -Name 'App' -FromVersion '1.0.9'  -ToVersion '2.0'
      Get-SessionLeistungstext -Lang 'de' | Should -Match '1\.0\.9, 1\.0\.10 -> 2\.0'
    }

    It 'counts the grouped update once in the summary' {
      Add-SessionActivity -Kind 'Update' -Name 'Google Chrome' -FromVersion '151.0.7922.109' -ToVersion '151.0.7922.138'
      Add-SessionActivity -Kind 'Update' -Name 'Google Chrome' -FromVersion '151.0.7922.72'  -ToVersion '151.0.7922.138'
      Get-SessionLeistungstext -Lang 'de' | Should -Match 'Zusammenfassung: 1 App\(s\) aktualisiert'
    }

    It 'keeps different target versions apart' {
      Add-SessionActivity -Kind 'Update' -Name 'App' -FromVersion '1.0' -ToVersion '2.0'
      Add-SessionActivity -Kind 'Update' -Name 'App' -FromVersion '2.0' -ToVersion '3.0'
      $text = Get-SessionLeistungstext -Lang 'de'
      @($text -split "`r`n" | Where-Object { $_ -like '- App*' }).Count | Should -Be 2
    }

    It 'states how many predecessors were actually superseded' {
      Add-SessionActivity -Kind 'Update' -Name 'App' -FromVersion '1.0' -ToVersion '3.0' -OldVersionRemoved $true
      Add-SessionActivity -Kind 'Update' -Name 'App' -FromVersion '2.0' -ToVersion '3.0' -OldVersionRemoved $true
      Get-SessionLeistungstext -Lang 'de' | Should -Match '2 alte Versionen abgelöst'
    }
  }

  Context 'the recorder itself' {
    # Regression: an EMPTY List is falsy in PowerShell, so a "-not $list" guard was true for every
    # fresh session and would have dropped every entry - always.
    It 'records the very first entry of a session' {
      Add-SessionActivity -Kind 'VersionRemoved' -Name 'Erste App' -FromVersion '1.0'
      $script:sessionActivity.Count | Should -Be 1
    }
    It 'stamps the entry with the current tenant' {
      Add-SessionActivity -Kind 'Deployed' -Name 'App' -ToVersion '1.0'
      $script:sessionActivity[0].Tenant | Should -Be 'admin@kunde.de'
    }
  }
}
