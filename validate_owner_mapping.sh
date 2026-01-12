#!/usr/bin/env bash
set -euo pipefail

# Requer: psql, jq, e variáveis de ambiente PGHOST/PGPORT/PGDATABASE/PGUSER/PGPASSWORD ou ~/.pgpass
# Uso: ./validate_owner_mapping.sh
# Opcional: passa uma connection string como primeiro argumento:
# ./validate_owner_mapping.sh "host=... port=... dbname=... user=... password=..."

DB_CONN=${1:-"host=${PGHOST:-} port=${PGPORT:-} dbname=${PGDATABASE:-} user=${PGUSER:-} password=${PGPASSWORD:-}"}

# Quick check for required tools
command -v psql >/dev/null 2>&1 || { echo "psql is required"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq is required"; exit 2; }

# Export owners from DB
owners_in_db=$(psql "$DB_CONN" -t -A -c "
  select distinct owner
  from app.edge_functions_registry
  where uses_service_role = true
    and audit_last_review is null
  order by owner;
")

if [ -z "$owners_in_db" ]; then
  echo "No owners found for review — nothing to validate."
  exit 0
fi

# Read mapping keys from JSON
if [ ! -f ".github/compliance-owner-map.json" ]; then
  echo "ERROR: .github/compliance-owner-map.json not found in repo root."
  exit 2
fi

owners_in_map=$(jq -r 'keys[]' .github/compliance-owner-map.json | sort || true)

# Compute difference: owners present in DB but missing in map
missing=$(comm -23 <(printf '%s\n' $owners_in_db | sort) <(printf '%s\n' $owners_in_map | sort) || true)

if [ -z "$missing" ]; then
  echo "OK — all owners present in the mapping JSON."
  exit 0
else
  echo "MISSING OWNERS in .github/compliance-owner-map.json:"
  printf '%s\n' "$missing"
  echo ""
  echo "Please add the missing owner keys (map to one or more GitHub usernames) before merging."
  exit 3
fi
