# AWS Load Balancer Controller Module

IAM role and EKS Pod Identity association for the [AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/). The Helm chart is deployed via ArgoCD from `argocd/config/regional-cluster/aws-load-balancer-controller/`.

## Usage

```hcl
module "aws_load_balancer_controller" {
  source       = "../../modules/aws-load-balancer-controller"
  cluster_name = module.regional_cluster.cluster_name
}
```
