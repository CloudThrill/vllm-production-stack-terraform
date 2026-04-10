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
## ⚙️ Provisioning Highlights

### 1. The Storage Model: Streams, Not Syncs
The AWS Mountpoint CSI Driver acts as an API translator. When the pod reads `model.safetensors`, Mountpoint streams bytes directly from S3 into the GPU's VRAM over the network. Your compute nodes remain completely stateless.

### 2. The S3 "subPath" containement 
We use a specific `prefix` S3 mount per model for all pods to use combined with .i.e `subPath: $${s3_my_model}`. 
* **Isolation:** Mounting an `S3 prefix` makes the pod blind to the rest of the bucket. No risk of caching outside folders. 
* **OOM Protection:** Prevents the "Poisoned Folder" scenario where vLLM tries to map an entire bucket into the GPU (Out-Of-Memory crash).

### 3. Multi-Pod per GPU Setup
To skip the exclusive GPU lock and test **multi-pod scaling** on a single physical GPU node with a shared S3 mount, we did the following. 
* **The Bypass:** in the vllm chart, We omit the hardware request `requestGPU: 1`, essentially lying to the Kubernetes Device Plugin.
* **Shared VRAM:** vLLM takes over VRAM management. By injecting `--gpu-memory-utilization=0.48`, the pods manage their own VMemory.

---

## 🏗️ Core Infrastructure Components

This deployment is an extension of our foundational [Vllm-EKS stack](https://cloudthrill.ca/vllm-production-stack-on-eks-terraform), embedding operational best practices from [AWS integration and automation](https://github.com/aws-ia). The below describes what was added to the code base to allow S3 mounts in the stack.
> 💡 **Note:** If you are looking for standard EBS-based model storage, use the [`eks-base`](../eks-base) stack instead.


### 1. Storage & IAM (`storage.tf`)
Loading massive weight files into to EBS volumes per each replica limits horizontal scaling and inflates costs. We bypass this entirely:
* **S3 Bucket Provisioning:** Creates a dedicated bucket for model weights. (terraform resource)
* **IRSA (IAM Roles for Service Accounts):** gives vLLM engine pods permission to securely read from S3 without hardcoded credentials.
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

### 2. EKS Storage Add-ons (`cluster-tools.tf`)
Manages the critical cluster-level utilities required for a production API:
* **S3 Mountpoint CSI Driver:** Deployed through helm, to allow to mount the S3 bucket locally and stream weights into GPU.

### 3. The 2-In-one vLLM "Squeeze" (`vllm-deploy.yaml.tpl`)
 For 2 small replicas(i.e TinyLlama 1B/3B) to share a 24GB NVIDIA L4, The template implements:
* **The Hardware Bypass:** removes `requestGPU: 1` to prevent the Kubernetes scheduler from fencing off the hardware from other vllm replicas.
* **The Magnet (Node Affinity):** Uses `nodeSelectorTerms` and `tolerations` to force the engines specifically onto the `g6.2xlarge` GPU node group.
* **VRAM Partitioning:** Injects `--gpu-memory-utilization=0.40` into the engine arguments. To provide 10.7 GiB of VRAM per pod   


---
## 🏗️ Terraform Provisioning Flow
The deployment automatically provisions only the required infrastructure based on your hardware selection. **IMPORTANT:** S3 deployment is only supporting the gpu mode.

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
 
