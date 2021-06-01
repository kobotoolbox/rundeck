## Rundeck
Automated jobs are created on a Rundeck instance (https://rundeck.kbtdev.org).

1. Scripts need environment files for each production environment.  
There are located in `/var/lib/rundeck/kobo/`:
- `hhi.env`
- `ocha.env` 
- `ifrc.env`


env files must contain these variables: 

| First Header  | Second Header |
| ------------- | ------------- |
| `AUTO_SCALING_GROUP_NAME` | Name of the ASG. Use `null` if none is in use  |
| `EC2_REGION` | AWS region (e.g.: `us-east-1`) |
| `INSTANCE_TYPE` | EC2 type (e.g.: `m5.xlarge`) |
| `SUBNET_ID` | Id of subnet  |
| `KEY_PAIR_NAME` | Name of SSH key use to log into the instance |
| `SECURITY_GROUP_SSH` | Id of the security group for SSH (e.g. `sg-xxxxxxx`) |
| `SECURITY_GROUP_RUNDECK_SSH` | Id of the security group for Rundeck (e.g. `sg-xxxxxxx`)   |
| `IAM_ROLE` | Role used by EC2 to run scripts (e.g.: `aws-script-role`) |
| `KOBO_EC2_MONITORED_DOMAIN` | Domain name monitored by kobo-ec2 script to restart containers in case of unhealthy state |
| `PRIMARY_FRONTEND_ID` | Id of EC2 (e.g.: `i-xxxxxxxxxx`) |
| `KEY_SSH` | Path to SSH key |


## ami-update.sh
To-Do write documentation

## asg-update.sh
To-Do write documentation

## deployment.sh
To-Do write documentation
