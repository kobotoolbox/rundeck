#!/bin/bash

# Variables
AWS="/usr/local/bin/aws"
DATE=$(date +"%Y%m%d.%H%M%S")
ENV=@option.ENVIRONMENT@
LAUNCH_CONFIGURATION_NAME="m5-reserved-instances-launch-config-${DATE}"
KOBO_INSTALL_DIR="/home/ubuntu/kobo-install"
KOBO_EC2_DIR="/home/ubuntu/kobo-ec2"
KOBO_INSTALL_VERSION=@option.KOBO_INSTALL_VERSION@
LATEST_VERSION_TAG="latest"

function check-action {
    VALUE="$1"
    if [[ "${ERROR_CODE}" == "0" ]]; then
        if [[ -n "${VALUE}" ]]; then
            echo-with-date "${MESSAGE_OK}"
        else
          echo-with-date "ERROR: ${MESSAGE_ERROR}"
          terminate-tmp-instances
          exit 1
        fi
    else
        echo-with-date "ERROR: ${MESSAGE_ERROR}"
        terminate-tmp-instances
        exit 1
    fi
}

function echo-with-date {
    MESSAGE="$1"
    echo "[ $(date) ] ${MESSAGE}"
}

function terminate-tmp-instances {
    INSTANCE_IDS=$($AWS ec2 describe-instances \
        --region ${EC2_REGION} \
        --filters "Name=tag:Name,Values=rundeck-tmp-ami" "Name=instance-state-name,Values=running" \
        --query "Reservations[].Instances[].InstanceId" \
        --output text)
    echo-with-date "Removing temporary instances..."
    #TERMINATE_INSTANCE=$($AWS ec2 terminate-instances --region ${EC2_REGION} --instance-ids $INSTANCE_IDS)
    if [[ "$(echo $?)" == "0" ]]; then
        echo-with-date "Termination of temporary instances have succeeded"
    else
        echo-with-date "Termination of temporary instances have failed"
    fi

}

echo-with-date "Environment variables"
echo "    DATE: ${DATE}"
echo "    ENV: ${ENV}"
echo "    KOBO_INSTALL_VERSION: ${KOBO_INSTALL_VERSION}"
echo "    LAUNCH_CONFIGURATION_NAME: ${LAUNCH_CONFIGURATION_NAME}"
source /var/lib/rundeck/kobo/${ENV}.env
echo "    AUTO_SCALING_GROUP_NAME: ${AUTO_SCALING_GROUP_NAME}"
echo "    EC2_REGION: ${EC2_REGION}"
echo "    INSTANCE_TYPE: ${INSTANCE_TYPE}"
echo "    SUBNET_ID: ${SUBNET_ID}"
echo "    KEY_PAIR_NAME: ${KEY_PAIR_NAME}"
echo "    SECURITY_GROUP_NGINX: ${SECURITY_GROUP_NGINX}"
echo "    SECURITY_GROUP_SSH: ${SECURITY_GROUP_SSH}"
echo "    SECURITY_GROUP_RUNDECK_SSH: ${SECURITY_GROUP_RUNDECK_SSH}"
echo "    IAM_ROLE: ${IAM_ROLE}"
echo "    KEY_SSH: ${KEY_SSH}"

# Tests Variables
if [[ ! -n "$ENV" || ! -n "$AUTO_SCALING_GROUP_NAME" || ! -n "$KOBO_INSTALL_VERSION" || ! -n "$EC2_REGION" || ! -n "$INSTANCE_TYPE" || ! -n "$SUBNET_ID" || ! -n "$KEY_PAIR_NAME" || ! -n "$SECURITY_GROUP_NGINX" || ! -n "$SECURITY_GROUP_SSH" || ! -n "$SECURITY_GROUP_RUNDECK_SSH" || ! -n "$IAM_ROLE" || ! -n "$KOBO_EC2_MONITORED_DOMAIN" ]]; then
    echo-with-date "Arguments missing"
    exit 1
fi

