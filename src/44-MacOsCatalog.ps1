# ==================================================================================================
# Teil 44: Katalog fuer macOS-PKG-Apps (Beta)
# ==================================================================================================
#
# Das Gegenstueck zum WinGet-Katalog - nur dass es fuer macOS keinen gibt, den Microsoft anbietet.
# Quelle ist deshalb Homebrew (formulae.brew.sh), gefiltert auf das, was wir wirklich verwenden
# koennen, plus eine kurze eigene Liste fuer die Faelle, in denen Homebrew danebenliegt.
#
# Gemessen am 11.09.2026 am vollstaendigen Katalog (7712 Casks):
#
#   DMG  2946 (38,2 %)   ZIP 1868 (24,2 %)   PKG 378 (4,9 %)   anderes 2257
#   von den 378 PKG-Casks haben 334 einen echten SHA256 (88 %)
#   von den 378 PKG-Casks nennen 0 eine bundle_short_version
#
# Drei Folgerungen, die den Aufbau hier bestimmen:
#
# 1. Wir nehmen NUR die PKG-Casks. Ein DMG waere macOSDmgApp, ein anderer App-Typ und ein ganz
#    anderes Format zum Auslesen (Plattenabbild statt xar). Bewusst nicht in diesem Umfang.
#
# 2. Homebrew kennt die Bundle-Version nicht (0 von 378). Die fuer Intunes Erkennung noetige
#    Version kommt deshalb weiterhin AUS DEM PAKET (Teil 43), nie aus dem Katalog. Die
#    Cask-Version dient nur dem Vergleich "hat sich etwas geaendert" - sie ist dafuer gut genug
#    und fuer sonst nichts (bei Microsoft Edge haengt ihr sogar ein GUID an).
#
# 3. Die grossen Browser liefert Homebrew als DMG, obwohl der Hersteller ein PKG anbietet - Chrome
#    ist genau so ein Fall. Dafuer die Ueberschreibliste unten. Sie ist kurz und bleibt kurz: jeder
#    Eintrag ist Pflegeaufwand und muss von Hand geprueft worden sein.

$script:macOsCatalogUrl = 'https://formulae.brew.sh/api/cask.json'
# Der Katalog ist rund 18 MB. Ein knapper Zeitablauf waere auf einer langsamen Leitung ein
# Fehlschlag ohne Grund; ohne Angabe wartete PowerShell 7 unbegrenzt.
$script:macOsCatalogTimeoutSeconds = 180
# So lange gilt die Kopie auf der Platte als frisch. Der Katalog aendert sich taeglich, aber nicht
# stuendlich - und 18 MB bei jedem Fensterstart waeren eine Zumutung.
$script:macOsCatalogMaxAgeHours = 24
$script:macOsCatalogPath = Join-Path (Get-LocalAppDataRoot) 'WinTunerGUI\mac-catalog.json'

# Apps, fuer die der Hersteller ein PKG anbietet, Homebrew aber auf ein DMG zeigt.
#
# JEDER Eintrag wurde von Hand geprueft - die URL muss mit HTTP 200 und einem PKG antworten, und
# das heruntergeladene Paket muss sich von Teil 43 lesen lassen. Das Datum sagt, wann zuletzt.
# Ein Eintrag ohne diese Pruefung gehoert hier nicht hinein: eine tote URL im Katalog ist ein
# Supportfall, den niemand von aussen erklaeren kann.
$script:macOsPkgOverrides = @(
  @{
    Token    = 'google-chrome'
    Name     = 'Google Chrome'
    Url      = 'https://dl.google.com/chrome/mac/universal/stable/gcem/GoogleChrome.pkg'
    Homepage = 'https://chromeenterprise.google/browser/download/'
    Reason   = 'Homebrew zeigt auf googlechrome.dmg; Google liefert daneben ein Enterprise-PKG.'
    Checked  = '2026-09-11'
  }
  @{
    Token    = 'firefox'
    Name     = 'Mozilla Firefox'
    Url      = 'https://download.mozilla.org/?product=firefox-pkg-latest-ssl&os=osx&lang=de'
    Homepage = 'https://www.mozilla.org/firefox/enterprise/'
    Reason   = 'Homebrew zeigt auf das DMG; Mozilla bietet dieselbe Fassung als PKG an.'
    Checked  = '2026-09-11'
  }
)

# --- Reine Auswertung (ohne Netz, deshalb vollstaendig pruefbar) ---------------------------------

