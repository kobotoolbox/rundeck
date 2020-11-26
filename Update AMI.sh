#!/bin/bash

# Variables
AWS="/usr/local/bin/aws"
DATE=$(date +"%Y%m%d")
DATE_ECHO=$(date +"%Y-%m-%d %r")
ENV=@option.Environment@
VERSION=@option.Version@
LAUNCH_CONFIGURATION_NAME="m5-reserved-instances-launch-config-${DATE}"
AMI_UBUNTU="ami-0885b1f6bd170450c"


echo DATE : $DATE
echo DATE_ECHO : $DATE_ECHO
echo ENV : $ENV
echo VERSION : $VERSION
echo LAUNCH_CONFIGURATION_NAME : $LAUNCH_CONFIGURATION_NAME
echo AMI_UBUNTU : $AMI_UBUNTU

function check-retry-pull {
    cd ${KOBO_INSTALL_DIR}
    # Pull new images
    COMPOSE_HTTP_TIMEOUT=200 python3 run.py ${1} pull > .log-pull 2>&1

    # Check if pull failed
    if [[ ! -z $(grep "error" .log-pull) ]]; then
        echo "[ $(date) ] Failed update ${2} containers..."
    fi
}

function check-action {
    if [[ $(echo $?) == 0 ]]; then
        echo "[ ${DATE_ECHO} ] ${1}"
    else
        echo "[ ${DATE_ECHO} ] ${2}"
        exit
    fi
}

case $ENV in
    ocha)
        source /home/ubuntu/${ENV}-config
        echo "Environment : ${ENV}"
        echo "AUTO_SCALING_GROUP_NAME : ${AUTO_SCALING_GROUP_NAME}"
        echo "EC2_REGION : ${EC2_REGION}"
        echo "INSTANCE_TYPE : ${INSTANCE_TYPE}"
        echo "SUBNET_ID : ${SUBNET_ID}"
        echo "KEY_PAIR_NAME : ${KEY_PAIR_NAME}"
        echo "SECURITY_GROUP_NGINX : ${SECURITY_GROUP_NGINX}"
        echo "SECURITY_GROUP_SSH : ${SECURITY_GROUP_SSH}"
        echo "SECURITY_GROUP_SSH : ${SECURITY_GROUP_RUNDECK_SSH}"
        echo "IAM_ROLE : ${IAM_ROLE}"
        echo "IAM_ROLE : ${KOBO_EC2_MONITORED_DOMAIN}"
        ;;
    hhi)
        source /home/ubuntu/${ENV}-config
        echo "Environment : ${ENV}"
        echo "AUTO_SCALING_GROUP_NAME ${AUTO_SCALING_GROUP_NAME}"
        echo "EC2_REGION : ${EC2_REGION}"
        echo "INSTANCE_TYPE : ${INSTANCE_TYPE}"
        echo "SUBNET_ID : ${SUBNET_ID}"
        echo "KEY_PAIR_NAME : ${KEY_PAIR_NAME}"
        echo "SECURITY_GROUP_NGINX : ${SECURITY_GROUP_NGINX}"
        echo "SECURITY_GROUP_SSH : ${SECURITY_GROUP_SSH}"
        echo "SECURITY_GROUP_SSH : ${SECURITY_GROUP_RUNDECK_SSH}"
        echo "IAM_ROLE : ${IAM_ROLE}"
        echo "IAM_ROLE : ${KOBO_EC2_MONITORED_DOMAIN}"
        ;;
    *)
esac

# Tests Variables
if [[ ! -n "$ENV" || ! -n "$AUTO_SCALING_GROUP_NAME" || ! -n "$VERSION" || ! -n "$EC2_REGION" || ! -n "$INSTANCE_TYPE" || ! -n "$SUBNET_ID" || ! -n "$KEY_PAIR_NAME" || ! -n "$SECURITY_GROUP_NGINX" || ! -n "$SECURITY_GROUP_SSH" || ! -n "$SECURITY_GROUP_RUNDECK_SSH" || ! -n "$IAM_ROLE" || ! -n "$KOBO_EC2_MONITORED_DOMAIN" ]]; then
    echo "[ $DATE_ECHO ] Arguments missing"
    exit 0
fi 

# Last AMI list
$AWS ec2 describe-images \
    --region ${EC2_REGION} \
    --filters "Name=tag:version,Values=latest" \
    --output table
    
# Find ID AMI - output : ami-039ef8fda247219c5
OLD_ID_AMI=$($AWS ec2 describe-images \
    --region ${EC2_REGION} \
    --filters 'Name=tag:version,Values=latest' \
    --query 'Images[].ImageId' \
    --output text)
