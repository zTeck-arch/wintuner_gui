# ==================================================================================================
# Teil 86: Bereich "macOS (PKG)" - Beta
# ==================================================================================================
#
# Der Handbetrieb: eine .pkg vom Hersteller waehlen, Metadaten pruefen, App in Intune anlegen und
# zuweisen. KEIN Katalog, KEIN Update-Motor, KEINE Abloesung - die Gruende stehen unten.
#
# Warum als Beta gekennzeichnet: Der Weg ist unter Windows vollstaendig pruefbar (Teil 42 und 43,
# 42 Tests), das ERGEBNIS nicht. Ob die App auf einem Mac installiert, sieht man erst auf dem
# Geraet. Das verstoesst gegen die Leitregel dieses Projekts - behaupten ist verboten, messen ist
# Pflicht - an einer Stelle, die wir nicht schliessen koennen, solange kein Mac in der Pruefkette
# steht. Die Warnkarte sagt das dem Techniker in seinen Worten.
#
# Warum keine Zuweisungseinstellungen wie bei Win32: New-AssignmentSettingsObject (45-Assignments)
# erzeugt hart ein '#microsoft.graph.win32LobAppAssignmentSettings'. Das an eine macOS-App zu
# schicken waere entweder ein Graph-Fehler oder - schlimmer - stillschweigend ignoriert. Hier wird
# deshalb nur Ziel und Absicht gesetzt, ohne Einstellungsobjekt.
#
# Warum kein Update-Weg: Supersedence gibt es fuer macOSPkgApp nicht. Ein Update hiesse "neue App
# anlegen, Zuweisungen kopieren, alte loeschen" - ein anderer Ablauf als der von Update-SingleApp,
# keine Variante davon. Das ist eine eigene Stufe und bewusst nicht in dieser.

# Zustandsbeutel im Skript-Bereich. Die Ereignishandler unten laufen, nachdem der Aufbau dieses
# Teils zurueckgekehrt ist - lokale Variablen waeren dann weg, und .GetNewClosure() ist in diesem
# Projekt aus guten Gruenden verboten (siehe PATTERNS).
$script:macPkgUi = @{
  Metadata     = $null
  PkgFile      = ''
  # Die Katalogeintraege der letzten Abfrage, damit die Suche oertlich filtert statt 18 MB neu zu holen.
  Entries      = @()
  # Gesetzt, wenn die Datei aus dem Katalog kam. Nur dann gibt es eine Marke und damit einen
  # Update-Weg; eine von Hand gewaehlte Datei bleibt eine reine Neuanlage.
  CatalogEntry = $null
}

# --- Graph: App anlegen, Inhalt setzen, zuweisen -------------------------------------------------

# Legt das App-Objekt an und gibt seine Id zurueck. Ohne Inhalt ist sie noch eine leere Huelle -
# Publish-MobileAppContentVersion (Teil 42) fuellt sie, danach wird committedContentVersion gesetzt.
#
# ACHTUNG: Der POST auf /mobileApps ist NICHT idempotent. Ein Wiederholungsversuch nach einem
# Zeitablauf legte eine zweite App an, und die erste blieb als leere Huelle im Tenant stehen.
# Deshalb -MaxRetries 0, wie an allen anlegenden Stellen dieser Anwendung.
function New-MacOsPkgApp {
  param(
    [Parameter(Mandatory)][string]$DisplayName,
    [Parameter(Mandatory)][string]$Publisher,
    [Parameter(Mandatory)][string]$FileName,
    [Parameter(Mandatory)][string]$BundleId,
    [Parameter(Mandatory)][string]$BundleVersion,
    [object[]]$IncludedApps = @(),
    [string]$MinimumOsProperty = 'v11_0',
    [bool]$IgnoreVersionDetection = $false,
    # Die Marke aus Teil 44. Sie ist das einzige, woran ein spaeterer Lauf erkennt, WAS hier
    # bereitgestellt wurde - ohne sie legt jede Aktualisierung eine zweite App daneben.
    [string]$Notes = '',
    [Parameter(Mandatory)][hashtable]$Headers
  )
  $minimumOs = @{ '@odata.type' = 'microsoft.graph.macOSMinimumOperatingSystem' }
  $minimumOs[$MinimumOsProperty] = $true

  # includedApps ist die Erkennungsregel. Ohne sie erkennt Intune die App auf dem Geraet nie und
  # installiert sie bei jeder Pruefung neu - deshalb steht im schlimmsten Fall die Haupt-App drin.
  $included = if ($IncludedApps.Count -gt 0) {
    @($IncludedApps | ForEach-Object {
      @{
        '@odata.type'  = 'microsoft.graph.macOSIncludedApp'
        bundleId       = [string]$_.BundleId
        bundleVersion  = [string]$_.BundleVersion
      }
    })
  } else {
    @(@{ '@odata.type' = 'microsoft.graph.macOSIncludedApp'; bundleId = $BundleId; bundleVersion = $BundleVersion })
  }

  $body = @{
    '@odata.type'                     = '#microsoft.graph.macOSPkgApp'
    displayName                       = $DisplayName
    publisher                         = $Publisher
    fileName                          = $FileName
    primaryBundleId                   = $BundleId
    primaryBundleVersion              = $BundleVersion
    includedApps                      = $included
    minimumSupportedOperatingSystem   = $minimumOs
    ignoreVersionDetection            = $IgnoreVersionDetection
    notes                             = $Notes
  } | ConvertTo-Json -Depth 6

  $created = Invoke-GraphRest -Uri 'https://graph.microsoft.com/beta/deviceAppManagement/mobileApps' `
    -Method POST -Headers $Headers -Body $body -Context ("create macOS pkg app '{0}'" -f $DisplayName) -MaxRetries 0
  $appId = [string]$created.id
  if ([string]::IsNullOrWhiteSpace($appId)) { throw 'Intune did not return an id for the new macOS app.' }
  Write-Log ("Created macOS pkg app '{0}' ({1}), bundle {2} {3}." -f $DisplayName, $appId, $BundleId, $BundleVersion)
  return $appId
}

# Setzt EINE Zuweisung. Bewusst ohne Einstellungsobjekt - siehe Kopf dieses Teils.
function Set-MacOsPkgAppAssignment {
  param(
    [Parameter(Mandatory)][string]$AppId,
    [Parameter(Mandatory)][string]$TargetValue,
    [ValidateSet('available', 'required', 'uninstall')][string]$Intent = 'available',
    [Parameter(Mandatory)][hashtable]$Headers
  )
  $target = switch ($TargetValue) {
    'AllUsers'   { @{ '@odata.type' = '#microsoft.graph.allLicensedUsersAssignmentTarget' } }
    'AllDevices' { @{ '@odata.type' = '#microsoft.graph.allDevicesAssignmentTarget' } }
    default {
      if (-not (Test-GuidString $TargetValue)) { throw ("Not a valid group id: {0}" -f $TargetValue) }
      @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = $TargetValue }
    }
  }
  $body = @{ mobileAppAssignments = @(@{
    '@odata.type' = '#microsoft.graph.mobileAppAssignment'
    intent        = $Intent
    target        = $target
  }) } | ConvertTo-Json -Depth 6
  [void](Invoke-GraphRest -Uri ("https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/{0}/assign" -f $AppId) `
    -Method POST -Headers $Headers -Body $body -Context ("assign macOS app {0}" -f $AppId) -MaxRetries 0)
  Write-Log ("Assigned macOS app {0}: {1}, intent {2}." -f $AppId, $TargetValue, $Intent)
}

