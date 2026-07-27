# Wazuh SIEM (single-node)

Sourced from the official `wazuh/wazuh-docker` repo, tag `v4.14.5` (matches CLAUDE.md's
documented pinned version).

**Deliberately NOT committed here** (real secrets, unlike the rest of this directory):
- `.env` (real values for WAZUH_INDEXER_PASSWORD / WAZUH_API_PASSWORD / WAZUH_DASHBOARD_PASSWORD —
  see `.env.example` for the shape; real values are in Vaultwarden, "House of Trae — Gateway VPS"
  folder)
- `config/wazuh_indexer/internal_users.yml` (real bcrypt hashes for the admin/kibanaserver users)
- `config/wazuh_indexer_ssl_certs/` (real private keys, generated fresh per deploy via
  `generate-indexer-certs.yml`)
- `config/wazuh_dashboard/wazuh.yml` here is a template with a placeholder password — the real
  file on sn-security has the actual API password substituted in.

To redeploy from scratch: copy this directory to the target host, run
`docker compose -f generate-indexer-certs.yml run --rm generator`, generate bcrypt hashes for
admin/kibanaserver via `docker run --rm wazuh/wazuh-indexer:4.14.5 bash
/usr/share/wazuh-indexer/plugins/opensearch-security/tools/hash.sh -p '<password>'`, populate
`internal_users.yml` and `wazuh.yml` with the real values, create `.env` from `.env.example`, then
`docker compose up -d`.
