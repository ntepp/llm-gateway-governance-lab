<#
  Provisionne la gouvernance dans LiteLLM via son API d'admin :
    - 3 équipes (= groupes Keycloak) avec modèles autorisés, budgets, quotas
    - 1 virtual key par application, rattachée à son équipe
  Idempotent : ce qui existe déjà est conservé.
#>
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$base = "http://localhost:4000"

function Read-EnvFile([string]$path) {
    $h = @{}
    if (Test-Path $path) {
        foreach ($line in Get-Content $path) {
            if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') { $h[$matches[1]] = $matches[2] }
        }
    }
    return $h
}

$envVars = Read-EnvFile (Join-Path $root ".env")
$headers = @{ Authorization = "Bearer $($envVars['LITELLM_MASTER_KEY'])" }

function Invoke-Admin([string]$method, [string]$path, $body = $null) {
    $params = @{ Method = $method; Uri = "$base$path"; Headers = $headers; ContentType = "application/json" }
    if ($body) { $params.Body = ($body | ConvertTo-Json -Depth 6) }
    return Invoke-RestMethod @params
}

# ------------------------------------------------------------------ Équipes
$teams = @(
    @{ team_id = "team-dev"; team_alias = "Engineering"
       models = @("gpt-nano", "gpt-6-luna", "claude-haiku", "gemini-flash-lite", "local-qwen")
       max_budget = 50; budget_duration = "30d"; tpm_limit = 200000; rpm_limit = 120
       metadata = @{ cost_center = "CC-ENG-001"; owner = "alice.dev@example.com" } },
    @{ team_id = "team-rh"; team_alias = "Ressources Humaines"
       models = @("local-qwen")   # données sensibles : modèle local uniquement
       max_budget = 5; budget_duration = "30d"; tpm_limit = 50000; rpm_limit = 30
       metadata = @{ cost_center = "CC-RH-002"; data_classification = "confidentiel"; owner = "bob.rh@example.com" } },
    @{ team_id = "team-finance"; team_alias = "Finance"
       models = @("gemini-flash-lite", "gpt-nano")
       max_budget = 1; budget_duration = "1d"; tpm_limit = 50000; rpm_limit = 10   # la démo de dépassement repose sur le plafond de la CLÉ (0,001 $), remise à zéro par prepare-demo.ps1
       metadata = @{ cost_center = "CC-FIN-003"; owner = "carla.finance@example.com" } }
)

foreach ($t in $teams) {
    $exists = $false
    try { Invoke-Admin GET "/team/info?team_id=$($t.team_id)" | Out-Null; $exists = $true } catch { }
    if ($exists) { Write-Host "Équipe $($t.team_id) : déjà présente" }
    else { Invoke-Admin POST "/team/new" $t | Out-Null; Write-Host "Équipe $($t.team_id) : créée" }
}

# ------------------------------------------------------------ Clés par app
$secretsDir = Join-Path $root ".secrets"
New-Item -ItemType Directory -Force $secretsDir | Out-Null
$keysFile = Join-Path $secretsDir "app-keys.env"
$keys = Read-EnvFile $keysFile

function New-KeyValue {
    $b = New-Object byte[] 24
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
    return "sk-" + ([Convert]::ToBase64String($b)).TrimEnd('=').Replace('+', 'A').Replace('/', 'B')
}

$apps = @(
    @{ var = "APP_KEY_COPILOT_DEV"; key_alias = "app-copilot-dev"; team_id = "team-dev"
       models = @("gpt-nano", "claude-haiku", "gemini-flash-lite", "local-qwen"); max_budget = 20; budget_duration = "30d"; rpm_limit = 60
       metadata = @{ application = "copilot-dev"; environment = "demo" } },
    @{ var = "APP_KEY_CHATBOT_RH"; key_alias = "app-chatbot-rh"; team_id = "team-rh"
       models = @("local-qwen"); max_budget = 5; budget_duration = "30d"; rpm_limit = 20
       metadata = @{ application = "chatbot-rh"; environment = "demo" } },
    @{ var = "APP_KEY_REPORTING_FINANCE"; key_alias = "app-reporting-finance"; team_id = "team-finance"
       models = @("gemini-flash-lite", "gpt-nano"); max_budget = 0.001; budget_duration = "1d"; rpm_limit = 10
       metadata = @{ application = "reporting-finance"; environment = "demo" } },
    @{ var = "APP_KEY_CODEX_CLI"; key_alias = "app-codex-cli"; team_id = "team-dev"
       models = @("gpt-6-luna", "gpt-nano", "claude-haiku", "gemini-flash-lite"); max_budget = 5; budget_duration = "30d"; rpm_limit = 60
       metadata = @{ application = "codex-cli"; environment = "demo"; usage = "agent de code via la gateway" } }
)

foreach ($a in $apps) {
    if ($keys.ContainsKey($a.var)) {
        try {
            Invoke-Admin GET "/key/info?key=$($keys[$a.var])" | Out-Null
            Write-Host "Clé $($a.key_alias) : déjà présente"; continue
        } catch { }
    }
    $value = New-KeyValue
    $body = @{} + $a; $body.Remove("var"); $body.key = $value
    Invoke-Admin POST "/key/generate" $body | Out-Null
    $keys[$a.var] = $value
    Write-Host "Clé $($a.key_alias) : créée"
}

$out = ($keys.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join "`n"
[IO.File]::WriteAllText($keysFile, "# Virtual keys LiteLLM par application (générées par bootstrap.ps1)`n$out`n", (New-Object Text.UTF8Encoding $false))
Write-Host "Clés applicatives écrites dans .secrets/app-keys.env"