# Zeigt diese Adresse auf ein Installationspaket?
#
# Nicht ueber die Dateiendung allein: eine URL kann eine Abfrage anhaengen
# (...firefox-pkg-latest-ssl&os=osx), und ein '.pkg' mitten im Pfad heisst nichts.
function Test-IsPkgUrl {
  param([string]$Url)
  if ([string]::IsNullOrWhiteSpace($Url)) { return $false }
  # Den Abfrageteil abschneiden und nur das letzte Pfadstueck ansehen.
  $path = ($Url -split '\?', 2)[0]
  if ($path -match '\.pkg$') { return $true }
  # Ausnahme fuer Adressen, die das Format in der Abfrage nennen statt im Pfad.
  return ($Url -match '(?i)[?&][^=]*=[^&]*-pkg-[^&]*')
}

# Macht aus einem Homebrew-Cask den Katalogeintrag, den der Rest der Anwendung benutzt.
function ConvertTo-MacOsCatalogEntry {
  param([Parameter(Mandatory)]$Cask)
  $names = @($Cask.name)
  return @{
    Token       = [string]$Cask.token
    Name        = if ($names.Count -gt 0 -and $names[0]) { [string]$names[0] } else { [string]$Cask.token }
    Description = [string]$Cask.desc
    Homepage    = [string]$Cask.homepage
    Url         = [string]$Cask.url
    Version     = [string]$Cask.version
    # 'no_check' heisst bei Homebrew: die Datei aendert sich unter derselben Adresse, ein fester
    # Hash ist unmoeglich. Das ist KEIN Fehler, aber der Aufrufer muss es wissen.
    Sha256      = $(if ([string]$Cask.sha256 -eq 'no_check') { '' } else { [string]$Cask.sha256 })
    Source      = 'homebrew'
  }
}

# Die Teilmenge des Katalogs, mit der diese Anwendung ueberhaupt etwas anfangen kann.
function Select-MacOsPkgCasks {
  param([object[]]$Casks)
  $out = [Collections.Generic.List[hashtable]]::new()
  foreach ($cask in $Casks) {
    if (-not $cask) { continue }
    if (-not (Test-IsPkgUrl -Url ([string]$cask.url))) { continue }
    if ([string]::IsNullOrWhiteSpace([string]$cask.token)) { continue }
    $out.Add((ConvertTo-MacOsCatalogEntry -Cask $cask))
  }
  # Das Komma ist kein Tippfehler: ohne es entfaltet PowerShell die Liste beim Zurueckgeben, und
  # bei GENAU EINEM Treffer bekommt der Aufrufer statt einer Liste das Hashtable selbst. Dann
  # liefert .Count die Zahl seiner SCHLUESSEL (8) und [0] greift ins Leere. Genau so gemessen.
  return , $out.ToArray()
}

# Legt die eigene Liste ueber die von Homebrew. Ein Ueberschreibeintrag ERSETZT den gleichnamigen
# Cask (die Version bleibt die von Homebrew - sie taugt weiter als Vergleichswert) und wird
# angehaengt, wenn es ihn dort gar nicht gibt.
function Merge-MacOsCatalogOverrides {
  param([object[]]$Entries, [object[]]$Overrides = @())
  $list = [Collections.Generic.List[hashtable]]::new()
  foreach ($e in $Entries) { if ($e) { $list.Add([hashtable]$e) } }
  $use = if ($Overrides.Count -gt 0) { $Overrides } else { $script:macOsPkgOverrides }

  foreach ($ov in $use) {
    $token = [string]$ov.Token
    if (-not $token) { continue }
    $existing = $null
    for ($i = 0; $i -lt $list.Count; $i++) {
      if ([string]$list[$i].Token -eq $token) { $existing = $i; break }
    }
    if ($null -ne $existing) {
      # Die Adresse und der Name kommen aus der eigenen Liste, die Version von Homebrew. Der Hash
      # wird GELEERT: er gehoerte zum DMG, nicht zu dem PKG, das wir jetzt laden.
      $list[$existing].Url = [string]$ov.Url
      $list[$existing].Sha256 = ''
      $list[$existing].Source = 'override'
      if ($ov.Name) { $list[$existing].Name = [string]$ov.Name }
      if ($ov.Homepage) { $list[$existing].Homepage = [string]$ov.Homepage }
    } else {
      $list.Add(@{
        Token = $token; Name = [string]$ov.Name; Description = ''
        Homepage = [string]$ov.Homepage; Url = [string]$ov.Url
        Version = ''; Sha256 = ''; Source = 'override'
      })
    }
  }
  # Siehe Select-MacOsPkgCasks: ein einzelner Eintrag darf nicht zum Hashtable zusammenfallen.
  return , $list.ToArray()
}

