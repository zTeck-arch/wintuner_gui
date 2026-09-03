BeforeAll {
  . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
  Initialize-TestAmbient
  # Der ECHTE Konfigurationsteil, nicht eine Kopie der Statusliste: die Regel "welche Antworten
  # werden wiederholt" darf im Test nicht anders lauten als in der Anwendung. 05-Config setzt nur
  # Variablen und definiert die zwei Pfadwurzeln, baut also keine Oberflaeche.
  . ([scriptblock]::Create((Get-SourcePartText -Part '05-Config.ps1')))
  . ([scriptblock]::Create((Get-SourceFunctionText -Part '40-Graph.ps1' `
    -Name 'Get-GraphRetryPlan', 'Get-ErrorRetryAfterSeconds')))

  # Ein Fehler mit Retry-After als TimeSpan - so gibt PowerShell 7 die Kopfzeile heraus.
  function global:New-RetryAfterError {
    param([int]$Seconds)
    [pscustomobject]@{
      Exception = [pscustomobject]@{
        Message  = 'too many requests'
        Response = [pscustomobject]@{
          Headers = [pscustomobject]@{ RetryAfter = [pscustomobject]@{ Delta = [TimeSpan]::FromSeconds($Seconds) } }
        }
      }
    }
  }
  # Und als roher Kopfzeilenwert, wie ihn ein Wrapper durchreicht.
  function global:New-RetryAfterHeaderError {
    param([string]$Value)
    [pscustomobject]@{
      Exception = [pscustomobject]@{
        Message  = 'too many requests'
        Response = [pscustomobject]@{ Headers = @{ 'Retry-After' = $Value } }
      }
    }
  }
  function global:New-MessageOnlyError {
    param([string]$Message)
    [pscustomobject]@{ Exception = [pscustomobject]@{ Message = $Message; Response = $null } }
  }
}

Describe 'Get-GraphRetryPlan' {
  # Die eine Regel, die eine Sicherheitsregel ist und keine Bequemlichkeit: ohne gelesenen Status
  # wird NICHT wiederholt. Status 0 heisst Zeitablauf, abgerissene Verbindung oder DNS - und genau
  # dann weiss der Aufrufer nicht, ob der Dienst die Anfrage schon ausgefuehrt hat. Ein zweiter POST
  # auf /mobileApps legte eine zweite, nicht verknuepfte App im Tenant an.
  Context 'ohne lesbaren HTTP-Status' {
    It 'wiederholt nicht' {
      $plan = Get-GraphRetryPlan -Status 0 -Attempt 0 -MaxRetries 2
      $plan.Retry | Should -BeFalse
    }
    It 'nennt den Grund, damit im Protokoll steht warum' {
      $plan = Get-GraphRetryPlan -Status 0 -Attempt 0 -MaxRetries 2
      $plan.Reason | Should -BeLike '*may already have been applied*'
    }
  }

  Context 'Antworten, die einen zweiten Versuch verdienen' {
    It 'wiederholt bei 429 und bei 5xx' -ForEach @(
      @{ Status = 429 }, @{ Status = 500 }, @{ Status = 502 }, @{ Status = 503 }, @{ Status = 504 }
    ) {
      (Get-GraphRetryPlan -Status $Status -Attempt 0 -MaxRetries 2).Retry | Should -BeTrue
    }
    It 'wiederholt NICHT bei einem Fehler der Anfrage' -ForEach @(
      @{ Status = 400 }, @{ Status = 401 }, @{ Status = 403 }, @{ Status = 404 }, @{ Status = 409 }
    ) {
      (Get-GraphRetryPlan -Status $Status -Attempt 0 -MaxRetries 2).Retry | Should -BeFalse
    }
  }

  Context 'Wartezeit' {
    It 'steigt 5 / 15 / 30, wenn der Dienst nichts vorgibt' {
      (Get-GraphRetryPlan -Status 429 -Attempt 0 -MaxRetries 5).WaitSeconds | Should -Be 5
      (Get-GraphRetryPlan -Status 429 -Attempt 1 -MaxRetries 5).WaitSeconds | Should -Be 15
      (Get-GraphRetryPlan -Status 429 -Attempt 2 -MaxRetries 5).WaitSeconds | Should -Be 30
      (Get-GraphRetryPlan -Status 429 -Attempt 3 -MaxRetries 5).WaitSeconds | Should -Be 30
    }
    It 'nimmt Retry-After des Dienstes, wenn es eines gibt' {
      (Get-GraphRetryPlan -Status 429 -Attempt 0 -MaxRetries 2 -RetryAfterSeconds 7).WaitSeconds | Should -Be 7
    }
    It 'begrenzt Retry-After auf 45 s - laenger wartet niemand auf eine Zuweisung' {
      (Get-GraphRetryPlan -Status 429 -Attempt 0 -MaxRetries 2 -RetryAfterSeconds 900).WaitSeconds | Should -Be 45
    }
    It 'faellt bei einem unbrauchbaren Retry-After auf die Treppe zurueck' {
      (Get-GraphRetryPlan -Status 429 -Attempt 0 -MaxRetries 2 -RetryAfterSeconds 0).WaitSeconds | Should -Be 5
      (Get-GraphRetryPlan -Status 429 -Attempt 1 -MaxRetries 2 -RetryAfterSeconds -5).WaitSeconds | Should -Be 15
    }
  }

  Context 'Obergrenze der Versuche' {
    It 'hoert auf, wenn die Versuche verbraucht sind' {
      $plan = Get-GraphRetryPlan -Status 429 -Attempt 2 -MaxRetries 2
      $plan.Retry | Should -BeFalse
      $plan.Reason | Should -Be 'retries exhausted'
    }
    # -MaxRetries 0 nutzen die nicht idempotenten Wege (App anlegen) und die Aufrufer mit eigener
    # Wiederholungsschleife (Inventar). Dort darf gar nichts wiederholt werden.
    It 'wiederholt bei MaxRetries 0 nie, auch nicht bei 429' {
      (Get-GraphRetryPlan -Status 429 -Attempt 0 -MaxRetries 0).Retry | Should -BeFalse
    }
  }
}

Describe 'Get-ErrorRetryAfterSeconds' {
  It 'liest Retry-After als TimeSpan' {
    Get-ErrorRetryAfterSeconds -ErrorRecord (New-RetryAfterError -Seconds 12) | Should -Be 12
  }
  It 'rundet einen Bruchteil auf, damit aus 0,4 s keine 0 wird' {
    $err = [pscustomobject]@{
      Exception = [pscustomobject]@{
        Message  = 'x'
        Response = [pscustomobject]@{
          Headers = [pscustomobject]@{ RetryAfter = [pscustomobject]@{ Delta = [TimeSpan]::FromMilliseconds(400) } }
        }
      }
    }
    Get-ErrorRetryAfterSeconds -ErrorRecord $err | Should -Be 1
  }
  It 'liest den rohen Kopfzeilenwert' {
    Get-ErrorRetryAfterSeconds -ErrorRecord (New-RetryAfterHeaderError -Value '20') | Should -Be 20
  }
  It 'liest die Angabe notfalls aus dem Fehlertext' {
    Get-ErrorRetryAfterSeconds -ErrorRecord (New-MessageOnlyError -Message 'Too many requests. Retry-After: 33') | Should -Be 33
  }
  It 'liefert 0, wenn nirgends eine Angabe steht' {
    Get-ErrorRetryAfterSeconds -ErrorRecord (New-MessageOnlyError -Message 'service unavailable') | Should -Be 0
  }
  It 'liefert 0 bei einem unbrauchbaren Kopfzeilenwert statt zu fliegen' {
    # Ein Datum statt Sekunden ist nach RFC erlaubt und wird hier bewusst nicht gedeutet: dann gilt
    # die eigene Treppe. Fliegen darf die Funktion dabei nicht.
    Get-ErrorRetryAfterSeconds -ErrorRecord (New-RetryAfterHeaderError -Value 'Wed, 21 Oct 2026 07:28:00 GMT') | Should -Be 0
  }
}
