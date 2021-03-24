#!/bin/bash

# Variables
AWS="/usr/local/bin/aws"
DATE=$(date +"%Y%m%d.%H%M%S")
ENV=@option.ENVIRONMENT@
DEPLOYMENT_TYPE=@option.DEPLOYMENT_TYPE@
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
          exit 1
        fi
    else
        echo-with-date "ERROR: ${MESSAGE_ERROR}"
        exit 1
    fi
}

function echo-with-date {
    MESSAGE="$1"
    echo "[ $(date) ] ${MESSAGE}"
}

echo-with-date "Environment variables"
echo "        DATE: ${DATE}"
echo "        ENV: ${ENV}"
echo "        DEPLOYMENT_TYPE: ${DEPLOYMENT_TYPE}"
echo "        KOBO_INSTALL_VERSION: ${KOBO_INSTALL_VERSION}"
echo "        LAUNCH_CONFIGURATION_NAME: ${LAUNCH_CONFIGURATION_NAME}"
source /var/lib/rundeck/kobo/${ENV}.env
echo "        AUTO_SCALING_GROUP_NAME: ${AUTO_SCALING_GROUP_NAME}"
echo "        EC2_REGION: ${EC2_REGION}"
echo "        INSTANCE_TYPE: ${INSTANCE_TYPE}"
echo "        KEY_PAIR_NAME: ${KEY_PAIR_NAME}"
echo "        SECURITY_GROUP_NGINX: ${SECURITY_GROUP_NGINX}"
echo "        SECURITY_GROUP_SSH: ${SECURITY_GROUP_SSH}"
echo "        IAM_ROLE: ${IAM_ROLE}"
echo "        KEY_SSH: ${KEY_SSH}"


# Tests Variables
if [[ ! -n "$ENV" || ! -n "$AUTO_SCALING_GROUP_NAME" || ! -n "$KOBO_INSTALL_VERSION" || ! -n "$EC2_REGION" || ! -n "$INSTANCE_TYPE" || ! -n "$KEY_PAIR_NAME" || ! -n "$SECURITY_GROUP_NGINX" || ! -n "$SECURITY_GROUP_SSH" || ! -n "$IAM_ROLE" ]]; then
    echo-with-date "Arguments missing"
    exit 1
fi

# Find latest AMI id - output : ami-039ef8fda247219c5
echo-with-date "Retrieving current latest AMI id..."
LATEST_AMI_ID=$($AWS ec2 describe-images \
    --region ${EC2_REGION} \
    --filters "Name=tag:version,Values=${LATEST_VERSION_TAG}" \
    --query "Images[].ImageId" \
    --output text)
ERROR_CODE=$(echo $?)
MESSAGE_OK="Found current latest AMI: ${LATEST_AMI_ID}"
MESSAGE_ERROR="Could not retrieve current latest AMI"
check-action "${LATEST_AMI_ID}"

# Copy the current ASG Launch Configuration, then modify it to use the new AMI
CREATE_LAUNCH_CONFIGURATION=$($AWS autoscaling create-launch-configuration \
    --launch-configuration-name ${LAUNCH_CONFIGURATION_NAME} \
    --image-id ${LATEST_AMI_ID} \
    --iam-instance-profile ${IAM_ROLE} \
    --key-name "${KEY_PAIR_NAME}" \
    --security-groups "${SECURITY_GROUP_NGINX}" "${SECURITY_GROUP_SSH}" \
    --instance-type ${INSTANCE_TYPE} \
    --region ${EC2_REGION} \
    --instance-monitoring Enabled=true \
    --ebs-optimized \
    --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=60,VolumeType=gp2,DeleteOnTermination=true,Encrypted=false}')

TEST_LAUNCH_CONFIGURATION=$($AWS autoscaling describe-launch-configurations \
    --region ${EC2_REGION} \
    --launch-configuration-name ${LAUNCH_CONFIGURATION_NAME} \
    --query 'LaunchConfigurations[].LaunchConfigurationName[]' \
    --output text)

ERROR_CODE=$(echo $?)
MESSAGE_OK="ASG launch configuration creation has succeeded"
MESSAGE_ERROR="ASG launch configuration creation has failed"
VALUE=$([[ "$TEST_LAUNCH_CONFIGURATION" == "$CREATE_LAUNCH_CONFIGURATION" ]] && echo 1 || echo 0)
check-action "${VALUE}"

# Tell ASG to use new Launch Configuration
$AWS autoscaling update-auto-scaling-group \
    --region ${EC2_REGION} \
    --auto-scaling-group-name ${AUTO_SCALING_GROUP_NAME} \
    --launch-configuration-name ${LAUNCH_CONFIGURATION_NAME}

TEST_UPDATE_ASG=$($AWS autoscaling describe-auto-scaling-groups \
    --region ${EC2_REGION} \
    --auto-scaling-group-name ${AUTO_SCALING_GROUP_NAME} \
    --query 'AutoScalingGroups[].LaunchConfigurationName[]'\
    --output text)

ERROR_CODE=$(echo $?)
MESSAGE_OK="Auto Scale Group update has succeeded"
MESSAGE_ERROR="Auto Scale Group update has failed"
VALUE=$([[ "$TEST_UPDATE_ASG" == "$CREATE_LAUNCH_CONFIGURATION" ]] && echo 1 || echo 0)
check-action "${VALUE}"

# ToDo clean up old launch configurations
