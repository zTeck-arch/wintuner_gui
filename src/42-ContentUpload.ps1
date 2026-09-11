# ==================================================================================================
# Teil 42: Inhalts-Upload nach Intune von Hand (Grundlage fuer macOS-PKG, Beta)
# ==================================================================================================
#
# Warum dieser Teil existiert: Fuer Win32 macht das WinTuner-Modul den Upload vollstaendig
# (Deploy-WtWin32App beim Anlegen, Deploy-WtWin32ContentVersion beim Ersetzen) - in der GUI stand
# dafuer bis hierher keine einzige Zeile. Das Modul kennt aber ausschliesslich win32LobApp. Fuer
# macOSPkgApp gibt es kein Cmdlet, also laeuft hier der dokumentierte LOB-Weg selbst:
#
#   contentVersions anlegen -> Datei anmelden -> auf die SAS-URL warten -> verschluesselt in
#   Bloecken in den Azure-Blob -> Blockliste -> commit -> auf commitFileSuccess warten ->
#   committedContentVersion an der App setzen.
#
# Der Weg ist fuer BEIDE App-Typen derselbe, deshalb nimmt Publish-MobileAppContentVersion den
# OData-Typ als Parameter. Fuer Win32 wird er bewusst NICHT benutzt: dort bleibt das Modul
# zustaendig, weil es dort erprobt ist und ein zweiter Weg nur eine zweite Fehlerquelle waere.
#
# Und der Grund fuer die Beta-Kennzeichnung im Fenster: Verschluesselung, Blockliste und
# Zustandsautomat sind hier unter Windows vollstaendig pruefbar - das ERGEBNIS nicht. Ob die App
# auf einem Mac wirklich installiert, sieht man erst auf dem Geraet. Jede Annahme dieses Teils ist
# deshalb als Test hinterlegt, damit wenigstens das Pruefbare geprueft ist.

# 6 MiB je Block: der von Microsoft in den eigenen Beispielen verwendete Wert. Groesser heisst
# weniger Anfragen, aber auch, dass ein Abbruch erst nach einem ganzen Block greift.
$script:blobBlockSize = 6 * 1024 * 1024
# Ein einzelner Block darf lange brauchen (6 MiB ueber eine schlechte Leitung), der Graph-Zeitablauf
# von wenigen Sekunden passt hier nicht. Ohne Angabe wartete Invoke-WebRequest unbegrenzt.
$script:blobBlockTimeoutSeconds = 300
# Faellt die SAS-URL waehrend des Uploads unter diese Restlaufzeit, wird sie erneuert. Ein Upload,
# dem die URL mitten im Blockschreiben ablaeuft, endet mit HTTP 403 und verliert alle Bloecke.
$script:blobSasRenewalMinutes = 10