echo "[ $DATE_ECHO ] Old ID_AMI : $OLD_ID_AMI"

# Tell AWS to create new EC2 instance using current AMI
LAUNCH_INSTANCE=$($AWS ec2 run-instances \
        --image-id ${AMI_UBUNTU} \
        --instance-type ${INSTANCE_TYPE} \
        --region ${EC2_REGION} \
        --count 1 \
        --subnet-id "${SUBNET_ID}" \
        --key-name "${KEY_PAIR_NAME}" \
        --security-group-ids "${SECURITY_GROUP_NGINX}" "${SECURITY_GROUP_SSH}" "${SECURITY_GROUP_RUNDECK_SSH}" \
        --monitoring Enabled=true \
        --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=60}' \
        --ebs-optimized \
        --iam-instance-profile Name="${IAM_ROLE}" \
        --tag-specifications 'ResourceType=instance,Tags=[{Key=AMI,Value=creating},{Key=kobo-ec2-environment-type,Value=frontend},{Key=kobo-ec2-version,Value=master},{Key=kobo-ec2-monitored-domain,Value='${KOBO_EC2_MONITORED_DOMAIN}'},{Key=kobo-env-branch,Value='${ENV}'},{Key=kobo-ec2-use-swap,Value=1},{Key=kobo-install-version,Value='${VERSION}'},{Key=Name,Value='${ENV}'-asg-frontends}]')
echo "[ ${DATE_ECHO} ] EC2 instance is in creation..."
sleep 60

# Status 
$AWS ec2 describe-instances \
    --region ${EC2_REGION} \
    --filters Name=tag-key,Values=AMI \
    --query 'Reservations[*].Instances[*].{Instance:InstanceId,AZ:Placement.AvailabilityZone,Status:Tags[?Key==`AMI`]|[0].Value}' \
    --output table

# Get ID of new instance 
ID_INSTANCE=$($AWS ec2 describe-instances \
    --region ${EC2_REGION} \
    --filters "Name=tag-key,Values=AMI" "Name=instance-state-name,Values=running" \
    --query 'Reservations[*].Instances[*].InstanceId' \
    --output text | tail -n1 )

RESULT_OK="New ID_INSTANCE : $ID_INSTANCE"
RESULT_NOK="Error - ID Instance empty"
check-action "${RESULT_OK}" "${RESULT_NOK}"

# Get public IP of new instance
PUBLIC_DNS_INSTANCE=$($AWS ec2 describe-instances \
    --region ${EC2_REGION} \
    --filters Name=tag-key,Values=AMI \
    --query 'Reservations[*].Instances[*].PublicDnsName' \
    --output text | tail -n1)

if [[ -n "$PUBLIC_DNS_INSTANCE" ]]; then
    echo "[ ${DATE_ECHO} ] New PUBLIC_DNS_INSTANCE : $PUBLIC_DNS_INSTANCE"
    SSH="ssh -o StrictHostKeyChecking=no -i /var/lib/rundeck/.ssh/hhiprod.pem ubuntu@${PUBLIC_DNS_INSTANCE}"
else
    echo "[ ${DATE_ECHO} ] Error - Public dns Instance empty"
    exit    
fi

# SSH into instance
$SSH 'exit' > /dev/null 2>&1 

RESULT_OK="Connection SSH Ok"
RESULT_NOK="Error - Connection SSH"
check-action "${RESULT_OK}" "${RESULT_NOK}"

# Use apt-get, etc. to update operating system 
$SSH "sudo apt update" > /dev/null 2>&1

RESULT_OK="APT update Ok"
RESULT_NOK="Error - APT update"
check-action "${RESULT_OK}" "${RESULT_NOK}"

sleep 30

# Use apt-get, etc. to update operating system 
$SSH "sudo apt upgrade --yes" > /dev/null 2>&1

RESULT_OK="APT upgrade Ok"
RESULT_NOK="Error - APT upgrade"
check-action "${RESULT_OK}" "${RESULT_NOK}"

sleep 90

# Install Docker 
$SSH "sudo apt install docker.io docker-compose --yes" > /dev/null 2>&1

RESULT_OK="APT install Docker Ok"
RESULT_NOK="Error - APT install Docker"
check-action "${RESULT_OK}" "${RESULT_NOK}"

sleep 30

# Config Docker 
$SSH "sudo usermod -aG docker ubuntu" > /dev/null 2>&1

