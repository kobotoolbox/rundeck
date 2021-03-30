#!/bin/bash

# Variables
AWS="/usr/local/bin/aws"
ENV=@option.ENVIRONMENT@
DEPLOY_ALL_AT_ONCE=@option.DEPLOY_ALL_AT_ONCE@
KOBO_INSTALL_DIR="/home/ubuntu/kobo-install"
KOBO_EC2_DIR="/home/ubuntu/kobo-ec2"
KOBO_INSTALL_VERSION=@option.KOBO_INSTALL_VERSION@
KOBO_EC2_VERSION=@option.KOBO_EC2_VERSION@
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

function deploy {
    INSTANCE_ID="$1"
    INSTANCE_NAME="$2"
    INSTANCE_DNS="$3"

    # Update KOBO_VERSION_INSTALL tag

    echo-with-date "##############################################################"
    echo-with-date "Deploying \`${KOBO_INSTALL_VERSION}\` to \`${INSTANCE_NAME}\`..."
    echo-with-date "##############################################################"

    echo-with-date "Tagging instance \`${INSTANCE_NAME}\` with new kobo-install version..."
    $AWS ec2 create-tags \
        --region ${EC2_REGION} \
        --resources ${INSTANCE_ID} \
        --tags "Key=kobo-install-version,Value=${KOBO_INSTALL_VERSION}" "Key=kobo-ec2-version,Value=${KOBO_EC2_VERSION}"

    KOBO_INSTALL_VERSION_TAG=$($AWS ec2 describe-tags \
        --region ${EC2_REGION} \
        --filters "Name=resource-id,Values=${INSTANCE_ID}" "Name=key,Values=kobo-install-version" \
        --query Tags[].Value \
        --output text)
    ERROR_CODE=$(echo $?)
    MESSAGE_OK="Tag \`kobo-install-version\` update has succeeded"
    MESSAGE_ERROR="Tag \`kobo-install-version\` update has failed"
    VALUE=$([[ "$KOBO_INSTALL_VERSION_TAG" == "$KOBO_INSTALL_VERSION" ]] && echo 1 || echo 0)
    check-action "${VALUE}"

    # ToDo copy .run.conf to instance, remove kobo-env pull from kobo-ec2 scripts
    SSH="ssh -o StrictHostKeyChecking=no -i $KEY_SSH ubuntu@${INSTANCE_DNS}"
    # Update kobo-docker, kobo-install with kobo-ec2 existing scripts
    echo-with-date "Updating KoBoToolbox on \`${INSTANCE_NAME}\`..."
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

    echo-with-date "KoBoToolbox is up and running on \`${INSTANCE_NAME}\`"
    echo-with-date "SUCCESS: Deployment has been completed successfully"
}

function echo-with-date {
    MESSAGE="$1"
    echo "[ $(date) ] ${MESSAGE}"
}

echo-with-date "Environment variables"
echo "    DATE: ${DATE}"
echo "    ENV: ${ENV}"
echo "    DEPLOY_ALL_AT_ONCE: ${DEPLOY_ALL_AT_ONCE}"
echo "    KOBO_INSTALL_VERSION: ${KOBO_INSTALL_VERSION}"
source /var/lib/rundeck/kobo/${ENV}.env
echo "    AUTO_SCALING_GROUP_NAME: ${AUTO_SCALING_GROUP_NAME}"
echo "    EC2_REGION: ${EC2_REGION}"
echo "    KEY_PAIR_NAME: ${KEY_PAIR_NAME}"
echo "    KEY_SSH: ${KEY_SSH}"
echo "    PRIMARY_FRONTEND_ID: ${PRIMARY_FRONTEND_ID}"

# Tests Variables
if [[ ! -n "$ENV" || ! -n "$AUTO_SCALING_GROUP_NAME" || ! -n "$KOBO_INSTALL_VERSION" || ! -n "$EC2_REGION" || ! -n "$KEY_PAIR_NAME" || ! -n "$IAM_ROLE" ]]; then
    echo-with-date "Arguments missing"
    exit 1
fi

# Get public IP of new instance
PRIMARY_FRONTEND_DNS=$($AWS ec2 describe-instances \
    --region ${EC2_REGION} \
    --instance-ids ${PRIMARY_FRONTEND_ID} \
    --query "Reservations[*].Instances[*].[PublicDnsName]" \
    --output text | tail -n1)
ERROR_CODE=$(echo $?)
MESSAGE_OK="Found public DNS of primary front-end instance: ${PRIMARY_FRONTEND_DNS}"
MESSAGE_ERROR="Could not get public DNS of primary front-end instance"
check-action "${PRIMARY_FRONTEND_DNS}"

ASG_MIN_CAPACITY=""
ASG_MAX_CAPACITY=""
ASG_DESIRED_CAPACITY=""

