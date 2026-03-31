<#
.SYNOPSIS
    Fix ALZ Bug #287 — Cross-subscription RBAC, DCR name, and UAMI name mismatches for Landing Zones DINE policies.

.DESCRIPTION
    This script discovers and fixes THREE problems in Azure Landing Zone deployments:

    Problem 1 (Issue #287): Landing Zones DINE policy managed identities lack RBAC
    on the Management resource group. The script discovers all affected policy MIs
    and deploys a Bicep template to create the missing role assignments.

    Problem 2: DCR name mismatch in Landing Zones policy parameters. The governance
    stack sometimes sets incorrect DCR names in the dcrResourceId parameter. The
    script compares actual DCR names with policy parameters and corrects mismatches.

    Problem 3: UAMI name mismatch in Landing Zones policy parameters. The governance
    stack sets the userAssignedIdentityResourceId parameter to a UAMI name that does
    not match the actual managed identity deployed in the Management resource group.
    This prevents the AddUserAssignedManagedIdentity_VM sub-policy from assigning the
    UAMI to VMs, which breaks Change Tracking and other features that require UAMI.

    Affected policies:
    - Deploy-VM-Monitoring          (AMA + DCR association for VMs)
    - Deploy-VM-ChangeTrack         (Change Tracking for VMs)
    - Deploy-VMSS-Monitoring        (AMA + DCR association for VMSS)
    - Deploy-VMSS-ChangeTrack       (Change Tracking for VMSS)
    - Deploy-vmHybr-Monitoring      (AMA for Azure Arc hybrid machines)
    - Deploy-vmArc-ChangeTrack      (Change Tracking for Azure Arc)
    - Deploy-MDFC-DefSQL-AMA        (Defender for SQL AMA)

.PARAMETER LandingZonesMgName
    Name of the Landing Zones management group. Default: 'landingzones'

.PARAMETER ManagementSubscriptionId
    Subscription ID where the Management resource group resides.

.PARAMETER ManagementResourceGroupName
    Name of the Management resource group containing DCRs and UAMI.

.PARAMETER FixRbac
    Fix Problem 1: Deploy Bicep to create missing RBAC role assignments.

.PARAMETER FixDcrNames
    Fix Problem 2: Update policy parameters to use correct DCR names.

.PARAMETER FixUamiName
    Fix Problem 3: Update policy parameters to use correct UAMI resource name.

.PARAMETER WhatIf
    Show what would be changed without making any modifications.

.EXAMPLE
    # Discover issues (dry run)
    .\fix-alz-monitoring.ps1 -ManagementSubscriptionId "d775d3cc-..." -ManagementResourceGroupName "rg-alz-logging-swedencentral" -WhatIf

    # Fix all problems
    .\fix-alz-monitoring.ps1 -ManagementSubscriptionId "d775d3cc-..." -ManagementResourceGroupName "rg-alz-logging-swedencentral" -FixRbac -FixDcrNames -FixUamiName

.LINK
    https://github.com/Azure/Azure-Landing-Zones/issues/287
    https://github.com/abengtss-max/alz-bug-287-fix
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$LandingZonesMgName = 'landingzones',

    [Parameter(Mandatory)]
    [string]$ManagementSubscriptionId,

    [Parameter(Mandatory)]
    [string]$ManagementResourceGroupName,

    [switch]$FixRbac,
    [switch]$FixDcrNames,
    [switch]$FixUamiName
)

$ErrorActionPreference = 'Stop'

# ── Policy assignments to check ──────────────────────────────────────────────
$policyNames = @(
    'Deploy-VM-Monitoring',
    'Deploy-VM-ChangeTrack',
    'Deploy-VMSS-Monitoring',
    'Deploy-VMSS-ChangeTrack',
    'Deploy-vmHybr-Monitoring',
    'Deploy-vmArc-ChangeTrack',
    'Deploy-MDFC-DefSQL-AMA'
)

# ── DCR keyword to actual name mapping ───────────────────────────────────────
# The DINE policies have a dcrResourceId parameter. We match on keywords to find
# the correct DCR regardless of naming convention.
$dcrKeywordMap = @{
    'vminsights'     = 'vmi'       # dcr-vmi-alz-* or dcr-alz-vminsights-*
    'changetracking' = 'ct'        # dcr-ct-alz-* or dcr-alz-changetracking-*
    'mdfcsql'        = 'mdfcsql'   # dcr-mdfcsql-alz-*
    'defender'       = 'mdfcsql'   # alternative keyword
}

