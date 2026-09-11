#requires -Version 7
<#
.SYNOPSIS
  Erzeugt sample-app.pkg - das Fixture, gegen das der PKG-Leser in jeder Pruefkette laeuft.

.DESCRIPTION
  Ein echtes xar-Archiv in der Form, die Hersteller ausliefern (Produktarchiv mit Distribution und
  einem Teilpaket-Verzeichnis darin), aber mit einer erfundenen Anwendung und ohne Payload. Daher
  wenige KB statt der 252 MB eines echten Google-Chrome-Pakets, und ohne Hersteller-Material im
  Repository.

  Bewusst NICHT im Test selbst erzeugt: dann prueefte der Leser gegen die Auffassung des Erzeugers
  vom xar-Format, und beide stammen von derselben Hand. So liegt eine Datei im Repository, die
  einmal gegen ein ECHTES Paket abgeglichen wurde (tests/Unit/PkgMetadata.Tests.ps1 prueft gegen
  GoogleChrome.pkg, wenn sie auf dem Rechner liegt).

  Die Werte sind mit Absicht anders als bei Chrome:
    - zwei Bundles, damit includedApps mit mehr als einem Eintrag geprueft wird
    - minimumSystemVersion 12.3, das Graph NICHT kennt - prueft das Abrunden auf v12_0
    - CFBundleShortVersionString und CFBundleVersion verschieden, wie in der Wirklichkeit

.NOTES
  Erneuern: pwsh -NoProfile -File tests/Fixtures/New-SamplePkg.ps1
#>
[CmdletBinding()]
param(
  [string]$OutFile = (Join-Path $PSScriptRoot 'sample-app.pkg')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$distribution = @'
<?xml version="1.0" encoding="utf-8" standalone="yes"?>
<installer-gui-script minSpecVersion="2">
    <title>Sample App</title>
    <options customize="never" require-scripts="false" hostArchitectures="x86_64,arm64"/>
    <volume-check>
        <allowed-os-versions>
            <os-version min="12.3"/>
        </allowed-os-versions>
    </volume-check>
    <choices-outline>
        <line choice="default">
            <line choice="com.example.SampleApp"/>
        </line>
    </choices-outline>
    <choice id="default"/>
    <choice id="com.example.SampleApp" visible="false" title="Sample App">
        <pkg-ref id="com.example.SampleApp"/>
    </choice>
    <pkg-ref id="com.example.SampleApp" version="4.2.1" installKBytes="1024">#SampleApp.pkg</pkg-ref>
    <pkg-ref id="com.example.SampleApp">
        <bundle-version>
            <bundle CFBundleShortVersionString="4.2.1" CFBundleVersion="4201" id="com.example.SampleApp" path="Sample App.app"/>
            <bundle CFBundleShortVersionString="1.0.7" CFBundleVersion="107" id="com.example.SampleHelper" path="Sample App.app/Contents/Helpers/Helper.app"/>
        </bundle-version>
    </pkg-ref>
    <product id="com.example.SampleApp" version="4.2.1"/>
</installer-gui-script>
'@

$packageInfo = @'
<?xml version="1.0" encoding="utf-8"?>
<pkg-info overwrite-permissions="true" relocatable="false" identifier="com.example.SampleApp" postinstall-action="none" version="4.2.1" format-version="2" install-location="/Applications" auth="root" minimumSystemVersion="12.3">
    <payload numberOfFiles="12" installKBytes="1024"/>
    <bundle path="./Sample App.app" id="com.example.SampleApp" CFBundleShortVersionString="4.2.1" CFBundleVersion="4201"/>
    <bundle-version>
        <bundle id="com.example.SampleApp"/>
    </bundle-version>
    <scripts>
        <postinstall file="./postinstall"/>
    </scripts>
</pkg-info>
'@

# Ein Bom-Ersatz: unkomprimiert abgelegt, damit der Leser auch den Zweig
# "application/octet-stream" zu sehen bekommt und nicht nur den zlib-Zweig.
$bomStub = "not a real bom, just bytes`n"

function Compress-Zlib {
  param([Parameter(Mandatory)][byte[]]$Data)
  $output = [System.IO.MemoryStream]::new()
  $zlib = [System.IO.Compression.ZLibStream]::new($output, [System.IO.Compression.CompressionLevel]::Optimal, $true)
  try { $zlib.Write($Data, 0, $Data.Length) } finally { $zlib.Dispose() }
  $bytes = $output.ToArray()
  $output.Dispose()
  return $bytes
}

function Set-BigEndian {
  param(
    [Parameter(Mandatory)][System.IO.Stream]$Stream,
    [Parameter(Mandatory)][uint64]$Value,
    [Parameter(Mandatory)][int]$Count
  )
  for ($i = $Count - 1; $i -ge 0; $i--) {
    $Stream.WriteByte([byte](($Value -shr ($i * 8)) -band 0xFF))
  }
}

# --- Heap zusammensetzen -------------------------------------------------------------------------
# Jeder Eintrag merkt sich seinen Offset IM HEAP; das TOC nennt genau diese Zahlen.
$heap = [System.IO.MemoryStream]::new()
$entries = [Collections.Generic.List[hashtable]]::new()

function Add-HeapEntry {
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$Text,
    [switch]$Uncompressed
  )
  $plain = [System.Text.Encoding]::UTF8.GetBytes($Text)
  $stored = if ($Uncompressed) { $plain } else { Compress-Zlib -Data $plain }
  $offset = $heap.Position
  $heap.Write($stored, 0, $stored.Length)
  $entries.Add(@{
    Name     = $Name
    Offset   = [int64]$offset
    Length   = [int64]$stored.Length
    Size     = [int64]$plain.Length
    Encoding = if ($Uncompressed) { 'application/octet-stream' } else { 'application/x-gzip' }
  })
}

