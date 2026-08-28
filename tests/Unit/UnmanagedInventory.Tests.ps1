BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '25-WinGetData.ps1' -Name @(
    'Get-PackageIdFromNotes', 'Test-IsSupersededApp', 'Test-IsPlausiblePackageId',
    'Get-LoosePackageIdFromNotes',
    'Select-UnmanagedWin32Apps', 'Merge-UnmanagedInventory', 'Get-ScanInventory'))))

  # Ein roher Graph-App-Datensatz, wie ihn Get-RawWin32AppsFromGraph liefert. Nur die Felder, die
  # die Auswahl liest - alles andere waere Beiwerk, das den Test unlesbar macht.
  function New-RawApp {
    param(
      [string]$Id,
      [string]$Name,
      [string]$Type = '#microsoft.graph.win32LobApp',
      [string]$Notes = '',
      [string]$Version = '1.0',
      [int]$SupersededAppCount = 0
    )
    [pscustomobject]@{
      'id'                 = $Id
      '@odata.type'        = $Type
      'displayName'        = $Name
      'displayVersion'     = $Version
      'notes'              = $Notes
      'isAssigned'         = $true
      'supersededAppCount' = $SupersededAppCount
    }
  }
}

Describe 'Select-UnmanagedWin32Apps' {
  # Der Grund fuer diese Funktion: die Marke im Notizfeld sagt, WER die App angelegt hat, nicht ob es
  # ein WinGet-Gegenstueck gibt. Handgebaute Pakete sind ebenfalls .intunewin-Apps, und die Marke
  # wird im Betrieb auch wieder entfernt - beides liess Apps aus der Update-Suche verschwinden.
  It 'keeps a Win32 app that has no WinTuner marker' {
    $result = @(Select-UnmanagedWin32Apps -RawApps @((New-RawApp -Id 'a1' -Name 'Docker Desktop' -Version '0.0.45122')))
    $result.Count | Should -Be 1
    $result[0].Name | Should -Be 'Docker Desktop'
    $result[0].CurrentVersion | Should -Be '0.0.45122'
    $result[0].GraphId | Should -Be 'a1'
  }

  It 'marks what it returns as unmanaged and leaves the package id empty' {
    # Leer ist Absicht, nicht Nachlaessigkeit: nur so MUSS Resolve-WingetIdForApp seine strengen
    # Regeln anwenden. Eine hier geratene Id wuerde ungeprueft bis in den Paketbau durchlaufen.
    $result = @(Select-UnmanagedWin32Apps -RawApps @((New-RawApp -Id 'a1' -Name 'GitHub Desktop')))
    $result[0].IsUnmanaged | Should -BeTrue
    $result[0].PackageId | Should -BeNullOrEmpty
  }

  It 'liest eine Paket-Id aus dem Notizfeld auch ohne die geklammerte Marke' {
    # Der Fall, um den es geht: im Notizfeld steht, was ein Mensch hingeschrieben hat. Diese Id ist
    # aufgeschrieben und nicht geraten - sie wegzuwerfen und stattdessen den Namen zu vergleichen
    # waere der schlechtere von zwei Wegen.
    $result = @(Select-UnmanagedWin32Apps -RawApps @(
      (New-RawApp -Id 'a1' -Name 'Google Chrome' -Notes 'Ausgerollt mit WinGet: Google.Chrome')))
    $result.Count | Should -Be 1
    $result[0].PackageId | Should -Be 'Google.Chrome'
    $result[0].PackageIdFromNotes | Should -BeTrue
    # Und trotzdem unmarkiert: die App bleibt in genau der Liste, in der sie vorher stand.
    $result[0].IsUnmanaged | Should -BeTrue
  }

  It 'wirft eine App mit loser Notiz-Id NICHT aus der Suche' {
    # Die Gegenprobe zur Regel darueber. Haette die lose Lesart als Marke gegolten, waere die App
    # aus dem markierten Inventar (keine Klammer-Marke) UND aus dieser Liste gefallen - also gar
    # nicht mehr geprueft worden. Genau das darf nicht passieren.
    $result = @(Select-UnmanagedWin32Apps -RawApps @(
      (New-RawApp -Id 'a1' -Name 'Zoom Rooms' -Notes 'WinTuner - Zoom.ZoomRooms')))
    $result.Count | Should -Be 1
    $result[0].GraphId | Should -Be 'a1'
  }
}