$lzScope = "/providers/Microsoft.Management/managementGroups/$LandingZonesMgName"

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  ALZ Bug #287 Fix — Landing Zones DINE Policy MI Diagnostics   ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
Write-Host "Landing Zones MG:     $LandingZonesMgName" -ForegroundColor Gray
Write-Host "Management Sub:       $ManagementSubscriptionId" -ForegroundColor Gray
Write-Host "Management RG:        $ManagementResourceGroupName" -ForegroundColor Gray
Write-Host ""

# ══════════════════════════════════════════════════════════════════════════════
# STEP 1: Discover policy assignment managed identities
# ══════════════════════════════════════════════════════════════════════════════
Write-Host "═══ Step 1: Discovering policy assignment managed identities ═══" -ForegroundColor Yellow
Write-Host ""

$discoveredMIs = @()
$missingPolicies = @()

foreach ($policyName in $policyNames) {
    try {
        $assignment = az policy assignment show `
            --name $policyName `
            --scope $lzScope `
            -o json 2>$null | ConvertFrom-Json

        if ($assignment -and $assignment.identity.principalId) {
            $principalId = $assignment.identity.principalId
            $discoveredMIs += @{
                Name        = $policyName
                PrincipalId = $principalId
                DisplayName = $assignment.displayName
            }

            # Check existing roles on management RG
            $mgmtRgScope = "/subscriptions/$ManagementSubscriptionId/resourceGroups/$ManagementResourceGroupName"
            $existingRoles = az role assignment list `
                --scope $mgmtRgScope `
                --assignee $principalId `
                --query "[].roleDefinitionName" -o json 2>$null | ConvertFrom-Json

            $roleCount = if ($existingRoles) { $existingRoles.Count } else { 0 }
            $status = if ($roleCount -ge 2) { "OK ($roleCount roles)" } else { "MISSING ($roleCount/2 roles)" }
            $color = if ($roleCount -ge 2) { "Green" } else { "Red" }

            Write-Host "  [FOUND] $policyName" -ForegroundColor Green -NoNewline
            Write-Host " | MI: $principalId" -ForegroundColor Gray -NoNewline
            Write-Host " | RBAC: " -NoNewline
            Write-Host $status -ForegroundColor $color
        }
        else {
            $missingPolicies += $policyName
            Write-Host "  [SKIP]  $policyName — no managed identity" -ForegroundColor DarkYellow
        }
    }
    catch {
        $missingPolicies += $policyName
        Write-Host "  [SKIP]  $policyName — not found at scope" -ForegroundColor DarkYellow
    }
}

Write-Host ""
Write-Host "  Found: $($discoveredMIs.Count) policy MIs | Skipped: $($missingPolicies.Count)" -ForegroundColor Gray
Write-Host ""

if ($discoveredMIs.Count -eq 0) {
    Write-Host "No DINE policy assignments found at $lzScope. Nothing to fix." -ForegroundColor Yellow
    exit 0
}

# ══════════════════════════════════════════════════════════════════════════════
# STEP 2: Check DCR name mismatches
# ══════════════════════════════════════════════════════════════════════════════
Write-Host "═══ Step 2: Checking DCR name mismatches in policy parameters ═══" -ForegroundColor Yellow
Write-Host ""

