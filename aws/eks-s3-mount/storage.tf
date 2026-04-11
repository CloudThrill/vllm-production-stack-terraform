
# Create EFS file system and mount targets separately  
locals {
  enable_efs_storage = var.enable_efs_storage && var.enable_efs_csi_driver
}

resource "aws_efs_file_system" "eks-efs" {
  count          = local.enable_efs_storage ? 1 : 0
  creation_token = "${var.cluster_name}-efs"

  performance_mode                = "generalPurpose"
  throughput_mode                 = "provisioned"
  provisioned_throughput_in_mibps = 100
  encrypted                       = true
  # lifecycle_policy {
  #   transition_to_ia = "AFTER_30_DAYS"
  # }
  tags = {
    Name = "eks-${var.cluster_name}-efs"
  }
}

# Create mount targets in each private subnet  
resource "aws_efs_mount_target" "eks-efs-mounts" {
  count           = local.enable_efs_storage ? length(local.private_subnet_ids) : 0
  file_system_id  = aws_efs_file_system.eks-efs[0].id
  subnet_id       = local.private_subnet_ids[count.index]
  security_groups = [aws_security_group.efs-sg[0].id, module.eks.cluster_primary_security_group_id]

  # being explicit helps Terraform order things correctly
  depends_on = [
    module.vpc,
    aws_efs_file_system.eks-efs,
  ]
}

###############################################################
# Security group for EFS  
##############################################################
resource "aws_security_group" "efs-sg" {
  count       = local.enable_efs_storage ? 1 : 0
  name_prefix = "eks-${var.cluster_name}-efs-"
  vpc_id      = local.vpc_id
  description = "EFS security group for EKS cluster ${var.cluster_name}"
  ingress {
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "Allow NFS traffic from VPC"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }

  tags = {
    Name = "${var.cluster_name}-efs-sg"
  }
}

##############################################################
# Storage class for EFS
##############################################################

resource "kubernetes_storage_class_v1" "eks-efs-sc" {
  count = local.enable_efs_storage ? 1 : 0
  metadata {
    name = "efs-sc"
  }

  storage_provisioner = "efs.csi.aws.com"

  parameters = {
    provisioningMode = "efs-ap"
    fileSystemId     = aws_efs_file_system.eks-efs[0].id
    directoryPerms   = "0755"
  }

  depends_on = [module.eks_addons.aws_efs_csi_driver]
}


##############################################################
# S3 Storage for vLLM Models
##############################################################

#--------------------------------------------------------------
# S3 Storage for vLLM Models
#--------------------------------------------------------------

locals {
  s3_bucket_name = var.create_s3_bucket ? one(aws_s3_bucket.vllm_models[*].id) : var.s3_bucket
}

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