# Der Update-Weg: eine NEUE Inhaltsversion in eine BESTEHENDE App.
#
# Ablösung (Supersedence) gibt es fuer macOSPkgApp nicht. Fuer macOS ist das aber kein Notbehelf,
# sondern der uebliche Weg: dieselbe App-ID, dieselben Zuweisungen, dieselbe Installationsstatistik,
# neuer Inhalt - und jedes zugewiesene Geraet bekommt die neue Fassung. Es entsteht keine zweite
# App, also bleibt auch nichts aufzuraeumen.
#
# Erkennungsregeln werden MITGESETZT, anders als beim Win32-Gegenstueck: bei macOS IST die Version
# die Erkennung (primaryBundleVersion und includedApps). Sie stehen zu lassen hiesse, dass Intune
# nach der alten Version sucht und die neue nie als installiert erkennt.
function Update-MacOsPkgAppContent {
  param(
    [Parameter(Mandatory)][string]$AppId,
    [Parameter(Mandatory)][string]$PkgFile,
    [Parameter(Mandatory)][string]$BundleId,
    [Parameter(Mandatory)][string]$BundleVersion,
    [object[]]$IncludedApps = @(),
    [string]$Notes = '',
    [Parameter(Mandatory)][hashtable]$Headers
  )
  $versionId = Publish-MobileAppContentVersion -AppId $AppId `
    -OdataType 'microsoft.graph.macOSPkgApp' -SourceFile $PkgFile -Headers $Headers

  $included = if ($IncludedApps.Count -gt 0) {
    @($IncludedApps | ForEach-Object {
      @{ '@odata.type' = 'microsoft.graph.macOSIncludedApp'; bundleId = [string]$_.BundleId; bundleVersion = [string]$_.BundleVersion }
    })
  } else {
    @(@{ '@odata.type' = 'microsoft.graph.macOSIncludedApp'; bundleId = $BundleId; bundleVersion = $BundleVersion })
  }
  $patch = @{
    '@odata.type'           = '#microsoft.graph.macOSPkgApp'
    committedContentVersion = $versionId
    primaryBundleId         = $BundleId
    primaryBundleVersion    = $BundleVersion
    includedApps            = $included
    fileName                = [IO.Path]::GetFileName($PkgFile)
  }
  if ($Notes) { $patch.notes = $Notes }
  [void](Invoke-GraphRest -Uri ("https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/{0}" -f $AppId) `
    -Method PATCH -Headers $Headers -Body ($patch | ConvertTo-Json -Depth 6) `
    -Context ("replace content of macOS app {0}" -f $AppId) -MaxRetries 0)
  Write-Log ("Replaced content of macOS app {0} with version {1} ({2})." -f $AppId, $versionId, $BundleVersion)
  return $versionId
}

# Der ganze Weg. Gibt einen Bericht zurueck statt zu werfen, damit der Handler eine Statuszeile
# schreiben kann - und nennt die AppId auch im Fehlerfall: eine angelegte App, die keinen Inhalt
# bekommen hat, muss der Techniker im Portal finden und wegraeumen koennen.
function Invoke-MacOsPkgDeploy {
  param(
    [Parameter(Mandatory)][string]$PkgFile,
    [Parameter(Mandatory)][string]$DisplayName,
    [Parameter(Mandatory)][string]$Publisher,
    [Parameter(Mandatory)][string]$BundleId,
    [Parameter(Mandatory)][string]$BundleVersion,
    [object[]]$IncludedApps = @(),
    [string]$MinimumOsProperty = 'v11_0',
    [bool]$IgnoreVersionDetection = $false,
    [string]$TargetValue = '',
    [ValidateSet('available', 'required', 'uninstall')][string]$Intent = 'available',
    # Gesetzt: den Inhalt DIESER App ersetzen, statt eine neue anzulegen. Der Aufrufer hat sie
    # ueber die Marke gefunden (Find-DeployedMacOsApp in Teil 44).
    [string]$ExistingAppId = '',
    [string]$Notes = ''
  )
  $out = @{ Success = $false; AppId = ''; ErrorMessage = ''; Assigned = $false; Replaced = $false }
  try {
    $token = Get-WtToken -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace([string]$token)) { throw 'WinTuner returned an empty access token.' }
    $headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }

    if ($ExistingAppId) {
      $out.AppId = $ExistingAppId
      $out.Replaced = $true
      [void](Update-MacOsPkgAppContent -AppId $ExistingAppId -PkgFile $PkgFile -BundleId $BundleId `
        -BundleVersion $BundleVersion -IncludedApps $IncludedApps -Notes $Notes -Headers $headers)
      # Zuweisungen bleiben, wie sie sind. Sie hier zu ueberschreiben waere der Unterschied
      # zwischen "aktualisiert" und "jemandem die Verteilung umgestellt".
      $out.Success = $true
      return $out
    }

    $out.AppId = New-MacOsPkgApp -DisplayName $DisplayName -Publisher $Publisher `
      -FileName ([IO.Path]::GetFileName($PkgFile)) -BundleId $BundleId -BundleVersion $BundleVersion `
      -IncludedApps $IncludedApps -MinimumOsProperty $MinimumOsProperty `
      -IgnoreVersionDetection $IgnoreVersionDetection -Notes $Notes -Headers $headers

    $versionId = Publish-MobileAppContentVersion -AppId $out.AppId `
      -OdataType 'microsoft.graph.macOSPkgApp' -SourceFile $PkgFile -Headers $headers

    # Erst das macht die hochgeladene Fassung zur aktiven. Ohne diesen Schritt steht die App mit
    # Inhalt im Tenant und verteilt trotzdem nichts.
    $patch = @{ '@odata.type' = '#microsoft.graph.macOSPkgApp'; committedContentVersion = $versionId } | ConvertTo-Json -Depth 4
    [void](Invoke-GraphRest -Uri ("https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/{0}" -f $out.AppId) `
      -Method PATCH -Headers $headers -Body $patch -Context ("commit content version for app {0}" -f $out.AppId) -MaxRetries 0)

    if ($TargetValue) {
      Set-MacOsPkgAppAssignment -AppId $out.AppId -TargetValue $TargetValue -Intent $Intent -Headers $headers
      $out.Assigned = $true
    }
    $out.Success = $true
    return $out
  } catch {
    $out.ErrorMessage = $_.Exception.Message
    Write-Log ("macOS pkg deployment FAILED (app id '{0}'): {1}" -f $out.AppId, $out.ErrorMessage)
    return $out
  }
}

# --- Der Bereich ---------------------------------------------------------------------------------

$tabMacPkg = New-Object System.Windows.Forms.Panel
$tabMacPkg.AutoScroll = $true

$macPkgTitle = New-Object System.Windows.Forms.Label
$macPkgTitle.Text = Get-UiString 'TabMacOsPkg'
$macPkgTitle.Location = New-Object System.Drawing.Point(16, 14)
$macPkgTitle.AutoSize = $true
$macPkgTitle.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
$tabMacPkg.Controls.Add($macPkgTitle)
[void](Add-SectionInfoBadge -Parent $tabMacPkg -AfterLabel $macPkgTitle -TextKey 'InfoMacOsPkg')

# --- Karte 1: die Beta-Warnung -------------------------------------------------------------------
#
# Nicht wegklickbar und immer die erste Karte. Sie nennt drei Dinge, die der Techniker sonst erst
# auf dem Geraet des Kunden erfaehrt: dass dieser Weg nicht auf einem Mac gemessen ist, dass eine
# unsignierte .pkg von Gatekeeper geblockt wird, und dass Installationsskripte im Paket als root
# laufen.
#
# Keine eigenen Farben: die Layout-Probe prueft den Kontrast in ALLEN SIEBEN Designs, und ein
# handgewaehltes Warnorange faellt dort zuverlaessig in mindestens einem durch. Fett und die
# Ueberschrift tragen die Warnung genauso.
$cardMacBeta = New-Card -X 16 -Y 48 -W 726 -H 150
$tabMacPkg.Controls.Add($cardMacBeta)

$macBetaTitle = New-Object System.Windows.Forms.Label
$macBetaTitle.Text = Get-UiString 'MacPkgBetaTitle'
$macBetaTitle.Location = New-Object System.Drawing.Point(14, 10)
$macBetaTitle.AutoSize = $true
$macBetaTitle.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$cardMacBeta.Controls.Add($macBetaTitle)

$macBetaText = New-Object System.Windows.Forms.Label
$macBetaText.Text = Get-UiString 'MacPkgBetaText'
$macBetaText.Location = New-Object System.Drawing.Point(14, 36)
$macBetaText.AutoSize = $true
$cardMacBeta.Controls.Add($macBetaText)

# --- Karte 2: der Katalog ------------------------------------------------------------------------
#
# Das Gegenstueck zur WinGet-Suche, gespeist aus Homebrew plus eigener Ueberschreibliste (Teil 44).
# Er fuettert DIESELBE Strecke wie die Dateiauswahl darunter: herunterladen, Metadaten lesen,
# Felder fuellen. Kein zweiter Bereitstellungsweg, nur eine zweite Art, an die Datei zu kommen -
# was heisst, dass der Katalog keine eigenen Fehlerquellen im Upload anschleppen kann.
$cardMacCatalog = New-Card -X 16 -Y 210 -W 726 -H 320
$tabMacPkg.Controls.Add($cardMacCatalog)

$macCatalogTitle = New-Object System.Windows.Forms.Label
$macCatalogTitle.Text = Get-UiString 'MacPkgCatalogSectionTitle'
$macCatalogTitle.Location = New-Object System.Drawing.Point(14, 10)
$macCatalogTitle.AutoSize = $true
$macCatalogTitle.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$cardMacCatalog.Controls.Add($macCatalogTitle)

$macSearchLabel = New-Object System.Windows.Forms.Label
$macSearchLabel.Text = Get-UiString 'MacPkgCatalogSearchLabel'
$macSearchLabel.AutoSize = $true
$cardMacCatalog.Controls.Add($macSearchLabel)

$macSearchBox = New-Object System.Windows.Forms.TextBox
$macSearchBox.Width = 300
$macSearchHost = New-RoundedInput -Inner $macSearchBox -X 120 -Y 44 -W 314 -H 32
$cardMacCatalog.Controls.Add($macSearchHost)

$macSearchButton = New-Object System.Windows.Forms.Button
$macSearchButton.Tag = 'btn-secondary'
$macSearchButton.Text = Get-UiString 'MacPkgCatalogSearchButton'
$macSearchButton.Size = New-Object System.Drawing.Size(120, 32)
$cardMacCatalog.Controls.Add($macSearchButton)

$macCatalogRefreshButton = New-Object System.Windows.Forms.Button
$macCatalogRefreshButton.Tag = 'btn-secondary'
$macCatalogRefreshButton.Text = Get-UiString 'MacPkgCatalogRefreshButton'
$macCatalogRefreshButton.Size = New-Object System.Drawing.Size(150, 32)
$cardMacCatalog.Controls.Add($macCatalogRefreshButton)

$macCatalogList = New-Object System.Windows.Forms.ListView
$macCatalogList.Location = New-Object System.Drawing.Point(14, 88)
$macCatalogList.Size = New-Object System.Drawing.Size(698, 150)
$macCatalogList.View = [System.Windows.Forms.View]::Details
$macCatalogList.FullRowSelect = $true
$macCatalogList.MultiSelect = $false
$macCatalogList.HideSelection = $false
$macCatalogList.HeaderStyle = [System.Windows.Forms.ColumnHeaderStyle]::Nonclickable
[void]$macCatalogList.Columns.Add((Get-UiString 'MacPkgColName'), 250)
[void]$macCatalogList.Columns.Add((Get-UiString 'MacPkgColVersion'), 160)
[void]$macCatalogList.Columns.Add((Get-UiString 'MacPkgColSource'), 130)
[void]$macCatalogList.Columns.Add((Get-UiString 'MacPkgColHash'), 130)
$cardMacCatalog.Controls.Add($macCatalogList)

$macCatalogUseButton = New-Object System.Windows.Forms.Button
$macCatalogUseButton.Text = Get-UiString 'MacPkgCatalogUseButton'
$macCatalogUseButton.Size = New-Object System.Drawing.Size(280, 32)
$macCatalogUseButton.Enabled = $false
$cardMacCatalog.Controls.Add($macCatalogUseButton)

# Steht nur, wenn der gewaehlte Eintrag KEINEN Hash mitbringt. Eine Warnung, die immer da ist,
# liest niemand - und 334 der 378 PKG-Casks bringen einen mit.
$macNoHashWarning = New-Object System.Windows.Forms.Label
$macNoHashWarning.Text = Get-UiString 'MacPkgNoHashWarning'
$macNoHashWarning.AutoSize = $true
$macNoHashWarning.Visible = $false
$cardMacCatalog.Controls.Add($macNoHashWarning)

# --- Karte 3: die Datei --------------------------------------------------------------------------
$cardMacFile = New-Card -X 16 -Y 210 -W 726 -H 110
$tabMacPkg.Controls.Add($cardMacFile)

$macFileTitle = New-Object System.Windows.Forms.Label
$macFileTitle.Text = Get-UiString 'MacPkgFileSectionTitle'
$macFileTitle.Location = New-Object System.Drawing.Point(14, 10)
$macFileTitle.AutoSize = $true
$macFileTitle.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$cardMacFile.Controls.Add($macFileTitle)

$macFileLabel = New-Object System.Windows.Forms.Label
$macFileLabel.Text = Get-UiString 'MacPkgFileLabel'
$macFileLabel.AutoSize = $true
$cardMacFile.Controls.Add($macFileLabel)

$macFileBox = New-Object System.Windows.Forms.TextBox
$macFileBox.Width = 400
$macFileBox.Text = Get-UiString 'MacPkgFilePlaceholder'
$macFileHost = New-RoundedInput -Inner $macFileBox -X 120 -Y 44 -W 414 -H 32
$cardMacFile.Controls.Add($macFileHost)

$macFileButton = New-Object System.Windows.Forms.Button
$macFileButton.Tag = 'btn-secondary'
$macFileButton.Text = Get-UiString 'SelectButton'
$macFileButton.Size = New-Object System.Drawing.Size(152, 32)
$cardMacFile.Controls.Add($macFileButton)

# --- Karte 3: die Metadaten ----------------------------------------------------------------------
$cardMacMeta = New-Card -X 16 -Y 332 -W 726 -H 300
$tabMacPkg.Controls.Add($cardMacMeta)

$macMetaTitle = New-Object System.Windows.Forms.Label
$macMetaTitle.Text = Get-UiString 'MacPkgMetaSectionTitle'
$macMetaTitle.Location = New-Object System.Drawing.Point(14, 10)
$macMetaTitle.AutoSize = $true
$macMetaTitle.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$cardMacMeta.Controls.Add($macMetaTitle)

$macNameLabel = New-Object System.Windows.Forms.Label
$macNameLabel.Text = Get-UiString 'MacPkgNameLabel'
$macNameLabel.AutoSize = $true
$cardMacMeta.Controls.Add($macNameLabel)
$macNameBox = New-Object System.Windows.Forms.TextBox
$macNameBox.Width = 300
$macNameHost = New-RoundedInput -Inner $macNameBox -X 160 -Y 44 -W 314 -H 32
$cardMacMeta.Controls.Add($macNameHost)

$macPublisherLabel = New-Object System.Windows.Forms.Label
$macPublisherLabel.Text = Get-UiString 'MacPkgPublisherLabel'
$macPublisherLabel.AutoSize = $true
$cardMacMeta.Controls.Add($macPublisherLabel)
$macPublisherBox = New-Object System.Windows.Forms.TextBox
$macPublisherBox.Width = 300
$macPublisherHost = New-RoundedInput -Inner $macPublisherBox -X 160 -Y 84 -W 314 -H 32
$cardMacMeta.Controls.Add($macPublisherHost)

$macBundleLabel = New-Object System.Windows.Forms.Label
$macBundleLabel.Text = Get-UiString 'MacPkgBundleIdLabel'
$macBundleLabel.AutoSize = $true
$cardMacMeta.Controls.Add($macBundleLabel)
$macBundleBox = New-Object System.Windows.Forms.TextBox
$macBundleBox.Width = 300
$macBundleHost = New-RoundedInput -Inner $macBundleBox -X 160 -Y 124 -W 314 -H 32
$cardMacMeta.Controls.Add($macBundleHost)

# Die zwei Versionen des Pakets. Chrome fuehrt 153.0.8010.37 als CFBundleShortVersionString und
# 8010.37 als CFBundleVersion; welche Intune fuer die Erkennung vergleicht, ist ohne Mac und ohne
# Tenant nicht messbar. Deshalb die Wahl statt einer Annahme - und der Tooltip sagt, was passiert,
# wenn sie falsch ist: die App wird bei jeder Pruefung neu installiert.
$macVersionLabel = New-Object System.Windows.Forms.Label
$macVersionLabel.Text = Get-UiString 'MacPkgVersionLabel'
$macVersionLabel.AutoSize = $true
$cardMacMeta.Controls.Add($macVersionLabel)

$macVersionCombo = New-Object System.Windows.Forms.ComboBox
$macVersionCombo.Width = 220
$macVersionCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
[void]$macVersionCombo.Items.AddRange(@((Get-UiString 'MacPkgVersionShort'), (Get-UiString 'MacPkgVersionBuild')))
$macVersionCombo.SelectedIndex = 0
$cardMacMeta.Controls.Add($macVersionCombo)

$macVersionBox = New-Object System.Windows.Forms.TextBox
$macVersionBox.Width = 180
$macVersionHost = New-RoundedInput -Inner $macVersionBox -X 400 -Y 164 -W 194 -H 32
$cardMacMeta.Controls.Add($macVersionHost)

$macMinOsLabel = New-Object System.Windows.Forms.Label
$macMinOsLabel.Text = Get-UiString 'MacPkgMinOsLabel'
$macMinOsLabel.AutoSize = $true
$cardMacMeta.Controls.Add($macMinOsLabel)
$macMinOsValue = New-Object System.Windows.Forms.Label
$macMinOsValue.Text = '-'
$macMinOsValue.AutoSize = $true
$cardMacMeta.Controls.Add($macMinOsValue)

$macIncludedLabel = New-Object System.Windows.Forms.Label
$macIncludedLabel.Text = Get-UiString 'MacPkgIncludedLabel'
$macIncludedLabel.AutoSize = $true
$cardMacMeta.Controls.Add($macIncludedLabel)
$macIncludedValue = New-Object System.Windows.Forms.Label
$macIncludedValue.Text = '-'
$macIncludedValue.AutoSize = $true
$cardMacMeta.Controls.Add($macIncludedValue)

$macIgnoreDetectionCheck = New-Object System.Windows.Forms.CheckBox
$macIgnoreDetectionCheck.Text = Get-UiString 'MacPkgIgnoreDetection'
$macIgnoreDetectionCheck.AutoSize = $true
$cardMacMeta.Controls.Add($macIgnoreDetectionCheck)

# Nur sichtbar, wenn das Paket wirklich Skripte mitbringt. Eine Warnung, die immer steht, liest
# niemand mehr.
$macScriptsWarning = New-Object System.Windows.Forms.Label
$macScriptsWarning.Text = Get-UiString 'MacPkgScriptsWarning'
$macScriptsWarning.AutoSize = $true
$macScriptsWarning.Visible = $false
$cardMacMeta.Controls.Add($macScriptsWarning)

# --- Karte 4: Zuweisung und Anlegen --------------------------------------------------------------
$cardMacDeploy = New-Card -X 16 -Y 644 -W 726 -H 200
$tabMacPkg.Controls.Add($cardMacDeploy)

$macDeployTitle = New-Object System.Windows.Forms.Label
$macDeployTitle.Text = Get-UiString 'MacPkgDeploySectionTitle'
$macDeployTitle.Location = New-Object System.Drawing.Point(14, 10)
$macDeployTitle.AutoSize = $true
$macDeployTitle.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$cardMacDeploy.Controls.Add($macDeployTitle)

$macAssignLabel = New-Object System.Windows.Forms.Label
$macAssignLabel.Text = Get-UiString 'AssignLabel'
$macAssignLabel.AutoSize = $true
$cardMacDeploy.Controls.Add($macAssignLabel)

$macAssignCombo = New-Object System.Windows.Forms.ComboBox
$macAssignCombo.Width = 250
$macAssignCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
[void]$macAssignCombo.Items.AddRange(@((Get-UiString 'AssignNotAssigned'), (Get-UiString 'AssignAllUsers'), (Get-UiString 'AssignAllDevices'), (Get-UiString 'AssignCustomGroup')))
$macAssignCombo.SelectedIndex = 0
$cardMacDeploy.Controls.Add($macAssignCombo)

$macAssignGroupBox = New-Object System.Windows.Forms.TextBox
$macAssignGroupBox.Width = 194
$macAssignGroupHost = New-RoundedInput -Inner $macAssignGroupBox -X 380 -Y 44 -W 180 -H 32
$macAssignGroupHost.Visible = $false
$cardMacDeploy.Controls.Add($macAssignGroupHost)

$macAssignFavButton = New-Object System.Windows.Forms.Button
$macAssignFavButton.Tag = 'btn-secondary'
$macAssignFavButton.Text = Get-UiString 'FavAddButton'
$macAssignFavButton.Size = New-Object System.Drawing.Size(96, 32)
$macAssignFavButton.Add_Click({ Show-GroupFavoriteDialog -GroupIdBox $macAssignGroupBox })
$cardMacDeploy.Controls.Add($macAssignFavButton)

$macAssignCombo.Add_SelectedIndexChanged({
  $macAssignGroupHost.Visible = ($macAssignCombo.SelectedItem -eq (Get-UiString 'AssignCustomGroup'))
})
# Damit ein neu gespeicherter Gruppen-Favorit auch in DIESER Liste auftaucht, ohne Neustart.
Register-AssignTargetCombo -TargetCombo $macAssignCombo

$macIntentLabel = New-Object System.Windows.Forms.Label
$macIntentLabel.Text = Get-UiString 'AssignIntentLabel'
$macIntentLabel.AutoSize = $true
$cardMacDeploy.Controls.Add($macIntentLabel)

$macIntentCombo = New-Object System.Windows.Forms.ComboBox
$macIntentCombo.Width = 250
$macIntentCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
[void]$macIntentCombo.Items.AddRange(@((Get-UiString 'IntentAvailable'), (Get-UiString 'IntentRequired'), (Get-UiString 'IntentUninstall')))
$macIntentCombo.SelectedIndex = 0
$cardMacDeploy.Controls.Add($macIntentCombo)

$macCreateButton = New-Object System.Windows.Forms.Button
$macCreateButton.Text = Get-UiString 'MacPkgCreateButton'
$macCreateButton.Size = New-Object System.Drawing.Size(220, 32)
$macCreateButton.Enabled = $false
$cardMacDeploy.Controls.Add($macCreateButton)

# --- Layout --------------------------------------------------------------------------------------
#
# Gemessen, nicht aus Pixelkonstanten: die deutschen Beschriftungen sind teils deutlich laenger als
# die englischen, und die Layout-Probe laeuft in BEIDEN Sprachen. Set-AppSettingsRowBlock richtet
# die Bedienelemente an einer gemeinsamen, gemessenen Beschriftungsspalte aus.
function Update-MacOsPkgLayout {
  if (-not $cardMacBeta) { return }
  $inner = [Math]::Max(320, $cardMacFile.Width - 28)

  # Die Warnung umbricht auf die Kartenbreite. MaximumSize statt fester Hoehe, damit sie in jeder
  # Sprache und jeder Schriftgroesse vollstaendig sichtbar bleibt.
  $macBetaText.MaximumSize = New-Object System.Drawing.Size($inner, 0)
  $macBetaText.Left = 14
  $macBetaText.Top = $macBetaTitle.Bottom + 8

  # Zwei Elemente in einer Zeile gehoeren in ZWEI ZELLEN, nicht neben eine Zelle gerechnet:
  # Set-AppSettingsRowBlock streckt ein Bedienelement ohne eigene Breite auf die ganze Restbreite
  # der Zeile. Ein daneben gesetzter Nachbar lag deshalb DARUNTER - von der Layout-Probe in allen
  # sieben Designs, zwei Fenstergroessen und beiden Sprachen gefunden (8 Befunde). Mit W je Zelle
  # verteilt der Helfer selbst und der Nachbar steht dort, wo er hingehoert.
  Set-AppSettingsRowBlock -X 14 -Y ($macCatalogTitle.Bottom + 10) -Width $inner -Rows @(
    @{ Cells = @(
        @{ L = $macSearchLabel; C = $macSearchHost; W = 314 }
        @{ C = $macSearchButton; W = 120 }
        @{ C = $macCatalogRefreshButton; W = 150 }
      ) }
  )
  # Die Liste bekommt die volle Kartenbreite und waechst mit ihr; die Spalten bleiben fest, damit
  # eine lange Cask-Bezeichnung die Version nicht aus dem Sichtbaren schiebt.
  $macCatalogList.Left = 14
  $macCatalogList.Top = $macSearchHost.Bottom + 12
  $macCatalogList.Width = $inner
  $macCatalogUseButton.Left = 14
  $macCatalogUseButton.Top = $macCatalogList.Bottom + 12
  $macNoHashWarning.MaximumSize = New-Object System.Drawing.Size($inner, 0)
  $macNoHashWarning.Left = 14
  $macNoHashWarning.Top = $macCatalogUseButton.Bottom + 10

  Set-AppSettingsRowBlock -X 14 -Y ($macFileTitle.Bottom + 10) -Width $inner -Rows @(
    @{ Cells = @(@{ L = $macFileLabel; C = $macFileHost; W = 414 }, @{ C = $macFileButton; W = 152 }) }
  )

  Set-AppSettingsRowBlock -X 14 -Y ($macMetaTitle.Bottom + 10) -Width $inner -Rows @(
    @{ Cells = @(@{ L = $macNameLabel;      C = $macNameHost;      W = 314 }) }
    @{ Cells = @(@{ L = $macPublisherLabel; C = $macPublisherHost; W = 314 }) }
    @{ Cells = @(@{ L = $macBundleLabel;    C = $macBundleHost;    W = 314 }) }
    @{ Cells = @(@{ L = $macVersionLabel;   C = $macVersionCombo;  W = 220 }, @{ C = $macVersionHost; W = 194 }) }
    @{ Cells = @(@{ L = $macMinOsLabel;     C = $macMinOsValue }) }
    @{ Cells = @(@{ L = $macIncludedLabel;  C = $macIncludedValue }) }
  )

  $macIgnoreDetectionCheck.Left = 14
  $macIgnoreDetectionCheck.Top = $macIncludedValue.Bottom + 12
  $macScriptsWarning.MaximumSize = New-Object System.Drawing.Size($inner, 0)
  $macScriptsWarning.Left = 14
  $macScriptsWarning.Top = $macIgnoreDetectionCheck.Bottom + 10

  Set-AppSettingsRowBlock -X 14 -Y ($macDeployTitle.Bottom + 10) -Width $inner -Rows @(
    @{ Cells = @(
        @{ L = $macAssignLabel; C = $macAssignCombo;     W = 250 }
        @{ C = $macAssignGroupHost; W = 180 }
        @{ C = $macAssignFavButton; W = 96 }
      ) }
    @{ Cells = @(@{ L = $macIntentLabel; C = $macIntentCombo; W = 250 }) }
  )
  $macCreateButton.Left = 14
  $macCreateButton.Top = $macIntentCombo.Bottom + 14

  # Eine ausgeblendete Warnung darf ihre Karte nicht so hoch machen, als waere sie da.
  $exclude = [Collections.Generic.List[object]]::new()
  if (-not $macScriptsWarning.Visible) { $exclude.Add($macScriptsWarning) }
  if (-not $macNoHashWarning.Visible) { $exclude.Add($macNoHashWarning) }
  Update-StackedCards -Panel $tabMacPkg -Exclude $exclude.ToArray() `
    -Cards @($cardMacBeta, $cardMacCatalog, $cardMacFile, $cardMacMeta, $cardMacDeploy)
}

