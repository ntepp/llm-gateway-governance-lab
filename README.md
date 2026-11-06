# LLM Gateway — démo LiteLLM + Keycloak (Docker)

Stack locale pour montrer, en conditions réelles, ce qu'une **LLM Gateway** apporte en **sécurité**, **gouvernance** et **maîtrise des coûts** : un point d'entrée unique compatible OpenAI devant plusieurs fournisseurs et un modèle local, avec SSO, droits par équipe, budgets, filtrage des données personnelles et règles AI Act.

## Architecture

```
 Navigateur ──SSO OIDC──► Keycloak :8080  (realm llm-gateway, groupes = équipes)
     │                        ▲
     ▼                        │ back-channel (token, userinfo)
 LiteLLM UI /ui ◄──────── LiteLLM Proxy :4000 ──► Ollama (local-qwen, on-prem)
                              │   │           ──► OpenAI    gpt-5-nano, gpt-6-luna
 Applications ─virtual key──► │   │           ──► Anthropic claude-haiku-5-5
 Codex CLI    ─virtual key──► │   │           ──► Google    gemini-3.1-flash-lite
                              ▼   ▼
                         PostgreSQL  Redis (cache, quotas partagés)
```

| Service | Rôle |
|---|---|
| LiteLLM Proxy | gateway compatible OpenAI, clés virtuelles, budgets, guardrails, journal des coûts |
| Keycloak | SSO OIDC de la console ; groupes → équipes, attribut → rôle LiteLLM |
| PostgreSQL | équipes, clés, dépenses (une base et un compte par service) |
| Redis | cache de réponses, quotas partagés |
| Ollama | modèle local `qwen2.5:0.5b` pour les données sensibles |

## Prérequis

- Docker Desktop (backend WSL 2) et PowerShell 5.1+ (scripts écrits pour Windows).
- Clés API fournisseurs (facultatives : un modèle sans clé échoue, les autres fonctionnent) :
  `OPENAI_DEMO_LLM_KEY`, `ANTHROPIC_DEMO_LLM_KEY`, `GEMINI_DEMO_LLM_KEY`, dans `.env` ou en variables d'environnement.

## Démarrage

```powershell
.\scripts\setup.ps1 -InitOnly   # génère .env avec des secrets aléatoires (y ajouter les clés fournisseurs si besoin)
.\scripts\setup.ps1             # démarre la stack, crée équipes, budgets et clés virtuelles
.\scripts\smoke-test.ps1        # rejoue les scénarios de gouvernance
.\scripts\pii-test.ps1          # rejoue les scénarios de protection des données
```

Avant une démo : `.\scripts\prepare-demo.ps1` (santé de la stack, remise à zéro du budget finance, préchauffage du modèle local).

Arrêt : `docker compose down` · Remise à zéro complète : `docker compose down -v`, puis supprimer `.env` et `.secrets/`.

> `.env` et `.secrets/` sont générés localement et **ne doivent jamais être commités** (ils sont dans `.gitignore`).

## Accès

| Quoi | URL | Identifiants |
|---|---|---|
| API compatible OpenAI | http://localhost:4000/v1 | clés virtuelles dans `.secrets/app-keys.env` |
| Console LiteLLM (SSO) | http://localhost:4000/ui | utilisateurs ci-dessous, mot de passe `DEMO_USERS_PASSWORD` du `.env` |
| Console LiteLLM (secours) | http://localhost:4000/fallback/login | `UI_USERNAME` / `UI_PASSWORD` du `.env` |
| Console Keycloak | http://localhost:8080/admin | `admin` / `KEYCLOAK_ADMIN_PASSWORD` du `.env` |

### Utilisateurs Keycloak (realm `llm-gateway`)

| Utilisateur | Groupe → équipe LiteLLM | Rôle LiteLLM |
|---|---|---|
| admin.platform | — | proxy_admin |
| alice.dev | team-dev | internal_user |
| bob.rh | team-rh | internal_user |
| carla.finance | team-finance | internal_user_viewer |

### Équipes et applications

| Équipe | Modèles autorisés | Budget équipe | Applications (clé virtuelle, plafond) |
|---|---|---|---|
| team-dev | gpt-nano, gpt-6-luna, claude-haiku, gemini-flash-lite, local-qwen | 50 $ / 30 j | app-copilot-dev (20 $), app-codex-cli (5 $) |
| team-rh | **local-qwen uniquement** (données sensibles) | 5 $ / 30 j | app-chatbot-rh (5 $) |
| team-finance | gemini-flash-lite, gpt-nano | 1 $ / jour | app-reporting-finance (**0,001 $ / jour**, démo de dépassement) |

## Modèles

