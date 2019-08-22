#!/bin/bash
while getopts "p:P:r:R:h" arg; do
    case $arg in
        p)
          SOURCE_PROFILE=${OPTARG}
          ;;
        P)
          DESTINATION_PROFILE=${OPTARG}
          ;;
        r)
          SOURCE_REGION=${OPTARG}
          ;;
        R)
          DESTINATION_REGION=${OPTARG}
          ;;
        h)
          cat <<- EOF
          [HELP]: ### CopyAWSCLIECRRepositoryCrossAccountCrossRegion. Copy ECR Repos. ###
		   
          [EXAMPLE]: scriptname -r us-east-1 -R eu-central-1 -p my-source-amazon-profile -P my-destination-amazon-profile"
          
          [REQUIREMENTS]: This script requires only four arguments -r (source_region), -R (destination_region),
              -p (source_profile), -P (destination_profile) and requires awscli, aws credentials file, jq and docker with current running service.
		  order to use this tool.
		  
         [REQUIRED ARGUMENTS]:
            -r) [region] [STRING] This option refers to the SOURCE region to be used for AWS.
            -R) [region] [STRING] This option refers to the DESTINATION region to be used for AWS.
            -p) [profile] [STRING] This option refers to the SOURCE profile to be used for AWS. This should exist in $HOME/.aws/credentials.
            -P) [profile] [STRING] This option refers to the DESTINATION profile to be used for AWS. This should exist in $HOME/.aws/credentials.
		  
         [OPTIONAL ARGUMENTS]:
            -h) [HELP] [takes no arguements] Print this dialog to the screen.
EOF
         exit 0
         ;;
      *)
         printf "%s\n" "Incorrect syntax, try -h for help"
         exit 0
         ;;
    esac
done

trap ctrl_c INT

function ctrl_c() {
        echo "** Caught SIGINT: CTRL-C **"
        exit 1
}

function copy_repo_names() {

        for repo in $(aws ecr --region=$SOURCE_REGION describe-repositories --profile $SOURCE_PROFILE | jq -r 'map(.[] | .repositoryName ) | join(" ")')
            do
                echo $(aws ecr --region $DESTINATION_REGION create-repository --repository-name $repo --profile $DESTINATION_PROFILE)
        done
}

function ecr_docker_login() {
    
    sourceECRLogin=$(aws ecr get-login --region $SOURCE_REGION --profile $SOURCE_PROFILE)
    if [[ -z $sourceECRLogin ]] && [[ $? -ne 0 ]]
        then
            isSourceLoggedIn="0"
        else
            isSourceLoggedIn="1"
    fi
    
    destinationECRLogin=$(aws ecr get-login --region $DESTINATION_REGION --profile $DESTINATION_PROFILE)
    if [[ -z $destinationECRLogin ]] && [[ $? -ne 0 ]]
        then
             isDestinationLoggedIn="0"
        else
             isDestinationLoggedIn="1"
    fi   
            
    if [[ $isSourceLoggedIn -eq 0 ]] || [[ $isDestinationLoggedIn -eq 0 ]]
        then
            printf "%s\n" "Unable to login to source or destination ECR repository, consult your systems administrator for additional priviledges."
    fi
}

function copy_contents_source_to_destionation_ecr() {
    printf "%s\n" "[INFO]: If you are not the root user, sudo will be invoked in order to escalate permissions for docker pull, tag, and push."
    for repo in $(aws ecr --profile $SOURCE_PROFILE --region=$SOURCE_REGION describe-repositories \
            | jq -r 'map(.[] | .repositoryName ) | join(" ")')
        do 
            for image in $(aws ecr --region \
            $SOURCE_REGION --profile $SOURCE_PROFILE list-images --repository-name $repo | jq -r \
            'map(.[] | .imageTag) | join(" ")')
                do 
                    sudo docker pull ${sourceCallerId}.dkr.ecr.${SOURCE_REGION}.amazonaws.com/${repo}:${image}
                    sudo docker tag ${sourceCallerId}.dkr.ecr.${SOURCE_REGION}.amazonaws.com/${repo}:${image} \
                    ${destinationCallerId}.dkr.ecr.${DESTINATION_REGION}.amazonaws.com/${repo}:${image}
                    sudo docker push ${destinationCallerId}.dkr.ecr.${DESTINATION_REGION}.amazonaws.com/${repo}:${image}
            done
    done
}

function sanity_test() {

    isAWSCLIInstalled=$(which aws)
    isAWSCredFileExist=$(test -r ~/.aws/credentials && echo "True")
    isJQInstalled=$(which jq)
    isDockerBinInstalled=$(which docker)
    isDockerServiceRun=$(test -e /run/docker.pid && echo "True")
    if [[ -z $isAWSCLIInstalled ]] && [[ -z $isJQInstalled ]] && [[ -z $isDockerBinInstalled ]] && \
            [[ $isAWSCredFileExist == "True" ]] && [[ $isDockerServiceRun == "True" ]]
        then
            export isSane="1"
        else
            printf "%s\n" \
                    "[ERROR]: Missing one or more dependencies:" "ATTN: Missing values indicate unresolved dependencies:" \
                    "[INFO]: AWSCLI status @ $isAWSCLIInstalled" \
                    "[INFO]: JQ status @ $isJQInstalled" \
                    "[INFO]: Docker Binary status @ $isDockerBinInstalled" \
                    "[INFO]: AWS Cred file status: $isAWSCredFileExist" \
                    "[INFO]: Docker Service status: $isDockerServiceRun"
    fi
}

function get_caller_identity_account() {

    sourceCallerId=$(aws sts get-caller-identity --profile $SOURCE_PROFILE | grep -i Arn | sed s'/\:/ /g;s/\"//g' | awk {'print $5'})
    destinationCallerId=$(aws sts get-caller-identity --profile $DESTINATION_PROFILE | grep -i Arn | sed s'/\:/ /g;s/\"//g' | awk {'print $5'})

}

function gdpr_and_permissions_understanding() {
    printf "%s\n" "[INFO]: This script requires sts:GetCallerIdentity, ecr:ListImages, ecr:TagResource," \
            "ecr:DescribeRepositories, ecr:CreateRepository, ecr:PutImage, ecr:DescribeImages, ecr:GetAuthorizationToken" \
            "ecr:InitiateLayerUpload, ecr:GetDownloadUrlForLayer, ecr:BatchGetItem, ecr:BatchGetImage, and ecr:BatchCheckLayerAvailability" \
            "[INFO]: Continue? y/n"
    read goNoGo
    printf "%s\n" "Please stop to consider any applicable GDPR requirements for these images? Is there any personally identifiable information," \
            "that could possibly exist? (Uncommon)" "[INFO]: Continue? y/n"
    read goNoGoGDPR
    if [[ $goNoGo == *y* ]] && [[ $goNoGoGDPR == *y* ]]
        then
            export permsAndGDPR=1
        else
            printf "%s\n" "User replied negatively to one or more questions, exiting."
            exit 1
    fi
}

# Run
sanity_test
if [[ $isSane -eq 1 ]] && [[ $permsAndGDPR -eq 1 ]]
    then
        get_caller_identity_account
        copy_repo_names
        ecr_docker_login
        copy_contents_source_to_destination
    else
        exit 1
fi