# --- Verdrahtung ---------------------------------------------------------------------------------

# Traegt die gelesenen Werte in die Metadatenkarte ein. Die Felder bleiben schreibbar: ein Paket,
# aus dem sich nichts lesen laesst, soll den Techniker nicht aufhalten.
function Set-MacPkgMetadataFields {
  param($Metadata)
  $script:macPkgUi.Metadata = $Metadata
  if (-not $Metadata -or -not $Metadata.Success) {
    $macMinOsValue.Text = '-'
    $macIncludedValue.Text = '-'
    $macScriptsWarning.Visible = $false
    return
  }
  if ([string]::IsNullOrWhiteSpace($macNameBox.Text) -and $Metadata.Title) { $macNameBox.Text = $Metadata.Title }
  $macBundleBox.Text = [string]$Metadata.PrimaryBundleId
  $macMinOsValue.Text = if ($Metadata.MinimumSystemVersion) {
    ("{0}  ({1})" -f $Metadata.MinimumSystemVersion, $Metadata.MinimumOsProperty)
  } else { '-' }
  $macIncludedValue.Text = [string]@($Metadata.IncludedApps).Count
  $macScriptsWarning.Visible = [bool]$Metadata.HasInstallScripts
  Update-MacPkgVersionField
}

# Setzt das Versionsfeld auf die gewaehlte der beiden Versionen des Pakets.
function Update-MacPkgVersionField {
  $meta = $script:macPkgUi.Metadata
  if (-not $meta -or -not $meta.Success) { return }
  # Ueber SelectedIndex, nicht ueber den Text: sonst haengt das Verhalten an der Sprache.
  $macVersionBox.Text = if ([int]$macVersionCombo.SelectedIndex -eq 1) {
    [string]$meta.BuildVersion
  } else {
    [string]$meta.ShortVersion
  }
}

