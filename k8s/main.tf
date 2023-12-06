# Fetch remote Terraform state
data "terraform_remote_state" "aws_tfstate" {
  backend = "local"
  config = {
    path = "${path.root}/../aws/terraform.tfstate"
  }
}

# EKS cluster authentication data
data "aws_eks_cluster_auth" "this" {
  name = data.terraform_remote_state.aws_tfstate.outputs.cluster_name
}

# Current AWS region data
data "aws_region" "current" {}

locals {

  # Extract all CIDR blocks from the remote Terraform state
  all_cidrs_from_remote_state = data.terraform_remote_state.aws_tfstate.outputs.secondary_vpc_public_subnets_cidr_blocks

  # Extract egress gateway subnets from the remote Terraform state
  egress_gateway_subnets = data.terraform_remote_state.aws_tfstate.outputs.secondary_vpc_public_subnets

  # Calculate broadcast addresses for each CIDR block
  broadcast_addresses = [for cidr in local.all_cidrs_from_remote_state : cidrhost(cidr, -1)]

  # Calculate the first 4 IPs of each CIDR block
  first_four_ips_of_each_cidr = [
    for cidr in local.all_cidrs_from_remote_state :
    cidrsubnet(cidr, 30 - tonumber(split("/", cidr)[1]), 0)
  ]

  # Combine broadcast addresses and the first 4 IPs to create the list of AWS reserved CIDRs
  reserved_cidrs = flatten([local.broadcast_addresses, local.first_four_ips_of_each_cidr])

  # Split each CIDR block from the remote state into two halves: 
  # The 'top' half represents the first half of the available address space, 
  # and the 'bottom' half represents the second half of the available address space.

  # Top halves of CIDR blocks
  top_halves_of_cidrs = [
    for cidr in local.all_cidrs_from_remote_state :
    cidrsubnet(cidr, 1, 0)
  ]

  # Bottom halves of CIDR blocks
  bottom_halves_of_cidrs = [
    for cidr in local.all_cidrs_from_remote_state :
    cidrsubnet(cidr, 1, 1)
  ]

  # Associate each CIDR block (both top and bottom halves) with its corresponding subnet from the remote state.
  # This creates a mapping where the key is the CIDR block and the value is the associated subnet.

  # Mapping of top halves of CIDR blocks to their corresponding subnets
  top_cidr_to_associated_subnet = {
    for i in range(length(local.top_halves_of_cidrs)) :
    local.top_halves_of_cidrs[i] => local.egress_gateway_subnets[i]
  }

  # Mapping of bottom halves of CIDR blocks to their corresponding subnets
  bottom_cidr_to_associated_subnet = {
    for i in range(length(local.bottom_halves_of_cidrs)) :
    local.bottom_halves_of_cidrs[i] => local.egress_gateway_subnets[i]
  }

  # Egress gateway configurations
  egress_gateway_count         = var.egress_gateway_count
  egress_gateway_replica_count = var.egress_gateway_replica_count

  # Split CIDR into /29s for egress gateways
  split_cidr_into_29s = {
    for cidr, subnet in local.bottom_cidr_to_associated_subnet : cidr => [
      for i in range(0, local.egress_gateway_count) :
      {
        "cidr"       = cidrsubnet(cidr, 29 - tonumber(split("/", cidr)[1]), i),
        "subnet_id"  = subnet,
        "pair_index" = i + 1
      }
    ]
  }

  # Flatten and map CIDRs to subnets for /29s
  cidr_to_subnet_bottom_29s = { for item in flatten([for cidrs in local.split_cidr_into_29s : cidrs]) : "${item.pair_index}-${item.subnet_id}" => item }

  # Group egress workloads by their associated pair index
  egress_workloads_grouped_by_pair_index = {
    for subnet_key, subnet_value in local.cidr_to_subnet_bottom_29s :
    subnet_value.pair_index => ["egress-workload-${replace(replace(subnet_key, ".", "-"), "/", "-")}"]...
  }

  # Generate EIP keys for each egress gateway and its replicas
  eip_keys = flatten([
    for gateway in range(1, local.egress_gateway_count + 1) :
    [for replica in range(1, local.egress_gateway_replica_count + 1) :
    "${gateway}-${replica}"]
  ])

  # Group EIPs by their associated pair index
  eip_grouped_by_pair_index = {
    for eip_key in local.eip_keys :
    eip_key => [aws_eip.egress_eip[eip_key].public_ip]
  }

}

