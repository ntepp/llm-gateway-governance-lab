#!/bin/sh
# Crée une base + un utilisateur dédiés par service (principe du moindre privilège).
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<EOSQL
CREATE USER litellm WITH PASSWORD '${LITELLM_DB_PASSWORD}';
CREATE DATABASE litellm OWNER litellm;
CREATE USER keycloak WITH PASSWORD '${KEYCLOAK_DB_PASSWORD}';
CREATE DATABASE keycloak OWNER keycloak;
EOSQL
