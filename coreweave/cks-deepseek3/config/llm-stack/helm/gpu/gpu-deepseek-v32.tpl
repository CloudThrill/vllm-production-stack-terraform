# This file is a Go template. Variables passed from Terraform are accessed with .VarName
servingEngineSpec:
  enableEngine: true
  runtimeClassName: ""  # Use nvidia default runtime for GPU 
  tolerations:  
    - key: "nvidia.com/gpu"  
      operator: "Exists"  
      effect: "NoSchedule"  
    - key: "is_gpu"
      operator: "Equal"
      value: "true"
      effect: "PreferNoSchedule"  
      
  startupProbe:  
    initialDelaySeconds: 1200  # <- was 3 min , 15-20 minutes
    periodSeconds: 30  
    failureThreshold: 120  
    httpGet:   
      path: /health  
      port: 8000
  nodeSelector:
    workload-type: gpu
    node-group: gpu-pool
#  containerSecurityContext: in BM nodes nvidia-smi Privileged containers see all host 8 GPUs. 
#    privileged: true   # ignores nvida plugin's NVIDIA_VISIBLE_DEVICES isolation
  modelSpec:
# ======================================================
# GPU 2-3: DeepSeek-V3.2 (The MoE Titan) head
# ======================================================
  - name: "deepseek-v32-fp8"
    repository: "vllm/vllm-openai"
    tag: "v0.15.1"
    modelURL: "deepseek-ai/DeepSeek-V3.2"
    replicaCount: 1
    requestGPU: 8
    requestCPU: 16
    requestMemory: "128Gi"
    limitCPU: 32
    limitMemory: "200Gi"
    pvcStorage: "800Gi"  # INCREASED: Must be > 700GB for DeepSeek-V3.2
    storageClass: "shared-vast"
    pvcAccessMode:              # ← ADD THIS
      - ReadWriteMany           # ← RWX for multi-node access needed by PP=2
    env:
#     - name: VLLM_USE_V1
#       value: "0"                  # FIX: Prevents the EngineCore/WorkerProc crash with vLLM 0.15.1 | Autoset to 0 by raycluster
      - name: VLLM_ATTENTION_BACKEND
        value: "FLASHINFER" #  Speed: Optimized for DeepSeek's MLA architecture
      - name: NCCL_CUMEM_ENABLE # <--- ADD THIS for stability
        value: "0"        
      - name: NCCL_IB_DISABLE
        value: "0"        
    # Note: For DeepSeek, vLLM 0.15.1 often uses 'DeepGEMM' by default. 
    # FlashInfer is the fallback if DeepGEMM is unstable on your specific drivers.
    vllmConfig:
      enableChunkedPrefill: true
      enablePrefixCaching: true 
      tensorParallelSize: 8   # 8 lowers performance of deepseek32 on H100 but necesary to fit 700GB+ model on 8 cards with fp8
      pipelineParallelSize: 2 # 
      maxModelLen: 16384
      extraArgs:
        - "--download-dir=/data/models"
        - "--disable-log-requests"
        - "--trust-remote-code"
        - "--quantization=fp8"            # This handles the memory saving
        - "--gpu-memory-utilization=0.92" # DeepSeek is  using half of 8 cards
        - "--enforce-eager"               # Prevents CUDA graph overhead at high utilization    
        - "--tokenizer-mode=deepseek_v32"
        - "--distributed-executor-backend=ray"
        - "--chat-template"
        - |
          ${lb}% if add_generation_prompt %${rb}<${pipe}begin of sentence${pipe}>${lb}% endif %${rb}${lb}% for message in messages %${rb}${lb}% if message['role'] == 'user' %${rb}<${pipe}User${pipe}>${lb}${lb} message['content'] ${rb}${rb}${lb}% elif message['role'] == 'assistant' %${rb}<${pipe}Assistant${pipe}>${lb}${lb} message['content'] ${rb}${rb}<${pipe}end of sentence${pipe}>${lb}% endif %${rb}${lb}% endfor %${rb}${lb}% if add_generation_prompt %${rb}<${pipe}Assistant${pipe}><think>${lb}% endif %${rb}
     #  - "--reasoning-parser deepseek_v3"  # OPTIONAL: DeepSeek's custom reasoning parser, if you want to use it instead of vLLM's default.
     #  - "--tool-call-parser=deepseek_v32" # OPTIONAL: DeepSeek's custom tool call parser, if you want to use it instead of vLLM's default.
     #  - "--enable-auto-tool-choice"       # OPTIONAL: Logic layer only. Let vLLM automatically choose the best tool call parser based on the model's responses. Can improve performance if your model sometimes responds in a way that confuses the default parser.
# ------------------------------------------------------
# RAY SPEC (Node 2) - Appended immediately after vllmConfig
# ------------------------------------------------------
    raySpec:
      # Worker Group: Defines the second node needed for PP=2
# This matches $modelSpec.raySpec.headNode in the template
      headNode: 
        requestGPU: 8
        requestCPU: 16
        requestMemory: "128Gi"      
      workerGroupSpecs:
      - groupName: "gpu-worker-group"
        replicas: 1               # 1 Worker Node (+ 1 Head above = 2 Total)
        minReplicas: 1
        maxReplicas: 1
        rayStartParams: {}
        template:
          spec:
            containers:
            - name: vllm-worker
              image: "vllm/vllm-openai:v0.15.1" # Must match Head
              resources:
                limits:
                  nvidia.com/gpu: "8"  # Uses the full 2nd Node
                  memory: "200Gi"
                  cpu: "32"
                requests:
                  nvidia.com/gpu: "8"
                  memory: "128Gi"
                  cpu: "16"
              env:
              - name: NCCL_IB_DISABLE
                value: "0"
              # --- ADD THESE FOR SYNC ---
              - name: NCCL_CUMEM_ENABLE
                value: "0"
              - name: VLLM_ATTENTION_BACKEND
                value: "FLASHINFER"
              # ---------------------------                
            # Ensure worker lands on a GPU node
            nodeSelector:
              workload-type: gpu
            tolerations:
            - key: "nvidia.com/gpu"
              operator: "Exists"
              effect: "NoSchedule"
routerSpec:
  enableRouter: true
  routingLogic: "roundrobin"
  resources:
    requests:
      cpu: "1"
      memory: "1Gi"
    limits:
      cpu: "2"
      memory: "2Gi"
      
   # Ingress configuration for the router
  ingress:
    enabled: true
    className: "traefik"  #  Use Traefik ingress controller
    annotations:
      # TLS/SSL configuration with cert-manager
      cert-manager.io/cluster-issuer: ${issuer_name}
      traefik.ingress.kubernetes.io/router.entrypoints: websecure
    hosts:
      - host: ${prefix}.${org_id}-${cluster_name}.coreweave.app   
        paths:
          - path: /
            pathType: Prefix

    # TLS configuration with automatic certificate
    tls:
      - secretName: vllm-tls-secret
        hosts:
          - ${prefix}.${org_id}-${cluster_name}.coreweave.app
####################################
# LMCache remote sharing (Optional)
####################################          

cacheserverSpec:
  enableServer: true
  repository: "lmcache/lmstack-cache-server"
  replicaCount: 1
  containerPort: 8080
  servicePort: 81
  serde: "naive"
  repository: "lmcache/vllm-openai"
  tag: "latest"
  resources:
    requests:
      cpu: "4"
      memory: "8G"
    limits:
      cpu: "4"
      memory: "10G"
  labels:
    environment: "cacheserver"
    release: "cacheserver"        
    component: "kv-storage" 