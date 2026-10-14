#!/usr/bin/env bash
# Remove known orphan AWS resources for deprovisioned / failed ephemeral envs
# when pipelines and terraform state are already gone.
#
# Default targets: f37869e8 (RC VPC shell + DynamoDB + logs),
#                  046f5f15 (MC VPC + Lambda ENIs + logs).
#
# Usage:
#   ./scripts/dev/ephemeral-orphan-cleanup.sh              # dry-run
#   ./scripts/dev/ephemeral-orphan-cleanup.sh --execute    # delete resources
#   ./scripts/dev/ephemeral-orphan-cleanup.sh --execute --id fb3672ae
#
# Requires: aws CLI, jq; profiles rrp-regional-dev and rrp-management-dev.
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
RC_PROFILE="${EPH_RC_PROFILE:-rrp-regional-dev}"
MC_PROFILE="${EPH_MC_PROFILE:-rrp-management-dev}"
EXECUTE=false
IDS=(f37869e8 046f5f15)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --execute) EXECUTE=true; shift ;;
    --id)
      IDS=("$2")
      shift 2
      ;;
    -h|--help)
      sed -n '1,18p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

run() {
  if [[ "${EXECUTE}" == "true" ]]; then
    log "RUN: $*"
    "$@"
  else
    log "DRY-RUN: $*"
  fi
}

delete_dynamodb_tables() {
  local profile="$1"
  local prefix="$2"
  local tables
  tables=$(aws dynamodb list-tables --profile "$profile" --region "$REGION" --output json \
    | jq -r --arg p "$prefix" '.TableNames[]? | select(startswith($p))')
  if [[ -z "${tables}" ]]; then
    log "  DynamoDB (${profile}): none"
    return 0
  fi
  while IFS= read -r table; do
    [[ -z "$table" ]] && continue
    run aws dynamodb delete-table --profile "$profile" --region "$REGION" --table-name "$table"
  done <<< "${tables}"
}

delete_log_groups() {
  local profile="$1"
  local id="$2"
  local groups
  groups=$(aws logs describe-log-groups --profile "$profile" --region "$REGION" --output json \
    | jq -r --arg id "$id" '.logGroups[]? | select(.logGroupName | contains($id)) | .logGroupName')
  if [[ -z "${groups}" ]]; then
    log "  CloudWatch logs (${profile}): none"
    return 0
  fi
  while IFS= read -r group; do
    [[ -z "$group" ]] && continue
    run aws logs delete-log-group --profile "$profile" --region "$REGION" --log-group-name "$group"
  done <<< "${groups}"
}

delete_apigw_vpc_links_for_env() {
  local profile="$1"
  local id="$2"
  local links
  links=$(aws apigatewayv2 get-vpc-links --profile "$profile" --region "$REGION" --output json 2>/dev/null \
    | jq -r --arg id "$id" '.Items[]? | select(.Name | contains($id)) | .VpcLinkId' || true)
  if [[ -z "${links}" ]]; then
    return 0
  fi
  while IFS= read -r link_id; do
    [[ -z "$link_id" ]] && continue
    run aws apigatewayv2 delete-vpc-link --profile "$profile" --region "$REGION" --vpc-link-id "$link_id"
  done <<< "${links}"
}

delete_enis_in_vpc() {
  local profile="$1"
  local vpc_id="$2"
  local enis
  enis=$(aws ec2 describe-network-interfaces --profile "$profile" --region "$REGION" \
    --filters "Name=vpc-id,Values=${vpc_id}" \
    --query 'NetworkInterfaces[*].NetworkInterfaceId' --output text)
  for eni in ${enis}; do
    [[ -z "$eni" || "$eni" == "None" ]] && continue
    local attachment_id
    attachment_id=$(aws ec2 describe-network-interfaces --profile "$profile" --region "$REGION" \
      --network-interface-ids "$eni" \
      --query 'NetworkInterfaces[0].Attachment.AttachmentId' --output text 2>/dev/null || true)
    if [[ -n "${attachment_id}" && "${attachment_id}" != "None" ]]; then
      run aws ec2 detach-network-interface --profile "$profile" --region "$REGION" \
        --attachment-id "$attachment_id" --force
    fi
    run aws ec2 delete-network-interface --profile "$profile" --region "$REGION" \
      --network-interface-id "$eni"
  done
}

delete_route_tables_in_vpc() {
  local profile="$1"
  local vpc_id="$2"
  local rt_ids
  # Delete every non-main route table (including orphaned tables with zero associations).
  rt_ids=$(aws ec2 describe-route-tables --profile "$profile" --region "$REGION" \
    --filters "Name=vpc-id,Values=${vpc_id}" --output json \
    | jq -r '.RouteTables[] | select([.Associations[]? | select(.Main == true)] | length == 0) | .RouteTableId')
  while IFS= read -r rt_id; do
    [[ -z "$rt_id" ]] && continue
    local assoc_ids
    assoc_ids=$(aws ec2 describe-route-tables --profile "$profile" --region "$REGION" \
      --route-table-ids "$rt_id" --output json \
      | jq -r '.RouteTables[0].Associations[]? | select(.Main != true) | .RouteTableAssociationId')
    while IFS= read -r assoc_id; do
      [[ -z "$assoc_id" ]] && continue
      run aws ec2 disassociate-route-table --profile "$profile" --region "$REGION" \
        --association-id "$assoc_id"
    done <<< "${assoc_ids}"
    run aws ec2 delete-route-table --profile "$profile" --region "$REGION" --route-table-id "$rt_id"
  done <<< "${rt_ids}"
}

