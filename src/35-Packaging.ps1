
# Der Runspace fuehrt genau eine Pipeline. Dieser Merker sagt, dass sie besetzt ist - Paketbau
# UND Inventar-Abfrage teilen ihn sich, und wer ihn besetzt findet, arbeitet inline weiter.
$script:pkgRunspaceInUse = $false

# Erzeugt EINEN Runspace mit importiertem WinTuner-Modul.
#
# Herausgeloest, weil es seit dem Vorab-Bau zwei davon gibt: einen fuer den Hauptbau und einen, der
# nebenher schon die naechste App baut. Geteilt werden duerfen sie nicht - ein Runspace fuehrt genau
# eine Pipeline, und das Nebeneinander ist der ganze Sinn der Sache.
function New-PackagingRunspace {
  param([string]$Purpose = 'packaging')
  try {
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = [System.Threading.ApartmentState]::MTA
    $rs.ThreadOptions  = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $rs.Open()
    $init = [powershell]::Create()
    $init.Runspace = $rs
    [void]$init.AddScript('$ProgressPreference = ''SilentlyContinue''; $InformationPreference = ''SilentlyContinue''; Import-Module WinTuner -ErrorAction Stop')
    [void]$init.Invoke()
    if ($init.Streams.Error.Count -gt 0) {
      $msg = ($init.Streams.Error | ForEach-Object { $_.ToString() }) -join '; '
      $init.Dispose(); $rs.Dispose()
      Write-Log ("Background {0} unavailable (module import failed): {1}" -f $Purpose, $msg)
      return $null
    }
    $init.Dispose()
    Write-Log ("Background {0} runspace ready (WinTuner module imported)." -f $Purpose)
    return $rs
  } catch {
    Write-Log ("Could not create the background {0} runspace: {1}" -f $Purpose, $_.Exception.Message)
    return $null
  }
}

function Get-PackageRunspace {
  if ($script:pkgRunspace -and $script:pkgRunspace.RunspaceStateInfo.State -eq 'Opened') {
    return $script:pkgRunspace
  }
  if ($script:pkgRunspace) { try { $script:pkgRunspace.Dispose() } catch { } }   # class 3: teardown
  $script:pkgRunspace = New-PackagingRunspace -Purpose 'packaging'
  return $script:pkgRunspace
}

# Runs New-WtWingetPackage in the background runspace and keeps the UI alive while it works.
# Returns @{ Succeeded; Result; ErrorMessage; TimedOut }. Falls back to a synchronous call
# (the previous behaviour) when no runspace can be created, so packaging never becomes impossible.
function Invoke-WtPackageBuild {
  param(
    [Parameter(Mandatory)][hashtable]$Arguments,
    [string]$Label = '',
    [int]$TimeoutMinutes = 30
  )
  # Hat der Vorab-Bau GENAU dieses Paket schon gebaut, wird sein Ergebnis uebernommen statt es ein
  # zweites Mal zu bauen. Steht hier ganz vorn, weil das der einzige Trichter ist, durch den jeder
  # Paketbau laeuft - egal ob Stapellauf, Favoritenlauf oder einzelner Klick. Passt der Schluessel
  # nicht, gibt Get-PrebuildResult $null zurueck und verwirft den Vorab-Bau; gebaut wird dann wie
  # immer. Auch ein GESCHEITERTER Vorab-Bau wird uebernommen: der Fehler waere hier derselbe, und
  # die Rueckfall-Logik in New-WingetPackageWithFallback sieht ihn genauso.
  $adopted = Get-PrebuildResult -Arguments $Arguments -Label $Label -TimeoutMinutes $TimeoutMinutes
  if ($adopted) { return $adopted }

  $rs = Get-PackageRunspace
  if (-not $rs) {
    Write-Log "Falling back to synchronous packaging (UI will block until the package is built)."
    try {
      $r = New-WtWingetPackage @Arguments
      return @{ Succeeded = $true; Result = $r; ErrorMessage = $null; TimedOut = $false }
    } catch {
      return @{ Succeeded = $false; Result = $null; ErrorMessage = $_.Exception.Message; TimedOut = $false }
    }
  }

  $ps = [powershell]::Create()
  $ps.Runspace = $rs
  # ErrorAction is passed through the hashtable by the caller; AddParameters keeps it intact.
  [void]$ps.AddCommand('New-WtWingetPackage').AddParameters($Arguments)

  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $script:packagingBusy = $true
  $script:pkgRunspaceInUse = $true
  try {
    $handle = $ps.BeginInvoke()
    $timedOut = $false
    while (-not $handle.IsCompleted) {
      # This is what keeps the window responsive: the UI thread pumps its message queue while the
      # package is being built on the other thread.
      [System.Windows.Forms.Application]::DoEvents()
      Start-Sleep -Milliseconds 60
      # "Stop after current app" can now abort the BUILD itself, not just wait for it: packaging
      # only writes local files, so stopping it leaves nothing half-done in Intune (unlike an
      # upload, which is why the deploy step is still never interrupted).
      if ($script:cancelBatch) {
        Write-Log ("Packaging canceled by user{0} after {1:n1}s." -f $(if ($Label) { " for $Label" } else { '' }), $sw.Elapsed.TotalSeconds)
        try { $ps.Stop() } catch { }   # class 3: best-effort abort
        return @{ Succeeded = $false; Result = $null; ErrorMessage = 'Canceled by user'; TimedOut = $false }
      }
      if ($sw.Elapsed.TotalMinutes -ge $TimeoutMinutes) {
        $timedOut = $true
        Write-Log ("Packaging timed out after {0} minute(s){1} - stopping the build." -f $TimeoutMinutes, $(if ($Label) { " for $Label" } else { '' }))
        try { $ps.Stop() } catch { }   # class 3: best-effort abort
        break
      }
    }
    if ($timedOut) {
      return @{ Succeeded = $false; Result = $null; ErrorMessage = "Packaging timed out after $TimeoutMinutes minute(s)"; TimedOut = $true }
    }

    $out = $ps.EndInvoke($handle)
    if ($ps.Streams.Error.Count -gt 0) {
      # New-WtWingetPackage was called with ErrorAction Stop, so a terminating error arrives here
      # as an exception from EndInvoke; anything left in the stream is reported as-is.
      $msg = ($ps.Streams.Error | ForEach-Object { $_.ToString() }) -join '; '
      return @{ Succeeded = $false; Result = $null; ErrorMessage = $msg; TimedOut = $false }
    }
    $result = if ($out -and $out.Count -gt 0) { $out[$out.Count - 1] } else { $null }
    Write-Log ("Packaging finished in {0:n1}s{1} (background)." -f $sw.Elapsed.TotalSeconds, $(if ($Label) { " for $Label" } else { '' }))
    return @{ Succeeded = $true; Result = $result; ErrorMessage = $null; TimedOut = $false }
  } catch {
    # BeginInvoke/EndInvoke surface the module's terminating errors here - unwrap to the real
    # message so the existing 404 / "Hash mismatch" fallbacks keep matching on it.
    $em = $_.Exception.Message
    if ($_.Exception.InnerException -and $_.Exception.InnerException.Message) { $em = $_.Exception.InnerException.Message }
    return @{ Succeeded = $false; Result = $null; ErrorMessage = $em; TimedOut = $false }
  } finally {
    $script:packagingBusy = $false
    $script:pkgRunspaceInUse = $false
    try { $ps.Dispose() } catch { }   # class 3: teardown
  }
}

