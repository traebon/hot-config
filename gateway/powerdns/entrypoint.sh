#!/bin/sh
set -e

POSTGRES_PASSWORD=$(cat /run/secrets/postgres_password)
PDNS_API_KEY=$(cat /run/secrets/pdns_api_key)

sed \
  -e "s/__POSTGRES_PASSWORD__/${POSTGRES_PASSWORD}/g" \
  -e "s/__PDNS_API_KEY__/${PDNS_API_KEY}/g" \
  /etc/powerdns/pdns.conf.template > /tmp/pdns.conf

echo "Config generated. Starting PowerDNS..."

exec pdns_server --config-dir=/tmp --config-name=""
