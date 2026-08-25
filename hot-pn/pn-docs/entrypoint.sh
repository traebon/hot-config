#!/bin/sh
export DB_PASS="$(cat /run/secrets/db_password)"
exec docker-entrypoint.sh node --no-deprecation server
