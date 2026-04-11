# output "Stack_Info" {
#   value = "Built with ❤️ by @Cloudthrill"
# }
# output "cluster_name" {
#   value = module.eks.cluster_name
# }

# output "cluster_endpoint" {
#   value = module.eks.cluster_endpoint
# }

# output "vpc_id" {
#   value = module.vpc.vpc_id
# }

# output "private_subnets" {
#   value = module.vpc.private_subnets
# }
# output "public_subnets" {
#   value = module.vpc.public_subnets
# }

locals {
  # Extracts unique AZs and creates a single string: "us-east-2a, us-east-2b"
  cluster_azs = join(", ", tolist(toset([for s in data.aws_subnet.cluster_public_subnets : s.availability_zone])))
}
# output "configure_kubectl" {
#   description = "Configure kubectl: make sure you're logged in with the correct AWS profile and run the following command to update your kubeconfig"
#   value       = "aws eks --region ${var.region} update-kubeconfig --name ${module.eks.cluster_name}"
#   sensitive   = true
# }

# output "kubeconfig_path" {
#   description = "Local path to the generated kubeconfig"
#   value       = local_file.kubeconfig.filename
#   sensitive   = true
# }

##### Network outputs #####
# output "vpc_cidr" {
#   value = data.aws_vpc.selected.cidr_block
# }

# # Output for cluster subnets  
# output "cluster_subnets_info" {
#   description = "Information about private subnets used by the EKS cluster"
#   value = {
#     for s in data.aws_subnet.cluster_subnets :
#     s.id => {
#       id                = s.id
#       cidr              = s.cidr_block
#       tags              = s.tags
#       name              = lookup(s.tags, "Name", "")
#       availability_zone = s.availability_zone
#     }
#   }
# }

# output "cluster_public_subnets_info" {
#   description = "Information about public subnets used by the EKS cluster"
#   value = {
#     for s in data.aws_subnet.cluster_public_subnets :
#     s.id => {
#       id                = s.id
#       cidr              = s.cidr_block
#       tags              = s.tags
#       name              = lookup(s.tags, "Name", "")
#       availability_zone = s.availability_zone
#     }
#   }
# }

# output "grafana_forward_cmd" {
#   description = "Command to forward Grafana port"
#   value       = "kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n kube-prometheus-stack"
# }

# # Output that defaults to null when no ingress exists  
# output "vllm_ingress_hostname" {
#   description = "The hostname of the vLLM ingress load balancer (null if no ingress configured)"
#   value = var.enable_vllm && var.enable_lb_ctl ? try(
#     data.kubernetes_ingress_v1.vllm_ingress[0].status[0].load_balancer[0].ingress[0].hostname,
#     null # Explicitly return null if ingress doesn't exist or has no hostname  
#   ) : null
#   depends_on = [helm_release.vllm_stack]
# }

# output "vllm_api_url" {
#   description = "Full HTTPS URL for the vLLM API (null until hostname exists)"
#   value = var.enable_vllm && var.enable_lb_ctl ? try(
#     "http://${data.kubernetes_ingress_v1.vllm_ingress[0].status[0].load_balancer[0].ingress[0].hostname}/v1",
#     null
#   ) : null
#   depends_on = [helm_release.vllm_stack]
# }

####################################################################
# Instance Types Configuration
# output "gpu_node_instance_type" {
#   description = "Instance types configured for GPU nodes"
#   value       = var.gpu_node_instance_types
# }

# output "cpu_node_instance_type" {
#   description = "Instance types configured for CPU nodes"
#   value       = var.cpu_node_instance_types
# }

# ################################################################
# # S3 Storage Output
# ################################################################

# output "s3_bucket" {
#   description = "S3 bucket name for vLLM models"
#   value       = var.enable_s3_csi_driver ? local.s3_bucket_name : null
# }

# output "s3_csi_driver_role_arn" {
#   description = "IAM role ARN for S3 CSI driver"
#   value       = var.enable_s3_csi_driver ? aws_iam_role.s3_csi_driver[0].arn : null
# }

####################################################################
# 🚀 TERMINAL UI SUMMARY
####################################################################

output "aws_vllm_stack_summary" {
  description = "Human-readable summary of the AWS EKS vLLM deployment"
  value = <<-EOT

  ✅ AWS EKS Cluster deployed successfully!

  🚀 VLLM PRODUCTION STACK ON AWS EKS 🚀
  -----------------------------------------------------------
  REGION             : ${var.region}
  AVAILABILITY ZONES : ${local.cluster_azs} 
  API ENDPOINT       : ${module.eks.cluster_endpoint}
  VPC ID             : ${module.vpc.vpc_id} (${data.aws_vpc.selected.cidr_block})

  🖥️  INFRASTRUCTURE & STORAGE
  -----------------------------------------------------------
  CPU NODES         : [${try(join(", ", var.cpu_node_instance_types), var.cpu_node_instance_types)}]
  GPU NODES         : [${try(join(", ", var.gpu_node_instance_types), var.gpu_node_instance_types)}]
  S3 MODEL BUCKET   : ${var.enable_s3_csi_driver ? local.s3_bucket_name : "Disabled"}
  S3 CSI ROLE       : ${var.enable_s3_csi_driver ? aws_iam_role.s3_csi_driver[0].arn : "N/A"}

  🧠  MODEL CONFIGURATION
  -----------------------------------------------------------
  HF SOURCE ID      : ${var.huggingface_model_id}
  API MODEL URL     : /models/${local.s3_models["tiny"]}

  🌐 ACCESS ENDPOINTS
  -----------------------------------------------------------
  VLLM API URL      : ${var.enable_vllm && var.enable_lb_ctl ? try("http://${data.kubernetes_ingress_v1.vllm_ingress[0].status[0].load_balancer[0].ingress[0].hostname}/v1", "Pending ALB Provisioning...") : "Disabled"}
  GRAFANA FORWARD   : kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n kube-prometheus-stack

  🛠️  QUICK START COMMANDS
  -----------------------------------------------------------
  1. Set Context    : export KUBECONFIG="./kubeconfig"
  2. Test API       : curl -k "${var.enable_vllm && var.enable_lb_ctl ? try("http://${data.kubernetes_ingress_v1.vllm_ingress[0].status[0].load_balancer[0].ingress[0].hostname}/v1/models", "<VLLM_API_URL>/v1/models") : "<VLLM_API_URL>/v1/models"}"
   
  Built with ❤️ by @Cloudthrill
  EOT
}