# Get actual DCRs from management RG
$actualDcrs = az monitor data-collection rule list `
    --subscription $ManagementSubscriptionId `
    --resource-group $ManagementResourceGroupName `
    --query "[].{name:name, id:id}" -o json 2>$null | ConvertFrom-Json

if (-not $actualDcrs -or $actualDcrs.Count -eq 0) {
    # Try without RG filter
    $actualDcrs = az monitor data-collection rule list `
        --subscription $ManagementSubscriptionId `
        --query "[].{name:name, id:id}" -o json 2>$null | ConvertFrom-Json
}

Write-Host "  Actual DCRs in management subscription:" -ForegroundColor Gray
foreach ($dcr in $actualDcrs) {
    Write-Host "    - $($dcr.name)" -ForegroundColor Gray
}
Write-Host ""

$dcrMismatches = @()

foreach ($mi in $discoveredMIs) {
    try {
        $assignment = az policy assignment show `
            --name $mi.Name `
            --scope $lzScope `
            --query "parameters.dcrResourceId.value" -o tsv 2>$null

        if ($assignment) {
            $policyDcrName = ($assignment -split '/')[-1]
            $policyDcrRg = ($assignment -split '/')[4]  # Extract RG from ID

            # Check if this DCR actually exists
            $exists = $actualDcrs | Where-Object { $_.id -eq $assignment }

            if ($exists) {
                Write-Host "  [OK]    $($mi.Name) → $policyDcrName" -ForegroundColor Green
            }
            else {
                # Try to find the correct DCR by matching keywords
                $correctDcr = $null
                foreach ($keyword in $dcrKeywordMap.Keys) {
                    if ($policyDcrName -match $keyword) {
                        $shortName = $dcrKeywordMap[$keyword]
                        $correctDcr = $actualDcrs | Where-Object { $_.name -match $shortName }
                        break
                    }
                }

                if (-not $correctDcr) {
                    # Broader match: try matching any DCR by partial name similarity
                    foreach ($dcr in $actualDcrs) {
                        if ($policyDcrName -match 'vminsights|vmi' -and $dcr.name -match 'vmi|vminsights') {
                            $correctDcr = $dcr; break
                        }
                        if ($policyDcrName -match 'changetracking|ct' -and $dcr.name -match 'ct|changetracking') {
                            $correctDcr = $dcr; break
                        }
                        if ($policyDcrName -match 'mdfcsql|defender' -and $dcr.name -match 'mdfcsql|defender') {
                            $correctDcr = $dcr; break
                        }
                    }
                }

                if ($correctDcr) {
                    Write-Host "  [WRONG] $($mi.Name)" -ForegroundColor Red
                    Write-Host "          Policy expects: $policyDcrName" -ForegroundColor Red
                    Write-Host "          Actual DCR:     $($correctDcr.name)" -ForegroundColor Green
                    $dcrMismatches += @{
                        PolicyName    = $mi.Name
                        CurrentDcrId  = $assignment
                        CorrectDcrId  = $correctDcr.id
                        CurrentName   = $policyDcrName
                        CorrectName   = $correctDcr.name
                    }
                }
                else {
                    Write-Host "  [WARN]  $($mi.Name) → $policyDcrName (not found, no match)" -ForegroundColor DarkYellow
                }
            }
        }
        else {
            Write-Host "  [SKIP]  $($mi.Name) — no dcrResourceId parameter" -ForegroundColor DarkYellow
        }
    }
    catch {
        Write-Host "  [SKIP]  $($mi.Name) — error checking parameters" -ForegroundColor DarkYellow
    }
}

Write-Host ""
Write-Host "  DCR mismatches found: $($dcrMismatches.Count)" -ForegroundColor $(if ($dcrMismatches.Count -gt 0) { 'Red' } else { 'Green' })
Write-Host ""

# ══════════════════════════════════════════════════════════════════════════════
# STEP 3: Check UAMI name mismatch
# ══════════════════════════════════════════════════════════════════════════════
Write-Host "═══ Step 3: Checking UAMI name in policy parameters ═══" -ForegroundColor Yellow
Write-Host ""

# Policies that use userAssignedIdentityResourceId parameter
$uamiPolicies = @(
    'Deploy-VM-Monitoring',
    'Deploy-VM-ChangeTrack',
    'Deploy-VMSS-Monitoring',
    'Deploy-VMSS-ChangeTrack',
    'Deploy-MDFC-DefSQL-AMA'
)

