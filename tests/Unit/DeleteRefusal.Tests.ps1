# Intune verweigert das Loeschen einer App, die Vorgaenger einer anderen ist - und das dauerhaft.
#
# Aus dem Betriebsprotokoll vom 03.09.2026: drei Apps (Chrome, Firefox, Zoom) scheiterten in DREI
# aufeinander folgenden Aufraeumlaeufen mit derselben Absage
#   "Cannot delete this app as it is the parent of another app: 774cc400-..."
# Je App und Durchlauf kostete das 5 bis 7 Sekunden Standbild, zwei wirkungslose Schreibvorgaenge in
# den Tenant und ein Dutzend Protokollzeilen - bei unveraenderter Aussicht auf Erfolg: keine.
#
# Diese Faelle halten die drei Entscheidungen fest, die daraus folgen: WAS als endgueltig gilt, dass
# eine endgueltige Absage nicht wiederholt wird, und dass die Liste beim Tenantwechsel leer ist.

BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-UiStringsText)))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '40-Graph.ps1' -Name @(
    'Get-GraphErrorBody', 'Get-GraphErrorText'))))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '45-Assignments.ps1' -Name @(
    'Test-IsStructuralDeleteRefusal', 'Clear-DeleteBlockedAppCache', 'Remove-AppWithUnlinkFallback'))))

  # Den Merkzettel aus der QUELLE holen, nicht hier nachbauen: eine Kopie liefe auseinander, und
  # dann prueften diese Faelle eine Liste, die niemand benutzt.
  $ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Get-SourcePartPath -Part '45-Assignments.ps1'), [ref]$null, [ref]$null)
  $assign = $ast.Find({
    param($n)
    $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $n.Left.Extent.Text -eq '$script:deleteBlockedApps'
  }, $true)
  if (-not $assign) { throw '$script:deleteBlockedApps nicht gefunden - umbenannt?' }
  . ([scriptblock]::Create($assign.Extent.Text))

  # Die Umgebung von Remove-AppWithUnlinkFallback als Attrappen. Jede zaehlt mit, damit ein Fall
  # belegen kann, dass NICHTS versucht wurde.
  $global:DeleteAttempts = [System.Collections.Generic.List[string]]::new()
  $global:UnlinkAttempts = [System.Collections.Generic.List[string]]::new()
  $global:Recorded = [System.Collections.Generic.List[string]]::new()
  Set-Item -Path function:global:Save-AppScopeSnapshot -Value { param($AppId, $AppName, $Version, $Reason) $null }
  Set-Item -Path function:global:Add-SessionActivity -Value { param($Kind, $Name, $FromVersion, $ToVersion, $Detail) $global:Recorded.Add([string]$Kind) }
  Set-Item -Path function:global:Test-IsNotFoundError -Value { param($ErrorRecord, $Context) $false }
  Set-Item -Path function:global:Get-SupersedingAppIdFromError -Value { param($m) '774cc400-521b-4a3a-a000-02afedef612f' }
  # Abhaengen scheitert - genau der Fall aus dem Betrieb.
  Set-Item -Path function:global:Remove-SupersededByUnlinking -Value {
    param($OldAppId, $NewAppId)
    $global:UnlinkAttempts.Add([string]$OldAppId)
    return $false
  }
  Set-Item -Path function:global:Invoke-WtRemoveWin32App -Value {
    param([string]$AppId)
    $global:DeleteAttempts.Add($AppId)
    throw ("Cannot delete this app as it is the parent of another app: 774cc400-521b-4a3a-a000-02afedef612f. - Url: https://proxy.amsub0202.manage.microsoft.com/...")
  }
}

Describe 'Test-IsStructuralDeleteRefusal' {

  It 'erkennt Intunes Absage wegen einer Abloesebeziehung' {
    Test-IsStructuralDeleteRefusal -Message 'Cannot delete this app as it is the parent of another app: 774cc400-521b-4a3a-a000-02afedef612f.' | Should -BeTrue
    Test-IsStructuralDeleteRefusal -Message 'Cannot delete this app' | Should -BeTrue
  }

  # Der teure Fehler waere hier die Gegenrichtung: eine voruebergehende Stoerung als endgueltig zu
  # lesen schaltet das Aufraeumen fuer den Rest der Sitzung stillschweigend ab.
  It 'haelt eine voruebergehende Stoerung NICHT fuer endgueltig' {
    foreach ($m in @(
      'Response status code does not indicate success: 429 (Too Many Requests).',
      'Response status code does not indicate success: 503 (Service Unavailable).',
      'The operation has timed out.',
      'Response status code does not indicate success: 403 (Forbidden).',
      'Not found', '', $null)) {
      Test-IsStructuralDeleteRefusal -Message $m | Should -BeFalse -Because "'$m' kann beim naechsten Lauf gehen"
    }
  }
}