# Thin wrapper so the fallback logic below reads like the original synchronous code: it throws on
# failure exactly like New-WtWingetPackage -ErrorAction Stop did, and the callers keep their
# existing try/catch structure (404 -> previous version, hash mismatch -> ask the user).
function Invoke-PackageBuildOrThrow {
  param([hashtable]$Arguments, [string]$Label = '')
  $r = Invoke-WtPackageBuild -Arguments $Arguments -Label $Label
  if (-not $r.Succeeded) { throw $r.ErrorMessage }
  return $r.Result
}

# Package/CDN endpoints can answer with HTTP 429 during bursts. Retry only that transient status;
# deterministic errors (404, hash mismatch, invalid manifest, etc.) continue into their dedicated
# fallback paths immediately. Retry-After is honored when present, otherwise use bounded backoff.
function Invoke-PackageBuildWithThrottleRetry {
  param([hashtable]$Arguments, [string]$Label = '', [int]$MaxRetries = 3)
  $retry = 0
  while ($true) {
    try { return (Invoke-PackageBuildOrThrow -Arguments $Arguments -Label $Label) }
    catch {
      $message = $_.Exception.Message
      # The status code decides when the exception carries one. The text is only consulted
      # otherwise, and then 429 must stand on its own: the previous pattern matched a bare "429"
      # anywhere, so a version number such as 1.429.0 or a package id containing those digits was
      # mistaken for throttling and the build was retried three times for nothing.
      $status = Get-ErrorHttpStatus -ErrorRecord $_
      $throttled = if ($status -gt 0) {
        $status -eq 429
      } else {
        $message -match '(?i)Too Many Requests' -or $message -match '(?i)HTTP\s*429' -or $message -match '(?<![\d.])429(?![\d.])'
      }
      # "Collection was modified" / "Value cannot be null" is the module enumerating its own live
      # app list while building - it failed the FIRST click and worked on the second. Retry it
      # automatically with a short pause so the user never has to click twice. Kept distinct from
      # throttling: a race clears in under a second, a 429 needs the longer server-directed backoff.
      $raced = (-not $throttled) -and (Test-IsTransientModuleRace $message)
      if ((-not $throttled -and -not $raced) -or $retry -ge $MaxRetries) { throw }
      $retry++
      $delay = if ($raced) { 2 } elseif ($retry -eq 1) { 5 } elseif ($retry -eq 2) { 15 } else { 30 }
      if ($throttled -and $message -match '(?i)Retry-After\s*[:=]\s*(\d+)') {
        $delay = [Math]::Max(1, [Math]::Min(45, [int]$Matches[1]))
      }
      if ($raced) {
        Write-Log ("Package build hit a transient module race {0} (retry {1}/{2}) after {3}s: {4}" -f $Label, $retry, $MaxRetries, $delay, $message)
      } else {
        Write-Log ("Package source throttled {0} (HTTP 429); retry {1}/{2} after {3}s." -f $Label, $retry, $MaxRetries, $delay)
      }
      for ($remaining = $delay; $remaining -gt 0; $remaining--) {
        if ($script:cancelBatch) { throw 'Cancelled by user while waiting for a rate-limit retry.' }
        Update-Status ((Get-UiString 'RateLimitRetryStatus') -f $retry, $remaining)
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Seconds 1
      }
    }
  }
}

