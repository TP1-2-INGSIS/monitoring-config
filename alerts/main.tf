#############################################################################
# Alertas de New Relic como código (Terraform)
#############################################################################
# Define una policy con 3 condiciones de alerta sobre las métricas que el
# agente Java APM ya reporta automáticamente. Es config compartida: se puede
# aplicar por servicio pasando distinto `app_name`.
#
# Requisitos:
#   - Terraform >= 1.5
#   - Variables de entorno o -var con:
#       NEW_RELIC_ACCOUNT_ID  -> TF_VAR_account_id
#       NEW_RELIC_API_KEY     -> User API key (NO la license key)
#
# Uso:
#   cd alerts
#   terraform init
#   terraform apply -var 'app_name=assets'
#############################################################################

terraform {
  required_version = ">= 1.5"
  required_providers {
    newrelic = {
      source  = "newrelic/newrelic"
      version = "~> 3.40"
    }
  }
}

provider "newrelic" {
  account_id = var.account_id
  api_key    = var.api_key
  region     = var.region
}

#############################################################################
# Variables
#############################################################################

variable "account_id" {
  description = "ID de la cuenta de New Relic."
  type        = number
}

variable "api_key" {
  description = "User API key de New Relic (NRAK-...). No es la license key."
  type        = string
  sensitive   = true
}

variable "region" {
  description = "Región de la cuenta: US o EU."
  type        = string
  default     = "US"
}

variable "app_name" {
  description = "Nombre del servicio tal como aparece en APM (NEW_RELIC_APP_NAME)."
  type        = string
}

variable "fivexx_threshold" {
  description = "Cantidad de respuestas 5xx en la ventana que dispara la alerta (la 'X')."
  type        = number
  default     = 5
}

variable "error_rate_threshold_pct" {
  description = "Porcentaje de transacciones con error que dispara la alerta."
  type        = number
  default     = 5
}

variable "notification_emails" {
  description = "Emails que reciben las notificaciones de alerta."
  type        = list(string)
  default     = []
}

#############################################################################
# Policy
#############################################################################

resource "newrelic_alert_policy" "service" {
  name                = "${var.app_name} - alertas"
  incident_preference = "PER_CONDITION" # un incidente por condición disparada
}

#############################################################################
# Alerta 1 — Exceso de respuestas 5xx (conteo absoluto)
# Cuenta las transacciones web que terminaron en un status 5xx.
#############################################################################

resource "newrelic_nrql_alert_condition" "http_5xx_count" {
  account_id = var.account_id
  policy_id  = newrelic_alert_policy.service.id
  name       = "Exceso de respuestas 5xx"
  type       = "static"
  enabled    = true

  nrql {
    query = <<-NRQL
      SELECT count(*) FROM Transaction
      WHERE appName = '${var.app_name}'
        AND httpResponseCode LIKE '5%'
    NRQL
  }

  # Se dispara si en 5 minutos hay más de `fivexx_threshold` respuestas 5xx.
  critical {
    operator              = "above"
    threshold             = var.fivexx_threshold
    threshold_duration    = 300
    threshold_occurrences = "all"
  }

  aggregation_window = 60
  aggregation_method = "event_flow"
  aggregation_delay  = 120
}

#############################################################################
# Alerta 2 — Error rate (%) alto
# Proporción de transacciones con error sobre el total. Capta degradación
# aunque el volumen sea distinto al de la alerta de conteo.
#############################################################################

resource "newrelic_nrql_alert_condition" "error_rate" {
  account_id = var.account_id
  policy_id  = newrelic_alert_policy.service.id
  name       = "Error rate alto"
  type       = "static"
  enabled    = true

  nrql {
    query = <<-NRQL
      SELECT percentage(count(*), WHERE error IS true) FROM Transaction
      WHERE appName = '${var.app_name}'
    NRQL
  }

  critical {
    operator              = "above"
    threshold             = var.error_rate_threshold_pct
    threshold_duration    = 300
    threshold_occurrences = "all"
  }

  aggregation_window = 60
  aggregation_method = "event_flow"
  aggregation_delay  = 120
}

#############################################################################
# Alerta 3 — Latencia / degradación de performance
# Un servicio puede devolver 200 pero estar lento. Alerta si el p95 de la
# duración de las transacciones web supera el umbral.
#############################################################################

resource "newrelic_nrql_alert_condition" "latency_p95" {
  account_id = var.account_id
  policy_id  = newrelic_alert_policy.service.id
  name       = "Latencia p95 alta"
  type       = "static"
  enabled    = true

  nrql {
    query = <<-NRQL
      SELECT percentile(duration, 95) FROM Transaction
      WHERE appName = '${var.app_name}'
        AND transactionType = 'Web'
    NRQL
  }

  # p95 por encima de 2 segundos durante 5 minutos.
  critical {
    operator              = "above"
    threshold             = 2
    threshold_duration    = 300
    threshold_occurrences = "all"
  }

  aggregation_window = 60
  aggregation_method = "event_flow"
  aggregation_delay  = 120
}

#############################################################################
# Notificaciones (opcional) — canal de email conectado a la policy.
# Si no pasás notification_emails, la policy queda sin canal (las alertas
# igual se ven en la UI de New Relic).
#############################################################################

resource "newrelic_notification_destination" "email" {
  count      = length(var.notification_emails) > 0 ? 1 : 0
  account_id = var.account_id
  name       = "${var.app_name} - email"
  type       = "EMAIL"

  property {
    key   = "email"
    value = join(",", var.notification_emails)
  }
}

resource "newrelic_notification_channel" "email" {
  count          = length(var.notification_emails) > 0 ? 1 : 0
  account_id     = var.account_id
  name           = "${var.app_name} - email channel"
  type           = "EMAIL"
  destination_id = newrelic_notification_destination.email[0].id
  product        = "IINT"

  property {
    key   = "subject"
    value = "Alerta New Relic: ${var.app_name}"
  }
}

resource "newrelic_workflow" "email" {
  count                 = length(var.notification_emails) > 0 ? 1 : 0
  account_id            = var.account_id
  name                  = "${var.app_name} - workflow"
  muting_rules_handling = "NOTIFY_ALL_ISSUES"

  issues_filter {
    name = "policy-filter"
    type = "FILTER"

    predicate {
      attribute = "labels.policyIds"
      operator  = "EXACTLY_MATCHES"
      values    = [newrelic_alert_policy.service.id]
    }
  }

  destination {
    channel_id = newrelic_notification_channel.email[0].id
  }
}