# --- Die Marke im Notizfeld ----------------------------------------------------------------------
#
# Damit ein spaeterer Lauf weiss, WAS er da bereitgestellt hat und in welcher Fassung. Ohne sie
# muesste die Update-Pruefung jedes Paket vollstaendig herunterladen, nur um die Version zu
# erfahren - bei Office sind das ueber 600 MB je Pruefung.
#
# Bewusst NICHT '[WinTuner|': dieses Muster liest Get-PackageIdFromNotes (Teil 25) als WinGet-Id,
# und die Inventarpfade dort sollen macOS-Apps gar nicht erst anfassen.
function New-MacOsAppMarker {
  param(
    [Parameter(Mandatory)][string]$CaskToken,
    [string]$Version = ''
  )
  return ("[WtMac|{0}|{1}]" -f $CaskToken, $Version)
}

function Read-MacOsAppMarker {
  param([string]$Notes)
  if ([string]::IsNullOrWhiteSpace($Notes)) { return $null }
  $m = [regex]::Match($Notes, '\[WtMac\|(?<token>[^|\]]+)\|(?<version>[^\]]*)\]')
  if (-not $m.Success) { return $null }
  return @{ Token = $m.Groups['token'].Value; Version = $m.Groups['version'].Value }
}

# Muss neu bereitgestellt werden? Der Vergleich laeuft ueber die CASK-Version, nicht ueber die
# Bundle-Version: die Cask-Version ist das einzige, was ohne Download bekannt ist.
#
# Unbekannt heisst NICHT "aktualisieren". Eine App ohne Marke, oder ein Katalogeintrag ohne
# Version, ist ein Fall fuer den Menschen - ein Update, das auf Verdacht laeuft, ersetzt den
# Inhalt einer produktiven App durch etwas, das vielleicht dasselbe ist.
function Test-MacOsUpdateNeeded {
  param([string]$DeployedVersion, [string]$CatalogVersion)
  if ([string]::IsNullOrWhiteSpace($DeployedVersion)) { return $false }
  if ([string]::IsNullOrWhiteSpace($CatalogVersion)) { return $false }
  return -not [string]::Equals($DeployedVersion.Trim(), $CatalogVersion.Trim(), [StringComparison]::OrdinalIgnoreCase)
}

# --- Kopie auf der Platte -------------------------------------------------------------------------

