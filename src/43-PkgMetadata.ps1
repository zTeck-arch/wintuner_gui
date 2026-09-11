# ==================================================================================================
# Teil 43: Metadaten aus einer macOS-.pkg lesen (Beta)
# ==================================================================================================
#
# Wozu: macOSPkgApp braucht primaryBundleId, primaryBundleVersion und includedApps - ohne diese
# Felder legt Intune die App an und erkennt sie auf dem Geraet nie, also installiert sie bei jedem
# Durchlauf neu. Auf einem Mac beantwortet "installer -pkginfo" das; unter Windows gibt es kein
# Werkzeug dafuer, also wird das Archiv hier selbst gelesen.
#
# Eine .pkg ist ein xar-Archiv:
#
#   [ Kopf, 28 Byte ][ TOC, zlib-komprimiertes XML ][ Heap: die Dateien, einzeln komprimiert ]
#
# Der Kopf nennt die Laenge des TOC, das TOC nennt Name, Offset und Laenge jeder Datei im Heap.
# Gebraucht werden genau zwei davon, beide unter 2 KB: "Distribution" und "PackageInfo". Der
# Payload - bei Google Chrome 252 MB - wird nie angefasst; es waere die einzige Stelle der
# Anwendung, die ein Viertel Gigabyte durch den Speicher zieht.
#
# Zwei Formen kommen vor:
#   - Produktarchiv (was Hersteller ausliefern): hat "Distribution" UND je Teilpaket "PackageInfo".
#     Distribution nennt in <bundle-version> ALLE enthaltenen Apps - das ist includedApps.
#   - Komponentenpaket: hat nur "PackageInfo". Dann liefert dessen <bundle> die eine App.
# Deshalb erst Distribution, dann PackageInfo als Rueckfall.
#
# Eine .pkg ist eine Datei aus dem Internet, also nichts, dem man traut: die Groessenangaben im
# Kopf werden begrenzt, bevor etwas belegt wird, und das XML wird ohne DTD-Verarbeitung gelesen
# (sonst waere eine praeparierte .pkg ein Weg, die Anwendung Dateien nachladen zu lassen).

# 8 MiB TOC sind schon absurd viel - das reale Chrome-Paket braucht 4,5 KB. Die Zahl kommt aus dem
# Dateikopf, ist also von der Datei bestimmt und nicht von uns: ohne Grenze waere eine handvoll
# praeparierter Bytes eine Belegung von mehreren GB.
$script:xarMaxTocBytes = 8 * 1024 * 1024
# Dieselbe Vorsicht fuer das Entpacken: ein zlib-Strom von wenigen Byte kann sich auf Gigabyte
# aufblasen. Kein echtes Distribution/PackageInfo ist ueber 4 MiB.
$script:xarMaxEntryBytes = 4 * 1024 * 1024

# Die Werte, die Graph fuer macOSMinimumOperatingSystem kennt. Mehr gibt es nicht; was daneben
# liegt, wird ABGERUNDET (siehe Get-MacOsMinimumOsProperty).
$script:macOsMinimumVersions = @(
  @{ Version = [version]'10.7';  Property = 'v10_7' }
  @{ Version = [version]'10.8';  Property = 'v10_8' }
  @{ Version = [version]'10.9';  Property = 'v10_9' }
  @{ Version = [version]'10.10'; Property = 'v10_10' }
  @{ Version = [version]'10.11'; Property = 'v10_11' }
  @{ Version = [version]'10.12'; Property = 'v10_12' }
  @{ Version = [version]'10.13'; Property = 'v10_13' }
  @{ Version = [version]'10.14'; Property = 'v10_14' }
  @{ Version = [version]'10.15'; Property = 'v10_15' }
  @{ Version = [version]'11.0';  Property = 'v11_0' }
  @{ Version = [version]'12.0';  Property = 'v12_0' }
  @{ Version = [version]'13.0';  Property = 'v13_0' }
  @{ Version = [version]'14.0';  Property = 'v14_0' }
  @{ Version = [version]'15.0';  Property = 'v15_0' }
)

# Uebersetzt "13.0" aus dem Paket in den Graph-Namen "v13_0".
#
# Abgerundet wird bewusst: Ein Paket mit minimumSystemVersion 13.5 bekommt v13_0, nicht v14_0.
# Aufrunden hiesse, allen Geraeten zwischen 13.0 und 13.5 die App gar nicht anzubieten - und die
# .pkg bringt ihre eigene volume-check-Bedingung mit, weigert sich auf einem zu alten System also
# selbst. Der umgekehrte Fehler waere eine App, die einem Teil der Flotte unsichtbar bleibt, ohne
# dass jemand sieht warum.
function Get-MacOsMinimumOsProperty {
  param([string]$Version)
  if ([string]::IsNullOrWhiteSpace($Version)) { return '' }
  $parsed = $null
  # "13" allein ist kein [version]; erst "13.0" laesst sich lesen.
  $text = if ($Version -notmatch '\.') { "$Version.0" } else { $Version }
  if (-not [version]::TryParse($text, [ref]$parsed)) { return '' }
  $match = ''
  foreach ($entry in $script:macOsMinimumVersions) {
    if ($parsed -ge $entry.Version) { $match = $entry.Property } else { break }
  }
  # Aelter als alles, was Graph kennt: dann der niedrigste Wert, nicht leer - sonst legt der
  # Aufrufer eine App ohne Mindestanforderung an.
  if (-not $match) { $match = $script:macOsMinimumVersions[0].Property }
  return $match
}

