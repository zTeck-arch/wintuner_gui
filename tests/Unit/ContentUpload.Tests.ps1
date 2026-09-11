#requires -Version 7
# Der Inhalts-Upload nach Intune - das Pruefbare daran.
#
# Diese Kette ist der erste Upload-Weg, den die GUI selbst geht statt ihn dem WinTuner-Modul zu
# ueberlassen (das Modul kennt nur win32LobApp, macOSPkgApp gibt es dort nicht). Der Preis dafuer:
# alles, was das Modul bisher richtig gemacht hat, muss hier selbst richtig sein - und das Ergebnis
# ist unter Windows NICHT beobachtbar. Ob eine macOS-App wirklich installiert, sieht man erst auf
# einem Mac, und dort erst beim Kunden.
#
# Deshalb wird hier alles geprueft, was ohne Mac und ohne Tenant pruefbar ist: dass das Chiffrat mit
# den mitgelieferten Schluesseln wieder aufgeht, dass der MAC passt, dass der Digest ueber den
# KLARTEXT gebildet wird, und dass die Blockkennungen die Form haben, die Azure verlangt. Jeder
# dieser Punkte war beim Schreiben mindestens einmal falsch.

BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  # Der GANZE Teil, nicht einzelne Funktionen: er setzt Blockgroesse, Zeitablauf und
  # Erneuerungsschwelle als Zuweisungen daneben, und eine Kopie davon im Test wuerde von der
  # Quelle abdriften. Der Teil baut keine UI, also ist das gefahrlos.
  . ([scriptblock]::Create((Get-SourcePartText -Part '42-ContentUpload.ps1')))

  # Absichtlich KEIN Vielfaches der Blockgroesse und kein Vielfaches von 16: so muss die
  # PKCS7-Auffuellung wirken, und ein Fehler darin faellt beim Entschluesseln auf.
  $script:plainBytes = [byte[]]::new(100003)
  [System.Security.Cryptography.RandomNumberGenerator]::Fill($script:plainBytes)
  $script:plainFile = Join-Path ([IO.Path]::GetTempPath()) ("wtgui-test-plain-{0}.bin" -f [guid]::NewGuid().ToString('N'))
  [System.IO.File]::WriteAllBytes($script:plainFile, $script:plainBytes)

  # Entschluesselt nach dem Schema, das Intune auf der anderen Seite anwendet:
  # [ MAC 32 ][ IV 16 ][ AES-256-CBC/PKCS7 ]
  function Invoke-TestDecrypt {
    param([string]$EncryptedFile, [hashtable]$Info)
    $raw = [System.IO.File]::ReadAllBytes($EncryptedFile)
    $iv = $raw[32..47]
    $cipher = $raw[48..($raw.Length - 1)]
    $aes = [System.Security.Cryptography.Aes]::Create()
    try {
      $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
      $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
      $aes.Key = [Convert]::FromBase64String($Info.encryptionKey)
      $aes.IV = [byte[]]$iv
      $dec = $aes.CreateDecryptor()
      try { return $dec.TransformFinalBlock([byte[]]$cipher, 0, $cipher.Length) }
      finally { $dec.Dispose() }
    } finally { $aes.Dispose() }
  }

  function New-TestEncryption {
    $target = Join-Path ([IO.Path]::GetTempPath()) ("wtgui-test-enc-{0}.bin" -f [guid]::NewGuid().ToString('N'))
    return (New-IntuneContentEncryption -SourceFile $script:plainFile -TargetFile $target)
  }
}

AfterAll {
  if ($script:plainFile -and (Test-Path -LiteralPath $script:plainFile)) {
    Remove-Item -LiteralPath $script:plainFile -Force -ErrorAction SilentlyContinue
  }
}

