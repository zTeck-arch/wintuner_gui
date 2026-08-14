@{
  # Analyser rules for tests/. Same set as the application, minus the ones that conflict with how
  # Pester 5 has to be written. Kept as a separate file rather than loosening the main settings, so
  # the application code stays under the stricter set.
  ExcludeRules = @(
    # --- Inherited from PSScriptAnalyzerSettings.psd1 (same reasons) ---
    'PSAvoidUsingWriteHost'
    'PSUseShouldProcessForStateChangingFunctions'
    'PSUseSingularNouns'
    'PSUseApprovedVerbs'
    'PSAvoidAssignmentToAutomaticVariable'
    'PSReviewUnusedParameter'
    'PSAvoidUsingEmptyCatchBlock'
    'PSAvoidOverwritingBuiltInCmdlets'
    'PSUseDeclaredVarsMoreThanAssignments'
    'PSUseBOMForUnicodeEncodedFile'

    # --- Specific to Pester ---
    # Pester 5 runs Describe/Context/It in separate scopes. A stub or fixture that the code under
    # test must see - a fake Get-WtWin32Apps, the handler deciding what Graph answers - has to live
    # in the global scope; $script: does not reach an It block. This is the documented pattern, not
    # sloppiness. It applies to test files only, which is why the application keeps the rule.
    'PSAvoidGlobalVars'
    'PSAvoidGlobalFunctions'
  )

  Severity = @('Error', 'Warning', 'Information')
}