# Get actual UAMI from management RG
$actualUami = az identity list `
    --resource-group $ManagementResourceGroupName `
    --subscription $ManagementSubscriptionId `
    --query "[0].{name:name, id:id}" -o json 2>$null | ConvertFrom-Json

$uamiMismatch = $null
if ($actualUami) {
    Write-Host "  Actual UAMI in management RG: $($actualUami.name)" -ForegroundColor Gray
    Write-Host ""

    foreach ($polName in $uamiPolicies) {
        $policyUami = az policy assignment show `
            --name $polName `
            --scope $lzScope `
            --query "parameters.userAssignedIdentityResourceId.value" -o tsv 2>$null

        if ($policyUami) {
            $policyUamiName = ($policyUami -split '/')[-1]
            if ($policyUamiName -ne $actualUami.name) {
                if (-not $uamiMismatch) {
                    $uamiMismatch = @{
                        PolicyUamiName = $policyUamiName
                        ActualUamiName = $actualUami.name
                        ActualUamiId   = $actualUami.id
                        AffectedPolicies = @()
                    }
                }
                $uamiMismatch.AffectedPolicies += $polName
                Write-Host "  [WRONG] $polName" -ForegroundColor Red
                Write-Host "          Policy expects: $policyUamiName" -ForegroundColor Red
                Write-Host "          Actual UAMI:    $($actualUami.name)" -ForegroundColor Green
            }
            else {
                Write-Host "  [OK]    $polName → $policyUamiName" -ForegroundColor Green
            }
        }
        else {
            Write-Host "  [SKIP]  $polName — no userAssignedIdentityResourceId parameter" -ForegroundColor DarkYellow
        }
    }
}
else {
    Write-Host "  [WARN]  No managed identity found in $ManagementResourceGroupName" -ForegroundColor DarkYellow
}

$uamiMismatchCount = if ($uamiMismatch) { $uamiMismatch.AffectedPolicies.Count } else { 0 }
Write-Host ""
Write-Host "  UAMI mismatches found: $uamiMismatchCount" -ForegroundColor $(if ($uamiMismatchCount -gt 0) { 'Red' } else { 'Green' })
Write-Host ""

# ══════════════════════════════════════════════════════════════════════════════
# STEP 4: Fix RBAC (deploy Bicep)
# ══════════════════════════════════════════════════════════════════════════════
$missingRbacMIs = @()
foreach ($mi in $discoveredMIs) {
    $mgmtRgScope = "/subscriptions/$ManagementSubscriptionId/resourceGroups/$ManagementResourceGroupName"
    $rolesJson = az role assignment list --scope $mgmtRgScope --assignee $mi.PrincipalId -o json 2>$null
    $rolesArr = $rolesJson | ConvertFrom-Json
    $roleCount = if ($rolesArr) { @($rolesArr).Count } else { 0 }
    if ($roleCount -lt 2) {
        $missingRbacMIs += $mi
    }
}

if ($FixRbac -and $missingRbacMIs.Count -gt 0) {
    Write-Host "═══ Step 4: Fixing RBAC — Deploying Bicep template ═══" -ForegroundColor Yellow
    Write-Host ""

    $principalIds = @($missingRbacMIs | ForEach-Object { $_.PrincipalId })

    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $bicepFile = Join-Path $scriptDir 'fix-alz-monitoring-rbac.bicep'

    if (-not (Test-Path $bicepFile)) {
        Write-Host "  ERROR: Bicep file not found at $bicepFile" -ForegroundColor Red
        exit 1
    }

    $deploymentName = "fix-alz-bug287-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

    Write-Host "  Deploying $($principalIds.Count) MI(s) × 2 roles = $($principalIds.Count * 2) role assignments" -ForegroundColor Cyan
    Write-Host "  Target: $ManagementResourceGroupName in subscription $ManagementSubscriptionId" -ForegroundColor Gray
    Write-Host ""

    if ($PSCmdlet.ShouldProcess("$ManagementResourceGroupName", "Deploy RBAC role assignments")) {
        # Write parameters to temp file to avoid CLI JSON parsing issues
        $paramsObj = @{
            '`$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
            contentVersion = '1.0.0.0'
            parameters = @{
                policyMiPrincipalIds = @{ value = $principalIds }
            }
        }
        $paramsFile = Join-Path $env:TEMP "fix-alz-rbac-params-$(Get-Date -Format 'yyyyMMddHHmmss').json"
        $paramsObj | ConvertTo-Json -Depth 5 | Set-Content -Path $paramsFile -Encoding UTF8

        $result = az deployment group create `
            --name $deploymentName `
            --resource-group $ManagementResourceGroupName `
            --subscription $ManagementSubscriptionId `
            --template-file $bicepFile `
            --parameters "@$paramsFile" `
            -o json 2>&1

        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) {
            $output = $result | ConvertFrom-Json
            $count = $output.properties.outputs.roleAssignmentCount.value
            Write-Host "  SUCCESS: $count role assignments created" -ForegroundColor Green
        }
        else {
            # Check if all errors are just "RoleAssignmentExists" (idempotent re-run)
            $resultStr = $result -join "`n"
            $parsed = $null
            try { $parsed = $resultStr | ConvertFrom-Json -ErrorAction SilentlyContinue } catch {}
            $details = $parsed.error.details
            $allExist = $details -and ($details | Where-Object { $_.code -ne 'RoleAssignmentExists' }).Count -eq 0
            if ($allExist) {
                $existCount = $details.Count
                $newCount = ($principalIds.Count * 2) - $existCount
                Write-Host "  SUCCESS: $newCount new role assignments created ($existCount already existed)" -ForegroundColor Green
            }
            else {
                Write-Host "  FAILED: Bicep deployment failed" -ForegroundColor Red
                Write-Host $result -ForegroundColor Red
            }
        }
    }
    Write-Host ""
}
elseif ($missingRbacMIs.Count -gt 0) {
    Write-Host "═══ Step 4: RBAC fix needed (use -FixRbac to apply) ═══" -ForegroundColor Yellow
    Write-Host "  $($missingRbacMIs.Count) policy MI(s) missing roles on Management RG" -ForegroundColor Red
    Write-Host ""
}
else {
    Write-Host "═══ Step 4: RBAC — All MIs already have correct roles ═══" -ForegroundColor Green
    Write-Host ""
}

