
#######################################################  
#       Ingress EndPoints 
#######################################################  

locals {
  base_domain  = "${var.org_id}-${var.cluster_name}.coreweave.app"

  grafana_host = "${var.grafana_host_prefix}.${local.base_domain}"
  vllm_host    = "${var.vllm_host_prefix}.${local.base_domain}"
  # Network string formatting
  net_summary  = join(" | ", [for k, v in { for p in coreweave_networking_vpc.k8s.vpc_prefixes : p.name => p.value } : "${k}: ${v}"])
}
 

output "vllm_stack_summary" {
  value = <<-EOT
✅ CoreWeave CKS cluster deployed successfully!

  🚀 VLLM PRODUCTION STACK ON COREWEAVE 🚀
  -----------------------------------------------------------
  ORG ID            : ${var.org_id}
  CLUSTER           : ${coreweave_cks_cluster.k8s.name} (${coreweave_cks_cluster.k8s.id})
  ENDPOINT          : https://${coreweave_cks_cluster.k8s.api_server_endpoint}
  VPC               : ${coreweave_networking_vpc.k8s.name} (${coreweave_networking_vpc.k8s.zone})
  NETWORKING        : ${local.net_summary}

  🖥️  NODEPOOL INFRASTRUCTURE
  -----------------------------------------------------------
  CPU POOL [${var.cpu_instance_id}] : ${var.enable_nodepool_cpu ? kubectl_manifest.nodepool_cpu["cpu"].name : "Disabled"}
  GPU POOL [${local.gpu_instance_id}] : ${var.enable_nodepool_gpu ? kubectl_manifest.nodepool_gpu["gpu"].name : "Disabled"}
  CPU SCALING       : ${var.enable_nodepool_cpu ? format("[target=%s, min=%s, max=%s, autoscaling=%s]", var.cpu_node_target, var.cpu_node_min, var.cpu_node_max, var.cpu_autoscaling) : "N/A"}
  GPU SCALING       : ${var.enable_nodepool_gpu ? format("[target=%s, min=%s, max=%s, autoscaling=%s]", var.gpu_node_target, var.gpu_node_min, var.gpu_node_max, var.gpu_autoscaling) : "N/A"}
  VLLM CONFIG       : ${var.enable_vllm ? "./${var.gpu_vllm_helm_config}" : "None"}
  
  🌐 ACCESS ENDPOINTS
  -----------------------------------------------------------
  VLLM API          : ${var.enable_vllm ? "https://${local.vllm_host}/v1" : "Disabled"}
  GRAFANA           : ${var.enable_monitoring ? "https://${local.grafana_host}" : "Disabled"}

  🛠️  QUICK START COMMANDS
  -----------------------------------------------------------
  1. Set Context   : export KUBECONFIG="./kubeconfig"
  2. Test Model    : curl -k "https://${local.vllm_host}/v1/models"
  
  Built with ❤️ by @Cloudthrill
  EOT
}