output "configure_kubectl" {
  description = "Configure kubectl: make sure you're logged in with the correct AWS profile and run the following command to update your kubeconfig"
  value       = "aws eks --region ${local.region} update-kubeconfig --name ${module.eks.cluster_name} --alias ${module.eks.cluster_name}"
}

################################################################################
# Cluster
################################################################################

output "cluster_name" {
  description = "Kubernetes Cluster Name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Endpoint for EKS control plane"
  value       = module.eks.cluster_endpoint
}

output "cluster_version" {
  description = "The Kubernetes version for the cluster"
  value       = module.eks.cluster_version
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data required to communicate with the cluster"
  value       = module.eks.cluster_certificate_authority_data
}

output "oidc_provider_arn" {
  description = "The ARN of the OIDC Provider if `enable_irsa = true`"
  value       = module.eks.oidc_provider_arn
}

output "secondary_vpc_public_subnets" {
  description = "List of IDs of public subnets created within the secondary VPC CIDR block"
  value       = [for i in range(length(module.vpc.public_subnets)) : module.vpc.public_subnets[i] if contains(local.secondary_vpc_public_subnets, module.vpc.public_subnets_cidr_blocks[i])]
}

output "secondary_vpc_public_subnets_cidr_blocks" {
  description = "List of CIDR blocks of public subnets created within the secondary VPC CIDR block"
  value       = local.secondary_vpc_public_subnets
}
