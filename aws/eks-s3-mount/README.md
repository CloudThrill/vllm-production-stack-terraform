# 🧑🏼‍🚀 vLLM Production Stack on Amazon EKS - S3 Mountpoint 

A production-grade Terraform deployment for serving Large Language Models using [vLLM](https://github.com/vllm-project/vllm) on Amazon EKS. 

This infrastructure completely decouples model storage from compute using the **AWS Mountpoint for Amazon S3 CSI Driver**, and introduces advanced Kubernetes scheduling techniques to bypass strict GPU locking, allowing multiple engine replicas to share a single cloud GPU efficiently.

## ✨ Architectural Highlights

### 1. The Storage Model: Streams, Not Syncs
Tools like Google Drive or Dropbox run background daemons that physically download copies of cloud files to a local hard drive. **The AWS Mountpoint CSI Driver does not do this.** It acts as an API translator. When the pod tries to read `model.safetensors`, Mountpoint streams the bytes directly from S3 into the GPU's VRAM over the network. 
* The file is never permanently written to your node's underlying EBS volume, keeping your compute nodes completely stateless.

### 2. The "subPath" Jail
We use a specific `prefix` mount combined with `subPath: $${s3_tiny_model}`. 
* **The Benefit:** Your vLLM pod is completely blind to the rest of the S3 bucket. If someone accidentally uploads 500GB of garbage data to another folder in the bucket, your pod physically cannot see it. 
* **OOM Protection:** It prevents the "Poisoned Folder" scenario where vLLM tries to map an entire bucket of unstructured files into a 24GB GPU, resulting in violent Out-Of-Memory crashes.

### 3. The "GPU Lie" & VRAM Policing
Standard Kubernetes scheduling (`nvidia.com/gpu: 1`) enforces an exclusive lock, wasting massive amounts of hardware for smaller models.
* **The Bypass:** We omit the hardware request, essentially lying to the Kubernetes Device Plugin.
* **The Sheriff:** Because Kubernetes isn't managing the VRAM, vLLM takes over. By injecting `--gpu-memory-utilization=0.48`, the pods manage their own internal fences on the shared hardware.
* **CUDA Graphs:** Enabled by default. The GPU processes tokens faster because it doesn't have to launch individual kernels for every token pass.

---

## 🏗️ Core Infrastructure Components

This deployment relies on several heavily customized Terraform resources and Helm template overrides to achieve its performance and cost-efficiency.

### 1. Storage & IAM (`storage.tf`)
Baking massive `.safetensors` files into Docker images or syncing them to EBS volumes limits horizontal scaling and inflates costs. We bypass this entirely:
* **S3 Bucket Provisioning:** Creates a dedicated bucket for model weights.
* **IRSA (IAM Roles for Service Accounts):** Wires up least-privilege OIDC access so the vLLM engine pods can securely read from S3 without hardcoded credentials.
* **S3 Mountpoint CSI Driver:** Deploys the AWS EKS Add-on, allowing the pods to mount the S3 bucket locally at `/models` and stream weights directly into GPU VRAM at initialization.

### 2. EKS Add-ons & Ingress (`cluster-tools.tf`)
Manages the critical cluster-level utilities required for a production API:
* **AWS Load Balancer Controller:** Automatically provisions an internet-facing Application Load Balancer (ALB) based on the vLLM Router's ingress annotations.
* **Kube-Prometheus-Stack:** Deploys Grafana and Prometheus to scrape and visualize vLLM engine metrics (KV cache usage, request throughput) via Kubernetes ServiceMonitors.

### 3. The Engine "Squeeze" (`vllm-deploy.yaml.tpl`)
Standard Kubernetes scheduling (`nvidia.com/gpu: 1`) locks a physical GPU to a single pod. For smaller models (like TinyLlama 1B/3B) on a 24GB NVIDIA L4, this wastes 80% of the hardware. The template implements:
* **The Hardware Bypass:** Sets `requestGPU: 0` to prevent the Kubernetes scheduler from fencing off the hardware.
* **The Magnet (Node Affinity):** Uses `nodeSelectorTerms` and `tolerations` to force the engines specifically onto the `g6.2xlarge` GPU node group.
* **VRAM Partitioning:** Injects `--gpu-memory-utilization=0.48` into the engine arguments. This safely partitions 10.7 GiB of VRAM per pod, leaving exact headroom for PyTorch's `torch.compile` graphs and KV Cache without triggering OOM evictions.

### 4. Router Stabilization (`main.tf` / `routerSpec`)
Because vLLM engines downloading weights from S3 and compiling execution graphs can take 2-3 minutes, standard Kubernetes probes will violently kill the frontend router before the system is ready.
* **`startupProbe` Injection:** We pass a custom `startupProbe` via the Helm `values` block with an `initialDelaySeconds: 150`. This teaches the `lmstack-router` patience, completely eliminating the "Death Loop" during cluster spin-up.

---

## 🧮 Hardware & VRAM Profiling (NVIDIA L4 / g6.2xlarge)

This configuration is tuned to safely stack **two** model instances on a single 24GB GPU:
* **Total Usable VRAM:** ~22.35 GiB
* **Partition per Pod:** `0.48` (~10.7 GiB)
* **Model Size (fp16):** ~2.05 GiB
* **KV Cache & Compilation Headroom:** ~8.6 GiB

---

## ⏱️ The Boot Bottleneck & Router Fix

Decoupling storage comes with a massive initialization penalty. Below is the VRAM profiling telemetry for booting a TinyLlama container via the S3 CSI Mountpoint:

| Stage | Duration | Description |
| :--- | :--- | :--- |
| **API Init** | 6s | Python environment and API server startup. |
| **Engine Init** | 14s | CUDA platform detection and V1 Engine config. |
| **Model Load** | **189s** | **The S3 Bottleneck.** Pulling 2GB of weights via CSI over the network. |
| **Weight Map** | 1s | Mapping loaded weights into VRAM. |
| **Graph Compile** | 19s | `torch.compile` and CUDA graph capture memory spiking. |
| **Total Boot** | **~3.9 min** | Total time until Uvicorn Port 8000 is ready to serve traffic. |

### Defeating the "Death Loop"
The upstream `lmstack-router` Helm chart has a rigidly hardcoded `livenessProbe` set to 30 seconds, and completely omits `startupProbe` templating. 
Because our S3 engine takes **3.9 minutes** to boot, Kubernetes continuously executes the router pod for failing health checks before the backend is even awake. This stack resolves this by injecting a custom JSON patch/template override with an `initialDelaySeconds: 150`, granting the system the patience required to compile the graphs.

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
| **vLLM Stack** | 03:39:15 | 03:47:29 | **~8m 14s** |
| **Total Deployment Time** | 03:23:02 | 03:47:29 | **~24 minutes** |

---

## 🚀 Quick Start & Deployment

### Prerequisites
* Terraform 1.9.8+
* AWS CLI configured with administrator access
* `kubectl` and `helm` installed
* `huggingface-cli` installed locally (for the automated bootstrap)

### 1. Provision Infrastructure & Bootstrap Models
A local sync script to push the HuggingFace weights to the newly provisioned S3 bucket is included directly in the Terraform stack as a `local-exec` block. It checks if the model prefix exists in S3; if not, it automatically downloads and loads the weights into the bucket during `terraform apply`.

```bash
terraform init
terraform apply -auto-approve
```
*Note: The Terraform output will automatically print a highly readable Terminal UI summary containing your generated S3 bucket name, IAM roles, and API endpoints.*

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

### 2. Test the Endpoint & Load Balancing
Wait 3-5 minutes for the engines to download the model from S3, compile their PyTorch graphs, and for the router to report healthy. Once ready, you can test the ALB or run a local barrage test to force load balancing.

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

Built with ❤️ by [@Cloudthrill](https://github.com/CloudThrill)
 