| Nom gateway | Modèle fournisseur | Clé | Prix / M tokens (entrée / sortie) |
|---|---|---|---|
| `gpt-nano` | openai/gpt-5-nano | OPENAI_DEMO_LLM_KEY | 0,05 $ / 0,40 $ |
| `gpt-6-luna` | openai/gpt-6-luna | OPENAI_DEMO_LLM_KEY | 0,10 $ / 0,50 $ |
| `claude-haiku` | anthropic/claude-haiku-5-5 | ANTHROPIC_DEMO_LLM_KEY | 0,10 $ / 0,50 $ |
| `gemini-flash-lite` | gemini/gemini-3.1-flash-lite | GEMINI_DEMO_LLM_KEY | 0,25 $ / 1,50 $ |
| `local-qwen` | ollama qwen2.5:0.5b | — | 0 (on-prem) |

Prix issus de la table de coûts LiteLLM (novembre 2026), à vérifier sur les grilles officielles.
Bascule automatique entre fournisseurs : `gpt-nano → gemini-flash-lite → claude-haiku`.

## Scénarios de démo

| Scénario | Commande | Résultat attendu |
|---|---|---|
| Une API, quatre modèles | `smoke-test.ps1` | réponses de OpenAI, Anthropic, Google et du local, avec le coût de chaque appel |
| SSO | console `/ui`, compte `alice.dev` | équipe et rôle repris de Keycloak |
| Moindre privilège | `smoke-test.ps1` | chatbot RH vers un modèle cloud : **403** |
| Budget | `smoke-test.ps1` | appli finance : 1er appel accepté, suivants **422** |
| Bascule silencieuse | clé fournisseur invalide | la réponse vient d'un autre fournisseur (en-tête `x-litellm-attempted-fallbacks`) |
| Données personnelles | `pii-test.ps1` | e-mail et téléphone masqués vers le cloud, NIR / IBAN / carte / clé AWS bloqués (**400**) |
| AI Act art. 5 | `pii-test.ps1` | « notation sociale » bloquée sur tous les modèles, local compris |

## Protection des données (RGPD) et AI Act

| Guardrail | Portée | Règles | Action |
|---|---|---|---|
| `pii-rgpd-cloud` | **modèles cloud uniquement** (attaché par modèle) | e-mail, téléphone FR (avec ou sans séparateurs) | **MASK** (`[EMAIL_REDACTED]`…) |
| | | NIR, IBAN, carte bancaire, passeport FR, clés AWS, tokens GitHub | **BLOCK** (HTTP 400) |
| `ai-act-art5` | **global**, tous modèles | pratiques interdites de l'article 5 (FR + EN) | **BLOCK** |

Le modèle local n'est pas filtré pour les données personnelles : la donnée ne quitte pas le périmètre.

Constats :
- Les règles fournies (`fr_phone`, `fr_nir`, `iban`) ne reconnaissent que les formats **sans espaces** : des expressions régulières ont été ajoutées pour les formats réels.
- Les expressions régulières ne détectent pas les **noms de personnes** (il faut un moteur de reconnaissance d'entités).
- En open source, les guardrails **par clé ou par équipe** sont réservés à la version Enterprise ; restent disponibles le global (`default_on`) et le **par modèle**.

## Codex CLI via la gateway

1. Installer Codex : `winget install OpenAI.Codex`.
2. Copier `codex/config.example.toml` vers `%USERPROFILE%\.codex\config.toml` (et `codex/claude.config.example.toml` vers `%USERPROFILE%\.codex\claude.config.toml` pour le profil Claude).
3. Placer la clé virtuelle `APP_KEY_CODEX_CLI` de `.secrets/app-keys.env` dans la variable d'environnement `LITELLM_CODEX_KEY`.
4. `codex` utilise `gpt-6-luna` ; `codex --profile claude` utilise Claude Haiku. Les dépenses apparaissent sur la clé `app-codex-cli` dans la console LiteLLM.

## Limites de LiteLLM open source rencontrées

- SSO de la console : gratuit jusqu'à **5 utilisateurs**.
- Authentification des **applications par jeton OIDC** (JWT) : réservée à la version Enterprise ; les applications utilisent des clés virtuelles. Les clients `app-*` (client_credentials) sont déclarés dans Keycloak pour une éventuelle passerelle d'échange de jeton.
- Guardrails par clé ou par équipe : Enterprise.

## Arborescence

```
docker-compose.yml        stack complète
litellm/config.yaml       modèles, guardrails, routage, cache
keycloak/realm-*.json     realm importé au démarrage (secrets injectés depuis .env)
postgres/init-*.sh        une base et un compte par service
scripts/                  setup, bootstrap, smoke-test, pii-test, prepare-demo
codex/                    exemples de configuration Codex CLI
```
