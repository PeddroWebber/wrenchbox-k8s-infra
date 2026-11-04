data "azurerm_resource_group" "main" {
  name = var.resource_group_name
}

data "azurerm_key_vault" "main" {
  name                = var.key_vault_name
  resource_group_name = data.azurerm_resource_group.main.name
}

data "azurerm_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

resource "azurerm_log_analytics_workspace" "main" {
  name                = "log-wrenchbox-${random_string.suffix.result}"
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_application_insights" "main" {
  name                = "appi-wrenchbox-${random_string.suffix.result}"
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name
  workspace_id        = azurerm_log_analytics_workspace.main.id
  application_type    = "web"
}

resource "azurerm_key_vault_secret" "app_insights" {
  name         = "applicationinsights-connection-string"
  value        = azurerm_application_insights.main.connection_string
  key_vault_id = data.azurerm_key_vault.main.id
}

resource "azurerm_kubernetes_cluster" "main" {
  name                = "aks-wrenchbox-${random_string.suffix.result}"
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name
  dns_prefix          = "wb${random_string.suffix.result}"

  default_node_pool {
    name       = "system"
    node_count = 1
    vm_size    = "Standard_B2s"
  }

  identity {
    type = "SystemAssigned"
  }

  oms_agent {
    log_analytics_workspace_id      = azurerm_log_analytics_workspace.main.id
    msi_auth_for_monitoring_enabled = true
  }
}

resource "kubernetes_namespace" "app" {
  for_each = toset(["wrenchbox-homolog", "wrenchbox-prod"])

  metadata {
    name = each.key
  }
}

resource "helm_release" "traefik" {
  name             = "traefik"
  repository       = "https://traefik.github.io/charts"
  chart            = "traefik"
  namespace        = "traefik"
  create_namespace = true

  set {
    name  = "ingressClass.enabled"
    value = "true"
  }

  depends_on = [azurerm_kubernetes_cluster.main]
}

resource "azurerm_api_management" "main" {
  name                = "apim-wrenchbox-${random_string.suffix.result}"
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name
  publisher_name      = "WrenchBox"
  publisher_email     = var.alert_email
  sku_name            = "Consumption_0"

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_role_assignment" "apim_secrets" {
  scope                = data.azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_api_management.main.identity[0].principal_id
}

resource "azurerm_api_management_named_value" "jwt" {
  name                = "jwt-secret"
  resource_group_name = data.azurerm_resource_group.main.name
  api_management_name = azurerm_api_management.main.name
  display_name        = "jwt-secret"
  secret              = true
  value_from_key_vault {
    secret_id = "${data.azurerm_key_vault.main.vault_uri}secrets/jwt-secret"
  }
}

resource "azurerm_api_management_named_value" "function_backend" {
  for_each            = toset(["homolog", "prod"])
  name                = "function-backend-${each.key}"
  resource_group_name = data.azurerm_resource_group.main.name
  api_management_name = azurerm_api_management.main.name
  display_name        = "function-backend-${each.key}"
  value               = each.key == "prod" ? var.function_backend_url_prod : var.function_backend_url_homolog
}

resource "azurerm_api_management_named_value" "api_backend" {
  for_each            = toset(["homolog", "prod"])
  name                = "api-backend-${each.key}"
  resource_group_name = data.azurerm_resource_group.main.name
  api_management_name = azurerm_api_management.main.name
  display_name        = "api-backend-${each.key}"
  value               = each.key == "prod" ? var.api_backend_url_prod : var.api_backend_url_homolog
}

resource "azurerm_api_management_api" "main" {
  for_each              = toset(["homolog", "prod"])
  name                  = "wrenchbox-${each.key}"
  resource_group_name   = data.azurerm_resource_group.main.name
  api_management_name   = azurerm_api_management.main.name
  revision              = "1"
  display_name          = "WrenchBox ${each.key}"
  path                  = each.key
  protocols             = ["https"]
  subscription_required = false
}

resource "azurerm_api_management_api_policy" "main" {
  for_each            = azurerm_api_management_api.main
  api_name            = each.value.name
  api_management_name = azurerm_api_management.main.name
  resource_group_name = data.azurerm_resource_group.main.name
  xml_content         = templatefile("${path.module}/policies/gateway.xml", { environment = each.key })
}

resource "azurerm_monitor_action_group" "main" {
  name                = "ag-wrenchbox"
  resource_group_name = data.azurerm_resource_group.main.name
  short_name          = "wrenchbox"

  email_receiver {
    name                    = "ops"
    email_address           = var.alert_email
    use_common_alert_schema = true
  }
}

resource "azurerm_monitor_metric_alert" "cpu" {
  name                = "aks-cpu-high"
  resource_group_name = data.azurerm_resource_group.main.name
  scopes              = [azurerm_kubernetes_cluster.main.id]
  description         = "CPU dos nós do AKS acima de 80%."
  severity            = 2
  frequency           = "PT1M"
  window_size         = "PT5M"

  criteria {
    metric_namespace = "Microsoft.ContainerService/managedClusters"
    metric_name      = "node_cpu_usage_percentage"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 80
  }

  action {
    action_group_id = azurerm_monitor_action_group.main.id
  }
}

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "work_orders" {
  name                 = "work-order-processing-failed"
  resource_group_name  = data.azurerm_resource_group.main.name
  location             = data.azurerm_resource_group.main.location
  description          = "Falha no processamento ou na notificação de ordem de serviço."
  scopes               = [azurerm_application_insights.main.id]
  severity             = 1
  evaluation_frequency = "PT5M"
  window_duration      = "PT5M"

  criteria {
    query                   = <<-KQL
      traces
      | where message has "WorkOrderProcessingFailed"
    KQL
    time_aggregation_method = "Count"
    operator                = "GreaterThan"
    threshold               = 0

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.main.id]
  }
}

resource "azurerm_application_insights_standard_web_test" "health" {
  name                    = "uptime-wrenchbox-${random_string.suffix.result}"
  resource_group_name     = data.azurerm_resource_group.main.name
  location                = data.azurerm_resource_group.main.location
  application_insights_id = azurerm_application_insights.main.id
  geo_locations           = ["us-fl-mia-edge"]
  frequency               = 300
  timeout                 = 30
  enabled                 = true

  request {
    url = "https://${azurerm_api_management.main.name}.azure-api.net/homolog/health"
  }
}
