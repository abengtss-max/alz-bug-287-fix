# Terraform Fix — ALZ Bug #287

> **For Bicep / PowerShell users**, see the [Bicep solution](../bicep/README.md).

## Overview

This Terraform fix creates **17 missing role assignments** required for end-to-end Azure Monitor Agent (AMA) ingestion across an ALZ deployment. It addresses the symptoms reported in [Azure/Azure-Landing-Zones#287](https://github.com/Azure/Azure-Landing-Zones/issues/287) and the related "extension installed, zero ingestion" problem.

**Two files, one fix:**

| File | Creates | Solves |
|---|---|---|
| `fix.landing-zones-policy-mi-rbac.tf` | 14 role assignments (7 policies × 2 roles) on the management resource group | `LinkedAuthorizationFailed` during DINE policy remediation (the original #287) |
| `fix.ama-uami-dcr-rbac.tf` | 3 role assignments (AMA UAMI → Monitoring Metrics Publisher) on each DCR | "AMA installed but no Heartbeat / InsightsMetrics / ConfigurationChange in LAW" |

> **Note:** This Terraform fix addresses the cross-subscription RBAC gap only. If you also have DCR name mismatches, use the [Bicep/PowerShell solution](../bicep/README.md).

## Prerequisites

- Existing ALZ Terraform Accelerator deployment using `avm-ptn-alz` and `avm-ptn-alz-management`
- Terraform ≥ 1.5
- Module references in your root module:
  - `module.management_groups[0]` — provides `policy_assignment_identity_ids`
  - `module.management_resources[0]` — provides `resource_group.id`, `data_collection_rule_ids`, `user_assigned_identity_ids`

## Usage

1. Copy **both** files into your ALZ Terraform Accelerator root module (alongside your existing `main.*.tf` files):
   - `fix.landing-zones-policy-mi-rbac.tf`
   - `fix.ama-uami-dcr-rbac.tf`

2. If your Landing Zones management group has a different name than `landingzones`, edit the local in `fix.landing-zones-policy-mi-rbac.tf`:
   ```hcl
   _landing_zones_mg_name = "your-landing-zones-mg-name"
   ```

3. If your DCR keys differ from the defaults, edit the local in `fix.ama-uami-dcr-rbac.tf`:
   ```hcl
   _ama_dcr_keys = toset(["change_tracking", "defender_sql", "vm_insights"])
   ```
   These keys must match the keys in `management_resource_settings.data_collection_rules` in your tfvars.

4. Plan and apply (locally or via your CI pipeline):
   ```bash
   terraform plan
   terraform apply
   ```

5. Expected plan output: **17 to add, 0 to change, 0 to destroy** (all `azurerm_role_assignment`).

## What Gets Created

### 14 cross-subscription RBAC assignments on the management RG

| Policy MI | Managed Identity Operator | Monitoring Contributor |
|---|:---:|:---:|
| Deploy-VM-Monitoring        | ✅ | ✅ |
| Deploy-VM-ChangeTrack       | ✅ | ✅ |
| Deploy-VMSS-Monitoring      | ✅ | ✅ |
| Deploy-VMSS-ChangeTrack     | ✅ | ✅ |
| Deploy-vmHybr-Monitoring    | ✅ | ✅ |
| Deploy-vmArc-ChangeTrack    | ✅ | ✅ |
| Deploy-MDFC-DefSQL-AMA      | ✅ | ✅ |

### 3 AMA UAMI assignments on each DCR

| DCR | Role |
|---|---|
| dcr-vm-insights      | Monitoring Metrics Publisher |
| dcr-change-tracking  | Monitoring Metrics Publisher |
| dcr-defender-sql     | Monitoring Metrics Publisher |

## Design Decisions

- **No hardcoded principal IDs** — all values come from module outputs, so the fix survives policy MI / UAMI recreation.
- **Static `for_each` keys** — uses policy name strings as map keys (not dynamic principal IDs), avoiding `Invalid for_each argument` errors.
- **Dynamic values only in resource attributes** — the `principal_id` lookup happens inside the resource block.
- **Least-privilege scopes** — DCR role assignments are scoped to each individual DCR resource, not the RG.
- **Idempotent** — re-applying does nothing if the assignments already exist in state.

## Verification

> Replace placeholders with values from your environment:
>
> - `<MGMT_SUB_ID>` — your management subscription ID
> - `<MGMT_RG>` — typically `rg-management-<region>` (e.g., `rg-management-uksouth`)
> - `<LAW_NAME>` — typically `law-management-<region>`
> - `<UAMI_NAME>` — typically `uami-management-ama-<region>`
> - `<LZ_MG>` — typically `landingzones`

### Step 1 — Quick count (should be 17)

```powershell
az login
az account set --subscription <MGMT_SUB_ID>

$mgmtRg = "/subscriptions/<MGMT_SUB_ID>/resourceGroups/<MGMT_RG>"
$dcrs   = @("dcr-vm-insights","dcr-change-tracking","dcr-defender-sql")

$rgCount = (az role assignment list --scope $mgmtRg `
  --query "[?contains(description, 'ALZ bug #287')].id" -o tsv | Measure-Object).Count

$dcrCount = 0
foreach ($d in $dcrs) {
  $scope = "$mgmtRg/providers/Microsoft.Insights/dataCollectionRules/$d"
  $dcrCount += (az role assignment list --scope $scope `
    --query "[?contains(description, 'AMA UAMI fix')].id" -o tsv | Measure-Object).Count
}

Write-Host "RG-scope  (expect 14): $rgCount"
Write-Host "DCR-scope (expect 3) : $dcrCount"
Write-Host "TOTAL     (expect 17): $($rgCount + $dcrCount)"
```

### Step 2 — Inspect the 14 RG-scope assignments

```powershell
az role assignment list --scope $mgmtRg `
  --query "[?contains(description, 'ALZ bug #287')].{policy:description, role:roleDefinitionName, principal:principalId}" `
  -o table
```
Expect 7 policies × 2 roles = 14 rows (Managed Identity Operator + Monitoring Contributor for each policy).

### Step 3 — Inspect the 3 DCR-scope assignments

```powershell
foreach ($d in $dcrs) {
  $scope = "$mgmtRg/providers/Microsoft.Insights/dataCollectionRules/$d"
  Write-Host "`n=== $d ===" -ForegroundColor Cyan
  az role assignment list --scope $scope `
    --query "[?roleDefinitionName=='Monitoring Metrics Publisher'].{role:roleDefinitionName, principal:principalId, desc:description}" `
    -o table
}
```
The `principal` value should match the AMA UAMI:
```powershell
az identity show -g <MGMT_RG> -n <UAMI_NAME> --query principalId -o tsv
```

### Step 4 — Single Resource Graph query (whole picture)

```powershell
az graph query -q @"
authorizationresources
| where type =~ 'microsoft.authorization/roleassignments'
| where properties.scope contains '<MGMT_RG>'
| where tostring(properties.description) contains 'ALZ bug #287'
   or tostring(properties.description) contains 'AMA UAMI fix'
| summarize count() by description = tostring(properties.description)
"@ -o table
```
Sum across all rows should equal **17**.

### Step 5 — Azure Portal (visual)

- Open `<MGMT_RG>` → **Access control (IAM)** → **Role assignments** → filter "Description contains: `ALZ bug #287`" → expect **14** entries.
- Open each DCR (`dcr-vm-insights`, `dcr-change-tracking`, `dcr-defender-sql`) → **Access control (IAM)** → **Role assignments** → expect **1** entry per DCR with role `Monitoring Metrics Publisher` and the AMA UAMI as principal.

## Post-Fix: Trigger Remediation

RBAC alone doesn't retroactively associate already-deployed VMs. Trigger remediation for each of the 7 DINE policies:

```powershell
$lzPolicies = @(
  "Deploy-VM-Monitoring","Deploy-VM-ChangeTrack",
  "Deploy-VMSS-Monitoring","Deploy-VMSS-ChangeTrack",
  "Deploy-vmHybr-Monitoring","Deploy-vmArc-ChangeTrack",
  "Deploy-MDFC-DefSQL-AMA"
)
foreach ($p in $lzPolicies) {
  az policy remediation create `
    --name "remediate-$($p.ToLower())-$(Get-Date -Format 'yyyyMMddHHmm')" `
    --policy-assignment $p `
    --resource-discovery-mode ReEvaluateCompliance `
    --management-group <LZ_MG> | Out-Null
  Write-Host "Triggered remediation: $p"
}
```

After ~10 minutes, check status:
```powershell
az policy remediation list --management-group <LZ_MG> `
  --query "[?starts_with(name, 'remediate-')].{name:name, state:provisioningState, ok:deploymentStatus.successfulDeployments, failed:deploymentStatus.failedDeployments}" `
  -o table
```
Expect `failed = 0`. Any non-zero failure with `LinkedAuthorizationFailed` means a role assignment is still missing.

## Functional Verification — ingestion in Log Analytics

Final proof that AMA can authenticate and push telemetry through the DCR pipeline. Run after a target VM has been remediated:

```powershell
$wsId = az monitor log-analytics workspace show `
  -g <MGMT_RG> -n <LAW_NAME> --query customerId -o tsv

# Heartbeat — proves AMA can authenticate and push
az monitor log-analytics query --workspace $wsId `
  --analytics-query "Heartbeat | where TimeGenerated > ago(15m) | summarize last_seen=max(TimeGenerated) by Computer" -o table

# VM Insights DCR pipeline working
az monitor log-analytics query --workspace $wsId `
  --analytics-query "InsightsMetrics | where TimeGenerated > ago(15m) | take 5" -o table

# Change Tracking DCR pipeline working
az monitor log-analytics query --workspace $wsId `
  --analytics-query "ConfigurationChange | where TimeGenerated > ago(1h) | take 5" -o table
```
Non-empty results = end-to-end success.

## Troubleshooting

| Symptom | Likely cause | Action |
|---|---|---|
| Plan shows fewer than 17 to add | A role assignment already exists from a prior fix attempt | Inspect `terraform state list` for `azurerm_role_assignment`; either accept the smaller delta or `terraform import` the existing ones |
| Plan shows destroys | You're applying in the wrong module / wrong workspace | Stop. Confirm `terraform workspace show` and the backend config |
| `Invalid for_each argument` | Static-key contract violated by a copy/paste edit | Don't put dynamic values in `for_each` keys; only in the resource body |
| Remediation still returns `LinkedAuthorizationFailed` | Role assignment didn't propagate yet | Wait 5 min for AAD propagation, then re-trigger remediation |
| Heartbeat empty after remediation succeeded | `Monitoring Metrics Publisher` missing on a DCR | Re-run Verification Step 3 |

## Cleanup / Removal

When the upstream fix lands in your accelerator version (track [PR #312](https://github.com/Azure/alz-terraform-accelerator/pull/312)):

```bash
rm fix.landing-zones-policy-mi-rbac.tf
rm fix.ama-uami-dcr-rbac.tf
terraform plan   # expect 17 to destroy
terraform apply
```

The upstream module will then create equivalent assignments with module-managed names.
