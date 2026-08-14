@{
  # Rules excluded here are not "ignored problems" – each one conflicts with a deliberate
  # design decision of this project. Anything not listed is enforced, and Error/Warning
  # findings fail the Validate workflow.
  ExcludeRules = @(
    # The prerequisite bootstrap runs before any WPF/WinForms window exists and must talk to
    # a plain console (it also has to work under Windows PowerShell 5.1). Write-Host is the
    # correct tool there, not a code smell.
    'PSAvoidUsingWriteHost'

    # This is a single-file application script, not a published module. Its functions are
    # internal helpers, never exported cmdlets, so ShouldProcess/-WhatIf plumbing and the
    # singular-noun naming convention for public cmdlets do not apply.
    'PSUseShouldProcessForStateChangingFunctions'
    'PSUseSingularNouns'
    'PSUseApprovedVerbs'

    # WinForms event handlers use the framework-mandated `param($sender, $e)` signature.
    # 15 of the 17 findings are exactly that idiom; renaming would obscure the pattern.
    # Trade-off: genuine $matches/$args shadowing is no longer caught automatically.
    'PSAvoidAssignmentToAutomaticVariable'
    'PSReviewUnusedParameter'

    # Best-effort teardown (`try { Disconnect-... } catch { }`) is used on purpose so that
    # cleanup never masks the original error. Tech debt: 67 occurrences are more than the
    # intentional ones, so these should be revisited during modularisation.
    'PSAvoidUsingEmptyCatchBlock'

    # False positive: PSScriptAnalyzer resolves Write-Log against a cmdlet that does not exist
    # in PowerShell 7.
    'PSAvoidOverwritingBuiltInCmdlets'

    # Excluded because the parts are dot-sourced into ONE shared scope, while the analyser reads
    # each file on its own - a variable assigned in 85-Rows.ps1 and read in 90-Main.ps1 looks
    # unused to it. Worth knowing: this rule previously reported a genuine defect here
    # ($convertedExclusion, assigned in Set-AppAssignmentSettings but read from a block that had
    # been misplaced into Get-AppVersionGroups) and it was wrongly dismissed as noise. Prefer
    # checking a finding of this rule by hand over assuming it is a false positive.
    'PSUseDeclaredVarsMoreThanAssignments'

    # The parts in src/ must stay BOM-free: a BOM is a byte sequence, and one sitting in the
    # middle of a concatenated file would corrupt the assembled script. The BOM matters only
    # for the shipped single file, where Build-SingleFile.ps1 adds it and StaticChecks.ps1
    # asserts it - so the rule is not dropped here, it is checked in the right place.
    'PSUseBOMForUnicodeEncodedFile'
  )

  # Cosmetic-only rules stay enabled but report as Information, which does not fail the build.
  Severity = @('Error', 'Warning', 'Information')
}