# Der Argumentsatz fuer New-WtWingetPackage - OHNE Version, die kommt je Versuch dazu.
#
# Herausgeloest, weil ihn seit dem Vorab-Bau ZWEI Wege brauchen: der Hauptlauf und der Bau, der
# nebenher schon die naechste App vorbereitet. Baute der eine mit anderen Optionen als der andere
# und der Hauptlauf uebernaehme dessen Ergebnis, entstuende ein Paket mit falschen Einstellungen -
# und das faellt nicht beim Bauen auf, sondern erst auf den Endgeraeten. Eine Quelle, keine Kopie.
#
# Optionale Angaben landen nur dann im Satz, wenn sie gesetzt sind: sonst behaelt das Modul seine
# eigenen Vorgaben. Genau deshalb duerfen die Schluessel auch fehlen statt leer zu sein - beide
# Seiten bilden den Satz ueber DIESE Funktion, also fehlen sie auf beiden Seiten gleich.
function Get-WingetPackageArguments {
  param(
    [string]$PackageId,
    [string]$PackageFolder,
    [string]$Architecture,
    [string]$InstallerContext,
    [string]$Locale,
    [string]$PreferredInstaller,
    [string]$InstallerArguments,
    [switch]$PackageScript
  )
  $base = @{ PackageId = $PackageId; PackageFolder = $PackageFolder; ErrorAction = 'Stop' }
  if ($Architecture)     { $base.Architecture     = $Architecture }
  if ($InstallerContext) { $base.InstallerContext = $InstallerContext }
  if ($Locale)           { $base.Locale           = $Locale }
  # Das Modul schreibt den Parameter "PreferedInstaller" (ein 'r'). Die Oberflaeche benutzt die
  # richtige Schreibweise, der Tippfehler bleibt auf diese eine Zeile beschraenkt.
  if ($PreferredInstaller) { $base.PreferedInstaller  = $PreferredInstaller }
  if ($InstallerArguments) { $base.InstallerArguments = $InstallerArguments }
  if ($PackageScript)      { $base.PackageScript = $true }
  return $base
}

# Der Schluessel ueber einen Argumentsatz: sortierte Name=Wert-Paare, ErrorAction ausgenommen.
#
# Er entscheidet, ob ein vorab gebautes Paket uebernommen werden darf. Deshalb geht der
# VOLLSTAENDIGE Satz ein und nicht nur Paket-Id und Version: zwei Baeufe derselben Version mit
# unterschiedlicher Architektur oder unterschiedlichem Installerkontext sind verschiedene Pakete,
# und sie sehen von aussen gleich aus. ErrorAction faellt heraus, weil es nur steuert, wie ein
# Fehler gemeldet wird, und nichts am erzeugten Paket aendert.
function Get-PackageBuildKey {
  param([Parameter(Mandatory)][hashtable]$Arguments)
  $names = @($Arguments.Keys |
    Where-Object { [string]$_ -ne 'ErrorAction' } |
    Sort-Object -Property { [string]$_ } -CaseSensitive)
  return (@($names | ForEach-Object { '{0}={1}' -f $_, [string]$Arguments[$_] }) -join '|')
}

# --- Vorab-Bau: das Paket der NAECHSTEN App entsteht, waehrend die aktuelle hochgeladen wird ---
#
# Gemessen an einem echten Lauf (8 Vorgaenge, ~8,5 Minuten) steht Paketieren gegen Hochladen bei
# Logi Tune 256 s zu 32 s, bei Chrome 13 s zu 25 s. Nacheinander addiert sich beides; nebeneinander
# faellt je App grob die kuerzere der beiden Phasen weg.
#
# Der Upload bleibt sequenziell und bleibt auf dem UI-Faden: Intune drosselt (HTTP 429 ist real
# aufgetreten), und die Graph-Sitzung gilt je Runspace. Nebenlaeufig ist ausschliesslich der
# Paketbau, und der schreibt nur lokale Dateien.
$script:prebuildRunspace = $null
# Der laufende Vorab-Bau: @{ Key; Label; Shell; Handle; Stopwatch }. Immer hoechstens einer.
$script:prebuild = $null
# Vom Stapellauf vorgemerkt, von Update-SingleApp angestossen: @{ Arguments; Label }.
$script:pendingPrebuild = $null

function Get-PrebuildRunspace {
  if ($script:prebuildRunspace -and $script:prebuildRunspace.RunspaceStateInfo.State -eq 'Opened') {
    return $script:prebuildRunspace
  }
  if ($script:prebuildRunspace) { try { $script:prebuildRunspace.Dispose() } catch { } }   # class 3: teardown
  $script:prebuildRunspace = New-PackagingRunspace -Purpose 'prebuild'
  return $script:prebuildRunspace
}

# Startet den Vorab-Bau. Gibt $true zurueck, wenn wirklich einer laeuft.
#
# Scheitert hier irgendetwas, ist das folgenlos: der Hauptlauf baut wie bisher selbst. Deshalb wird
# nichts geworfen und nichts angezeigt - nur protokolliert.
function Start-PackagePrebuild {
  param([Parameter(Mandatory)][hashtable]$Arguments, [string]$Label = '')
  if ($script:cancelBatch) { return $false }
  if ($script:prebuild) { return $false }
  $rs = Get-PrebuildRunspace
  if (-not $rs) { return $false }
  try {
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddCommand('New-WtWingetPackage').AddParameters($Arguments)
    $handle = $ps.BeginInvoke()
    $script:prebuild = @{
      Key       = (Get-PackageBuildKey -Arguments $Arguments)
      Label     = $Label
      Shell     = $ps
      Handle    = $handle
      Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    }
    Write-Log ("Prebuild started for {0} while the current app uploads." -f $Label)
    return $true
  } catch {
    Write-Log ("Prebuild could not be started for {0}: {1}" -f $Label, $_.Exception.Message)
    $script:prebuild = $null
    return $false
  }
}

# Stoesst den vorgemerkten Vorab-Bau an. Aufgerufen von Update-SingleApp, sobald das Paket der
# AKTUELLEN App fertig ist und der Upload beginnt - nicht frueher, sonst bauen zwei gleichzeitig
# und nehmen sich gegenseitig die Leitung weg.
function Start-PendingPackagePrebuild {
  $pending = $script:pendingPrebuild
  $script:pendingPrebuild = $null
  if (-not $pending -or -not $pending.Arguments) { return }
  [void](Start-PackagePrebuild -Arguments $pending.Arguments -Label ([string]$pending.Label))
}

