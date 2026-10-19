# =============================================================================
# Data Sources
# =============================================================================

data "aws_availability_zones" "available" {
  state = "available"

  # Restrict to standard, in-region AZs. This excludes Local Zones and
  # Wavelength zones, which cannot back the HyperShift PrivateLink NLB /
  # endpoint service that management clusters rely on.
  filter {
    name   = "zone-type"
    values = ["availability-zone"]
  }
}

data "aws_region" "current" {}