Describe 'Test-IsPlausiblePackageId' {
  It 'nimmt an, was wie Hersteller.Produkt aussieht' {
    Test-IsPlausiblePackageId -Value 'Google.Chrome' | Should -BeTrue
    Test-IsPlausiblePackageId -Value 'Microsoft.VisualStudioCode' | Should -BeTrue
    Test-IsPlausiblePackageId -Value 'Microsoft.VCRedist.2015+.x64' | Should -BeTrue
  }

  It 'lehnt eine Versionsnummer ab' {
    # '1.4.1' erfuellt das Punktmuster und ist trotzdem keine Id. Ohne diese Regel haette
    # "WinTuner 1.4.1" im Notizfeld eine Paket-Id namens 1.4.1 ergeben.
    Test-IsPlausiblePackageId -Value '1.4.1' | Should -BeFalse
    Test-IsPlausiblePackageId -Value '0.16.0' | Should -BeFalse
  }

  It 'lehnt einen Dateinamen ab' {
    Test-IsPlausiblePackageId -Value 'setup.exe' | Should -BeFalse
    Test-IsPlausiblePackageId -Value 'Paket.intunewin' | Should -BeFalse
  }

  It 'lehnt ab, was gar keinen Punkt hat oder leer ist' {
    Test-IsPlausiblePackageId -Value 'Chrome' | Should -BeFalse
    Test-IsPlausiblePackageId -Value 'Keeper Password Manager' | Should -BeFalse
    Test-IsPlausiblePackageId -Value '' | Should -BeFalse
    Test-IsPlausiblePackageId -Value $null | Should -BeFalse
  }
}

Describe 'Get-LoosePackageIdFromNotes' {
  It 'liest die Id hinter dem blossen Wort, in beiden Schreibweisen' {
    Get-LoosePackageIdFromNotes -Notes 'WinGet: Google.Chrome'      | Should -Be 'Google.Chrome'
    Get-LoosePackageIdFromNotes -Notes 'winget Google.Chrome'       | Should -Be 'Google.Chrome'
    Get-LoosePackageIdFromNotes -Notes 'WinTuner - Zoom.ZoomRooms'  | Should -Be 'Zoom.ZoomRooms'
    Get-LoosePackageIdFromNotes -Notes 'WingetIntune = Docker.DockerDesktop' | Should -Be 'Docker.DockerDesktop'
  }

  It 'geht ueber eine Erwaehnung ohne Id hinweg' {
    # "WinTuner GUI 0.16.0" ist eine Erwaehnung, keine Zuordnung. Nur den ersten Treffer zu
    # betrachten haette die echte Id dahinter uebersehen.
    Get-LoosePackageIdFromNotes -Notes 'Gebaut mit WinTuner GUI 0.16.0, WinGet Google.Chrome' | Should -Be 'Google.Chrome'
  }

  It 'raet nichts, wo nichts steht' {
    Get-LoosePackageIdFromNotes -Notes 'WinTuner 1.4.1'            | Should -Be ''
    Get-LoosePackageIdFromNotes -Notes 'Installiert mit winget.'   | Should -Be ''
    Get-LoosePackageIdFromNotes -Notes 'Google.Chrome'             | Should -Be ''
    Get-LoosePackageIdFromNotes -Notes 'Von Hand gebaut'           | Should -Be ''
    Get-LoosePackageIdFromNotes -Notes ''                          | Should -Be ''
  }

  It 'schneidet Satzzeichen am Ende ab' {
    Get-LoosePackageIdFromNotes -Notes 'Quelle: WinGet (Google.Chrome).' | Should -Be 'Google.Chrome'
  }
}