# Find latest AMI id - output : ami-039ef8fda247219c5
echo-with-date "Retrieving current latest AMI id..."
OLD_AMI_ID=$($AWS ec2 describe-images \
    --region ${EC2_REGION} \
    --filters "Name=tag:version,Values=${LATEST_VERSION_TAG}" \
    --query "Images[].ImageId" \
    --output text)
ERROR_CODE=$(echo $?)
MESSAGE_OK="Found current latest AMI: ${OLD_AMI_ID}"
MESSAGE_ERROR="Could not retrieve current latest AMI"
check-action "${OLD_AMI_ID}"

# Tell AWS to create a new EC2 instance using current AMI
echo-with-date "Launching new EC2 instance..."
LAUNCH_INSTANCE=$($AWS ec2 run-instances \
        --image-id ${OLD_AMI_ID} \
        --instance-type ${INSTANCE_TYPE} \
        --region ${EC2_REGION} \
        --count 1 \
        --subnet-id "${SUBNET_ID}" \
        --key-name "${KEY_PAIR_NAME}" \
        --security-group-ids "${SECURITY_GROUP_SSH}" "${SECURITY_GROUP_RUNDECK_SSH}" \
        --monitoring Enabled=true \
        --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=60}" \
        --ebs-optimized \
        --iam-instance-profile Name="${IAM_ROLE}" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=billing,Value=${ENV}},{Key=kobo-ec2-environment-type,Value=frontend},{Key=kobo-ec2-version,Value=rundeck-support},{Key=kobo-ec2-monitored-domain,Value=${KOBO_EC2_MONITORED_DOMAIN}},{Key=kobo-env-branch,Value=${ENV}},{Key=kobo-ec2-use-swap,Value=0},{Key=kobo-install-version,Value=${KOBO_INSTALL_VERSION}},{Key=Name,Value=rundeck-tmp-ami}]")
ERROR_CODE=$(echo $?)
MESSAGE_OK="Instance launching has succeeded"
MESSAGE_ERROR="Instance launching has failed"
check-action "${LAUNCH_INSTANCE}"


# Get ID of new instance
INSTANCE_ID=$($AWS ec2 describe-instances \
    --region ${EC2_REGION} \
    --filters "Name=tag:Name,Values=rundeck-tmp-ami" \
    --query "Reservations[].Instances[].[LaunchTime,InstanceId]" \
    --output json | jq -r "sort_by(.[0])|reverse|.[0][1]")

ERROR_CODE=$(echo $?)
MESSAGE_OK="New instance ID: ${INSTANCE_ID}"
MESSAGE_ERROR="Could not retrieve new instance ID"
check-action "${INSTANCE_ID}"

# Wait for instance creation
while [ "$($AWS ec2 describe-instances --region ${EC2_REGION} --instance-ids ${INSTANCE_ID} --query 'Reservations[].Instances[].State.Name' --output text)" != "running" ]; do
    echo-with-date "Instance creation in progress..."
    sleep 10
done

echo-with-date "Instance creation has succeeded"

# Get public IP of new instance
PUBLIC_DNS_INSTANCE=$($AWS ec2 describe-instances \
    --region ${EC2_REGION} \
    --instance-ids ${INSTANCE_ID} \
    --query "Reservations[*].Instances[*].[PublicDnsName]" \
    --output text | tail -n1)
ERROR_CODE=$(echo $?)
MESSAGE_OK="Public DNS of new instance: ${PUBLIC_DNS_INSTANCE}"
MESSAGE_ERROR="New instance does not have a public DNS"
check-action "${PUBLIC_DNS_INSTANCE}"

SSH="ssh -o StrictHostKeyChecking=no -i $KEY_SSH ubuntu@${PUBLIC_DNS_INSTANCE}"

# SSH into instance
echo-with-date "Trying SSH connection..."
$SSH 'exit' > /dev/null 2>&1
ERROR_CODE=$(echo $?)
MESSAGE_OK="SSH connection to instance has succeeded"
MESSAGE_ERROR="SSH connection to instance failed"
check-action "True"

 Use apt-get, etc. to update operating system
echo-with-date "Updating APT sources..."
$SSH "sudo apt update" > /dev/null 2>&1
ERROR_CODE=$(echo $?)
MESSAGE_OK="APT update has succeeded"
MESSAGE_ERROR="APT update has failed"
check-action "True"

