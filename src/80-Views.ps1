# Stat tiles: big number + caption inside a rounded card. Numbers load on connect.
function New-DashTile {
  param([int]$X, [int]$Y = 56, [string]$Caption, [string]$Target)
  $card = New-Card -X $X -Y $Y -W 170 -H 96
  $tabDashboard.Controls.Add($card)
  $num = New-Object System.Windows.Forms.Label
  $num.Text = [System.Char]::ConvertFromUtf32(0x2014)   # em dash placeholder
  $num.Location = New-Object System.Drawing.Point(18, 10)
  $num.AutoSize = $true
  # 22pt (was 26pt): a 26pt number label is 54px tall and its bottom (Y=66) overlapped the caption
  # at Y=64 – a real 2–3 digit count would collide with the caption text. 22pt + the positions below
  # give a clean ~6px gap, and number/caption share the same left edge (x=18).
  $num.Font = New-Object System.Drawing.Font("Segoe UI", 22, [System.Drawing.FontStyle]::Bold)
  $card.Controls.Add($num)
  $cap = New-Object System.Windows.Forms.Label
  $cap.Text = $Caption
  $cap.Location = New-Object System.Drawing.Point(18, 62)
  $cap.AutoSize = $true
  $card.Controls.Add($cap)
  # Make the whole tile a click target that jumps to the relevant section (card + both labels share
  # the handler so a click anywhere on the tile works).
  # IMPORTANT: no .GetNewClosure() here. A closure runs in its own dynamic module, which cannot see
  # SCRIPT-scope functions – the previous version threw "Show-Section is not recognized" on every
  # tile click. The target is carried on the control's .Name and read back from the sender instead
  # (same proven pattern as the sidebar nav buttons). .Name is free; .Tag is taken by the themer.
  if ($Target) {
    # Hover: die Kachel hebt sich leicht ab, solange der Zeiger darauf steht. Der Handcursor allein
    # verraet die Klickbarkeit erst, wenn man schon darauf zeigt - und nie im Screenshot.
    $enter = {
      param($sender, $e)
      try {
        $tile = if ($sender -is [System.Windows.Forms.Panel]) { $sender } else { $sender.Parent }
        if ($tile) { $tile.BackColor = Get-DimmedColor -Fore $script:currentTheme.ForeColor -Back (Get-CardBackColor $script:currentTheme) -Ratio 0.10 }
      } catch { }
    }
    $leave = {
      param($sender, $e)
      try {
        $tile = if ($sender -is [System.Windows.Forms.Panel]) { $sender } else { $sender.Parent }
        if ($tile) { $tile.BackColor = Get-CardBackColor $script:currentTheme }
      } catch { }
    }
    foreach ($c in @($card, $num, $cap)) {
      $c.Cursor = [System.Windows.Forms.Cursors]::Hand
      $c.Name = "dashtile_$Target"
      $c.Add_MouseEnter($enter)
      $c.Add_MouseLeave($leave)
      $c.Add_Click({
        param($sender, $e)
        try { Show-Section ($sender.Name.Substring(9)) }   # strip "dashtile_"
        catch { try { Write-Log ("Dashboard tile click error: {0}" -f $_.Exception.Message) } catch {} }
      })
    }
  }
  return $num
}
# Zwei Gruppen, nicht eine Reihe aus vier gleichen Kacheln.
#
# Drei der Kacheln zaehlen im verbundenen Tenant, die vierte misst Speicherplatz auf DIESEM Rechner.
# In derselben Reihe und derselben Form gelesen, sah das nach vier Zahlen derselben Art aus - und die
# lokale Kachel war die einzige, die auch ohne Anmeldung schon einen Wert zeigte, direkt neben dem
# Hinweis, man muesse sich erst verbinden. Die Beschriftung darueber trennt die zwei Welten, die
# Einstellungsseite ordnet inzwischen nach derselben Grenze.
$dashTenantGroupLabel = New-Object System.Windows.Forms.Label
$dashTenantGroupLabel.Tag = 'hint'
$dashTenantGroupLabel.Text = Get-UiString 'DashGroupTenant'
$dashTenantGroupLabel.Location = New-Object System.Drawing.Point(18, 46)
$dashTenantGroupLabel.AutoSize = $true
$tabDashboard.Controls.Add($dashTenantGroupLabel)

$dashLocalGroupLabel = New-Object System.Windows.Forms.Label
$dashLocalGroupLabel.Tag = 'hint'
$dashLocalGroupLabel.Text = Get-UiString 'DashGroupLocal'
$dashLocalGroupLabel.Location = New-Object System.Drawing.Point(586, 46)
$dashLocalGroupLabel.AutoSize = $true
$tabDashboard.Controls.Add($dashLocalGroupLabel)

$script:dashManagedVal    = New-DashTile -X 16  -Y 68 -Caption (Get-UiString 'DashManaged')    -Target 'updates'
$script:dashUpdatesVal    = New-DashTile -X 198 -Y 68 -Caption (Get-UiString 'DashUpdates')    -Target 'updates'
$script:dashSupersededVal = New-DashTile -X 380 -Y 68 -Caption (Get-UiString 'DashSuperseded') -Target 'updates'
# Die Kachel wurde als "Apps, die ein Update brauchen" gelesen und stand direkt neben genau dieser
# Kachel. Sie zaehlt ABGELOESTE Versionen - eine Zahl, die mit jedem Update waechst.
# Die vierte Kachel braucht keinen Tenant: der Paketordner waechst ueber Monate still mit, und
# nichts zeigte je darauf. Ein Klick landet in den Einstellungen, wo der Aufraeum-Knopf steht.
# 24 px Abstand statt 12 - der Sprung ist die Grenze zwischen den beiden Gruppen.
$script:dashPackagesVal = New-DashTile -X 574 -Y 68 -Caption (Get-UiString 'DashLocalPackages') -Target 'settings'

# Size of the local package folder, formatted for the tile. Deliberately cheap to fail: an
# unreadable or missing folder shows a dash rather than blocking the dashboard.
function Update-LocalPackagesTile {
  try {
    if (-not $script:dashPackagesVal) { return }
    $root = [string]$script:settings.DefaultPackagePath
    if (-not $root -or -not (Test-Path -LiteralPath $root -PathType Container)) {
      $script:dashPackagesVal.Text = [System.Char]::ConvertFromUtf32(0x2014)
      return
    }
    $bytes = Get-FolderSizeBytes -Path $root
    $script:dashPackagesVal.Text = if ($bytes -ge 1GB) { '{0:n1} GB' -f ($bytes / 1GB) }
                                   elseif ($bytes -ge 1MB) { '{0:n0} MB' -f ($bytes / 1MB) }
                                   else { '{0:n0} KB' -f ($bytes / 1KB) }
  } catch { }   # class 3: a tile must never break the dashboard
}
Update-LocalPackagesTile

$dashHint = New-Object System.Windows.Forms.Label
$dashHint.Text = Get-UiString 'DashConnectHint'
$dashHint.Location = New-Object System.Drawing.Point(18, 172)
$dashHint.AutoSize = $true
$tabDashboard.Controls.Add($dashHint)

# Der Stand gehoert neben die Zahlen, nicht ins Protokoll: die Kacheln werden nicht mehr bei jedem
# Besuch neu geladen (das war das kurze Einfrieren), also muss die Oberflaeche sagen, WANN sie
# gemessen wurden.
#
# Einen Knopf "Jetzt aktualisieren" gab es hier kurz; er ist auf Wunsch wieder weg. Neu geladen wird
# ohnehin bei der Anmeldung und nach jedem Eingriff (siehe $script:dashboardStale) - der Knopf haette
# nur die Zeile verbreitert, ohne eine Frage zu beantworten, die die Zeile nicht schon beantwortet.
function Update-DashboardFreshness {
  if (-not $dashHint) { return }
  if (-not $script:isConnected) {
    $dashHint.Text = Get-UiString 'DashConnectHint'
    return
  }
  if ($script:dashboardLastRefresh -eq [datetime]::MinValue) {
    $dashHint.Text = Get-UiString 'LoadingAppsStatus'
  } else {
    $local = $script:dashboardLastRefresh.ToLocalTime().ToString('HH:mm')
    $key = if ($script:dashboardStale) { 'DashStaleHint' } else { 'DashAsOfLabel' }
    $dashHint.Text = (Get-UiString $key) -f $local
  }
}

$dashActionsLabel = New-Object System.Windows.Forms.Label
$dashActionsLabel.Text = Get-UiString 'DashQuickActions'
$dashActionsLabel.Location = New-Object System.Drawing.Point(16, 208)
$dashActionsLabel.AutoSize = $true
$dashActionsLabel.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
$tabDashboard.Controls.Add($dashActionsLabel)

$dashAddBtn = New-Object System.Windows.Forms.Button
$dashAddBtn.Text = Get-UiString 'DashAddApp'
$dashAddBtn.Location = New-Object System.Drawing.Point(16, 240)
$dashAddBtn.Size = New-Object System.Drawing.Size(224, 40)
$dashAddBtn.Add_Click({ Show-Section 'winget' })
$tabDashboard.Controls.Add($dashAddBtn)

$dashUpdBtn = New-Object System.Windows.Forms.Button
$dashUpdBtn.Tag = 'btn-secondary'
$dashUpdBtn.Text = Get-UiString 'DashCheckUpdates'
$dashUpdBtn.Location = New-Object System.Drawing.Point(256, 240)
$dashUpdBtn.Size = New-Object System.Drawing.Size(224, 40)
$dashUpdBtn.Add_Click({ Show-Section 'updates' })
$tabDashboard.Controls.Add($dashUpdBtn)

$dashScanBtn = New-Object System.Windows.Forms.Button
$dashScanBtn.Tag = 'btn-secondary'
$dashScanBtn.Text = Get-UiString 'DashScanDiscovered'
$dashScanBtn.Location = New-Object System.Drawing.Point(496, 240)
$dashScanBtn.Size = New-Object System.Drawing.Size(224, 40)
$dashScanBtn.Add_Click({ Show-Section 'discovered' })
$tabDashboard.Controls.Add($dashScanBtn)

# Row two: these DO something instead of only navigating. All three are local-only - no tenant is
# touched - which is why they are safe one click away. Anything that writes to Intune stays behind
# its own section and confirmation, as the security model requires.
$dashFavBtn = New-Object System.Windows.Forms.Button
$dashFavBtn.Tag = 'btn-secondary'
$dashFavBtn.Text = Get-UiString 'DashCheckFavorites'
$dashFavBtn.Location = New-Object System.Drawing.Point(16, 288)
$dashFavBtn.Size = New-Object System.Drawing.Size(224, 40)
$dashFavBtn.Add_Click({
  # Switch first, so the run is visible where its results appear - the way the login auto-check does.
  Show-Section 'localpackages'
  [System.Windows.Forms.Application]::DoEvents()
  try { if ($favoriteRefreshButton -and $favoriteRefreshButton.Enabled) { $favoriteRefreshButton.PerformClick() } }
  catch { Write-Log ("Dashboard favourite check failed: {0}" -f $_.Exception.Message) }
})
$tabDashboard.Controls.Add($dashFavBtn)

$dashLocalBtn = New-Object System.Windows.Forms.Button
$dashLocalBtn.Tag = 'btn-secondary'
$dashLocalBtn.Text = Get-UiString 'DashUpdateLocal'
$dashLocalBtn.Location = New-Object System.Drawing.Point(256, 288)
$dashLocalBtn.Size = New-Object System.Drawing.Size(224, 40)
$dashLocalBtn.Add_Click({
  Show-Section 'localpackages'
  [System.Windows.Forms.Application]::DoEvents()
  try { if ($favoriteAllLocalButton -and $favoriteAllLocalButton.Enabled) { $favoriteAllLocalButton.PerformClick() } }
  catch { Write-Log ("Dashboard local update failed: {0}" -f $_.Exception.Message) }
})
$tabDashboard.Controls.Add($dashLocalBtn)

$dashRecordBtn = New-Object System.Windows.Forms.Button
$dashRecordBtn.Tag = 'btn-secondary'
$dashRecordBtn.Text = Get-UiString 'DashShowRecord'
$dashRecordBtn.Location = New-Object System.Drawing.Point(496, 288)
$dashRecordBtn.Size = New-Object System.Drawing.Size(224, 40)
$dashRecordBtn.Add_Click({
  try { Show-LeistungstextDialog } catch { Write-Log ("Dashboard record dialog failed: {0}" -f $_.Exception.Message) }
})
$tabDashboard.Controls.Add($dashRecordBtn)

# Loads the tile numbers (safe no-op when not connected). Runs SYNCHRONOUSLY on the UI thread -
# the comment inside says why a worker thread cannot do it. The cooldown is what keeps that from
# being felt on every navigation.
$script:dashboardLastRefresh = [datetime]::MinValue
$script:dashboardRefreshing = $false
$script:dashboardRefreshCooldownSeconds = 30
# Gesetzt von allem, was die Kachelzahlen aendert (Update-Lauf, Versionsbereinigung, Loeschen einer
# abgeloesten App, neue Bereitstellung). Der naechste Besuch des Dashboards laedt dann neu - ohne
# diesen Merker zeigte es nach einem Lauf die Zahlen von vorher, und genau das war die Beschwerde
# "8 veraltete Apps stimmt nicht mehr".
$script:dashboardStale = $false

function Refresh-Dashboard {
  param(
    # Set by the manual refresh path; navigation always goes through the cooldown.
    [switch]$Force
  )
  if (-not $script:isConnected) { return }

  # Re-entrancy guard. The DoEvents call below pumps the message loop, so a second navigation to
  # the dashboard could start this function again while the first run was still enumerating -
  # which produced "Collection was modified; enumeration operation may not execute".
  if ($script:dashboardRefreshing) { return }

  # Every run costs three tenant queries, and each one makes the WinTuner module log "Getting list
  # of published apps". Refreshing on every single navigation turned normal clicking around into a
  # constant stream of queries, so repeat visits reuse the tiles until the cooldown has passed.
  if (-not $Force) {
    $age = ([datetime]::UtcNow - $script:dashboardLastRefresh).TotalSeconds
    if ($age -lt $script:dashboardRefreshCooldownSeconds) { return }
  }
  $script:dashboardRefreshing = $true
  # Die Kachel-Zahlen kommen aus Get-CachedWin32Apps, und die Inventar-Abfrage darunter laeuft
  # inzwischen im Paket-Runspace (Get-Win32AppsOffThread) - das Fenster zeichnet also waehrend des
  # Ladens. Der frueher hier stehende Satz, der Graph-Kontext lebe nur im Haupt-Runspace, war
  # falsch: die GraphSession ist ein prozessweites Singleton (siehe die Notiz in 70-Runtime).
  try {
    Update-Status (Get-UiString 'LoadingAppsStatus')
    [System.Windows.Forms.Application]::DoEvents()
    # Read-only tiles: a few seconds of cache is invisible here and removes three module queries
    # per visit. -Force honours the explicit refresh after sign-in.
    $all = @(Get-CachedWin32Apps -Force:$Force)
    $sup = @(Get-CachedWin32Apps -Superseded -Force:$Force)
    # "0 verwaltete Apps, aber 6 abgeloeste" ist unmoeglich - so stand es aber im Protokoll, nachdem
    # die Modul-Abfrage in ihren Wettlauf gelaufen war. Die Kacheln haetten die 0 als Tatsache
    # hingeschrieben. Also: einmal erzwungen nachlesen, und wenn der Widerspruch bleibt, KEINE Zahl
    # behaupten, sondern es sagen.
    # 0 verwaltete Apps neben abgeloesten Versionen ist auffaellig - aber nicht zwingend falsch:
    # wurden die neuesten Versionen geloescht, bleiben die alten mit ihrer Ablöse-Markierung stehen.
    # Belastbar geprueft wird das eine Stufe tiefer (Get-Win32AppsResilient liest bei einer leeren
    # Antwort erneut und holt eine zweite Meinung direkt von Graph). Hier wird deshalb nur noch
    # erklaert, statt die Kacheln zu verweigern.
    if (Test-InventoryContradiction -ActiveCount $all.Count -SupersededCount $sup.Count) {
      Write-Log ("Dashboard: 0 WinTuner-managed active app(s) next to {0} superseded one(s). Both answers were cross-checked against Graph. The usual cause is that the newest versions were deleted while their predecessors kept the supersedence mark; apps built by hand or by another tool never appear here at all." -f $sup.Count)
    }
    # Two ways to fill the "Updates available" tile, and they answer different questions.
    #
    # Full scan (opt-in): the real version comparison, the same verdict per app that the update scan
    # reaches, via Measure-AvailableUpdates. Costs one package lookup per app, so it is a setting and
    # not the default - but when it is on, the tile and the scan agree, which is the whole point.
    #
    # Otherwise: Intune's own UpdateAvailable flag. One query, instant, and honest about being
    # Intune's opinion rather than a comparison. The tooltip says which of the two produced the number.
    #
    # Either way through the resilient wrapper: this used to be the last bare inventory call in the
    # dashboard, so the module's "Collection was modified" race took the whole refresh down with it
    # and produced "Laden der Apps aus Intune fehlgeschlagen" right after signing in.
    $updateCount = 0
    $tileTooltipKey = 'TtDashUpdatesFlag'
    # Die Kachel rechnet ueber DIESELBE Liste wie die Update-Suche - das ist der ganze Sinn von
    # Measure-AvailableUpdates. Aber nur beim echten Versionsvergleich: Get-ScanInventory liest den
    # Tenant seitenweise ueber Graph, und fuer die Kennzeichen-Variante unten waere das ein
    # Durchlauf fuer eine Zahl, die aus einer voellig anderen Quelle stammt.
    #
    # Die Kachel "verwaltete Apps" bleibt bei $all: sie beantwortet weiter die Frage, wie viele Apps
    # WinTuner gebaut hat, und das ist eine andere Frage als "wie viele koennen aktualisiert werden".
    $scanScope = if ($script:settings.DashboardUpdatesFullScan) { @(Get-ScanInventory -ManagedApps $all) } else { @($all) }
    if ($scanScope.Count -eq 0) {
      # Ohne App kann es kein Update geben - die dritte Tenant-Abfrage (und bei leerem
      # Inventar ihre Gegenprobe) war beim Anmelden reine Wartezeit fuer eine garantierte Null.
      $tileTooltipKey = if ($script:settings.DashboardUpdatesFullScan) { 'TtDashUpdatesScan' } else { 'TtDashUpdatesFlag' }
      Write-Log 'Dashboard tile: no app in scope that could have an update - skipping the update query.'
    } elseif ($script:settings.DashboardUpdatesFullScan) {
      Update-Status (Get-UiString 'DashUpdatesScanning')
      [System.Windows.Forms.Application]::DoEvents()
      $measured = Measure-AvailableUpdates -Apps $scanScope
      $updateCount = [int]$measured.Outdated
      $tileTooltipKey = 'TtDashUpdatesScan'
      Write-Log ("Dashboard tile (full scan): {0} outdated, {1} up to date, {2} newer version already in the tenant, {3} without a WinGet id, {4} lookup failed, of {5} checked." -f
        $measured.Outdated, $measured.UpToDate, $measured.AlreadyNewerInTenant, $measured.NoWingetId, $measured.Failed, $measured.Checked)
    } else {
      $upd = @(Get-Win32AppsResilient -UpdateAvailable $true -Label 'dashboard tile (updates)')
      $updateCount = $upd.Count
      # Named, not just counted. "updates=1" while the update scan reports no candidates is a
      # perfectly consistent pair of answers to two different questions - Intune flags an app whose
      # newer version ALREADY sits in the tenant, the scan asks whether there is work left to do -
      # but with only a number in the log there is no way to see which app it was, and the two
      # figures look like a contradiction. This line ends that guessing.
      if ($updateCount -gt 0) {
        foreach ($u in $upd) {
          Write-Log ("  Intune flags an update for: {0} {1} ({2})" -f [string]$u.Name, [string]$u.CurrentVersion, [string]$u.GraphId)
        }
        Write-Log 'Note: the update scan may still report no candidates - a newer version that is already deployed needs no work. Switch on the full version comparison in Settings (Searching for app updates) to make the tile answer the same question as the scan.'
      }
      # Die Abweichung geht seit ScanUnmanagedWin32Apps auch in die andere Richtung, und das ist die
      # verwirrendere Richtung:
      # Intunes Kennzeichen kennt nur markierte Apps, die Suche prueft alle. Die Kachel kann also
      # DEUTLICH weniger zeigen als die Suche findet - ohne diese Zeile sieht das nach einem Fehler aus.
      if ($script:settings.ScanUnmanagedWin32Apps) {
        Write-Log 'Note: this number counts only WinTuner-marked apps, because it comes from Intune. The update scan additionally checks Win32 apps without the marker, so it can find MORE than this tile shows. The full version comparison makes both agree.'
      }
    }
    try { if ($toolTip -and $script:dashUpdatesVal) { $toolTip.SetToolTip($script:dashUpdatesVal, (Get-UiString $tileTooltipKey)) } } catch { Write-LogDebug 'dashboard tile tooltip' }
    if ($script:dashManagedVal)    { $script:dashManagedVal.Text    = "$($all.Count)" }
    if ($script:dashUpdatesVal)    { $script:dashUpdatesVal.Text    = "$updateCount" }
    if ($script:dashSupersededVal) { $script:dashSupersededVal.Text = "$($sup.Count)" }
    Write-Log ("Dashboard refreshed: managed={0} updates={1} superseded={2} (updates from {3})" -f $all.Count, $updateCount, $sup.Count,
      $(if ($script:settings.DashboardUpdatesFullScan) { 'full version scan' } else { "Intune's UpdateAvailable flag" }))
    Update-Status (Get-UiString 'DashLoadedStatus')
    $script:dashboardLastRefresh = [datetime]::UtcNow
    $script:dashboardStale = $false
    try { Update-DashboardFreshness } catch { Write-LogDebug 'dashboard freshness' }
  } catch {
    Write-Log ("Dashboard refresh failed: {0}" -f $_.Exception.Message)
    Update-Status (Get-UiString 'LoadAppsFailedStatus')
  } finally {
    $script:dashboardRefreshing = $false
  }
}

