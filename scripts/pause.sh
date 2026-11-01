#!/usr/bin/env bash
# Pause both deployments without deleting anything; undo with scripts/resume.sh.
# Needs: gh, az and aws logged in to the accounts that own the resources. See docs/operations.md.
set -euo pipefail

AZ_RG=${AZ_RG:-talos-rg}
AZ_APP=${AZ_APP:-talos-api}
AWS_REGION=${AWS_REGION:-eu-north-1}
AWS_FUNCTION=${AWS_FUNCTION:-talos-api}
REPO=${REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}
ci_state() {
  gh workflow list -R "$REPO" --all --json path,state \
    --jq '.[] | select(.path == ".github/workflows/ci.yml") | .state'
}

# 1. CI first, so a push or a merged Dependabot PR can't redeploy while (or after) pausing.
if [ "$(ci_state)" = active ]; then
  gh workflow disable ci.yml -R "$REPO"
fi

# 2. Azure: remove the public endpoint, then deactivate the running revision. In an Express-mode
#    environment the app kept serving with ingress disabled; deactivating stops every replica.
if [ -n "$(az containerapp show -n "$AZ_APP" -g "$AZ_RG" --query properties.configuration.ingress.fqdn -o tsv)" ]; then
  az containerapp ingress disable -n "$AZ_APP" -g "$AZ_RG" -o none
fi
for REV in $(az containerapp revision list -n "$AZ_APP" -g "$AZ_RG" --query "[?properties.active].name" -o tsv); do
  az containerapp revision deactivate -n "$AZ_APP" -g "$AZ_RG" --revision "$REV" -o none
done

# 3. AWS: reserved concurrency 0 means no instance may run; the URL answers 429.
aws lambda put-function-concurrency --function-name "$AWS_FUNCTION" --region "$AWS_REGION" \
  --reserved-concurrent-executions 0 --query ReservedConcurrentExecutions --output text >/dev/null

echo "Paused. Azure revisions:"
az containerapp revision list -n "$AZ_APP" -g "$AZ_RG" \
  --query "[].{name:name, active:properties.active, replicas:properties.replicas}" -o table
echo "AWS reserved concurrency: $(aws lambda get-function-concurrency --function-name "$AWS_FUNCTION" \
  --region "$AWS_REGION" --query ReservedConcurrentExecutions --output text)"
echo "CI: $(ci_state)"
