# This file is a Go template. Variables passed from Terraform are accessed with .VarName
servingEngineSpec:
  enableEngine: true
  runtimeClassName: ""  # Use nvidia default runtime for GPU 
  tolerations:  
    - key: "nvidia.com/gpu"  
      operator: "Exists"  
      effect: "NoSchedule"  
  startupProbe:
    initialDelaySeconds: 180  # <- was 60, give it 3 min to start up  
    periodSeconds: 30  
    failureThreshold: 120  
    httpGet:   
      path: /health
      port: 8000
  nodeSelector:
    workload-type: gpu
    node-group: gpu-pool
  containerSecurityContext:
    privileged: true
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

routerSpec:
  enableRouter: true
  routingLogic: "roundrobin"
  startupProbe:
    initialDelaySeconds: 150
    periodSeconds: 10
    failureThreshold: 30
    httpGet:   
      path: /health
      port: 8000    
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
    className: "alb"  # Use ALB ingress controller for EKS
    annotations:
      # AWS Load Balancer Controller annotations
      kubernetes.io/ingress.class: alb
      alb.ingress.kubernetes.io/scheme: internet-facing
      alb.ingress.kubernetes.io/target-type: ip
      alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}]'   # Remove HTTPS: 443  
      # remove alb.ingress.kubernetes.io/ssl-redirect: '443'
      # Health check configuration for vLLM
      alb.ingress.kubernetes.io/healthcheck-path: /health  # vLLM standard health endpoint
      alb.ingress.kubernetes.io/healthcheck-port: traffic-port #  router service port
      alb.ingress.kubernetes.io/healthcheck-protocol: HTTP
      alb.ingress.kubernetes.io/success-codes: "200-299" 
    hosts:
#     - host:  vllm-api.com  # Replace with your domain
      - paths:
          - path: /
            pathType: Prefix

# Optional: TLS configuration
  # tls:
  #   - secretName: vllm-tls-secret
  #     hosts:
  #       - vllm-api.yourdomain.com      