# Liest Kopf und Inhaltsverzeichnis. Gibt das TOC-XML und den Heap-Anfang zurueck; der Strom bleibt
# offen und gehoert weiter dem Aufrufer.
function Read-XarToc {
  param(
    [Parameter(Mandatory)][System.IO.Stream]$Stream
  )
  $header = [byte[]]::new(28)
  if ($Stream.Read($header, 0, 28) -lt 28) { throw 'Not a .pkg file: it is too short to hold a xar header.' }
  if ($header[0] -ne 0x78 -or $header[1] -ne 0x61 -or $header[2] -ne 0x72 -or $header[3] -ne 0x21) {
    throw 'Not a .pkg file: the xar signature is missing.'
  }
  # xar speichert alle Zahlen in Big-Endian - die Reihenfolge, die Intel-Rechner NICHT verwenden.
  $headerSize = [int](Get-BigEndianValue -Bytes $header -Offset 4 -Count 2)
  $tocCompressed = [int64](Get-BigEndianValue -Bytes $header -Offset 8 -Count 8)
  if ($headerSize -lt 28 -or $tocCompressed -le 0) { throw 'The xar header is malformed.' }
  if ($tocCompressed -gt $script:xarMaxTocBytes) {
    throw ("The xar table of contents claims {0} bytes, which is beyond anything a real .pkg needs." -f $tocCompressed)
  }

  [void]$Stream.Seek($headerSize, [System.IO.SeekOrigin]::Begin)
  $compressed = [byte[]]::new($tocCompressed)
  if ($Stream.Read($compressed, 0, [int]$tocCompressed) -lt $tocCompressed) {
    throw 'The xar table of contents is truncated.'
  }
  $xmlText = Expand-ZlibBytes -Data $compressed -MaxBytes $script:xarMaxEntryBytes
  return @{
    Toc      = (ConvertTo-SafeXml -Text $xmlText)
    HeapBase = [int64]($headerSize + $tocCompressed)
  }
}

# Big-Endian, weil xar es so ablegt. [BitConverter] liest auf dieser Maschine Little-Endian und
# haette den Kopf lautlos falsch gedeutet.
function Get-BigEndianValue {
  param(
    [Parameter(Mandatory)][byte[]]$Bytes,
    [Parameter(Mandatory)][int]$Offset,
    [Parameter(Mandatory)][int]$Count
  )
  $value = [uint64]0
  for ($i = 0; $i -lt $Count; $i++) { $value = ($value -shl 8) -bor $Bytes[$Offset + $i] }
  return $value
}

# Entpackt einen zlib-Strom mit Obergrenze. CopyTo ohne Grenze waere der Punkt, an dem eine
# praeparierte Datei den Arbeitsspeicher belegt.
function Expand-ZlibBytes {
  param(
    [Parameter(Mandatory)][byte[]]$Data,
    [int]$MaxBytes = 0
  )
  $limit = if ($MaxBytes -gt 0) { $MaxBytes } else { $script:xarMaxEntryBytes }
  # NICHT $input: das ist eine automatische Variable (die Pipeline-Eingabe der Funktion) und eine
  # Zuweisung darauf ueberschreibt sie.
  $inputStream = [System.IO.MemoryStream]::new($Data)
  $output = [System.IO.MemoryStream]::new()
  $zlib = $null
  try {
    $zlib = [System.IO.Compression.ZLibStream]::new($inputStream, [System.IO.Compression.CompressionMode]::Decompress)
    $buffer = [byte[]]::new(64 * 1024)
    while ($true) {
      $read = $zlib.Read($buffer, 0, $buffer.Length)
      if ($read -le 0) { break }
      if (($output.Length + $read) -gt $limit) {
        throw ("A .pkg entry expands past the {0} byte limit; refusing to read it." -f $limit)
      }
      $output.Write($buffer, 0, $read)
    }
    return [System.Text.Encoding]::UTF8.GetString($output.ToArray())
  } finally {
    if ($zlib) { try { $zlib.Dispose() } catch { } }
    try { $inputStream.Dispose() } catch { }
    try { $output.Dispose() } catch { }
  }
}

