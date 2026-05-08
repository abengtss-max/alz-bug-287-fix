# =============================================================================
# Workaround for AMA UAMI missing Monitoring Metrics Publisher on DCRs
#
# Root cause:
#   The avm-ptn-alz-management module creates the AMA UAMI and the DCRs, but
#   does NOT assign the UAMI the permissions needed to actually push data
#   through the DCR pipeline. Without this assignment, AMA authenticates as
#   the UAMI but is rejected by Azure Monitor — resulting in zero ingestion
#   in Log Analytics despite the extension being installed and DCR associations
#   being present.
#
# What this file fixes:
#   Grants the AMA UAMI "Monitoring Metrics Publisher" on each management DCR.
#   This is the minimum permission required for AMA to authenticate and send
#   telemetry (Heartbeat, InsightsMetrics, ChangeTracking, etc.) through the
#   DCR data pipeline.
#
# Relationship to fix.landing-zones-policy-mi-rbac.tf (ALZ bug #287):
#   That fix enables DINE policies to assign the UAMI to VMs and create DCR
#   associations. THIS fix enables the UAMI itself to ingest data.
#   Both fixes are required for end-to-end monitoring to work.
#
# No principal IDs or resource IDs are hardcoded — all values are resolved
# from module outputs at plan/apply time.
# =============================================================================

locals {
  # DCR config keys as defined in management_resource_settings.data_collection_rules.
  # These must match the keys used in the tfvars configuration.
  _ama_dcr_keys = toset([
    "change_tracking",
    "defender_sql",
    "vm_insights",
  ])
}

# Look up the AMA UAMI to obtain its principal_id.
# The module output user_assigned_identity_ids["ama"].id gives the resource ID
# but not the principal_id, so we use a data source.
data "azurerm_user_assigned_identity" "ama_uami" {
  provider            = azurerm.management
  resource_group_name = module.management_resources[0].resource_group.name
  name                = split("/", module.management_resources[0].user_assigned_identity_ids["ama"].id)[8]
}

# Grant the AMA UAMI Monitoring Metrics Publisher on each management DCR.
# Scope: individual DCR resource (least-privilege — not subscription or RG scope).
resource "azurerm_role_assignment" "ama_uami_metrics_publisher" {
  for_each = local._ama_dcr_keys

  scope                = module.management_resources[0].data_collection_rule_ids[each.key].id
  role_definition_name = "Monitoring Metrics Publisher"
  principal_id         = data.azurerm_user_assigned_identity.ama_uami.principal_id
  principal_type       = "ServicePrincipal"
  description          = "AMA UAMI fix: allow AMA agent to push telemetry through management DCRs"
}
