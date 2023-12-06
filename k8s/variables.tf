variable "egress_gateway_count" {
  description = "Number of Egress Gateways to create"
  type        = string
  default     = "0"
}

variable "egress_gateway_replica_count" {
  description = "Number of pods for each Egress Gateway"
  type        = string
  default     = "0"
}
