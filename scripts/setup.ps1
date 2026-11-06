<#
  Démarre la stack LLM Gateway de démo.
  - Génère .env (secrets aléatoires) au premier lancement
  - docker compose up -d
  - Attend que Keycloak et LiteLLM soient prêts
  - Lance le bootstrap (équipes, budgets, clés par application)
#>
param([switch]$InitOnly)   # -InitOnly : génère seulement .env, sans démarrer la stack
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

function New-Secret([int]$bytes = 24) {
    $b = New-Object byte[] $bytes
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
    return ([Convert]::ToBase64String($b)).TrimEnd('=').Replace('+', 'A').Replace('/', 'B')
}

$envFile = Join-Path $root ".env"
if (-not (Test-Path $envFile)) {
    Write-Host "Génération de .env avec des secrets aléatoires..."
    $content = @"
# Généré par scripts/setup.ps1 - NE PAS COMMITTER
POSTGRES_PASSWORD=$(New-Secret)
LITELLM_DB_PASSWORD=$(New-Secret)
KEYCLOAK_DB_PASSWORD=$(New-Secret)

# Clé maître LiteLLM (doit commencer par sk-) et clé de chiffrement des credentials en base
LITELLM_MASTER_KEY=sk-master-$(New-Secret)
LITELLM_SALT_KEY=sk-salt-$(New-Secret 32)

# Login de secours de l'UI LiteLLM (/ui) si le SSO est indisponible
UI_USERNAME=admin
UI_PASSWORD=$(New-Secret 12)

# Keycloak : console d'admin (utilisateur 'admin') sur http://localhost:8080
KEYCLOAK_ADMIN_PASSWORD=$(New-Secret 12)
# Secret du client OIDC litellm-ui
LITELLM_OIDC_CLIENT_SECRET=$(New-Secret 32)
# Mot de passe commun des utilisateurs de démo du realm llm-gateway
DEMO_USERS_PASSWORD=Demo-$(New-Secret 8)
# Secret commun des clients machine-to-machine (app-*)
APP_CLIENTS_SECRET=$(New-Secret 32)

OLLAMA_MODEL=qwen2.5:0.5b

# Clés fournisseurs : à renseigner ici (ou en variables d'environnement Windows)
OPENAI_DEMO_LLM_KEY=
ANTHROPIC_DEMO_LLM_KEY=
GEMINI_DEMO_LLM_KEY=
"@
    [IO.File]::WriteAllText($envFile, $content.Replace("`r`n", "`n"), (New-Object Text.UTF8Encoding $false))
    Write-Host ".env créé."
}

# Contrôle de présence des clés fournisseurs (sans jamais les afficher)
$envText = Get-Content $envFile -Raw
foreach ($k in "OPENAI_DEMO_LLM_KEY", "ANTHROPIC_DEMO_LLM_KEY", "GEMINI_DEMO_LLM_KEY") {
    $inFile = $envText -match "(?m)^$k=\S+"
    $inEnv = [bool][Environment]::GetEnvironmentVariable($k)
    if (-not ($inFile -or $inEnv)) { Write-Warning "$k absente : le modèle correspondant échouera (à renseigner dans .env)." }
}
if ($InitOnly) { Write-Host "Mode -InitOnly : stack non démarrée."; return }

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    $env:Path += ";C:\Program Files\Docker\Docker\resources\bin"
}
# Docker écrit sa progression sur stderr : sous PowerShell 5.1 ça ne doit pas être fatal
$ErrorActionPreference = "Continue"
docker info --format "{{.ServerVersion}}" 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Docker n'est pas démarré. Lance Docker Desktop puis relance ce script." }

Write-Host "Démarrage de la stack (le premier lancement télécharge les images, quelques minutes)..."
docker compose up -d --quiet-pull
if ($LASTEXITCODE -ne 0) { throw "docker compose up a échoué (voir: docker compose logs)" }
$ErrorActionPreference = "Stop"

function Wait-Url([string]$url, [string]$name, [int]$timeoutSec = 600) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    Write-Host -NoNewline "Attente de $name "
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 5
            if ($r.StatusCode -eq 200) { Write-Host " OK"; return }
        } catch { }
        Write-Host -NoNewline "."
        Start-Sleep -Seconds 5
    }
    throw "$name n'a pas répondu à temps ($url). Voir: docker compose logs"
}

Wait-Url "http://localhost:8080/realms/llm-gateway/.well-known/openid-configuration" "Keycloak"
Wait-Url "http://localhost:4000/health/liveliness" "LiteLLM"

& (Join-Path $PSScriptRoot "bootstrap.ps1")

Write-Host ""
Write-Host "==================== PRÊT ===================="
Write-Host " LiteLLM API       : http://localhost:4000"
Write-Host " LiteLLM UI (SSO)  : http://localhost:4000/ui"
Write-Host " Keycloak console  : http://localhost:8080/admin  (user: admin)"
Write-Host " Secrets           : .env  et  .secrets/app-keys.env"
Write-Host "=============================================="
