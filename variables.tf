variable "resource_group_name" {
  type    = string
  default = "rg-wrenchbox"
}

variable "key_vault_name" {
  type = string
}

variable "alert_email" {
  type    = string
  default = "admin@wrenchbox.local"
}

variable "function_backend_url_homolog" {
  type    = string
  default = "https://placeholder-homolog.azurewebsites.net"
}

variable "function_backend_url_prod" {
  type    = string
  default = "https://placeholder-prod.azurewebsites.net"
}

variable "api_backend_url_homolog" {
  type    = string
  default = "http://traefik.traefik.svc.cluster.local"
}

variable "api_backend_url_prod" {
  type    = string
  default = "http://traefik.traefik.svc.cluster.local"
}