Describe 'Select-UnmanagedWin32Apps - Marke, App-Typ und Zustand' {
  It 'drops an app that carries the WinTuner marker' {
    # Die gehoert dem Modul und kommt ueber das regulaere Inventar - mit belastbarer PackageId.
    $result = @(Select-UnmanagedWin32Apps -RawApps @(
      (New-RawApp -Id 'a1' -Name 'Google Chrome' -Notes '[WinTuner|winget|Google.Chrome]')))
    $result.Count | Should -Be 0
  }

  It 'drops the historical WingetIntune marker as well' {
    $result = @(Select-UnmanagedWin32Apps -RawApps @(
      (New-RawApp -Id 'a1' -Name 'Mozilla Firefox' -Notes '[WingetIntune|winget|Mozilla.Firefox]')))
    $result.Count | Should -Be 0
  }

  It 'drops every app type WinTuner cannot package' {
    # Store-, Microsoft-365-, Edge-, MSI- und Weblink-Apps sind ein anderer @odata.type. Sie hier
    # durchzulassen haette Zeilen erzeugt, die kein Paketbau je haette bedienen koennen.
    $result = @(Select-UnmanagedWin32Apps -RawApps @(
      (New-RawApp -Id 'b1' -Name 'Slack'          -Type '#microsoft.graph.winGetApp'),
      (New-RawApp -Id 'b2' -Name 'Node.js'        -Type '#microsoft.graph.windowsMobileMSI'),
      (New-RawApp -Id 'b3' -Name 'Microsoft 365'  -Type '#microsoft.graph.officeSuiteApp'),
      (New-RawApp -Id 'b4' -Name 'Microsoft Edge' -Type '#microsoft.graph.windowsMicrosoftEdgeApp'),
      (New-RawApp -Id 'b5' -Name 'TeamViewer'     -Type '#microsoft.graph.webApp')))
    $result.Count | Should -Be 0
  }

  It 'accepts the type with and without the leading hash' {
    $result = @(Select-UnmanagedWin32Apps -RawApps @(
      (New-RawApp -Id 'a1' -Name 'With hash'    -Type '#microsoft.graph.win32LobApp'),
      (New-RawApp -Id 'a2' -Name 'Without hash' -Type 'microsoft.graph.win32LobApp')))
    $result.Count | Should -Be 2
  }

  It 'returns only active apps by default' {
    # supersededAppCount > 0 heisst "wird von etwas Neuerem abgeloest", also die ALTE Version. Sie in
    # die Update-Suche zu ziehen hiesse, eine bereits erledigte Ablösung noch einmal zu bauen.
    $result = @(Select-UnmanagedWin32Apps -RawApps @(
      (New-RawApp -Id 'a1' -Name 'Aktuell' -SupersededAppCount 0),
      (New-RawApp -Id 'a2' -Name 'Alt'     -SupersededAppCount 1)))
    $result.Count | Should -Be 1
    $result[0].Name | Should -Be 'Aktuell'
  }

  It 'returns only superseded apps when asked for them' {
    $result = @(Select-UnmanagedWin32Apps -Superseded -RawApps @(
      (New-RawApp -Id 'a1' -Name 'Aktuell' -SupersededAppCount 0),
      (New-RawApp -Id 'a2' -Name 'Alt'     -SupersededAppCount 2)))
    $result.Count | Should -Be 1
    $result[0].Name | Should -Be 'Alt'
  }

  It 'skips records without an id and copes with an empty or missing list' {
    @(Select-UnmanagedWin32Apps -RawApps @((New-RawApp -Id '' -Name 'Kaputt'))).Count | Should -Be 0
    @(Select-UnmanagedWin32Apps -RawApps @()).Count   | Should -Be 0
    @(Select-UnmanagedWin32Apps -RawApps $null).Count | Should -Be 0
  }
}