# Verwirft einen laufenden Vorab-Bau. Gefahrlos: er schreibt nur lokale Dateien, im Gegensatz zu
# einem Upload, der deshalb nie unterbrochen wird.
function Stop-PackagePrebuild {
  param([string]$Reason = '')
  $pb = $script:prebuild
  $script:prebuild = $null
  $script:pendingPrebuild = $null
  if (-not $pb) { return }
  try { $pb.Shell.Stop() } catch { }      # class 3: teardown
  try { $pb.Shell.Dispose() } catch { }   # class 3: teardown
  Write-Log ("Prebuild for {0} discarded{1}." -f $pb.Label, $(if ($Reason) { " ($Reason)" } else { '' }))
}

function Close-PrebuildRunspace {
  Stop-PackagePrebuild -Reason 'shutting down'
  if ($script:prebuildRunspace) {
    try { $script:prebuildRunspace.Close(); $script:prebuildRunspace.Dispose() } catch { }   # class 3: teardown
    $script:prebuildRunspace = $null
    Write-Log 'Background prebuild runspace closed.'
  }
}

# ---------------------------------------------------------------------------------------------
# Upload im Hintergrund-Runspace
#
# Gemeldet am 02.09.2026 aus dem Betrieb: waehrend eines Uploads steht das Fenster auf "Keine
# Rueckmeldung" - ein Klick auf "Aktivitaetsprotokoll" tut sichtbar nichts, gemeldet wurde es als
# Einfrieren. Dazu eine Flut aus
#   "[ERROR] Write log to PowerShell failed: The WriteObject and WriteError methods cannot be
#    called from outside the overridden ... same thread"
# Beides hat EINE Ursache: Deploy-WtWin32App lief auf dem UI-Faden. Dann pumpt niemand die
# Nachrichtenschleife, und der .NET-Logger des Moduls schreibt in den Host SEINES Runspace - auf dem
# UI-Faden ist das unsere Konsole, und weil das Modul aus fortgesetzten Aufgaben (anderer Thread)
# protokolliert, scheitert jede einzelne Zeile mit genau dieser Meldung.
#
# Beim Paketbau ist beides seit 0.15.x weg, aus demselben Grund: eigener Runspace (siehe den
# Kommentar in 30-UpdateTargets bei $script:pkgRunspace). Der Upload zieht das jetzt nach.
#
# Ein EIGENER Runspace, nicht pkgRunspace und nicht prebuildRunspace: ein Runspace fuehrt genau eine
# Pipeline, und waehrend des Uploads baut der Vorab-Bau schon die naechste App - das Nebeneinander
# ist der ganze Zweck der Sache.
$script:deployRunspace = $null
$script:deployRunspaceInUse = $false

function Get-DeployRunspace {
  if ($script:deployRunspace -and $script:deployRunspace.RunspaceStateInfo.State -eq 'Opened') {
    return $script:deployRunspace
  }
  if ($script:deployRunspace) { try { $script:deployRunspace.Dispose() } catch { } }   # class 3: teardown
  $script:deployRunspace = New-PackagingRunspace -Purpose 'upload'
  return $script:deployRunspace
}

function Close-DeployRunspace {
  if ($script:deployRunspace) {
    try { $script:deployRunspace.Close(); $script:deployRunspace.Dispose() } catch { }   # class 3: teardown
    $script:deployRunspace = $null
    Write-Log 'Background upload runspace closed.'
  }
}

# Fuehrt Deploy-WtWin32App im Upload-Runspace aus und haelt das Fenster dabei lebendig.
#
# Gibt zurueck, was das Modul zurueckgibt; wirft den Fehler AUS dem Upload unveraendert auf dem
# UI-Faden. Beides absichtlich: die Aufrufer pruefen den Rueckgabewert auf .Id und ihre bestehenden
# try/catch samt Textpruefungen (403, Duplikat) sollen denselben Fehler sehen wie bei einem
# Inline-Aufruf. Eine Auslagerung, die den Fehler umformt, waere eine stille Verhaltensaenderung an
# der Stelle, an der Apps im Kundentenant angelegt werden.
#
# KEIN Zeitablauf, KEIN Abbruch, KEIN $ps.Stop(): ein halber Upload laesst eine halb angelegte App
# im Tenant. Der Abbruchknopf wirkt weiterhin ZWISCHEN den Apps - anders als beim Paketbau, der nur
# lokale Dateien schreibt und deshalb unterbrochen werden darf.
#
# Dass die Anmeldung in den zweiten Runspace traegt, ist gemessen und nicht angenommen:
# GraphSession::Instance ist ein statisches Singleton (tests/Unit/GraphSessionSharing.Tests.ps1),
# und das Inventar wird laengst so gelesen.
function Invoke-WtDeployOffThread {
  param(
    [Parameter(Mandatory)][hashtable]$Arguments,
    [string]$Label = 'upload'
  )
  $rs = $null
  # Besetzt heisst hier nicht "warten": zwei Uploads gleichzeitig gibt es nicht (die Busy-Sperre
  # haelt sie auseinander), aber wenn doch, ist inline richtig und nicht eine zweite Pipeline im
  # selben Runspace - die liefe in "Pipelines cannot be run concurrently".
  if (-not $script:deployRunspaceInUse) {
    try { $rs = Get-DeployRunspace } catch { $rs = $null }
  }
  if (-not $rs) {
    Write-Log ("Uploading {0} on the UI thread (no background runspace); the window will not respond until it finishes." -f $Label)
    return Deploy-WtWin32App @Arguments
  }

  $ps = [powershell]::Create()
  $ps.Runspace = $rs
  [void]$ps.AddCommand('Deploy-WtWin32App').AddParameters($Arguments)
  $script:deployRunspaceInUse = $true
  try {
    $async = $ps.BeginInvoke()
    # Das ist der ganze Gewinn: der UI-Faden pumpt seine Nachrichtenschleife, waehrend der Upload
    # auf dem anderen Thread laeuft. Das Fenster zeichnet, das Protokoll laesst sich aufklappen.
    while (-not $async.AsyncWaitHandle.WaitOne(50)) {
      [System.Windows.Forms.Application]::DoEvents()
    }
    $out = $ps.EndInvoke($async)
    if ($ps.Streams.Error.Count -gt 0) {
      # Deploy-WtWin32App wird mit ErrorAction Stop gerufen, ein abbrechender Fehler kommt also aus
      # EndInvoke als Ausnahme. Was im Strom liegenbleibt, wird unveraendert weitergeworfen.
      throw (($ps.Streams.Error | ForEach-Object { $_.ToString() }) -join '; ')
    }
    if ($out -and $out.Count -gt 0) { return $out[$out.Count - 1] }
    return $null
  } catch {
    # BeginInvoke/EndInvoke verpacken den Modulfehler. Ausgepackt, damit die Textpruefungen der
    # Aufrufer weiter greifen.
    if ($_.Exception.InnerException -and $_.Exception.InnerException.Message) {
      throw $_.Exception.InnerException.Message
    }
    throw
  } finally {
    $script:deployRunspaceInUse = $false
    try { $ps.Dispose() } catch { }   # class 3: teardown
  }
}