$macVersionCombo.Add_SelectedIndexChanged({ Update-MacPkgVersionField })

# Fuellt die Trefferliste. Der Suchbegriff filtert oertlich ueber die Kopie auf der Platte - der
# Katalog wird NICHT bei jedem Tastendruck neu geholt (18 MB).
function Update-MacPkgCatalogList {
  param([object[]]$Entries, [string]$Filter = '')
  $macCatalogList.BeginUpdate()
  try {
    $macCatalogList.Items.Clear()
    $needle = [string]$Filter
    foreach ($entry in $Entries) {
      if ($needle) {
        $hay = ("{0} {1} {2}" -f $entry.Name, $entry.Token, $entry.Description)
        if ($hay -notmatch [regex]::Escape($needle)) { continue }
      }
      $item = New-Object System.Windows.Forms.ListViewItem([string]$entry.Name)
      [void]$item.SubItems.Add([string]$entry.Version)
      [void]$item.SubItems.Add($(if ([string]$entry.Source -eq 'override') {
        Get-UiString 'MacPkgSourceOverride' } else { Get-UiString 'MacPkgSourceHomebrew' }))
      [void]$item.SubItems.Add($(if ([string]$entry.Sha256) {
        Get-UiString 'MacPkgHashYes' } else { Get-UiString 'MacPkgHashNo' }))
      $item.Tag = $entry
      [void]$macCatalogList.Items.Add($item)
    }
  } finally {
    $macCatalogList.EndUpdate()
  }
  return $macCatalogList.Items.Count
}

