# =============================================================================
# Workaround for Azure Landing Zones bug #287
# https://github.com/Azure/Azure-Landing-Zones/issues/287
#
# DINE policy assignments at the Landing Zones management group create
# system-assigned managed identities that need cross-subscription permissions
# on the Management resource group (where the UAMI and DCRs reside).
# The avm-ptn-alz module only creates role assignments scoped to the
# management group hierarchy, not to the Management RG in a different MG branch.
#
# This file dynamically retrieves the policy MI principal IDs from the
# management_groups module output and creates the required role assignments
# on the Management resource group.
#
# No principal IDs are hardcoded — all values are resolved at plan/apply time.
# =============================================================================

locals {
  # Management group name for Landing Zones in the ALZ hierarchy.
  # This must match the MG id in your architecture definition
  # (lib/architecture_definitions/alz_custom.alz_architecture_definition.yaml).
  _landing_zones_mg_name = "landingzones"

  # The Landing Zones MG AMA/monitoring policy assignments that require
  # cross-subscription role assignments on the Management resource group.
  # These are STATIC strings — safe for use in for_each keys.
  _landing_zones_ama_policy_names = [
    "Deploy-VM-Monitoring",
    "Deploy-VM-ChangeTrack",
    "Deploy-VMSS-Monitoring",
    "Deploy-VMSS-ChangeTrack",
    "Deploy-vmHybr-Monitoring",
    "Deploy-vmArc-ChangeTrack",
    "Deploy-MDFC-DefSQL-AMA",
  ]

  # Roles required on the Management RG for the DINE policies to function:
  #   Managed Identity Operator — assign the UAMI to target VMs/VMSS/Arc servers
  #   Monitoring Contributor    — associate DCRs with target resources
  _management_rg_cross_sub_roles = {
    managed_identity_operator = "Managed Identity Operator"
    monitoring_contributor    = "Monitoring Contributor"
  }

  # Build a STATIC key map (policy × role) so Terraform can always determine
  # the full set of for_each keys at plan time. Only dynamic values (principal_id)
  # go into the map values — never into keys.
  _landing_zones_policy_mi_role_assignments = {
    for combo in flatten([
      for policy_name in local._landing_zones_ama_policy_names : [
        for role_key, role_name in local._management_rg_cross_sub_roles : {
          key         = "${policy_name}-${role_key}"
          policy_name = policy_name
          role_name   = role_name
        }
      ]
    ]) : combo.key => combo
  }
}

# Grant the Landing Zones MG policy MIs the required roles on the Management RG
resource "azurerm_role_assignment" "landing_zones_policy_mi" {
  for_each = local._landing_zones_policy_mi_role_assignments

  scope                = module.management_resources[0].resource_group.id
  role_definition_name = each.value.role_name
  principal_id         = module.management_groups[0].policy_assignment_identity_ids["${local._landing_zones_mg_name}/${each.value.policy_name}"]
  principal_type       = "ServicePrincipal"
  description          = "ALZ bug #287 workaround: Cross-subscription RBAC for Landing Zones DINE policy MI"
}