# Liest XML OHNE DTD-Verarbeitung und ohne externe Aufloesung.
#
# Der schlichte [xml]-Cast erlaubt je nach Laufzeit eine DTD. Eine praeparierte .pkg koennte damit
# eine Entitaet definieren, die auf eine lokale Datei oder eine URL zeigt - und die Anwendung
# liest .pkg-Dateien, die der Techniker irgendwo heruntergeladen hat.
function ConvertTo-SafeXml {
  param([Parameter(Mandatory)][string]$Text)
  $settings = [System.Xml.XmlReaderSettings]::new()
  $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
  $settings.XmlResolver = $null
  $reader = $null
  try {
    $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($Text), $settings)
    $document = [System.Xml.XmlDocument]::new()
    $document.XmlResolver = $null
    $document.Load($reader)
    return $document
  } finally {
    if ($reader) { try { $reader.Dispose() } catch { } }
  }
}

# Holt EINE Datei aus dem Heap und gibt ihren Text zurueck. $null, wenn sie nicht im Archiv steht -
# "Distribution" fehlt bei Komponentenpaketen voellig, und das ist kein Fehler.
function Get-XarEntryText {
  param(
    [Parameter(Mandatory)][System.IO.Stream]$Stream,
    [Parameter(Mandatory)][System.Xml.XmlDocument]$Toc,
    [Parameter(Mandatory)][int64]$HeapBase,
    [Parameter(Mandatory)][string]$Name
  )
  foreach ($node in $Toc.SelectNodes('//file')) {
    $nameNode = $node.SelectSingleNode('name')
    if (-not $nameNode -or $nameNode.InnerText -ne $Name) { continue }
    $data = $node.SelectSingleNode('data')
    if (-not $data) { continue }
    $offset = [int64]$data.SelectSingleNode('offset').InnerText
    $length = [int64]$data.SelectSingleNode('length').InnerText
    if ($length -le 0 -or $length -gt $script:xarMaxEntryBytes) { continue }
    [void]$Stream.Seek($HeapBase + $offset, [System.IO.SeekOrigin]::Begin)
    $raw = [byte[]]::new($length)
    if ($Stream.Read($raw, 0, [int]$length) -lt $length) { continue }
    $style = ''
    $encoding = $data.SelectSingleNode('encoding')
    if ($encoding) { $style = [string]$encoding.GetAttribute('style') }
    # xar nennt zlib-Daten "application/x-gzip"; unkomprimierte Eintraege haben
    # "application/octet-stream". Beides kommt in echten Paketen vor.
    if ($style -match 'gzip|zlib') { return (Expand-ZlibBytes -Data $raw) }
    return [System.Text.Encoding]::UTF8.GetString($raw)
  }
  return $null
}

# --- Die Auswertung ------------------------------------------------------------------------------

# Liest die Apps aus dem Distribution-XML eines Produktarchivs.
function Get-PkgAppsFromDistribution {
  param([Parameter(Mandatory)][System.Xml.XmlDocument]$Distribution)
  $apps = [Collections.Generic.List[hashtable]]::new()
  foreach ($bundle in $Distribution.SelectNodes('//bundle-version/bundle')) {
    $id = [string]$bundle.GetAttribute('id')
    if ([string]::IsNullOrWhiteSpace($id)) { continue }
    $apps.Add(@{
      BundleId     = $id
      ShortVersion = [string]$bundle.GetAttribute('CFBundleShortVersionString')
      BuildVersion = [string]$bundle.GetAttribute('CFBundleVersion')
      Path         = [string]$bundle.GetAttribute('path')
    })
  }
  return $apps
}

# Liest die App aus dem PackageInfo eines Komponentenpakets.
function Get-PkgAppsFromPackageInfo {
  param([Parameter(Mandatory)][System.Xml.XmlDocument]$PackageInfo)
  $apps = [Collections.Generic.List[hashtable]]::new()
  foreach ($bundle in $PackageInfo.SelectNodes('/pkg-info/bundle')) {
    $id = [string]$bundle.GetAttribute('id')
    if ([string]::IsNullOrWhiteSpace($id)) { continue }
    $apps.Add(@{
      BundleId     = $id
      ShortVersion = [string]$bundle.GetAttribute('CFBundleShortVersionString')
      BuildVersion = [string]$bundle.GetAttribute('CFBundleVersion')
      Path         = [string]$bundle.GetAttribute('path')
    })
  }
  return $apps
}