Describe 'Merge-UnmanagedInventory' {
  It 'appends the unmarked apps to the module inventory' {
    $managed = @([pscustomobject]@{ Name = 'Chrome'; GraphId = 'm1'; PackageId = 'Google.Chrome' })
    $unmanaged = @([pscustomobject]@{ Name = 'Docker'; GraphId = 'u1'; PackageId = ''; IsUnmanaged = $true })
    $result = @(Merge-UnmanagedInventory -ManagedApps $managed -UnmanagedApps $unmanaged)
    $result.Count | Should -Be 2
    @($result | Where-Object { $_.GraphId -eq 'u1' }).Count | Should -Be 1
  }

  It 'keeps the module object when both lists name the same GraphId' {
    # Das Modul-Objekt traegt die PackageId aus dem Notizfeld, das Graph-Objekt nur einen Namen. Das
    # Graph-Objekt gewinnen zu lassen hiesse, eine belastbare Id gegen einen Namensabgleich zu tauschen.
    $managed = @([pscustomobject]@{ Name = 'Chrome'; GraphId = 'x1'; PackageId = 'Google.Chrome' })
    $unmanaged = @([pscustomobject]@{ Name = 'Chrome'; GraphId = 'x1'; PackageId = ''; IsUnmanaged = $true })
    $result = @(Merge-UnmanagedInventory -ManagedApps $managed -UnmanagedApps $unmanaged)
    $result.Count | Should -Be 1
    $result[0].PackageId | Should -Be 'Google.Chrome'
  }

  It 'compares Graph ids case-insensitively' {
    # Graph gibt GUIDs mal so, mal so zurueck. Ein Gross-/Kleinschreibungsunterschied haette dieselbe
    # App zweimal in die Suche gelegt - und damit in zwei konkurrierende Uploads.
    $managed = @([pscustomobject]@{ Name = 'Chrome'; GraphId = 'AB12'; PackageId = 'Google.Chrome' })
    $unmanaged = @([pscustomobject]@{ Name = 'Chrome'; GraphId = 'ab12'; PackageId = '' })
    @(Merge-UnmanagedInventory -ManagedApps $managed -UnmanagedApps $unmanaged).Count | Should -Be 1
  }

  It 'skips entries without a GraphId and copes with empty lists' {
    $managed = @([pscustomobject]@{ Name = 'Ohne Id'; GraphId = '' })
    @(Merge-UnmanagedInventory -ManagedApps $managed -UnmanagedApps @()).Count | Should -Be 0
    @(Merge-UnmanagedInventory -ManagedApps $null -UnmanagedApps $null).Count  | Should -Be 0
  }
}