RESULT_OK="Config Docker Ok"
RESULT_NOK="Error - Config Docker"
check-action "${RESULT_OK}" "${RESULT_NOK}"

# Github clone 
$SSH "git clone --branch stable https://github.com/kobotoolbox/kobo-install.git" > /dev/null 2>&1

RESULT_OK="Clone Github kobo-install Ok"
RESULT_NOK="Error - Clone Github kobo-install"
check-action "${RESULT_OK}" "${RESULT_NOK}"

sleep 15

$SSH "git clone https://github.com/kobotoolbox/kobo-docker.git" > /dev/null 2>&1

RESULT_OK="Clone Github kobo-docker Ok"
RESULT_NOK="Error - Clone Github kobo-docker"
check-action "${RESULT_OK}" "${RESULT_NOK}"

sleep 15

# Copy file
rsync -ap --progress -e "ssh -o StrictHostKeyChecking=no -i /var/lib/rundeck/.ssh/${ENV}prod.pem" /var/lib/rundeck/.${ENV}-run.conf ubuntu@${PUBLIC_DNS_INSTANCE}:/home/ubuntu/kobo-install/.run.conf > /dev/null 2>&1

RESULT_OK="Copy file run.conf OK"
RESULT_NOK="Error - Copy file run.conf"
check-action "${RESULT_OK}" "${RESULT_NOK}"

sleep 10

# Install Kobo before update


# Update kobo-install and kobo-docker (./run.py --auto-update <kobo-install-tag|stable>)
$SSH "python3 ${KOBO_INSTALL_DIR}run.py --auto-update ${KOBO_INSTALL_VERSION}"

RESULT_OK="Update Kobo Ok"
RESULT_NOK="Error - Update Kobo"
check-action "${RESULT_OK}" "${RESULT_NOK}"

# Force recreate Docker frontend
$SSH "python3 /home/ubuntu/kobo-install/run.py -cf up --force-recreate -d kobocat kpi enketo_express nginx" > /dev/null 2>&1

RESULT_OK="Force recreate Kobo Ok"
RESULT_NOK="Error - Force recreate Kobo"
check-action "${RESULT_OK}" "${RESULT_NOK}"

echo "[ ${DATE_ECHO} ] Force recreate Kobo..."
sleep 30

TEST_DOCKER_NGINX=$($SSH "docker inspect -f '{{.State.Running}}' kobofe_nginx_1")
TEST_DOCKER_KC=$($SSH "docker inspect -f '{{.State.Running}}' kobofe_kobocat_1")
TEST_DOCKER_KPI=$($SSH "docker inspect -f '{{.State.Running}}' kobofe_kpi_1")
TEST_DOCKER_EE=$($SSH "docker inspect -f '{{.State.Running}}' kobofe_enketo_express_1")