# Holt den Katalog (aus der Kopie oder frisch) und zeigt ihn an.
function Show-MacPkgCatalog {
  param([switch]$Force)
  Show-Progress
  try {
    Update-Status (Get-UiString 'MacPkgCatalogLoadingStatus')
    $entries = Get-MacOsCatalogEntries -Force:$Force
    $script:macPkgUi.Entries = @($entries)
    $shown = Update-MacPkgCatalogList -Entries $script:macPkgUi.Entries -Filter ([string]$macSearchBox.Text)
    Update-Status ((Get-UiString 'MacPkgCatalogLoadedStatus') -f $shown, @($entries).Count)
  } catch {
    Update-Status ((Get-UiString 'MacPkgCatalogFailedStatus') -f $_.Exception.Message)
  } finally {
    Hide-Progress
  }
  Update-SectionLayout -Key 'macospkg'
}

$macCatalogRefreshButton.Add_Click({
  if (Test-UiBusy) { return }
  Show-MacPkgCatalog -Force
})

$macSearchButton.Add_Click({
  if (Test-UiBusy) { return }
  # Noch nie geladen: dann jetzt, sonst sucht der Knopf in einer leeren Liste und es sieht aus,
  # als gaebe es den Treffer nicht.
  if (-not $script:macPkgUi.Entries -or @($script:macPkgUi.Entries).Count -eq 0) {
    Show-MacPkgCatalog
    return
  }
  $shown = Update-MacPkgCatalogList -Entries $script:macPkgUi.Entries -Filter ([string]$macSearchBox.Text)
  Update-Status ((Get-UiString 'MacPkgCatalogLoadedStatus') -f $shown, @($script:macPkgUi.Entries).Count)
})