Describe 'Get-ScanInventory' {
  BeforeEach {
    $global:TestLog.Clear()
    $global:UnmanagedCalls = 0
    Set-Item -Path function:global:Get-UnmanagedWin32Apps -Value {
      $global:UnmanagedCalls++
      if ($global:UnmanagedThrows) { throw 'Graph read failed' }
      return @([pscustomobject]@{ Name = 'Docker Desktop'; GraphId = 'u1'; PackageId = ''; IsUnmanaged = $true })
    }
    $global:UnmanagedThrows = $false
  }

  AfterAll { Remove-Item -Path function:global:Get-UnmanagedWin32Apps -ErrorAction SilentlyContinue }

  It 'returns the module inventory unchanged when the setting is off' {
    # Und liest den Tenant dann auch nicht: die Graph-Abfrage ist ein Seitendurchlauf, der ohne die
    # Einstellung nichts beitraegt.
    $script:settings = @{ ScanUnmanagedWin32Apps = $false }
    $managed = @([pscustomobject]@{ Name = 'Chrome'; GraphId = 'm1' })
    $result = @(Get-ScanInventory -ManagedApps $managed)
    $result.Count | Should -Be 1
    $global:UnmanagedCalls | Should -Be 0
  }

  It 'adds the unmarked apps when the setting is on' {
    $script:settings = @{ ScanUnmanagedWin32Apps = $true }
    $result = @(Get-ScanInventory -ManagedApps @([pscustomobject]@{ Name = 'Chrome'; GraphId = 'm1' }))
    $result.Count | Should -Be 2
    $global:UnmanagedCalls | Should -Be 1
  }

  It 'keeps scanning the marked apps when the Graph read fails, and says so' {
    # Ein Fehler in der Zusatzabfrage darf die Suche nicht abbrechen - die markierten Apps sind
    # vollstaendig gelesen. Lautlos darf die Luecke aber auch nicht bleiben, sonst liest sich ein
    # verkuerzter Lauf wie ein vollstaendiger.
    $script:settings = @{ ScanUnmanagedWin32Apps = $true }
    $global:UnmanagedThrows = $true
    $result = @(Get-ScanInventory -ManagedApps @([pscustomobject]@{ Name = 'Chrome'; GraphId = 'm1' }))
    $result.Count | Should -Be 1
    ($global:TestLog -join "`n") | Should -Match 'could not be read'
  }

  It 'does not claim a widened scope when the tenant has no unmarked apps' {
    $script:settings = @{ ScanUnmanagedWin32Apps = $true }
    Set-Item -Path function:global:Get-UnmanagedWin32Apps -Value { @() }
    $result = @(Get-ScanInventory -ManagedApps @([pscustomobject]@{ Name = 'Chrome'; GraphId = 'm1' }))
    $result.Count | Should -Be 1
    ($global:TestLog -join "`n") | Should -Not -Match 'unmarked Win32 app'
  }

  It 'accepts an empty module inventory and still finds the unmarked apps' {
    # Genau der Fall, den 0.16.0 als "Keine von WinTuner verwalteten Apps" abgewiesen hat, obwohl im
    # Portal Win32-Apps standen.
    $script:settings = @{ ScanUnmanagedWin32Apps = $true }
    $result = @(Get-ScanInventory -ManagedApps @())
    $result.Count | Should -Be 1
    $result[0].Name | Should -Be 'Docker Desktop'
  }
}

Describe 'Die Update-Suche benutzt den erweiterten Umfang' {
  # Der Klick-Handler ist keine Funktion und laesst sich nicht einzeln laden - geprueft wird deshalb
  # die Stelle im Quelltext. Ohne diese Regel waere Get-ScanInventory eine Funktion, die niemand
  # ruft: alles gruen, und die Suche liefe weiter nur ueber die markierten Apps.
  BeforeAll { $script:mainText = Get-SourcePartText -Part '90-Main.ps1' }

  It 'legt den Umfang NACH dem Abzug der abgeloesten Ueberlappung fest' {
    # Reihenfolge ist hier kein Geschmack: Select-UnmanagedWin32Apps trennt aktiv/abgeloest schon
    # selbst. Vorher eingehaengt wuerden die unmarkierten Apps ein zweites Mal gegen das
    # Modul-Inventar der abgeloesten gerechnet - und dabei teilweise wieder herausfallen.
    $script:mainText | Should -Match '(?s)Remove-SupersededInventoryOverlap.*?\$all = @\(Get-ScanInventory -ManagedApps \$all\)'
  }

  It 'erklaert ein leeres Ergebnis passend zum Umfang' {
    # Mit eingeschaltetem Schalter heisst "null" nicht mehr "keine WinTuner-Apps", sondern "gar keine
    # Win32-Apps". Die alte Meldung waere an dieser Stelle eine falsche Auskunft.
    $script:mainText | Should -Match 'if \(\$script:settings\.ScanUnmanagedWin32Apps\) \{'
    $script:mainText | Should -Match "Update-Status \(Get-UiString 'NoWin32AppsStatus'\)"
  }
}