# Use apt-get, etc. to update operating system
echo-with-date "Upgrading APT packages..."
$SSH "sudo apt upgrade --yes" > /dev/null 2>&1
ERROR_CODE=$(echo $?)
MESSAGE_OK="APT upgrade has succeeded"
MESSAGE_ERROR="APT upgrade has failed"
check-action "True"

# ToDo copy .run.conf to instance, remove kobo-env pull from kobo-ec2 scripts

# Update kobo-docker, kobo-install with kobo-ec2 existing scripts
echo-with-date "Updating KoBoToolbox on AMI..."
$SSH "/bin/bash $KOBO_EC2_DIR/start_env.bash rundeck"
ERROR_CODE=$(echo $?)
MESSAGE_OK="KoBoToolbox update has succeeded"
MESSAGE_ERROR="KoBoToolbox update has failed"
check-action "True"

# Wait for 2 minutes maximum KoBoToolbox to be up and running
CPT=1
MAX_TRIES=12
echo-with-date "Waiting for KoboToolbox to be up and running..."
while $SSH "/bin/bash ${KOBO_EC2_DIR}/crons/frontend/containers_monitor.bash" | grep 'nothing to do' > /dev/null 2>&1; do
    if [ "${CPT}" -gt "${MAX_TRIES}" ]; then
      echo-with-date "ERROR: Something went wrong, KoBoToolbox did not start"
      terminate-tmp-instances
      exit 1
    fi
    sleep 10
    CPT=$(( $CPT + 1 ))
done

echo-with-date "Docker containers are up and running..."

#AWS
NEWEST_AMI_ID=$($AWS ec2 create-image \
    --region ${EC2_REGION} \
    --instance-id ${INSTANCE_ID}  \
    --name "kobo.${ENV}.frontend.ami.$DATE" \
    --description "Front-end AMI for ${ENV}" \
    --output text)

# Wait AMI creation
while [ "$($AWS ec2 describe-images --region ${EC2_REGION} --image-ids ${NEWEST_AMI_ID} --query Images[].State --output text)" = "pending" ]; do
    echo-with-date "AMI (${NEWEST_AMI_ID}) creation is in progress..."
    sleep 30
done

TEST_CREATE_IMAGE=$($AWS ec2 describe-images \
--region ${EC2_REGION} \
--image-ids ${NEWEST_AMI_ID} \
--query Images[].Name \
--output text)

ERROR_CODE=$(echo $?)
MESSAGE_OK="AMI creation has succeeded"
MESSAGE_ERROR="AMI creation has failed"
check-action "${TEST_CREATE_IMAGE}"

# Change tag AMI
echo-with-date "Moving latest version tag to newest AMI..."
$AWS ec2 create-tags \
    --region ${EC2_REGION} \
    --resources ${NEWEST_AMI_ID} \
    --tags "Key=version,Value=${LATEST_VERSION_TAG}" "Key=billing,Value=${ENV}"

$AWS ec2 delete-tags \
  --region ${EC2_REGION} \
  --resources ${OLD_AMI_ID} \
  --tags "Key=version,Value=${LATEST_VERSION_TAG}"
ERROR_CODE=$(echo $?)
MESSAGE_OK="Tag \`version=${LATEST_VERSION_TAG}\` has been removed from old AMI successfully"
MESSAGE_ERROR="Tag \`version=${LATEST_VERSION_TAG}\` has not be moved"
check-action "True"

# Test - Change tag AMI
TEST_UPDATE_AMI_TAG=$($AWS ec2 describe-images \
    --region ${EC2_REGION} \
    --image-ids ${NEWEST_AMI_ID} \
    --query 'Images[].Tags[?Key==`version`]|[].Value' \
    --output text)
ERROR_CODE=$(echo $?)
MESSAGE_OK="Tag \`version=${LATEST_VERSION_TAG}\` has been moved successfully"
MESSAGE_ERROR="Tag \`version=${LATEST_VERSION_TAG}\` has not be moved"
check-action "${TEST_UPDATE_AMI_TAG}"

terminate-tmp-instances

# ToDo Clean up old AMI
