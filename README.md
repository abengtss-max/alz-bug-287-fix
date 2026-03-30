# ALZ Bug #287 Fix — Cross-Subscription RBAC for Landing Zones DINE Policy Managed Identities

## The Problem

**GitHub Issue:** [Azure/Azure-Landing-Zones#287](https://github.com/Azure/Azure-Landing-Zones/issues/287)

When deploying Azure Landing Zones (ALZ) using the accelerator, 7 DINE (DeployIfNotExists) monitoring policies are assigned at the **Landing Zones** management group. Each policy creates a system-assigned managed identity (MI) that needs permissions on the **Management** resource group (where DCRs and the UAMI reside).

The Management RG sits under the **Platform** management group — a different branch of the MG hierarchy. The ALZ accelerator only assigns RBAC within the same MG branch, so:

- Landing Zones policy MIs get **0 role assignments** on the Management RG
- DINE remediation fails with `LinkedAuthorizationFailed`
- VMs never get AMA, Change Tracking, or DCR associations

```
alz (root)
├── platform
│   └── management     ← Management RG lives here (DCRs + UAMI)
├── landingzones       ← Policy MIs created here (NO access to Management RG!)
│   ├── corp
│   └── online
└── ...
```

Additionally, the governance stack may set incorrect DCR names in the `dcrResourceId` policy parameter, causing `InvalidAssociation` errors even when RBAC is fixed.

## Choose Your Solution

| Solution | Fixes | Best For |
|---|---|---|
| [**Bicep + PowerShell**](bicep/README.md) | Problem 1 (RBAC) + Problem 2 (DCR names) | Any ALZ deployment — automatic discovery, diagnosis, and fix |
| [**Terraform**](terraform/README.md) | Problem 1 (RBAC) only | ALZ Terraform Accelerator (`avm-ptn-alz`) users |

### Which one should I use?

- **Using Terraform Accelerator?** → Use the [Terraform solution](terraform/README.md). Drop the `.tf` file into your root module — it integrates with `avm-ptn-alz` module outputs and creates role assignments declaratively.

- **Using Bicep Accelerator or any other deployment method?** → Use the [Bicep + PowerShell solution](bicep/README.md). It works with any ALZ deployment by dynamically discovering policy MIs and DCR mismatches.

- **Not sure?** → Use the [Bicep + PowerShell solution](bicep/README.md). It's standalone, requires no IaC integration, and fixes both problems.

## Affected Policies

| Policy Assignment | Purpose |
|---|---|
| `Deploy-VM-Monitoring` | Deploy AMA and DCR association on VMs |
| `Deploy-VM-ChangeTrack` | Deploy Change Tracking extension on VMs |
| `Deploy-VMSS-Monitoring` | Deploy AMA and DCR association on VMSS |
| `Deploy-VMSS-ChangeTrack` | Deploy Change Tracking extension on VMSS |
| `Deploy-vmHybr-Monitoring` | Deploy AMA on Azure Arc hybrid machines |
| `Deploy-vmArc-ChangeTrack` | Deploy Change Tracking on Azure Arc machines |
| `Deploy-MDFC-DefSQL-AMA` | Deploy Microsoft Defender for SQL AMA |

## License

MIT
