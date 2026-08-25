#!/usr/bin/env bash
#
# Seed OIDC client secrets + allowed-source-CIDRs for SRE UI ALB
#
# Creates/updates AWS Secrets Manager secrets for OIDC client secrets
# (Grafana, ArgoCD, Prometheus, Thanos) and optionally the SSM parameter for
# allowed source CIDRs, all required by the Regional Cluster pipeline when
# enable_sre_oidc_auth and enable_sre_public_access are true.
#
# Usage:
#   REGION=us-east-1 ./scripts/dev/sre-oidc-secrets.sh
#   REGION=us-west-2 ./scripts/dev/sre-oidc-secrets.sh --no-cidrs
#   REGION=us-east-1 ./scripts/dev/sre-oidc-secrets.sh --services grafana,prometheus
#
# Prerequisites:
#   - Caller has active AWS credentials for the target RC account
#     (e.g. via AWS SSO, SAML, or aws-vault)
#   - RH SSO OIDC clients registered and client secrets issued
#   - jq installed
#
# The script is idempotent — safe to re-run for secret rotation.
#
# See docs/design/sre-ui-access.md for architecture context.

set -euo pipefail

REGION="${REGION:-us-east-1}"
SKIP_CIDRS=false
SERVICES=""

usage() {
    echo "Usage: REGION=<region> $0 [OPTIONS]"
    echo ""
    echo "Seed OIDC client secrets for SRE UI ALB in the target RC account."
    echo ""
    echo "Options:"
    echo "  --services <list>  Comma-separated list of services to configure"
    echo "                     (grafana,argocd,prometheus,thanos)"
    echo "                     If omitted, you'll be prompted interactively for each service"
    echo "  --no-cidrs         Skip the allowed-source-CIDRs SSM parameter (for internal-only ALB)"
    echo ""
    echo "Environment:"
    echo "  REGION             AWS region (default: us-east-1)"
    echo ""
    echo "Examples:"
    echo "  # Configure all services interactively (prompts yes/no for each):"
    echo "  REGION=us-east-1 $0"
    echo ""
    echo "  # Configure only Grafana:"
    echo "  REGION=us-east-1 $0 --services grafana"
    echo ""
    echo "  # Configure Grafana and Prometheus, skip CIDRs:"
    echo "  REGION=us-east-1 $0 --services grafana,prometheus --no-cidrs"
    exit 1
}

die() { echo "Error: $*" >&2; exit 1; }

while [ "${1:-}" != "" ]; do
    case $1 in
        --no-cidrs )    SKIP_CIDRS=true ;;
        --services )    SERVICES="${2:-}"
                        shift
                        ;;
        --help )        usage ;;
        * )             echo "Unexpected parameter: $1"; usage ;;
    esac
    shift
done

command -v aws >/dev/null 2>&1 || die "aws CLI not found"
command -v jq >/dev/null 2>&1 || die "jq not found"

# =============================================================================
# Identity & Confirmation
# =============================================================================

echo "Fetching AWS identity..."
identity_json=$(aws sts get-caller-identity 2>/dev/null) \
    || die "Failed to get AWS identity. Are you authenticated?"

account=$(echo "$identity_json" | jq -r '.Account')
arn=$(echo "$identity_json" | jq -r '.Arn')

echo ""
echo "=== SRE OIDC Secrets Seeding ==="
echo "  AWS Account:  $account"
echo "  Identity:     $arn"
echo "  Region:       $REGION"
echo ""

# Determine which services to configure
AVAILABLE_SERVICES="grafana argocd prometheus thanos"
SERVICES_TO_CONFIGURE=""

if [ -n "$SERVICES" ]; then
    # Services specified via --services flag
    SERVICES_TO_CONFIGURE="$SERVICES"
    echo "Services (from --services): $SERVICES_TO_CONFIGURE"
else
    # Interactive mode - ask for each service
    echo "Select services to configure (y/n for each):"
    for svc in $AVAILABLE_SERVICES; do
        read -p "  Configure ${svc}? [y/N]: " answer
        case "$answer" in
            [Yy]* )
                SERVICES_TO_CONFIGURE="${SERVICES_TO_CONFIGURE:+$SERVICES_TO_CONFIGURE,}$svc"
                ;;
        esac
    done
fi

# Convert comma-separated list to space-separated
SERVICES_LIST=$(echo "$SERVICES_TO_CONFIGURE" | tr ',' ' ')

if [ -z "$SERVICES_LIST" ]; then
    echo ""
    echo "No services selected. Nothing to do."
    exit 0
fi

