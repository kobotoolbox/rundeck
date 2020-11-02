#!/bin/bash

DATE=$(date +"%Y%m%d")
DATE_ECHO=$(date +"%Y-%m-%d %r")
ENV=@option.Environment@
LAUNCH_CONFIGURATION_NAME=""
KOBO_INSTALL_DIR="/home/ubuntu/kobo-install"

echo DATE : $DATE
echo DATE_ECHO : $DATE_ECHO
echo ENV : $ENV
echo LAUNCH_CONFIGURATION_NAME : $LAUNCH_CONFIGURATION_NAME

function check-retry-pull {
    cd ${KOBO_INSTALL_DIR}
    # Pull new images
    COMPOSE_HTTP_TIMEOUT=200 python3 run.py ${1} pull > .log-pull 2>&1

    # Check if pull failed
    if [[ ! -z $(grep "error" .log-pull) ]]; then
        echo "[ $(date) ] Failed update ${2} containers..."
        
    fi
}

# Choice of environment 
case $ENV in
    OCHA)
        echo "Environment : ${ENV}"
        AUTO_SCALING_GROUP_NAME=""
        echo "AUTO_SCALING_GROUP_NAME : ${AUTO_SCALING_GROUP_NAME}"
        EC2_REGION=""
        echo "EC2_REGION : ${EC2_REGION}"
        RSA_KEY=""
        echo "RSA KEY : ${RSA_KEY}"
        ;;
    HHI)
        echo "Environment : ${ENV}"
        AUTO_SCALING_GROUP_NAME=""
        echo "AUTO_SCALING_GROUP_NAME ${AUTO_SCALING_GROUP_NAME}"
        EC2_REGION=""
        echo "EC2_REGION : ${EC2_REGION}"
        RSA_KEY=""
        echo "RSA KEY : ${RSA_KEY}"
        ;;
    *)
esac

# Update our AMIs each time code is deployed

# Last AMI list
aws ec2 describe-images \
    --region ${EC2_REGION} \
    --filters "Name=tag:version,Values=latest" \
    --output table

# Find ID AMI - output : ami-039ef8fda247219c5
ID_AMI=$(aws ec2 describe-images \
    --region ${EC2_REGION} \
    --filters 'Name=tag:version,Values=latest' \
    --query 'Images[].ImageId'
    --output text)

# Tell AWS to create new EC2 instance using current AMI


# Status 
aws ec2 describe-instances \
    --filters Name=tag-key,Values=AMI \
    --query 'Reservations[*].Instances[*].{Instance:InstanceId,AZ:Placement.AvailabilityZone,Status:Tags[?Key==`AMI`]|[0].Value}' \
    --output table

# Get ID of new instance 
ID_INSTANCE=$(aws ec2 describe-instances \
    --filters Name=tag-key,Values=AMI \
    --query 'Reservations[*].Instances[*].{Instance:InstanceId,AZ:Placement.AvailabilityZone,Status:Tags[?Key==`AMI`]|[0].Value}' \
    --output text)

if [[ ! -n "$ID_INSTANCE" ]]; then
    echo "[ ${DATE_ECHO}] Error - ID Instance empty"
fi

# Get public IP of new instance
PUBLIC_DNS_INSTANCE=$(aws ec2 describe-instances \
    --filters Name=tag-key,Values=AMI \
    --query 'Reservations[].Instances[].PublicDnsName' \ 
    --output text)

if [[ ! -n "$PUBLIC_DNS_INSTANCE" ]]; then
    echo "[ ${DATE_ECHO}] Error - Public dns Instance empty"
fi

# SSH into instance
ssh -i hhi ubuntu@${PUBLIC_DNS_INSTANCE} 'exit' > /dev/null 2>&1 

if [[ $(echo $?) == 0 ]]; then
    echo "[ ${DATE_ECHO}] Connection SSH Ok"
else
    echo "[ ${DATE_ECHO}] Error - Connection SSH"
fi

# Use apt-get, etc. to update operating system
ssh -i hhi ubuntu@${PUBLIC_DNS_INSTANCE} "apt update && apt upgrade --yes" > /dev/null 2>&1

if [[ $(echo $?) == 0 ]]; then
    echo "[ ${DATE_ECHO}] APT Upgrade Ok"
else
    echo "[ ${DATE_ECHO}] Error - APT Upgrade"
fi

# Wait a little bit to be sure docker is ready to start
echo "Waiting for Docker to be up..."
ssh -i hhi ubuntu@${PUBLIC_DNS_INSTANCE} "while (sudo systemctl is-active docker | grep 'inactive' > /dev/null 2>&1); do; sleep 1; done;" > /dev/null 2>&1
echo "Docker is ready!"