# ══════════════════════════════════════════════════════════════════════════════
# STEP 5: Fix DCR name mismatches
# ══════════════════════════════════════════════════════════════════════════════
if ($FixDcrNames -and $dcrMismatches.Count -gt 0) {
    Write-Host "═══ Step 5: Fixing DCR name mismatches in policy parameters ═══" -ForegroundColor Yellow
    Write-Host ""

    foreach ($mismatch in $dcrMismatches) {
        Write-Host "  Updating $($mismatch.PolicyName)..." -ForegroundColor Cyan
        Write-Host "    From: $($mismatch.CurrentName)" -ForegroundColor Red
        Write-Host "    To:   $($mismatch.CorrectName)" -ForegroundColor Green

        if ($PSCmdlet.ShouldProcess("$($mismatch.PolicyName)", "Update dcrResourceId parameter")) {
            # Fetch ALL existing parameters first, then update only dcrResourceId
            $existingParams = az policy assignment show `
                --name $mismatch.PolicyName `
                --scope $lzScope `
                --query "parameters" -o json 2>$null | ConvertFrom-Json

            # Convert to hashtable and update the DCR ID
            $paramsHash = @{}
            foreach ($prop in $existingParams.PSObject.Properties) {
                $paramsHash[$prop.Name] = @{ value = $prop.Value.value }
            }
            $paramsHash['dcrResourceId'] = @{ value = $mismatch.CorrectDcrId }

            # Write to temp file to avoid quoting issues
            $tempFile = [System.IO.Path]::GetTempFileName()
            ($paramsHash | ConvertTo-Json -Depth 5) | Out-File -FilePath $tempFile -Encoding utf8 -NoNewline

            az policy assignment update `
                --name $mismatch.PolicyName `
                --scope $lzScope `
                --params "@$tempFile" `
                -o none 2>&1

            Remove-Item $tempFile -ErrorAction SilentlyContinue

            if ($LASTEXITCODE -eq 0) {
                Write-Host "    UPDATED" -ForegroundColor Green
            }
            else {
                Write-Host "    FAILED — may need manual update" -ForegroundColor Red
            }
        }
    }
    Write-Host ""
}
elseif ($dcrMismatches.Count -gt 0) {
    Write-Host "═══ Step 5: DCR fix needed (use -FixDcrNames to apply) ═══" -ForegroundColor Yellow
    foreach ($m in $dcrMismatches) {
        Write-Host "  $($m.PolicyName): $($m.CurrentName) → $($m.CorrectName)" -ForegroundColor Red
    }
    Write-Host ""
}
else {
    Write-Host "═══ Step 5: DCR names — All policy parameters match actual DCRs ═══" -ForegroundColor Green
    Write-Host ""
}

# ══════════════════════════════════════════════════════════════════════════════
# STEP 6: Fix UAMI name mismatch
# ══════════════════════════════════════════════════════════════════════════════
if ($FixUamiName -and $uamiMismatch) {
    Write-Host "═══ Step 6: Fixing UAMI name in policy parameters ═══" -ForegroundColor Yellow
    Write-Host ""

    foreach ($polName in $uamiMismatch.AffectedPolicies) {
        Write-Host "  Updating $polName..." -ForegroundColor Cyan
        Write-Host "    From: $($uamiMismatch.PolicyUamiName)" -ForegroundColor Red
        Write-Host "    To:   $($uamiMismatch.ActualUamiName)" -ForegroundColor Green

        if ($PSCmdlet.ShouldProcess("$polName", "Update userAssignedIdentityResourceId parameter")) {
            $existingParams = az policy assignment show `
                --name $polName `
                --scope $lzScope `
                --query "parameters" -o json 2>$null | ConvertFrom-Json

            $paramsHash = @{}
            foreach ($prop in $existingParams.PSObject.Properties) {
                $paramsHash[$prop.Name] = @{ value = $prop.Value.value }
            }
            $paramsHash['userAssignedIdentityResourceId'] = @{ value = $uamiMismatch.ActualUamiId }

            $tempFile = [System.IO.Path]::GetTempFileName()
            ($paramsHash | ConvertTo-Json -Depth 5) | Out-File -FilePath $tempFile -Encoding utf8 -NoNewline

            az policy assignment update `
                --name $polName `
                --scope $lzScope `
                --params "@$tempFile" `
                -o none 2>&1

            Remove-Item $tempFile -ErrorAction SilentlyContinue

            if ($LASTEXITCODE -eq 0) {
                Write-Host "    UPDATED" -ForegroundColor Green
            }
            else {
                Write-Host "    FAILED — may need manual update" -ForegroundColor Red
            }
        }
    }
    Write-Host ""
}
elseif ($uamiMismatchCount -gt 0) {
    Write-Host "═══ Step 6: UAMI fix needed (use -FixUamiName to apply) ═══" -ForegroundColor Yellow
    Write-Host "  $uamiMismatchCount policy(ies) reference '$($uamiMismatch.PolicyUamiName)' but actual is '$($uamiMismatch.ActualUamiName)'" -ForegroundColor Red
    Write-Host ""
}
else {
    Write-Host "═══ Step 6: UAMI name — All policy parameters match actual UAMI ═══" -ForegroundColor Green
    Write-Host ""
}