Describe 'Remove-AppWithUnlinkFallback' {

  BeforeEach {
    $global:DeleteAttempts.Clear(); $global:UnlinkAttempts.Clear(); $global:Recorded.Clear()
    $global:TestLog.Clear()
    Clear-DeleteBlockedAppCache
  }

  It 'merkt eine strukturelle Absage, wenn auch das Abhaengen sie nicht loest' {
    $r = Remove-AppWithUnlinkFallback -GraphId 'aaaaaaaa-0000-0000-0000-000000000001' -AppName 'Mozilla Firefox' -Version '153.0.1'
    $r | Should -BeFalse
    @($global:DeleteAttempts).Count | Should -Be 1
    @($global:UnlinkAttempts).Count | Should -Be 1
    ($global:TestLog -join "`n") | Should -Match 'will not be retried in this session'
  }

  # Der Punkt der ganzen Uebung: der zweite Durchlauf ruehrt die App nicht mehr an.
  It 'versucht es im zweiten Durchlauf gar nicht mehr' {
    [void](Remove-AppWithUnlinkFallback -GraphId 'aaaaaaaa-0000-0000-0000-000000000001' -AppName 'Mozilla Firefox' -Version '153.0.1')
    $global:DeleteAttempts.Clear(); $global:UnlinkAttempts.Clear(); $global:TestLog.Clear()

    $r = Remove-AppWithUnlinkFallback -GraphId 'aaaaaaaa-0000-0000-0000-000000000001' -AppName 'Mozilla Firefox' -Version '153.0.1'
    $r | Should -BeFalse
    @($global:DeleteAttempts).Count | Should -Be 0 -Because 'kein Loeschversuch mehr'
    @($global:UnlinkAttempts).Count | Should -Be 0 -Because 'und kein Schreibvorgang in den Tenant'
    ($global:TestLog -join "`n") | Should -Match 'Deletion skipped'
  }

  It 'merkt sich nur die abgelehnte App, nicht die naechste' {
    [void](Remove-AppWithUnlinkFallback -GraphId 'aaaaaaaa-0000-0000-0000-000000000001' -AppName 'Mozilla Firefox')
    $global:DeleteAttempts.Clear()
    [void](Remove-AppWithUnlinkFallback -GraphId 'bbbbbbbb-0000-0000-0000-000000000002' -AppName 'Google Chrome')
    @($global:DeleteAttempts).Count | Should -Be 1 -Because 'eine andere App wird sehr wohl versucht'
  }

  # Eine App-Id gehoert einem Tenant. Bliebe sie stehen, wuerde beim naechsten Kunden eine Loeschung
  # uebersprungen, die dort funktionieren wuerde - dieselbe Fehlerklasse wie ein stehengebliebenes
  # Inventar, nur leiser.
  It 'vergisst die Absage beim Tenantwechsel' {
    [void](Remove-AppWithUnlinkFallback -GraphId 'aaaaaaaa-0000-0000-0000-000000000001' -AppName 'Mozilla Firefox')
    Clear-DeleteBlockedAppCache
    $global:DeleteAttempts.Clear()
    [void](Remove-AppWithUnlinkFallback -GraphId 'aaaaaaaa-0000-0000-0000-000000000001' -AppName 'Mozilla Firefox')
    @($global:DeleteAttempts).Count | Should -Be 1
  }

  It 'zaehlt eine uebersprungene App nicht als Erfolg' {
    [void](Remove-AppWithUnlinkFallback -GraphId 'aaaaaaaa-0000-0000-0000-000000000001' -AppName 'Mozilla Firefox' -Version '153.0.1')
    $global:Recorded.Clear()
    [void](Remove-AppWithUnlinkFallback -GraphId 'aaaaaaaa-0000-0000-0000-000000000001' -AppName 'Mozilla Firefox' -Version '153.0.1')
    @($global:Recorded).Count | Should -Be 0 -Because 'nichts geloescht heisst nichts im Leistungsnachweis'
  }
}