function Get-MacOsCatalogCache {
  if (-not $script:macOsCatalogPath) { return $null }
  try {
    if (-not (Test-Path -LiteralPath $script:macOsCatalogPath)) { return $null }
    $raw = Get-Content -LiteralPath $script:macOsCatalogPath -Raw -Encoding utf8 -ErrorAction Stop
    $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
    $fetched = [datetime]::MinValue
    [void][datetime]::TryParse([string]$parsed.FetchedUtc, [cultureinfo]::InvariantCulture,
      [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal,
      [ref]$fetched)
    $entries = @($parsed.Entries | ForEach-Object {
      @{
        Token = [string]$_.Token; Name = [string]$_.Name; Description = [string]$_.Description
        Homepage = [string]$_.Homepage; Url = [string]$_.Url; Version = [string]$_.Version
        Sha256 = [string]$_.Sha256; Source = [string]$_.Source
      }
    })
    return @{ FetchedUtc = $fetched; Entries = $entries }
  } catch {
    # Eine unlesbare Kopie ist kein Grund, die Anwendung aufzuhalten - sie wird neu geholt.
    Write-Log ("The macOS catalogue cache could not be read and will be fetched again: {0}" -f $_.Exception.Message)
    return $null
  }
}

function Save-MacOsCatalogCache {
  param([Parameter(Mandatory)][object[]]$Entries)
  try {
    $dir = Split-Path -Parent $script:macOsCatalogPath
    # .NET statt New-Item: das Cmdlet kennt kein -LiteralPath, und ein Ordnername mit [ oder ]
    # wuerde von -Path als Muster gelesen und stillschweigend nicht gefunden. So macht es der
    # ganze Bestand, und eine StaticCheck-Regel wacht darueber.
    if (-not (Test-Path -LiteralPath $dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
    $payload = @{ FetchedUtc = ([datetime]::UtcNow.ToString('o')); Entries = @($Entries) } | ConvertTo-Json -Depth 5
    Set-Content -LiteralPath $script:macOsCatalogPath -Value $payload -Encoding utf8 -ErrorAction Stop
    Write-Log ("macOS catalogue cached: {0} entries." -f @($Entries).Count)
  } catch {
    Write-Log ("The macOS catalogue could not be cached: {0}" -f $_.Exception.Message)
  }
}

# --- Netz ------------------------------------------------------------------------------------------

# Holt den Katalog, filtert ihn und legt das Ergebnis auf die Platte. Gibt die Eintraege zurueck.
function Update-MacOsCatalog {
  $casks = Invoke-RestMethod -Uri $script:macOsCatalogUrl -Method GET `
    -TimeoutSec $script:macOsCatalogTimeoutSeconds -ErrorAction Stop
  $pkgOnly = Select-MacOsPkgCasks -Casks @($casks)
  $merged = Merge-MacOsCatalogOverrides -Entries $pkgOnly
  Write-Log ("macOS catalogue fetched: {0} cask(s) total, {1} usable as .pkg, {2} after overrides." -f
    @($casks).Count, $pkgOnly.Count, $merged.Count)
  Save-MacOsCatalogCache -Entries $merged
  return $merged
}

# Die Eintraege - aus der Kopie, wenn sie frisch genug ist, sonst neu geholt.
function Get-MacOsCatalogEntries {
  param([switch]$Force)
  if (-not $Force) {
    $cache = Get-MacOsCatalogCache
    if ($cache -and $cache.Entries.Count -gt 0) {
      $age = ([datetime]::UtcNow - $cache.FetchedUtc).TotalHours
      if ($age -ge 0 -and $age -lt $script:macOsCatalogMaxAgeHours) { return $cache.Entries }
    }
  }
  return (Update-MacOsCatalog)
}

# Die macOS-PKG-Apps dieses Tenants, jede mit ihrer Marke - die Grundlage fuer "gibt es das schon?".
#
# Gefiltert wird ORTLICH nach @odata.type, nicht ueber einen abgeleiteten Pfad: manche Tenants
# beantworten /mobileApps/microsoft.graph.macOSPkgApp mit HTTP 400. Denselben Weg geht Teil 25 fuer
# die Win32-Apps, aus demselben Grund.
function Get-TenantMacOsPkgApps {
  $token = Get-WtToken -ErrorAction Stop
  if ([string]::IsNullOrWhiteSpace([string]$token)) { throw 'WinTuner returned an empty access token.' }
  $headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
  $uri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?`$top=100"
  $apps = [Collections.Generic.List[hashtable]]::new()
  $pages = 0
  while ($uri -and $pages -lt 100) {
    if ($script:cancelBatch) { break }
    $resp = Invoke-GraphRest -Uri $uri -Method GET -Headers $headers -Context 'list macOS pkg apps' -MaxRetries 2
    foreach ($app in @($resp.value)) {
      $odataType = [string]$app.'@odata.type'
      if (-not [string]::Equals($odataType.TrimStart([char]'#'), 'microsoft.graph.macOSPkgApp', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
      $marker = Read-MacOsAppMarker -Notes ([string]$app.notes)
      $apps.Add(@{
        Id            = [string]$app.id
        DisplayName   = [string]$app.displayName
        Notes         = [string]$app.notes
        BundleId      = [string]$app.primaryBundleId
        BundleVersion = [string]$app.primaryBundleVersion
        CaskToken     = $(if ($marker) { [string]$marker.Token } else { '' })
        CaskVersion   = $(if ($marker) { [string]$marker.Version } else { '' })
      })
    }
    $uri = [string]$resp.'@odata.nextLink'
    $pages++
  }
  Write-Log ("Tenant inventory: {0} macOS pkg app(s), {1} of them carry a WtMac marker." -f
    $apps.Count, @($apps | Where-Object { $_.CaskToken }).Count)
  return , $apps.ToArray()
}

# Sucht die bereits bereitgestellte App zu einem Katalogeintrag. Ueber die MARKE, nicht ueber den
# Anzeigenamen: den kann jemand im Portal umbenennen, und dann legte ein Update eine zweite App an.
function Find-DeployedMacOsApp {
  param(
    [object[]]$TenantApps,
    [Parameter(Mandatory)][AllowEmptyString()][string]$CaskToken
  )
  # Ein leerer Token passt auf JEDE App ohne Marke - und das sind genau die, die von Hand oder von
  # jemand anderem angelegt wurden. Ohne diesen Riegel ersetzte ein Update den Inhalt einer App,
  # die diese Anwendung nie bereitgestellt hat. Der Parameter liess vorher nur deshalb nichts
  # Leeres durch, weil Mandatory den Bindungsversuch abwies - also durch einen Fehler statt durch
  # eine Entscheidung.
  if ([string]::IsNullOrWhiteSpace($CaskToken)) { return $null }
  foreach ($app in $TenantApps) {
    if ([string]::IsNullOrWhiteSpace([string]$app.CaskToken)) { continue }
    if ([string]$app.CaskToken -eq $CaskToken) { return $app }
  }
  return $null
}

# Laedt ein Paket herunter. Blockweise, damit der Fortschritt sichtbar und der Abbruch wirksam ist -
# Office ist ueber 600 MB, und ein Invoke-WebRequest -OutFile darauf ist ein eingefrorenes Fenster.
#
# Ist ein Hash bekannt, wird er GEPRUEFT und die Datei bei Abweichung geloescht. Ist keiner bekannt
# (Ueberschreibeintraege und die 44 Casks mit 'no_check'), sagt das Ergebnis das ausdruecklich -
# der Aufrufer soll nicht glauben, es sei geprueft worden.
function Invoke-MacOsPackageDownload {
  param(
    [Parameter(Mandatory)][string]$Url,
    [Parameter(Mandatory)][string]$TargetFile,
    [string]$ExpectedSha256 = ''
  )
  $out = @{ Success = $false; ErrorMessage = ''; Path = $TargetFile; Bytes = 0; HashVerified = $false }
  $client = $null; $response = $null; $source = $null; $target = $null
  try {
    $client = [System.Net.Http.HttpClient]::new()
    $client.Timeout = [TimeSpan]::FromMinutes(30)
    $response = $client.GetAsync($Url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    if (-not $response.IsSuccessStatusCode) {
      throw ("The download answered HTTP {0} ({1})." -f [int]$response.StatusCode, $response.ReasonPhrase)
    }
    $total = [int64]0
    if ($response.Content.Headers.ContentLength) { $total = [int64]$response.Content.Headers.ContentLength }

    $source = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    $target = [System.IO.File]::Open($TargetFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
    $buffer = [byte[]]::new(1024 * 1024)
    $done = [int64]0
    while ($true) {
      if ($script:cancelBatch) { throw 'Download cancelled.' }
      $read = $source.Read($buffer, 0, $buffer.Length)
      if ($read -le 0) { break }
      $target.Write($buffer, 0, $read)
      $done += $read
      try {
        Update-Status ((Get-UiString 'MacPkgDownloadProgressStatus') -f
          [math]::Round($done / 1MB), $(if ($total -gt 0) { [math]::Round($total / 1MB) } else { '?' })) -NoLog
      } catch { }
      try { [System.Windows.Forms.Application]::DoEvents() } catch { }
    }
    $target.Dispose(); $target = $null
    $out.Bytes = $done

    if ($ExpectedSha256) {
      $actual = (Get-FileHash -LiteralPath $TargetFile -Algorithm SHA256).Hash
      if (-not [string]::Equals($actual, $ExpectedSha256, [StringComparison]::OrdinalIgnoreCase)) {
        # Die Datei ist nicht die erwartete. Sie stehen zu lassen hiesse, dass sie beim naechsten
        # Versuch als fertiger Download herumliegt.
        Remove-Item -LiteralPath $TargetFile -Force -ErrorAction SilentlyContinue
        throw ("The downloaded file does not match the expected SHA256 (expected {0}, got {1})." -f $ExpectedSha256, $actual)
      }
      $out.HashVerified = $true
    }
    $out.Success = $true
    Write-Log ("Downloaded {0} ({1:n1} MB, hash {2})." -f $Url, ($done / 1MB),
      $(if ($out.HashVerified) { 'verified' } elseif ($ExpectedSha256) { 'mismatch' } else { 'not published by the catalogue' }))
    return $out
  } catch {
    $out.ErrorMessage = $_.Exception.Message
    Write-Log ("Download FAILED for {0}: {1}" -f $Url, $out.ErrorMessage)
    return $out
  } finally {
    if ($target) { try { $target.Dispose() } catch { } }
    if ($source) { try { $source.Dispose() } catch { } }
    if ($response) { try { $response.Dispose() } catch { } }
    if ($client) { try { $client.Dispose() } catch { } }
  }
}