# Uebernimmt das Ergebnis des Vorab-Baus - aber NUR bei exakt gleichem Argumentsatz.
#
# Das ist die Stelle, an der ein Fehler teuer waere: uebernaehme sie ein Paket, das mit anderen
# Optionen gebaut wurde, faellt das nicht beim Bauen auf, sondern erst auf den Endgeraeten. Deshalb
# entscheidet der Schluessel ueber den VOLLSTAENDIGEN Satz, und ein nicht passender Vorab-Bau wird
# verworfen statt irgendwie verwertet.
#
# Gibt $null zurueck, wenn nichts zu uebernehmen ist - dann baut der Aufrufer wie bisher selbst.
function Get-PrebuildResult {
  param([Parameter(Mandatory)][hashtable]$Arguments, [string]$Label = '', [int]$TimeoutMinutes = 30)
  if (-not $script:prebuild) { return $null }

  $wanted = Get-PackageBuildKey -Arguments $Arguments
  if (-not [string]::Equals($wanted, [string]$script:prebuild.Key, [System.StringComparison]::Ordinal)) {
    Stop-PackagePrebuild -Reason ("does not match what {0} needs" -f $Label)
    return $null
  }

  # Erst aus dem Skript-Bereich nehmen, dann warten: sonst koennte ein zweiter Aufruf waehrend des
  # Wartens denselben Bau ein zweites Mal einsammeln.
  $pb = $script:prebuild
  $script:prebuild = $null
  try {
    while (-not $pb.Handle.IsCompleted) {
      [System.Windows.Forms.Application]::DoEvents()
      Start-Sleep -Milliseconds 60
      if ($script:cancelBatch) {
        try { $pb.Shell.Stop() } catch { }   # class 3: teardown
        Write-Log ("Prebuild for {0} canceled by user." -f $pb.Label)
        return @{ Succeeded = $false; Result = $null; ErrorMessage = 'Canceled by user'; TimedOut = $false }
      }
      if ($pb.Stopwatch.Elapsed.TotalMinutes -ge $TimeoutMinutes) {
        try { $pb.Shell.Stop() } catch { }   # class 3: teardown
        Write-Log ("Prebuild for {0} timed out after {1} minute(s)." -f $pb.Label, $TimeoutMinutes)
        return @{ Succeeded = $false; Result = $null; ErrorMessage = "Packaging timed out after $TimeoutMinutes minute(s)"; TimedOut = $true }
      }
    }
    $out = $pb.Shell.EndInvoke($pb.Handle)
    if ($pb.Shell.Streams.Error.Count -gt 0) {
      $msg = ($pb.Shell.Streams.Error | ForEach-Object { $_.ToString() }) -join '; '
      Write-Log ("Prebuild for {0} failed; the run continues as if there had been none: {1}" -f $pb.Label, $msg)
      return @{ Succeeded = $false; Result = $null; ErrorMessage = $msg; TimedOut = $false }
    }
    $result = if ($out -and $out.Count -gt 0) { $out[$out.Count - 1] } else { $null }
    Write-Log ("Prebuild adopted for {0}: the package was already built ({1:n1}s ago), nothing was built twice." -f $Label, $pb.Stopwatch.Elapsed.TotalSeconds)
    return @{ Succeeded = $true; Result = $result; ErrorMessage = $null; TimedOut = $false }
  } catch {
    $em = $_.Exception.Message
    if ($_.Exception.InnerException -and $_.Exception.InnerException.Message) { $em = $_.Exception.InnerException.Message }
    Write-Log ("Prebuild for {0} failed; the run continues as if there had been none: {1}" -f $pb.Label, $em)
    return @{ Succeeded = $false; Result = $null; ErrorMessage = $em; TimedOut = $false }
  } finally {
    try { $pb.Shell.Dispose() } catch { }   # class 3: teardown
  }
}

# Entscheidet, auf WELCHE Version zurueckgefallen wird, wenn die neueste nicht baubar ist.
#
# Die Regel steht bewusst an einer Stelle und ohne Fenster, damit sie pruefbar ist: die
# naechstaeltere angebotene Version, und nur dann, wenn sie gegenueber dem, was im Tenant liegt,
# ueberhaupt noch ein Update ist. Ein Rueckfall auf eine Version, die der Tenant schon hat, waere
# kein Notnagel, sondern ein Rueckschritt - und ein Paket, das niemand braucht.
function Get-PackageFallbackVersion {
  param([string]$PackageId, [string]$LatestVersion, [string]$InstalledVersion)
  $prev = Get-PreviousWingetVersion -PackageId $PackageId -LatestVersion $LatestVersion
  if (-not $prev) { return $null }
  if ($InstalledVersion -and -not (Test-IsNewerVersion $prev $InstalledVersion)) { return $null }
  return $prev
}

