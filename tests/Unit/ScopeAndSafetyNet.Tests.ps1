BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  # The real string table, so the assertions below check the texts that actually ship.
  . ([scriptblock]::Create((Get-UiStringsText)))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '40-Graph.ps1' -Name 'Group-UpdateCandidates')))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '20-Version.ps1' -Name @(
    'Get-ComparableVersionParts', 'Test-IsNewerVersion'))))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '45-Assignments.ps1' -Name @(
    'Save-AppScopeSnapshot', 'Get-ScopeSnapshotText'))))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '70-Runtime.ps1' -Name @(
    'Get-TenantDisplayName', 'Get-TenantDisplayLabel', 'Set-TenantDisplayName',
    'Test-ChangeConfirmationsSuppressed'))))

  function global:New-Candidate {
    param([string]$Name, [string]$Version, [string]$GraphId, [string]$PackageId = 'Acme.Tool', [string]$Latest = '3.0')
    [pscustomobject]@{
      Name = $Name; CurrentVersion = $Version; LatestVersion = $Latest
      GraphId = $GraphId; PackageId = $PackageId; ExistingTargetGraphId = $null; ExistingTargetName = $null
    }
  }
}

Describe 'Group-UpdateCandidates scope warning' {
  # Reported from a real run: Google Chrome had two predecessors - one assigned to a group, one not
  # assigned at all - and the row said "Scopes abweichend". That is not a differing scope. The
  # signature comparison counted the '<none>' sentinel as if it were a scope, so the most ordinary
  # situation there is (an older version already unassigned) raised a conflict warning, which teaches
  # the reader to ignore the warning entirely.
  BeforeEach {
    $global:ProbeResults = @{}
    function global:Get-AppAssignmentScopeProbe {
      param([string]$AppId, [string]$AppName)
      if ($global:ProbeResults.ContainsKey($AppId)) { return $global:ProbeResults[$AppId] }
      return [pscustomobject]@{ Succeeded = $true; Signature = '<none>'; Summary = 'keine Zuweisung'; Count = 0 }
    }
  }
  AfterAll { Remove-Item function:global:Get-AppAssignmentScopeProbe -ErrorAction SilentlyContinue }

  It 'does NOT warn when one predecessor is assigned and the other is not' {
    $global:ProbeResults['id-assigned'] = [pscustomobject]@{
      Succeeded = $true; Signature = 'required|group-abc|none|-'; Summary = 'required Gruppe abc'; Count = 1 }
    $global:ProbeResults['id-none'] = [pscustomobject]@{
      Succeeded = $true; Signature = '<none>'; Summary = 'keine Zuweisung'; Count = 0 }
    $out = @(Group-UpdateCandidates -Candidates @(
      (New-Candidate -Name 'Google Chrome' -Version '150.0' -GraphId 'id-assigned'),
      (New-Candidate -Name 'Google Chrome' -Version '148.0' -GraphId 'id-none')))
    $out.Count | Should -Be 1
    $out[0].ScopeWarning | Should -BeFalse -Because 'no assignment is not a differing assignment'
    $out[0].ScopeUnknown | Should -BeFalse
  }

  It 'warns when two predecessors carry genuinely different assignments' {
    $global:ProbeResults['id-a'] = [pscustomobject]@{
      Succeeded = $true; Signature = 'required|group-abc|none|-'; Summary = 'required Gruppe abc'; Count = 1 }
    $global:ProbeResults['id-b'] = [pscustomobject]@{
      Succeeded = $true; Signature = 'available|group-xyz|none|-'; Summary = 'available Gruppe xyz'; Count = 1 }
    $out = @(Group-UpdateCandidates -Candidates @(
      (New-Candidate -Name 'Acme' -Version '1.0' -GraphId 'id-a'),
      (New-Candidate -Name 'Acme' -Version '2.0' -GraphId 'id-b')))
    $out[0].ScopeWarning | Should -BeTrue
  }

  It 'does not warn when both predecessors are unassigned' {
    $out = @(Group-UpdateCandidates -Candidates @(
      (New-Candidate -Name 'Acme' -Version '1.0' -GraphId 'id-1'),
      (New-Candidate -Name 'Acme' -Version '2.0' -GraphId 'id-2')))
    $out[0].ScopeWarning | Should -BeFalse
    $out[0].NoAssignment | Should -BeTrue
  }

  It 'reports an unreadable probe as unknown, NOT as differing' {
    # "I could not read it" and "they differ" need different words: the first sends the reader to the
    # portal to look, the second to a conflict that may not exist.
    $global:ProbeResults['id-ok'] = [pscustomobject]@{
      Succeeded = $true; Signature = 'required|group-abc|none|-'; Summary = 'required Gruppe abc'; Count = 1 }
    $global:ProbeResults['id-broken'] = [pscustomobject]@{
      Succeeded = $false; Signature = $null; Summary = 'Fehler'; Count = $null }
    $out = @(Group-UpdateCandidates -Candidates @(
      (New-Candidate -Name 'Acme' -Version '1.0' -GraphId 'id-ok'),
      (New-Candidate -Name 'Acme' -Version '2.0' -GraphId 'id-broken')))
    $out[0].ScopeUnknown | Should -BeTrue
    $out[0].ScopeWarning | Should -BeFalse
  }

  It 'still warns about separate deployment lanes with the same package id' {
    $out = @(Group-UpdateCandidates -Candidates @(
      (New-Candidate -Name 'Acme Pilot' -Version '1.0' -GraphId 'id-1'),
      (New-Candidate -Name 'Acme Standard' -Version '2.0' -GraphId 'id-2')))
    $out[0].ScopeWarning | Should -BeTrue -Because 'different display names can mean intentionally separate lanes'
  }
}