echo ""
echo "Will configure secrets for: $SERVICES_LIST"
if [ "$SKIP_CIDRS" = false ]; then
    echo "Will configure: /infra/sre-ui-alb/allowed-source-cidrs SSM parameter"
fi
echo ""
read -p "Proceed? (type 'yes' to confirm): " confirm

if [ "$confirm" != "yes" ]; then
    echo "Aborted."
    exit 0
fi

# =============================================================================
# Seed OIDC Client Secrets
# =============================================================================

for svc in $SERVICES_LIST; do
    secret_id="sre-ui-alb/${svc}/oidc-client-secret"
    echo ""
    echo "==> ${svc} OIDC client secret"
    echo "    Secret ID: ${secret_id}"
    echo "    RH SSO client: rosa-hyperfleet-${svc}-sre-<env>-${REGION}"
    echo ""
    read -rs -p "    Paste the OIDC client secret (input hidden): " secret_value
    echo ""

    if [ -z "$secret_value" ]; then
        echo "    ⚠️  Skipping (empty value)"
        continue
    fi

    # Try create first; on ResourceExistsException, fall back to update
    if aws secretsmanager create-secret \
        --name "$secret_id" \
        --secret-string "$secret_value" \
        --region "$REGION" \
        --description "OIDC client secret for ${svc} SRE UI (ALB authenticate-oidc)" \
        >/dev/null 2>&1; then
        echo "    ✅ Created: ${secret_id}"
    else
        # Assume it exists; update the secret version
        if aws secretsmanager put-secret-value \
            --secret-id "$secret_id" \
            --secret-string "$secret_value" \
            --region "$REGION" \
            >/dev/null 2>&1; then
            echo "    ✅ Updated: ${secret_id}"
        else
            echo "    ❌ Failed to create or update: ${secret_id}" >&2
            exit 1
        fi
    fi
done

# =============================================================================
# Seed Allowed Source CIDRs (SSM Parameter)
# =============================================================================

if [ "$SKIP_CIDRS" = false ]; then
    echo ""
    echo "==> Allowed source CIDRs for public SRE UI ALB"
    echo "    SSM parameter: /infra/sre-ui-alb/allowed-source-cidrs"
    echo ""
    echo "    This is a JSON list of CIDR blocks (e.g. [\"1.2.3.4/32\", \"5.6.0.0/16\"])."
    echo "    Type [] to explicitly allow all (not recommended for production)."
    echo "    Leave empty to skip."
    echo ""
    read -p "    Paste the JSON list: " cidrs_value

    # Abort if empty response (user just hit enter)
    if [ -z "$cidrs_value" ]; then
        echo "    ⚠️  Skipping CIDRs parameter (empty input)" >&2
        echo ""
        echo "✅ Seeding complete!"
        echo ""
        echo "Next steps:"
        echo "  1. Verify secrets:"
        echo "     aws secretsmanager list-secrets --region $REGION --query 'SecretList[?starts_with(Name, \`sre-ui-alb/\`)].Name' --output table"
        echo "  2. Configure /infra/sre-ui-alb/allowed-source-cidrs SSM parameter manually or re-run this script with --no-cidrs to skip the prompt."
        echo "  3. Run the RC pipeline — it will fetch these secrets at runtime."
        echo ""
        exit 0
    fi

    # Validate it's valid JSON
    if ! echo "$cidrs_value" | jq -e . >/dev/null 2>&1; then
        echo "    ❌ Invalid JSON. Skipping CIDRs parameter." >&2
    else
        if aws ssm put-parameter \
            --name "/infra/sre-ui-alb/allowed-source-cidrs" \
            --value "$cidrs_value" \
            --type String \
            --overwrite \
            --region "$REGION" \
            --description "Allowed source CIDRs for SRE UI ALB (public mode)" \
            >/dev/null 2>&1; then
            echo "    ✅ Created/updated: /infra/sre-ui-alb/allowed-source-cidrs"
        else
            echo "    ❌ Failed to write SSM parameter" >&2
            exit 1
        fi
    fi
fi

# =============================================================================
# Done
# =============================================================================

echo ""
echo "✅ Seeding complete!"
echo ""
echo "Next steps:"
echo "  1. Verify secrets:"
echo "     aws secretsmanager list-secrets --region $REGION --query 'SecretList[?starts_with(Name, \`sre-ui-alb/\`)].Name' --output table"
if [ "$SKIP_CIDRS" = false ]; then
    echo "  2. Verify CIDRs:"
    echo "     aws ssm get-parameter --name /infra/sre-ui-alb/allowed-source-cidrs --region $REGION --query Parameter.Value --output text"
fi
echo "  3. Run the RC pipeline — it will fetch these secrets at runtime."
echo ""