Describe 'Get-GraphErrorBody / Get-GraphErrorText' {

  # Der Anlass: "Response status code does not indicate success: 400 (Bad Request)." stand dreimal
  # im Protokoll, und damit war der Grund nicht feststellbar. Der Grund steht im Koerper.
  It 'holt den Antwortkoerper aus ErrorDetails' {
    $rec = [pscustomobject]@{
      Exception    = [pscustomobject]@{ Message = 'Response status code does not indicate success: 400 (Bad Request).' }
      ErrorDetails = [pscustomobject]@{ Message = "{`r`n  `"error`": {`r`n    `"code`": `"BadRequest`",`r`n    `"message`": `"Relationship is invalid`"`r`n  }`r`n}" }
    }
    $body = Get-GraphErrorBody -ErrorRecord $rec
    $body | Should -Match 'BadRequest'
    $body | Should -Match 'Relationship is invalid'
    # Einzeilig, damit die Zeile greppbar bleibt - ein mehrzeiliger JSON-Block im Protokoll ist
    # genau das, was der Modulfehler daneben schon falsch macht.
    $body | Should -Not -Match "`n"
  }

  It 'kuerzt einen sehr langen Koerper und sagt es' {
    $rec = [pscustomobject]@{
      Exception    = [pscustomobject]@{ Message = 'boom' }
      ErrorDetails = [pscustomobject]@{ Message = ('x' * 3000) }
    }
    $body = Get-GraphErrorBody -ErrorRecord $rec -MaxLength 100
    $body.Length | Should -BeLessThan 200
    $body | Should -Match 'Zeichen'
  }

  It 'bleibt bei einem Fehler ohne Koerper beim Fehlertext allein' {
    $rec = [pscustomobject]@{ Exception = [pscustomobject]@{ Message = 'timeout' }; ErrorDetails = $null }
    Get-GraphErrorBody -ErrorRecord $rec | Should -Be ''
    Get-GraphErrorText -ErrorRecord $rec | Should -Be 'timeout'
  }

  It 'haengt den Koerper an den Fehlertext' {
    $rec = [pscustomobject]@{
      Exception    = [pscustomobject]@{ Message = '400 (Bad Request)' }
      ErrorDetails = [pscustomobject]@{ Message = 'relationship not allowed' }
    }
    Get-GraphErrorText -ErrorRecord $rec | Should -Be '400 (Bad Request) | response: relationship not allowed'
  }
}

Describe 'Verdrahtung im Quelltext' {

  # Loeschen ist ein schreibender Modulaufruf wie der Upload und gehoert damit vom UI-Faden weg.
  It 'loescht ueber den Hintergrund-Trichter' {
    $fn = Get-SourceFunctionText -Part '30-UpdateTargets.ps1' -Name 'Invoke-WtRemoveWin32App'
    $fn | Should -Match 'Invoke-WtModuleCallOffThread'
  }

  # Der Riegel, der beim Upload schon gilt: eine halb ausgefuehrte Loeschung ist nicht
  # zurueckzunehmen, also wird sie nie abgebrochen.
  It 'bricht eine laufende Loeschung nicht ab' {
    $fn = Get-SourceFunctionText -Part '30-UpdateTargets.ps1' -Name 'Invoke-WtRemoveWin32App'
    $fn | Should -Not -Match '\.Stop\(\)'
    $fn | Should -Not -Match 'cancelBatch'
  }

  # Ohne das Nachlesen sieht ein wirkungsloser Schreibvorgang im Protokoll wie eine geglueckte
  # Aenderung aus, der nur die Loeschung nicht folgte - und das ist die falsche Fehlersuche.
  It 'liest nach, ob das Abhaengen wirklich gewirkt hat, statt es anzunehmen' {
    $fn = Get-SourceFunctionText -Part '35-Packaging.ps1' -Name 'Remove-SupersededByUnlinking'
    $fn | Should -Match 'is STILL there'
    # Zweimal lesen: einmal vor der Aenderung, einmal danach.
    ([regex]::Matches($fn, 'Get-GraphCollectionItems')).Count | Should -BeGreaterOrEqual 2
  }

  It 'nennt beim gescheiterten Rueckbau den Antwortkoerper, nicht nur den Status' {
    $fn = Get-SourceFunctionText -Part '35-Packaging.ps1' -Name 'Remove-SupersededByUnlinking'
    $fn | Should -Match 'CRITICAL: could not restore relationships[\s\S]*Get-GraphErrorText'
  }

  # Eine Warteschleife auf dem UI-Faden ohne DoEvents ist ein Standbild - dieser Pfad laeuft mitten
  # im Aufraeumen.
  It 'pumpt die Nachrichtenschleife waehrend der Wartezeit nach dem Abhaengen' {
    $fn = Get-SourceFunctionText -Part '35-Packaging.ps1' -Name 'Remove-SupersededByUnlinking'
    $fn | Should -Match 'DoEvents'
    $fn | Should -Not -Match 'Start-Sleep -Seconds'
  }
}
