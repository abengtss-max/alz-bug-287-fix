# Bicep + PowerShell Fix — ALZ Bug #287

> **For Terraform users**, see the [Terraform solution](../terraform/README.md).

## Overview

This solution fixes **two problems** that prevent DINE monitoring policies from working in Azure Landing Zone deployments:

| Problem | Description | Impact |
|---|---|---|
| **#1 — Missing RBAC** ([Issue #287](https://github.com/Azure/Azure-Landing-Zones/issues/287)) | Landing Zones DINE policy MIs have 0 role assignments on the Management RG | `LinkedAuthorizationFailed` — remediation cannot assign UAMI or associate DCRs |
| **#2 — DCR Name Mismatch** | Policy `dcrResourceId` parameters reference DCR names that don't exist | `InvalidAssociation` — remediation creates associations to non-existent DCRs |

The script automatically discovers all affected policies, diagnoses both problems, and fixes them.

## Prerequisites

- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) >= 2.50
- [Bicep CLI](https://learn.microsoft.com/azure/azure-resource-manager/bicep/install) (bundled with Azure CLI)
- PowerShell 7+ or Windows PowerShell 5.1
- Permissions:
  - **Reader** on the Landing Zones management group (to discover policy assignments)
  - **Owner** or **User Access Administrator** on the Management resource group (to create role assignments)
  - **Resource Policy Contributor** on the Landing Zones management group (to update policy parameters)

## Files

| File | Purpose |
|---|---|
| `fix-alz-monitoring.ps1` | PowerShell script — discovers, diagnoses, and fixes both problems |
| `fix-alz-monitoring-rbac.bicep` | Bicep module — creates missing RBAC role assignments on Management RG |

## Quick Start

### Step 1 — Clone and navigate

```powershell
git clone https://github.com/abengtss-max/alz-bug-287-fix.git
cd alz-bug-287-fix/bicep
```

### Step 2 — Discover issues (dry run)

Run the script with `-WhatIf` to see what's wrong without making changes:

```powershell
.\fix-alz-monitoring.ps1 `
    -ManagementSubscriptionId "<your-management-subscription-id>" `
    -ManagementResourceGroupName "<your-management-rg-name>" `
    -LandingZonesMgName "landingzones" `
    -WhatIf
```

The script will output:
- **Step 1** — All 7 DINE policy MIs and their current RBAC status (OK / MISSING)
- **Step 2** — DCR name comparison (actual vs. policy parameter values)

### Step 3 — Apply fixes

Run with `-FixRbac` and/or `-FixDcrNames` to apply the corrections:

```powershell
# Fix both problems
.\fix-alz-monitoring.ps1 `
    -ManagementSubscriptionId "<your-management-subscription-id>" `
    -ManagementResourceGroupName "<your-management-rg-name>" `
    -LandingZonesMgName "landingzones" `
    -FixRbac -FixDcrNames
```

You can also fix just one problem:

```powershell
# Fix RBAC only
.\fix-alz-monitoring.ps1 ... -FixRbac

# Fix DCR names only
.\fix-alz-monitoring.ps1 ... -FixDcrNames
```

### Step 4 — Trigger policy remediation

After the fix, existing VMs won't get DCR associations until you trigger remediation:

```powershell
$subId = "<your-spoke-subscription-id>"

# VM Insights DCR association
az policy remediation create `
    --name "remediate-vm-monitoring" `
    --policy-assignment "Deploy-VM-Monitoring" `
    --definition-reference-id "DataCollectionRuleAssociation_Windows" `
    --resource-discovery-mode ReEvaluateCompliance `
    --subscription $subId

# AMA agent deployment
az policy remediation create `
    --name "remediate-ama-windows" `
    --policy-assignment "Deploy-VM-Monitoring" `
    --definition-reference-id "deployAzureMonitoringAgentWindowsVMWithUAI" `
    --resource-discovery-mode ReEvaluateCompliance `
    --subscription $subId

# Change Tracking DCR association
az policy remediation create `
    --name "remediate-ct-windows" `
    --policy-assignment "Deploy-VM-ChangeTrack" `
    --definition-reference-id "DCRAWindowsVMChangeTrackingAndInventory" `
    --resource-discovery-mode ReEvaluateCompliance `
    --subscription $subId
```

### Step 5 — Verify

Run the script again to confirm everything is green:

```powershell
.\fix-alz-monitoring.ps1 `
    -ManagementSubscriptionId "<your-management-subscription-id>" `
    -ManagementResourceGroupName "<your-management-rg-name>"
```

Expected output:

```
═══ Step 1: Discovering policy assignment managed identities ═══
  [FOUND] Deploy-VM-Monitoring    | MI: ... | RBAC: OK (2 roles)
  [FOUND] Deploy-VM-ChangeTrack   | MI: ... | RBAC: OK (2 roles)
  ...

═══ Step 2: Checking DCR name mismatches in policy parameters ═══
  [OK] Deploy-VM-Monitoring → dcr-vmi-alz-swedencentral
  [OK] Deploy-VM-ChangeTrack → dcr-ct-alz-swedencentral
  ...

═══ Step 3: RBAC — All MIs already have correct roles ═══
═══ Step 4: DCR names — All policy parameters match actual DCRs ═══
```

You can also verify DCR associations on a VM:

```powershell
az monitor data-collection rule association list `
    --resource "<vm-resource-id>" -o table
```

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `ManagementSubscriptionId` | Yes | — | Subscription ID where the Management RG resides |
| `ManagementResourceGroupName` | Yes | — | Name of the Management RG (contains DCRs + UAMI) |
| `LandingZonesMgName` | No | `landingzones` | Name of the Landing Zones management group |
| `FixRbac` | No | `$false` | Deploy Bicep to create missing role assignments |
| `FixDcrNames` | No | `$false` | Update policy parameters with correct DCR names |
| `WhatIf` | No | `$false` | Show changes without applying |

## How It Works

```
┌──────────────────────────────────────────────────────────────┐
│  Step 1: Discover                                           │
│  - Find all 7 DINE policy assignments at LZ MG scope        │
│  - Extract managed identity principal IDs                    │
│  - Check existing RBAC on Management RG                      │
├──────────────────────────────────────────────────────────────┤
│  Step 2: Diagnose DCR Names                                  │
│  - List actual DCRs in Management subscription               │
│  - Compare with dcrResourceId in each policy assignment       │
│  - Flag mismatches                                           │
├──────────────────────────────────────────────────────────────┤
│  Step 3: Fix RBAC (if -FixRbac)                              │
│  - Deploy Bicep template to Management RG                    │
│  - Creates Monitoring Contributor + MI Operator per MI       │
│  - Idempotent: safe to re-run                                │
├──────────────────────────────────────────────────────────────┤
│  Step 4: Fix DCR Names (if -FixDcrNames)                     │
│  - Update policy assignment dcrResourceId parameters         │
│  - Preserves all other policy parameters                     │
│  - Idempotent: skips already-correct assignments             │
└──────────────────────────────────────────────────────────────┘
```

## What Gets Fixed

### Problem 1 — RBAC (14 role assignments)

| Policy MI | Managed Identity Operator | Monitoring Contributor |
|---|---|---|
| Deploy-VM-Monitoring | ✅ | ✅ |
| Deploy-VM-ChangeTrack | ✅ | ✅ |
| Deploy-VMSS-Monitoring | ✅ | ✅ |
| Deploy-VMSS-ChangeTrack | ✅ | ✅ |
| Deploy-vmHybr-Monitoring | ✅ | ✅ |
| Deploy-vmArc-ChangeTrack | ✅ | ✅ |
| Deploy-MDFC-DefSQL-AMA | ✅ | ✅ |

### Problem 2 — DCR Name Corrections

| Policy | Wrong Name | Correct Name |
|---|---|---|
| Deploy-VM-Monitoring | `dcr-alz-vminsights-*` | `dcr-vmi-alz-*` |
| Deploy-VM-ChangeTrack | `dcr-alz-changetracking-*` | `dcr-ct-alz-*` |
| Deploy-VMSS-Monitoring | `dcr-alz-vminsights-*` | `dcr-vmi-alz-*` |
| Deploy-VMSS-ChangeTrack | `dcr-alz-changetracking-*` | `dcr-ct-alz-*` |
| Deploy-MDFC-DefSQL-AMA | `dcr-alz-mdfcsql-*` | `dcr-mdfcsql-alz-*` |

## Idempotency

The script is fully idempotent and safe to re-run:

- **RBAC**: Bicep deployment uses deterministic `guid()` for role assignment names — Azure skips existing assignments
- **DCR names**: Script compares before updating — skips policies where parameters already match
- **Diagnosis**: Running without `-FixRbac` or `-FixDcrNames` is always read-only
