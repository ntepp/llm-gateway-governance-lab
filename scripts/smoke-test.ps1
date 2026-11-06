<#
  Tests rapides des scénarios de gouvernance avec les clés applicatives.
#>
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$base = "http://localhost:4000"

$keys = @{}
foreach ($line in Get-Content (Join-Path $root ".secrets\app-keys.env")) {
    if ($line -match '^([A-Z_]+)=(.*)$') { $keys[$matches[1]] = $matches[2] }
}

function Test-Chat([string]$label, [string]$key, [string]$model, [string]$prompt = "Dis bonjour en une phrase.") {
    $body = @{ model = $model; messages = @(@{ role = "user"; content = $prompt }); max_tokens = 200 } | ConvertTo-Json -Depth 5
    try {
        $r = Invoke-WebRequest -Method POST -Uri "$base/v1/chat/completions" -UseBasicParsing `
            -Headers @{ Authorization = "Bearer $key" } -ContentType "application/json" -Body $body
        $j = $r.Content | ConvertFrom-Json
        $cost = $r.Headers["x-litellm-response-cost"]
        $fb = $r.Headers["x-litellm-attempted-fallbacks"]
        $served = $j.model
        $txt = ($j.choices[0].message.content -replace "\s+", " ")
        $color = "Green"; $note = ""
        if ($fb -and $fb -ne "0") { $color = "Magenta"; $note = " [FALLBACK x$fb]" }
        Write-Host ("[OK ] {0,-45} -> servi par {1}{2} (cost={3}) : {4}" -f $label, $served, $note, $cost, $txt.Substring(0, [Math]::Min(50, $txt.Length))) -ForegroundColor $color
    } catch {
        $msg = $_.ErrorDetails.Message
        if (-not $msg) { $msg = $_.Exception.Message }
        $code = $null; try { $code = [int]$_.Exception.Response.StatusCode } catch { }
        Write-Host ("[{0}] {1,-45} -> {2}" -f $code, $label, ($msg -replace "\s+", " ").Substring(0, [Math]::Min(140, $msg.Length))) -ForegroundColor Yellow
    }
}

Write-Host "`n--- Accès autorisés : 3 fournisseurs + local, même API ---"
Test-Chat "copilot-dev -> gpt-nano (OpenAI)"            $keys.APP_KEY_COPILOT_DEV "gpt-nano"
Test-Chat "copilot-dev -> claude-haiku (Anthropic)"     $keys.APP_KEY_COPILOT_DEV "claude-haiku"
Test-Chat "copilot-dev -> gemini-flash-lite (Google)"   $keys.APP_KEY_COPILOT_DEV "gemini-flash-lite"
Test-Chat "copilot-dev -> local-qwen (Ollama)"          $keys.APP_KEY_COPILOT_DEV "local-qwen"
Test-Chat "chatbot-rh  -> local-qwen"                   $keys.APP_KEY_CHATBOT_RH "local-qwen"

Write-Host "`n--- Politiques de gouvernance (refus attendus) ---"
Test-Chat "chatbot-rh  -> gpt-nano (cloud interdit)"    $keys.APP_KEY_CHATBOT_RH "gpt-nano"
Test-Chat "reporting-finance -> claude-haiku (non autorisé)" $keys.APP_KEY_REPORTING_FINANCE "claude-haiku"
Test-Chat "clé invalide"                                "sk-invalide-123" "gemini-flash-lite"

Write-Host "`n--- Budget finance (0.001 USD/jour) : on consomme jusqu'au refus (coût réel < 0.002 USD) ---"
for ($i = 1; $i -le 10; $i++) {
    Test-Chat "reporting-finance -> gemini-flash-lite #$i" $keys.APP_KEY_REPORTING_FINANCE "gemini-flash-lite" ("Analyse longue du budget trimestriel. " * 400)
}