# Kubernetes provider configuration
provider "kubernetes" {
  host                   = data.terraform_remote_state.aws_tfstate.outputs.cluster_endpoint
  cluster_ca_certificate = base64decode(data.terraform_remote_state.aws_tfstate.outputs.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", data.terraform_remote_state.aws_tfstate.outputs.cluster_name]
  }
}

# Resources
resource "kubernetes_manifest" "aws_ip_reservations" {
  manifest = {
    "apiVersion" = "projectcalico.org/v3"
    "kind"       = "IPReservation"
    "metadata" = {
      "name" = "aws-ip-reservations"
    }
    "spec" = {
      "reservedCIDRs" = local.reserved_cidrs
    }
  }
}

resource "kubernetes_manifest" "host_secondary_ippools" {
  for_each = local.top_cidr_to_associated_subnet

  manifest = {
    "apiVersion" = "projectcalico.org/v3"
    "kind"       = "IPPool"
    "metadata" = {
      "name" = "egress-secondary-${each.value}"
    }
    "spec" = {
      "allowedUses"      = ["HostSecondaryInterface"]
      "awsSubnetID"      = each.value
      "blockSize"        = 32
      "cidr"             = each.key
      "disableBGPExport" = true
    }
  }
}

resource "kubernetes_manifest" "workload_ippools" {
  for_each = local.cidr_to_subnet_bottom_29s

  manifest = {
    "apiVersion" = "projectcalico.org/v3"
    "kind"       = "IPPool"
    "metadata" = {
      "name" = "egress-workload-${replace(replace(each.key, ".", "-"), "/", "-")}"
    }
    "spec" = {
      "allowedUses"      = ["Workload"]
      "awsSubnetID"      = each.value.subnet_id
      "blockSize"        = 32
      "cidr"             = each.value.cidr
      "disableBGPExport" = true
      "nodeSelector"     = "!all()"
    }
  }
}

resource "aws_eip" "egress_eip" {
  for_each = { for key in local.eip_keys : key => key }

  tags = {
    Name = "EIP-for-EGW-${each.key}"
  }
}

resource "kubernetes_manifest" "calico_egress_gateways" {
  for_each = local.egress_workloads_grouped_by_pair_index

  manifest = {
    "apiVersion" = "operator.tigera.io/v1"
    "kind"       = "EgressGateway"
    "metadata" = {
      "name"      = "egw-${each.key}"
      "namespace" = "default"
    }
    "spec" = {
      "ipPools"     = [for pool_name in each.value : { "name" = pool_name[0] }]
      "logSeverity" = "Info"
      "replicas"    = local.egress_gateway_replica_count
      "aws" = {
        "nativeIP"   = "Enabled"
        "elasticIPs" = [for replica in range(1, local.egress_gateway_replica_count + 1) : aws_eip.egress_eip["${each.key}-${replica}"].public_ip]
      }
      "template" = {
        "metadata" = {
          "labels" = {
            "egress-gateway" = "egw-${each.key}"
          }
        }
        "spec" = {
          "nodeSelector" = {
            "kubernetes.io/os" = "linux"
          }
          "terminationGracePeriodSeconds" = 0
          "topologySpreadConstraints" = [
            {
              "labelSelector" = {
                "matchLabels" = {
                  "egress-gateway" = "egw-${each.key}"
                }
              }
              "maxSkew"           = 1
              "topologyKey"       = "topology.kubernetes.io/zone"
              "whenUnsatisfiable" = "DoNotSchedule"
            },
          ]
        }
      }
    }
  }

  depends_on = [
    resource.aws_eip.egress_eip
  ]
}