# Update kobo-install and kobo-docker (./run.py --auto-update <kobo-install-tag|stable>)
ssh -i hhi ubuntu@${PUBLIC_DNS_INSTANCE} "cd ${KOBO_INSTALL_DIR} && python3 run.py --auto-update ${KOBO_INSTALL_VERSION}"

if [[ $(echo $?) == 0 ]]; then
    echo "[ ${DATE_ECHO}] Update kobo-install Ok"
else
    echo "[ ${DATE_ECHO}] Error - Update kobo-install"
fi

# Pull new Docker images
ssh -i hhi ubuntu@${PUBLIC_DNS_INSTANCE} "check-retry-pull -cf frontend"
echo "[ $(date) ] Updating frontend containers..."

if [[ $(echo $?) == 0 ]]; then
    echo "[ ${DATE_ECHO}] Update frontend containers Ok"
else
    echo "[ ${DATE_ECHO}] Error - Update frontend containers"
fi

# Start Enketo so that it builds its static files

# Tell AWS to create a new AMI from this instance
CREATE_IMAGE=$(aws ec2 create-image \
    --instance-id ${ID_INSTANCE}  \
    --name "" \
    --description "Frontend AMI for ${ENV}" \
    --output text)

TEST_CREATE_IMAGE=$(aws ec2 describe-images \
    --image-ids ${CREATE_IMAGE})

if [[ -n "TEST_CREATE_IMAGE" ]]; then
    echo "[ ${DATE_ECHO}] Create AMI : "
else
    echo "[ ${DATE_ECHO}] Error - Create AMI : "
fi

if [LE DOCKER EST OK VIA HTTP OU DOCKER]; then 

    # Copy the current ASG Launch Configuration, then modify it to use the new AMI


    TEST_LAUNCH_CONF=$(aws autoscaling describe-launch-configurations \
        --launch-configuration-names ${LAUNCH_CONFIGURATION_NAME} \
        --query 'LaunchConfigurations[].LaunchConfigurationName' \
        --output text)

    if [[ -n "$TEST_LAUNCH_CONF" ]]; then
        echo "[ ${DATE_ECHO}] Create ASG launch configuration : ${LAUNCH_CONFIGURATION_NAME}"
    else 
        echo "[ ${DATE_ECHO}] Error - Create ASG launch configuration : ${LAUNCH_CONFIGURATION_NAME}"
    fi

    # Tell ASG to use new Launch Configuration
    aws autoscaling update-auto-scaling-group \
        --auto-scaling-group-name ${AUTO_SCALING_GROUP_NAME} \
        --launch-configuration-name ${LAUNCH_CONFIGURATION_NAME}

    TEST_UPDATE_AUTO_SCALING=$(aws autoscaling describe-auto-scaling-groups \
        --auto-scaling-group-name ${AUTO_SCALING_GROUP_NAME} \
        --query 'AutoScalingGroups[].LaunchConfigurationName[]'\
        --output text)

    if [[ "${TEST_UPDATE_AUTO_SCALING}" == "${LAUNCH_CONFIGURATION_NAME}" ]]; then
        echo "[ ${DATE_ECHO}] Apply new ASG launch configuration : ${LAUNCH_CONFIGURATION_NAME}"
    else 
        echo "[ ${DATE_ECHO}] Error - Apply new ASG launch configuration : ${LAUNCH_CONFIGURATION_NAME}"
    fi

    # Delete the old ASG Launch Configuration
    aws autoscaling delete-launch-configuration --launch-configuration-name my-launch-config
    # Keep the previous AMI but delete any older AMIs
    # Don’t delete the previous one so that we can roll back if the new AMI doesn’t work (e.g. bad application code)

    # Change tag AMI
    aws ec2 create-tags \
        --resources ${CREATE_IMAGE} \
        --tags Key=version,Value=latest

    TEST_UPDATE_AMI_TAG=$(aws ec2 describe-images \
        --image-ids ${CREATE_IMAGE} \
        --query 'Images[].Tags[?Key==`version`]|[].Value' \
        --output text)

    if [[ "${TEST_UPDATE_AMI_TAG}" == "latest" ]]; then
        echo "[ ${DATE_ECHO}] Apply tag : ${TEST_UPDATE_AMI_TAG} on AMI"
    else 
        echo "[ ${DATE_ECHO}] Error - Apply tag : ${TEST_UPDATE_AMI_TAG} on AMI"
    fi
fi

# Delete EC2 instance 
aws ec2 terminate-instances --instance-ids ${ID_INSTANCE}

# Delete old AMI