# Baut die Ausweichversion. Bis 0.17.0 stand dieser Block drei Mal fast gleich in
# New-WingetPackageWithFallback (404, Rueckfrage "Nein", und gar nicht im unbeaufsichtigten Lauf);
# einmal davon ohne Protokollzeile, sodass ein stillschweigend aelteres Paket im Tenant landete.
#
# $Reason nennt den Grund im Klartext, weil im Protokoll sonst nur eine Version steht, die niemand
# angefordert hat.
function Invoke-PackageFallbackBuild {
  param(
    [Parameter(Mandatory)][hashtable]$Arguments,
    [string]$PackageId,
    [string]$LatestVersion,
    [string]$InstalledVersion,
    [int]$ThrottleRetries = 3,
    [string]$Reason = 'the newest version could not be built',
    [string]$OriginalError
  )
  $deployed = if ($InstalledVersion) { $InstalledVersion } else { '(unknown)' }
  $prev = Get-PackageFallbackVersion -PackageId $PackageId -LatestVersion $LatestVersion -InstalledVersion $InstalledVersion
  if (-not $prev) {
    Write-Log ("Package fallback for {0}: {1} ({2}), and no older offered version is left that would still be an update over the deployed {3}. Nothing was built." -f $PackageId, $Reason, $LatestVersion, $deployed)
    return [pscustomobject]@{ Succeeded=$false; EffectiveVersion=$null; UsedFallbackVersion=$false; ErrorMessage=$OriginalError }
  }
  Write-Log ("Package fallback for {0}: {1} ({2}); building the previously offered {3} instead - it is still an update over the deployed {4}." -f $PackageId, $Reason, $LatestVersion, $prev, $deployed)
  try {
    [void](Invoke-PackageBuildWithThrottleRetry -Arguments ($Arguments + @{ Version = $prev }) -Label $PackageId -MaxRetries $ThrottleRetries)
    Write-Log ("Package fallback for {0}: {1} built successfully; {2} stays open until the upstream installer matches its manifest hash again." -f $PackageId, $prev, $LatestVersion)
    return [pscustomobject]@{ Succeeded=$true; EffectiveVersion=$prev; UsedFallbackVersion=$true }
  } catch {
    Write-Log ("Package fallback for {0}: the previously offered {1} failed to build as well: {2}" -f $PackageId, $prev, $_.Exception.Message)
    return [pscustomobject]@{ Succeeded=$false; EffectiveVersion=$null; UsedFallbackVersion=$false; ErrorMessage=$_.Exception.Message }
  }
}

