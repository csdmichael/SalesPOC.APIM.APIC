# SalesPOC APIM + API Center Deployment Repo

This repo deploys and configures the following Azure resources in an idempotent way:

- API Management: `/subscriptions/86b37969-9445-49cf-b03f-d8866235171c/resourceGroups/ai-myaacoub/providers/Microsoft.ApiManagement/service/apim-poc-my`
- API Center: `/subscriptions/86b37969-9445-49cf-b03f-d8866235171c/resourceGroups/ai-myaacoub/providers/Microsoft.ApiCenter/services/api-center-poc-my`

## What it configures

1. **APIM API**
   - Ensures an API named `SalesPOC-API` exists in APIM.
   - Imports from App Service OpenAPI endpoint only if missing.

2. **APIM MCP Server**
   - Attempts to create MCP server from `SalesPOC-API`.
   - Exposes **GET operations only** as MCP tools.
   - Applies MCP guardrail policy only when MCP server is newly created:
     - request size cap (token-budget proxy)
     - prompt-injection pattern checks
     - harmful/hate pattern checks
     - rate limit + quota

3. **API Center Environment + APIM Integration**
   - Ensures a `production` environment exists in API Center.
   - Ensures APIM integration exists and targets that environment.

4. **API Center API registration**
   - Ensures API `SalesPOC-API` exists in API Center with:
     - version `v1`
     - definition `openapi`
     - deployment `production`

5. **API analysis ruleset**
   - Creates analyzer config `CustomRulesetPOC` (config id: `customrulesetpoc`) if missing.
   - Imports custom Spectral ruleset from `scripts/spectral/CustomRulesetPOC`.
   - Ruleset extends `spectral:oas` and turns off rule `oas3-schema` to avoid blocking date-in-string validation constraints.

## Non-overwrite behavior

This repo is designed to **not overwrite existing resources**:

- If a target resource/config already exists, the script logs and skips it.
- Existing APIM/API Center resources are not replaced.
- Existing analyzer config is not re-imported.

## GitHub Actions workflow

Workflow file: `.github/workflows/deploy-to-azure.yml`

### Required GitHub secret

Set `AZURE_CREDENTIALS` in your GitHub repo secrets with a service principal JSON from:

```bash
az ad sp create-for-rbac \
  --name "github-salespoc-apim-apic" \
  --role Contributor \
  --scopes /subscriptions/86b37969-9445-49cf-b03f-d8866235171c/resourceGroups/ai-myaacoub \
  --sdk-auth
```

## Run locally

```powershell
pwsh ./scripts/deploy.ps1
```

Optional: pass parameters to override defaults.

## Notes

- APIM MCP control-plane endpoints can vary by API version/release channel. The script tries multiple known preview endpoints.
- If MCP creation cannot be resolved via automation in your tenant/region, the script prints a manual fallback.