# ══════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ══════════════════════════════════════════════════════════════════════════════
Write-Host "╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║                          SUMMARY                               ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Policy MIs discovered:    $($discoveredMIs.Count) / $($policyNames.Count)" -ForegroundColor Gray
Write-Host "  RBAC issues:              $($missingRbacMIs.Count)" -ForegroundColor $(if ($missingRbacMIs.Count -gt 0 -and -not $FixRbac) { 'Red' } else { 'Green' })
Write-Host "  DCR name mismatches:      $($dcrMismatches.Count)" -ForegroundColor $(if ($dcrMismatches.Count -gt 0 -and -not $FixDcrNames) { 'Red' } else { 'Green' })
Write-Host "  UAMI name mismatches:     $uamiMismatchCount" -ForegroundColor $(if ($uamiMismatchCount -gt 0 -and -not $FixUamiName) { 'Red' } else { 'Green' })
Write-Host ""

if ((-not $FixRbac -and $missingRbacMIs.Count -gt 0) -or (-not $FixDcrNames -and $dcrMismatches.Count -gt 0) -or (-not $FixUamiName -and $uamiMismatchCount -gt 0)) {
    Write-Host "  To fix all issues, run:" -ForegroundColor Yellow
    Write-Host "  .\fix-alz-monitoring.ps1 ``" -ForegroundColor White
    Write-Host "      -ManagementSubscriptionId '$ManagementSubscriptionId' ``" -ForegroundColor White
    Write-Host "      -ManagementResourceGroupName '$ManagementResourceGroupName' ``" -ForegroundColor White
    Write-Host "      -LandingZonesMgName '$LandingZonesMgName' ``" -ForegroundColor White
    Write-Host "      -FixRbac -FixDcrNames -FixUamiName" -ForegroundColor White
    Write-Host ""
}

Write-Host "  After fixing, trigger remediation to apply to existing VMs:" -ForegroundColor Gray
Write-Host '  az policy remediation create --name "remediate-monitoring" `' -ForegroundColor DarkGray
Write-Host '      --policy-assignment "<assignment-id>" `' -ForegroundColor DarkGray
Write-Host '      --definition-reference-id "<ref-id>" `' -ForegroundColor DarkGray
Write-Host '      --resource-discovery-mode ReEvaluateCompliance' -ForegroundColor DarkGray
Write-Host ""