$macCatalogList.Add_SelectedIndexChanged({
  $has = ($macCatalogList.SelectedItems.Count -gt 0)
  $macCatalogUseButton.Enabled = $has
  $entry = $(if ($has) { $macCatalogList.SelectedItems[0].Tag } else { $null })
  # Die Warnung gehoert an den gewaehlten Eintrag, nicht an den Katalog: die Ueberschreibeintraege
  # und 44 der Casks bringen keinen Hash mit, der Rest schon.
  $macNoHashWarning.Visible = ($entry -and -not [string]$entry.Sha256)
  Update-SectionLayout -Key 'macospkg'
})

$macCatalogUseButton.Add_Click({
  if (Test-UiBusy) { return }
  if ($macCatalogList.SelectedItems.Count -eq 0) { Update-Status (Get-UiString 'MacPkgCatalogNoSelection'); return }
  $entry = $macCatalogList.SelectedItems[0].Tag
  if (-not $entry) { return }

  $script:cancelBatch = $false
  Show-Progress -Cancellable
  try {
    $target = Join-Path ([IO.Path]::GetTempPath()) ("wtgui-{0}.pkg" -f ([string]$entry.Token -replace '[^A-Za-z0-9._-]', '_'))
    Update-Status ((Get-UiString 'MacPkgDownloadingStatus') -f $entry.Name)
    $dl = Invoke-MacOsPackageDownload -Url ([string]$entry.Url) -TargetFile $target -ExpectedSha256 ([string]$entry.Sha256)
    if (-not $dl.Success) {
      if ($script:cancelBatch) { Update-Status (Get-UiString 'MacPkgDownloadCancelledStatus') }
      else { Update-Status ((Get-UiString 'MacPkgDownloadFailedStatus') -f $dl.ErrorMessage) }
      return
    }

    # Ab hier laeuft genau dieselbe Strecke wie bei der Dateiauswahl von Hand.
    $script:macPkgUi.PkgFile = $target
    $script:macPkgUi.CatalogEntry = $entry
    $macFileBox.Text = $target
    $meta = Get-MacOsPkgMetadata -PkgFile $target
    if ($meta.Success -and -not $macNameBox.Text) { $macNameBox.Text = [string]$entry.Name }
    Set-MacPkgMetadataFields -Metadata $meta
    $macCreateButton.Enabled = $true
    Update-Status ((Get-UiString 'MacPkgDownloadOkStatus') -f $entry.Name,
      [math]::Round($dl.Bytes / 1MB), $(if ($dl.HashVerified) { Get-UiString 'MacPkgHashYes' } else { Get-UiString 'MacPkgHashNo' }))
  } finally {
    Hide-Progress
    Update-SectionLayout -Key 'macospkg'
  }
})

