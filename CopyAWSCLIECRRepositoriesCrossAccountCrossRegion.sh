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
                if [[ $? -eq 0 ]]
                    then
                        printf "%s\n" "[INFO]: Copied ${repo} to ${DESTINATION_PROFILE} and ${DESTINATION_REGION}..."
                        export isCopiedToDestination=1
                    else
                        printf "%s\n" "[ERROR]: Failed to copy ${repo} to ${DESTINATION_PROFILE} and ${DESTINATION_REGION}, exiting..."
                        exit 1
                fi
        done
}

function ecr_docker_login() {
    
    printf "%s\n" "[INFO]: If you are not the root user, sudo will be invoked in order to escalate permissions for docker pull, tag, and push."
    sourceECRLogin=$(aws ecr get-login --region $SOURCE_REGION --profile $SOURCE_PROFILE)
    if [[ -n $sourceECRLogin ]] && [[ $? -eq 0 ]]
        then
            isSourceLogInTrue="1"
        else
            isSourceLogInTrue="0"
    fi
    
    destinationECRLogin=$(aws ecr get-login --region $DESTINATION_REGION --profile $DESTINATION_PROFILE)
    if [[ -n $destinationECRLogin ]] && [[ $? -eq 0 ]]
        then
             isDestinationLogInTrue="1"
        else
             isDestinationLogInTrue="0"
    fi   
    if [[ $isSourceLogInTrue -eq 1 ]] || [[ $isDestinationLogInTrue -eq 1 ]]
        then
            sudo $sourceECRLogin && sudo $destinationECRLogin
            if [[ $? -eq 0 ]]
                then
                    dockerLoggedIn=1
                else
                    dockerLoggedIn=0
            fi
        else
            printf "%s\n" "[ERROR]: Failed to login to docker from ECR credentials. Check your service status and try again."
    fi
}

function copy_contents_source_to_destination_ecr() {
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
    if [[ -x $isAWSCLIInstalled ]] && [[ -x $isJQInstalled ]] && [[ -x $isDockerBinInstalled ]] && \
            [[ $isAWSCredFileExist == "True" ]] && [[ $isDockerServiceRun == "True" ]]
        then
            export isSane="1"
        else
            printf "%s\n" \
                    "[ERROR]: Missing one or more dependencies:"
            printf '\e[1;31m%-6s\e[m' "[ATTN]: Missing values indicate unresolved dependencies:"
            printf "%s\n" "[INFO]: AWSCLI status @ $isAWSCLIInstalled" \
                    "[INFO]: JQ status @ $isJQInstalled" \
                    "[INFO]: Docker Binary status @ $isDockerBinInstalled" \
                    "[INFO]: AWS Cred file status: $isAWSCredFileExist" \
                    "[INFO]: Docker Service status: $isDockerServiceRun"
    fi
}

function get_caller_identity_account() {

    sourceCallerId=$(aws sts get-caller-identity --profile $SOURCE_PROFILE | grep -i Arn | sed s'/\:/ /g;s/\"//g' | awk {'print $5'})
    destinationCallerId=$(aws sts get-caller-identity --profile $DESTINATION_PROFILE | grep -i Arn | sed s'/\:/ /g;s/\"//g' | awk {'print $5'})
    if [[ -z $sourceCallerId ]] || [[ $destinationCallerId ]] 
        then
            gotAccountNumber=1
        else
            gotAccountNumber=0
    fi 
}

function gdpr_and_permissions_understanding() {
    printf '\e[1;32m%-6s\e[m\n' "[ATTENTION]: Permissions Understanding:" 
    printf "%s\n" "[INFO]: This script requires sts:GetCallerIdentity, ecr:ListImages, ecr:TagResource," \
            "ecr:DescribeRepositories, ecr:CreateRepository, ecr:PutImage, ecr:DescribeImages, ecr:GetAuthorizationToken, " \
            "ecr:InitiateLayerUpload, ecr:GetDownloadUrlForLayer, ecr:BatchGetItem, ecr:BatchGetImage, and ecr:BatchCheckLayerAvailability" \
            "[INFO]: Continue? y/n"
    read goNoGo
    printf '\e[1;32m%-6s\e[m\n' "[ATTENTION]: GDPR Understanding:"
    printf "%s\n" "Please consider any applicable GDPR requirements for these images." "I.E: Is there any personally identifiable information," \
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
gdpr_and_permissions_understanding
if [[ $isSane -eq 1 ]] && [[ $permsAndGDPR -eq 1 ]] && \
        [[ -n $SOURCE_PROFILE ]] && [[ -n $SOURCE_REGION ]] && \
        [[ -n $DESTINATION_PROFILE ]] && [[ -n $DESTINATION_REGION ]]
    then
        get_caller_identity_account
        if [[ $gotAccountNumber -eq 1 ]]
            then
                ecr_docker_login
                if [[ $dockerLoggedIn -eq 1 ]]
                    then
                        copy_repo_names
                        if [[ $isCopiedToDestination -eq 1 ]]
                            then
                                copy_contents_source_to_destination_ecr
                                if [[ $? -eq 0 ]]
                                    then
                                        printf "%s\n" "[SUCCESS]: Operation has completed with success."
                                        exit 0
                                    else
                                        printf "%s\n" "[FAILED]: Operation has failed to copy one or more image layers, but has not been rolled back."
                                        exit 1 
                                fi
                            else
                                printf "%s\n" "[FAILED]: Operation has failed to copy one or more reponames, has not been rolled back." \
                                        "[INFO]: Will continue my attempt to copy, just incase the repo names have already been copied."
                                copy_contents_source_to_destination_ecr
                                if [[ $? -ne 0 ]]
                                    then
                                        printf "%s\n" "[INFO]: Failed to copy data in the case of existing repo names. Exiting..."
                                        exit 1 
                                fi
                        fi
                    else
                        printf "%s\n" "[FAILED]: Docker was unable to login to the repositories in question."
                        exit 1
                fi
            else
                printf "%s\n" "[FAILED]: Unable to get CallerIdentitiy for account numbers, do you have permissions to call sts:GetCallerIdentity?"
                exit 1
        fi
    else
            printf "%s\n" "[FAILED]: Action has been cancelled, or environment is not sane (Missing depedencies), or user has not provided values to cli OPERANDS."
fi
