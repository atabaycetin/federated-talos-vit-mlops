# Operations: pausing and resuming the deployments

The service runs in two places: **Azure Container Apps** (deployed by CI on every push to `main`) and **AWS Lambda** (deployed by hand). Both can be switched off **without deleting anything**, so they cost nothing while paused and come back with the same configuration, API keys and URLs.

```bash
scripts/pause.sh    # CI off, Azure revision deactivated, Lambda concurrency 0
scripts/resume.sh   # the reverse, then prints the health-check URLs
```

Both scripts need `gh`, `az` and `aws` logged in to the accounts that own the resources. Running them as anyone else fails with an authorization error: the commands name resources, they don't grant access to them. Resource names default to `talos-rg` / `talos-api` (Azure) and `talos-api` in `eu-north-1` (AWS); override them with `AZ_RG`, `AZ_APP`, `AWS_FUNCTION`, `AWS_REGION`.

## Pause, step by step

| step | command | what it does |
|---|---|---|
| 1. CI | `gh workflow disable ci.yml` | Stops every workflow run, so a push or a merged Dependabot PR can't redeploy to Azure. The workflow, secrets and variables are kept. |
| 2. Azure endpoint | `az containerapp ingress disable -n talos-api -g talos-rg` | Removes the public HTTPS endpoint from the app's configuration. |
| 3. Azure revision | `az containerapp revision deactivate -n talos-api -g talos-rg --revision <revision>` | Stops all replicas of the running revision and takes it out of traffic. Needed because in an **Express-mode** environment the app kept serving requests with ingress disabled. |
| 4. AWS | `aws lambda put-function-concurrency --function-name talos-api --reserved-concurrent-executions 0` | Allows zero concurrent instances: every call is rejected with `429` before the code runs, and nothing is billed. |

What stays, at no cost: the Container Apps environment, the deploy identity, the Lambda function and its Function URL, its IAM role, and the image in ECR (within the free storage).

Check that it's paused:
- **Azure:** the revision shows `active: False` with 0 replicas, and the old URL no longer returns `200`.
- **AWS:** `GET <function-url>/health` returns `429`.
- **CI:** `gh workflow list --all` shows `ci` as `disabled_manually`.

## Resume, step by step

| step | command | what it does |
|---|---|---|
| 1. AWS | `aws lambda delete-function-concurrency --function-name talos-api` | Removes the limit; the function uses the account's shared concurrency pool again. |
| 2. Azure revision | `az containerapp revision activate -n talos-api -g talos-rg --revision <latest revision>` | Brings the revision back into service. |
| 3. Azure endpoint | `az containerapp ingress enable -n talos-api -g talos-rg --type external --target-port 8000 --transport auto` | Restores the public endpoint, with the same hostname as before. |
| 4. CI | `gh workflow enable ci.yml` | Re-enables CI last, so pushes to `main` deploy again only once everything is up. |

The first request after resuming is a cold start: about 5 s on Azure and about 25 s on Lambda at 512 MB. Expect `200` from `/health` and `401` from `/predict` without the `X-API-Key` header.

## Deleting for good

Pausing keeps everything for later. To remove the deployments entirely:

- **Azure:** everything lives in one resource group, so delete the group (`az group delete -n talos-rg --yes`), then remove the repository variable `AZURE_CONTAINERAPP_NAME` so CI skips the deploy job.
- **AWS:** delete the function, its log group (`/aws/lambda/talos-api`, which isn't removed with the function), the ECR repository (`--force` deletes its images too), and detach and delete the `talos-lambda` role.

Also note that both accounts have end dates of their own: Azure for Students credit and AWS's Free plan each expire, after which the provider disables the resources unless the account is upgraded.
