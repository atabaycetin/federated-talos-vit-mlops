#!/usr/bin/env bash
# Resume both deployments paused by scripts/pause.sh. See docs/operations.md.
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

# 1. AWS: drop the concurrency limit, back to the account's shared pool.
aws lambda delete-function-concurrency --function-name "$AWS_FUNCTION" --region "$AWS_REGION"

# 2. Azure: reactivate the latest revision, then restore the public endpoint (same URL as before).
REV=$(az containerapp show -n "$AZ_APP" -g "$AZ_RG" --query properties.latestRevisionName -o tsv)
if [ "$(az containerapp revision show -n "$AZ_APP" -g "$AZ_RG" --revision "$REV" --query properties.active -o tsv)" != true ]; then
  az containerapp revision activate -n "$AZ_APP" -g "$AZ_RG" --revision "$REV" -o none
fi
if [ -z "$(az containerapp show -n "$AZ_APP" -g "$AZ_RG" --query properties.configuration.ingress.fqdn -o tsv)" ]; then
  az containerapp ingress enable -n "$AZ_APP" -g "$AZ_RG" --type external --target-port 8000 --transport auto -o none
fi

# 3. CI last: from here on, pushes to main deploy again.
if [ "$(ci_state)" != active ]; then
  gh workflow enable ci.yml -R "$REPO"
fi

echo "Resumed."
echo "Azure:  https://$(az containerapp show -n "$AZ_APP" -g "$AZ_RG" --query properties.configuration.ingress.fqdn -o tsv)/health"
echo "Lambda: $(aws lambda get-function-url-config --function-name "$AWS_FUNCTION" --region "$AWS_REGION" \
  --query FunctionUrl --output text)health"
echo "Expect 200 from /health (the first call is a cold start) and 401 from /predict without the API key."
