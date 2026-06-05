#!/usr/bin/env bash
# Run this in AWS CloudShell to:
#   1. Add repo:Themis128/OMV:* to the cloudless-github-oidc IAM role trust policy
#   2. Create SSM Parameter Store entries for the cloudless-ops IAM key
#
# Usage:
#   AWS_SECRET_ACCESS_KEY_VALUE=<secret> bash scripts/fix-oidc-and-ssm.sh

set -euo pipefail

ROLE_NAME="cloudless-github-oidc"
REPO_SUBJECT="repo:Themis128/OMV:*"
SSM_KEY_ID_PARAM="/sst/cloudless/github/AWS_ACCESS_KEY_ID"
SSM_SECRET_PARAM="/sst/cloudless/github/AWS_SECRET_ACCESS_KEY"
AWS_KEY_ID="${AWS_ACCESS_KEY_ID_VALUE:-AKIAUBXIAELUS34WI2KW}"

# Prompt for secret if not provided
if [[ -z "${AWS_SECRET_ACCESS_KEY_VALUE:-}" ]]; then
  read -rsp "Enter AWS Secret Access Key for ${AWS_KEY_ID}: " AWS_SECRET_ACCESS_KEY_VALUE
  echo
fi

echo "=== Step 1: Fix OIDC trust policy for ${ROLE_NAME} ==="

CURRENT_POLICY=$(aws iam get-role --role-name "${ROLE_NAME}" \
  --query 'Role.AssumeRolePolicyDocument' --output json)

if echo "${CURRENT_POLICY}" | grep -q "${REPO_SUBJECT}"; then
  echo "✅ ${REPO_SUBJECT} already in trust policy — skipping update"
else
  UPDATED_POLICY=$(echo "${CURRENT_POLICY}" | python3 -c "
import json, sys
policy = json.load(sys.stdin)
for stmt in policy['Statement']:
    cond = stmt.get('Condition', {})
    like = cond.get('StringLike', {})
    sub = like.get('token.actions.githubusercontent.com:sub', [])
    if isinstance(sub, str):
        sub = [sub]
    if 'repo:Themis128/OMV:*' not in sub:
        sub.append('repo:Themis128/OMV:*')
        like['token.actions.githubusercontent.com:sub'] = sub
        cond['StringLike'] = like
        stmt['Condition'] = cond
print(json.dumps(policy))
")

  aws iam update-assume-role-policy \
    --role-name "${ROLE_NAME}" \
    --policy-document "${UPDATED_POLICY}"
  echo "✅ Added ${REPO_SUBJECT} to trust policy"
fi

echo ""
echo "=== Step 2: Create/update SSM parameters ==="

aws ssm put-parameter \
  --name "${SSM_KEY_ID_PARAM}" \
  --value "${AWS_KEY_ID}" \
  --type "String" \
  --overwrite \
  --region us-east-1
echo "✅ Stored ${SSM_KEY_ID_PARAM}"

aws ssm put-parameter \
  --name "${SSM_SECRET_PARAM}" \
  --value "${AWS_SECRET_ACCESS_KEY_VALUE}" \
  --type "SecureString" \
  --overwrite \
  --region us-east-1
echo "✅ Stored ${SSM_SECRET_PARAM}"

echo ""
echo "=== Done ==="
echo "Next: trigger apply-github-secrets-from-ssm from GitHub Actions"
echo "  https://github.com/Themis128/OMV/actions/workflows/apply-github-secrets-from-ssm.yml"
