# 🧑🏼‍🚀 vLLM Production Stack on Amazon EKS - S3 Mountpoint 

<img width="1536" height="1024" alt="vllm_prod-stack-eks-s3" src="https://github.com/user-attachments/assets/ab2fa28a-2ac3-4c01-ac19-a2225ceda960" />

✍🏼This Terraform stack delivers a **production-ready vLLM serving environment** on Amazon EKS. It decouples model storage from compute using the **AWS Mountpoint for Amazon S3 CSI Driver** (no EBS needed) and leverages customized pod scheduling to bypass strict GPU locking, allowing multiple engine replicas to share a single cloud GPU and model weights through S3 mounted Extravolumes.

| Project Item | Description |
| :--- | :--- |
| **Author** | [@cloudthrill](https://cloudthrill.ca) |
| **Stack** | Terraform ◦ AWS ◦ EKS ◦ S3 ◦ Calico ◦ Helm ◦ vLLM |
| **Module** |  S3-storage EKS blueprint for enterprise-grade vLLM clusters |
| **CNI** | AWS VPC with full-overlay **Calico** network |
| **Hardware** | Toggleable **CPU** or **GPU** via feature flag |

## 📑 Table of Contents
- [✨ Architectural Highlights](#-architectural-highlights)
  - [1. The Storage Model: Streams, Not Syncs](#1-the-storage-model-streams-not-syncs)
  - [2. The "subPath" Containment](#2-the-subpath-containment)
  - [3. Multi-Pod per GPU Setup](#3-multi-pod-per-gpu-setup)
- [🏗️ Core Infrastructure Components](#️-core-infrastructure-components)
- [🧮 Hardware & VRAM Profiling](#-hardware--vram-profiling-nvidia-l4--g62xlarge)
- [⏱️ The Boot Bottleneck](#️-the-boot-bottleneck)
- [🏗️ Terraform Provisioning Flow](#️-terraform-provisioning-flow)
- [🚀 Quick Start & Deployment](#-quick-start--deployment)
  - [Prerequisites](#prerequisites)
  - [1. Provision & Automated Bootstrap](#1-provision--automated-bootstrap)
  - [2. Observe the Boot Sequence](#2-observe-the-boot-sequence)
  - [3. Test Load Balancing](#3-test-load-balancing)

---
>[!Note]
> This deployment is an extension of our foundational [Vllm-EKS stack](https://cloudthrill.ca/vllm-production-stack-on-eks-terraform), leveraging [AWS integration and automation](https://github.com/aws-ia) modules. The only difference is the S3 mount integration for model storage.

## 📂 Project Structure

```bash
./
├── main.tf
├── network.tf
├── storage.tf
├── provider.tf
├── variables.tf
├── output.tf
├── cluster-tools.tf
├── datasources.tf
├── iam_role.tf
├── vllm-production-stack.tf
├── env-vars.template
├── terraform.tfvars.template
├── modules/
│   ├── aws-networking/   # remote module
│   │   └── aws-vpc/      # remote module
│   ├── aws-eks/           # remote module
│   ├── eks-blueprints-addons/     # remote module
|   ├── eks-data-addons|           # remote module
│   └── llm-stack                  
|       ├── helm|                  
|           ├── cpu|               
|           └── gpu| gpu-tinyllama-light-ingress-s3.tpl  <<-- Our Vllm deployment chart using s3 as a PVC                
├── config/
│   ├── calico-values.tpl
│   └── kubeconfig.tpl
└── README.md                          # ← you are here

```

## ⚙️ Provisioning Highlights
Loading massive weight files into to EBS volumes per each replica limits horizontal scaling and inflates costs. We bypass this entirely:

> 💡 **Note:** If you are looking for standard EBS-based model storage, use the [`eks-base`](../eks-base) stack instead.

* ✅ **Streams, Not Syncs** (`cluster-tools.tf`)<br>
  The AWS Mountpoint CSI Driver streams `model.safetensors` directly from S3 into GPU VRAM, keeping compute nodes 100% stateless.

* ✅ **S3 "subPath" Containment** (`storage.tf`)<br>
  Mounts a strict S3 prefix per model (e.g., `subPath: $${s3_my_model}`) to guarantee bucket isolation and prevent Out-Of-Memory crashes from "Poisoned Folders."

* ✅ **Multi-Pod GPU Scaling** (`gpu-tinyllama-light-ingress-s3.tpl`)<br>
  Bypasses the K8s hardware lock (by omitting `requestGPU: 1`) and injects `--gpu-memory-utilization=0.40` so multiple pod replicas can safely share a single physical GPU.

* 🏁🛑 **Race Condition Guards**

| Guard Type | Purpose | Behavior |
|------------|---------|----------|
| **Phantom Dependency** | Prevents premature Helm deployment | Forces the Terraform Helm release to wait until the `local-exec` S3 model bootstrap is 100% complete |
| **`bootstrap_model_to_s3`** | Guarantees Model Weight Availability | Checks the S3 prefix. If empty, automatically downloads the HuggingFace model and syncs it to S3, If prefix and weights exist do nothing.|


> 💡 **Note:** If you are looking for standard EBS-based model storage, use the [`eks-base`](../eks-base) stack instead.
---
## ✅ Prerequisites

| Tool | Version | Notes |
| :--- | :--- | :--- |
| **Terraform** | 1.9.8 | tested on 1.9.8 |
| **AWS CLI v2** | ≥ 2.16 | profile / SSO auth |
| **kubectl** | ≥ 1.32 | ±1 of control-plane |
| **helm** | ≥ 3.14 | used by `helm_release` |
|**huggingface-cli**|1.9.0| Installed locally (for the automated bootstrap)
---
<details>
 <summary><b>Follow steps to Install tools (Ubuntu/Debian) below 👇🏼</b></summary>

 ```bash
# Install tools
# 1. Terraform
sudo apt update && sudo apt install -y jq curl unzip gpg
wget -qO- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install -y terraform

# 2. AWS CLI
curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" && unzip -q awscliv2.zip && sudo ./aws/install && rm -rf aws awscliv2.zip

# 3. Kubectl
curl -sLO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && sudo install kubectl /usr/local/bin/ && rm kubectl

# 4. Hugging-face CLI
pipx install huggingface-hub

```

</details>

**Configure AWS**

```bash
aws configure --profile myprofile
export AWS_PROFILE=myprofile        # ← If null Terraform exec auth will use the default profile
```

## 🏗️ Core Infrastructure Components
The deployment provisions the required infrastructure based on your hardware selection. **IMPORTANT:** S3 deployment is only supporting the gpu mode.

| Phase | Component | Action | Condition |
|-------|-----------|--------|-----------|
| **1. Infrastructure** | VPC | Provision VPC with 3 public + 3 private subnets | Always |
| | EKS | Deploy v1.30 cluster + CPU node group (t3a.large) | Always |
| | CNI | Remove aws-node, install Calico overlay (VXLAN) | Always |
| | Add-ons | Deploy EBS CSI, ALB controller, kube-prometheus | Always |
| **2. vLLM Stack** | | | `enable_vllm = true` |
| | HF secret| Deploy Create `hf-token-secret` for Hugging Face | `enable_vllm = true` |
| | CPU Deployment | Deploy vLLM on existing CPU nodes | `inference_hardware = "cpu"` |
| | GPU Infrastructure | Provision GPU node group (g5.xlarge) | `inference_hardware = "gpu"` |
| | GPU Operator | Deploy NVIDIA operator/plugin | `inference_hardware = "gpu"` |
| | GPU Deployment | Deploy vLLM on GPU nodes with scheduling | `inference_hardware = "gpu"` |
| | Application | Deploy TinyLlama-1.1B Helm chart to `vllm` namespace | `enable_vllm = true` |
| **3. Networking** | Load Balancer | Configure ALB and ingress for external access | `enable_vllm = true` |
| **4. model storage** | PVC mounted from S3 | Crate S3 Bucket+ load from HF + install S3 CSI Driver + create PV/PVC | -> `/models/<model>` |
 
---
## 🏗️ Terraform Provisioning Flow
This deployment utilizes a "phantom dependency" chain (checking S3, seeding if missing, then rendering the Helm template) to ensure race conditions never occur. From a cold start, the entire infrastructure stack provisions in **~24 minutes**:

| Stage                 | Start    | End      | Duration    |
| ----------------------- | -------- | -------- | ----------- |
| **IAM & S3** | 03:23:02 | 03:23:17 | ~15s        |
| **VPC** | 03:23:02 | 03:25:16 | ~2m 14s     |
| **EKS Control Plane** | 03:25:16 | 03:31:21 | ~6m 5s      |
| **Node Groups** | 03:32:04 | 03:33:53 | ~1m 49s     |
| **Add-ons (Core)** | 03:33:53 | 03:35:53 | ~2m         |
| **Add-ons (Helm)** | 03:35:53 | 03:38:39 | ~2m 46s     |
| **S3 CSI Driver** | 03:38:39 | 03:38:47 | ~8s         |
| **Calico + GPU Plugin** | 03:38:47 | 03:39:15 | ~28s        |
| **vLLM Stack(1Router+ 2Engines+ S3 model load+ Ovservability)** | 03:39:15 | 03:47:29 | **~8m 14s** |
| **Total Deployment Time** | 03:23:02 | 03:47:29 | **~24 minutes** |

---
## 🔍 S3 Mountpoint & GPU  Walkthrough

This build uses a highly specific Terraform sequence to orchestrate the S3 streaming and VRAM partitioning. 

>[!note]
> **AWS Mountpoint** is strictly an API translator. It intercepts pod filesystem reads (like `ls` or `cat`) and translates them into native `s3:ListObjectsV2` and `s3:GetObject` API calls.

### 1. The Automated S3 Bootstrap (Execution Barrier)
Before Helm deploys the vLLM pods, this `local-exec` block checks S3. If the model weights are missing, it downloads them locally via the `huggingface-cli` and syncs them to the bucket, acting as a deployment gate.
* **S3 Bucket Provisioning:** Creates a dedicated bucket for model weights. (terraform resource)

<details>
<summary><b>View the Automated S3 Bootstrapping Code (Terraform)</b></summary>

```hcl
resource "terraform_data" "bootstrap_model_to_s3" {
  count = var.enable_vllm && var.enable_s3_model_storage && var.bootstrap_model_to_s3 ? 1 : 0

  triggers_replace = [
    local.s3_bucket_name,
    local.model_s3_paths["tiny"],
    var.huggingface_model_id
  ]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]

    environment = {
      HF_TOKEN = var.hf_token
    }

    command = <<-EOT
      set -euo pipefail

      # Cleanly export the AWS profile only if one is provided
      %{if local.aws_profile != ""}
      export AWS_PROFILE="${local.aws_profile}"
      %{endif}

      BUCKET="${local.s3_bucket_name}"
      PREFIX="${local.model_s3_paths["tiny"]}"
      HF_MODEL="${var.huggingface_model_id}"
      TMP_DIR="$(mktemp -d)"
      MIN_SIZE_BYTES=1000000000

      trap 'rm -rf "$TMP_DIR"' EXIT

      echo "Checking if model exists in s3://$BUCKET/$PREFIX/"
      # 1. Check for the config file
      HAS_CONFIG=0
      if aws s3 ls "s3://$BUCKET/$PREFIX/config.json" >/dev/null 2>&1; then
        HAS_CONFIG=1
      fi
      # 2. Check total directory size to prevent partial uploads
      SIZE=$(aws s3 ls "s3://$BUCKET/$PREFIX/" --recursive --summarize 2>/dev/null | awk '/Total Size:/ {print $3}' || true)
      SIZE=$${SIZE:-0}

      if [ "$HAS_CONFIG" -eq 1 ] && [ "$SIZE" -gt "$MIN_SIZE_BYTES" ]; then
        echo "Model already exists in S3 (config.json found, size: $SIZE bytes). Skipping bootstrap."
        exit 0
      fi

      echo "Model not found or incomplete. Downloading from Hugging Face: $HF_MODEL"
      hf download "$HF_MODEL" --local-dir "$TMP_DIR"

      echo "Uploading model to s3://$BUCKET/$PREFIX/"
      aws s3 sync "$TMP_DIR/" "s3://$BUCKET/$PREFIX/" --exclude ".cache/*" --only-show-errors

      echo "Bootstrap complete."
    EOT
  }

  depends_on = [
    aws_s3_bucket.vllm_models
  ]
}
```
</details>


### 2. S3 Mountpoint CSI Driver (Helm)
Deployed through helm, to allow to mount the S3 bucket locally and stream weights into GPU. It is deployed in `kube-system` namespace, allowing standard Kubernetes PV to target S3 buckets.

```hcl
# cluster-tools.tf snippet
resource "helm_release" "aws_mountpoint_s3_csi_driver" {
  name       = "aws-mountpoint-s3-csi-driver"
  repository = "[https://aws.github.io/eks-charts](https://aws.github.io/eks-charts)"
  chart      = "aws-mountpoint-s3-csi-driver"
  namespace  = "kube-system"
  version    = "1.2.0" 

  set {
    name  = "node.tolerateAllTaints"
    value = "true"
  }
}
```

### 3. IAM & Storage Containment (IRSA + PV/PVC)
We use IAM Roles for Service Accounts (IRSA) to grant the S3 CSI driver (pods) least-privilege access, and provision a massive `1200Ti` Persistent Volume (since S3 is effectively infinite).

<details>
<summary><b>View the S3 storage deployment Code (Terraform)</b></summary>

  ```hcl
  # storage.tf snippet
  
  resource "aws_s3_bucket" "vllm_models" {
    count  = var.enable_s3_model_storage && var.create_s3_bucket ? 1 : 0
    bucket = var.s3_bucket
    force_destroy = true
    tags = merge(
      var.tags,
      {
        Name    = var.s3_bucket
        Purpose = "vLLM model storage"
      }
    )
  
    # lifecycle {
    #   prevent_destroy = true # Prevent accidental deletion of model bucket
    # }
  }
  
  resource "aws_s3_bucket_server_side_encryption_configuration" "vllm_models" {
    count  = var.enable_s3_model_storage && var.create_s3_bucket ? 1 : 0
    bucket = aws_s3_bucket.vllm_models[0].id
  
    rule {
      apply_server_side_encryption_by_default {
        sse_algorithm = "AES256"
      }
    }
  }
  
  resource "aws_s3_bucket_public_access_block" "vllm_models" {
    count  = var.enable_s3_model_storage && var.create_s3_bucket ? 1 : 0
    bucket = aws_s3_bucket.vllm_models[0].id
  
    block_public_acls       = true
    block_public_policy     = true
    ignore_public_acls      = true
    restrict_public_buckets = true
  }
  
  #--------------------------------------------------------------
  # IAM for Mountpoint S3 CSI driver
  # Assumes cluster-tools.tf will create/annotate:
  # kube-system / s3-csi-driver-sa
  #--------------------------------------------------------------
  
  data "aws_iam_policy_document" "s3_csi_driver_assume_role" {
    count = var.enable_s3_csi_driver ? 1 : 0
  
    statement {
      effect  = "Allow"
      actions = ["sts:AssumeRoleWithWebIdentity"]
  
      principals {
        type        = "Federated"
        identifiers = [module.eks.oidc_provider_arn]
      }
  
      condition {
        test     = "StringEquals"
        variable = "${replace(module.eks.oidc_provider, "https://", "")}:sub"
        values   = ["system:serviceaccount:kube-system:s3-csi-driver-sa"]
      }
  
      condition {
        test     = "StringEquals"
        variable = "${replace(module.eks.oidc_provider, "https://", "")}:aud"
        values   = ["sts.amazonaws.com"]
      }
    }
  }
  
  resource "aws_iam_role" "s3_csi_driver" {
    count              = var.enable_s3_csi_driver ? 1 : 0
    name_prefix        = "${module.eks.cluster_name}-s3-csi-driver-"
    assume_role_policy = data.aws_iam_policy_document.s3_csi_driver_assume_role[0].json
  
    tags = merge(
      var.tags,
      {
        Name = "${module.eks.cluster_name}-s3-csi-driver"
      }
    )
  }
  
  data "aws_iam_policy_document" "s3_csi_driver_readonly" {
    count = var.enable_s3_csi_driver ? 1 : 0
  
    statement {
      sid     = "ListBucket"
      effect  = "Allow"
      actions = ["s3:ListBucket"]
      resources = [
        "arn:aws:s3:::${local.s3_bucket_name}"
      ]
    }
  
    statement {
      sid     = "ReadObjects"
      effect  = "Allow"
      actions = ["s3:GetObject"]
      resources = [
        "arn:aws:s3:::${local.s3_bucket_name}/*"
      ]
    }
  }
  
  resource "aws_iam_policy" "s3_csi_driver_readonly" {
    count       = var.enable_s3_csi_driver ? 1 : 0
    name_prefix = "${module.eks.cluster_name}-s3-csi-read-"
    description = "Read-only access for Mountpoint S3 CSI driver"
    policy      = data.aws_iam_policy_document.s3_csi_driver_readonly[0].json
  
    tags = merge(
      var.tags,
      {
        Name = "${module.eks.cluster_name}-s3-csi-readonly"
      }
    )
  }
  
  resource "aws_iam_role_policy_attachment" "s3_csi_driver_readonly" {
    count      = var.enable_s3_csi_driver ? 1 : 0
    role       = aws_iam_role.s3_csi_driver[0].name
    policy_arn = aws_iam_policy.s3_csi_driver_readonly[0].arn
  }
  
  #--------------------------------------------------------------
  # Static PV/PVC for Mountpoint S3 CSI
  # Mount only the models/ prefix from the bucket
  #--------------------------------------------------------------
  
  resource "kubernetes_persistent_volume" "s3_models" {
    count = var.enable_vllm && var.enable_s3_model_storage ? 1 : 0
  
    metadata {
      name = "vllm-s3-pv"
      labels = {
        storage = "s3-models"
      }
    }
  
    spec {
      capacity = {
        storage = "1200Gi" # ignored by the driver, still required by Kubernetes
      }
  
      access_modes                     = ["ReadOnlyMany"]
      persistent_volume_reclaim_policy = "Retain"
      storage_class_name               = ""
  
      claim_ref {
        namespace = kubernetes_namespace.vllm["vllm"].metadata[0].name
        name      = "vllm-s3-claim"
      }
  
      mount_options = [
        "region ${var.region}",
        "prefix ${local.model_s3_paths["tiny"]}/"
      ]
  
      persistent_volume_source {
        csi {
          driver        = "s3.csi.aws.com"
          volume_handle = "vllm-s3-${module.eks.cluster_name}"
  
          volume_attributes = {
            bucketName = local.s3_bucket_name
          }
        }
      }
    }
  
    depends_on = [
      aws_iam_role_policy_attachment.s3_csi_driver_readonly,
      module.eks_addons,
      terraform_data.bootstrap_model_to_s3
    ]
  }
  
  resource "kubernetes_persistent_volume_claim" "s3_models" {
    count = var.enable_vllm && var.enable_s3_model_storage ? 1 : 0
  
    metadata {
      name      = "vllm-s3-claim"
      namespace = "vllm"
      labels = {
        app = "vllm"
      }
    }
  
    spec {
      access_modes       = ["ReadOnlyMany"]
      storage_class_name = ""
      volume_name        = kubernetes_persistent_volume.s3_models[0].metadata[0].name
  
      resources {
        requests = {
          storage = "1200Gi" # ignored by the driver, still required by Kubernetes
        }
      }
    }
  
    depends_on = [
      kubernetes_persistent_volume.s3_models
    ]
  }

```

</details>


## 4. The 2-In-1 vLLM "Squeeze" (`vllm-deploy.yaml.tpl`)
To run 2 small replicas (like TinyLlama 1B/3B) on a single 24GB NVIDIA L4, we alter the standard Helm values. We remove the K8s hardware lock, force the pod onto the GPU node, and partition the VRAM.

```yaml
# vllm-deploy.yaml.tpl snippet
  modelSpec:
  - name: "tinyllama-gpu"
    repository: "vllm/vllm-openai"
    tag: "v0.8.5.post1"
    modelURL: "/models/${s3_tiny_model}"
    mountPvcStorage: false   # We will use extraVolumes to mount the S3 model directly, so we disable the default PVC storage
    # 3.  Forces VLLM pods onto the GPU node when GPUrequest is removed, and allows multiple pods to share the GPU with the new --gpu-memory-utilization setting.)
    nodeSelectorTerms:
        - matchExpressions:
          - key: workload-type
            operator: "In"
            values:
            - "gpu"  
    replicaCount: 2
    requestCPU: 1
    requestMemory: "2Gi"
  # requestGPU: 1          # REMOVED: To allow multiple pods on one GPU
    limitCPU: 2
    limitMemory: "8Gi"
    vllmConfig:
      dtype:  "float16"  # Changed from "bfloat16" not supported by Tesla T4 GPU (compute capability 7.5) 
      extraArgs:
        - "--disable-log-requests" 
        - "--gpu-memory-utilization=0.4"  # To SQUEEZE: 0.4 * 2 = 80% total L4 VRAM
        - "--host"  # NEW: Explicitly set the host address
        - "0.0.0.0" # NEW: Bind to all interfaces
    env: []        # NEW: CPU env vars removed
    # ---------------------------------------------------------
    # CUSTOM MOUNT PATH
    # mount the Persistent Volume directly to that path.
    # ---------------------------------------------------------    
    extraVolumes:
      - name: s3-model-storage
        persistentVolumeClaim:
          claimName: vllm-s3-claim
    extraVolumeMounts:
      - name: s3-model-storage
        # Mounts the S3 model directly into the /models/tiny-llama folder
        mountPath: /models/${s3_tiny_model}
        readOnly: true 

...
routerSpec:
  enableRouter: true
  routingLogic: "roundrobin"
  startupProbe:
    initialDelaySeconds: 150   # <----- keep routerpod alive until pods are spun up
    periodSeconds: 10
    failureThreshold: 30
    httpGet:   
      path: /health
      port: 8000    
```

---
## 🚀 Quick Start & Deployment
### ⚙️ Provisioning logic

 ### 1. Clone the repository

```bash
git clone https://github.com/CloudThrill/vllm-production-stack-terraform
cd vllm-production-stack-terraform/eks/
```

### 2. Configure the Environment

```bash
cp env-vars.template env-vars
vim env-vars  # Set HF token and customize deployment options
source env-vars
```

**Usage examples**

* **Option 1: Through Environment Variables**

  ```bash
  # Copy and customize
  $ cp env-vars.template env-vars
  $ vi env-vars
  ################################################################################
  # EKS Cluster Configuration
  ################################################################################
  # ☸️ EKS cluster basics
  export TF_VAR_cluster_name="vllm-eks-prod" # default: "vllm-eks-prod"
  export TF_VAR_cluster_version="1.30"       # default: "1.30" - Kubernetes cluster version
   ################################################################################
   # 🤖 NVIDIA setup selector
   #   • plugin           -> device-plugin only
   #   • operator_no_driver -> GPU Operator (driver disabled)
   #   • operator_custom  -> GPU Operator with your YAML
   ################################################################################
   export TF_VAR_nvidia_setup="plugin" # default: "plugin"
   ################################################################################
   # 🧠 LLM Inference Configuration
   ################################################################################
   export TF_VAR_enable_vllm="true"         # default: "false" - Set to "true" to deploy vLLM
   export TF_VAR_hf_token=""                # default: "" - Hugging Face token for model download (if needed)
   export TF_VAR_inference_hardware="gpu"   # default: "cpu" - "cpu" or "gpu"
   ################################################################################
   export TF_VAR_nvidia_setup="plugin" # default: ""
   # Paths to Helm chart values templates for vLLM.
   # These paths are relative to the root of your Terraform project.
   export TF_VAR_gpu_vllm_helm_config="./modules/llm-stack/helm/gpu/gpu-tinyllama-light-ingress.tpl" # default: ""
   export TF_VAR_cpu_vllm_helm_config="./modules/llm-stack/helm/cpu/cpu-tinyllama-light-ingress.tpl" # default: ""
   ################################################################################
   # ⚙️ Node-group sizing
   ################################################################################
   # CPU pool (always present)
   export TF_VAR_cpu_node_min_size="1"     # default: 1
   export TF_VAR_cpu_node_max_size="3"     # default: 3
   export TF_VAR_cpu_node_desired_size="2" # default: 2
   # GPU pool (ignored unless inference_hardware = "gpu")
   export TF_VAR_gpu_node_min_size="1"     # default: 1
   export TF_VAR_gpu_node_max_size="1"     # default: 1
   export TF_VAR_gpu_node_desired_size="1" # default: 1
   ...snip
   $ source env-vars
   ```

* **Option 2: Through Terraform Variables**

  ```bash
   # Copy and customize
   $ cp terraform.tfvars.example terraform.tfvars
   $ vim terraform.tfvars
  ```

### 3. Deploy Infrastructure & Bootstrap Models
A local sync script to push the Model weights from HF to the S3 bucket is included in the Terraform stack as a `local-exec` block. 
It checks if the model prefix exists in S3; if not, it automatically downloads and loads the weights into the bucket during `terraform apply`.

```bash
terraform init
terraform plan
terraform apply
```

***Note**: The Terraform output will automatically print a highly readable Terminal UI summary containing your generated S3 bucket name, IAM roles, and API endpoints.*

<details><summary><b>View the final Apply output (Terraform)</b></summary>
  
```bash
Apply complete! Resources: 110 added, 0 changed, 0 destroyed.

Outputs:

aws_vllm_stack_summary = <<EOT

✅ AWS EKS Cluster deployed successfully!

🚀 VLLM PRODUCTION STACK ON AWS EKS 🚀
-----------------------------------------------------------
REGION             : us-east-2
AVAILABILITY ZONES : us-east-2a, us-east-2b, us-east-2c
API ENDPOINT       : https://E3DF43C8D31DFED9602255BBE94901DF.gr7.us-east-2.eks.amazonaws.com
VPC ID             : vpc-09a8ebe863defea50 (10.20.0.0/16)

🖥️  INFRASTRUCTURE & STORAGE
-----------------------------------------------------------
CPU NODES         : [t3.xlarge]
GPU NODES         : [g6.2xlarge]
S3 MODEL BUCKET   : vllm-cloudthrill
S3 CSI ROLE       : arn:aws:iam::588922096256:role/vllm-eks-prod-s3-csi-driver-20260409033130884700000018

🧠  MODEL CONFIGURATION
-----------------------------------------------------------
HF SOURCE ID      : TinyLlama/TinyLlama-1.1B-Chat-v1.0
API MODEL URL     : /models/tiny-llama

🌐 ACCESS ENDPOINTS
-----------------------------------------------------------
VLLM API URL      : Disabled
GRAFANA FORWARD   : kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n kube-prometheus-stack

🛠️  QUICK START COMMANDS
-----------------------------------------------------------
1. Set Context    : export KUBECONFIG="./kubeconfig"
2. Test API       : curl -k "<VLLM_API_URL>/v1/models"

Built with ❤️ by @Cloudthrill
```
</details>


### 2. Test the Endpoint & Load Balancing
Router Stabilization: you might need to bump the `startupProbe`  `initialDelaySeconds: 150` to keep router alive while the vllm pod loads S3 weights & compiles graphs.

**Basic API Check:**
```bash
export KUBECONFIG="./kubeconfig"
curl -k "http://<YOUR_ALB_URL>/v1/models"
```

**Round-Robin Load Balancing Test:**
```bash
# Forward the router port locally (run this in the background or a separate terminal)
kubectl -n vllm port-forward svc/vllm-gpu-router-service 30080:80 &
export vllm_api_url=http://localhost:30080/v1

# Send a barrage of prompts to test the round-robin distribution
prompts=("The capital of France is" "Why is the sky blue?" "Write a poem about GPUs" "Explain Kubernetes" "Toronto is famous for" "Artificial Intelligence is")

for i in {0..5}; do
  echo -n "Request $((i+1)) [Prompt: $${prompts[$i]}] -> "
  curl -s $vllm_api_url/completions \
    -H "Content-Type: application/json" \
    -d "{
      \"model\": \"/models/tiny-llama\",
      \"prompt\": \"$${prompts[$i]}\",
      \"max_tokens\": 10
    }" | jq -r '.choices[].text' | tr -d '\n'
  echo ""
done
```

### 3. Observe the "Squeeze" in Action
While your test script is running, observe the engine logs. You will see traffic actively splitting and hitting both of your squeezed GPU replica pods in a perfect round-robin configuration.

```bash
# Watch the engine logs to see both pods responding
stern tinyllama-gpu -n vllm --tail 100 --no-follow --include 'POST|Engine' --exclude 'launcher|200 OK|health|metrics' --color always
```
## ⏱️ Engine Initialization Telemetry (Cold Start)

Unlike EBS block storage, the CSI driver streams model weights directly into VRAM over the network at startup.
Below is the boot telemetry for a 2GB model:
| Stage | Duration | Description |
| :--- | :--- | :--- |
| **API Init** | 6s | Python environment and API server startup. |
| **Engine Init** | 14s | CUDA platform detection and V1 Engine config. |
| **Model Load** | **189s** | **The S3 Bottleneck.** Pulling 2GB of weights via CSI over the network. |
| **Weight Map** | 1s | Mapping loaded weights into VRAM. |
| **Graph Compile** | 19s | `torch.compile` and CUDA graph capture memory spiking. |
| **Total Boot** | **~3.9 min** | Total time until Uvicorn Port 8000 is ready to serve traffic. |


## 🧮 VRAM Profiling (NVIDIA L4)

This stack is tuned to stack **two** model instances on a single 24GB GPU:

  * **Total Usable VRAM:** $\sim 22.35 \text{ GiB}$
  * **Partition per Pod:** $0.48$ ($\sim 10.7 \text{ GiB}$)
  * **Model Size (fp16):** $\sim 2.05 \text{ GiB}$
---
Built with ❤️ by [@Cloudthrill](https://github.com/CloudThrill)
 