Describe 'New-IntuneContentEncryption' {

  It 'erzeugt ein Chiffrat, das sich mit den gemeldeten Schluesseln wieder aufloest' {
    $enc = New-TestEncryption
    try {
      $back = Invoke-TestDecrypt -EncryptedFile $enc.EncryptedPath -Info $enc.EncryptionInfo
      $back.Length | Should -Be $script:plainBytes.Length
      # Byteweise vergleichen, nicht ueber eine Zeichenkette: ein Kodierungsumweg wuerde jeden
      # Unterschied in den oberen Bits verstecken.
      [System.Linq.Enumerable]::SequenceEqual([byte[]]$back, $script:plainBytes) | Should -BeTrue
    } finally { Remove-Item -LiteralPath $enc.EncryptedPath -Force -ErrorAction SilentlyContinue }
  }

  It 'legt den MAC ueber IV + Chiffrat, also ueber alles ab Byte 32' {
    $enc = New-TestEncryption
    try {
      $raw = [System.IO.File]::ReadAllBytes($enc.EncryptedPath)
      $hmac = [System.Security.Cryptography.HMACSHA256]::new()
      try {
        $hmac.Key = [Convert]::FromBase64String($enc.EncryptionInfo.macKey)
        $expected = $hmac.ComputeHash([byte[]]($raw[32..($raw.Length - 1)]))
      } finally { $hmac.Dispose() }
      [Convert]::ToBase64String($expected) | Should -Be $enc.EncryptionInfo.mac
      # Und der MAC steht wirklich in den ersten 32 Byte, nicht nur im Rueckgabewert.
      [Convert]::ToBase64String([byte[]]($raw[0..31])) | Should -Be $enc.EncryptionInfo.mac
    } finally { Remove-Item -LiteralPath $enc.EncryptedPath -Force -ErrorAction SilentlyContinue }
  }

  It 'bildet fileDigest ueber den KLARTEXT, nicht ueber das Chiffrat' {
    # Die Verwechslung ergibt eine App, die Intune ohne Murren annimmt und die auf dem Geraet
    # scheitert - also genau der Fehler, den man ohne Mac nie zu Gesicht bekommt.
    $enc = New-TestEncryption
    try {
      $sha = [System.Security.Cryptography.SHA256]::Create()
      try {
        $plainHash = [Convert]::ToBase64String($sha.ComputeHash($script:plainBytes))
        $cipherHash = [Convert]::ToBase64String($sha.ComputeHash([System.IO.File]::ReadAllBytes($enc.EncryptedPath)))
      } finally { $sha.Dispose() }
      $enc.EncryptionInfo.fileDigest | Should -Be $plainHash
      $enc.EncryptionInfo.fileDigest | Should -Not -Be $cipherHash
      $enc.EncryptionInfo.fileDigestAlgorithm | Should -Be 'SHA256'
      $enc.EncryptionInfo.profileIdentifier | Should -Be 'ProfileVersion1'
    } finally { Remove-Item -LiteralPath $enc.EncryptedPath -Force -ErrorAction SilentlyContinue }
  }

  It 'meldet einen MAC-Schluessel, der nicht aus Nullbytes besteht' {
    # Regression: der Getter von HMAC.Key gibt eine KOPIE zurueck. Ein
    # RandomNumberGenerator::Fill($hmac.Key) machte deshalb nur die Kopie zufaellig und liess den
    # echten Schluessel auf 32 Nullbytes stehen. Der MAC verifizierte trotzdem - der Schluessel war
    # nur fuer jeden vorhersagbar, ohne jede Fehlermeldung.
    $enc = New-TestEncryption
    try {
      $key = [Convert]::FromBase64String($enc.EncryptionInfo.macKey)
      $key.Length | Should -Be 32
      ($key | Where-Object { $_ -ne 0 }).Count | Should -BeGreaterThan 0
    } finally { Remove-Item -LiteralPath $enc.EncryptedPath -Force -ErrorAction SilentlyContinue }
  }

  It 'verwendet fuer jeden Lauf neue Schluessel und einen neuen IV' {
    $a = New-TestEncryption
    $b = New-TestEncryption
    try {
      $a.EncryptionInfo.encryptionKey | Should -Not -Be $b.EncryptionInfo.encryptionKey
      $a.EncryptionInfo.macKey | Should -Not -Be $b.EncryptionInfo.macKey
      $a.EncryptionInfo.initializationVector | Should -Not -Be $b.EncryptionInfo.initializationVector
      # Derselbe Klartext, also derselbe Digest - der darf sich NICHT unterscheiden.
      $a.EncryptionInfo.fileDigest | Should -Be $b.EncryptionInfo.fileDigest
    } finally {
      Remove-Item -LiteralPath $a.EncryptedPath -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $b.EncryptedPath -Force -ErrorAction SilentlyContinue
    }
  }

  It 'meldet beide Groessen: die des Originals und die der verschluesselten Kopie' {
    # sizeEncrypted geht so an Graph. Steht dort die Klartextgroesse, bricht der commit ab.
    $enc = New-TestEncryption
    try {
      $enc.PlainSize | Should -Be $script:plainBytes.Length
      $enc.EncryptedSize | Should -Be (Get-Item -LiteralPath $enc.EncryptedPath).Length
      # 32 MAC + 16 IV + Auffuellung auf die naechste 16er-Grenze.
      $enc.EncryptedSize | Should -BeGreaterThan $enc.PlainSize
    } finally { Remove-Item -LiteralPath $enc.EncryptedPath -Force -ErrorAction SilentlyContinue }
  }

  It 'bricht ab, wenn die Quelldatei fehlt' {
    $missing = Join-Path ([IO.Path]::GetTempPath()) ("wtgui-test-missing-{0}.bin" -f [guid]::NewGuid().ToString('N'))
    { New-IntuneContentEncryption -SourceFile $missing -TargetFile "$missing.enc" } | Should -Throw
  }
}