Add-HeapEntry -Name 'Distribution' -Text $distribution
Add-HeapEntry -Name 'PackageInfo' -Text $packageInfo
Add-HeapEntry -Name 'Bom' -Text $bomStub -Uncompressed
$heapBytes = $heap.ToArray()
$heap.Dispose()

# --- TOC bauen -----------------------------------------------------------------------------------
# Die Schachtelung ahmt ein echtes Produktarchiv nach: Distribution liegt oben, PackageInfo und Bom
# in einem Verzeichnis mit dem Namen des Teilpakets.
$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
[void]$sb.AppendLine('<xar><toc>')
$id = 1
function Format-FileNode {
  param([hashtable]$Entry, [int]$Id, [string]$Indent)
  $node = [System.Text.StringBuilder]::new()
  [void]$node.AppendLine("$Indent<file id=`"$Id`">")
  [void]$node.AppendLine("$Indent  <name>$($Entry.Name)</name>")
  [void]$node.AppendLine("$Indent  <type>file</type>")
  [void]$node.AppendLine("$Indent  <data>")
  [void]$node.AppendLine("$Indent    <offset>$($Entry.Offset)</offset>")
  [void]$node.AppendLine("$Indent    <size>$($Entry.Size)</size>")
  [void]$node.AppendLine("$Indent    <length>$($Entry.Length)</length>")
  [void]$node.AppendLine("$Indent    <encoding style=`"$($Entry.Encoding)`"/>")
  [void]$node.AppendLine("$Indent  </data>")
  [void]$node.AppendLine("$Indent</file>")
  return $node.ToString()
}
[void]$sb.Append((Format-FileNode -Entry $entries[0] -Id ($id++) -Indent '  '))
[void]$sb.AppendLine("  <file id=`"$($id++)`">")
[void]$sb.AppendLine('    <name>SampleApp.pkg</name>')
[void]$sb.AppendLine('    <type>directory</type>')
[void]$sb.Append((Format-FileNode -Entry $entries[1] -Id ($id++) -Indent '    '))
[void]$sb.Append((Format-FileNode -Entry $entries[2] -Id ($id++) -Indent '    '))
[void]$sb.AppendLine('  </file>')
[void]$sb.AppendLine('</toc></xar>')

$tocPlain = [System.Text.Encoding]::UTF8.GetBytes($sb.ToString())
$tocCompressed = Compress-Zlib -Data $tocPlain

# --- Datei schreiben -----------------------------------------------------------------------------
$out = [System.IO.File]::Open($OutFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
try {
  $out.Write([System.Text.Encoding]::ASCII.GetBytes('xar!'), 0, 4)
  Set-BigEndian -Stream $out -Value 28 -Count 2                              # Kopfgroesse
  Set-BigEndian -Stream $out -Value 1 -Count 2                               # Version
  Set-BigEndian -Stream $out -Value ([uint64]$tocCompressed.Length) -Count 8
  Set-BigEndian -Stream $out -Value ([uint64]$tocPlain.Length) -Count 8
  # Pruefsummenverfahren 0 = keines. Echte Pakete nennen hier SHA1 und legen die Summe in den Heap;
  # der Leser wertet sie nicht aus, und ein Fixture ohne sie ist ehrlicher als eine erfundene.
  Set-BigEndian -Stream $out -Value 0 -Count 4
  $out.Write($tocCompressed, 0, $tocCompressed.Length)
  $out.Write($heapBytes, 0, $heapBytes.Length)
} finally { $out.Dispose() }

Write-Host ("Fixture written: {0} ({1} bytes, TOC {2} -> {3})" -f
  $OutFile, (Get-Item -LiteralPath $OutFile).Length, $tocCompressed.Length, $tocPlain.Length)
