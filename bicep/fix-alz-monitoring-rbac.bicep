// ============================================================================
// ALZ Bug #287 Fix — Cross-Subscription RBAC for Landing Zones DINE Policy MIs
// ============================================================================
// GitHub Issue: https://github.com/Azure/Azure-Landing-Zones/issues/287
//
// Problem: The ALZ accelerator creates DINE policy assignments at the Landing
// Zones MG, each with a system-assigned managed identity (MI). These MIs need
// to read DCRs and assign UAMIs from the Management resource group, which sits
// under the Platform MG — a different branch of the MG hierarchy.
// The accelerator only assigns RBAC within the same MG branch, so LZ MIs get
// 0 role assignments on the Management RG → DINE remediation fails with
// LinkedAuthorizationFailed.
//
// Fix: Create Monitoring Contributor + Managed Identity Operator role
// assignments on the Management RG for each affected policy MI.
//
// Deploy: az deployment group create \
//           --resource-group <management-rg-name> \
//           --subscription <management-subscription-id> \
//           --template-file fix-alz-monitoring-rbac.bicep \
//           --parameters policyMiPrincipalIds='[...]'
// ============================================================================

targetScope = 'resourceGroup'

@description('Array of principal IDs (GUIDs) from Landing Zones DINE policy assignment managed identities. Discovered automatically by the companion PowerShell script.')
param policyMiPrincipalIds array

// Built-in role definition IDs
var monitoringContributorRoleId = '749f88d5-cbae-40b8-bcfc-e573ddc772fa'
var managedIdentityOperatorRoleId = 'f1a07417-d97a-45cb-824c-7a7467783830'

// Build a flat list of all combinations: each MI × each role
var roleAssignments = [for principalId in policyMiPrincipalIds: [
  {
    principalId: principalId
    roleDefinitionId: monitoringContributorRoleId
    roleName: 'Monitoring Contributor'
  }
  {
    principalId: principalId
    roleDefinitionId: managedIdentityOperatorRoleId
    roleName: 'Managed Identity Operator'
  }
]]

// Flatten the nested array
var flatRoleAssignments = flatten(roleAssignments)

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (ra, i) in flatRoleAssignments: {
  name: guid(resourceGroup().id, ra.principalId, ra.roleDefinitionId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', ra.roleDefinitionId)
    principalId: ra.principalId
    principalType: 'ServicePrincipal'
    description: 'ALZ bug #287 fix — ${ra.roleName} for Landing Zones DINE policy MI'
  }
}]

output roleAssignmentCount int = length(flatRoleAssignments)
output roleAssignmentDetails array = [for (ra, i) in flatRoleAssignments: {
  principalId: ra.principalId
  role: ra.roleName
}]