Describe 'Get-BlobBlockId' {

  It 'gibt allen Kennungen dieselbe Laenge' {
    # Azure beantwortet unterschiedlich lange Block-Kennungen mit HTTP 400 - und zwar erst beim
    # Schreiben der Blockliste, wenn alle Daten schon oben sind.
    $ids = @(0, 1, 9, 10, 999, 1000, 12345678 | ForEach-Object { Get-BlobBlockId -Index $_ })
    ($ids | ForEach-Object { $_.Length } | Sort-Object -Unique).Count | Should -Be 1
  }

  It 'gibt verschiedenen Bloecken verschiedene Kennungen' {
    $ids = @(0..50 | ForEach-Object { Get-BlobBlockId -Index $_ })
    ($ids | Sort-Object -Unique).Count | Should -Be 51
  }

  It 'liefert gueltiges Base64' {
    $id = Get-BlobBlockId -Index 7
    { [Convert]::FromBase64String($id) } | Should -Not -Throw
    [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($id)) | Should -Be 'block-00000007'
  }
}

Describe 'Get-BlobBlockListXml' {

  It 'behaelt die Reihenfolge der Bloecke' {
    # Diese Reihenfolge bestimmt die Reihenfolge der BYTES, nicht die des Hochladens. Eine
    # vertauschte Liste ergibt eine Datei, die Azure klaglos annimmt und die unbrauchbar ist.
    $xml = Get-BlobBlockListXml -BlockIds @('AAA', 'BBB', 'CCC')
    $xml | Should -BeLike '*<Latest>AAA</Latest><Latest>BBB</Latest><Latest>CCC</Latest>*'
  }

  It 'ist wohlgeformtes XML mit BlockList als Wurzel' {
    $xml = [xml](Get-BlobBlockListXml -BlockIds @('AAA', 'BBB'))
    $xml.BlockList.Latest.Count | Should -Be 2
  }
}

Describe 'Test-SasRenewalDue' {

  It 'erneuert, wenn die Restlaufzeit unter der Schwelle liegt' {
    $now = [datetime]::UtcNow
    Test-SasRenewalDue -ExpiresUtc $now.AddMinutes(4) -NowUtc $now | Should -BeTrue
  }

  It 'erneuert nicht, solange genug Zeit bleibt' {
    $now = [datetime]::UtcNow
    Test-SasRenewalDue -ExpiresUtc $now.AddMinutes(45) -NowUtc $now | Should -BeFalse
  }

  It 'erneuert auch bei bereits abgelaufener URL' {
    $now = [datetime]::UtcNow
    Test-SasRenewalDue -ExpiresUtc $now.AddMinutes(-1) -NowUtc $now | Should -BeTrue
  }

  It 'erneuert NICHT, wenn kein Ablaufdatum bekannt ist' {
    # Ein unnoetiger renewUpload setzt den Zustand der Datei zurueck und kostet eine weitere
    # Warteschleife. Unbekannt heisst hier: nichts tun.
    Test-SasRenewalDue -ExpiresUtc ([datetime]::MinValue) -NowUtc ([datetime]::UtcNow) | Should -BeFalse
  }

  It 'achtet auf eine ausdruecklich genannte Schwelle' {
    $now = [datetime]::UtcNow
    Test-SasRenewalDue -ExpiresUtc $now.AddMinutes(20) -NowUtc $now -ThresholdMinutes 30 | Should -BeTrue
    Test-SasRenewalDue -ExpiresUtc $now.AddMinutes(20) -NowUtc $now -ThresholdMinutes 5 | Should -BeFalse
  }
}

Describe 'Get-UtcDateOrMin' {

  It 'liest den ISO-Zeitstempel, wie Graph ihn liefert' {
    $d = Get-UtcDateOrMin -Value '2026-09-11T14:30:00.0000000Z'
    $d.Year | Should -Be 2026
    $d.Hour | Should -Be 14
    $d.Kind | Should -Be ([System.DateTimeKind]::Utc)
  }

  It 'nimmt auch ein echtes DateTime an' {
    $src = [datetime]::new(2026, 9, 11, 12, 0, 0, [System.DateTimeKind]::Utc)
    (Get-UtcDateOrMin -Value $src).Hour | Should -Be 12
  }

  It 'gibt MinValue zurueck, statt bei Unsinn zu werfen' {
    # Ein Zeitstempel, den man nicht lesen kann, darf einen laufenden Upload nicht abbrechen -
    # dann wird eben nicht erneuert.
    Get-UtcDateOrMin -Value 'nicht wirklich ein Datum' | Should -Be ([datetime]::MinValue)
    Get-UtcDateOrMin -Value $null | Should -Be ([datetime]::MinValue)
    Get-UtcDateOrMin -Value '' | Should -Be ([datetime]::MinValue)
  }
}
