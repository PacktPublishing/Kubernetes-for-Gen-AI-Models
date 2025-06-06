module "eks_blueprints_addons" {
  source = "aws-ia/eks-blueprints-addons/aws"
  version = "~> 1.21"
  cluster_name = module.eks.cluster_name
  cluster_endpoint = module.eks.cluster_endpoint
  cluster_version = module.eks.cluster_version
  oidc_provider_arn = module.eks.oidc_provider_arn
  enable_aws_load_balancer_controller = true
  enable_secrets_store_csi_driver = true
  enable_secrets_store_csi_driver_provider_aws = true

  secrets_store_csi_driver = {
    chart_version = "1.5.0"
    values = [
      <<-EOT
      syncSecret:
        enabled: true
      EOT
    ]
  }
  
  secrets_store_csi_driver_provider_aws = {
    chart_version = "1.0.1"
    values = [
      <<-EOT
      tolerations:
        - operator: Exists
      EOT
    ]
  }
  eks_addons = {
    aws-ebs-csi-driver = {
      service_account_role_arn = module.ebs_csi_driver_irsa.iam_role_arn
    }
    metrics-server = {}
    coredns = {}
    kube-proxy = {}
    vpc-cni = {}
    eks-pod-identity-agent = {}
  }
  enable_kube_prometheus_stack = true
  kube_prometheus_stack = {
    values = [
      templatefile("${path.module}/kube-prometheus.yaml", {
        storage_class_type     = kubernetes_storage_class.default_gp3.id
      })
    ]
    chart_version = "72.3.0"
    namespace     = "monitoring"
  }

  helm_releases = {
    "prometheus-adapter" = {
      repository = "https://prometheus-community.github.io/helm-charts"
      chart      = "prometheus-adapter"
      namespace  = module.eks_blueprints_addons.kube_prometheus_stack.namespace
      version    = "4.46.0"
    }
  }
}

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.36"

  cluster_name          = module.eks.cluster_name
  enable_v1_permissions = true
  namespace             = "kube-system"

  node_iam_role_use_name_prefix   = false
  node_iam_role_name              = local.name
  create_pod_identity_association = true
}

resource "helm_release" "karpenter" {
  name                = "karpenter"
  namespace           = "kube-system"
  repository          = "oci://public.ecr.aws/karpenter"
  chart               = "karpenter"
  version             = "1.4.0"

  values = [
    <<-EOT
    settings:
      clusterName: ${module.eks.cluster_name}
      clusterEndpoint: ${module.eks.cluster_endpoint}
      interruptionQueue: ${module.karpenter.queue_name}
    webhook:
      enabled: false
    EOT
  ]

  lifecycle {
    ignore_changes = [
      repository_password
    ]
  }
}

#---------------------------------------------------------------
# IRSA for EBS CSI Driver
#---------------------------------------------------------------
module "ebs_csi_driver_irsa" {
  source = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.55"
  role_name_prefix = format("%s-%s", local.name, "ebs-csi-driver-")
  attach_ebs_csi_policy = true
  oidc_providers = {
    main = {
      provider_arn = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}

#---------------------------------------------------------------
# GP3 Encrypted Storage Class
#---------------------------------------------------------------
resource "kubernetes_annotations" "disable_gp2" {
  annotations = {
    "storageclass.kubernetes.io/is-default-class" : "false"
  }
  api_version = "storage.k8s.io/v1"
  kind        = "StorageClass"
  metadata {
    name = "gp2"
  }
  force = true

  depends_on = [module.eks.eks_cluster_id]
}

resource "kubernetes_storage_class" "default_gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" : "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  allow_volume_expansion = true
  volume_binding_mode    = "WaitForFirstConsumer"
  parameters = {
    fsType    = "ext4"
    encrypted = true
    type      = "gp3"
  }

  depends_on = [kubernetes_annotations.disable_gp2]
}

data "http" "kubecost_values" {
  url = "https://raw.githubusercontent.com/kubecost/cost-analyzer-helm-chart/develop/cost-analyzer/values-eks-cost-monitoring.yaml"
}

resource "helm_release" "kubecost" {
  name       = "kubecost"
  repository = "oci://public.ecr.aws/kubecost"
  chart      = "cost-analyzer"
  namespace  = "kubecost"
  create_namespace = true
  values = [data.http.kubecost_values.response_body]
}
