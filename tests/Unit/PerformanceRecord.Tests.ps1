BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '20-Version.ps1' -Name 'Get-ComparableVersionParts')))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '50-UpdateEngine.ps1' `
    -Name 'Add-SessionActivity', 'Get-SessionLeistungstext', 'Clear-SessionActivityRecord', 'Select-RecentActivity',
    'Get-ActivityTenantDomain')))

  # The record is persisted by the caller; here only the in-memory list matters.
  function global:Save-SessionActivity { }
  $script:logRetentionWeeks = 2
}

Describe 'Performance record' {
  BeforeEach {
    $script:sessionActivity = [System.Collections.Generic.List[object]]::new()
    $script:currentUserUpn = 'admin@kunde.de'
    $script:activityTenantUpn = 'admin@kunde.de'
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
      # The wording now says WHICH mechanism removed them - the version cleanup, not an update.
      Get-SessionLeistungstext -Lang 'de' | Should -Match '3 alte Version\(en\) durch die Versionsbereinigung entfernt'
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
    It 'marks an update whose predecessor was DELETED as deleted, not as superseded' {
      # Regression: OldVersionRemoved means the predecessor was deleted, but the record printed
      # "alte Version abgelöst" (superseded) for it - and then counted it under neither heading. A
      # run that deleted two apps read as if it had only superseded them.
      $text = Get-SessionLeistungstext -Lang 'de'
      $text | Should -Match 'Vorgänger gelöscht'
      $text | Should -Match '1 Vorgänger beim Update gelöscht'
      $text | Should -Match '0 Vorgänger abgelöst und behalten'
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
      $script:currentUserUpn = 'admin@anderer-kunde.de'
      Get-SessionLeistungstext -Lang 'de' | Should -Not -Match 'Fremd-App'
    }

    # Der Kunde ist die DOMAENE, nicht das Konto. Beim Dienstleister liegen die Rechte oft auf einem
    # zweiten Konto desselben Tenants; wer sich damit anmeldet, hat vorher seinen eigenen Nachweis
    # nicht mehr gesehen.
    It 'zeigt den Nachweis auch einem zweiten Konto desselben Kunden' {
      Add-SessionActivity -Kind 'VersionRemoved' -Name 'Eigene-App' -FromVersion '1.0'
      $script:currentUserUpn = 'admin2@kunde.de'
      Get-SessionLeistungstext -Lang 'de' | Should -Match 'Eigene-App'
    }
  }

  # Der Fehler, der drei echte Updates aus dem Nachweis geworfen hat: waehrend des Laufs wurde
  # getrennt, $script:currentUserUpn war danach leer, und alle folgenden Eintraege bekamen einen
  # LEEREN Tenant - beim naechsten Start unter "Letzte Sitzung" nicht mehr auffindbar.
  Context 'Trennen mitten im Lauf' {
    It 'erfasst weiter unter der angemeldeten Adresse, wenn die Sitzung getrennt wurde' {
      $script:activityTenantUpn = 'admin@kunde.de'
      $script:currentUserUpn = ''
      Add-SessionActivity -Kind 'Update' -Name 'Notepad++' -FromVersion '8.9.7' -ToVersion '8.9.8'
      $script:currentUserUpn = 'admin@kunde.de'
      $text = Get-SessionLeistungstext -Lang 'de'
      $text | Should -Match 'Notepad\+\+'
      $text | Should -Not -Match 'ohne Tenant-Zuordnung|keinem Tenant zugeordnet'
    }

    It 'haengt Eintraege ohne Zuordnung getrennt an und sagt, dass sie geprueft werden muessen' {
      # So sehen Aufzeichnungen aus, die VOR der Behebung entstanden sind.
      $script:sessionActivity.Add([pscustomobject]@{
        Kind = 'Update'; Tenant = ''; Name = 'Jabra Direct'; FromVersion = '8.1.14601'
        ToVersion = '8.2.23201'; OldVersionRemoved = $false; SupersedenceCreated = $true
        Detail = ''; Timestamp = (Get-Date '2026-08-26T09:24:04') })
      $text = Get-SessionLeistungstext -Lang 'de'
      $text | Should -Match 'keinem Tenant zugeordnet'
      $text | Should -Match 'Jabra Direct'
      # Und sie duerfen NICHT als Leistung dieses Kunden gelten: der zugeordnete Teil bleibt leer.
      $text | Should -Match 'noch nichts erfasst'
      $text | Should -Not -Match 'Aktualisiert:'
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

    It 'states how many predecessors were actually deleted' {
      Add-SessionActivity -Kind 'Update' -Name 'App' -FromVersion '1.0' -ToVersion '3.0' -OldVersionRemoved $true
      Add-SessionActivity -Kind 'Update' -Name 'App' -FromVersion '2.0' -ToVersion '3.0' -OldVersionRemoved $true
      Get-SessionLeistungstext -Lang 'de' | Should -Match '2 Vorgänger gelöscht'
    }
  }

  Context 'signed out [#15]' {
    # No tenant must NEVER fall back to showing every customer's activity - the text is pasted into
    # a ticket. Show a "please sign in" hint instead.
    It 'does not leak other tenants when signed out' {
      Add-SessionActivity -Kind 'VersionRemoved' -Name 'Kunde-A App' -FromVersion '1.0'
      $script:currentUserUpn = ''
      $text = Get-SessionLeistungstext -Lang 'de'
      $text | Should -Not -Match 'Kunde-A App'
      $text | Should -Match 'anmelden'
    }
  }

  Context 'clearing the record [#16/#36]' {
    It 'empties both in-memory records and deletes the file' {
      $script:activityHistoryPath = Join-Path ([IO.Path]::GetTempPath()) ("wt-hist-" + [guid]::NewGuid().ToString('N') + '.json')
      Set-Content -LiteralPath $script:activityHistoryPath -Value '[{"Name":"x"}]' -Encoding utf8
      Add-SessionActivity -Kind 'Deployed' -Name 'App' -ToVersion '1.0'
      $script:previousSessionActivity = @([pscustomobject]@{ Name = 'Old'; Tenant = 'admin@kunde.de' })

      Clear-SessionActivityRecord

      $script:sessionActivity.Count | Should -Be 0
      $script:previousSessionActivity.Count | Should -Be 0
      Test-Path -LiteralPath $script:activityHistoryPath | Should -BeFalse
    }
  }

  Context 'retention [#35]' {
    It 'drops entries older than the retention window' {
      $now = Get-Date
      $entries = @(
        [pscustomobject]@{ Name='fresh'; Timestamp = $now.AddDays(-3) },
        [pscustomobject]@{ Name='old';   Timestamp = $now.AddDays(-30) }
      )
      $kept = Select-RecentActivity -Entries $entries -RetentionWeeks 2 -Now $now
      @($kept).Name | Should -Contain 'fresh'
      @($kept).Name | Should -Not -Contain 'old'
    }
    It 'keeps an entry whose timestamp cannot be parsed rather than losing data' {
      $kept = Select-RecentActivity -Entries @([pscustomobject]@{ Name='weird'; Timestamp='not-a-date' }) -RetentionWeeks 2
      @($kept).Name | Should -Contain 'weird'
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

Describe 'Performance record: supersede versus delete' {
  # Reported from a real run: two apps were DELETED during the update (one by the consolidation
  # path, one by the guarded cleanup) and one was superseded and kept - and the record said
  # "2 alte Version(en) beim Update abgelöst, 0 alte Version(en) entfernt". Both outcomes had
  # collapsed into a single boolean that was rendered with the word for the wrong one.
  BeforeEach {
    $script:sessionActivity = [System.Collections.Generic.List[object]]::new()
    $script:previousSessionActivity = [System.Collections.Generic.List[object]]::new()
    $script:currentUserUpn = 'admin@kunde.de'
  }

  It 'names a superseded, kept predecessor as such' {
    Add-SessionActivity -Kind 'Update' -Name 'Google Chrome' -FromVersion '150.0.7871.187' `
      -ToVersion '151.0.7922.174' -SupersedenceCreated $true
    $text = Get-SessionLeistungstext -Lang 'de'
    $text | Should -Match 'Vorgänger abgelöst, in Intune behalten'
    $text | Should -Match '1 Vorgänger abgelöst und behalten'
    $text | Should -Match '0 Vorgänger beim Update gelöscht'
  }

  It 'keeps deletion and supersedence apart within one product' {
    # Exactly the reported Chrome case: one predecessor superseded and kept, an older one deleted.
    Add-SessionActivity -Kind 'Update' -Name 'Google Chrome' -FromVersion '150.0.7871.187' `
      -ToVersion '151.0.7922.174' -SupersedenceCreated $true
    Add-SessionActivity -Kind 'Update' -Name 'Google Chrome' -FromVersion '148.0.7778.168' `
      -ToVersion '151.0.7922.174' -OldVersionRemoved $true
    $text = Get-SessionLeistungstext -Lang 'de'
    $text | Should -Match '1 abgelöst und behalten, 1 gelöscht'
    $text | Should -Match '1 Vorgänger abgelöst und behalten'
    $text | Should -Match '1 Vorgänger beim Update gelöscht'
  }

  It 'counts a deletion only once, never as both outcomes' {
    Add-SessionActivity -Kind 'Update' -Name 'Nextcloud' -FromVersion '33.0.7' -ToVersion '34.0.2' `
      -OldVersionRemoved $true -SupersedenceCreated $true
    $text = Get-SessionLeistungstext -Lang 'de'
    # Deleted wins: the object is gone, so calling it "kept in Intune" would be false.
    $text | Should -Match '1 Vorgänger beim Update gelöscht'
    $text | Should -Match '0 Vorgänger abgelöst und behalten'
  }

  It 'reports the assignment hand-over the module performed' {
    Add-SessionActivity -Kind 'Update' -Name 'Google Chrome' -FromVersion '150.0' -ToVersion '151.0' -SupersedenceCreated $true
    Add-SessionActivity -Kind 'AssignmentsChanged' -Name 'Google Chrome' -ToVersion '151.0' `
      -Detail 'Zuweisung an die neue Version übergeben'
    $text = Get-SessionLeistungstext -Lang 'de'
    $text | Should -Match 'Zuweisungen geändert:'
    $text | Should -Match 'Zuweisung an die neue Version übergeben'
    $text | Should -Match '1 Zuweisungsänderung\(en\)'
  }

  It 'says nothing about predecessors when an update touched none' {
    Add-SessionActivity -Kind 'Update' -Name 'Solo' -FromVersion '1.0' -ToVersion '2.0'
    $text = Get-SessionLeistungstext -Lang 'de'
    $text | Should -Not -Match 'gelöscht\)'
    $text | Should -Not -Match 'behalten\)'
    $text | Should -Match '0 Vorgänger abgelöst und behalten, 0 Vorgänger beim Update gelöscht'
  }
}