# Alles, was die Metadatenkarte und der Upload brauchen - in einem Durchgang.
#
# Wirft NICHT: eine unlesbare .pkg ist ein Fall fuer die Oberflaeche (Felder leer, Techniker tippt),
# kein Abbruch. Der Grund steht in ErrorMessage.
function Get-MacOsPkgMetadata {
  param([Parameter(Mandatory)][string]$PkgFile)
  $out = @{
    Success             = $false
    ErrorMessage        = ''
    Title               = ''
    PrimaryBundleId     = ''
    ShortVersion        = ''
    BuildVersion        = ''
    IncludedApps        = @()
    MinimumSystemVersion = ''
    MinimumOsProperty   = ''
    HasInstallScripts   = $false
    Source              = ''
  }
  if (-not (Test-Path -LiteralPath $PkgFile -PathType Leaf)) {
    $out.ErrorMessage = (Get-UiString 'MacPkgFileMissing')
    return $out
  }
  $stream = $null
  try {
    $stream = [System.IO.File]::OpenRead($PkgFile)
    $toc = Read-XarToc -Stream $stream

    $distributionText = Get-XarEntryText -Stream $stream -Toc $toc.Toc -HeapBase $toc.HeapBase -Name 'Distribution'
    $packageInfoText = Get-XarEntryText -Stream $stream -Toc $toc.Toc -HeapBase $toc.HeapBase -Name 'PackageInfo'
    if (-not $distributionText -and -not $packageInfoText) {
      $out.ErrorMessage = (Get-UiString 'MacPkgNoMetadata')
      return $out
    }

    $apps = [Collections.Generic.List[hashtable]]::new()
    if ($distributionText) {
      $distribution = ConvertTo-SafeXml -Text $distributionText
      $out.Source = 'Distribution'
      $titleNode = $distribution.SelectSingleNode('//title')
      if ($titleNode) { $out.Title = $titleNode.InnerText.Trim() }
      foreach ($app in (Get-PkgAppsFromDistribution -Distribution $distribution)) { $apps.Add($app) }
      # Die Mindestversion steht im volume-check, nicht bei den Bundles.
      $osNode = $distribution.SelectSingleNode('//allowed-os-versions/os-version')
      if ($osNode) { $out.MinimumSystemVersion = [string]$osNode.GetAttribute('min') }
    }

    if ($packageInfoText) {
      $packageInfo = ConvertTo-SafeXml -Text $packageInfoText
      if (-not $out.Source) { $out.Source = 'PackageInfo' }
      $info = $packageInfo.SelectSingleNode('/pkg-info')
      if ($info) {
        if (-not $out.MinimumSystemVersion) { $out.MinimumSystemVersion = [string]$info.GetAttribute('minimumSystemVersion') }
        # Pre-/Postinstall laufen als root. Das ist Sache des Herstellers, gehoert aber in die
        # Warnkarte - der Techniker soll wissen, dass er mehr hochlaedt als eine App.
        if ($packageInfo.SelectSingleNode('/pkg-info/scripts/*')) { $out.HasInstallScripts = $true }
      }
      # Nur ergaenzen, was Distribution nicht schon hatte: dort steht die vollstaendige Liste.
      if ($apps.Count -eq 0) {
        foreach ($app in (Get-PkgAppsFromPackageInfo -PackageInfo $packageInfo)) { $apps.Add($app) }
      }
      # Ohne jede Bundle-Angabe bleibt der identifier des Pakets als letzte Auskunft.
      if ($apps.Count -eq 0 -and $info) {
        $identifier = [string]$info.GetAttribute('identifier')
        if ($identifier) {
          $apps.Add(@{
            BundleId     = $identifier
            ShortVersion = [string]$info.GetAttribute('version')
            BuildVersion = ''
            Path         = ''
          })
        }
      }
    }

    if ($apps.Count -eq 0) {
      $out.ErrorMessage = (Get-UiString 'MacPkgNoBundle')
      return $out
    }

    # Die erste App ist die Hauptanwendung: Distribution listet sie in der Reihenfolge der
    # choices-outline, und bei einem Komponentenpaket gibt es nur eine.
    $primary = $apps[0]
    $out.PrimaryBundleId = $primary.BundleId
    $out.ShortVersion = $primary.ShortVersion
    $out.BuildVersion = $primary.BuildVersion
    $out.IncludedApps = @($apps)
    $out.MinimumOsProperty = Get-MacOsMinimumOsProperty -Version $out.MinimumSystemVersion
    $out.Success = $true
    Write-Log ("Read .pkg metadata from {0}: {1} {2} (build {3}), {4} bundle(s), min macOS {5}." -f
      $out.Source, $out.PrimaryBundleId, $out.ShortVersion, $out.BuildVersion, $apps.Count, $out.MinimumSystemVersion)
    return $out
  } catch {
    $out.ErrorMessage = $_.Exception.Message
    Write-Log ("Could not read .pkg metadata from '{0}': {1}" -f $PkgFile, $out.ErrorMessage)
    return $out
  } finally {
    if ($stream) { try { $stream.Dispose() } catch { } }
  }
}
