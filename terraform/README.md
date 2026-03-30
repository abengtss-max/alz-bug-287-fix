# Terraform Fix — ALZ Bug #287

> **For Bicep / PowerShell users**, see the [Bicep solution](../bicep/README.md).

## Overview

This Terraform file creates the 14 missing RBAC role assignments (7 policies × 2 roles) on the Management resource group for Landing Zones DINE policy managed identities.

**What it fixes:** Problem 1 — Missing cross-subscription RBAC (Issue [#287](https://github.com/Azure/Azure-Landing-Zones/issues/287))

> **Note:** This Terraform fix addresses Problem 1 (RBAC) only. If you also have DCR name mismatches (Problem 2), use the [Bicep/PowerShell solution](../bicep/README.md) which handles both problems.

## Prerequisites

- Existing ALZ Terraform Accelerator deployment using `avm-ptn-alz`
- Terraform >= 1.5
- `module.management_groups[0]` — the `avm-ptn-alz` module (provides `policy_assignment_identity_ids`)
- `module.management_resources[0]` — the `avm-ptn-alz-management` module (provides `resource_group.id`)

## Usage

1. Copy `fix.landing-zones-policy-mi-rbac.tf` into your ALZ Terraform Accelerator root module (alongside your existing `.tf` files).

2. If your Landing Zones management group has a different name than `landingzones`, update the local:

   ```hcl
   _landing_zones_mg_name = "your-landing-zones-mg-name"
   ```

3. Plan and apply:

   ```bash
   terraform plan
   terraform apply
   ```

4. Verify 14 role assignments were created (7 policies × 2 roles).

## What Gets Created

| Policy MI | Managed Identity Operator | Monitoring Contributor |
|---|---|---|
| Deploy-VM-Monitoring | ✅ | ✅ |
| Deploy-VM-ChangeTrack | ✅ | ✅ |
| Deploy-VMSS-Monitoring | ✅ | ✅ |
| Deploy-VMSS-ChangeTrack | ✅ | ✅ |
| Deploy-vmHybr-Monitoring | ✅ | ✅ |
| Deploy-vmArc-ChangeTrack | ✅ | ✅ |
| Deploy-MDFC-DefSQL-AMA | ✅ | ✅ |

## Design Decisions

- **No hardcoded principal IDs** — all values come from module outputs, so the fix survives policy MI recreation
- **Static `for_each` keys** — uses policy name strings (not dynamic principal IDs) as map keys, avoiding `Invalid for_each argument` errors
- **Dynamic values only in resource attributes** — the `principal_id` lookup happens inside the resource block, not in `for_each` keys

## Verification

After applying, verify with Azure Resource Graph:

```kusto
authorizationresources
| where type =~ "microsoft.authorization/roleassignments"
| where properties.scope contains "rg-management-"
| where properties.description contains "ALZ bug #287"
| project principalId = tostring(properties.principalId),
          role = tostring(properties.roleDefinitionId),
          description = tostring(properties.description)
| summarize count()
```

Expected result: **14** role assignments.

## Post-Fix: Trigger Remediation

After the RBAC fix is in place, trigger policy remediation to apply DCR associations to existing VMs:

```powershell
# VM Insights DCR association
az policy remediation create --name "remediate-vm-monitoring" `
    --policy-assignment "Deploy-VM-Monitoring" `
    --definition-reference-id "DataCollectionRuleAssociation_Windows" `
    --resource-discovery-mode ReEvaluateCompliance `
    --management-group "landingzones"

# Change Tracking DCR association
az policy remediation create --name "remediate-vm-changetrack" `
    --policy-assignment "Deploy-VM-ChangeTrack" `
    --definition-reference-id "DCRAWindowsVMChangeTrackingAndInventory" `
    --resource-discovery-mode ReEvaluateCompliance `
    --management-group "landingzones"
```
