#!/bin/sh
set -e
cd /data
if [ ! -f /data/.runner ]; then
  /bin/forgejo-runner register \
    --no-interactive \
    --instance "${FORGEJO_INSTANCE_URL}" \
    --token "$(cat /run/secrets/forgejo_runner_token)" \
    --name "${FORGEJO_RUNNER_NAME}" \
    --labels "${FORGEJO_RUNNER_LABELS}" \
    --config /etc/forgejo-runner/config.yaml
fi
exec /bin/forgejo-runner daemon --config /etc/forgejo-runner/config.yaml