Describe 'Save-AppScopeSnapshot' {
  # Safety net: once an app object is deleted its assignments are gone with it. If the deletion turns
  # out to have been wrong there is otherwise no way back to "Chrome was available for X, required
  # for Y".
  BeforeEach {
    $global:TestLog.Clear()
    $script:scopeSnapshots = [System.Collections.Generic.List[object]]::new()
    $script:settings = @{ SaveScopeBeforeRemoval = $true }
    $script:currentUserUpn = 'admin@kunde.de'
    function global:Get-AppAssignmentScopeProbe {
      param([string]$AppId, [string]$AppName)
      return $global:SnapshotProbe
    }
    $global:SnapshotProbe = [pscustomobject]@{
      Succeeded = $true; Signature = 'available|alllicensedusers|none|-'; Summary = 'available Alle Benutzer'; Count = 1 }
  }
  AfterAll {
    Remove-Item function:global:Get-AppAssignmentScopeProbe -ErrorAction SilentlyContinue
    Remove-Variable -Name SnapshotProbe -Scope Global -ErrorAction SilentlyContinue
  }

  It 'keeps the scope and says so in the log' {
    $entry = Save-AppScopeSnapshot -AppId 'app-1' -AppName 'Google Chrome' -Version '148.0' -Reason 'Testlauf'
    $entry | Should -Not -BeNullOrEmpty
    $entry.Scope | Should -Be 'available Alle Benutzer'
    $script:scopeSnapshots.Count | Should -Be 1
    ($global:TestLog -join "`n") | Should -Match 'Scope kept before removal'
  }

  It 'records an unassigned app as unassigned rather than as a failure' {
    $global:SnapshotProbe = [pscustomobject]@{ Succeeded = $true; Signature = '<none>'; Summary = 'x'; Count = 0 }
    (Save-AppScopeSnapshot -AppId 'app-2' -AppName 'Solo').Scope | Should -Be (Get-UiString 'ScopeSnapshotNone')
  }

  It 'records a failed probe AS a failed probe, and never blocks the deletion' {
    $global:SnapshotProbe = [pscustomobject]@{ Succeeded = $false; Signature = $null; Summary = $null; Count = $null }
    $entry = Save-AppScopeSnapshot -AppId 'app-3' -AppName 'Broken'
    $entry.Succeeded | Should -BeFalse
    $entry.Scope | Should -Be (Get-UiString 'ScopeSnapshotUnreadable')
  }

  It 'does nothing when the safety net is switched off' {
    $script:settings.SaveScopeBeforeRemoval = $false
    Save-AppScopeSnapshot -AppId 'app-4' -AppName 'Ignored' | Should -BeNullOrEmpty
    $script:scopeSnapshots.Count | Should -Be 0
  }

  It 'survives a probe that throws' {
    function global:Get-AppAssignmentScopeProbe { param($AppId, $AppName) throw 'Graph exploded' }
    { Save-AppScopeSnapshot -AppId 'app-5' -AppName 'Boom' } | Should -Not -Throw
    $script:scopeSnapshots.Count | Should -Be 1
  }

  It 'renders newest first, so the deletion that just happened is on top' {
    $null = Save-AppScopeSnapshot -AppId 'app-a' -AppName 'Erste' -Version '1.0' -Reason 'r1'
    Start-Sleep -Milliseconds 20
    $null = Save-AppScopeSnapshot -AppId 'app-b' -AppName 'Zweite' -Version '2.0' -Reason 'r2'
    $text = Get-ScopeSnapshotText
    $text.IndexOf('Zweite') | Should -BeLessThan $text.IndexOf('Erste')
  }

  It 'says so plainly when nothing was deleted' {
    Get-ScopeSnapshotText | Should -Be (Get-UiString 'ScopeSnapshotEmpty')
  }
}