$macFileButton.Add_Click({
  $dialog = New-Object System.Windows.Forms.OpenFileDialog
  $dialog.Filter = Get-UiString 'MacPkgFileFilter'
  if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
  $script:macPkgUi.PkgFile = $dialog.FileName
  # Eine von Hand gewaehlte Datei gehoert zu keinem Katalogeintrag. Die Marke eines frueheren
  # Katalog-Downloads stehen zu lassen hiesse, eine fremde Datei unter dessen Namen zu aktualisieren.
  $script:macPkgUi.CatalogEntry = $null
  $macFileBox.Text = $dialog.FileName
  Update-Status (Get-UiString 'MacPkgReadingStatus')
  $meta = Get-MacOsPkgMetadata -PkgFile $dialog.FileName
  Set-MacPkgMetadataFields -Metadata $meta
  if ($meta.Success) {
    Update-Status ((Get-UiString 'MacPkgReadOkStatus') -f $meta.PrimaryBundleId, $macVersionBox.Text)
  } else {
    Update-Status ((Get-UiString 'MacPkgReadFailedStatus') -f $meta.ErrorMessage)
  }
  $macCreateButton.Enabled = $true
  Update-SectionLayout -Key 'macospkg'
})

$macCreateButton.Add_Click({
  $pkg = [string]$script:macPkgUi.PkgFile
  if (-not $pkg -or -not (Test-Path -LiteralPath $pkg -PathType Leaf)) {
    Update-Status (Get-UiString 'MacPkgNoFile'); return
  }
  if ([string]::IsNullOrWhiteSpace($macNameBox.Text)) { Update-Status (Get-UiString 'MacPkgNoName'); return }
  if ([string]::IsNullOrWhiteSpace($macPublisherBox.Text)) { Update-Status (Get-UiString 'MacPkgNoPublisher'); return }
  if ([string]::IsNullOrWhiteSpace($macBundleBox.Text)) { Update-Status (Get-UiString 'MacPkgNoBundleId'); return }
  if ([string]::IsNullOrWhiteSpace($macVersionBox.Text)) { Update-Status (Get-UiString 'MacPkgNoVersion'); return }

  $target = Get-SelectedAssignmentTarget -TargetCombo $macAssignCombo -GroupIdBox $macAssignGroupBox
  $intent = switch ([int]$macIntentCombo.SelectedIndex) { 1 { 'required' } 2 { 'uninstall' } default { 'available' } }
  $targetText = if ($target) { [string]$macAssignCombo.SelectedItem } else { Get-UiString 'AssignNotAssigned' }

  # Gibt es diese App schon? Nur beantwortbar, wenn die Datei aus dem Katalog kam - dann traegt
  # die App im Tenant eine Marke mit demselben Token. Ueber den Anzeigenamen zu suchen waere
  # falsch: den kann jemand im Portal umbenannt haben, und dann entstuende eine zweite App.
  $entry = $script:macPkgUi.CatalogEntry
  $existing = $null
  $notes = ''
  if ($entry) {
    $notes = New-MacOsAppMarker -CaskToken ([string]$entry.Token) -Version ([string]$entry.Version)
    try {
      $existing = Find-DeployedMacOsApp -TenantApps (Get-TenantMacOsPkgApps) -CaskToken ([string]$entry.Token)
    } catch {
      # Das Inventar nicht lesen zu koennen darf die Neuanlage nicht verhindern - es heisst nur,
      # dass wir den Update-Weg nicht anbieten koennen.
      Write-Log ("Could not check the tenant for an existing macOS app: {0}" -f $_.Exception.Message)
      $existing = $null
    }
  }

  $sizeMb = [math]::Round((Get-Item -LiteralPath $pkg).Length / 1MB)
  if ($existing) {
    # Der Update-Weg. IMMER fragen: der Inhalt einer produktiven App wird ersetzt, und jedes
    # zugewiesene Geraet bekommt die neue Fassung - auch wenn niemand eine Zuweisung angefasst hat.
    $question = (Get-UiString 'MacPkgReplaceConfirm') -f $existing.DisplayName,
      $existing.BundleVersion, $macVersionBox.Text, $sizeMb
    $confirmed = Confirm-ChangeAction -Text $question -Title (Get-UiString 'MacPkgCreateButton') `
      -LogContext 'replace content of an existing macOS pkg app' -AlwaysAsk
  } else {
    # Eine Zuweisung erreicht Geraete, das blosse Anlegen nicht. Deshalb ist die Frage nur dann
    # unterdrueckbar, wenn nichts zugewiesen wird.
    $question = (Get-UiString 'MacPkgConfirm') -f $macNameBox.Text, $macVersionBox.Text, $sizeMb, $targetText
    $confirmed = if ($target) {
      Confirm-ChangeAction -Text $question -Title (Get-UiString 'MacPkgCreateButton') `
        -LogContext 'create macOS pkg app with assignment' -AlwaysAsk
    } else {
      Confirm-ChangeAction -Text $question -Title (Get-UiString 'MacPkgCreateButton') `
        -LogContext 'create macOS pkg app'
    }
  }
  if (-not $confirmed) { return }

  $included = @()
  $meta = $script:macPkgUi.Metadata
  if ($meta -and $meta.Success) {
    # Dieselbe Wahl wie fuer die Hauptversion auf ALLE enthaltenen Apps anwenden: eine Mischung aus
    # kurzer und langer Fassung waere eine Erkennungsregel, die teils greift und teils nicht.
    $useBuild = ([int]$macVersionCombo.SelectedIndex -eq 1)
    $included = @($meta.IncludedApps | ForEach-Object {
      @{
        BundleId      = [string]$_.BundleId
        BundleVersion = if ($useBuild) { [string]$_.BuildVersion } else { [string]$_.ShortVersion }
      }
    })
  }
  $minOs = if ($meta -and $meta.MinimumOsProperty) { [string]$meta.MinimumOsProperty } else { 'v11_0' }

  # Den Merker zuruecksetzen, BEVOR die Anzeige erscheint. Ein vorher abgebrochener Lauf laesst ihn
  # gesetzt stehen, und der naechste Upload braeche dann sofort mit "Upload cancelled" ab, ohne
  # dass jemand etwas geklickt hat.
  $script:cancelBatch = $false
  # Die Sichtbarkeit der Fortschrittsanzeige IST die Busy-Sperre - jedes Show-Progress braucht ein
  # Hide-Progress im selben Handler, auch auf dem Fehlerweg.
  Show-Progress -Cancellable
  try {
    Update-Status ((Get-UiString 'MacPkgCreatingStatus') -f $macNameBox.Text)
    $result = Invoke-MacOsPkgDeploy -PkgFile $pkg -DisplayName $macNameBox.Text `
      -Publisher $macPublisherBox.Text -BundleId $macBundleBox.Text -BundleVersion $macVersionBox.Text `
      -IncludedApps $included -MinimumOsProperty $minOs `
      -IgnoreVersionDetection ([bool]$macIgnoreDetectionCheck.Checked) `
      -TargetValue $target -Intent $intent `
      -ExistingAppId $(if ($existing) { [string]$existing.Id } else { '' }) -Notes $notes
    if ($result.Success -and $result.Replaced) {
      Update-Status ((Get-UiString 'MacPkgReplaceDoneStatus') -f $macNameBox.Text, $macVersionBox.Text, $result.AppId)
    } elseif ($result.Success) {
      Update-Status ((Get-UiString 'MacPkgDoneStatus') -f $macNameBox.Text, $result.AppId)
    } elseif ($script:cancelBatch) {
      # Ein Abbruch ist kein Fehler und darf nicht wie einer aussehen. Er hinterlaesst aber
      # dasselbe Problem: die App steht schon im Tenant, ohne vollstaendigen Inhalt.
      Update-Status ((Get-UiString 'MacPkgCancelledStatus') -f $result.AppId)
    } elseif ($result.AppId) {
      # Die App steht im Tenant, hat aber keinen (vollstaendigen) Inhalt. Ihre Id zu nennen ist der
      # Unterschied zwischen "aufraeumbar" und "irgendwo im Portal suchen".
      Update-Status ((Get-UiString 'MacPkgFailedWithAppStatus') -f $result.ErrorMessage, $result.AppId)
    } else {
      Update-Status ((Get-UiString 'MacPkgFailedStatus') -f $result.ErrorMessage)
    }
  } finally {
    Hide-Progress
  }
})

Add-Section -Key 'macospkg' -Panel $tabMacPkg -Label (Get-UiString 'TabMacOsPkg') -Group 'deploy'
