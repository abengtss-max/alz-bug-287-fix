# ALZ Bug #287 Fix — Cross-Subscription RBAC for Landing Zones DINE Policy Managed Identities

## The Bug

**GitHub Issue:** [Azure/Azure-Landing-Zones#287](https://github.com/Azure/Azure-Landing-Zones/issues/287)

When deploying the Azure Landing Zone (ALZ) using the Terraform Accelerator (`avm-ptn-alz`), several **DINE (DeployIfNotExists)** policies are assigned at the **Landing Zones** management group. These policies handle Azure Monitor Agent (AMA) deployment, Change Tracking, and Microsoft Defender for SQL AMA:

| Policy Assignment | Purpose |
|---|---|
| `Deploy-VM-Monitoring` | Deploy AMA and DCR association on VMs |
| `Deploy-VM-ChangeTrack` | Deploy Change Tracking extension on VMs |
| `Deploy-VMSS-Monitoring` | Deploy AMA and DCR association on VMSS |
| `Deploy-VMSS-ChangeTrack` | Deploy Change Tracking extension on VMSS |
| `Deploy-vmHybr-Monitoring` | Deploy AMA on Azure Arc hybrid machines |
| `Deploy-vmArc-ChangeTrack` | Deploy Change Tracking on Azure Arc machines |
| `Deploy-MDFC-DefSQL-AMA` | Deploy Microsoft Defender for SQL AMA |

Each of these policy assignments creates a **system-assigned managed identity (MI)** that lives at the Landing Zones management group scope. When a remediation task runs, the MI needs to:

1. **Assign a User-Assigned Managed Identity (UAMI)** to the target VM/VMSS/Arc server → requires **Managed Identity Operator** on the Management resource group (where the UAMI lives)
2. **Associate Data Collection Rules (DCRs)** with the target resource → requires **Monitoring Contributor** on the Management resource group (where the DCRs live)

### The Problem

The Management resource group (`rg-management-*`) is in the **Management subscription**, which sits under the **Platform** management group — a completely different branch of the MG hierarchy from Landing Zones.

The `avm-ptn-alz` module creates role assignments for policy MIs scoped to their **own management group hierarchy** only. It does **not** create cross-branch role assignments to the Management resource group. As a result:

- The 7 Landing Zones MG policy MIs have **0 role assignments** on the Management RG
- DINE remediation tasks fail with `LinkedAuthorizationFailed` errors
- VMs in Landing Zone subscriptions never get AMA, Change Tracking, or Dependency Agent extensions deployed

```
Management Group Hierarchy:

alz (root)
├── platform
│   ├── management     ← rg-management-* with UAMI + DCRs lives here
│   ├── connectivity
│   ├── identity
│   └── security
├── landingzones       ← DINE policy MIs created here (NO access to management RG!)
│   ├── corp
│   └── online
├── sandbox
└── decommissioned
```

## The Fix

The file [`fix.landing-zones-policy-mi-rbac.tf`](fix.landing-zones-policy-mi-rbac.tf) creates the missing role assignments by:

1. **Defining the 7 affected policy names as static strings** — safe for Terraform `for_each` keys
2. **Defining the 2 required roles** — Managed Identity Operator and Monitoring Contributor
3. **Building a static key map** of all 14 combinations (7 policies × 2 roles)
4. **Dynamically resolving the principal IDs** at plan/apply time using the `module.management_groups[0].policy_assignment_identity_ids` output from the `avm-ptn-alz` module
5. **Creating `azurerm_role_assignment` resources** scoped to the Management resource group

### Result

14 role assignments are created on the Management resource group:

| Policy MI | Managed Identity Operator | Monitoring Contributor |
|---|---|---|
| Deploy-VM-Monitoring | ✅ | ✅ |
| Deploy-VM-ChangeTrack | ✅ | ✅ |
| Deploy-VMSS-Monitoring | ✅ | ✅ |
| Deploy-VMSS-ChangeTrack | ✅ | ✅ |
| Deploy-vmHybr-Monitoring | ✅ | ✅ |
| Deploy-vmArc-ChangeTrack | ✅ | ✅ |
| Deploy-MDFC-DefSQL-AMA | ✅ | ✅ |

### Key Design Decisions

- **No hardcoded principal IDs** — all values come from module outputs, so the fix survives policy MI recreation
- **Static `for_each` keys** — uses policy name strings (not dynamic principal IDs) as map keys, avoiding the `Invalid for_each argument` error where Terraform cannot determine keys at plan time
- **Dynamic values only in resource attributes** — the `principal_id` lookup happens inside the resource block, not in the `for_each` keys

## Usage

Drop [`fix.landing-zones-policy-mi-rbac.tf`](fix.landing-zones-policy-mi-rbac.tf) into your ALZ Terraform Accelerator root module alongside your existing `.tf` files. It requires:

- `module.management_groups[0]` — the `avm-ptn-alz` module (provides `policy_assignment_identity_ids` output)
- `module.management_resources[0]` — the `avm-ptn-alz-management` module (provides `resource_group.id`)

Run `terraform plan` to see the 14 role assignments, then `terraform apply`.

## Verification

After applying, verify with this Azure Resource Graph query:

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

## License

MIT