Describe 'Tenant display names' {
  BeforeEach {
    $script:settings = @{ TenantDisplayNames = @{} }
  }

  It 'falls back to the derived name when nothing was set by hand' {
    # adm@alsterspree.de -> "Alsterspree" comes from the domain derivation.
    Get-TenantDisplayName -Upn 'adm@alsterspree.de' | Should -Be 'Alsterspree'
  }

  It 'lets a manual name win over the derivation' {
    Set-TenantDisplayName -Upn 'adm@alsterspree.de' -Name 'Stadtwerke Nord'
    Get-TenantDisplayName -Upn 'adm@alsterspree.de' | Should -Be 'Stadtwerke Nord'
  }

  It 'always keeps the address visible next to a manual name' {
    Set-TenantDisplayName -Upn 'adm@kunde.de' -Name 'Kunde GmbH'
    Get-TenantDisplayLabel -Upn 'adm@kunde.de' | Should -Be 'Kunde GmbH (adm@kunde.de)'
  }

  It 'shows the derived name with the address when nothing was set by hand' {
    # The derivation always produces something, so the label reads "Name (address)" either way -
    # and the address is what matters for not picking the wrong customer.
    Get-TenantDisplayLabel -Upn 'adm@kunde.de' | Should -Be 'Kunde (adm@kunde.de)'
  }

  It 'shows the address alone when even the derivation cannot produce a name' {
    Get-TenantDisplayLabel -Upn 'weird' | Should -Be 'weird'
  }

  It 'clearing a name is a real action and restores the derivation' {
    Set-TenantDisplayName -Upn 'adm@alsterspree.de' -Name 'Temporaer'
    Set-TenantDisplayName -Upn 'adm@alsterspree.de' -Name ''
    Get-TenantDisplayName -Upn 'adm@alsterspree.de' | Should -Be 'Alsterspree'
  }

  It 'trims a pasted name' {
    Set-TenantDisplayName -Upn 'adm@kunde.de' -Name '  Kunde GmbH  '
    Get-TenantDisplayName -Upn 'adm@kunde.de' | Should -Be 'Kunde GmbH'
  }

  It 'ignores an empty UPN' {
    Get-TenantDisplayName -Upn '' | Should -Be ''
    Get-TenantDisplayLabel -Upn '' | Should -Be ''
  }
}

Describe 'Test-ChangeConfirmationsSuppressed' {
  # Switching the prompts off is acknowledged once per VERSION: a new release may add a prompt the
  # technician has never seen, and a settings file carried over must not silently disable it.
  BeforeEach { $script:appVersion = '0.16.0' }

  It 'is off by default' {
    $script:settings = @{ SuppressChangeConfirmations = $false; ChangeConfirmationRiskAcceptedVersion = '' }
    Test-ChangeConfirmationsSuppressed | Should -BeFalse
  }

  It 'honours the switch once the risk was acknowledged for this version' {
    $script:settings = @{ SuppressChangeConfirmations = $true; ChangeConfirmationRiskAcceptedVersion = '0.16.0' }
    Test-ChangeConfirmationsSuppressed | Should -BeTrue
  }

  It 'asks again after an upgrade, even with the switch still on' {
    $script:settings = @{ SuppressChangeConfirmations = $true; ChangeConfirmationRiskAcceptedVersion = '0.15.8' }
    Test-ChangeConfirmationsSuppressed | Should -BeFalse -Because 'a new version may add prompts nobody has seen yet'
  }

  It 'ignores an acknowledgement without the switch' {
    $script:settings = @{ SuppressChangeConfirmations = $false; ChangeConfirmationRiskAcceptedVersion = '0.16.0' }
    Test-ChangeConfirmationsSuppressed | Should -BeFalse
  }
}
