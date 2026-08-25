#!/bin/bash
set -euo pipefail

# Get account ID with error checking
if ! ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --no-cli-pager 2>/dev/null); then
    echo "❌ Error: Failed to get AWS account ID. Check your AWS credentials."
    exit 1
fi

if [[ -z "$ACCOUNT_ID" || ! "$ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
    echo "❌ Error: Invalid AWS account ID: '$ACCOUNT_ID'"
    exit 1
fi

CENTRAL=false
POSITIONAL_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --central) CENTRAL=true; shift ;;
        *) POSITIONAL_ARGS+=("$1"); shift ;;
    esac
done

# Prioritize: 1) positional arg, 2) AWS_REGION env var, 3) AWS CLI config, 4) default us-east-1
configured_region=$(aws configure get region 2>/dev/null || true)
REGION="${POSITIONAL_ARGS[0]:-${AWS_REGION:-${configured_region:-us-east-1}}}"

if [[ "$CENTRAL" == "true" ]]; then
    BUCKET_NAME="terraform-state-${ACCOUNT_ID}"
else
    BUCKET_NAME="terraform-state-${ACCOUNT_ID}-${REGION}"
fi

echo "Bootstrapping Terraform State in $REGION..."
echo "Bucket: $BUCKET_NAME"
echo ""

# Function to apply bucket security settings
apply_bucket_security() {
    echo "Applying security settings to bucket $BUCKET_NAME..."

    aws s3api put-bucket-versioning \
        --bucket "$BUCKET_NAME" \
        --versioning-configuration Status=Enabled \
        --region "$REGION" \
        --no-cli-pager

    aws s3api put-bucket-encryption \
        --bucket "$BUCKET_NAME" \
        --server-side-encryption-configuration '{"Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]}' \
        --region "$REGION" \
        --no-cli-pager

    aws s3api put-public-access-block \
        --bucket "$BUCKET_NAME" \
        --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" \
        --region "$REGION" \
        --no-cli-pager

    # Get AWS Organization ID to restrict access to organization members only
    ORG_ID=$(aws organizations describe-organization --query 'Organization.Id' --output text --no-cli-pager 2>/dev/null || echo "")

    # Add bucket policy to allow cross-account access from OrganizationAccountAccessRole
    # This allows target accounts in the same organization to access their state files
    if [ -n "$ORG_ID" ]; then
        echo "Detected AWS Organization: $ORG_ID"
        cat > /tmp/bucket-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowOrganizationAccountAccess",
      "Effect": "Allow",
      "Principal": "*",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::${BUCKET_NAME}",
        "arn:aws:s3:::${BUCKET_NAME}/*"
      ],
      "Condition": {
        "StringEquals": {
          "aws:PrincipalOrgID": "${ORG_ID}"
        }
      }
    }
  ]
}
EOF
    else
        echo "⚠️  Warning: Not in an AWS Organization, skipping cross-account bucket policy"
        echo "⚠️  Cross-account access will not work without a bucket policy"
        cat > /tmp/bucket-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyAll",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::${BUCKET_NAME}",
        "arn:aws:s3:::${BUCKET_NAME}/*"
      ],
      "Condition": {
        "StringNotEquals": {
          "aws:PrincipalAccount": "${ACCOUNT_ID}"
        }
      }
    }
  ]
}
EOF
    fi

    aws s3api put-bucket-policy \
        --bucket "$BUCKET_NAME" \
        --policy file:///tmp/bucket-policy.json \
        --region "$REGION" \
        --no-cli-pager

    rm -f /tmp/bucket-policy.json

    echo "✅ Security settings and cross-account policy applied"
}

# Create S3 Bucket
if aws s3api head-bucket --bucket "$BUCKET_NAME" --no-cli-pager 2>/dev/null; then
    echo "✅ Bucket $BUCKET_NAME already exists."
    apply_bucket_security
else
    echo "Creating bucket $BUCKET_NAME..."
    if [[ "$REGION" == "us-east-1" ]]; then
        aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$REGION" --no-cli-pager
    else
        aws s3api create-bucket --bucket "$BUCKET_NAME" --create-bucket-configuration LocationConstraint="$REGION" --region "$REGION" --no-cli-pager
    fi
    echo "✅ Bucket created successfully"
    apply_bucket_security
fi

echo ""
echo "✅ Bootstrap complete."
echo "   State bucket: $BUCKET_NAME"
echo "   Locking: lockfile (stored in S3)"