# --- Verschluesselung ---------------------------------------------------------------------------
#
# Intune erwartet das Schema "ProfileVersion1". Der Aufbau der hochgeladenen Datei ist:
#
#   [ HMAC-SHA256, 32 Byte ][ IV, 16 Byte ][ AES-256-CBC/PKCS7 der Nutzdaten ]
#
# Der HMAC laeuft ueber IV + Chiffrat, also ueber alles NACH den ersten 32 Byte, und wird
# anschliessend an den Anfang zurueckgeschrieben. Der fileDigest dagegen ist der SHA256 der
# UNVERSCHLUESSELTEN Datei - eine Verwechslung der beiden ergibt eine App, die Intune ohne Murren
# annimmt und die auf dem Geraet scheitert.
function New-IntuneContentEncryption {
  param(
    [Parameter(Mandatory)][string]$SourceFile,
    [Parameter(Mandatory)][string]$TargetFile
  )
  if (-not (Test-Path -LiteralPath $SourceFile -PathType Leaf)) {
    throw ("Cannot encrypt '{0}': the file does not exist." -f $SourceFile)
  }

  $aes = $null; $hmac = $null; $sha = $null
  $inStream = $null; $outStream = $null; $cryptoStream = $null
  try {
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $aes.KeySize = 256
    $aes.GenerateKey()
    $aes.GenerateIV()

    # Erst fuellen, DANN zuweisen. Der Getter von HMAC.Key gibt eine Kopie zurueck: ein
    # Fill($hmac.Key) wuerde diese Kopie zufaellig machen und den echten Schluessel auf 32
    # Nullbytes stehen lassen - ein MAC-Schluessel, den jeder kennt, ohne jede Fehlermeldung.
    $macKey = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($macKey)
    $hmac = [System.Security.Cryptography.HMACSHA256]::new()
    $hmac.Key = $macKey

    # Der Klartext-Digest wird im selben Durchgang NICHT gebildet: der Strom wird von der
    # Verschluesselung verbraucht. Ein zweites Lesen ist billiger als ein Umweg ueber den Speicher,
    # denn eine .pkg kann mehrere hundert MB haben.
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $inStream = [System.IO.File]::OpenRead($SourceFile)
    $fileDigest = $sha.ComputeHash($inStream)
    $inStream.Dispose(); $inStream = $null

    $outStream = [System.IO.File]::Open($TargetFile, [System.IO.FileMode]::Create,
      [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    # Platzhalter fuer den HMAC. Er ist erst bekannt, wenn das Chiffrat vollstaendig geschrieben
    # wurde, und wird danach an dieselbe Stelle zurueckgeschrieben.
    $outStream.Write([byte[]]::new(32), 0, 32)
    $outStream.Write($aes.IV, 0, $aes.IV.Length)

    $inStream = [System.IO.File]::OpenRead($SourceFile)
    $cryptoStream = [System.Security.Cryptography.CryptoStream]::new(
      $outStream, $aes.CreateEncryptor(), [System.Security.Cryptography.CryptoStreamMode]::Write, $true)
    $inStream.CopyTo($cryptoStream, 1024 * 1024)
    $cryptoStream.FlushFinalBlock()
    $cryptoStream.Dispose(); $cryptoStream = $null
    $inStream.Dispose(); $inStream = $null

    # HMAC ueber IV + Chiffrat, also ab Byte 32 bis zum Ende.
    [void]$outStream.Seek(32, [System.IO.SeekOrigin]::Begin)
    $mac = $hmac.ComputeHash($outStream)
    [void]$outStream.Seek(0, [System.IO.SeekOrigin]::Begin)
    $outStream.Write($mac, 0, $mac.Length)
    $outStream.Flush()
    $encryptedSize = $outStream.Length
    $outStream.Dispose(); $outStream = $null

    return @{
      EncryptedPath = $TargetFile
      EncryptedSize = [int64]$encryptedSize
      PlainSize     = [int64](Get-Item -LiteralPath $SourceFile).Length
      # Genau die Feldnamen, die der commit-Aufruf erwartet.
      EncryptionInfo = @{
        encryptionKey        = [Convert]::ToBase64String($aes.Key)
        macKey               = [Convert]::ToBase64String($macKey)
        initializationVector = [Convert]::ToBase64String($aes.IV)
        mac                  = [Convert]::ToBase64String($mac)
        profileIdentifier    = 'ProfileVersion1'
        fileDigest           = [Convert]::ToBase64String($fileDigest)
        fileDigestAlgorithm  = 'SHA256'
      }
    }
  } finally {
    if ($cryptoStream) { try { $cryptoStream.Dispose() } catch { } }
    if ($inStream) { try { $inStream.Dispose() } catch { } }
    if ($outStream) { try { $outStream.Dispose() } catch { } }
    if ($sha) { try { $sha.Dispose() } catch { } }
    if ($hmac) { try { $hmac.Dispose() } catch { } }
    if ($aes) { try { $aes.Dispose() } catch { } }
  }
}

# --- Blob-Hilfen ---------------------------------------------------------------------------------
#
# Azure verlangt Block-Kennungen GLEICHER Laenge; unterschiedlich lange Kennungen beantwortet der
# Dienst mit HTTP 400, und zwar erst beim Schreiben der Blockliste, wenn alle Daten schon oben sind.
# Deshalb feste Breite und nicht einfach die Zahl.
function Get-BlobBlockId {
  param([Parameter(Mandatory)][int]$Index)
  return [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(("block-{0:D8}" -f $Index)))
}

# Die SAS-URL traegt ihr Ablaufdatum im Dateiobjekt (azureStorageUriExpirationDateTime). Laeuft sie
# mitten im Upload ab, antwortet der Blob mit 403 und die bereits geschriebenen Bloecke sind
# verloren - deshalb VOR jedem Block fragen, nicht danach reagieren.
function Test-SasRenewalDue {
  param(
    [datetime]$ExpiresUtc,
    [datetime]$NowUtc = [datetime]::UtcNow,
    [int]$ThresholdMinutes = 0
  )
  $threshold = if ($ThresholdMinutes -gt 0) { $ThresholdMinutes } else { $script:blobSasRenewalMinutes }
  # Kein Ablaufdatum bekannt: nicht erneuern. Ein unnoetiger renewUpload setzt den Zustand der
  # Datei zurueck und kostet eine weitere Warteschleife.
  if ($ExpiresUtc -eq [datetime]::MinValue) { return $false }
  return ($ExpiresUtc - $NowUtc).TotalMinutes -lt $threshold
}

# Baut die Blockliste, mit der Azure die Einzelbloecke zu einer Datei zusammensetzt. Die Reihenfolge
# IN dieser Liste bestimmt die Reihenfolge der Bytes - nicht die Reihenfolge des Hochladens.
function Get-BlobBlockListXml {
  param([Parameter(Mandatory)][string[]]$BlockIds)
  $sb = [System.Text.StringBuilder]::new()
  [void]$sb.Append('<?xml version="1.0" encoding="utf-8"?><BlockList>')
  foreach ($id in $BlockIds) { [void]$sb.Append('<Latest>').Append($id).Append('</Latest>') }
  [void]$sb.Append('</BlockList>')
  return $sb.ToString()
}

# --- Zustandsautomat der Inhaltsdatei ------------------------------------------------------------
#
# Jeder Schritt des LOB-Weges ist asynchron: der Dienst meldet den Fortschritt ueber uploadState.
# Wer nicht wartet, laedt gegen eine SAS-URL, die noch nicht existiert, oder setzt
# committedContentVersion, bevor der commit durch ist - beides ergibt eine App ohne Inhalt.
function Wait-MobileAppFileState {
  param(
    [Parameter(Mandatory)][string]$FileUri,
    [Parameter(Mandatory)][hashtable]$Headers,
    [Parameter(Mandatory)][string]$SuccessState,
    [Parameter(Mandatory)][string]$FailureState,
    [int]$TimeoutSeconds = 600
  )
  $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
  while ([datetime]::UtcNow -lt $deadline) {
    if ($script:cancelBatch) { throw 'Upload cancelled.' }
    $file = Invoke-GraphRest -Uri $FileUri -Method GET -Headers $Headers `
      -Context ("poll upload state of content file") -MaxRetries 2
    $state = [string]$file.uploadState
    if ($state -eq $SuccessState) { return $file }
    if ($state -eq $FailureState) {
      throw ("Intune reported '{0}' for the content file; the upload cannot continue." -f $state)
    }
    try { [System.Windows.Forms.Application]::DoEvents() } catch { }
    Start-Sleep -Seconds 2
  }
  throw ("Timed out after {0}s waiting for the content file to reach '{1}'." -f $TimeoutSeconds, $SuccessState)
}

# --- Der eigentliche Upload ----------------------------------------------------------------------
#
# Laedt die verschluesselte Datei blockweise in den Azure-Blob. Erneuert die SAS-URL unterwegs,
# wenn sie zu ablaufen droht, und ist zwischen zwei Bloecken abbrechbar.
function Send-BlobBlocks {
  param(
    [Parameter(Mandatory)][string]$EncryptedFile,
    [Parameter(Mandatory)][string]$AzureStorageUri,
    [Parameter(Mandatory)][string]$FileUri,
    [Parameter(Mandatory)][hashtable]$Headers,
    [datetime]$ExpiresUtc = [datetime]::MinValue
  )
  $sasUri = $AzureStorageUri
  $expires = $ExpiresUtc
  $blockIds = [Collections.Generic.List[string]]::new()
  $stream = [System.IO.File]::OpenRead($EncryptedFile)
  try {
    $total = $stream.Length
    $buffer = [byte[]]::new($script:blobBlockSize)
    $index = 0
    while ($true) {
      if ($script:cancelBatch) { throw 'Upload cancelled.' }
      $read = $stream.Read($buffer, 0, $buffer.Length)
      if ($read -le 0) { break }

      if (Test-SasRenewalDue -ExpiresUtc $expires) {
        Write-Log 'Blob: the upload URL is about to expire; renewing it.'
        [void](Invoke-GraphRest -Uri ("{0}/renewUpload" -f $FileUri) -Method POST -Headers $Headers `
          -Context 'renew content file upload URL' -MaxRetries 0)
        $renewed = Wait-MobileAppFileState -FileUri $FileUri -Headers $Headers `
          -SuccessState 'azureStorageUriRenewalSuccess' -FailureState 'azureStorageUriRenewalFailed'
        $sasUri = [string]$renewed.azureStorageUri
        $expires = Get-UtcDateOrMin -Value $renewed.azureStorageUriExpirationDateTime
      }

      $blockId = Get-BlobBlockId -Index $index
      # Ein Bereichsausdruck ($buffer[0..n]) auf einem byte[] liefert in PowerShell ein object[];
      # Invoke-WebRequest schickt daraus nicht die Rohbytes. Deshalb eine echte byte[]-Kopie.
      $chunk = if ($read -eq $buffer.Length) {
        $buffer
      } else {
        $tail = [byte[]]::new($read)
        [System.Array]::Copy($buffer, 0, $tail, 0, $read)
        $tail
      }
      $blockUri = ("{0}&comp=block&blockid={1}" -f $sasUri, [uri]::EscapeDataString($blockId))
      [void](Invoke-WebRequest -Uri $blockUri -Method PUT -Body $chunk `
        -Headers @{ 'x-ms-blob-type' = 'BlockBlob' } -ContentType 'application/octet-stream' `
        -TimeoutSec $script:blobBlockTimeoutSeconds -ErrorAction Stop)
      $blockIds.Add($blockId)
      $index++

      $done = [math]::Min($stream.Position, $total)
      try {
        Update-Status ((Get-UiString 'MacPkgUploadProgressStatus') -f
          [math]::Round($done / 1MB), [math]::Round($total / 1MB)) -NoLog
      } catch { }
      try { [System.Windows.Forms.Application]::DoEvents() } catch { }
    }
  } finally {
    $stream.Dispose()
  }

  $listUri = ("{0}&comp=blocklist" -f $sasUri)
  [void](Invoke-WebRequest -Uri $listUri -Method PUT -Body (Get-BlobBlockListXml -BlockIds $blockIds.ToArray()) `
    -ContentType 'application/xml' -TimeoutSec $script:blobBlockTimeoutSeconds -ErrorAction Stop)
  Write-Log ("Blob: {0} block(s) uploaded and committed to the block list." -f $blockIds.Count)
  return $blockIds.Count
}

# Graph liefert Zeitstempel je nach Endpunkt als Zeichenkette oder gar nicht. Ein fehlgeschlagener
# Parse darf den Upload nicht abbrechen - dann wird eben nicht erneuert (siehe Test-SasRenewalDue).
function Get-UtcDateOrMin {
  param($Value)
  if ($null -eq $Value) { return [datetime]::MinValue }
  if ($Value -is [datetime]) { return ([datetime]$Value).ToUniversalTime() }
  $parsed = [datetime]::MinValue
  if ([datetime]::TryParse([string]$Value, [cultureinfo]::InvariantCulture,
      [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal,
      [ref]$parsed)) {
    return $parsed
  }
  return [datetime]::MinValue
}

# Haengt eine neue Inhaltsversion an eine BESTEHENDE App und gibt deren Id zurueck. Der Aufrufer
# setzt danach committedContentVersion - erst das macht die Version zur aktiven.
function Publish-MobileAppContentVersion {
  param(
    [Parameter(Mandatory)][string]$AppId,
    [Parameter(Mandatory)][string]$OdataType,
    [Parameter(Mandatory)][string]$SourceFile,
    [Parameter(Mandatory)][hashtable]$Headers
  )
  if (-not (Test-Path -LiteralPath $SourceFile -PathType Leaf)) {
    throw ("The file to upload does not exist: {0}" -f $SourceFile)
  }
  $base = ("https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/{0}/{1}" -f $AppId, $OdataType)
  # Die verschluesselte Kopie ist so gross wie das Original und wird in JEDEM Fall wieder entfernt.
  $encryptedPath = Join-Path ([IO.Path]::GetTempPath()) ("wtgui-enc-{0}.bin" -f [guid]::NewGuid().ToString('N'))
  try {
    Write-Log ("Encrypting '{0}' for upload." -f $SourceFile)
    $enc = New-IntuneContentEncryption -SourceFile $SourceFile -TargetFile $encryptedPath

    # POST legt eine Ressource AN und ist damit nicht idempotent: ein Wiederholungsversuch nach
    # einem Zeitablauf erzeugte eine zweite, leere Inhaltsversion. Deshalb MaxRetries 0.
    $version = Invoke-GraphRest -Uri ("{0}/contentVersions" -f $base) -Method POST -Headers $Headers `
      -Body '{}' -Context 'create content version' -MaxRetries 0
    $versionId = [string]$version.id
    if ([string]::IsNullOrWhiteSpace($versionId)) { throw 'Intune did not return a content version id.' }

    $fileBody = @{
      '@odata.type'   = '#microsoft.graph.mobileAppContentFile'
      name            = [IO.Path]::GetFileName($SourceFile)
      size            = $enc.PlainSize
      sizeEncrypted   = $enc.EncryptedSize
      isDependency    = $false
    } | ConvertTo-Json -Depth 4
    $fileResource = Invoke-GraphRest -Uri ("{0}/contentVersions/{1}/files" -f $base, $versionId) `
      -Method POST -Headers $Headers -Body $fileBody -Context 'register content file' -MaxRetries 0
    $fileId = [string]$fileResource.id
    if ([string]::IsNullOrWhiteSpace($fileId)) { throw 'Intune did not return a content file id.' }
    $fileUri = ("{0}/contentVersions/{1}/files/{2}" -f $base, $versionId, $fileId)

    $ready = Wait-MobileAppFileState -FileUri $fileUri -Headers $Headers `
      -SuccessState 'azureStorageUriRequestSuccess' -FailureState 'azureStorageUriRequestFailed'
    [void](Send-BlobBlocks -EncryptedFile $enc.EncryptedPath -AzureStorageUri ([string]$ready.azureStorageUri) `
      -FileUri $fileUri -Headers $Headers -ExpiresUtc (Get-UtcDateOrMin -Value $ready.azureStorageUriExpirationDateTime))

    $commitBody = @{ fileEncryptionInfo = $enc.EncryptionInfo } | ConvertTo-Json -Depth 4
    [void](Invoke-GraphRest -Uri ("{0}/commit" -f $fileUri) -Method POST -Headers $Headers `
      -Body $commitBody -Context 'commit content file' -MaxRetries 0)
    [void](Wait-MobileAppFileState -FileUri $fileUri -Headers $Headers `
      -SuccessState 'commitFileSuccess' -FailureState 'commitFileFailed')

    Write-Log ("Content version {0} uploaded and committed for app {1}." -f $versionId, $AppId)
    return $versionId
  } finally {
    if (Test-Path -LiteralPath $encryptedPath -PathType Leaf) {
      try { Remove-Item -LiteralPath $encryptedPath -Force -ErrorAction Stop }
      catch { Write-Log ("Could not remove the temporary encrypted copy '{0}': {1}" -f $encryptedPath, $_.Exception.Message) }
    }
  }
}
