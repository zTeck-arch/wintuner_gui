BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '80-Views.ps1' -Name 'Select-StoreListEntry')))

  # The function reads the list view from script scope, the way it does in the application.
  #
  # CreateControl() is essential, not decoration: without a window handle a ListView keeps the
  # selection only on the items and never reports it through SelectedItems, and EnsureVisible has
  # nothing to scroll. Creating the handle makes this fixture behave like the one on screen, so the
  # test exercises the same path the deployed app takes.
  function global:New-StoreListFixture {
    param([object[]]$Apps)
    $lv = New-Object System.Windows.Forms.ListView
    $lv.View = [System.Windows.Forms.View]::Details
    $lv.MultiSelect = $false
    [void]$lv.Columns.Add('Name', 200)
    $lv.CreateControl()
    foreach ($a in $Apps) {
      $row = New-Object System.Windows.Forms.ListViewItem([string]$a.DisplayName)
      $row.Tag = $a
      [void]$lv.Items.Add($row)
    }
    return $lv
  }
}

Describe 'Select-StoreListEntry' {
  # Regression: after deploying a Store app the query box was cleared and the tenant inventory was
  # reloaded unfiltered, so the list showed every Store app in the tenant and the one just created
  # was not marked at all - in a large tenant it was not even on screen. The deploy path now filters
  # by package id and calls this to put the new app in view.
  BeforeEach {
    $script:storeTenantListView = New-StoreListFixture -Apps @(
      [pscustomobject]@{ DisplayName = 'Alpha'; PackageIdentifier = '9NALPHA'; Id = 'id-alpha' },
      [pscustomobject]@{ DisplayName = 'Bravo'; PackageIdentifier = '9NBRAVO'; Id = 'id-bravo' },
      [pscustomobject]@{ DisplayName = 'Charlie'; PackageIdentifier = '9NCHARLIE'; Id = 'id-charlie' }
    )
  }

  It 'selects the entry whose Graph id matches' {
    Select-StoreListEntry -PackageIdentifier '9NALPHA' -GraphId 'id-bravo'
    $selected = @($script:storeTenantListView.SelectedItems)
    $selected.Count | Should -Be 1
    $selected[0].Text | Should -Be 'Bravo'
  }

  # The Graph id is the authoritative handle, but it stays empty when the tenant could not be
  # re-read after the deployment. The package identifier has to carry the match in that case.
  It 'falls back to the package identifier when no Graph id is known' {
    Select-StoreListEntry -PackageIdentifier '9NCHARLIE' -GraphId ''
    $selected = @($script:storeTenantListView.SelectedItems)
    $selected.Count | Should -Be 1
    $selected[0].Text | Should -Be 'Charlie'
  }

  It 'prefers the Graph id over a package identifier pointing elsewhere' {
    Select-StoreListEntry -PackageIdentifier '9NALPHA' -GraphId 'id-charlie'
    @($script:storeTenantListView.SelectedItems)[0].Text | Should -Be 'Charlie'
  }

  It 'leaves the list alone when nothing matches' {
    Select-StoreListEntry -PackageIdentifier '9NUNKNOWN' -GraphId 'id-unknown'
    @($script:storeTenantListView.SelectedItems).Count | Should -Be 0
  }

  It 'does not throw when a row carries no app object' {
    $row = New-Object System.Windows.Forms.ListViewItem('orphan')
    [void]$script:storeTenantListView.Items.Add($row)
    { Select-StoreListEntry -PackageIdentifier '9NALPHA' -GraphId 'id-alpha' } | Should -Not -Throw
    @($script:storeTenantListView.SelectedItems)[0].Text | Should -Be 'Alpha'
  }
}
