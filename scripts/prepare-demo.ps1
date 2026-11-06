<#
  À lancer le matin de la présentation (stack démarrée) :
    1. vérifie que la gateway et Keycloak répondent
    2. remet à zéro la dépense de l'appli finance (démo 6 : dépassement de budget)
    3. préchauffe le modèle local (évite ~7 s d'attente à la première démo)
#>
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$base = "http://localhost:4000"

function Read-EnvFile([string]$path) {
    $h = @{}
    foreach ($line in Get-Content $path) { if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') { $h[$matches[1]] = $matches[2] } }
    return $h
}
$envVars = Read-EnvFile (Join-Path $root ".env")
$keys = Read-EnvFile (Join-Path $root ".secrets\app-keys.env")
$admin = @{ Authorization = "Bearer $($envVars['LITELLM_MASTER_KEY'])" }

function Step([string]$label, [scriptblock]$action) {
    try { $msg = & $action; Write-Host ("[OK]  {0} {1}" -f $label, $msg) -ForegroundColor Green }
    catch { Write-Host ("[KO]  {0} : {1}" -f $label, $_.Exception.Message) -ForegroundColor Red }
}

Step "Gateway LiteLLM" { (Invoke-WebRequest "$base/health/liveliness" -UseBasicParsing -TimeoutSec 5).StatusCode | Out-Null; "" }
Step "Keycloak" { (Invoke-WebRequest "http://localhost:8080/realms/llm-gateway/.well-known/openid-configuration" -UseBasicParsing -TimeoutSec 5).StatusCode | Out-Null; "" }

Step "Budget de l'equipe finance (plafond equipe 1 USD)" {
    $body = @{ team_id = "team-finance"; max_budget = 1; budget_duration = "1d" } | ConvertTo-Json
    Invoke-RestMethod -Method POST -Uri "$base/team/update" -Headers $admin -ContentType "application/json" -Body $body | Out-Null; ""
}
Step "Remise a zero de la depense de app-reporting-finance" {
    $k = $keys["APP_KEY_REPORTING_FINANCE"]
    Invoke-RestMethod -Method POST -Uri "$base/key/$k/reset_spend" -Headers $admin -ContentType "application/json" -Body '{"reset_to": 0}' | Out-Null
    $info = Invoke-RestMethod -Uri "$base/key/info?key=$k" -Headers $admin
    "(depense = $($info.info.spend) USD / plafond $($info.info.max_budget) USD)"
}
Step "Prechauffage du modele local (local-qwen)" {
    $body = @{ model = "local-qwen"; max_tokens = 5; messages = @(@{ role = "user"; content = "ok" }) } | ConvertTo-Json -Depth 4
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Invoke-RestMethod -Method POST -Uri "$base/v1/chat/completions" -Headers @{ Authorization = "Bearer $($keys['APP_KEY_COPILOT_DEV'])" } -ContentType "application/json" -Body $body | Out-Null
    "($([math]::Round($sw.Elapsed.TotalSeconds,1)) s)"
}
Write-Host "`nPret pour la demo. Ordre conseille : smoke-test.ps1 (demos 1, 3, 5, 6), UI /ui avec alice.dev (demo 2), pii-test.ps1 (demo 4)."
