# 🧑🏼‍🚀 vLLM Production Stack on Amazon EKS - S3 Mountpoint 

<img width="1536" height="1024" alt="vllm_prod-stack-eks-s3" src="https://github.com/user-attachments/assets/ab2fa28a-2ac3-4c01-ac19-a2225ceda960" />

<br>✍🏼This Terraform stack delivers a **production-ready vLLM serving environment** on Amazon EKS. By utilizing the **AWS Mountpoint S3 CSI Driver**, it decouples model storage from compute (no EBS needed) and leverages customized scheduling to allow multiple vLLM replicas to share a single GPU and model storage. This is an S3-optimized variant of our foundational [Vllm-EKS stack](https://cloudthrill.ca/vllm-production-stack-on-eks-terraform).
> 💡**Note**: For standard EBS-backed deployment, please use the [`eks-base`](../eks-base) stack instead.

| Project Item | Description |
| :--- | :--- |
| **Author** | [@cloudthrill](https://cloudthrill.ca) |
| **Stack** | Terraform ◦ AWS ◦ EKS ◦ S3 ◦ Calico ◦ Helm ◦ vLLM |
| **Module** |  S3-storage EKS blueprint for enterprise-grade vLLM clusters |
| **CNI** | AWS VPC with full-overlay **Calico** network |
| **Hardware** | Toggleable **CPU** or **GPU** via feature flag |


## 📑 Table of Contents
- [📂 Project Structure](#-project-structure)
- [⚙️ Provisioning Highlights](#️-provisioning-highlights)
- [✅ Prerequisites](#-prerequisites)
- [🏗️ Core Infrastructure Components](#️-core-infrastructure-components)
- [🔍 S3 Mountpoint & GPU Walkthrough](#-s3-mountpoint--gpu--walkthrough)
  - [1. The Automated S3 Bootstrap (LLM seeding) `storage.tf`](#1-the-automated-s3-bootstrap-llm-seeding-storagetf)
  - [2. S3 Mountpoint CSI Driver `cluster-tools.tf`](#2-s3-mountpoint-csi-driver-cluster-toolstf)
  - [3. IAM & S3 Storage provisioning `storage.tf`](#3-iam--s3-storage-provisioning-storagetf)
  - [4. The multi-replica vLLM "Squeeze" `gpu-tinyllama-light-ingress-s3.tpl`](#4-the-multi-replica-vllm-squeeze-gpu-tinyllama-light-ingress-s3tpl)
- [🚀 Quick Start & Deployment](#-quick-start--deployment)
  - [🏗️ Terraform Provisioning Flow](#️-terraform-provisioning-flow)
  - [1. Clone the repository](#1-clone-the-repository)
  - [2. Configure the Environment](#2-configure-the-environment)
  - [3. Deploy Infrastructure & Bootstrap Models](#3-deploy-infrastructure--bootstrap-models)
- [Test the Endpoint & Load Balancing](#test-the-endpoint--load-balancing)
- [⏱️ Engine Initialization Telemetry (Cold Start)](#️-engine-initialization-telemetry-cold-start)
  - [🧮 VRAM Profiling (g6.2xlarge: L4)](#-vram-profiling-g62xlarge-l4)

---
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

---
## ⚙️ Provisioning Highlights
Loading massive weight files into EBS volumes per each replica limits horizontal scaling and inflates costs. We bypass this entirely:

* ✅ **Streams, Not Syncs** (`cluster-tools.tf`)<br>
  * Mountpoint CSI streams weights directly from S3 → GPU VRAM (no EBS overhead)
  * Strict prefix isolation per model prevents bucket contamination

* ✅ **Multi-Pod GPU Scaling** (`gpu-tinyllama-light-ingress-s3.tpl`)<br>
  * Bypasses K8s hardware lock (omits `requestGPU: 1`)
  * VRAM partitioning via `--gpu-memory-utilization=0.40` enables 2 replicas per GPU


* 🏁🛑 **Automated Bootstrapping**
  
| Feature | Implementation | Benefit |
|---------|---------------|---------|
| **HuggingFace Download** | Auto-downloads model if S3 prefix is empty | Zero manual setup |
| **Idempotency Checks** | Validates `config.json` existence + minimum file size | Prevents duplicate uploads |
| **Dependency Sequencing** | Helm waits for bootstrap completion before vLLM deployment | Eliminates race conditions |

> **AWS Mountpoint** is an API translator. It converts standard pod filesystem reads directly into native S3 streaming API GET calls on the fly.
---
## ✅ Prerequisites

| Tool | Version | Notes |
| :--- | :--- | :--- |
| **Terraform** | 1.9.8 | tested on 1.9.8 |
| **AWS CLI v2** | ≥ 2.16 | profile / SSO auth |
| **kubectl** | ≥ 1.32 | ±1 of control-plane |
| **helm** | ≥ 3.14 | used by `helm_release` |
|**huggingface-cli**|1.9.0| Installed locally (for the automated bootstrap)

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
---
## 🏗️ Core Infrastructure Components
The deployment provisions the required infrastructure based on your hardware selection.

| Phase | Component | Action | Condition |
|-------|-----------|--------|-----------|
| **1.Infrastructure**| VPC | Provision VPC with 3 public + 3 private subnets | Always |
| | EKS | Deploy v1.30 cluster + CPU node group (t3a.large) | Always |
| | CNI | Remove aws-node, install Calico overlay (VXLAN) | Always |
| | Add-ons | Deploy EBS CSI, ALB controller, kube-prometheus | Always |
| **2. LLM storage** | S3 based PVC | Create S3 Bucket+ load llm from HF + install S3 CSI Driver + attach S3 IAM role + create PV/PVC targeting S3 | -> `/models/<model>` |
| **3. vLLM Stack** | | | `enable_vllm = true` |
| | HF secret| Deploy Create `hf-token-secret` for Hugging Face | `enable_vllm = true` |
| | CPU Deployment | Deploy vLLM on existing CPU nodes | `inference_hardware = "cpu"` |
| | GPU Infrastructure | Provision GPU node group (g5.xlarge) | `inference_hardware = "gpu"` |
| | GPU Operator | Deploy NVIDIA operator/plugin | `inference_hardware = "gpu"` |
| | GPU Deployment | Deploy vLLM on GPU nodes with scheduling | `inference_hardware = "gpu"` |
| | Application | Deploy TinyLlama-1.1B Helm chart to `vllm` namespace | `enable_vllm = true` |
| **4. Networking** | Load Balancer | Configure ALB and ingress for external access | `enable_lb_ctl = true` |
>  **IMPORTANT:** This S3-backed variant is only supported by the gpu mode for now.
---
## 🔍 S3 Mountpoint & GPU  Walkthrough

This build uses a highly specific Terraform sequence to orchestrate the S3 streaming and VRAM partitioning.

### 1. The Automated S3 Bootstrap (LLM seeding) [`storage.tf`](./storage.tf)
Once S3 bucket is created (`aws_s3_bucket.vllm_models`), check for its model files, if missing, HF download them and sync them into the bucket.

```hcl
# storage.tf snippet
locals {
  # selected_model_s3_path = local.model_s3_paths["tiny"]
  s3_models = {
    tiny  = "tiny-llama"
    llama = "llama-3"
    qwen  = "qwen-3"
  }
  model_s3_paths = {
    for k, v in local.s3_models :
    k => "${var.s3_models_prefix}/${v}"
  }
}
######################

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
    aws_s3_bucket.vllm_models   # <==== only runs when bucket is created
  ]
}
```


### 2. S3 Mountpoint CSI Driver [`cluster-tools.tf`](./cluster-tools.tf)
The S3 CSI driver will allow to mount S3 buckets in Persistent Volumes and stream weights into GPU through PVCs.

```hcl
# cluster-tools.tf snippet
module "eks_addons" {
  source = "git::..//eks-blueprints-addons?ref=v1.0.0"
...
helm_releases = var.enable_s3_csi_driver ? {
    aws-mountpoint-s3-csi-driver = {
      description      = "Mountpoint for Amazon S3 CSI driver"
      namespace        = "kube-system"
      create_namespace = false
      chart            = "aws-mountpoint-s3-csi-driver"
      chart_version    = var.s3_csi_driver_version
      repository       = "https://awslabs.github.io/mountpoint-s3-csi-driver"

      values = [
        yamlencode({
          node = {
            serviceAccount = {
              create = true
              name   = "s3-csi-driver-sa"
              annotations = {
                "eks.amazonaws.com/role-arn" = aws_iam_role.s3_csi_driver[0].arn
              }
            }
            # Add this for GPU node compatibility
            tolerations = [
              {
                key      = "nvidia.com/gpu"
                operator = "Exists"
                effect   = "NoSchedule"
              }
            ]
...
```

### 3. IAM & S3 Storage provisioning [`storage.tf`](./storage.tf)
Create an S3 bucket for model weights, attach IAM roles to give pods access to it, then provision both vLLM PV & PVC linked to the bucket.

<details>
<summary><b>View the S3 storage deployment Code (Terraform)</b></summary>

  ```hcl
  # storage.tf snippet

  #--------------------------------------------------------------
  # S3 Storage for vLLM Models
  #--------------------------------------------------------------

  locals {
    s3_bucket_name = var.create_s3_bucket ? one(aws_s3_bucket.vllm_models[*].id) : var.s3_bucket
    }
 
  #--------------------------------------------------------------
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


## 4. The multi-replica vLLM "Squeeze" [`gpu-tinyllama-light-ingress-s3.tpl`](./gpu-tinyllama-light-ingress-s3.tpl)
To run 2 replicas (TinyLlama 1B/3B) on a single 24GB NVIDIA L4, we remove the K8s hardware lock to allow the VRAM to be partitioned safely.

```yaml
# gpu-tinyllama-light-ingress-s3.tpl snippet
  modelSpec:
  - name: "tinyllama-gpu"
    repository: "vllm/vllm-openai"
    tag: "v0.8.5.post1"
    modelURL: "/models/${s3_tiny_model}"
    mountPvcStorage: false   # We will use extraVolumes to mount the S3 model directly instead
    # Forces VLLM pods onto the GPU node when GPUrequest is removed, and allows multiple pods to share the GPU 
    nodeSelectorTerms:
        - matchExpressions:
          - key: workload-type
            operator: "In"
            values:
            - "gpu"  
    replicaCount: 2
    requestCPU: 1
    requestMemory: "2Gi"
  # requestGPU: 1          # REMOVED: remove the K8s hardware lock to allow multiple pods on one GPU
    limitCPU: 2
    limitMemory: "8Gi"
    vllmConfig:
      dtype:  "float16"  # Changed from "bfloat16" not supported by Tesla T4 GPU (compute capability 7.5) 
      extraArgs:
        - "--disable-log-requests" 
        - "--gpu-memory-utilization=0.4"  # To SQUEEZE: 0.4 * 2 = 80% total L4 VRAM
        - "--host"   
        - "0.0.0.0"  
    env: []        
    # ---------------------------------------------------------
    # CUSTOM MOUNT PATH
    # mount the S3 Persistent Volume directly to that path.
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
 <details>
<summary><b>🧠 Why K8s Can't Natively Share GPUs?</b></summary>

* **The Integer Problem:** <br> K8s only accepts whole numbers. You can't request `0.5` GPUs; it grants `1` full device ID by default.
* **Kernel Blindness:** <br>Linux `cgroups` enforce system RAM limits, not GPU VRAM. Once K8s injects `/dev/nvidia0` into a pod, that pod has access to the full VRAM. 
* **Enterprise Solutions:** <br>At scale, engineers fix this using
  * **MIG** (hardware partitioning, unsupported on L4)
  * **Time-Slicing** (software context-switching)
  * **MPS** (merged CUDA streams).  
  * **HAMi** software GPU virtualization (intercepts CUDA for hard fractional limits)
  * **KAI Scheduler** (NVIDIA's soft-isolation AI scheduler). For a single node, letting vLLM self-manage its own VRAM is the cleanest bypass.
</details>

---
## 🚀 Quick Start & Deployment
### 🏗️ Terraform Provisioning Flow
This deployment utilizes a "phantom dependency" chain to ensure race conditions never occur. 

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
| **vLLM Stack(1Router+ 2Engines+ S3 model load+ Obvservability)** | 03:39:15 | 03:47:29 | **~8m 14s** |
| **Total Deployment Time** | 03:23:02 | 03:47:29 | **~24 minutes** |
> From a cold start, the entire infrastructure stack provisions in **~24 minutes**:
 ### 1. Clone the repository
```bash
git clone https://github.com/CloudThrill/vllm-production-stack-terraform
cd vllm-production-stack-terraform/aws/eks-s3-mount/
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
   # ☸️ EKS cluster basics
  ################################################################################
  export TF_VAR_cluster_name="vllm-eks-prod" # default: "vllm-eks-prod"
  export TF_VAR_cluster_version="1.32"       # default: "1.30" - Kubernetes cluster version
  export TF_VAR_gpu_node_instance_types='["g6.2xlarge"]'
  ################################################################################
   # 💽 S3 Model Storage 
  ################################################################################
  export TF_VAR_enable_s3_csi_driver=true
  export TF_VAR_enable_s3_model_storage=true
  export TF_VAR_create_s3_bucket=true
  export TF_VAR_s3_bucket="vllm-bucket-random"    # CHANGE ME (must be unique globally)
  export TF_VAR_s3_models_prefix="models"
  export TF_VAR_s3_csi_driver_version="1.10.0"
  export TF_VAR_huggingface_model_id="TinyLlama/TinyLlama-1.1B-Chat-v1.0"
  ################################################################################
   # 🧠 LLM Inference Configuration
  ################################################################################
  export TF_VAR_enable_vllm="true"         # default: "false" - Set to "true" to deploy vLLM
  export TF_VAR_hf_token=""                # default: "" - Hugging Face token for model download (if needed)
  export TF_VAR_inference_hardware="gpu"   # must be "gpu"
  # Paths to VLLM Helm chart values templates.
  # export TF_VAR_gpu_vllm_helm_config="./modules/llm-stack/helm/gpu/gpu-tinyllama-light-ingress-3.tpl" # DO NOT Change
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
 The bootstrap automatically downloads and loads the weights into the bucket during `terraform apply`.

```bash
terraform init
terraform plan
terraform apply
```

***Note**: The Terraform output will print a highly readable summary containing your INFRA & S3 Storage info, along with API endpoints.*
  
```bash
Apply complete! Resources: 110 added, 0 changed, 0 destroyed.

Outputs:

aws_vllm_stack_summary = <<EOT

✅ AWS EKS Cluster deployed successfully!

🚀 VLLM PRODUCTION STACK ON AWS EKS 🚀
-----------------------------------------------------------
REGION             : us-east-2
AVAILABILITY ZONES : us-east-2a, us-east-2b, us-east-2c
API ENDPOINT       : https://XXXXXXXXXX.gr7.us-east-2.eks.amazonaws.com
VPC ID             : vpc-09a8ebe863defea50 (10.20.0.0/16)

🖥️  INFRASTRUCTURE & STORAGE
-----------------------------------------------------------
CPU NODES         : [t3.xlarge]
GPU NODES         : [g6.2xlarge]
S3 MODEL BUCKET   : vllm-cloudthrill
S3 CSI ROLE       : arn:aws:iam::xxxxxxxxxxx:role/vllm-eks-prod-s3-csi-driver-xxxx

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


## Test the Endpoint & Load Balancing
We will now do a quick test to monitor S3 storage being shared by 2 replicas while handling batch requests in a Round-Robin fashion. 

**1. Basic API Check:**
```bash
export KUBECONFIG="./kubeconfig"
curl -k "http://<YOUR_ALB_URL>/v1/models"
```

**2. Round-Robin Load Balancing Test:**
```bash
# 1. Extract the router URL
-- case 1 : Forward the router port locally (run this in the background or a separate terminal)
kubectl -n vllm port-forward svc/vllm-gpu-router-service 30080:80 &
export vllm_api_url=http://localhost:30080/v1

-- case 2 : AWS ALB Ingress enabled
$ kubectl get ingress -n vllm -o json| jq -r .items[0].status.loadBalancer.ingress[].hostname
export vllm_api_url=http://k8s-vllm-vllmingr-**********.us-east-2.elb.amazonaws.com/v1

# 2. Send a barrage of concurent prompts to test the round-robin distribution
seq 1 100 | xargs -n 1 -P 25 -I {} curl -s -X POST $vllm_api_url/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "/models/tiny-llama",
    "prompt": "Explain the architecture of Kubernetes and how it schedules pods in detail:",
    "max_tokens": 150
  }' \
  -o /dev/null \
  -w "✅ Request: {} | Status: %{http_code} | Time: %{time_total}s\n"
```

**3. Observe the inference in Action**
<br>While the test script is running, observe the engine logs. You will see traffic actively splitting and hitting both replica pods (round-robin).

```bash
# Watch the engine logs to see both pods responding
stern tinyllama-gpu -n vllm --tail 100 --no-follow --include 'POST|Engine' --exclude 'launcher|200 OK|health|metrics' --color always
```
<details>
<summary><b>🔎View the monitoring output from vllm pods (Terraform)</b></summary>

  ```nginx
+ vllm-gpu-tinyllama-gpu-deployment-vllm-6949f54975-qtwps › vllm
+ vllm-gpu-tinyllama-gpu-deployment-vllm-6949f54975-52hsz › vllm
vllm-gpu-tinyllama-gpu-deployment-vllm-6949f54975-qtwps vllm INFO 04-08 01:24:55 [loggers.py:111] Engine 000: Avg prompt throughput: 77.4 tokens/s, Avg generation throughput: 558.8 tokens/s, Running: 7 reqs, Waiting: 0 reqs, GPU KV cache usage: 0.3%, Prefix cache hit rate: 0.0%
vllm-gpu-tinyllama-gpu-deployment-vllm-6949f54975-qtwps vllm INFO 04-08 01:26:05 [loggers.py:111] Engine 000: Avg prompt throughput: 12.6 tokens/s, Avg generation throughput: 191.2 tokens/s, Running: 0 reqs, Waiting: 0 reqs, GPU KV cache usage: 0.0%, Prefix cache hit rate: 0.0%
vllm-gpu-tinyllama-gpu-deployment-vllm-6949f54975-52hsz vllm INFO 04-08 01:26:08 [loggers.py:111] Engine 000: Avg prompt throughput: 72.0 tokens/s, Avg generation throughput: 583.1 tokens/s, Running: 11 reqs, Waiting: 0 reqs, GPU KV cache usage: 2.9%, Prefix cache hit rate: 0.0%
vllm-gpu-tinyllama-gpu-deployment-vllm-6949f54975-52hsz vllm INFO 04-08 01:41:28 [loggers.py:111] Engine 000: Avg prompt throughput: 82.8 tokens/s, Avg generation throughput: 567.0 tokens/s, Running: 8 reqs, Waiting: 0 reqs, GPU KV cache usage: 1.5%, Prefix cache hit rate: 0.0%
vllm-gpu-tinyllama-gpu-deployment-vllm-6949f54975-52hsz vllm INFO 04-08 01:41:48 [loggers.py:111] Engine 000: Avg prompt throughput: 18.0 tokens/s, Avg generation throughput: 11.6 tokens/s, Running: 10 reqs, Waiting: 0 reqs, GPU KV cache usage: 1.9%, Prefix cache hit rate: 0.0%
```
</details>

## ⏱️ Engine Initialization Telemetry (Cold Start)

Below is the boot telemetry for a 2GB model while the CSI driver streams model weights directly into VRAM over the network
| Stage | Duration | Description |
| :--- | :--- | :--- |
| **API Init** | 6s | Python environment and API server startup. |
| **Engine Init** | 14s | CUDA platform detection and V1 Engine config. |
| **Model Load** | **189s** | **The S3 Bottleneck.** Pulling 2GB of weights via CSI over the network. |
| **Weight Map** | 1s | Mapping loaded weights into VRAM. |
| **Graph Compile** | 19s | `torch.compile` and CUDA graph capture memory spiking. |
| **Total Boot** | **~3.9 min** | Total time until Uvicorn Port 8000 is ready to serve traffic. |
> **Router Stabilization:** <br>You might need to bump the `startupProbe` `initialDelaySeconds: 150+` to keep router alive while the vllm pods load S3 weights.


#### 🧮 VRAM Profiling (g6.2xlarge: L4)

This stack is tuned to stack **two** model instances on a single 24GB GPU:

* **Total Usable VRAM:** ~22.35 GiB (24 GB - OS overhead)
* **Per-Pod Allocation:** 0.4 × 22.35 = ~8.9 GiB
* **Model Footprint (fp16):** ~2.05 GiB
* **KV Cache + Compile Overhead:** ~6.8 GiB
---
## 🔧 Cleanup Notes

### Optional Manual Cleanup

In rare cases, you may need to manually clean up some AWS resources while running terraform destroy.

**🐈 Calico Cleanup Jobs**

If encountering job conflicts during Calico removal (i.e: * jobs.batch "tigera-operator-uninstall" already exists) run the below commands

```bash
# use the following commands to delete the jobs manually first:
kubectl -n tigera-operator delete job tigera-operator-uninstall --ignore-not-found=true
```
See most common issues in this [troubleshooting section](https://github.com/CloudThrill/vllm-production-stack-terraform/tree/main/aws/eks-base#-cleanup-notes)

---
<br>Built with ❤️ by [@Cloudthrill](https://github.com/CloudThrill)
 
