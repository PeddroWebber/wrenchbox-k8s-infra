output "aks_name" {
  value = azurerm_kubernetes_cluster.main.name
}

output "resource_group_name" {
  value = data.azurerm_resource_group.main.name
}

output "api_management_gateway" {
  value = azurerm_api_management.main.gateway_url
}

output "application_insights_name" {
  value = azurerm_application_insights.main.name
}