# Section: WinGet Apps
$tabCreate = New-Object System.Windows.Forms.Panel
Add-Section -Key 'winget' -Panel $tabCreate -Label (Get-UiString 'TabWinGetApps') -Group 'deploy'

# Section title
$wingetTitle = New-Object System.Windows.Forms.Label
$wingetTitle.Text = Get-UiString 'SectionWingetTitle'
$wingetTitle.Location = New-Object System.Drawing.Point(16, 12)
$wingetTitle.AutoSize = $true
$wingetTitle.Font = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)
$tabCreate.Controls.Add($wingetTitle)
[void](Add-SectionInfoBadge -Parent $tabCreate -AfterLabel $wingetTitle -TextKey 'InfoWinget')

# --- Card 1: Find package ---
# 162 statt 118: die Zeile mit "Auf diesem PC installieren..." kam dazu.
$cardFind = New-Card -X 16 -Y 48 -W 726 -H 162
$tabCreate.Controls.Add($cardFind)

$step1Label = New-Object System.Windows.Forms.Label
$step1Label.Text = Get-UiString 'Step1FindPackage'
$step1Label.Location = New-Object System.Drawing.Point(14, 10)
$step1Label.AutoSize = $true
$step1Label.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$cardFind.Controls.Add($step1Label)
[void](Add-SectionInfoBadge -Parent $cardFind -AfterLabel $step1Label -TextKey 'InfoCardFind')

$appSearchBox = New-Object System.Windows.Forms.TextBox
if ($null -ne $appSearchBox) {
  $appSearchBox.Add_KeyDown({
    param($sender, $e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
      if ($searchButton -and $searchButton.Enabled) { $searchButton.PerformClick() }
      $e.SuppressKeyPress = $true
    }
  })
}
$appSearchBox.Width = 532
$appSearchHost = New-RoundedInput -Inner $appSearchBox -X 14 -Y 40 -W 532 -H 32
$cardFind.Controls.Add($appSearchHost)

$searchButton = New-Object System.Windows.Forms.Button
$searchButton.Text = Get-UiString 'SearchButton'
$searchButton.Location = New-Object System.Drawing.Point(558, 40)
$searchButton.Width = 152
$searchButton.Height = 32
$cardFind.Controls.Add($searchButton)

$dropdown = New-Object System.Windows.Forms.ComboBox
$dropdown.Width = 374
$dropdown.DropDownWidth = 532
$dropdown.MaxDropDownItems = 14
$dropdown.IntegralHeight = $true
$dropdown.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
# ComboBoxes are placed directly (no rounded input host): the host's rounded border behind the
# combo's own square dropdown box just looked like a box-in-a-box. The square themed combo alone
# is the intended look here.
$dropdown.Location = New-Object System.Drawing.Point(14, 84)
$cardFind.Controls.Add($dropdown)

# Links und abgesetzt: die beiden Knoepfe rechts betreffen nur die AUSWAHL, dieser installiert
# Software auf dem Rechner, an dem man gerade sitzt.
$localInstallButton = New-Object System.Windows.Forms.Button
$localInstallButton.Tag = 'btn-secondary'
$localInstallButton.Text = Get-UiString 'LocalInstallButton'
$localInstallButton.Location = New-Object System.Drawing.Point(14, 116)
$localInstallButton.Width = 210
$localInstallButton.Height = 32
$cardFind.Controls.Add($localInstallButton)

