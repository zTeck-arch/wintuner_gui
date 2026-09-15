BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  # Get-AssignmentWriteErrorText holt seine Saetze seit 0.18.0 aus der Stringtabelle.
  . ([scriptblock]::Create((Get-UiStringsText)))
  $script:uiLanguage = 'en'
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '45-Assignments.ps1' `
    -Name 'Move-AppAssignments', 'Get-AssignmentWriteErrorText')))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '40-Graph.ps1' -Name 'Get-ErrorHttpStatus')))

  $global:OldId = '11111111-1111-1111-1111-111111111111'
  $global:NewId = '22222222-2222-2222-2222-222222222222'

  function global:Get-WtToken { 'test-token' }
  function global:Add-SessionActivity { param($Kind, $Name, $Detail) }
  function global:Get-UiString { param($Key) $Key }

  # Eine gewoehnliche Gruppenzuweisung, wie Graph sie herausgibt.
  function global:New-GroupAssignment {
    param([string]$GroupId = '33333333-3333-3333-3333-333333333333', [string]$Intent = 'required')
    [pscustomobject]@{
      id     = 'assignment-1'
      intent = $Intent
      source = 'direct'
      target = [pscustomobject]@{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = $GroupId }
    }
  }
  # Die Nutzlast des ERSTEN Schreibvorgangs - mit der Zusicherung, dass es ihn gab.
  #
  # Ohne diese Zeile ist die Pruefung wertlos: blieb der Schreibvorgang aus, liefert
  # ConvertFrom-Json auf $null nur einen nicht abbrechenden Fehler, $body bleibt $null, und
  # @($null.mobileAppAssignments).Count ist 1 - die Zusicherung "genau eine Zuweisung" waere also
  # gruen, obwohl gar nichts gesendet wurde. Genau so ist dieser Test bei der Gegenprobe zuerst
  # durchgerutscht.
  function global:Get-FirstWriteBody {
    $global:WriteBodies.Count | Should -BeGreaterThan 0
    return ($global:WriteBodies[0] | ConvertFrom-Json)
  }

  # Ein Fehler, der GEWORFEN werden kann und seinen Status behaelt.
  #
  # Ein einfaches PSCustomObject genuegt hier nicht: `throw $objekt` verpackt es in eine
  # RuntimeException, und Get-ErrorHttpStatus liest dann Status 0 - der Klartexthinweis fiel weg und
  # das Protokoll bekam nur den rohen Text. Deshalb eine echte ErrorRecord mit einer angehaengten
  # Response-Eigenschaft: genau die Form, in der Get-ErrorHttpStatus den Status sucht
  # ($ex.PSObject.Properties['Response'] -> $ex.Response.StatusCode).
  function global:New-ThrowableHttpError {
    param([int]$Status, [string]$Message = 'request failed')
    $exc = [System.Exception]::new(("{0} (HTTP {1})" -f $Message, $Status))
    $exc | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = $Status }) -Force
    return [System.Management.Automation.ErrorRecord]::new(
      $exc, 'GraphWriteFailed', [System.Management.Automation.ErrorCategory]::NotSpecified, $null)
  }
}

Describe 'Move-AppAssignments: die Uebergabe schreibt ZWEI Mal' {
  BeforeEach {
    # Was der Vorgaenger traegt, und wie die zwei Schreibvorgaenge ausgehen sollen.
    $global:OldAssignments = @(New-GroupAssignment)
    $global:NewAssignments = @()
    $global:WriteCalls = [System.Collections.Generic.List[string]]::new()
    # Was wirklich auf der Leitung lag. Ohne das laesst sich "die Zuweisung steht genau einmal im
    # Paket" nicht pruefen - und genau daran haengt die Uebergabe, seit das Ziel schon die Kopie
    # des Moduls traegt.
    $global:WriteBodies = [System.Collections.Generic.List[string]]::new()
    $global:FailOnWrite = 0    # 1 = der erste Schreibvorgang scheitert, 2 = der zweite
    $global:FailStatus = 429
    $global:TestLog.Clear()

    Set-Item -Path function:global:Get-GraphCollectionItems -Value {
      param($Uri, $Headers, $MaxPages)
      if ($Uri -like ("*" + $global:OldId + "*")) { return $global:OldAssignments }
      return $global:NewAssignments
    }
    # Der Transport als Attrappe: sie notiert, WELCHE App geschrieben wurde, und kann gezielt an
    # einem der beiden Schreibvorgaenge scheitern.
    Set-Item -Path function:global:Invoke-GraphRest -Value {
      param($Uri, $Method = 'GET', $Headers, $Body, $TimeoutSeconds, $MaxRetries, $Context)
      $which = if ($Uri -like ("*" + $global:NewId + "*")) { 'new' } else { 'old' }
      $global:WriteCalls.Add($which)
      $global:WriteBodies.Add([string]$Body)
      if (($global:FailOnWrite -eq 1 -and $which -eq 'new') -or
          ($global:FailOnWrite -eq 2 -and $which -eq 'old')) {
        throw (New-ThrowableHttpError -Status $global:FailStatus -Message 'assignment write rejected')
      }
      return [pscustomobject]@{ }
    }
  }

  Context 'beide Schreibvorgaenge gelingen' {
    It 'schreibt erst die neue, dann die alte App - in dieser Reihenfolge' {
      Move-AppAssignments -OldAppId $global:OldId -NewAppId $global:NewId -AppName 'Chrome' | Should -BeTrue
      @($global:WriteCalls) | Should -Be @('new', 'old')
    }
    It 'protokolliert beide Schritte' {
      $null = Move-AppAssignments -OldAppId $global:OldId -NewAppId $global:NewId -AppName 'Chrome'
      @($global:TestLog | Where-Object { $_ -like '*now has 1 assignment(s)*' }).Count | Should -Be 1
      @($global:TestLog | Where-Object { $_ -like '*removed 1 assignment(s) from superseded app*' }).Count | Should -Be 1
    }
  }

  # Der offene Pruefpunkt 4 aus PRUEFANLEITUNG-OFFENE-PUNKTE.md - dort als "schwierig, kuenstlicher
  # Fehler noetig, nur am Tenant pruefbar" beschrieben. Mit dem Transport als Naht ist es ein
  # Unit-Test: der zweite Schreibvorgang scheitert, die neue Version traegt die Zuweisungen schon.
  Context 'der ZWEITE Schreibvorgang scheitert - der halb angewendete Zustand' {
    BeforeEach { $global:FailOnWrite = 2 }

    It 'meldet PARTIALLY applied und nicht "nichts geaendert"' {
      Move-AppAssignments -OldAppId $global:OldId -NewAppId $global:NewId -AppName 'Chrome' | Should -BeFalse
      @($global:TestLog | Where-Object { $_ -like '*PARTIALLY applied*' }).Count | Should -Be 1
      @($global:TestLog | Where-Object { $_ -like '*did not happen*' }).Count | Should -Be 0
    }
    It 'sagt im Protokoll, dass gerade BEIDE Versionen zugewiesen sind' {
      $null = Move-AppAssignments -OldAppId $global:OldId -NewAppId $global:NewId -AppName 'Chrome'
      @($global:TestLog | Where-Object { $_ -like '*Both versions are assigned right now*' }).Count | Should -Be 1
    }
    # Der offene Pruefpunkt 3 derselben Anleitung, halb erledigt: dass der KLARTEXT erscheint und
    # nicht nur die rohe Graph-Meldung, laesst sich hier pruefen. Was ein echter Tenant noch zeigen
    # muss, ist die Form, in der Graph seinen 403 wirklich schickt.
    It 'nennt die Drosselung im Klartext, statt nur den rohen Fehler durchzureichen' {
      $null = Move-AppAssignments -OldAppId $global:OldId -NewAppId $global:NewId -AppName 'Chrome'
      @($global:TestLog | Where-Object { $_ -like '*throttling the request (HTTP 429)*' }).Count | Should -Be 1
    }
    It 'nennt bei fehlender Schreibrolle, dass ein zweiter Versuch nicht hilft' {
      $global:FailStatus = 403
      $null = Move-AppAssignments -OldAppId $global:OldId -NewAppId $global:NewId -AppName 'Chrome'
      @($global:TestLog | Where-Object { $_ -like '*no permission to change assignments (HTTP 403)*' }).Count | Should -Be 1
      @($global:TestLog | Where-Object { $_ -like '*retrying will not help*' }).Count | Should -Be 1
    }
    It 'reicht die rohe Graph-Meldung zusaetzlich weiter, nicht statt des Hinweises' {
      $null = Move-AppAssignments -OldAppId $global:OldId -NewAppId $global:NewId -AppName 'Chrome'
      @($global:TestLog | Where-Object { $_ -like '*assignment write rejected*' }).Count | Should -Be 1
    }
  }

  Context 'der ERSTE Schreibvorgang scheitert - nichts wurde geaendert' {
    BeforeEach { $global:FailOnWrite = 1 }

    It 'meldet "nichts geaendert" und NICHT PARTIALLY applied' {
      Move-AppAssignments -OldAppId $global:OldId -NewAppId $global:NewId -AppName 'Chrome' | Should -BeFalse
      @($global:TestLog | Where-Object { $_ -like '*did not happen*' }).Count | Should -Be 1
      @($global:TestLog | Where-Object { $_ -like '*PARTIALLY applied*' }).Count | Should -Be 0
    }
    It 'ruehrt die alte App gar nicht an' {
      $null = Move-AppAssignments -OldAppId $global:OldId -NewAppId $global:NewId -AppName 'Chrome'
      @($global:WriteCalls) | Should -Be @('new')
    }
  }

  Context 'nichts zu uebertragen' {
    It 'meldet Erfolg, ohne zu schreiben' {
      $global:OldAssignments = @()
      Move-AppAssignments -OldAppId $global:OldId -NewAppId $global:NewId -AppName 'Chrome' | Should -BeTrue
      $global:WriteCalls.Count | Should -Be 0
    }
  }

  # Diese Zuweisungen gehoeren einem Policy Set oder werden geerbt: sie muessen an ihrer QUELLE
  # geaendert werden, ein Ueberschreiben hier wuerde die Policy stillschweigend verwerfen.
  Context 'geerbte oder Policy-Set-Zuweisungen' {
    It 'bricht ab, ohne zu schreiben' {
      $inherited = New-GroupAssignment
      $inherited.source = 'policySets'
      $global:OldAssignments = @($inherited)
      Move-AppAssignments -OldAppId $global:OldId -NewAppId $global:NewId -AppName 'Chrome' | Should -BeFalse
      $global:WriteCalls.Count | Should -Be 0
      @($global:TestLog | Where-Object { $_ -like '*policy-set/inherited*' }).Count | Should -Be 1
    }
  }

  # Der Befund aus dem Betrieb (gemeldet zu 0.20.0): "die alten Zuweisungen werden geloescht, aber
  # nicht bei der neuen Version hinterlegt". Die Uebergabe lag bis dahin bei Deploy-WtWin32App, das
  # Kopieren und Leeren in EINER Graph-Sammelanfrage erledigt, ohne dependsOn und ohne die Antwort
  # anzusehen - ein gescheitertes Kopieren neben einem geglueckten Leeren faellt dort niemandem auf.
  # Seit 0.20.1 laeuft die Abloese mit -KeepAssignments und der Umzug passiert hier. Damit trifft
  # die Uebergabe auf der neuen App auf die Kopie, die das Modul trotzdem angelegt hat - inklusive
  # der Einstellungen, die es einer Available-Zuweisung ohne Einstellungen anhaengt.
  Context 'das Ziel traegt schon die Kopie des Moduls' {
    BeforeEach {
      $global:OldAssignments = @(New-GroupAssignment -Intent 'available')
      $copy = New-GroupAssignment -Intent 'available'
      $copy | Add-Member -NotePropertyName settings -NotePropertyValue ([pscustomobject]@{
        '@odata.type' = '#microsoft.graph.win32LobAppAssignmentSettings'
        notifications = 'showReboot'
      }) -Force
      $global:NewAssignments = @($copy)
    }

    It 'bricht ohne den Schalter ab - beim Zusammenfuehren zweier echter Quellen ist das richtig' {
      Move-AppAssignments -OldAppId $global:OldId -NewAppId $global:NewId -AppName 'Chrome' | Should -BeFalse
      $global:WriteCalls.Count | Should -Be 0
    }

    It 'fuehrt die Uebergabe mit -SourceIsAuthoritative zu Ende' {
      Move-AppAssignments -OldAppId $global:OldId -NewAppId $global:NewId -AppName 'Chrome' -SourceIsAuthoritative |
        Should -BeTrue
      @($global:WriteCalls) | Should -Be @('new', 'old')
    }

    It 'schickt die Zuweisung genau einmal, nicht als Quelle UND als Kopie' {
      $null = Move-AppAssignments -OldAppId $global:OldId -NewAppId $global:NewId -AppName 'Chrome' -SourceIsAuthoritative
      $body = Get-FirstWriteBody
      @($body.mobileAppAssignments).Count | Should -Be 1
    }

    It 'behaelt die Einstellungen des Moduls, wenn die Quelle keine hat' {
      $null = Move-AppAssignments -OldAppId $global:OldId -NewAppId $global:NewId -AppName 'Chrome' -SourceIsAuthoritative
      $body = Get-FirstWriteBody
      @($body.mobileAppAssignments)[0].settings.notifications | Should -Be 'showReboot'
    }

    It 'laesst die QUELLE gewinnen, wenn beide Seiten Einstellungen tragen' {
      $src = New-GroupAssignment -Intent 'available'
      $src | Add-Member -NotePropertyName settings -NotePropertyValue ([pscustomobject]@{
        '@odata.type' = '#microsoft.graph.win32LobAppAssignmentSettings'
        notifications = 'hideAll'
      }) -Force
      $global:OldAssignments = @($src)
      $null = Move-AppAssignments -OldAppId $global:OldId -NewAppId $global:NewId -AppName 'Chrome' -SourceIsAuthoritative
      $body = Get-FirstWriteBody
      @($body.mobileAppAssignments)[0].settings.notifications | Should -Be 'hideAll'
    }
  }

  # "Erfolg" heisst bei dieser Funktion auch "es gab nichts zu tun". Der Leistungsnachweis braucht
  # den Unterschied: bis 0.20.0 nannte er die Uebergabe genau dann, wenn sie gescheitert war.
  Context 'der Ausgabebeutel trennt "geschrieben" von "nichts zu tun"' {
    It 'meldet Wrote, wenn wirklich geschrieben wurde' {
      $bag = @{}
      $null = Move-AppAssignments -OldAppId $global:OldId -NewAppId $global:NewId -AppName 'Chrome' -Outcome $bag
      $bag['Wrote'] | Should -BeTrue
      $bag['SourceCount'] | Should -Be 1
    }
    It 'meldet KEIN Wrote, wenn die Quelle schon leer war' {
      $global:OldAssignments = @()
      $bag = @{}
      Move-AppAssignments -OldAppId $global:OldId -NewAppId $global:NewId -AppName 'Chrome' -Outcome $bag | Should -BeTrue
      $bag['Wrote'] | Should -BeFalse
      $bag['SourceCount'] | Should -Be 0
    }
    It 'meldet KEIN Wrote, wenn der erste Schreibvorgang scheitert' {
      $global:FailOnWrite = 1
      $bag = @{}
      $null = Move-AppAssignments -OldAppId $global:OldId -NewAppId $global:NewId -AppName 'Chrome' -Outcome $bag
      $bag['Wrote'] | Should -BeFalse
    }
  }

  Context 'unbrauchbare App-Ids' {
    It 'schreibt nichts, wenn eine Id keine GUID ist' {
      Move-AppAssignments -OldAppId 'nicht-eine-guid' -NewAppId $global:NewId | Should -BeFalse
      $global:WriteCalls.Count | Should -Be 0
    }
    It 'schreibt nichts, wenn alte und neue App dieselbe sind' {
      Move-AppAssignments -OldAppId $global:OldId -NewAppId $global:OldId | Should -BeFalse
      $global:WriteCalls.Count | Should -Be 0
    }
  }
}
