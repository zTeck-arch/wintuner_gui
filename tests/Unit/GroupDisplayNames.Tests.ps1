# Zuweisungen nennen die Gruppe beim Namen, nicht bei ihrer GUID.
#
# Gemeldet: "ich kann mit erhoehten Rechten die Group-IDs sehen, aber nicht die Klarnamen wie in
# Intune". Der Grund war, dass die Zuweisungstexte die groupId unveraendert ausgegeben haben.
#
# Geprueft wird hier vor allem, was dabei teuer werden kann: eine Liste mit 300 Apps darf nicht
# 300 Mal in denselben 403 laufen, und ein Favoritenname darf gar keine Abfrage kosten.

BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '20-Version.ps1' -Name 'Test-GuidString')))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '82-TenantApps.ps1' -Name @(
    'Get-EntraGroupDisplayName', 'Get-EntraGroupLabel', 'Clear-EntraGroupNameCache'))))
}

Describe 'Get-EntraGroupDisplayName' {

  BeforeEach {
    Clear-EntraGroupNameCache
    $global:TestGroupFavorites = @()
    $global:TestRestCalls = 0
    $global:TestRestStatus = 0
    $global:TestRestName = 'Pilot-Gruppe'
    $global:TestMgContext = $null

    Set-Item -Path function:global:Get-GroupFavorites -Value { @($global:TestGroupFavorites) }
    Set-Item -Path function:global:Get-WtToken -Value { 'token' }
    Set-Item -Path function:global:Get-ErrorHttpStatus -Value { param($ErrorRecord) [int]$global:TestRestStatus }
    Set-Item -Path function:global:Get-MgContext -Value { $global:TestMgContext }
    Set-Item -Path function:global:Invoke-MgGraphRequest -Value { param($Method, $Uri) @{ displayName = 'Name aus der Graph-Sitzung' } }
    Set-Item -Path function:global:Invoke-RestMethod -Value {
      param($Uri, $Method, $Headers, $Body, $ErrorAction)
      $global:TestRestCalls++
      if ($global:TestRestStatus -ne 0) { throw "HTTP $($global:TestRestStatus)" }
      return [pscustomobject]@{ displayName = $global:TestRestName }
    }
  }

  It 'nimmt den Favoritennamen dieses Kunden ohne jede Abfrage' {
    $global:TestGroupFavorites = @([pscustomobject]@{ Id = '3B97B055-129D-46D5-A51D-0806D4026742'; Name = 'Pilot Buchhaltung' })
    Get-EntraGroupDisplayName -GroupId '3b97b055-129d-46d5-a51d-0806d4026742' | Should -Be 'Pilot Buchhaltung'
    $global:TestRestCalls | Should -Be 0
  }

  It 'liest den Namen mit dem Token der Anwendung' {
    Get-EntraGroupDisplayName -GroupId '3b97b055-129d-46d5-a51d-0806d4026742' | Should -Be 'Pilot-Gruppe'
    $global:TestRestCalls | Should -Be 1
  }

  It 'fragt denselben Namen nur einmal ab' {
    [void](Get-EntraGroupDisplayName -GroupId '3b97b055-129d-46d5-a51d-0806d4026742')
    [void](Get-EntraGroupDisplayName -GroupId '3B97B055-129D-46D5-A51D-0806D4026742')
    $global:TestRestCalls | Should -Be 1
  }

  It 'weicht auf eine bereits erteilte Graph-Zustimmung aus' {
    $global:TestRestStatus = 403
    $global:TestMgContext = [pscustomobject]@{ Scopes = @('Group.Read.All'); Account = 'admin@kunde.de' }
    Get-EntraGroupDisplayName -GroupId '3b97b055-129d-46d5-a51d-0806d4026742' | Should -Be 'Name aus der Graph-Sitzung'
  }

  It 'schaltet die Abfrage nach einem 403 ohne Zustimmung ab, statt sie zu wiederholen' {
    $global:TestRestStatus = 403
    Get-EntraGroupDisplayName -GroupId '3b97b055-129d-46d5-a51d-0806d4026742' | Should -Be ''
    Get-EntraGroupDisplayName -GroupId '7fd7f027-56f3-40e0-804d-31c1e6fff259' | Should -Be ''
    $global:TestRestCalls | Should -Be 1
    ($global:TestLog -join ' ') | Should -Match "Gruppen"
  }

  It 'merkt sich eine geloeschte Gruppe (404) und fragt sie nicht wieder ab' {
    $global:TestRestStatus = 404
    Get-EntraGroupDisplayName -GroupId '3b97b055-129d-46d5-a51d-0806d4026742' | Should -Be ''
    Get-EntraGroupDisplayName -GroupId '3b97b055-129d-46d5-a51d-0806d4026742' | Should -Be ''
    $global:TestRestCalls | Should -Be 1
    ($global:TestLog -join ' ') | Should -Match 'no longer exists'
  }

  It 'fragt nichts ab, was keine GUID ist' {
    Get-EntraGroupDisplayName -GroupId 'alle-benutzer' | Should -Be ''
    $global:TestRestCalls | Should -Be 0
  }
}

Describe 'Get-EntraGroupLabel' {

  BeforeEach {
    Clear-EntraGroupNameCache
    Set-Item -Path function:global:Get-GroupFavorites -Value { @() }
    Set-Item -Path function:global:Get-WtToken -Value { throw 'no token' }
    Set-Item -Path function:global:Get-ErrorHttpStatus -Value { param($ErrorRecord) 0 }
    Set-Item -Path function:global:Get-MgContext -Value { $null }
  }

  It 'zeigt die GUID, wenn kein Name zu holen ist - nie eine leere Zelle' {
    Get-EntraGroupLabel -GroupId '3b97b055-129d-46d5-a51d-0806d4026742' | Should -Be '3b97b055-129d-46d5-a51d-0806d4026742'
  }
}

Describe 'Zuweisungstexte im Quelltext' {

  It 'geben keine rohe groupId mehr aus' {
    $part = Get-SourcePartText -Part '82-TenantApps.ps1'
    $part | Should -Not -Match "'Group \{0\}' -f \[string\]\`$a\.target\.groupId"
    $part | Should -Not -Match "TargetGroup'\) -f \[string\]\`$Assignment\.GroupId"
    # ... sondern gehen durch den Aufloeser.
    ([regex]::Matches($part, 'Get-EntraGroupLabel -GroupId')).Count | Should -BeGreaterOrEqual 4
  }
}
