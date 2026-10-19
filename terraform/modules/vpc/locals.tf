locals {
  # Span the VPC across every in-region availability zone.
  #
  # This is required for management clusters: the HyperShift PrivateLink endpoint
  # service only advertises the AZs its NLB has subnets in, and a customer's
  # worker subnets may land in ANY AZ ID of the region. Matching is done by
  # account-independent AZ ID, so the management VPC must cover every AZ to avoid
  # "endpoint service does not support the availability zone" errors.
  azs = data.aws_availability_zones.available.names

  # One subnet per AZ, carved from the VPC CIDR. Private subnets are /19 and
  # public subnets /24 for a /16 VPC, which fits up to 6 AZs without overlap.
  private_subnet_cidrs = [for i in range(length(local.azs)) : cidrsubnet(var.vpc_cidr, 3, i)]
  public_subnet_cidrs  = [for i in range(length(local.azs)) : cidrsubnet(var.vpc_cidr, 8, 240 + i)]

  common_tags = {
    function  = "cluster-infra"
    module    = "vpc"
    ManagedBy = "terraform"
  }
}
