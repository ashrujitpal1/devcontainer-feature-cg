#!/bin/bash
set -euo pipefail

# =============================================================================
# setup-github-oidc.sh
#
# One-time setup: Creates the IAM OIDC provider and role that allows
# GitHub Actions to publish delta policies to S3.
#
# Run this from your terminal where AWS credentials are configured
# for account 696072349808.
#
# Usage:
#   chmod +x setup-github-oidc.sh
#   ./setup-github-oidc.sh
# =============================================================================

AWS_ACCOUNT_ID="696072349808"
GITHUB_ORG="ashrujitpal1"
GITHUB_REPO="devcontainer-feature-cg"
ROLE_NAME="github-actions-s3-policy-publish"
S3_BUCKET="capital-group-claude-policies"

echo "=== Step 1: Create GitHub OIDC Identity Provider ==="
echo "(This is idempotent — will skip if already exists)"

if aws iam get-open-id-connect-provider \
  --open-id-connect-provider-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com" \
  >/dev/null 2>&1; then
  echo "OIDC provider already exists — skipping"
else
  aws iam create-open-id-connect-provider \
    --url "https://token.actions.githubusercontent.com" \
    --client-id-list "sts.amazonaws.com" \
    --thumbprint-list "6938fd4d98bab03faadb97b34396831e3780aea1" \
    --tags Key=Purpose,Value=GitHubActionsOIDC
  echo "OIDC provider created"
fi

echo ""
echo "=== Step 2: Create IAM Trust Policy ==="

TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:${GITHUB_ORG}/${GITHUB_REPO}:*"
        }
      }
    }
  ]
}
EOF
)

echo ""
echo "=== Step 3: Create IAM Role ==="

if aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
  echo "Role ${ROLE_NAME} already exists — updating trust policy"
  aws iam update-assume-role-policy \
    --role-name "${ROLE_NAME}" \
    --policy-document "${TRUST_POLICY}"
else
  aws iam create-role \
    --role-name "${ROLE_NAME}" \
    --assume-role-policy-document "${TRUST_POLICY}" \
    --description "Allows GitHub Actions to publish delta policies to S3 for Capital Group Claude platform" \
    --tags Key=Purpose,Value=GitHubActionsS3PolicyPublish
  echo "Role created"
fi

echo ""
echo "=== Step 4: Create and attach S3 policy ==="

S3_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowS3PolicyPublish",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::${S3_BUCKET}",
        "arn:aws:s3:::${S3_BUCKET}/*"
      ]
    }
  ]
}
EOF
)

POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${ROLE_NAME}-s3-access"

if aws iam get-policy --policy-arn "${POLICY_ARN}" >/dev/null 2>&1; then
  echo "Policy already exists — creating new version"
  aws iam create-policy-version \
    --policy-arn "${POLICY_ARN}" \
    --policy-document "${S3_POLICY}" \
    --set-as-default
else
  aws iam create-policy \
    --policy-name "${ROLE_NAME}-s3-access" \
    --policy-document "${S3_POLICY}" \
    --description "S3 access for publishing Claude delta policies"
  echo "Policy created"
fi

aws iam attach-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-arn "${POLICY_ARN}" 2>/dev/null || true

echo ""
echo "=== Step 5: Output ==="
ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_NAME}"
echo ""
echo "=============================================="
echo "  SETUP COMPLETE"
echo "=============================================="
echo ""
echo "Role ARN (add this as GitHub secret):"
echo "  ${ROLE_ARN}"
echo ""
echo "GitHub secret to create:"
echo "  Name:  AWS_POLICY_PUBLISH_ROLE_ARN"
echo "  Value: ${ROLE_ARN}"
echo ""
echo "To add the secret, go to:"
echo "  https://github.com/${GITHUB_ORG}/${GITHUB_REPO}/settings/secrets/actions/new"
echo ""
echo "=============================================="