delete_vpc_endpoints_in_vpc() {
  local profile="$1"
  local vpc_id="$2"
  local endpoint_ids
  endpoint_ids=$(aws ec2 describe-vpc-endpoints --profile "$profile" --region "$REGION" \
    --filters "Name=vpc-id,Values=${vpc_id}" \
    --query 'VpcEndpoints[*].VpcEndpointId' --output text)
  for endpoint_id in ${endpoint_ids}; do
    [[ -z "$endpoint_id" || "$endpoint_id" == "None" ]] && continue
    run aws ec2 delete-vpc-endpoints --profile "$profile" --region "$REGION" \
      --vpc-endpoint-ids "$endpoint_id"
  done
}

detach_and_delete_internet_gateways() {
  local profile="$1"
  local vpc_id="$2"
  local igw_ids
  igw_ids=$(aws ec2 describe-internet-gateways --profile "$profile" --region "$REGION" \
    --filters "Name=attachment.vpc-id,Values=${vpc_id}" \
    --query 'InternetGateways[*].InternetGatewayId' --output text)
  for igw_id in ${igw_ids}; do
    [[ -z "$igw_id" || "$igw_id" == "None" ]] && continue
    run aws ec2 detach-internet-gateway --profile "$profile" --region "$REGION" \
      --internet-gateway-id "$igw_id" --vpc-id "$vpc_id"
    run aws ec2 delete-internet-gateway --profile "$profile" --region "$REGION" \
      --internet-gateway-id "$igw_id"
  done
}

delete_vpc_by_id() {
  local profile="$1"
  local vpc_id="$2"
  local name="$3"
  local env_id="$4"

  log "  VPC ${name} (${vpc_id}) in ${profile}"

  delete_apigw_vpc_links_for_env "$profile" "$env_id"

  local nat_ids
  nat_ids=$(aws ec2 describe-nat-gateways --profile "$profile" --region "$REGION" \
    --filter "Name=vpc-id,Values=${vpc_id}" "Name=state,Values=available,pending,deleting" \
    --query 'NatGateways[*].NatGatewayId' --output text)
  for nat in ${nat_ids}; do
    [[ -z "$nat" || "$nat" == "None" ]] && continue
    run aws ec2 delete-nat-gateway --profile "$profile" --region "$REGION" --nat-gateway-id "$nat"
  done

  delete_enis_in_vpc "$profile" "$vpc_id"
  delete_vpc_endpoints_in_vpc "$profile" "$vpc_id"

  local subnet_ids
  subnet_ids=$(aws ec2 describe-subnets --profile "$profile" --region "$REGION" \
    --filters "Name=vpc-id,Values=${vpc_id}" \
    --query 'Subnets[*].SubnetId' --output text)
  for subnet in ${subnet_ids}; do
    [[ -z "$subnet" || "$subnet" == "None" ]] && continue
    run aws ec2 delete-subnet --profile "$profile" --region "$REGION" --subnet-id "$subnet"
  done

  delete_route_tables_in_vpc "$profile" "$vpc_id"
  detach_and_delete_internet_gateways "$profile" "$vpc_id"

  local pass
  for pass in 1 2 3; do
    local sg_ids
    sg_ids=$(aws ec2 describe-security-groups --profile "$profile" --region "$REGION" \
      --filters "Name=vpc-id,Values=${vpc_id}" \
      --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text)
    [[ -z "${sg_ids}" || "${sg_ids}" == "None" ]] && break
    for sg in ${sg_ids}; do
      [[ -z "$sg" || "$sg" == "None" ]] && continue
      run aws ec2 delete-security-group --profile "$profile" --region "$REGION" --group-id "$sg"
    done
  done

  run aws ec2 delete-vpc --profile "$profile" --region "$REGION" --vpc-id "$vpc_id"
}

delete_vpcs_for_env() {
  local profile="$1"
  local id="$2"
  local vpcs_json
  vpcs_json=$(aws ec2 describe-vpcs --profile "$profile" --region "$REGION" --output json \
    | jq -r --arg id "$id" '.Vpcs[] | select([.Tags[]?.Value] | any(. != null and contains($id))) | [.VpcId, (.Tags[]|select(.Key=="Name")|.Value)] | @tsv')
  if [[ -z "${vpcs_json}" ]]; then
    log "  VPCs (${profile}): none"
    return 0
  fi
  while IFS=$'\t' read -r vpc_id vpc_name; do
    delete_vpc_by_id "$profile" "$vpc_id" "$vpc_name" "$id"
  done <<< "${vpcs_json}"
}

cleanup_env() {
  local id="$1"
  local prefix="eph-${id}"
  log "======== ${id} (prefix ${prefix}) ========"

  delete_dynamodb_tables "$RC_PROFILE" "$prefix"
  delete_log_groups "$RC_PROFILE" "$id"
  delete_log_groups "$MC_PROFILE" "$id"
  delete_vpcs_for_env "$RC_PROFILE" "$id"
  delete_vpcs_for_env "$MC_PROFILE" "$id"

  log "Done ${id}"
}

if [[ "${EXECUTE}" != "true" ]]; then
  log "Dry-run only. Pass --execute to delete resources."
fi

for id in "${IDS[@]}"; do
  cleanup_env "$id"
done

log "Finished."