function New-WingetPackageWithFallback {
  param(
    [string]$PackageId,
    [string]$PackageFolder,
    [string]$DesiredVersion,
    [string]$LatestVersion,
    [string]$InstalledVersion,
    [string]$Architecture,
    [string]$InstallerContext,
    [string]$Locale,
    [string]$PreferredInstaller,
    [string]$InstallerArguments,
    [switch]$PackageScript,
    [switch]$AllowUserRetry,
    # Wie oft eine HTTP-429-Sperre abgewartet wird. Der automatische Favoritenlauf beim Start setzt
    # das auf 1: 5 s statt 5+15+30 s. Er laeuft unbeaufsichtigt, blockiert aber die Busy-Sperre und
    # damit die Anmeldung samt Update-Suche - im gemeldeten Protokoll 35 s Wartezeit fuer ein Paket,
    # das danach ohnehin an einer Hash-Abweichung scheiterte.
    [int]$ThrottleRetries = 3
  )
  # Der Argumentsatz kommt aus Get-WingetPackageArguments - derselben Funktion, die auch der
  # Vorab-Bau benutzt. Nur so kann sein Ergebnis hier gefahrlos uebernommen werden.
  $base = Get-WingetPackageArguments -PackageId $PackageId -PackageFolder $PackageFolder `
    -Architecture $Architecture -InstallerContext $InstallerContext -Locale $Locale `
    -PreferredInstaller $PreferredInstaller -InstallerArguments $InstallerArguments `
    -PackageScript:$PackageScript

  $attemptVersion = $DesiredVersion
  if (-not $attemptVersion) { $attemptVersion = $LatestVersion }
  try {
    if ($attemptVersion) { [void](Invoke-PackageBuildWithThrottleRetry -Arguments ($base + @{ Version = $attemptVersion }) -Label $PackageId -MaxRetries $ThrottleRetries) }
    else { [void](Invoke-PackageBuildWithThrottleRetry -Arguments $base -Label $PackageId -MaxRetries $ThrottleRetries) }
    return [pscustomobject]@{ Succeeded=$true; EffectiveVersion=$attemptVersion; UsedFallbackVersion=$false }
  } catch {
    $m = $_.Exception.Message
    $latest = if ($attemptVersion) { $attemptVersion } else { $LatestVersion }
    $fallbackArgs = @{
      Arguments = $base; PackageId = $PackageId; LatestVersion = $latest
      InstalledVersion = $InstalledVersion; ThrottleRetries = $ThrottleRetries; OriginalError = $m
    }

    if ($m -match '404' -or $m -match 'Not Found') {
      return (Invoke-PackageFallbackBuild @fallbackArgs -Reason 'the manifest for the newest version is gone from the WinGet repository')
    }

    if ($m -notmatch 'Hash mismatch') { return [pscustomobject]@{ Succeeded=$false; EffectiveVersion=$null; UsedFallbackVersion=$false; ErrorMessage=$m } }

    # Eine Hash-Abweichung heisst: der Hersteller hat den Installer unter derselben Adresse
    # ausgetauscht, das WinGet-Manifest kennt aber noch die alte Pruefsumme. Das ist nichts, was ein
    # zweiter Versuch heilt, und es dauert regelmaessig Tage, bis das Manifest nachzieht.
    if ($AllowUserRetry) {
      $res = [System.Windows.Forms.MessageBox]::Show((Get-UiString 'HashMismatchDialog'), (Get-UiString 'HashMismatchTitle'), [System.Windows.Forms.MessageBoxButtons]::YesNoCancel, [System.Windows.Forms.MessageBoxIcon]::Warning, [System.Windows.Forms.MessageBoxDefaultButton]::Button1)
      if ($res -eq [System.Windows.Forms.DialogResult]::Yes) {
        try {
          if ($attemptVersion) { [void](Invoke-PackageBuildWithThrottleRetry -Arguments ($base + @{ Version = $attemptVersion }) -Label $PackageId -MaxRetries $ThrottleRetries) }
          else { [void](Invoke-PackageBuildWithThrottleRetry -Arguments $base -Label $PackageId -MaxRetries $ThrottleRetries) }
          return [pscustomobject]@{ Succeeded=$true; EffectiveVersion=$attemptVersion; UsedFallbackVersion=$false }
        } catch { return [pscustomobject]@{ Succeeded=$false; EffectiveVersion=$null; UsedFallbackVersion=$false; ErrorMessage=$_.Exception.Message } }
      }
      if ($res -ne [System.Windows.Forms.DialogResult]::No) { return [pscustomobject]@{ Succeeded=$false; EffectiveVersion=$null; UsedFallbackVersion=$false; ErrorMessage="Cancelled by user" } }
      return (Invoke-PackageFallbackBuild @fallbackArgs -Reason 'hash mismatch, and the user chose the previous version')
    }

    # Ohne Rueckfrage - der Stapellauf reicht -AllowUserRetry nicht durch - brach der Lauf hier bis
    # 0.17.0 einfach ab, und die App blieb auf ihrem alten Stand stehen, bis jemand das Protokoll
    # las. Ueber Wochen wird daraus genau die Luecke, die dieses Werkzeug schliessen soll. Die
    # naechstaeltere angebotene Version ist kein Ersatz fuer die neueste, aber sie ist ein Update.
    return (Invoke-PackageFallbackBuild @fallbackArgs -Reason 'hash mismatch on the newest version')
  }
}

# Decides whether a folder is a protected Windows location that must never receive packages.
#
# Split out of Test-PackageFolderUsable so it can be tested: the caller shows a MessageBox, which
# makes it untestable, while THIS is the part that has to be right.
#
# Both comparisons ignore case on purpose. PowerShell's -eq does so by default, but .NET's
# String.StartsWith(String) does NOT - so "c:\program files\pakete" walked straight past a guard
# that "C:\Program Files\pakete" tripped. Windows paths are case-insensitive; a guard that is not
# only protects the spelling the caller happened to type.
function Test-IsProtectedSystemFolder {
  param([Parameter(Mandatory)][string]$Folder)
  $candidate = ([string]$Folder).Trim().TrimEnd([char]'\')
  if ([string]::IsNullOrWhiteSpace($candidate)) { return $false }
  $forbidden = @(
    [Environment]::GetFolderPath('Windows'),
    [Environment]::GetFolderPath('System'),
    "$env:SystemRoot\System32",
    "$env:SystemRoot\SysWOW64",
    "$env:ProgramFiles",
    "${env:ProgramFiles(x86)}"
  ) | Where-Object { $_ } | ForEach-Object { ([string]$_).TrimEnd([char]'\') }

  foreach ($p in $forbidden) {
    if ([string]::Equals($candidate, $p, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ($candidate.StartsWith($p + '\', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
  }
  return $false
}

# Single gate for the package folder, used by every packaging/update flow (this check used to be
# copy-pasted four times and only covered system paths). Verifies: not a protected system location,
# creatable, actually WRITABLE (proven with a probe file, so a missing permission surfaces here
# instead of as a cryptic packaging error), and warns on low free disk space because packaging
# downloads installers. Returns $true when packaging may proceed.
function Test-PackageFolderUsable {
  param([Parameter(Mandatory)][string]$Folder)
  try {
    if (Test-IsProtectedSystemFolder -Folder $Folder) {
      [void][System.Windows.Forms.MessageBox]::Show(
        ((Get-UiString 'InvalidFolderDialog') -f $Folder),
        (Get-UiString 'InvalidFolderTitle'),
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning)
      return $false
    }

    # -LiteralPath / [IO.*] throughout: a package folder like 'Intune Pakete [Kunde]' otherwise made
    # the write probe fail (the '[' is a wildcard for -Path), and a perfectly writable folder was
    # reported to the user as "not writable". New-Item has no -LiteralPath, so use [IO.Directory].
    if (-not (Test-Path -LiteralPath $Folder)) { [void][System.IO.Directory]::CreateDirectory($Folder) }

    # Prove write access rather than assuming it.
    $probe = Join-Path $Folder (".wtgui_write_test_{0}.tmp" -f ([guid]::NewGuid().ToString('N')))
    [System.IO.File]::WriteAllText($probe, 'x')
    try { [System.IO.File]::Delete($probe) } catch { }

    # Low-space warning (non-blocking – the user decides whether to continue).
    try {
      $root = [System.IO.Path]::GetPathRoot($Folder)
      if ($root) {
        $drv = Get-PSDrive -Name ($root.TrimEnd(':\/')) -ErrorAction SilentlyContinue
        if ($drv -and $null -ne $drv.Free) {
          $freeGb = [math]::Round($drv.Free / (1024 * 1024 * 1024), 1)
          if ($freeGb -lt 2) {
            $go = [System.Windows.Forms.MessageBox]::Show(
              ((Get-UiString 'LowDiskSpaceDialog') -f $freeGb, $Folder),
              (Get-UiString 'LowDiskSpaceTitle'),
              [System.Windows.Forms.MessageBoxButtons]::YesNo,
              [System.Windows.Forms.MessageBoxIcon]::Warning)
            if ($go -ne [System.Windows.Forms.DialogResult]::Yes) { return $false }
          }
        }
      }
    } catch {
      # The folder stays usable, but the user loses the low-disk-space warning before a build.
      Write-Log ("Free space check for '{0}' failed: {1}" -f $Folder, $_.Exception.Message)
    }

    return $true
  } catch {
    [void][System.Windows.Forms.MessageBox]::Show(
      ((Get-UiString 'FolderNotWritableDialog') -f $Folder, $_.Exception.Message),
      (Get-UiString 'FolderNotWritableTitle'),
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Error)
    Write-Log "Package folder unusable ($Folder): $($_.Exception.Message)"
    return $false
  }
}

# Force-removes an app that Intune blocks because it is still the supersedence PARENT of a newer
# app: it removes the supersedence link (new -> old) from the NEW app – keeping every other
# relationship untouched – and then deletes the old app. Uses raw Graph via the already-authenticated
# Graph REST calls authenticated with WinTuner's own token. Best-effort: on ANY doubt it aborts and returns
# $false, so the caller falls back to simply keeping the old app (nothing is left in a worse state).
# NOTE: this mutates Intune relationships and deletes an app – validate on a test app first.
function Remove-SupersededByUnlinking {
  param([Parameter(Mandatory)][string]$OldAppId, [Parameter(Mandatory)][string]$NewAppId)
  if (-not (Test-GuidString $OldAppId) -or -not (Test-GuidString $NewAppId)) { Write-Log "Unlink: invalid app id(s), aborting."; return $false }
  # Use WinTuner's OWN access token. Invoke-MgGraphRequest was the first attempt, but it needs a
  # separate Connect-MgGraph session – WinTuner authenticates through its own flow, so that call
  # always failed with "Authentication needed. Please call Connect-MgGraph." Get-WtToken hands back
  # the token of the session the user is actually connected with. (Never logged.)
  $token = $null
  try { $token = Get-WtToken -ErrorAction Stop } catch { Write-Log "Unlink: could not obtain WinTuner token: $($_.Exception.Message)"; return $false }
  if ([string]::IsNullOrWhiteSpace($token)) { Write-Log "Unlink: empty token, aborting."; return $false }
  $headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
  try {
    $relUri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$NewAppId/relationships"
    $rels = @(Get-GraphCollectionItems -Uri $relUri -Headers $headers)
    # Keep only OUTGOING relationships (this app is the source), minus the supersedence to the old app.
    $keep = @(); $originalOutgoing = @(); $removed = 0
    foreach ($r in $rels) {
      # Invoke-RestMethod returns PSCustomObjects (Invoke-MgGraphRequest returned hashtables), so
      # properties are accessed with dot notation here.
      $type = [string]$r.'@odata.type'; $src = [string]$r.sourceId; $tid = [string]$r.targetId
      if ($src -ne $NewAppId) { continue }   # incoming relationship – not part of updateRelationships
      if ([string]::IsNullOrWhiteSpace($type) -or -not (Test-GuidString $tid)) {
        Write-Log ("Unlink: outgoing relationship on {0} is incomplete (type='{1}', target='{2}'); aborting before mutation." -f $NewAppId, $type, $tid)
        return $false
      }
      $item = @{ '@odata.type' = $type; 'targetId' = $tid }
      if ($r.PSObject.Properties['supersedenceType'] -and $r.supersedenceType) { $item['supersedenceType'] = $r.supersedenceType }
      if ($r.PSObject.Properties['dependencyType']   -and $r.dependencyType)   { $item['dependencyType']   = $r.dependencyType }
      $originalOutgoing += $item
      if ($type -match 'Supersedence' -and $tid -eq $OldAppId) { $removed++; continue }
      $keep += $item
    }
    if ($removed -eq 0) { Write-Log "Unlink: no outgoing supersedence $NewAppId -> $OldAppId found; aborting (won't risk a blind delete)."; return $false }
    $body = @{ relationships = @($keep) } | ConvertTo-Json -Depth 8
    $updUri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$NewAppId/updateRelationships"
    # updateRelationships ERSETZT die Beziehungsliste durch die mitgeschickte, ist also idempotent -
    # ein zweiter Versuch nach einer Drosselung hinterlaesst denselben Zustand wie der erste.
    Invoke-GraphRest -Method POST -Uri $updUri -Headers $headers -Body $body `
      -Context ("unlink supersedence on {0}" -f $NewAppId) | Out-Null
    Write-Log ("Unlink: removed supersedence {0} -> {1}; kept {2} other outgoing relationship(s)." -f $NewAppId, $OldAppId, $keep.Count)
    Start-Sleep -Seconds 2
    try {
      Invoke-WtRemoveWin32App -AppId $OldAppId
    } catch {
      $deleteError = $_.Exception.Message
      # The relationship mutation succeeded but deletion did not. Restore the original outgoing
      # relationship set so a transient delete failure never silently breaks supersedence.
      try {
        $restoreBody = @{ relationships = @($originalOutgoing) } | ConvertTo-Json -Depth 8
        Invoke-GraphRest -Method POST -Uri $updUri -Headers $headers -Body $restoreBody `
          -Context ("restore supersedence on {0}" -f $NewAppId) | Out-Null
        Write-Log ("Unlink rollback: restored {0} outgoing relationship(s) on {1} after delete failed." -f $originalOutgoing.Count, $NewAppId)
      } catch {
        Write-Log ("CRITICAL: could not restore relationships on {0} after delete of {1} failed: {2}" -f $NewAppId, $OldAppId, $_.Exception.Message)
      }
      throw $deleteError
    }
    Write-Log "Unlink: old app $OldAppId deleted after removing the supersedence link."
    return $true
  } catch {
    Write-Log ("Unlink: failed for old app {0} (kept it): {1}" -f $OldAppId, $_.Exception.Message)
    return $false
  }
}