$localInstallButton.Add_Click({
  if (Test-UiBusy) { return }
  if (-not $dropdown.SelectedItem) { Update-Status (Get-UiString 'SelectPackageFirstStatus'); return }
  $package = $script:packageMap[[string]$dropdown.SelectedItem]
  $packageId = if ($package) { [string]$package.PackageID } else { '' }
  if ([string]::IsNullOrWhiteSpace($packageId)) { Update-Status (Get-UiString 'InvalidSelectionStatus'); return }

  # winget kommt mit dem App-Installer und fehlt auf frisch aufgesetzten oder abgespeckten
  # Systemen. Das vorher zu pruefen ist ehrlicher als eine Fehlermeldung aus einem Prozess, den es
  # nicht gibt.
  $wingetCmd = $null
  try { $wingetCmd = (Get-Command winget.exe -ErrorAction SilentlyContinue).Source } catch { }
  if (-not $wingetCmd) {
    Write-Log 'Local install: winget.exe was not found on this machine.'
    [void][System.Windows.Forms.MessageBox]::Show(
      (Get-UiString 'LocalInstallNoWinget'), (Get-UiString 'InfoTitle'),
      [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
    return
  }

  $confirm = [System.Windows.Forms.MessageBox]::Show(
    ((Get-UiString 'LocalInstallConfirm') -f $packageId, $env:COMPUTERNAME),
    (Get-UiString 'ConfirmTitle'),
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Warning,
    [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
  if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

  try {
    $localInstallButton.Enabled = $false
    Update-Status ((Get-UiString 'LocalInstallRunning') -f $packageId)
    [System.Windows.Forms.Application]::DoEvents()   # pumps the message loop; see 70-Runtime
    # --exact: der Bezeichner steht fest, winget soll nicht auf einen aehnlichen Namen ausweichen.
    # Die beiden Zustimmungen sind noetig, weil winget sonst auf eine Eingabe wartet, die in einem
    # Fenster ohne Konsole niemand geben kann - der Aufruf haenge sonst bis zum Zeitueberlauf.
    $wingetArgs = @('install', '--id', $packageId, '--exact', '--source', 'winget',
                    '--accept-package-agreements', '--accept-source-agreements')
    Write-Log ("Local install on this machine: winget {0}" -f ($wingetArgs -join ' '))
    $proc = Start-Process -FilePath $wingetCmd -ArgumentList $wingetArgs -Wait -PassThru -ErrorAction Stop
    $code = [int]$proc.ExitCode
    Write-Log ("Local install of '{0}' finished with winget exit code {1}." -f $packageId, $code)
    if ($code -eq 0) {
      Update-Status ((Get-UiString 'LocalInstallDone') -f $packageId)
    } elseif ($code -eq -1978335189) {
      # APPINSTALLER_CLI_ERROR_UPDATE_NOT_APPLICABLE: schon installiert und aktuell. Kein Fehler,
      # sondern die haeufigste Antwort, wenn man ein Paket zweimal anklickt.
      Update-Status ((Get-UiString 'LocalInstallNoChange') -f $packageId)
    } else {
      Update-Status ((Get-UiString 'LocalInstallFailed') -f $packageId, $code)
    }
  } catch {
    Write-Log ("Local install of '{0}' failed: {1}" -f $packageId, $_.Exception.Message)
    Update-Status ((Get-UiString 'LocalInstallFailed') -f $packageId, $_.Exception.Message)
  } finally {
    $localInstallButton.Enabled = $true
  }
})

$favoriteAddButton = New-Object System.Windows.Forms.Button
$favoriteAddButton.Tag = 'btn-secondary'
$favoriteAddButton.Text = Get-UiString 'FavoriteAddButton'
$favoriteAddButton.Location = New-Object System.Drawing.Point(400, 78)
$favoriteAddButton.Width = 146
$favoriteAddButton.Height = 32
$cardFind.Controls.Add($favoriteAddButton)

$versionsButton = New-Object System.Windows.Forms.Button
$versionsButton.Tag = 'btn-secondary'
$versionsButton.Text = Get-UiString 'VersionsButton'
$versionsButton.Location = New-Object System.Drawing.Point(558, 78)
$versionsButton.Width = 152
$versionsButton.Height = 32
$cardFind.Controls.Add($versionsButton)

# Keep the effective version visible next to the step heading. Previously it was only written to
# the transient status/activity area at the bottom, so it was easy to miss before packaging.
$selectedVersionLabel = New-Object System.Windows.Forms.Label
$selectedVersionLabel.Tag = 'hint'
$selectedVersionLabel.Text = (Get-UiString 'SelectedVersionLabel') -f (Get-UiString 'SelectedVersionNone')
$selectedVersionLabel.Location = New-Object System.Drawing.Point(352, 10)
$selectedVersionLabel.Size = New-Object System.Drawing.Size(358, 20)
$selectedVersionLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$selectedVersionLabel.AutoEllipsis = $true
$cardFind.Controls.Add($selectedVersionLabel)

# --- Card 2: Package & deploy ---
$cardDeploy = New-Card -X 16 -Y 222 -W 726 -H 214
$tabCreate.Controls.Add($cardDeploy)

$step2Label = New-Object System.Windows.Forms.Label
$step2Label.Text = Get-UiString 'Step2Deploy'
$step2Label.Location = New-Object System.Drawing.Point(14, 10)
$step2Label.AutoSize = $true
$step2Label.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$cardDeploy.Controls.Add($step2Label)
[void](Add-SectionInfoBadge -Parent $cardDeploy -AfterLabel $step2Label -TextKey 'InfoCardDeploy')

$pathLabel = New-Object System.Windows.Forms.Label
$pathLabel.Text = Get-UiString 'PathLabel'
$pathLabel.Location = New-Object System.Drawing.Point(14, 50)
$pathLabel.AutoSize = $true
$cardDeploy.Controls.Add($pathLabel)

$pathBox = New-Object System.Windows.Forms.TextBox
$pathBox.Width = 450
$pathBox.Text = Get-DefaultPackagePath
$pathHost = New-RoundedInput -Inner $pathBox -X 112 -Y 42 -W 434 -H 32
$cardDeploy.Controls.Add($pathHost)

$browseButton = New-Object System.Windows.Forms.Button
$browseButton.Tag = 'btn-secondary'
$browseButton.Text = Get-UiString 'SelectButton'
$browseButton.Location = New-Object System.Drawing.Point(558, 42)
$browseButton.Width = 152
$browseButton.Height = 32
$cardDeploy.Controls.Add($browseButton)
$browseButton.Add_Click({
  $folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
  if ($folderBrowser.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
    $pathBox.Text = $folderBrowser.SelectedPath
  }
})

# Assignment target – without this, a newly created app has NO Intune assignment at all
# and someone has to go set it manually in the portal after every upload.
$assignLabel = New-Object System.Windows.Forms.Label
$assignLabel.Text = Get-UiString 'AssignLabel'
$assignLabel.Location = New-Object System.Drawing.Point(14, 90)
$assignLabel.AutoSize = $true
$cardDeploy.Controls.Add($assignLabel)

$assignTargetCombo = New-Object System.Windows.Forms.ComboBox
$assignTargetCombo.Width = 250
$assignTargetCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
[void]$assignTargetCombo.Items.AddRange(@((Get-UiString 'AssignNotAssigned'), (Get-UiString 'AssignAllUsers'), (Get-UiString 'AssignAllDevices'), (Get-UiString 'AssignCustomGroup')))
$assignTargetCombo.SelectedIndex = 0
$assignTargetCombo.Location = New-Object System.Drawing.Point(112, 88)
$cardDeploy.Controls.Add($assignTargetCombo)

$assignGroupIdBox = New-Object System.Windows.Forms.TextBox
$assignGroupIdBox.Width = 194
$assignGroupIdHost = New-RoundedInput -Inner $assignGroupIdBox -X 372 -Y 82 -W 180 -H 32
$assignGroupIdHost.Visible = $false
$cardDeploy.Controls.Add($assignGroupIdHost)

$assignFavButton = New-Object System.Windows.Forms.Button
$assignFavButton.Tag = 'btn-secondary'
$assignFavButton.Text = Get-UiString 'FavAddButton'
$assignFavButton.Location = New-Object System.Drawing.Point(558, 82)
$assignFavButton.Size = New-Object System.Drawing.Size(96, 32)
# IMMER sichtbar. Der Knopf war nur eingeblendet, wenn "Bestimmte Gruppe" gewaehlt war - damit war
# die einzige Stelle, an der man Gruppen-Favoriten eines Kunden pflegt, praktisch unfindbar (genau
# so gemeldet). Er oeffnet die Verwaltung auch dann, wenn gerade keine Gruppen-ID im Feld steht.
$assignFavButton.Visible = $true
$assignFavButton.Add_Click({ Show-GroupFavoriteDialog -GroupIdBox $assignGroupIdBox })
$cardDeploy.Controls.Add($assignFavButton)

$assignTargetCombo.Add_SelectedIndexChanged({
  $isCustom = ($assignTargetCombo.SelectedItem -eq (Get-UiString 'AssignCustomGroup'))
  $assignGroupIdHost.Visible = $isCustom
})
Register-AssignTargetCombo -TargetCombo $assignTargetCombo

# Assignment intent (Available / Required / Uninstall) → Deploy-WtWin32App -AvailableFor /
# -RequiredFor / -UninstallFor. Read by SelectedIndex so it is language-independent.
$assignIntentLabel = New-Object System.Windows.Forms.Label
$assignIntentLabel.Text = Get-UiString 'AssignIntentLabel'
$assignIntentLabel.Location = New-Object System.Drawing.Point(14, 130)
$assignIntentLabel.AutoSize = $true
$cardDeploy.Controls.Add($assignIntentLabel)

$script:assignIntentCombo = New-Object System.Windows.Forms.ComboBox
$script:assignIntentCombo.Width = 250
$script:assignIntentCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
[void]$script:assignIntentCombo.Items.AddRange(@((Get-UiString 'IntentAvailable'), (Get-UiString 'IntentRequired'), (Get-UiString 'IntentUninstall')))
$script:assignIntentCombo.SelectedIndex = 0
$script:assignIntentCombo.Location = New-Object System.Drawing.Point(112, 128)
$cardDeploy.Controls.Add($script:assignIntentCombo)

$createButton = New-Object System.Windows.Forms.Button
$createButton.Text = Get-UiString 'CreateButton'
$createButton.Location = New-Object System.Drawing.Point(14, 168)
$createButton.Width = 180
$createButton.Height = 32
$cardDeploy.Controls.Add($createButton)

$uploadButton = New-Object System.Windows.Forms.Button
$uploadButton.Text = Get-UiString 'UploadButton'
$uploadButton.Location = New-Object System.Drawing.Point(204, 168)
$uploadButton.Width = 180
$uploadButton.Height = 32
$uploadButton.Visible = $true
$uploadButton.Enabled = $false
$cardDeploy.Controls.Add($uploadButton)

# Advanced package options (collapsible): architecture / install context / locale, passed to
# New-WtWingetPackage. Empty = keep the module's own default. Hidden until expanded; expanding
# grows the card (its rounded region re-applies on resize).
$advToggle = New-Object System.Windows.Forms.Button
$advToggle.Tag = 'btn-secondary'
$advToggle.Text = (Get-UiString 'AdvancedOptions') + "  " + [System.Char]::ConvertFromUtf32(0x25BE)
$advToggle.Location = New-Object System.Drawing.Point(400, 168)
$advToggle.Size = New-Object System.Drawing.Size(200, 32)
$cardDeploy.Controls.Add($advToggle)

$archLabel = New-Object System.Windows.Forms.Label
$archLabel.Text = Get-UiString 'ArchLabel'
$archLabel.Location = New-Object System.Drawing.Point(14, 214)
$archLabel.AutoSize = $true
$archLabel.Visible = $false
$cardDeploy.Controls.Add($archLabel)

$script:archCombo = New-Object System.Windows.Forms.ComboBox
$script:archCombo.Width = 150
$script:archCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
[void]$script:archCombo.Items.AddRange(@((Get-UiString 'OptDefault'), 'x64', 'x86', 'arm64'))
$script:archCombo.SelectedIndex = 0
$archHost = New-RoundedInput -Inner $script:archCombo -X 150 -Y 208 -W 150 -H 32
$archHost.Visible = $false
$cardDeploy.Controls.Add($archHost)

$contextLabel = New-Object System.Windows.Forms.Label
$contextLabel.Text = Get-UiString 'ContextLabel'
$contextLabel.Location = New-Object System.Drawing.Point(320, 214)
$contextLabel.AutoSize = $true
$contextLabel.Visible = $false
$cardDeploy.Controls.Add($contextLabel)

$script:contextCombo = New-Object System.Windows.Forms.ComboBox
$script:contextCombo.Width = 140
$script:contextCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
[void]$script:contextCombo.Items.AddRange(@((Get-UiString 'OptDefault'), 'System', 'User'))
$script:contextCombo.SelectedIndex = 0
$contextHost = New-RoundedInput -Inner $script:contextCombo -X 470 -Y 208 -W 140 -H 32
$contextHost.Visible = $false
$cardDeploy.Controls.Add($contextHost)

$localeLabel = New-Object System.Windows.Forms.Label
$localeLabel.Text = Get-UiString 'LocaleLabel'
$localeLabel.Location = New-Object System.Drawing.Point(14, 252)
$localeLabel.AutoSize = $true
$localeLabel.Visible = $false
$cardDeploy.Controls.Add($localeLabel)

$script:localeBox = New-Object System.Windows.Forms.TextBox
$script:localeBox.Width = 150
$localeHost = New-RoundedInput -Inner $script:localeBox -X 150 -Y 246 -W 150 -H 32
$localeHost.Visible = $false
$cardDeploy.Controls.Add($localeHost)

# Preferred installer type → New-WtWingetPackage -PreferedInstaller (note the module's spelling).
# A winget manifest can offer several installers; this picks which one is packaged. Index 0 keeps
# the module's own choice, so nothing is passed unless the user really wants a specific type.
$installerTypeLabel = New-Object System.Windows.Forms.Label
$installerTypeLabel.Text = Get-UiString 'InstallerTypeLabel'
$installerTypeLabel.Location = New-Object System.Drawing.Point(320, 252)
$installerTypeLabel.AutoSize = $true
$installerTypeLabel.Visible = $false
$cardDeploy.Controls.Add($installerTypeLabel)

$script:installerTypeCombo = New-Object System.Windows.Forms.ComboBox
$script:installerTypeCombo.Width = 140
$script:installerTypeCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
# Values are the WingetIntune.Models.InstallerType enum names; 'Unknown' is the enum default and
# is deliberately not offered - "Default" already means "pass nothing".
[void]$script:installerTypeCombo.Items.AddRange(@((Get-UiString 'OptDefault'),
  'Msi', 'Msix', 'Appx', 'Exe', 'Zip', 'Inno', 'Nullsoft', 'Wix', 'Burn', 'Pwa', 'Portable'))
$script:installerTypeCombo.SelectedIndex = 0
$installerTypeHost = New-RoundedInput -Inner $script:installerTypeCombo -X 470 -Y 246 -W 140 -H 32
$installerTypeHost.Visible = $false
$cardDeploy.Controls.Add($installerTypeHost)

# Installer arguments → New-WtWingetPackage -InstallerArguments. Replaces the silent switches
# winget would derive, so it is left empty unless the user knows the installer needs something else.
$installerArgsLabel = New-Object System.Windows.Forms.Label
$installerArgsLabel.Text = Get-UiString 'InstallerArgsLabel'
$installerArgsLabel.Location = New-Object System.Drawing.Point(14, 290)
$installerArgsLabel.AutoSize = $true
$installerArgsLabel.Visible = $false
$cardDeploy.Controls.Add($installerArgsLabel)

$script:installerArgsBox = New-Object System.Windows.Forms.TextBox
$script:installerArgsBox.Width = 460
$script:installerArgsBox.PlaceholderText = Get-UiString 'InstallerArgsPlaceholder'
$installerArgsHost = New-RoundedInput -Inner $script:installerArgsBox -X 150 -Y 284 -W 460 -H 32
$installerArgsHost.Visible = $false
$cardDeploy.Controls.Add($installerArgsHost)

# Optional Intune display name and role-scope tags exposed by Deploy-WtWin32App.
$overrideAppNameLabel = New-Object System.Windows.Forms.Label
$overrideAppNameLabel.Text = Get-UiString 'OverrideAppNameLabel'
$overrideAppNameLabel.Location = New-Object System.Drawing.Point(14, 328)
$overrideAppNameLabel.AutoSize = $true
$overrideAppNameLabel.Visible = $false
$cardDeploy.Controls.Add($overrideAppNameLabel)

$script:overrideAppNameBox = New-Object System.Windows.Forms.TextBox
$script:overrideAppNameBox.Width = 460
$script:overrideAppNameBox.PlaceholderText = Get-UiString 'OverrideAppNamePlaceholder'
$overrideAppNameHost = New-RoundedInput -Inner $script:overrideAppNameBox -X 150 -Y 322 -W 460 -H 32
$overrideAppNameHost.Visible = $false
$cardDeploy.Controls.Add($overrideAppNameHost)

$roleScopeTagsLabel = New-Object System.Windows.Forms.Label
$roleScopeTagsLabel.Text = Get-UiString 'RoleScopeTagsLabel'
$roleScopeTagsLabel.Location = New-Object System.Drawing.Point(14, 366)
$roleScopeTagsLabel.AutoSize = $true
$roleScopeTagsLabel.Visible = $false
$cardDeploy.Controls.Add($roleScopeTagsLabel)

$script:roleScopeTagsBox = New-Object System.Windows.Forms.TextBox
$script:roleScopeTagsBox.Width = 460
$script:roleScopeTagsBox.PlaceholderText = Get-UiString 'RoleScopeTagsPlaceholder'
$roleScopeTagsHost = New-RoundedInput -Inner $script:roleScopeTagsBox -X 150 -Y 360 -W 460 -H 32
$roleScopeTagsHost.Visible = $false
$cardDeploy.Controls.Add($roleScopeTagsHost)

# Intune app categories (comma-separated) → Deploy-WtWin32App -Categories.
$categoriesLabel = New-Object System.Windows.Forms.Label
$categoriesLabel.Text = Get-UiString 'CategoriesLabel'
$categoriesLabel.Location = New-Object System.Drawing.Point(14, 404)
$categoriesLabel.AutoSize = $true
$categoriesLabel.Visible = $false
$cardDeploy.Controls.Add($categoriesLabel)

$script:categoriesBox = New-Object System.Windows.Forms.TextBox
$script:categoriesBox.Width = 460
$script:categoriesBox.PlaceholderText = Get-UiString 'CategoriesPlaceholder'
# X=150 lines this up with the Locale and Installer-arguments fields directly above it.
$categoriesHost = New-RoundedInput -Inner $script:categoriesBox -X 150 -Y 398 -W 460 -H 32
$categoriesHost.Visible = $false
$cardDeploy.Controls.Add($categoriesHost)

# Optional assignment lane details. Included is the normal mode. Excluded is intentionally
# limited to a custom group; Intune does not support an "exclude all users/devices" target.
$deployGroupModeLabel = New-Object System.Windows.Forms.Label
$deployGroupModeLabel.Text = Get-UiString 'DeployAssignmentModeLabel'
$deployGroupModeLabel.Location = New-Object System.Drawing.Point(14, 442)
$deployGroupModeLabel.AutoSize = $true
$deployGroupModeLabel.Visible = $false
$cardDeploy.Controls.Add($deployGroupModeLabel)
$script:deployGroupModeCombo = New-Object System.Windows.Forms.ComboBox
$script:deployGroupModeCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$script:deployGroupModeCombo.Location = New-Object System.Drawing.Point(150, 439)
$script:deployGroupModeCombo.Width = 150
[void]$script:deployGroupModeCombo.Items.AddRange(@((Get-UiString 'DeployAssignmentIncluded'), (Get-UiString 'DeployAssignmentExcluded')))
$script:deployGroupModeCombo.SelectedIndex = 0
$script:deployGroupModeCombo.Visible = $false
$cardDeploy.Controls.Add($script:deployGroupModeCombo)

$deployExcludeBaseLabel = New-Object System.Windows.Forms.Label
$deployExcludeBaseLabel.Text = Get-UiString 'DeployExcludeBaseLabel'
$deployExcludeBaseLabel.Location = New-Object System.Drawing.Point(14, 480)
$deployExcludeBaseLabel.AutoSize = $true
$deployExcludeBaseLabel.Visible = $false
Set-LabelDimmed -Label $deployExcludeBaseLabel -Dimmed $true
$cardDeploy.Controls.Add($deployExcludeBaseLabel)
$script:deployExcludeBaseCombo = New-Object System.Windows.Forms.ComboBox
$script:deployExcludeBaseCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$script:deployExcludeBaseCombo.Location = New-Object System.Drawing.Point(150, 477)
$script:deployExcludeBaseCombo.Width = 150
[void]$script:deployExcludeBaseCombo.Items.AddRange(@((Get-UiString 'DeployExcludeBaseUsers'), (Get-UiString 'DeployExcludeBaseDevices')))
$script:deployExcludeBaseCombo.SelectedIndex = 0
$script:deployExcludeBaseCombo.Visible = $false
$script:deployExcludeBaseCombo.Enabled = $false
$cardDeploy.Controls.Add($script:deployExcludeBaseCombo)
$script:deployGroupModeCombo.Add_SelectedIndexChanged({
  $isExcluded = ($script:deployGroupModeCombo.SelectedIndex -eq 1)
  Set-LabelDimmed -Label $deployExcludeBaseLabel -Dimmed (-not $isExcluded)
  $script:deployExcludeBaseCombo.Enabled = $isExcluded
})

$deployFilterModeLabel = New-Object System.Windows.Forms.Label
$deployFilterModeLabel.Text = Get-UiString 'DeployFilterModeLabel'
$deployFilterModeLabel.Location = New-Object System.Drawing.Point(320, 442)
$deployFilterModeLabel.AutoSize = $true
$deployFilterModeLabel.Visible = $false
$cardDeploy.Controls.Add($deployFilterModeLabel)
$script:deployFilterModeCombo = New-Object System.Windows.Forms.ComboBox
$script:deployFilterModeCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$script:deployFilterModeCombo.Location = New-Object System.Drawing.Point(470, 439)
$script:deployFilterModeCombo.Width = 140
[void]$script:deployFilterModeCombo.Items.AddRange(@((Get-UiString 'DeployFilterNone'), (Get-UiString 'DeployFilterInclude'), (Get-UiString 'DeployFilterExclude')))
$script:deployFilterModeCombo.SelectedIndex = 0
$script:deployFilterModeCombo.Visible = $false
$cardDeploy.Controls.Add($script:deployFilterModeCombo)

$deployFilterIdLabel = New-Object System.Windows.Forms.Label
$deployFilterIdLabel.Text = Get-UiString 'DeployFilterIdLabel'
$deployFilterIdLabel.Location = New-Object System.Drawing.Point(320, 480)
$deployFilterIdLabel.AutoSize = $true
$deployFilterIdLabel.Visible = $false
$cardDeploy.Controls.Add($deployFilterIdLabel)
$script:deployFilterIdBox = New-Object System.Windows.Forms.TextBox
$script:deployFilterIdBox.Width = 140
$script:deployFilterIdBox.PlaceholderText = Get-UiString 'DeployFilterIdPlaceholder'
$deployFilterIdHost = New-RoundedInput -Inner $script:deployFilterIdBox -X 470 -Y 474 -W 140 -H 32
$deployFilterIdHost.Visible = $false
$deployFilterIdHost.Enabled = $false
$cardDeploy.Controls.Add($deployFilterIdHost)
$script:deployFilterModeCombo.Add_SelectedIndexChanged({
  $deployFilterIdHost.Enabled = ($script:deployFilterModeCombo.SelectedIndex -gt 0)
})

$script:packageScriptCheckbox = New-Object System.Windows.Forms.CheckBox
$script:packageScriptCheckbox.Text = Get-UiString 'PackageScriptCheckbox'
$script:packageScriptCheckbox.Location = New-Object System.Drawing.Point(14, 514)
$script:packageScriptCheckbox.AutoSize = $true
$script:packageScriptCheckbox.Visible = $false
$cardDeploy.Controls.Add($script:packageScriptCheckbox)

# Turn on Intune's built-in auto-update for the app after deploy → Update-WtIntuneApp -EnableAutoUpdate.
$script:autoUpdateCheckbox = New-Object System.Windows.Forms.CheckBox
$script:autoUpdateCheckbox.Text = Get-UiString 'AutoUpdateCheckbox'
$script:autoUpdateCheckbox.Location = New-Object System.Drawing.Point(14, 542)
$script:autoUpdateCheckbox.AutoSize = $true
$script:autoUpdateCheckbox.Visible = $false
$cardDeploy.Controls.Add($script:autoUpdateCheckbox)

# Assignment settings for THIS deployment (same options as the bulk dialog). They are applied
# right after the upload, because the settings hang on the assignment - which only exists once the
# app has been created with a target. Without a target group these controls have nothing to write to.
$deployAppSettingsLabel = New-Object System.Windows.Forms.Label
$deployAppSettingsLabel.Text = Get-UiString 'DeployAppSettingsLabel'
$deployAppSettingsLabel.Location = New-Object System.Drawing.Point(14, 572)
$deployAppSettingsLabel.AutoSize = $true
$deployAppSettingsLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$deployAppSettingsLabel.Visible = $false
$cardDeploy.Controls.Add($deployAppSettingsLabel)

$deployNotifyLabel = New-Object System.Windows.Forms.Label
$deployNotifyLabel.Text = Get-UiString 'AppSettingsNotifyLabel'
$deployNotifyLabel.Location = New-Object System.Drawing.Point(14, 604)
$deployNotifyLabel.AutoSize = $true
$deployNotifyLabel.Visible = $false
$cardDeploy.Controls.Add($deployNotifyLabel)

$script:deployNotifyCombo = New-Object System.Windows.Forms.ComboBox
$script:deployNotifyCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$script:deployNotifyCombo.Location = New-Object System.Drawing.Point(240, 601)
$script:deployNotifyCombo.Width = 300
$script:deployNotifyCombo.Visible = $false
[void]$script:deployNotifyCombo.Items.AddRange(@(
  (Get-UiString 'AppSettingsNotifyKeep'),
  (Get-UiString 'AppSettingsNotifyAll'),
  (Get-UiString 'AppSettingsNotifyReboot'),
  (Get-UiString 'AppSettingsNotifyHide')))
$script:deployNotifyCombo.SelectedIndex = 0
$cardDeploy.Controls.Add($script:deployNotifyCombo)

$script:deployAvailCheck = New-Object System.Windows.Forms.CheckBox
$script:deployAvailCheck.Text = Get-UiString 'DeployAvailableFrom'
$script:deployAvailCheck.Location = New-Object System.Drawing.Point(14, 636)
$script:deployAvailCheck.AutoSize = $true
$script:deployAvailCheck.Visible = $false
$cardDeploy.Controls.Add($script:deployAvailCheck)

$script:deployAvailPicker = New-Object System.Windows.Forms.DateTimePicker
$script:deployAvailPicker.Format = [System.Windows.Forms.DateTimePickerFormat]::Custom
$script:deployAvailPicker.CustomFormat = "dd.MM.yyyy  HH:mm"
$script:deployAvailPicker.ShowUpDown = $true
$script:deployAvailPicker.Location = New-Object System.Drawing.Point(240, 633)
$script:deployAvailPicker.Width = 300
$script:deployAvailPicker.Enabled = $false
$script:deployAvailPicker.Visible = $false
$cardDeploy.Controls.Add($script:deployAvailPicker)
$script:deployAvailCheck.Add_CheckedChanged({ $script:deployAvailPicker.Enabled = $script:deployAvailCheck.Checked })

$script:deployDeadlineCheck = New-Object System.Windows.Forms.CheckBox
$script:deployDeadlineCheck.Text = Get-UiString 'DeployDeadline'
$script:deployDeadlineCheck.Location = New-Object System.Drawing.Point(14, 668)
$script:deployDeadlineCheck.AutoSize = $true
$script:deployDeadlineCheck.Visible = $false
$cardDeploy.Controls.Add($script:deployDeadlineCheck)

$script:deployDeadlinePicker = New-Object System.Windows.Forms.DateTimePicker
$script:deployDeadlinePicker.Format = [System.Windows.Forms.DateTimePickerFormat]::Custom
$script:deployDeadlinePicker.CustomFormat = "dd.MM.yyyy  HH:mm"
$script:deployDeadlinePicker.ShowUpDown = $true
$script:deployDeadlinePicker.Location = New-Object System.Drawing.Point(240, 665)
$script:deployDeadlinePicker.Width = 300
$script:deployDeadlinePicker.Enabled = $false
$script:deployDeadlinePicker.Visible = $false
$cardDeploy.Controls.Add($script:deployDeadlinePicker)
$script:deployDeadlineCheck.Add_CheckedChanged({ $script:deployDeadlinePicker.Enabled = $script:deployDeadlineCheck.Checked })

$script:deployLocalTimeCheck = New-Object System.Windows.Forms.CheckBox
$script:deployLocalTimeCheck.Text = Get-UiString 'AppSettingsUseLocalTime'
$script:deployLocalTimeCheck.Location = New-Object System.Drawing.Point(14, 700)
$script:deployLocalTimeCheck.AutoSize = $true
$script:deployLocalTimeCheck.Checked = $true
$script:deployLocalTimeCheck.Visible = $false
$cardDeploy.Controls.Add($script:deployLocalTimeCheck)

$script:deployRestartEnableCheck = New-Object System.Windows.Forms.CheckBox
$script:deployRestartEnableCheck.Text = Get-UiString 'DeployRestartEnable'
$script:deployRestartEnableCheck.Location = New-Object System.Drawing.Point(14, 730)
$script:deployRestartEnableCheck.AutoSize = $true
$script:deployRestartEnableCheck.Visible = $false
$cardDeploy.Controls.Add($script:deployRestartEnableCheck)

$deployRestartGraceLabel = New-Object System.Windows.Forms.Label
$deployRestartGraceLabel.Text = Get-UiString 'AppSettingsRestartGrace'
$deployRestartGraceLabel.Location = New-Object System.Drawing.Point(32, 762)
$deployRestartGraceLabel.AutoSize = $true
$deployRestartGraceLabel.Visible = $false
Set-LabelDimmed -Label $deployRestartGraceLabel -Dimmed $true
$cardDeploy.Controls.Add($deployRestartGraceLabel)
$script:deployRestartGraceValue = New-Object System.Windows.Forms.NumericUpDown
$script:deployRestartGraceValue.Location = New-Object System.Drawing.Point(240, 759)
$script:deployRestartGraceValue.Width = 110
$script:deployRestartGraceValue.Minimum = 1
$script:deployRestartGraceValue.Maximum = 20160
$script:deployRestartGraceValue.Value = 1440
$script:deployRestartGraceValue.Visible = $false
$script:deployRestartGraceValue.Enabled = $false
$cardDeploy.Controls.Add($script:deployRestartGraceValue)

$deployRestartCountdownLabel = New-Object System.Windows.Forms.Label
$deployRestartCountdownLabel.Text = Get-UiString 'AppSettingsRestartCountdown'
$deployRestartCountdownLabel.Location = New-Object System.Drawing.Point(32, 794)
$deployRestartCountdownLabel.AutoSize = $true
$deployRestartCountdownLabel.Visible = $false
Set-LabelDimmed -Label $deployRestartCountdownLabel -Dimmed $true
$cardDeploy.Controls.Add($deployRestartCountdownLabel)
$script:deployRestartCountdownValue = New-Object System.Windows.Forms.NumericUpDown
$script:deployRestartCountdownValue.Location = New-Object System.Drawing.Point(240, 791)
$script:deployRestartCountdownValue.Width = 110
$script:deployRestartCountdownValue.Minimum = 1
$script:deployRestartCountdownValue.Maximum = 20160
$script:deployRestartCountdownValue.Value = 15
$script:deployRestartCountdownValue.Visible = $false
$script:deployRestartCountdownValue.Enabled = $false
$cardDeploy.Controls.Add($script:deployRestartCountdownValue)

$script:deployRestartSnoozeCheck = New-Object System.Windows.Forms.CheckBox
$script:deployRestartSnoozeCheck.Text = Get-UiString 'AppSettingsRestartSnooze'
$script:deployRestartSnoozeCheck.Location = New-Object System.Drawing.Point(380, 762)
$script:deployRestartSnoozeCheck.AutoSize = $true
$script:deployRestartSnoozeCheck.Checked = $true
$script:deployRestartSnoozeCheck.Visible = $false
$script:deployRestartSnoozeCheck.Enabled = $false
$cardDeploy.Controls.Add($script:deployRestartSnoozeCheck)
$deployRestartSnoozeLabel = New-Object System.Windows.Forms.Label
$deployRestartSnoozeLabel.Text = Get-UiString 'AppSettingsRestartSnoozeMinutes'
$deployRestartSnoozeLabel.Location = New-Object System.Drawing.Point(380, 794)
$deployRestartSnoozeLabel.AutoSize = $true
$deployRestartSnoozeLabel.Visible = $false
Set-LabelDimmed -Label $deployRestartSnoozeLabel -Dimmed $true
$cardDeploy.Controls.Add($deployRestartSnoozeLabel)
$script:deployRestartSnoozeValue = New-Object System.Windows.Forms.NumericUpDown
$script:deployRestartSnoozeValue.Location = New-Object System.Drawing.Point(570, 791)
$script:deployRestartSnoozeValue.Width = 110
$script:deployRestartSnoozeValue.Minimum = 1
$script:deployRestartSnoozeValue.Maximum = 20160
$script:deployRestartSnoozeValue.Value = 240
$script:deployRestartSnoozeValue.Visible = $false
$script:deployRestartSnoozeValue.Enabled = $false
$cardDeploy.Controls.Add($script:deployRestartSnoozeValue)
$script:deployRestartEnableCheck.Add_CheckedChanged({
  $enabled = [bool]$script:deployRestartEnableCheck.Checked
  Set-LabelDimmed -Label $deployRestartGraceLabel -Dimmed (-not $enabled)
  Set-LabelDimmed -Label $deployRestartCountdownLabel -Dimmed (-not $enabled)
  Set-LabelDimmed -Label $deployRestartSnoozeLabel -Dimmed (-not $enabled)
  $script:deployRestartGraceValue.Enabled = $enabled
  $script:deployRestartCountdownValue.Enabled = $enabled
  $script:deployRestartSnoozeCheck.Enabled = $enabled
  $script:deployRestartSnoozeValue.Enabled = ($enabled -and $script:deployRestartSnoozeCheck.Checked)
})
$script:deployRestartSnoozeCheck.Add_CheckedChanged({
  $script:deployRestartSnoozeValue.Enabled = ($script:deployRestartEnableCheck.Checked -and $script:deployRestartSnoozeCheck.Checked)
})

$deployDeliveryLabel = New-Object System.Windows.Forms.Label
$deployDeliveryLabel.Text = Get-UiString 'AppSettingsDeliveryPriority'
$deployDeliveryLabel.Location = New-Object System.Drawing.Point(14, 832)
$deployDeliveryLabel.AutoSize = $true
$deployDeliveryLabel.Visible = $false
$cardDeploy.Controls.Add($deployDeliveryLabel)
$script:deployDeliveryCombo = New-Object System.Windows.Forms.ComboBox
$script:deployDeliveryCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$script:deployDeliveryCombo.Location = New-Object System.Drawing.Point(240, 829)
$script:deployDeliveryCombo.Width = 300
[void]$script:deployDeliveryCombo.Items.AddRange(@((Get-UiString 'AppSettingsDeliveryBackground'), (Get-UiString 'AppSettingsDeliveryForeground')))
$script:deployDeliveryCombo.SelectedIndex = 0
$script:deployDeliveryCombo.Visible = $false
$cardDeploy.Controls.Add($script:deployDeliveryCombo)

# Builds the settings object from the deploy card, or $null when the user changed nothing.
# Liest einen Satz Zuweisungs-Steuerelemente in ein Settings-Objekt.
#
# Beide Bereitstellungswege - WinGet und Microsoft Store - benutzen dieselben Regeln; nur der Umfang
# unterscheidet sich. Die Steuerelemente werden als Hashtable uebergeben, fehlende Schluessel sind
# schlicht "gibt es in dieser Variante nicht".
#
# Wirft bei einer unzulaessigen Neustart-Kombination, so wie es die beiden Vorgaenger taten: ein
# Countdown oder ein Aufschub laenger als die Kulanzzeit ergibt in Intune eine Frist, die vor ihrer
# eigenen Ankuendigung ablaeuft.
function Read-AssignmentSettingsControls {
  param([Parameter(Mandatory)][hashtable]$Controls)

  $a = @{}
  if ($Controls.NotifyCombo) {
    switch ($Controls.NotifyCombo.SelectedIndex) {
      1 { $a.Notifications = 'showAll' }
      2 { $a.Notifications = 'showReboot' }
      3 { $a.Notifications = 'hideAll' }
    }
  }
  if ($Controls.AvailCheck -and $Controls.AvailCheck.Checked -and $Controls.AvailPicker) {
    $a.AvailableFrom = $Controls.AvailPicker.Value
  }
  if ($Controls.DeadlineCheck -and $Controls.DeadlineCheck.Checked -and $Controls.DeadlinePicker) {
    $a.Deadline = $Controls.DeadlinePicker.Value
  }
  if ($Controls.LocalTimeCheck) { $a.UseLocalTime = [bool]$Controls.LocalTimeCheck.Checked }
  if ($Controls.RestartEnableCheck -and $Controls.RestartEnableCheck.Checked) {
    $grace = [int]$Controls.RestartGraceValue.Value
    $countdown = [int]$Controls.RestartCountdownValue.Value
    $snooze = if ($Controls.RestartSnoozeCheck -and $Controls.RestartSnoozeCheck.Checked) { [int]$Controls.RestartSnoozeValue.Value } else { 0 }
    if ($countdown -gt $grace -or $snooze -gt $grace) { throw (Get-UiString 'AppSettingsRestartInvalid') }
    $a.RestartGraceMinutes = $grace
    $a.RestartCountdownMinutes = $countdown
    $a.RestartSnoozeMinutes = $snooze
  }
  # Background/normal is Intune's default and is represented by omitting the property. This also
  # keeps new-app assignments compatible with national clouds where DO priority is unsupported.
  if ($Controls.DeliveryCombo -and $Controls.DeliveryCombo.SelectedIndex -eq 1) {
    $a.DeliveryOptimizationPriority = 'foreground'
  }
  $s = New-AssignmentSettingsObject @a
  # "Nichts zu aendern" heisst: gar nichts schicken. Ein leeres Settings-Objekt wuerde in Intune die
  # bestehenden Werte ueberschreiben, statt sie in Ruhe zu lassen.
  if ((Get-AssignmentSettingsSummary $s) -eq '(nothing to change)') { return $null }
  return $s
}

# Der WinGet-Weg: voller Umfang.
# Die vorhandene "Intune-Auto-Update"-Checkbox deckt das Auto-Update neuer Apps ueber
# Update-WtIntuneApp bereits ab, deshalb steht es hier nicht noch einmal.
function Get-DeployAssignmentSettings {
  return (Read-AssignmentSettingsControls -Controls @{
    NotifyCombo            = $script:deployNotifyCombo
    AvailCheck             = $script:deployAvailCheck
    AvailPicker            = $script:deployAvailPicker
    DeadlineCheck          = $script:deployDeadlineCheck
    DeadlinePicker         = $script:deployDeadlinePicker
    LocalTimeCheck         = $script:deployLocalTimeCheck
    RestartEnableCheck     = $script:deployRestartEnableCheck
    RestartGraceValue      = $script:deployRestartGraceValue
    RestartCountdownValue  = $script:deployRestartCountdownValue
    RestartSnoozeCheck     = $script:deployRestartSnoozeCheck
    RestartSnoozeValue     = $script:deployRestartSnoozeValue
    DeliveryCombo          = $script:deployDeliveryCombo
  })
}

function Get-DeployAssignmentTargetChanges {
  $mode = if ($script:deployGroupModeCombo.SelectedIndex -eq 1) { 'exclude' } else { 'include' }
  $filterType = switch ($script:deployFilterModeCombo.SelectedIndex) {
    1 { 'include' }
    2 { 'exclude' }
    default { 'none' }
  }
  $excludeBase = if ($script:deployExcludeBaseCombo.SelectedIndex -eq 1) { 'AllDevices' } else { 'AllUsers' }
  $changes = @{ AssignmentMode = $mode; ExcludeBaseTarget = $excludeBase; FilterType = $filterType }
  if ($filterType -ne 'none') { $changes.FilterId = $script:deployFilterIdBox.Text.Trim() }
  return $changes
}

# The section scrolls if the expanded Advanced area is taller than the visible content height.
$tabCreate.AutoScroll = $true

$script:advExpanded = $false
$advControls = @($archLabel, $archHost, $contextLabel, $contextHost, $localeLabel, $localeHost,
                 $installerTypeLabel, $installerTypeHost, $installerArgsLabel, $installerArgsHost,
                 $overrideAppNameLabel, $overrideAppNameHost, $roleScopeTagsLabel, $roleScopeTagsHost,
                 $categoriesLabel, $categoriesHost, $deployGroupModeLabel, $script:deployGroupModeCombo,
                 $deployExcludeBaseLabel, $script:deployExcludeBaseCombo,
                 $deployFilterModeLabel, $script:deployFilterModeCombo, $deployFilterIdLabel, $deployFilterIdHost,
                 $script:packageScriptCheckbox, $script:autoUpdateCheckbox,
                 $deployAppSettingsLabel, $deployNotifyLabel, $script:deployNotifyCombo, $script:deployAvailCheck, $script:deployAvailPicker,
                 $script:deployDeadlineCheck, $script:deployDeadlinePicker, $script:deployLocalTimeCheck,
                 $script:deployRestartEnableCheck, $deployRestartGraceLabel, $script:deployRestartGraceValue,
                 $deployRestartCountdownLabel, $script:deployRestartCountdownValue, $script:deployRestartSnoozeCheck,
                 $deployRestartSnoozeLabel, $script:deployRestartSnoozeValue, $deployDeliveryLabel, $script:deployDeliveryCombo)
$advToggle.Add_Click({
  $script:advExpanded = -not $script:advExpanded
  foreach ($c in $advControls) { $c.Visible = $script:advExpanded }
  $cardDeploy.Height = if ($script:advExpanded) { 874 } else { 214 }
  # Keep the favorites card just below the (now taller/shorter) deploy card so they never overlap.
  # The Microsoft Store card used to sit between the two; it has its own section now.
  if ($cardFavorites) { $cardFavorites.Top = $cardDeploy.Bottom + 12 }
  $chev = if ($script:advExpanded) { [System.Char]::ConvertFromUtf32(0x25B4) } else { [System.Char]::ConvertFromUtf32(0x25BE) }
  $advToggle.Text = (Get-UiString 'AdvancedOptions') + "  " + $chev
})

# Section: Microsoft Store apps
#
# Its own section rather than a third card inside "WinGet Apps": a Store app is never packaged and
# never uploaded - Intune creates it from a package identifier. Sitting under the packaging section
# it also had to borrow that section's assignment controls, so the deployment hint pointed at a card
# titled "Package and deploy" and users could not tell that setting a target there was what governed
# the Store deployment. The assignment controls below belong to this section alone.
$tabStore = New-Object System.Windows.Forms.Panel
Add-Section -Key 'store' -Panel $tabStore -Label (Get-UiString 'TabStore') -Group 'deploy'

# Die Liste der bereitgestellten Store-Apps stand auf festen 126 px - vier Zeilen, egal wie gross
# das Fenster war. Sie bekommt jetzt, was zwischen ihrer Karte und der Zuweisungskarte darunter
# uebrig ist.
function Update-StoreLayout {
  try {
    if (-not $tabStore -or -not $cardStore -or -not $storeTenantListView) { return }
    $avail = $tabStore.ClientSize.Height
    if ($avail -lt 200) { return }
    $topY = 48; $gap = 12; $bottomPad = 6
    # Unter der Liste steht der Knopf "Zuweisungen dieser App verwalten...".
    $btnGap = 8; $btnH = 32
    # Erst die Zuweisungskarte anordnen (sie bestimmt ihre eigene Hoehe aus dem Inhalt), dann den
    # Rest darauf ausrichten.
    if (Get-Command Update-StoreAssignLayout -ErrorAction SilentlyContinue) { Update-StoreAssignLayout }
    $assignH = if ($cardStoreAssign) { $cardStoreAssign.Height } else { 180 }
    # 170 ueber der Liste (Suchzeile, Knoepfe, Hinweis), Knopf + Rand darunter.
    $storeH = $avail - $topY - $gap - $assignH - $bottomPad
    $minStoreH = 170 + 80 + $btnGap + $btnH + 16
    if ($storeH -lt $minStoreH) { $storeH = $minStoreH }
    # + Scrollversatz: sonst wandert die Karte bei jeder Neuanordnung im gescrollten Zustand nach
    # unten (siehe Get-ScrollOffsetY).
    $cardStore.Top = $topY + (Get-ScrollOffsetY $tabStore)
    $cardStore.Height = $storeH
    $inner = [Math]::Max(698, $cardStore.ClientSize.Width - 28)
    $storeTenantListView.Size = New-Object System.Drawing.Size($inner, ($storeH - 170 - 16 - $btnGap - $btnH))
    if ($storeManageAssignmentsButton) {
      $storeManageAssignmentsButton.Location = New-Object System.Drawing.Point($storeTenantListView.Left, ($storeTenantListView.Bottom + $btnGap))
    }
    $listInner = $inner - [System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth - 2
    $extra = $listInner - 670
    if ($extra -gt 0 -and $storeTenantListView.Columns.Count -ge 4) {
      $storeTenantListView.Columns[0].Width = 230 + [int]($extra * 0.40)
      $storeTenantListView.Columns[1].Width = 210 + [int]($extra * 0.30)
      $storeTenantListView.Columns[2].Width = 95  + [int]($extra * 0.12)
      $storeTenantListView.Columns[3].Width = 135 + [int]($extra * 0.18)
    }
    if ($cardStoreAssign) { $cardStoreAssign.Top = $cardStore.Bottom + $gap }
  } catch { Write-LogDebug 'store layout' }
}
$tabStore.AutoScroll = $true

$storeSectionTitle = New-Object System.Windows.Forms.Label
$storeSectionTitle.Text = Get-UiString 'StoreSectionTitle'
$storeSectionTitle.Location = New-Object System.Drawing.Point(16, 12)
$storeSectionTitle.AutoSize = $true
$storeSectionTitle.Font = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)
$tabStore.Controls.Add($storeSectionTitle)
[void](Add-SectionInfoBadge -Parent $tabStore -AfterLabel $storeSectionTitle -TextKey 'InfoStore')

# --- Card A: assignment for the Store app about to be deployed ---
# Only the options a Store app actually honours. Availability date, delivery optimisation and Intune
# auto-update are deliberately absent: the deploy path already reported them as unsupported, so
# offering them here would only invite settings that silently do nothing.
# Y=366: unter der App-Karte. Diese Karte stand oben und musste ihre Lage im Text erklaeren.
$cardStoreAssign = New-Card -X 16 -Y 366 -W 726 -H 180
$tabStore.Controls.Add($cardStoreAssign)

$storeAssignTitle = New-Object System.Windows.Forms.Label
$storeAssignTitle.Text = Get-UiString 'StoreAssignCardTitle'
$storeAssignTitle.Location = New-Object System.Drawing.Point(14, 10)
$storeAssignTitle.AutoSize = $true
$storeAssignTitle.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$cardStoreAssign.Controls.Add($storeAssignTitle)

$storeAssignCardHint = New-Object System.Windows.Forms.Label
$storeAssignCardHint.Text = Get-UiString 'StoreAssignCardHint'
$storeAssignCardHint.Location = New-Object System.Drawing.Point(14, 34)
$storeAssignCardHint.Size = New-Object System.Drawing.Size(698, 20)
$cardStoreAssign.Controls.Add($storeAssignCardHint)

$storeAssignTargetLabel = New-Object System.Windows.Forms.Label
$storeAssignTargetLabel.Text = Get-UiString 'AssignLabel'
$storeAssignTargetLabel.Location = New-Object System.Drawing.Point(14, 68)
$storeAssignTargetLabel.AutoSize = $true
$cardStoreAssign.Controls.Add($storeAssignTargetLabel)

$script:storeAssignTargetCombo = New-Object System.Windows.Forms.ComboBox
$script:storeAssignTargetCombo.Width = 250
$script:storeAssignTargetCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
[void]$script:storeAssignTargetCombo.Items.AddRange(@((Get-UiString 'AssignNotAssigned'), (Get-UiString 'AssignAllUsers'), (Get-UiString 'AssignAllDevices'), (Get-UiString 'AssignCustomGroup')))
$script:storeAssignTargetCombo.SelectedIndex = 0
$script:storeAssignTargetCombo.Location = New-Object System.Drawing.Point(140, 64)
$cardStoreAssign.Controls.Add($script:storeAssignTargetCombo)

$script:storeAssignGroupIdBox = New-Object System.Windows.Forms.TextBox
$script:storeAssignGroupIdBox.Width = 244
$storeAssignGroupIdHost = New-RoundedInput -Inner $script:storeAssignGroupIdBox -X 400 -Y 62 -W 250 -H 32
$storeAssignGroupIdHost.Visible = $false
$cardStoreAssign.Controls.Add($storeAssignGroupIdHost)

$storeAssignFavButton = New-Object System.Windows.Forms.Button
$storeAssignFavButton.Tag = 'btn-secondary'
$storeAssignFavButton.Text = Get-UiString 'FavAddButton'
$storeAssignFavButton.Location = New-Object System.Drawing.Point(656, 62)
$storeAssignFavButton.Size = New-Object System.Drawing.Size(96, 32)
$storeAssignFavButton.Visible = $true
$storeAssignFavButton.Add_Click({ Show-GroupFavoriteDialog -GroupIdBox $script:storeAssignGroupIdBox })
$cardStoreAssign.Controls.Add($storeAssignFavButton)

$script:storeAssignTargetCombo.Add_SelectedIndexChanged({
  $isCustom = ($script:storeAssignTargetCombo.SelectedItem -eq (Get-UiString 'AssignCustomGroup'))
  $storeAssignGroupIdHost.Visible = $isCustom
})
Register-AssignTargetCombo -TargetCombo $script:storeAssignTargetCombo

$storeAssignIntentLabel = New-Object System.Windows.Forms.Label
$storeAssignIntentLabel.Text = Get-UiString 'AssignIntentLabel'
$storeAssignIntentLabel.Location = New-Object System.Drawing.Point(14, 108)
$storeAssignIntentLabel.AutoSize = $true
$cardStoreAssign.Controls.Add($storeAssignIntentLabel)

$script:storeAssignIntentCombo = New-Object System.Windows.Forms.ComboBox
$script:storeAssignIntentCombo.Width = 250
$script:storeAssignIntentCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
[void]$script:storeAssignIntentCombo.Items.AddRange(@((Get-UiString 'IntentAvailable'), (Get-UiString 'IntentRequired'), (Get-UiString 'IntentUninstall')))
$script:storeAssignIntentCombo.SelectedIndex = 0
$script:storeAssignIntentCombo.Location = New-Object System.Drawing.Point(140, 104)
$cardStoreAssign.Controls.Add($script:storeAssignIntentCombo)

$storeAdvToggle = New-Object System.Windows.Forms.Button
$storeAdvToggle.Tag = 'btn-secondary'
$storeAdvToggle.Text = (Get-UiString 'StoreAdvancedOptions') + "  " + [System.Char]::ConvertFromUtf32(0x25BE)
$storeAdvToggle.Location = New-Object System.Drawing.Point(14, 142)
$storeAdvToggle.Size = New-Object System.Drawing.Size(260, 30)
$cardStoreAssign.Controls.Add($storeAdvToggle)

# --- advanced assignment options (hidden until expanded) ---
$storeGroupModeLabel = New-Object System.Windows.Forms.Label
$storeGroupModeLabel.Text = Get-UiString 'DeployAssignmentModeLabel'
$storeGroupModeLabel.Location = New-Object System.Drawing.Point(14, 190)
$storeGroupModeLabel.AutoSize = $true
$cardStoreAssign.Controls.Add($storeGroupModeLabel)

$script:storeGroupModeCombo = New-Object System.Windows.Forms.ComboBox
$script:storeGroupModeCombo.Width = 250
$script:storeGroupModeCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
[void]$script:storeGroupModeCombo.Items.AddRange(@((Get-UiString 'DeployAssignmentIncluded'), (Get-UiString 'DeployAssignmentExcluded')))
$script:storeGroupModeCombo.SelectedIndex = 0
$script:storeGroupModeCombo.Location = New-Object System.Drawing.Point(240, 186)
$cardStoreAssign.Controls.Add($script:storeGroupModeCombo)

$storeExcludeBaseLabel = New-Object System.Windows.Forms.Label
$storeExcludeBaseLabel.Text = Get-UiString 'DeployExcludeBaseLabel'
$storeExcludeBaseLabel.Location = New-Object System.Drawing.Point(14, 226)
$storeExcludeBaseLabel.AutoSize = $true
$cardStoreAssign.Controls.Add($storeExcludeBaseLabel)

$script:storeExcludeBaseCombo = New-Object System.Windows.Forms.ComboBox
$script:storeExcludeBaseCombo.Width = 250
$script:storeExcludeBaseCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
[void]$script:storeExcludeBaseCombo.Items.AddRange(@((Get-UiString 'TargetAllUsers'), (Get-UiString 'TargetAllDevices')))
$script:storeExcludeBaseCombo.SelectedIndex = 0
$script:storeExcludeBaseCombo.Location = New-Object System.Drawing.Point(240, 222)
$cardStoreAssign.Controls.Add($script:storeExcludeBaseCombo)

$storeFilterModeLabel = New-Object System.Windows.Forms.Label
$storeFilterModeLabel.Text = Get-UiString 'DeployFilterModeLabel'
$storeFilterModeLabel.Location = New-Object System.Drawing.Point(14, 262)
$storeFilterModeLabel.AutoSize = $true
$cardStoreAssign.Controls.Add($storeFilterModeLabel)

$script:storeFilterModeCombo = New-Object System.Windows.Forms.ComboBox
$script:storeFilterModeCombo.Width = 250
$script:storeFilterModeCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
[void]$script:storeFilterModeCombo.Items.AddRange(@((Get-UiString 'DeployFilterNone'), (Get-UiString 'DeployFilterInclude'), (Get-UiString 'DeployFilterExclude')))
$script:storeFilterModeCombo.SelectedIndex = 0
$script:storeFilterModeCombo.Location = New-Object System.Drawing.Point(240, 258)
$cardStoreAssign.Controls.Add($script:storeFilterModeCombo)

$storeFilterIdLabel = New-Object System.Windows.Forms.Label
$storeFilterIdLabel.Text = Get-UiString 'DeployFilterIdLabel'
$storeFilterIdLabel.Location = New-Object System.Drawing.Point(14, 298)
$storeFilterIdLabel.AutoSize = $true
$cardStoreAssign.Controls.Add($storeFilterIdLabel)

$script:storeFilterIdBox = New-Object System.Windows.Forms.TextBox
$script:storeFilterIdBox.Width = 244
$storeFilterIdHost = New-RoundedInput -Inner $script:storeFilterIdBox -X 240 -Y 294 -W 250 -H 32
$cardStoreAssign.Controls.Add($storeFilterIdHost)

$storeNotifyLabel = New-Object System.Windows.Forms.Label
$storeNotifyLabel.Text = Get-UiString 'AppSettingsNotifyLabel'
$storeNotifyLabel.Location = New-Object System.Drawing.Point(14, 338)
$storeNotifyLabel.AutoSize = $true
$cardStoreAssign.Controls.Add($storeNotifyLabel)

$script:storeNotifyCombo = New-Object System.Windows.Forms.ComboBox
$script:storeNotifyCombo.Width = 250
$script:storeNotifyCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
[void]$script:storeNotifyCombo.Items.AddRange(@((Get-UiString 'AppSettingsNotifyKeep'), (Get-UiString 'AppSettingsNotifyAll'), (Get-UiString 'AppSettingsNotifyReboot'), (Get-UiString 'AppSettingsNotifyHide')))
$script:storeNotifyCombo.SelectedIndex = 0
$script:storeNotifyCombo.Location = New-Object System.Drawing.Point(240, 334)
$cardStoreAssign.Controls.Add($script:storeNotifyCombo)

# "Leave unchanged" does not mean "no notifications": the property is simply not sent, and Intune
# then applies its own default, which is showAll. Naming that here saves guessing what the neutral
# option actually produces on the device.
$storeNotifyDefaultHint = New-Object System.Windows.Forms.Label
$storeNotifyDefaultHint.Text = Get-UiString 'NotifyDefaultHint'
$storeNotifyDefaultHint.Location = New-Object System.Drawing.Point(500, 336)
$storeNotifyDefaultHint.Size = New-Object System.Drawing.Size(212, 30)
$cardStoreAssign.Controls.Add($storeNotifyDefaultHint)

$script:storeDeadlineCheck = New-Object System.Windows.Forms.CheckBox
$script:storeDeadlineCheck.Text = Get-UiString 'DeployDeadline'
$script:storeDeadlineCheck.Location = New-Object System.Drawing.Point(14, 374)
$script:storeDeadlineCheck.AutoSize = $true
$cardStoreAssign.Controls.Add($script:storeDeadlineCheck)

$script:storeDeadlinePicker = New-Object System.Windows.Forms.DateTimePicker
$script:storeDeadlinePicker.Format = [System.Windows.Forms.DateTimePickerFormat]::Custom
$script:storeDeadlinePicker.CustomFormat = "yyyy-MM-dd HH:mm"
$script:storeDeadlinePicker.Width = 250
$script:storeDeadlinePicker.Location = New-Object System.Drawing.Point(440, 370)
$cardStoreAssign.Controls.Add($script:storeDeadlinePicker)

$script:storeLocalTimeCheck = New-Object System.Windows.Forms.CheckBox
$script:storeLocalTimeCheck.Text = Get-UiString 'AppSettingsUseLocalTime'
$script:storeLocalTimeCheck.Location = New-Object System.Drawing.Point(14, 406)
$script:storeLocalTimeCheck.AutoSize = $true
$cardStoreAssign.Controls.Add($script:storeLocalTimeCheck)

$script:storeRestartEnableCheck = New-Object System.Windows.Forms.CheckBox
$script:storeRestartEnableCheck.Text = Get-UiString 'DeployRestartEnable'
$script:storeRestartEnableCheck.Location = New-Object System.Drawing.Point(14, 438)
$script:storeRestartEnableCheck.AutoSize = $true
$cardStoreAssign.Controls.Add($script:storeRestartEnableCheck)

$storeRestartGraceLabel = New-Object System.Windows.Forms.Label
$storeRestartGraceLabel.Text = Get-UiString 'AppSettingsRestartGrace'
$storeRestartGraceLabel.Location = New-Object System.Drawing.Point(34, 474)
$storeRestartGraceLabel.AutoSize = $true
$cardStoreAssign.Controls.Add($storeRestartGraceLabel)

$script:storeRestartGraceValue = New-Object System.Windows.Forms.NumericUpDown
$script:storeRestartGraceValue.Minimum = 0
$script:storeRestartGraceValue.Maximum = 10080
$script:storeRestartGraceValue.Value = 1440
$script:storeRestartGraceValue.Width = 90
$script:storeRestartGraceValue.Location = New-Object System.Drawing.Point(440, 470)
$cardStoreAssign.Controls.Add($script:storeRestartGraceValue)

$storeRestartCountdownLabel = New-Object System.Windows.Forms.Label
$storeRestartCountdownLabel.Text = Get-UiString 'AppSettingsRestartCountdown'
$storeRestartCountdownLabel.Location = New-Object System.Drawing.Point(34, 510)
$storeRestartCountdownLabel.AutoSize = $true
$cardStoreAssign.Controls.Add($storeRestartCountdownLabel)

$script:storeRestartCountdownValue = New-Object System.Windows.Forms.NumericUpDown
$script:storeRestartCountdownValue.Minimum = 0
$script:storeRestartCountdownValue.Maximum = 10080
$script:storeRestartCountdownValue.Value = 15
$script:storeRestartCountdownValue.Width = 90
$script:storeRestartCountdownValue.Location = New-Object System.Drawing.Point(440, 506)
$cardStoreAssign.Controls.Add($script:storeRestartCountdownValue)

$script:storeRestartSnoozeCheck = New-Object System.Windows.Forms.CheckBox
$script:storeRestartSnoozeCheck.Text = Get-UiString 'AppSettingsRestartSnooze'
$script:storeRestartSnoozeCheck.Location = New-Object System.Drawing.Point(34, 542)
$script:storeRestartSnoozeCheck.AutoSize = $true
$cardStoreAssign.Controls.Add($script:storeRestartSnoozeCheck)

$script:storeRestartSnoozeValue = New-Object System.Windows.Forms.NumericUpDown
$script:storeRestartSnoozeValue.Minimum = 0
$script:storeRestartSnoozeValue.Maximum = 10080
$script:storeRestartSnoozeValue.Value = 240
$script:storeRestartSnoozeValue.Width = 90
$script:storeRestartSnoozeValue.Location = New-Object System.Drawing.Point(440, 538)
$cardStoreAssign.Controls.Add($script:storeRestartSnoozeValue)

$storeCategoriesLabel = New-Object System.Windows.Forms.Label
$storeCategoriesLabel.Text = Get-UiString 'CategoriesLabel'
$storeCategoriesLabel.Location = New-Object System.Drawing.Point(14, 582)
$storeCategoriesLabel.AutoSize = $true
$cardStoreAssign.Controls.Add($storeCategoriesLabel)

# Its own field rather than the WinGet card's: reading that one meant categories typed for a WinGet
# package silently ended up on a Store app deployed afterwards.
$script:storeCategoriesBox = New-Object System.Windows.Forms.TextBox
$script:storeCategoriesBox.Width = 294
$script:storeCategoriesBox.PlaceholderText = Get-UiString 'CategoriesPlaceholder'
$storeCategoriesHost = New-RoundedInput -Inner $script:storeCategoriesBox -X 240 -Y 578 -W 300 -H 32
$cardStoreAssign.Controls.Add($storeCategoriesHost)

$storeUnsupportedNote = New-Object System.Windows.Forms.Label
$storeUnsupportedNote.Text = Get-UiString 'StoreUnsupportedNote'
$storeUnsupportedNote.Location = New-Object System.Drawing.Point(14, 620)
$storeUnsupportedNote.Size = New-Object System.Drawing.Size(698, 32)
$cardStoreAssign.Controls.Add($storeUnsupportedNote)

$script:storeAdvControls = @($storeGroupModeLabel, $script:storeGroupModeCombo,
                             $storeExcludeBaseLabel, $script:storeExcludeBaseCombo,
                             $storeFilterModeLabel, $script:storeFilterModeCombo,
                             $storeFilterIdLabel, $storeFilterIdHost,
                             $storeNotifyLabel, $script:storeNotifyCombo, $storeNotifyDefaultHint,
                             $script:storeDeadlineCheck, $script:storeDeadlinePicker, $script:storeLocalTimeCheck,
                             $script:storeRestartEnableCheck, $storeRestartGraceLabel, $script:storeRestartGraceValue,
                             $storeRestartCountdownLabel, $script:storeRestartCountdownValue,
                             $script:storeRestartSnoozeCheck, $script:storeRestartSnoozeValue,
                             $storeCategoriesLabel, $storeCategoriesHost,
                             $storeUnsupportedNote)
foreach ($c in $script:storeAdvControls) { $c.Visible = $false }

$script:storeAdvExpanded = $false
$storeAdvToggle.Add_Click({
  $script:storeAdvExpanded = -not $script:storeAdvExpanded
  foreach ($c in $script:storeAdvControls) { $c.Visible = $script:storeAdvExpanded }
  # Die Hoehe kommt aus dem Inhalt (Update-StoreAssignLayout), nicht aus zwei Konstanten.
  $chev = if ($script:storeAdvExpanded) { [System.Char]::ConvertFromUtf32(0x25B4) } else { [System.Char]::ConvertFromUtf32(0x25BE) }
  $storeAdvToggle.Text = (Get-UiString 'StoreAdvancedOptions') + "  " + $chev
  # Hier stand: "$cardStore.Top = $cardStoreAssign.Bottom + 12". Das war richtig, solange die
  # Zuweisungskarte OBEN stand - seit sie unter die App-Karte gewandert ist, schob diese Zeile die
  # App-Karte unter die Zuweisungskarte und die beiden tauschten beim Aufklappen die Plaetze.
  #
  # Die Anordnung gehoert an EINE Stelle, und die heisst Update-StoreLayout. Der Aufklapper aendert
  # nur noch die Hoehe seiner eigenen Karte und laesst neu anordnen.
  if (Get-Command Update-StoreLayout -ErrorAction SilentlyContinue) { Update-StoreLayout }
})


# --- Anordnung der Zuweisungskarte: gemessen, und ab genuegend Breite zweispaltig ---------------
#
# Die erweiterten Optionen standen als eine lange Spalte untereinander: Beschriftungen bei x=14,
# Bedienelemente bei x=240, dazwischen Kaestchen, die aus der Reihe fielen, und ein Datumsfeld, das
# ganz rechts klebte. Das las sich wie eine Liste ohne Ordnung, obwohl es drei Themen sind:
# WER (Gruppenmodus, Ausschlussbasis, Filter), WIE (Benachrichtigung, Stichtag) und NEUSTART.
#
# Diese Funktion ordnet die Karte in genau diesen Bloecken an - mit gemessener Beschriftungsspalte,
# damit kein Text unter einem Bedienelement verschwindet, und ab genuegend Breite in zwei Spalten,
# weil die Karte breit ist und die Liste sonst unnoetig tief wird.
function Update-StoreAssignLayout {
  if (-not $cardStoreAssign) { return }
  try {
    $m = 14
    $gap = 6
    $contentW = [Math]::Max(400, $cardStoreAssign.ClientSize.Width - (2 * $m))

    # Kopf: Titel, Hinweis, Ziel, Intent, Aufklapper - immer sichtbar, immer einspaltig.
    $storeAssignTitle.Left = $m
    $storeAssignCardHint.Left = $m
    $storeAssignCardHint.Width = $contentW
    $storeAssignCardHint.Top = $storeAssignTitle.Bottom + 6
    $headRows = @(
      @{ Cells = @(@{ L = $storeAssignTargetLabel; C = $script:storeAssignTargetCombo; W = 250 },
                   @{ L = $null; C = $storeAssignGroupIdHost; W = 250 },
                   @{ L = $null; C = $storeAssignFavButton; W = 96 }) }
      @{ Cells = @(@{ L = $storeAssignIntentLabel; C = $script:storeAssignIntentCombo; W = 250 }) }
    )
    $y = $storeAssignCardHint.Bottom + 8
    $y = Set-AppSettingsRowBlock -Rows $headRows -X $m -Y $y -Width $contentW -Gap $gap
    $storeAdvToggle.Left = $m
    $storeAdvToggle.Top = $y + 2
    $y = $storeAdvToggle.Bottom + 10

    if (-not $script:storeAdvExpanded) {
      $cardStoreAssign.Height = $y + 8
      return
    }

    # WER bekommt die App - und WIE sie geliefert wird.
    $rowsWho = @(
      @{ Cells = @(@{ L = $storeGroupModeLabel;   C = $script:storeGroupModeCombo;   W = 250 }) }
      @{ Cells = @(@{ L = $storeExcludeBaseLabel; C = $script:storeExcludeBaseCombo; W = 250 }) }
      @{ Cells = @(@{ L = $storeFilterModeLabel;  C = $script:storeFilterModeCombo;  W = 250 }) }
      @{ Cells = @(@{ L = $storeFilterIdLabel;    C = $storeFilterIdHost;            W = 250 }) }
      @{ Cells = @(@{ L = $storeCategoriesLabel;  C = $storeCategoriesHost;          W = 250 }) }
    )
    $rowsHow = @(
      @{ Cells = @(@{ L = $storeNotifyLabel; C = $script:storeNotifyCombo; W = 250 }) }
      @{ FullWidth = $true; Cells = @(@{ L = $null; C = $script:storeDeadlineCheck; W = (Get-ControlTextWidth $script:storeDeadlineCheck) + 24 },
                   @{ L = $null; C = $script:storeDeadlinePicker; W = 190 }) }
      @{ FullWidth = $true; Cells = @(@{ L = $null; C = $script:storeLocalTimeCheck; W = (Get-ControlTextWidth $script:storeLocalTimeCheck) + 24 }) }
      @{ FullWidth = $true; Cells = @(@{ L = $null; C = $script:storeRestartEnableCheck; W = (Get-ControlTextWidth $script:storeRestartEnableCheck) + 24 }) }
      @{ Indent = 20; Cells = @(@{ L = $storeRestartGraceLabel;     C = $script:storeRestartGraceValue;     W = 110 }) }
      @{ Indent = 20; Cells = @(@{ L = $storeRestartCountdownLabel; C = $script:storeRestartCountdownValue; W = 110 }) }
      @{ Indent = 20; FullWidth = $true; Cells = @(@{ L = $null; C = $script:storeRestartSnoozeCheck; W = (Get-ControlTextWidth $script:storeRestartSnoozeCheck) + 24 },
                                @{ L = $null; C = $script:storeRestartSnoozeValue; W = 110 }) }
    )

    # Zweispaltig, sobald beide Spalten wirklich hineinpassen - gemessen an den Beschriftungen
    # dieser Sprache, nicht an einer Pixelschwelle.
    $needWho = (Get-AppSettingsLabelColumn -Rows $rowsWho -Width $contentW) + 250
    $needHow = (Get-AppSettingsLabelColumn -Rows $rowsHow -Width $contentW) + 250 + 24 + 190
    $twoColumns = ($contentW -ge ($needWho + $needHow + 24))
    if ($twoColumns) {
      $colGap = 24
      $leftW = [int](($contentW - $colGap) * 0.46)
      $rightW = $contentW - $colGap - $leftW
      $endLeft  = Set-AppSettingsRowBlock -Rows $rowsWho -X $m -Y $y -Width $leftW -Gap $gap
      $endRight = Set-AppSettingsRowBlock -Rows $rowsHow -X ($m + $leftW + $colGap) -Y $y -Width $rightW -Gap $gap
      $y = [Math]::Max($endLeft, $endRight)
    } else {
      $sharedLabel = [Math]::Max((Get-AppSettingsLabelColumn -Rows $rowsWho -Width $contentW),
                                 (Get-AppSettingsLabelColumn -Rows $rowsHow -Width $contentW))
      $y = Set-AppSettingsRowBlock -Rows $rowsWho -X $m -Y $y -Width $contentW -Gap $gap -LabelWidth $sharedLabel
      $y = Set-AppSettingsRowBlock -Rows $rowsHow -X $m -Y $y -Width $contentW -Gap $gap -LabelWidth $sharedLabel
    }

    # Der Hinweis auf die NICHT unterstuetzten Einstellungen steht am Ende, ueber die volle Breite.
    if ($storeNotifyDefaultHint) {
      $storeNotifyDefaultHint.Left = $m
      $storeNotifyDefaultHint.Top = $y + 2
      $storeNotifyDefaultHint.Width = $contentW
      $storeNotifyDefaultHint.Height = Get-ControlTextHeight $storeNotifyDefaultHint $contentW
      $y = $storeNotifyDefaultHint.Bottom + 4
    }
    if ($storeUnsupportedNote) {
      $storeUnsupportedNote.Left = $m
      $storeUnsupportedNote.Top = $y + 2
      $storeUnsupportedNote.Width = $contentW
      $storeUnsupportedNote.Height = Get-ControlTextHeight $storeUnsupportedNote $contentW
      $y = $storeUnsupportedNote.Bottom
    }
    $cardStoreAssign.Height = $y + 12
  } catch { Write-LogDebug 'store assign layout' }
}

# --- Card B: Microsoft Store app (deployed directly, no packaging) ---
# Includes a tenant inventory so duplicate Store package IDs are visible before deployment.
$cardStore = New-Card -X 16 -Y 48 -W 726 -H 310
$tabStore.Controls.Add($cardStore)

$storeTitle = New-Object System.Windows.Forms.Label
$storeTitle.Text = Get-UiString 'StoreCardTitle'
$storeTitle.Location = New-Object System.Drawing.Point(14, 10)
$storeTitle.AutoSize = $true
$storeTitle.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$cardStore.Controls.Add($storeTitle)

$storeQueryLabel = New-Object System.Windows.Forms.Label
$storeQueryLabel.Text = Get-UiString 'StoreQueryLabel'
$storeQueryLabel.Location = New-Object System.Drawing.Point(14, 44)
$storeQueryLabel.AutoSize = $true
$cardStore.Controls.Add($storeQueryLabel)

$storeQueryBox = New-Object System.Windows.Forms.TextBox
$storeQueryBox.Width = 344
$storeQueryBox.PlaceholderText = Get-UiString 'StoreQueryPlaceholder'
$storeQueryHost = New-RoundedInput -Inner $storeQueryBox -X 158 -Y 38 -W 344 -H 32
$cardStore.Controls.Add($storeQueryHost)

$storeTenantSearchButton = New-Object System.Windows.Forms.Button
$storeTenantSearchButton.Tag = 'btn-secondary'
$storeTenantSearchButton.Text = Get-UiString 'StoreTenantSearchButton'
$storeTenantSearchButton.Location = New-Object System.Drawing.Point(514, 38)
$storeTenantSearchButton.Size = New-Object System.Drawing.Size(198, 32)
$cardStore.Controls.Add($storeTenantSearchButton)

# Deploy sits AFTER the catalog search: searching is the first step, and the search fills this
# card's input field with the exact package id that deploying then relies on.
$storeDeployButton = New-Object System.Windows.Forms.Button
$storeDeployButton.Text = Get-UiString 'StoreDeployButton'
$storeDeployButton.Location = New-Object System.Drawing.Point(226, 78)
$storeDeployButton.Size = New-Object System.Drawing.Size(200, 32)
$cardStore.Controls.Add($storeDeployButton)

# Searches the Store CATALOG, unlike the two tenant-inventory buttons. Deploying needs one exact
# package id, so this fills the input field above from a picker instead of forcing the user to
# already know the precise Store name.
$storeCatalogSearchButton = New-Object System.Windows.Forms.Button
$storeCatalogSearchButton.Tag = 'btn-secondary'
$storeCatalogSearchButton.Text = Get-UiString 'StoreCatalogSearchButton'
$storeCatalogSearchButton.Location = New-Object System.Drawing.Point(14, 78)
$storeCatalogSearchButton.Size = New-Object System.Drawing.Size(200, 32)
$cardStore.Controls.Add($storeCatalogSearchButton)

$storeShowAllButton = New-Object System.Windows.Forms.Button
$storeShowAllButton.Tag = 'btn-secondary'
$storeShowAllButton.Text = Get-UiString 'StoreTenantShowAllButton'
$storeShowAllButton.Location = New-Object System.Drawing.Point(438, 78)
$storeShowAllButton.Size = New-Object System.Drawing.Size(200, 32)
$cardStore.Controls.Add($storeShowAllButton)

# Live preview of what deploying will actually do. The target, intent and advanced settings live in
# the "Package and deploy" card ABOVE this one and were easy to miss entirely - the old static hint
# only said so in prose, so an app was deployed unassigned without the user noticing why.
$storeHintLabel = New-Object System.Windows.Forms.Label
$storeHintLabel.Text = Get-UiString 'StoreHint'
$storeHintLabel.Location = New-Object System.Drawing.Point(14, 116)
$storeHintLabel.Size = New-Object System.Drawing.Size(698, 46)
$cardStore.Controls.Add($storeHintLabel)

# Builds the assignment settings object from THIS section's controls, or $null when nothing was
# changed. Deliberately narrower than Get-DeployAssignmentSettings: no availability date and no
# delivery optimisation, because Microsoft Store apps do not honour either.
# Der Store-Weg ist BEWUSST schmaler: kein Verfuegbarkeitsdatum und keine Zustellprioritaet - der
# Store-Pfad des Moduls traegt sie nicht. Vorher war dieser Unterschied nur daran zu erkennen, dass
# in der Kopie zwei Zeilen fehlten; jetzt steht er als fehlender Schluessel da.
function Get-StoreAssignmentSettings {
  return (Read-AssignmentSettingsControls -Controls @{
    NotifyCombo            = $script:storeNotifyCombo
    DeadlineCheck          = $script:storeDeadlineCheck
    DeadlinePicker         = $script:storeDeadlinePicker
    LocalTimeCheck         = $script:storeLocalTimeCheck
    RestartEnableCheck     = $script:storeRestartEnableCheck
    RestartGraceValue      = $script:storeRestartGraceValue
    RestartCountdownValue  = $script:storeRestartCountdownValue
    RestartSnoozeCheck     = $script:storeRestartSnoozeCheck
    RestartSnoozeValue     = $script:storeRestartSnoozeValue
  })
}

function Get-StoreAssignmentTargetChanges {
  $mode = if ($script:storeGroupModeCombo.SelectedIndex -eq 1) { 'exclude' } else { 'include' }
  $filterType = switch ($script:storeFilterModeCombo.SelectedIndex) {
    1 { 'include' }
    2 { 'exclude' }
    default { 'none' }
  }
  $excludeBase = if ($script:storeExcludeBaseCombo.SelectedIndex -eq 1) { 'AllDevices' } else { 'AllUsers' }
  $changes = @{ AssignmentMode = $mode; ExcludeBaseTarget = $excludeBase; FilterType = $filterType }
  if ($filterType -ne 'none') { $changes.FilterId = $script:storeFilterIdBox.Text.Trim() }
  return $changes
}

function Update-StoreAssignmentPreview {
  try {
    if (-not $storeHintLabel) { return }
    $target = Get-SelectedAssignmentTarget -TargetCombo $script:storeAssignTargetCombo -GroupIdBox $script:storeAssignGroupIdBox
    if (-not $target) {
      $storeHintLabel.Text = Get-UiString 'StoreAssignPreviewNone'
      $storeHintLabel.ForeColor = [System.Drawing.Color]::DarkOrange
      return
    }
    $intentIndex = if ($script:storeAssignIntentCombo) { [int]$script:storeAssignIntentCombo.SelectedIndex } else { 0 }
    $intentText = switch ($intentIndex) {
      1 { Get-UiString 'IntentRequired' }
      2 { Get-UiString 'IntentUninstall' }
      default { Get-UiString 'IntentAvailable' }
    }
    $scopeText = switch ([int]$script:storeAssignTargetCombo.SelectedIndex) {
      1 { Get-UiString 'TargetAllUsers' }
      2 { Get-UiString 'TargetAllDevices' }
      3 { (Get-UiString 'TargetGroup') -f [string]$target }
      default { [string]$target }
    }
    $storeHintLabel.Text = (Get-UiString 'StoreAssignPreview') -f $scopeText, $intentText
    $storeHintLabel.ForeColor = $script:currentTheme.ForeColor
  } catch { }   # class 3: a preview must never block deployment
}

# Kept in sync with the controls it mirrors, so the Store card always states what will happen.
$script:storeAssignTargetCombo.Add_SelectedIndexChanged({ Update-StoreAssignmentPreview })
$script:storeAssignGroupIdBox.Add_TextChanged({ Update-StoreAssignmentPreview })
if ($script:storeAssignIntentCombo) { $script:storeAssignIntentCombo.Add_SelectedIndexChanged({ Update-StoreAssignmentPreview }) }
Update-StoreAssignmentPreview

$storeTenantListView = New-Object System.Windows.Forms.ListView
$storeTenantListView.Location = New-Object System.Drawing.Point(14, 170)
$storeTenantListView.Size = New-Object System.Drawing.Size(698, 126)
$storeTenantListView.View = [System.Windows.Forms.View]::Details
$storeTenantListView.FullRowSelect = $true
$storeTenantListView.MultiSelect = $false
$storeTenantListView.HideSelection = $false
$storeTenantListView.HeaderStyle = [System.Windows.Forms.ColumnHeaderStyle]::Nonclickable
[void]$storeTenantListView.Columns.Add((Get-UiString 'StoreColName'), 230)
[void]$storeTenantListView.Columns.Add((Get-UiString 'StoreColPackageId'), 210)
[void]$storeTenantListView.Columns.Add((Get-UiString 'StoreColAssigned'), 95)
[void]$storeTenantListView.Columns.Add((Get-UiString 'StoreColState'), 135)
$cardStore.Controls.Add($storeTenantListView)

# Bis hierhin hatte die Liste keinen einzigen Klick-Handler: Markieren einer Zeile bewirkte nichts.
# Der Knopf oeffnet fuer die markierte, bereits im Tenant vorhandene App denselben
# Zuweisungs-Manager wie bei "Alle Tenant-Apps" (Show-AssignmentManagerDialog).
$storeManageAssignmentsButton = New-Object System.Windows.Forms.Button
$storeManageAssignmentsButton.Tag = 'btn-secondary'
$storeManageAssignmentsButton.Text = Get-UiString 'StoreManageAssignmentsButton'
$storeManageAssignmentsButton.Location = New-Object System.Drawing.Point(14, 304)
$storeManageAssignmentsButton.Size = New-Object System.Drawing.Size(260, 32)
$storeManageAssignmentsButton.Enabled = $false
$cardStore.Controls.Add($storeManageAssignmentsButton)

$storeTenantListView.Add_SelectedIndexChanged({
  $storeManageAssignmentsButton.Enabled = ($storeTenantListView.SelectedItems.Count -gt 0)
})

$storeManageAssignmentsButton.Add_Click({
  if (-not (Test-Connected)) { return }
  if (Test-UiBusy) { return }
  if ($storeTenantListView.SelectedItems.Count -eq 0) { return }
  $app = $storeTenantListView.SelectedItems[0].Tag
  if (-not $app -or -not $app.Id) { return }
  $changed = Show-AssignmentManagerDialog -AppId ([string]$app.Id) -AppName ([string]$app.DisplayName)
  if ($changed) {
    # Der Zuweisungs-Manager schreibt gegen den Tenant, nicht gegen dieses Cache-Objekt - die
    # Spalte "Zugewiesen" muss also neu gelesen werden, sonst zeigt sie den alten Stand.
    try { Refresh-TenantStoreApps -Query $storeQueryBox.Text.Trim() } catch { }
  }
})

$script:tenantStoreApps = @()

function Update-TenantStoreListView {
  param([string]$Query = '')
  $filtered = @($script:tenantStoreApps)
  if (-not [string]::IsNullOrWhiteSpace($Query)) {
    $q = $Query.Trim()
    $filtered = @($filtered | Where-Object {
      ([string]$_.DisplayName).IndexOf($q, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
      ([string]$_.PackageIdentifier).IndexOf($q, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
      ([string]$_.Publisher).IndexOf($q, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
    })
  }
  $storeTenantListView.BeginUpdate()
  try {
    $storeTenantListView.Items.Clear()
    foreach ($app in $filtered) {
      $row = New-Object System.Windows.Forms.ListViewItem([string]$app.DisplayName)
      $row.Tag = $app
      [void]$row.SubItems.Add([string]$app.PackageIdentifier)
      [void]$row.SubItems.Add($(if ($app.IsAssigned) { Get-UiString 'StoreAssignedYes' } else { Get-UiString 'StoreAssignedNo' }))
      [void]$row.SubItems.Add([string]$app.PublishingState)
      [void]$storeTenantListView.Items.Add($row)
    }
  } finally { $storeTenantListView.EndUpdate() }
  if ($filtered.Count -eq 0) { Update-Status (Get-UiString 'StoreTenantNoMatchesStatus') }
  else { Update-Status ((Get-UiString 'StoreTenantLoadedStatus') -f $filtered.Count) }
}

function Refresh-TenantStoreApps {
  param([string]$Query = '')
  Update-Status (Get-UiString 'StoreTenantLoadingStatus')
  [System.Windows.Forms.Application]::DoEvents()
  $script:tenantStoreApps = @(Get-TenantStoreApps)
  Update-TenantStoreListView -Query $Query
}

# Highlights one entry after a deployment, so the app that was just created is the one in view.
# Matched on the Graph id when it is known and on the package identifier otherwise - the id is the
# authoritative handle, but it stays $null when the tenant could not be re-read.
function Select-StoreListEntry {
  param([string]$PackageIdentifier, [string]$GraphId)
  if (-not $storeTenantListView) { return }
  foreach ($row in $storeTenantListView.Items) {
    $app = $row.Tag
    if (-not $app) { continue }
    $isMatch = if ($GraphId) { ([string]$app.Id) -eq $GraphId }
               else { ([string]$app.PackageIdentifier) -eq $PackageIdentifier }
    if ($isMatch) {
      $row.Selected = $true
      $row.EnsureVisible()
      try { $storeTenantListView.Focus() } catch { }   # class 3: focus is cosmetic here
      return
    }
  }
}

# Catalog search: unlike the tenant buttons this needs no Graph connection, because it only asks
# winget. The picked package id is written back into the query box, so the existing deploy path
# then resolves unambiguously instead of failing on a name like "Spotify".
$storeCatalogSearchButton.Add_Click({
  if (Test-UiBusy) { return }
  $query = $storeQueryBox.Text.Trim()
  if (-not $query) { Update-Status (Get-UiString 'StoreQueryEmptyStatus'); return }
  try {
    $storeCatalogSearchButton.Enabled = $false
    Update-Status ((Get-UiString 'StoreSearchingStatus') -f $query)
    [System.Windows.Forms.Application]::DoEvents()  # pumps the message loop; this work stays on the UI thread on purpose (see 70-Runtime)

    $results = @(Search-MsStorePackage -Query $query)
    if ($results.Count -eq 0) {
      Update-Status ((Get-UiString 'StoreSearchNoResultsStatus') -f $query)
      Write-Log ("Microsoft Store search returned no result for '{0}'." -f $query)
      return
    }

    Write-Log ("Microsoft Store search for '{0}' returned {1} distinct package(s)." -f $query, $results.Count)
    $picked = Show-StorePickerDialog -Results $results
    if (-not $picked) { Update-Status ''; return }

    $storeQueryBox.Text = [string]$picked.PackageIdentifier
    Update-Status ((Get-UiString 'StoreSearchPickedStatus') -f $picked.Name, $picked.PackageIdentifier)
    Write-Log ("Selected Microsoft Store package '{0}' ({1}) for deployment." -f $picked.Name, $picked.PackageIdentifier)
  } catch {
    Write-Log ("Microsoft Store search failed: {0}" -f $_.Exception.Message)
    Update-Status ((Get-UiString 'StoreSearchFailedStatus') -f $_.Exception.Message)
  } finally {
    $storeCatalogSearchButton.Enabled = $true
  }
})

$storeTenantSearchButton.Add_Click({
  if (-not (Test-Connected)) { return }
  if (Test-UiBusy) { return }
  try {
    $storeTenantSearchButton.Enabled = $false; $storeShowAllButton.Enabled = $false
    Refresh-TenantStoreApps -Query $storeQueryBox.Text.Trim()
  } catch {
    Write-Log ("Store tenant search failed: {0}" -f $_.Exception.Message)
    Update-Status ((Get-UiString 'StoreTenantLoadFailedStatus') -f $_.Exception.Message)
  } finally {
    $storeTenantSearchButton.Enabled = $true; $storeShowAllButton.Enabled = $true
  }
})

$storeShowAllButton.Add_Click({
  if (-not (Test-Connected)) { return }
  if (Test-UiBusy) { return }
  try {
    $storeTenantSearchButton.Enabled = $false; $storeShowAllButton.Enabled = $false
    Refresh-TenantStoreApps
  } catch {
    Write-Log ("Store tenant inventory failed: {0}" -f $_.Exception.Message)
    Update-Status ((Get-UiString 'StoreTenantLoadFailedStatus') -f $_.Exception.Message)
  } finally {
    $storeTenantSearchButton.Enabled = $true; $storeShowAllButton.Enabled = $true
  }
})

$storeDeployButton.Add_Click({
  if (-not (Test-Connected)) { return }
  if (Test-UiBusy) { return }
  $q = $storeQueryBox.Text.Trim()
  if ([string]::IsNullOrWhiteSpace($q)) { Update-Status (Get-UiString 'StoreQueryEmptyStatus'); return }
  try {
    $storeDeployButton.Enabled = $false
    Show-Progress
    Update-Status ((Get-UiString 'StoreDeployingStatus') -f $q)
    [System.Windows.Forms.Application]::DoEvents()

    # Resolve the first Store search result to an exact package identity before changing Intune.
    # Deployment then uses PackageId, so the duplicate guard and the mutation refer to the same app.
    $storePackage = Resolve-MsStorePackage -Query $q
    $storePackageId = [string]$storePackage.PackageIdentifier
    Write-Log ("Store query '{0}' resolved to '{1}' ({2})." -f $q, $storePackage.Name, $storePackageId)
    $script:tenantStoreApps = @(Get-TenantStoreApps)
    $duplicates = @(Find-TenantStoreAppMatch -Apps $script:tenantStoreApps -Query $storePackageId)
    Update-TenantStoreListView -Query $q
    if ($duplicates.Count -gt 0) {
      $lines = @($duplicates | Select-Object -First 8 | ForEach-Object {
        $assigned = if ($_.IsAssigned) { Get-UiString 'StoreAssignedYes' } else { Get-UiString 'StoreAssignedNo' }
        "{0} | {1} | Intune {2} | {3} | {4}" -f $_.DisplayName, $_.PackageIdentifier, $_.Id, $assigned, $_.PublishingState
      })
      if ($duplicates.Count -gt 8) { $lines += '...' }
      [void][System.Windows.Forms.MessageBox]::Show(
        ((Get-UiString 'StoreAlreadyExistsDialog') -f ($lines -join "`r`n")),
        (Get-UiString 'StoreAlreadyExistsTitle'),
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information)
      Write-Log ("Store deploy blocked for '{0}': {1} matching tenant app(s) already exist." -f $q, $duplicates.Count)
      return
    }

    # This section's own assignment controls. They used to be borrowed from the "Package and deploy"
    # card in the WinGet section, which is why the hint below pointed at a card that was not even on
    # screen once the Store moved into its own section.
    $assignTarget = Get-SelectedAssignmentTarget -TargetCombo $script:storeAssignTargetCombo -GroupIdBox $script:storeAssignGroupIdBox
    $targetChanges = Get-StoreAssignmentTargetChanges
    $plannedDeploySettings = Get-StoreAssignmentSettings
    $intentIdx = if ($script:storeAssignIntentCombo) { [int]$script:storeAssignIntentCombo.SelectedIndex } else { 0 }
    $assignmentIntent = switch ($intentIdx) { 1 { 'required' }; 2 { 'uninstall' }; default { 'available' } }
    if (-not $assignTarget -and ($plannedDeploySettings -or $intentIdx -ne 0 -or $targetChanges.AssignmentMode -eq 'exclude' -or $targetChanges.FilterType -ne 'none')) {
      throw (Get-UiString 'DeployAssignmentTargetRequired')
    }
    if ($script:storeAssignTargetCombo.SelectedIndex -eq 3 -and -not (Test-GuidString ([string]$assignTarget))) {
      throw (Get-UiString 'DeployGroupIdRequired')
    }
    if ($assignTarget -and $targetChanges.AssignmentMode -eq 'exclude' -and -not (Test-IsGroupSelection -TargetCombo $script:storeAssignTargetCombo)) {
      throw (Get-UiString 'DeployExcludedRequiresGroup')
    }
    if ($targetChanges.AssignmentMode -eq 'exclude' -and $targetChanges.FilterType -ne 'none') {
      throw (Get-UiString 'DeployExcludeFilterConflict')
    }
    if ($targetChanges.FilterType -ne 'none' -and -not (Test-GuidString ([string]$targetChanges.FilterId))) {
      throw (Get-UiString 'DeployFilterIdRequired')
    }
    # Upload unassigned. The complete assignment is created only after the authoritative Graph ID
    # has been resolved from packageIdentifier.
    $splat = @{ PackageId = $storePackageId; ErrorAction = 'Stop' }
    if ($script:storeCategoriesBox -and -not [string]::IsNullOrWhiteSpace($script:storeCategoriesBox.Text)) {
      $cats = @($script:storeCategoriesBox.Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
      if ($cats.Count -gt 0) { $splat.Categories = $cats }
    }

    # Creating the app over Graph directly is the primary path. Deploy-WtMsStoreApp drives the
    # Graph .NET SDK, which in this GUI fails every single time with a retried ServiceUnavailable -
    # reproduced across two days, two apps and module versions 1.3.2 and 1.4.1 - and burns roughly
    # 22 seconds on retries before giving up. Our own Invoke-RestMethod reaches the same tenant from
    # the same thread in about a second. The module stays as a fallback in case a future version
    # sets properties this payload does not.
    $storeResult = $null
    try {
      $storeResult = New-TenantStoreAppViaGraph -PackageIdentifier $storePackageId -DisplayName ([string]$storePackage.Name) -Categories $splat.Categories
    } catch {
      $graphError = $_.Exception.Message
      Write-Log ("Direct Graph creation of the Store app failed ({0}); falling back to Deploy-WtMsStoreApp." -f $graphError)
      Update-Status (Get-UiString 'StoreFallbackStatus')
      [System.Windows.Forms.Application]::DoEvents()  # pumps the message loop; this work stays on the UI thread on purpose (see 70-Runtime)
      $storeResult = Deploy-WtMsStoreApp @splat
    }
    $returnedStoreId = if ($storeResult -and $storeResult.Id) { [string]$storeResult.Id } else { $null }
    if (-not $returnedStoreId -and $storeResult -and $storeResult.id) { $returnedStoreId = [string]$storeResult.id }
    $resolvedStoreApp = Resolve-DeployedStoreTarget -PackageIdentifier $storePackageId -ReturnedId $returnedStoreId
    $storeGraphId = if ($resolvedStoreApp) { [string]$resolvedStoreApp.Id } else { $null }
    $storeProblems = [System.Collections.Generic.List[string]]::new()
    if ($assignTarget -and $storeGraphId) {
      $settings = if ($plannedDeploySettings) { $plannedDeploySettings } else { @{ '@odata.type' = '#microsoft.graph.win32LobAppAssignmentSettings' } }
      $assignmentResult = New-AppAssignmentConfiguration -AppId $storeGraphId -TargetValue $assignTarget -Intent $assignmentIntent `
        -AssignmentMode ([string]$targetChanges.AssignmentMode) -ExcludeBaseTarget ([string]$targetChanges.ExcludeBaseTarget) -FilterType ([string]$targetChanges.FilterType) `
        -FilterId ([string]$targetChanges.FilterId) -Settings $settings -AppKind winget -AppName $storePackageId
      if ($assignmentResult.ErrorMessage) { $storeProblems.Add([string]$assignmentResult.ErrorMessage) }
    } elseif ($assignTarget) {
      $storeProblems.Add('The authoritative Intune Store app ID could not be resolved; no assignment was created.')
    }
    # The settings Store apps cannot honour are no longer offered in this section, so there is
    # nothing left to warn about here - the note in the assignment card states it up front instead.
    Write-Log ("Store deploy: '{0}' ({1}) -> {2}" -f $q, $storePackageId, $(if ($storeGraphId) { $storeGraphId } else { 'unresolved' }))
    # The Store app was created above; record it for the performance text. Its assignment, if any,
    # is recorded inside New-AppAssignmentConfiguration and is therefore not duplicated here.
    try { Add-SessionActivity -Kind 'Deployed' -Name ([string]$storePackage.Name) -Detail (Get-UiString 'ActivityDeployed') } catch { }
    # Keep the freshly deployed app in view. The query box used to be cleared and the inventory
    # reloaded unfiltered, so the list jumped to every Store app in the tenant and the one just
    # created was lost among them - in a large tenant, off screen entirely.
    $storeQueryBox.Text = $storePackageId
    try {
      Refresh-TenantStoreApps -Query $storePackageId
      Select-StoreListEntry -PackageIdentifier $storePackageId -GraphId $storeGraphId
    } catch { Write-Log ("Store inventory refresh after deploy failed: {0}" -f $_.Exception.Message) }
    if ($storeProblems.Count -gt 0) {
      Update-Status ((Get-UiString 'StorePartialStatus') -f ($storeProblems -join '; '))
    } else {
      Update-Status ((Get-UiString 'StoreDeployedSelectedStatus') -f $storePackage.Name)
    }
  } catch {
    $m = $_.Exception.Message
    # Intune answering "ServiceUnavailable" to the create call has nothing to do with the user's
    # input - the package was already resolved successfully above. The raw message repeats the same
    # retry text four times and tells the user nothing actionable, so it is replaced by a dialog
    # that names the cause and offers the portal as a way through.
    if ($m -match 'ServiceUnavailable' -or $m -match 'Too many retries') {
      Write-Log "Store deploy failed for '$q' with a Microsoft-side ServiceUnavailable after the module's retries: $m"
      Update-Status ((Get-UiString 'StoreDeployFailedStatus') -f 'ServiceUnavailable')
      [void][System.Windows.Forms.MessageBox]::Show(
        ((Get-UiString 'StoreServiceUnavailable') -f $q),
        (Get-UiString 'InfoTitle'),
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning)
    } else {
      Update-Status ((Get-UiString 'StoreDeployFailedStatus') -f $m)
      Write-Log "Store deploy failed for '$q': $m"
    }
  } finally {
    Hide-Progress
    $storeDeployButton.Enabled = $true
  }
})

# ==================================================
# Section: Local packages
# ==================================================
#
# War bis hierher die dritte Karte in "Apps aus WinGet hinzufuegen" - und legt nichts in Intune an.
# Sie pflegt lokale Paketkopien: pruefen, herunterladen, alle lokalen Apps aktualisieren, plus eine
# Autostart-Option. Mit dem Bereitstellen teilt sie nur, dass beides WinGet benutzt. In einer Seite,
# deren Info-Text erklaeren muss, dass sie fuer Apps ist, die es in Intune noch NICHT gibt, war das
# eine dritte Bedeutung auf derselben Flaeche.
#
# "Favorit hinzufuegen" bleibt absichtlich drueben bei der Suche: aufgenommen wird ein Paket dort,
# wo man es gerade gefunden hat. Verwaltet wird die Liste hier.
$tabLocalPackages = New-Object System.Windows.Forms.Panel
$tabLocalPackages.AutoScroll = $true
Add-Section -Key 'localpackages' -Panel $tabLocalPackages -Label (Get-UiString 'TabLocalPackages') -Group 'local'

# Eine Karte, Hoehe aus dem Inhalt - sonst bliebe dort die Luecke stehen, wo die Autostart-Option
# stand, bevor sie in die Einstellungen umgezogen ist.
#
# Die Liste selbst waechst mit: sie stand auf festen 108 px, also gut vier Zeilen, waehrend darunter
# auf einem normalen Bildschirm 350 px leer blieben und man in einer halbleeren Seite scrollte.
function Update-LocalPackagesLayout {
  if (-not $cardFavorites -or -not $favoriteListView) { return }
  try {
    $inner = [Math]::Max(400, $cardFavorites.ClientSize.Width - 28)
    $favoriteListView.Width = $inner
    # Zusaetzliche Breite geht an die Statusspalte - dort stehen ganze Saetze.
    $extra = $inner - [System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth - 2 - 692
    if ($extra -gt 0 -and $favoriteListView.Columns.Count -ge 4) {
      $favoriteListView.Columns[0].Width = 280 + [int]($extra * 0.35)
      $favoriteListView.Columns[3].Width = 202 + [int]($extra * 0.65)
    }
    # Hoehe aus dem, was die Sektion hergibt: Kartenrand oben (48), Listenanfang (36), darunter
    # Knopfreihe und Kartenrand. Gemessen statt gezaehlt, damit ein Designwechsel nichts verschiebt.
    $avail = $tabLocalPackages.ClientSize.Height
    if ($avail -ge 300) {
      $buttonH = [Math]::Max(28, $favoriteRefreshButton.Height)
      $listH = $avail - 48 - 36 - 10 - $buttonH - 16 - 6
      if ($listH -lt 108) { $listH = 108 }
      $favoriteListView.Height = $listH
      foreach ($b in @($favoriteRefreshButton, $favoriteRemoveButton, $favoriteAllLocalButton)) {
        if ($b) { $b.Top = $favoriteListView.Bottom + 10 }
      }
    }
  } catch { Write-LogDebug 'local packages layout' }
  Update-StackedCards -Panel $tabLocalPackages -Cards @($cardFavorites)
}

$localPackagesHeaderLabel = New-Object System.Windows.Forms.Label
$localPackagesHeaderLabel.Text = Get-UiString 'LocalPackagesHeaderLabel'
$localPackagesHeaderLabel.Location = New-Object System.Drawing.Point(16, 12)
$localPackagesHeaderLabel.AutoSize = $true
$localPackagesHeaderLabel.Font = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)
$tabLocalPackages.Controls.Add($localPackagesHeaderLabel)
[void](Add-SectionInfoBadge -Parent $tabLocalPackages -AfterLabel $localPackagesHeaderLabel -TextKey 'InfoLocalPackages')

$cardFavorites = New-Card -X 16 -Y 48 -W 726 -H 230
$tabLocalPackages.Controls.Add($cardFavorites)

$favoriteTitle = New-Object System.Windows.Forms.Label
$favoriteTitle.Text = Get-UiString 'FavoriteCardTitle'
$favoriteTitle.Location = New-Object System.Drawing.Point(14, 10)
$favoriteTitle.AutoSize = $true
$favoriteTitle.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$cardFavorites.Controls.Add($favoriteTitle)
[void](Add-SectionInfoBadge -Parent $cardFavorites -AfterLabel $favoriteTitle -TextKey 'InfoCardFavorites')

$favoriteListView = New-Object System.Windows.Forms.ListView
$favoriteListView.Location = New-Object System.Drawing.Point(14, 36)
$favoriteListView.Size = New-Object System.Drawing.Size(698, 108)
$favoriteListView.View = [System.Windows.Forms.View]::Details
$favoriteListView.FullRowSelect = $true
$favoriteListView.MultiSelect = $true
$favoriteListView.HideSelection = $false
[void]$favoriteListView.Columns.Add((Get-UiString 'ColFavoritePackage'), 280)
[void]$favoriteListView.Columns.Add((Get-UiString 'ColFavoriteLocal'), 105)
[void]$favoriteListView.Columns.Add((Get-UiString 'ColFavoriteOnline'), 105)
[void]$favoriteListView.Columns.Add((Get-UiString 'ColFavoriteStatus'), 202)
$cardFavorites.Controls.Add($favoriteListView)

$favoriteRefreshButton = New-Object System.Windows.Forms.Button
$favoriteRefreshButton.Text = Get-UiString 'FavoriteRefreshButton'
$favoriteRefreshButton.Location = New-Object System.Drawing.Point(14, 154)
$favoriteRefreshButton.Size = New-Object System.Drawing.Size(230, 32)
$cardFavorites.Controls.Add($favoriteRefreshButton)

$favoriteRemoveButton = New-Object System.Windows.Forms.Button
$favoriteRemoveButton.Tag = 'btn-secondary'
$favoriteRemoveButton.Text = Get-UiString 'FavoriteRemoveButton'
$favoriteRemoveButton.Location = New-Object System.Drawing.Point(254, 154)
$favoriteRemoveButton.Size = New-Object System.Drawing.Size(180, 32)
$cardFavorites.Controls.Add($favoriteRemoveButton)

$favoriteAllLocalButton = New-Object System.Windows.Forms.Button
$favoriteAllLocalButton.Tag = 'btn-secondary'
$favoriteAllLocalButton.Text = Get-UiString 'FavoriteAllLocalButton'
$favoriteAllLocalButton.Location = New-Object System.Drawing.Point(444, 154)
$favoriteAllLocalButton.Size = New-Object System.Drawing.Size(268, 32)
$cardFavorites.Controls.Add($favoriteAllLocalButton)

# Die Autostart-Option stand hier und speicherte sich beim Klick. Sie ist eine Startup-Entscheidung
# wie "nach der Anmeldung nach Updates suchen" und liegt jetzt bei den anderen, auf der
# Einstellungsseite in der Karte "Paketierung auf diesem Rechner" (siehe 85-Rows).

function Get-FavoriteListRow {
  param([Parameter(Mandatory)][string]$PackageId)
  foreach ($row in @($favoriteListView.Items)) {
    if ([string]::Equals([string]$row.Tag, $PackageId, [System.StringComparison]::OrdinalIgnoreCase)) { return $row }
  }
  return $null
}

function Update-FavoritePackageList {
  $favoriteListView.BeginUpdate()
  try {
    $favoriteListView.Items.Clear()
    $root = if ($pathBox -and $pathBox.Text.Trim()) { $pathBox.Text.Trim() } else { [string]$script:settings.DefaultPackagePath }
    foreach ($packageId in @($script:settings.WingetFavorites | Sort-Object)) {
      if ([string]::IsNullOrWhiteSpace([string]$packageId)) { continue }
      $local = Get-LocalFavoritePackageVersion -PackageId $packageId -RootPackageFolder $root
      $row = New-Object System.Windows.Forms.ListViewItem([string]$packageId)
      $row.Tag = [string]$packageId
      [void]$row.SubItems.Add($(if ($local) { $local } else { Get-UiString 'FavoriteLocalMissing' }))
      [void]$row.SubItems.Add('-')
      [void]$row.SubItems.Add('')
      [void]$favoriteListView.Items.Add($row)
    }
  } finally {
    $favoriteListView.EndUpdate()
  }
}

function Invoke-LocalPackageSetUpdate {
  param(
    [Parameter(Mandatory)][string[]]$PackageIds,
    [switch]$Automatic,
    [ValidateSet('Favorites','AllLocal')][string]$Mode = 'Favorites'
  )

  $packages = @($PackageIds | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)
  if ($packages.Count -eq 0) { return }

  $root = try { [System.IO.Path]::GetFullPath($pathBox.Text.Trim()) } catch { $null }
  if (-not $root -or -not (Test-PackageFolderUsable -Folder $root)) { return }
  if ($Mode -eq 'Favorites') { Update-FavoritePackageList }

  $downloaded = 0; $current = 0; $failed = 0; $index = 0
  $favoriteRefreshButton.Enabled = $false
  $favoriteAddButton.Enabled = $false
  $favoriteRemoveButton.Enabled = $false
  $favoriteAllLocalButton.Enabled = $false
  Show-Progress -Total ([Math]::Max(1, $packages.Count))
  try {
    foreach ($packageId in $packages) {
      $index++
      $checkingKey = if ($Mode -eq 'AllLocal') { 'LocalPackageCheckingStatus' } else { 'FavoriteCheckingStatus' }
      Update-Status ((Get-UiString $checkingKey) -f $index, $packages.Count, $packageId)
      [System.Windows.Forms.Application]::DoEvents()
      $row = Get-FavoriteListRow -PackageId $packageId
      $local = Get-LocalFavoritePackageVersion -PackageId $packageId -RootPackageFolder $root
      if ($row) { $row.SubItems[1].Text = if ($local) { $local } else { Get-UiString 'FavoriteLocalMissing' } }

      $latestInfo = Get-FreshLatestPackageVersion -PackageId $packageId
      $latest = [string]$latestInfo.Latest
      if ([string]::IsNullOrWhiteSpace($latest)) {
        $failed++
        if ($row) { $row.SubItems[2].Text = '-'; $row.SubItems[3].Text = Get-UiString 'FavoriteLookupFailed' }
        Write-Log "Favorite update: no current online version for $packageId."
        Set-ProgressValue $index
        continue
      }
      if ($row) { $row.SubItems[2].Text = $latest }

      if ($local -and -not (Test-IsNewerVersion -Latest $latest -Current $local)) {
        $current++
        if ($row) { $row.SubItems[3].Text = Get-UiString 'FavoriteUpToDate' }
        Set-ProgressValue $index
        continue
      }

      if ($row) { $row.SubItems[3].Text = (Get-UiString 'FavoriteDownloading') -f $latest }
      [System.Windows.Forms.Application]::DoEvents()
      # Automatisch heisst: niemand sieht zu, und der Lauf haelt die Busy-Sperre. Eine 429-Sperre
      # wird deshalb genau einmal abgewartet (5 s) statt dreimal (50 s) - sonst wartet die Anmeldung
      # mit. Von Hand angestossen bleibt es bei drei Versuchen.
      $build = New-WingetPackageWithFallback -PackageId $packageId -PackageFolder $root `
        -DesiredVersion $latest -LatestVersion $latest -InstalledVersion $local `
        -ThrottleRetries $(if ($Automatic) { 1 } else { 3 }) `
        -AllowUserRetry:(-not $Automatic) -ErrorAction SilentlyContinue
      if ($build -and $build.Succeeded) {
        $effective = if ($build.EffectiveVersion) { [string]$build.EffectiveVersion } else { $latest }
        $downloaded++
        if ($row) {
          $row.SubItems[1].Text = $effective
          $row.SubItems[3].Text = (Get-UiString 'FavoriteDownloaded') -f $effective
        }
        Write-Log "Favorite update: built/downloaded $packageId version $effective into $root."
      } else {
        $failed++
        if ($row) { $row.SubItems[3].Text = Get-UiString 'FavoriteDownloadFailed' }
        $detail = if ($build -and $build.ErrorMessage) { $build.ErrorMessage } else { 'unknown package build error' }
        Write-Log "Favorite update failed for ${packageId}: $detail"
      }
      Set-ProgressValue $index
    }
    $doneKey = if ($Mode -eq 'AllLocal') { 'LocalPackageBatchDoneStatus' } else { 'FavoriteBatchDoneStatus' }
    Update-Status ((Get-UiString $doneKey) -f $downloaded, $current, $failed)
  } finally {
    Hide-Progress
    $favoriteRefreshButton.Enabled = $true
    $favoriteAddButton.Enabled = $true
    $favoriteRemoveButton.Enabled = $true
    $favoriteAllLocalButton.Enabled = $true
  }
}

function Invoke-FavoritePackagesUpdate {
  param([switch]$Automatic)
  if (Test-UiBusy) { return }
  $favorites = @($script:settings.WingetFavorites | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
  if ($favorites.Count -eq 0) { Update-Status (Get-UiString 'FavoriteNoneStatus'); return }
  Invoke-LocalPackageSetUpdate -PackageIds $favorites -Automatic:$Automatic -Mode Favorites
}

function Invoke-AllLocalPackagesUpdate {
  if (Test-UiBusy) { return }
  $root = try { [System.IO.Path]::GetFullPath($pathBox.Text.Trim()) } catch { $null }
  if (-not $root -or -not (Test-PackageFolderUsable -Folder $root)) { return }
  $localPackages = @(Get-LocalPackageIds -RootPackageFolder $root)
  if ($localPackages.Count -eq 0) {
    Update-Status ((Get-UiString 'LocalPackageNoneStatus') -f $root)
    return
  }
  $confirm = [System.Windows.Forms.MessageBox]::Show(
    ((Get-UiString 'LocalPackageConfirmDialog') -f $localPackages.Count, $root),
    (Get-UiString 'ConfirmTitle'),
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Question)
  if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }
  Write-Log ("Local package bulk update: checking {0} package folder(s) below {1}." -f $localPackages.Count, $root)
  Invoke-LocalPackageSetUpdate -PackageIds $localPackages -Mode AllLocal
}

$favoriteAddButton.Add_Click({
  if (Test-UiBusy) { return }
  if (-not $dropdown.SelectedItem) { Update-Status (Get-UiString 'SelectPackageFirstStatus'); return }
  $package = $script:packageMap[[string]$dropdown.SelectedItem]
  $packageId = if ($package) { [string]$package.PackageID } else { '' }
  if ([string]::IsNullOrWhiteSpace($packageId)) { Update-Status (Get-UiString 'InvalidSelectionStatus'); return }
  if (@($script:settings.WingetFavorites) -contains $packageId) {
    Update-Status ((Get-UiString 'FavoriteAlreadySavedStatus') -f $packageId)
    return
  }
  $script:settings.WingetFavorites = @($script:settings.WingetFavorites) + $packageId
  Save-Settings
  Update-FavoritePackageList
  Update-Status ((Get-UiString 'FavoriteAddedStatus') -f $packageId)
})

$favoriteRemoveButton.Add_Click({
  if (Test-UiBusy) { return }
  if ($favoriteListView.SelectedItems.Count -eq 0) { Update-Status (Get-UiString 'FavoriteNoSelectionStatus'); return }
  $removeIds = @($favoriteListView.SelectedItems | ForEach-Object { [string]$_.Tag })
  $script:settings.WingetFavorites = @($script:settings.WingetFavorites | Where-Object { $removeIds -notcontains [string]$_ })
  Save-Settings
  Update-FavoritePackageList
  Update-Status ((Get-UiString 'FavoriteRemovedStatus') -f $removeIds.Count)
})

$favoriteRefreshButton.Add_Click({ Invoke-FavoritePackagesUpdate })
$favoriteAllLocalButton.Add_Click({ Invoke-AllLocalPackagesUpdate })
$pathBox.Add_TextChanged({ if ($favoriteListView) { Update-FavoritePackageList } })
Update-FavoritePackageList

# Section: Updates
$tabUpdate = New-Object System.Windows.Forms.Panel
Add-Section -Key 'updates' -Panel $tabUpdate -Label (Get-UiString 'TabUpdates') -Group 'manage'

# Section title
$updateHeaderLabel = New-Object System.Windows.Forms.Label
$updateHeaderLabel.Text = Get-UiString 'UpdateHeaderLabel'
$updateHeaderLabel.Location = New-Object System.Drawing.Point(16,12)
$updateHeaderLabel.AutoSize = $true
$updateHeaderLabel.Font = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)
$tabUpdate.Controls.Add($updateHeaderLabel)
[void](Add-SectionInfoBadge -Parent $tabUpdate -AfterLabel $updateHeaderLabel -TextKey 'InfoUpdates')

# --- Card 1: Available updates ---
$cardUpdates = New-Card -X 16 -Y 48 -W 726 -H 258
$tabUpdate.Controls.Add($cardUpdates)

$updatesStepLabel = New-Object System.Windows.Forms.Label
$updatesStepLabel.Text = Get-UiString 'UpdatesCardAvailable'
$updatesStepLabel.Location = New-Object System.Drawing.Point(14,10)
$updatesStepLabel.AutoSize = $true
$updatesStepLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$cardUpdates.Controls.Add($updatesStepLabel)
[void](Add-SectionInfoBadge -Parent $cardUpdates -AfterLabel $updatesStepLabel -TextKey 'InfoCardAvailableUpdates')

$updateSearchButton = New-Object System.Windows.Forms.Button
$updateSearchButton.Text = Get-UiString 'UpdateSearchButton'
$updateSearchButton.Location = New-Object System.Drawing.Point(14,38)
$updateSearchButton.Width = 180
$updateSearchButton.Enabled = $false
$cardUpdates.Controls.Add($updateSearchButton)

$updateFilterLabel = New-Object System.Windows.Forms.Label
$updateFilterLabel.Text = Get-UiString 'UpdateFilterLabel'
$updateFilterLabel.Location = New-Object System.Drawing.Point(206,42)
$updateFilterLabel.AutoSize = $true
$cardUpdates.Controls.Add($updateFilterLabel)

$updateFilterBox = New-Object System.Windows.Forms.TextBox
$updateFilterBox.Width = 462
$updateFilterBox.PlaceholderText = Get-UiString 'UpdateFilterPlaceholder'
# Wrapped in a rounded input host so the placeholder/typed text has proper left padding (a bare
# TextBox put "Type to filter..." hard against the left border) and matches the other fields.
$updateFilterHost = New-RoundedInput -Inner $updateFilterBox -X 250 -Y 37 -W 462 -H 30
$cardUpdates.Controls.Add($updateFilterHost)

# Detail ListView (was a CheckedListBox): shows the version columns that matter for an update
# decision instead of just the app name. $script:updateApps stays the source of truth; the rows
# only mirror it, and each row keeps the app name in .Text so the existing lookups keep working.
$updateListBox = New-Object System.Windows.Forms.ListView
$updateListBox.Location = New-Object System.Drawing.Point(14,72)
$updateListBox.Width = 698
$updateListBox.Height = 142
$updateListBox.View = [System.Windows.Forms.View]::Details
$updateListBox.CheckBoxes = $true
$updateListBox.FullRowSelect = $true
$updateListBox.MultiSelect = $false
$updateListBox.HideSelection = $false
$updateListBox.HeaderStyle = [System.Windows.Forms.ColumnHeaderStyle]::Nonclickable
# Widths add up to just under the fixed list width (698) so no horizontal scrollbar appears.
# The state column holds only what the target IS; anything qualifying it goes into the separate
# note column, which previously truncated the state text into an unreadable "... | scope...".
[void]$updateListBox.Columns.Add((Get-UiString 'ColApp'), 235)
[void]$updateListBox.Columns.Add((Get-UiString 'ColCurrentVersion'), 100)
[void]$updateListBox.Columns.Add((Get-UiString 'ColLatestVersion'), 100)
[void]$updateListBox.Columns.Add((Get-UiString 'ColUpdateState'), 110)
[void]$updateListBox.Columns.Add((Get-UiString 'ColUpdateNote'), 145)
$cardUpdates.Controls.Add($updateListBox)

# Schutz direkt an der Zeile pflegen. Der Weg ueber die Einstellungen gibt es auch, aber gemerkt
# wird "das ist unser eigenes Paket" genau hier - beim Blick auf die Liste, nicht drei Klicks
# spaeter. Der Eintrag traegt den ANZEIGENAMEN der App, also ohne Platzhalter; breitere Muster
# ('Splashtop*') schreibt man in der Einstellungskarte.
$updateListMenu = New-Object System.Windows.Forms.ContextMenuStrip
$updateProtectItem = New-Object System.Windows.Forms.ToolStripMenuItem
$updateProtectItem.Text = Get-UiString 'UpdateCtxProtect'
$updateUnprotectItem = New-Object System.Windows.Forms.ToolStripMenuItem
$updateUnprotectItem.Text = Get-UiString 'UpdateCtxUnprotect'
# Der einzige Weg, einer App eine Paket-Id zu geben, ohne die settings.json von Hand zu oeffnen.
# Genau hier wird er gebraucht: an der gesperrten Zeile, die sagt "keine WinGet-Id zuordenbar".
$updateAssignIdItem = New-Object System.Windows.Forms.ToolStripMenuItem
$updateAssignIdItem.Text = Get-UiString 'UpdateCtxAssignId'
[void]$updateListMenu.Items.Add($updateProtectItem)
[void]$updateListMenu.Items.Add($updateUnprotectItem)
[void]$updateListMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$updateListMenu.Items.Add($updateAssignIdItem)
$updateListBox.ContextMenuStrip = $updateListMenu

# Nur der Eintrag, der auf die angeklickte Zeile passt, ist waehlbar - ein Menue, in dem beide
# Eintraege immer anklickbar sind, laesst offen, welchen Zustand die Zeile gerade hat.
$updateListMenu.Add_Opening({
  $sel = @($updateListBox.SelectedItems)
  if ($sel.Count -eq 0 -or -not $sel[0].Tag) {
    $updateProtectItem.Enabled = $false
    $updateUnprotectItem.Enabled = $false
    $updateAssignIdItem.Enabled = $false
    return
  }
  $isProtected = [bool]$sel[0].Tag.IsProtected
  $updateProtectItem.Enabled = -not $isProtected
  $updateUnprotectItem.Enabled = $isProtected
  # Bewusst fuer JEDE Zeile waehlbar, nicht nur fuer die gesperrten: eine ueber den Namen zugeordnete
  # Id kann auch falsch sein, und dann muss man sie hier gerade ruecken koennen.
  $updateAssignIdItem.Enabled = $true
})

# Beide Eintraege schreiben SOFORT und speichern - anders als die Haken auf der Einstellungsseite,
# die erst "Einstellungen speichern" braucht. Ein Schutz, der erst nach einem weiteren Klick an
# anderer Stelle gilt, ist genau dann keiner, wenn man ihn braucht.
$updateProtectItem.Add_Click({
  $sel = @($updateListBox.SelectedItems)
  if ($sel.Count -eq 0 -or -not $sel[0].Tag) { return }
  $name = [string]$sel[0].Tag.Name
  $script:settings.ProtectedApps = @(Add-ProtectedAppPattern -Patterns $script:settings.ProtectedApps -Pattern $name)
  Save-Settings
  Write-Log ("Protected apps: added '{0}' (now {1} entr(y/ies)). This app will still be listed and can still be ticked, but an update run asks first - even with confirmations switched off." -f $name, @($script:settings.ProtectedApps).Count)
  Update-UpdateListRows
  try { Update-ProtectedAppsList } catch { Write-LogDebug 'protected apps settings list' }
  Update-Status ((Get-UiString 'ProtectedAddedStatus') -f $name)
})

$updateUnprotectItem.Add_Click({
  $sel = @($updateListBox.SelectedItems)
  if ($sel.Count -eq 0 -or -not $sel[0].Tag) { return }
  $name = [string]$sel[0].Tag.Name
  $script:settings.ProtectedApps = @(Remove-ProtectedAppPattern -Patterns $script:settings.ProtectedApps -Pattern $name)
  Save-Settings
  Write-Log ("Protected apps: removed '{0}' (now {1} entr(y/ies))." -f $name, @($script:settings.ProtectedApps).Count)
  # Ein Muster mit Platzhalter kann DIESE App weiterhin schuetzen - der exakte Eintrag ist weg, der
  # Schutz womoeglich nicht. Update-UpdateListRows rechnet das neu, statt es zu behaupten.
  Update-UpdateListRows
  try { Update-ProtectedAppsList } catch { Write-LogDebug 'protected apps settings list' }
  Update-Status ((Get-UiString 'ProtectedRemovedStatus') -f $name)
})

# Die Paket-Id von Hand setzen - fuer Apps, deren Anzeigename keinen sicheren Treffer hergibt
# (Keeper Password Manager, Harmony SASE, TeamViewer und alles andere mit Zusatz im Namen). Der
# Eintrag landet in WingetOverrides und wird von Resolve-WingetIdForApp VOR jeder Suche gelesen,
# ist also ab dem naechsten Vergleich massgeblich - deshalb laeuft die Suche gleich noch einmal.
$updateAssignIdItem.Add_Click({
  $sel = @($updateListBox.SelectedItems)
  if ($sel.Count -eq 0 -or -not $sel[0].Tag) { return }
  if (Test-UiBusy) { return }
  $model = $sel[0].Tag
  $name = ([string]$model.Name).Trim()
  if (-not $name) { return }
  $current = [string]$model.PackageId
  $entered = Show-TextInputDialog -Title (Get-UiString 'AssignIdTitle') -Prompt ((Get-UiString 'AssignIdPrompt') -f $name) -Value $current
  # $null heisst abgebrochen, '' heisst "Zuordnung entfernen" - der Unterschied zaehlt hier.
  if ($null -eq $entered) { return }
  $value = ([string]$entered).Trim()
  if ($value -and -not (Test-IsPlausiblePackageId -Value $value)) {
    [void][System.Windows.Forms.MessageBox]::Show(((Get-UiString 'AssignIdInvalidDialog') -f $value), (Get-UiString 'AssignIdInvalidTitle'),
      [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
    Write-Log ("WinGet id mapping rejected for '{0}': '{1}' is not shaped like a package id; nothing was saved." -f $name, $value)
    return
  }
  if (-not $script:settings.WingetOverrides) { $script:settings.WingetOverrides = @{} }
  # Ueber eine KOPIE der Schluessel, sonst bricht das Entfernen die Aufzaehlung ab. Entfernt wird
  # ohne Ruecksicht auf Gross-/Kleinschreibung, weil Resolve-WingetIdForApp genauso vergleicht -
  # sonst blieben zwei Eintraege stehen und der aeltere haette gewonnen.
  foreach ($key in @($script:settings.WingetOverrides.Keys)) {
    if ([string]::Equals(([string]$key).Trim(), $name, [System.StringComparison]::OrdinalIgnoreCase)) {
      $script:settings.WingetOverrides.Remove($key)
    }
  }
  if ($value) { $script:settings.WingetOverrides[$name] = $value }
  Save-Settings
  if ($value) {
    Write-Log ("WinGet id mapping saved: '{0}' -> {1} (now {2} mapping(s)). The scan uses it before any name matching." -f $name, $value, @($script:settings.WingetOverrides.Keys).Count)
    Update-Status ((Get-UiString 'AssignIdSavedStatus') -f $name, $value)
  } else {
    Write-Log ("WinGet id mapping removed for '{0}' (now {1} mapping(s))." -f $name, @($script:settings.WingetOverrides.Keys).Count)
    Update-Status ((Get-UiString 'AssignIdRemovedStatus') -f $name)
  }
  # Neu suchen statt die Zeile umzuschreiben: die Id entscheidet ueber die Zielversion, und die
  # steht erst nach einer Abfrage fest. Eine Zeile mit behaupteter Zielversion waere geraten.
  $updateSearchButton.PerformClick()
})

