#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PAYLOAD_SRC="${PAYLOAD_SRC:-$ROOT_DIR/system-bootstrap}"
DEPLOY_SCRIPT="$ROOT_DIR/overlay/airootfs/usr/local/bin/deploy-1to1.sh"

required_payload_files=(
  "scripts/install-all.sh"
  "scripts/restore-audit.sh"
  "scripts/resolve-adaptive-layers.sh"
  "scripts/verify-target-matrix.sh"
  "manifests/enabled-system-units.txt"
)

for rel_path in "${required_payload_files[@]}"; do
  if [[ ! -e "$PAYLOAD_SRC/$rel_path" ]]; then
    echo "Missing required payload file: $PAYLOAD_SRC/$rel_path" >&2
    exit 1
  fi
done

grep -q '/root/system-bootstrap/scripts/install-all.sh' "$DEPLOY_SCRIPT" || {
  echo "deploy-1to1.sh is not delegating restore to shared install-all.sh" >&2
  exit 1
}

grep -q '/root/system-bootstrap/scripts/restore-audit.sh' "$DEPLOY_SCRIPT" || {
  echo "deploy-1to1.sh is not delegating audit to shared restore-audit.sh" >&2
  exit 1
}

grep -q 'enabled-system-units.txt' "$DEPLOY_SCRIPT" || {
  echo "deploy-1to1.sh is not wired to the shared enabled-system-units manifest" >&2
  exit 1
}

if grep -q 'SERVICES_MANIFEST="/root/system-bootstrap/manifests/enabled-services.txt"' "$DEPLOY_SCRIPT"; then
  echo "deploy-1to1.sh still embeds the legacy enabled-services-only audit path" >&2
  exit 1
fi

echo "verify-platform-bridge ok"
