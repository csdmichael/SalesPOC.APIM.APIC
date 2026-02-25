param(
    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId = "86b37969-9445-49cf-b03f-d8866235171c",

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName = "ai-myaacoub",

    [Parameter(Mandatory = $false)]
    [string]$ApimServiceName = "apim-poc-my",

    [Parameter(Mandatory = $false)]
    [string]$AppServiceName = "salespoc-api",

    [Parameter(Mandatory = $false)]
    [string]$OpenApiUrl = "",

    [Parameter(Mandatory = $false)]
    [string]$ApiDisplayName = "SalesAPI",

    [Parameter(Mandatory = $false)]
    [string]$ApiId = "salesApi",

    [Parameter(Mandatory = $false)]
    [string]$ApiPath = "salesApi",

    [Parameter(Mandatory = $false)]
    [string]$McpServerId = "sales-api-mcp"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host "\n==> $Message" -ForegroundColor Cyan
}

function Command-Exists {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Try-AzRest {
    param(
        [string]$Method,
        [string]$Uri,
        [string]$Body = ""
    )

    try {
        if ([string]::IsNullOrWhiteSpace($Body)) {
            $out = az rest --method $Method --uri $Uri -o json 2>$null
        }
        else {
            $out = az rest --method $Method --uri $Uri --body $Body -o json 2>$null
        }

        if ([string]::IsNullOrWhiteSpace($out)) {
            return $null
        }

        return ($out | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

function Invoke-Az {
    param([scriptblock]$Script)
    & $Script
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI command failed."
    }
}

function Resolve-OpenApiUrl {
    param(
        [string]$AppServiceName,
        [string]$ExplicitUrl
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitUrl)) {
        return $ExplicitUrl
    }

    $candidates = @(
        "https://$AppServiceName.azurewebsites.net/openapi/v1.json",
        "https://$AppServiceName.azurewebsites.net/openapi.json",
        "https://$AppServiceName.azurewebsites.net/swagger/v1/swagger.json",
        "https://$AppServiceName.azurewebsites.net/swagger.json",
        "https://$AppServiceName.azurewebsites.net/v3/api-docs"
    )

    foreach ($candidate in $candidates) {
        try {
            $response = Invoke-WebRequest -Uri $candidate -Method Get -TimeoutSec 20 -UseBasicParsing
            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300) {
                return $candidate
            }
        }
        catch {
            continue
        }
    }

    throw "Could not find an OpenAPI endpoint for App Service '$AppServiceName'. Provide -OpenApiUrl explicitly or expose one of: /openapi/v1.json, /openapi.json, /swagger/v1/swagger.json, /swagger.json, /v3/api-docs"
}

if (-not (Command-Exists "az")) {
    throw "Azure CLI is required."
}

$OpenApiUrl = Resolve-OpenApiUrl -AppServiceName $AppServiceName -ExplicitUrl $OpenApiUrl
Write-Host "Using OpenAPI URL: $OpenApiUrl" -ForegroundColor DarkCyan

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptRoot
$mcpPolicyPath = Join-Path $scriptRoot "mcp-policy.xml"

$apimResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.ApiManagement/service/$ApimServiceName"

Write-Step "Setting Azure subscription"
Invoke-Az { az account set --subscription $SubscriptionId }

Write-Step "Ensuring APIM API '$ApiDisplayName' exists (no overwrite)"
$existingApimApi = $null
try {
    $existingApimApi = az apim api show --resource-group $ResourceGroupName --service-name $ApimServiceName --api-id $ApiId -o json | ConvertFrom-Json
}
catch {
    $existingApimApi = $null
}

if ($null -ne $existingApimApi) {
    Write-Host "APIM API '$ApiId' already exists. Skipping import." -ForegroundColor Yellow
}
else {
    Invoke-Az {
        az apim api import `
            --resource-group $ResourceGroupName `
            --service-name $ApimServiceName `
            --api-id $ApiId `
            --path $ApiPath `
            --display-name $ApiDisplayName `
            --service-url "https://$AppServiceName.azurewebsites.net" `
            --specification-format OpenApiJson `
            --specification-url $OpenApiUrl `
            --api-type http `
            --protocols https `
            --subscription-required false
    }
}

Write-Step "Resolving GET operations for MCP tools"
$operations = az apim api operation list --resource-group $ResourceGroupName --service-name $ApimServiceName --api-id $ApiId -o json | ConvertFrom-Json
$getOps = @($operations | Where-Object { $_.method -eq "GET" } | ForEach-Object {
    if ($_.name) { $_.name }
    elseif ($_.operationId) { $_.operationId }
    else { $null }
} | Where-Object { $_ })

if ($getOps.Count -eq 0) {
    throw "No GET operations found on APIM API '$ApiId'."
}

Write-Host ("GET operations selected as MCP tools: " + ($getOps -join ", "))

Write-Step "Ensuring MCP server exists (no overwrite)"
$mcpServerUriCandidates = @(
    "$apimResourceId/mcpServers/${McpServerId}?api-version=2025-03-01-preview",
    "$apimResourceId/mcpServers/${McpServerId}?api-version=2024-10-01-preview",
    "$apimResourceId/apis/$ApiId/mcpServers/${McpServerId}?api-version=2025-03-01-preview",
    "$apimResourceId/apis/$ApiId/mcpServers/${McpServerId}?api-version=2024-10-01-preview"
)

$existingMcpUri = $null
foreach ($candidate in $mcpServerUriCandidates) {
    $probe = Try-AzRest -Method "GET" -Uri $candidate
    if ($null -ne $probe) {
        $existingMcpUri = $candidate
        break
    }
}

$mcpCreated = $false

if ($null -ne $existingMcpUri) {
    Write-Host "MCP server '$McpServerId' already exists. Skipping creation and policy update." -ForegroundColor Yellow
}
else {
    $mcpPayloadCandidates = @(
        (@{
                properties = @{
                    displayName    = "$ApiDisplayName MCP"
                    description    = "MCP server for $ApiDisplayName exposing GET operations only"
                    apiId          = "/apis/$ApiId"
                    operationNames = $getOps
                }
            } | ConvertTo-Json -Depth 20),
        (@{
                properties = @{
                    title             = "$ApiDisplayName MCP"
                    sourceApiId       = "/apis/$ApiId"
                    toolOperationIds  = $getOps
                }
            } | ConvertTo-Json -Depth 20),
        (@{
                properties = @{
                    apiId      = "/apis/$ApiId"
                    operations = $getOps
                }
            } | ConvertTo-Json -Depth 20)
    )

    foreach ($uri in $mcpServerUriCandidates) {
        foreach ($payload in $mcpPayloadCandidates) {
            $created = Try-AzRest -Method "PUT" -Uri $uri -Body $payload
            if ($null -ne $created) {
                $existingMcpUri = $uri
                $mcpCreated = $true
                break
            }
        }

        if ($mcpCreated) {
            break
        }
    }

    if ($mcpCreated) {
        Write-Host "MCP server '$McpServerId' created." -ForegroundColor Green
    }
    else {
        Write-Warning "Could not create MCP server through ARM/REST in this run. APIM MCP control plane can vary by region/release channel."
        Write-Warning "Manual fallback: create MCP server in APIM portal from API '$ApiId' and select only GET operations as tools."
    }
}

if ($mcpCreated -and (Test-Path $mcpPolicyPath)) {
    Write-Step "Applying MCP policy guardrails (token cap, prompt/hate/harmful checks, rate limiting)"
    $policyXml = Get-Content -Path $mcpPolicyPath -Raw

    $policyUris = @(
        "$apimResourceId/mcpServers/$McpServerId/policies/policy?api-version=2025-03-01-preview",
        "$apimResourceId/mcpServers/$McpServerId/policies/policy?api-version=2024-10-01-preview",
        "$apimResourceId/apis/$ApiId/mcpServers/$McpServerId/policies/policy?api-version=2025-03-01-preview",
        "$apimResourceId/apis/$ApiId/mcpServers/$McpServerId/policies/policy?api-version=2024-10-01-preview"
    )

    $policyBody = @{
        properties = @{
            format = "rawxml"
            value  = $policyXml
        }
    } | ConvertTo-Json -Depth 10

    $policyApplied = $false
    foreach ($policyUri in $policyUris) {
        $policyResult = Try-AzRest -Method "PUT" -Uri $policyUri -Body $policyBody
        if ($null -ne $policyResult) {
            $policyApplied = $true
            break
        }
    }

    if (-not $policyApplied) {
        Write-Warning "MCP server was created but policy update endpoint wasn't resolved automatically. Apply scripts/mcp-policy.xml manually in APIM MCP policy editor."
    }
}

Write-Host "\nDeployment script completed." -ForegroundColor Green
Write-Host "Resources were created only when missing; existing resources were not overwritten." -ForegroundColor Green

exit 0