if [ -n "${AUTO_SCALING_GROUP_NAME}" ] && [ "${DEPLOY_ALL_AT_ONCE}" != "true" ]; then
    # Decrease ASG capacity
    echo-with-date "Retrieving ASG current capacity..."
    ASG_CAPACITY=$($AWS autoscaling describe-auto-scaling-groups \
        --region ${EC2_REGION} \
        --auto-scaling-group-names ${AUTO_SCALING_GROUP_NAME} \
        --query "AutoScalingGroups[].[MinSize, MaxSize, DesiredCapacity]" \
        --output text)
    ASG_MIN_CAPACITY=$(echo "${ASG_CAPACITY}"|cut -f 1)
    ASG_MAX_CAPACITY=$(echo "${ASG_CAPACITY}"|cut -f 2)
    ASG_DESIRED_CAPACITY=$(echo "${ASG_CAPACITY}"|cut -f 3)
    ERROR_CODE=$(echo $?)
    MESSAGE_OK="ASG capacity is: min-size=${ASG_MIN_CAPACITY}, max-size=${ASG_MAX_CAPACITY}, desired-capacity=${ASG_DESIRED_CAPACITY}"
    MESSAGE_ERROR="Could not get ASG capacity"
    check-action "${ASG_CAPACITY}"

    echo-with-date "Decreasing ASG capacity..."
    $AWS autoscaling update-auto-scaling-group \
        --region ${EC2_REGION} \
        --auto-scaling-group-name ${AUTO_SCALING_GROUP_NAME} \
        --min-size 0 --max-size 0 --desired-capacity 0

    ASG_CAPACITY=$($AWS autoscaling describe-auto-scaling-groups \
        --region ${EC2_REGION} \
        --auto-scaling-group-names ${AUTO_SCALING_GROUP_NAME} \
        --query "AutoScalingGroups[].[MinSize, MaxSize, DesiredCapacity]" \
        --output text| tr -d "\t")
    ERROR_CODE=$(echo $?)
    MESSAGE_OK="ASG capacity has been decreased successfully"
    MESSAGE_ERROR="ASG capacity could not be decreased"
    VALUE=$([[ "$ASG_CAPACITY" == "000" ]] && echo 1 || echo 0)
    check-action "${VALUE}"
fi

deploy "${PRIMARY_FRONTEND_ID}" "primary front-end" "${PRIMARY_FRONTEND_DNS}"

if [ -n "${AUTO_SCALING_GROUP_NAME}" ]; then
    echo-with-date "Updating tags on auto scaling group..."
    $AWS autoscaling create-or-update-tags \
        --region "${EC2_REGION}" \
        --tags "ResourceId=${AUTO_SCALING_GROUP_NAME},ResourceType=auto-scaling-group,Key=kobo-install-version,Value=${KOBO_INSTALL_VERSION},PropagateAtLaunch=true" \
               "ResourceId=${AUTO_SCALING_GROUP_NAME},ResourceType=auto-scaling-group,Key=kobo-ec2-version,Value=${KOBO_EC2_VERSION},PropagateAtLaunch=true"
    TAG_ERROR_CODE=$(echo $?)

    KOBO_INSTALL_VERSION_TAG=$($AWS autoscaling describe-auto-scaling-groups \
      --auto-scaling-group-names "${AUTO_SCALING_GROUP_NAME}" \
      --query "AutoScalingGroups[].Tags[?Key==\`kobo-install-version\`]|[].Value" \
      --output text)
    DESCRIBE_TAG_ERROR_CODE=$(echo $?)
    ERROR_CODE=$([[ "$TAG_ERROR_CODE" == "0" ]] && [[ "$DESCRIBE_TAG_ERROR_CODE" == "0" ]] && echo 0 || echo 1)
    MESSAGE_OK="Tags have been successfully updated"
    MESSAGE_ERROR="Tags update has failed"
    VALUE=$([[ "$KOBO_INSTALL_VERSION_TAG" == "${KOBO_INSTALL_VERSION}" ]] && echo 1 || echo 0)
    check-action "${VALUE}"
fi

if [ -n "${AUTO_SCALING_GROUP_NAME}" ] && [ "${DEPLOY_ALL_AT_ONCE}" == "true" ]; then
    ASG_FRONTENDS=$($AWS ec2 describe-instances \
        --region ${EC2_REGION} \
        --filters "Name=tag:Name,Values=${ENV}-asg-frontends" "Name=instance-state-name,Values=running" \
        --query "Reservations[].Instances[].[InstanceId, PublicDnsName]" \
        --output text)

    echo "${ASG_FRONTENDS}" | while read ASG_FRONTEND; do
        ASG_INSTANCE_ID=$(echo "${ASG_FRONTEND}"|cut -f 1)
        ASG_INSTANCE_DNS=$(echo "${ASG_FRONTEND}"|cut -f 2)
        deploy "${ASG_INSTANCE_ID}" "${ASG_INSTANCE_ID}" "${ASG_INSTANCE_DNS}"
    done
fi

if [ -n "${AUTO_SCALING_GROUP_NAME}" ] && [ "${DEPLOY_ALL_AT_ONCE}" != "true" ]; then
    echo-with-date "Increasing ASG capacity back to previous values..."
    $AWS autoscaling update-auto-scaling-group \
        --region ${EC2_REGION} \
        --auto-scaling-group-name ${AUTO_SCALING_GROUP_NAME} \
        --min-size ${ASG_MIN_CAPACITY} --max-size ${ASG_MAX_CAPACITY} --desired-capacity ${ASG_DESIRED_CAPACITY}

    ASG_CAPACITY=$($AWS autoscaling describe-auto-scaling-groups \
        --region ${EC2_REGION} \
        --auto-scaling-group-names ${AUTO_SCALING_GROUP_NAME} \
        --query "AutoScalingGroups[].[MinSize, MaxSize, DesiredCapacity]" \
        --output text| tr -d "\t")
    ERROR_CODE=$(echo $?)
    MESSAGE_OK="ASG capacity has been increased successfully"
    MESSAGE_ERROR="ASG capacity could not be increased"
    VALUE=$([[ "$ASG_CAPACITY" == "${ASG_MIN_CAPACITY}${ASG_MAX_CAPACITY}${ASG_DESIRED_CAPACITY}" ]] && echo 1 || echo 0)
    check-action "${VALUE}"
fi