if [[ ${TEST_DOCKER_NGINX} == "true" ]] && [ ${TEST_DOCKER_KC} == "true" ]] && [ ${TEST_DOCKER_KPI} == "true" ]] && [ ${TEST_DOCKER_EE} == "true" ]]; then
    echo "[ ${DATE_ECHO}] Docker UP"
    #AWS
    CREATE_IMAGE=$($AWS ec2 create-image \
        --region ${EC2_REGION} \
        --instance-id ${ID_INSTANCE}  \
        --name "kobo.hhi.frontend.ami.$DATE" \
        --description "Frontend AMI for ${ENV}" \
        --output text)
    ID_AMI=${CREATE_IMAGE}
    
    # Wait AMI creation 
    while [ "$($AWS ec2 describe-images --region ${EC2_REGION} --image-ids ${ID_AMI} --query Images[].State --output text)" = "pending" ]; do
        echo "[ ${DATE_ECHO} ] AMI ${ID_AMI} is in progress..."
        sleep 10
    done

    TEST_CREATE_IMAGE=$($AWS ec2 describe-images \
    --region ${EC2_REGION} \
    --image-ids ${ID_AMI} \
    --query Images[].Name \
    --output text)
    
    if [[ -n "${TEST_CREATE_IMAGE}" ]]; then
        echo "[ ${DATE_ECHO} ] Create AMI : ${TEST_CREATE_IMAGE}"
    else
        echo "[ ${DATE_ECHO} ] Error - Create AMI : ${TEST_CREATE_IMAGE}"
        exit 
    fi
 
    # Copy the current ASG Launch Configuration, then modify it to use the new AMI
    CREATE_LAUNCH_CONFIGURATION=$($AWS autoscaling create-launch-configuration \
        --launch-configuration-name ${LAUNCH_CONFIGURATION_NAME} \
        --image-id ${ID_AMI} \
        --iam-instance-profile ${IAM_ROLE} \
        --key-name "${KEY_PAIR_NAME}" \
        --security-groups "${SECURITY_GROUP_NGINX}" "${SECURITY_GROUP_SSH}" \
        --instance-type ${INSTANCE_TYPE} \
        --region ${EC2_REGION} \
        --instance-monitoring Enabled=true \
        --ebs-optimized \
        --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=60,VolumeType=gp2,DeleteOnTermination=true,Encrypted=false}')
  
    #Test ASG
    if [[ -n "$CREATE_LAUNCH_CONFIGURATION" ]]; then
        echo "[ ${DATE_ECHO} ] Create ASG launch configuration : ${LAUNCH_CONFIGURATION_NAME}"
    else 
        echo "[ ${DATE_ECHO} ] Error - Create ASG launch configuration : ${LAUNCH_CONFIGURATION_NAME}"
        exit
    fi

    # Tell ASG to use new Launch Configuration
    $AWS autoscaling update-auto-scaling-group \
        --auto-scaling-group-name ${AUTO_SCALING_GROUP_NAME} \
        --launch-configuration-name ${LAUNCH_CONFIGURATION_NAME}

    TEST_UPDATE_AUTO_SCALING=$($AWS autoscaling describe-auto-scaling-groups \
        --auto-scaling-group-name ${AUTO_SCALING_GROUP_NAME} \
        --query 'AutoScalingGroups[].LaunchConfigurationName[]'\
        --output text)

    if [[ "${TEST_UPDATE_AUTO_SCALING}" == "${LAUNCH_CONFIGURATION_NAME}" ]]; then
        echo "[ ${DATE_ECHO} ] Apply new ASG launch configuration : ${LAUNCH_CONFIGURATION_NAME}"
    else 
        echo "[ ${DATE_ECHO} ] Error - Apply new ASG launch configuration : ${LAUNCH_CONFIGURATION_NAME}"
        exit
    fi

    # Delete the old ASG Launch Configuration
    #$AWS autoscaling delete-launch-configuration --launch-configuration-name my-launch-config
    # Keep the previous AMI but delete any older AMIs
    # Don’t delete the previous one so that we can roll back if the new AMI doesn’t work (e.g. bad application code)

    # Change tag AMI
    $AWS ec2 create-tags \
        --resources ${ID_AMI} \
        --tags Key=version,Value=latest

    TEST_UPDATE_AMI_TAG=$($AWS ec2 describe-images \
        --image-ids ${ID_AMI} \
        --query 'Images[].Tags[?Key==`version`]|[].Value' \
        --output text)

    if [[ "${TEST_UPDATE_AMI_TAG}" == "latest" ]]; then
        echo "[ ${DATE_ECHO} ] Apply tag : ${TEST_UPDATE_AMI_TAG} on AMI"
    else 
        echo "[ ${DATE_ECHO} ] Error - Apply tag : ${TEST_UPDATE_AMI_TAG} on AMI"
        exit
    fi

    # Delete EC2 instance 
    $AWS ec2 terminate-instances --instance-ids ${ID_INSTANCE}
    TEST_DELETE_INSTANCE=$($AWS ec2 describe-instances \
    --region ${EC2_REGION} \
    --instance-ids ${ID_INSTANCE} \
    --query Reservations[].Instances[].State.Name \
    --output text)
    
    if [[ "${TEST_DELETE_INSTANCE}" == "terminated" ]]; then
        echo "[ ${DATE_ECHO} ] Instance : ${ID_INSTANCE} deleted"
    else 
        echo "[ ${DATE_ECHO} ] Error - Instance : ${ID_INSTANCE} deleted"
        exit
    fi 
    
    # Delete old AMI
    $AWS ec2 deregister-image --image-id $OLD_ID_AMI
    TEST_DELETE_AMI=$($AWS ec2 describe-images \
        --region ${EC2_REGION} \
        --image-ids $OLD_ID_AMI \
        --query Images[].ImageId \
        --output text)
    if [[ "${TEST_DELETE_AMI}" != "$OLD_ID_AMI" ]]; then
        echo "[ ${DATE_ECHO} ] AMI : ${OLD_ID_AMI} deleted"
    else
        echo "[ ${DATE_ECHO} ] Error - AMI : ${OLD_ID_AMI} deleted" 
    fi
    
else
    echo "[ ${DATE_ECHO} ] Error - Docker"
    exit
fi