#!/bin/sh
DB_PASS="$(cat /run/secrets/db_password)" || { echo "failed to read DB_PASS secret" >&2; exit 1; }
export DB_PASS
exec docker-entrypoint.sh node --no-deprecation server
