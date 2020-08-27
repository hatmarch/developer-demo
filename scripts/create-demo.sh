#!/bin/bash

set -Eeuo pipefail

declare -r SCRIPT_DIR=$(cd -P $(dirname $0) && pwd)
declare PROJECT_PREFIX="dev-demo"

display_usage() {
cat << EOF
$0: Create Developer Demo --

  Usage: ${0##*/} [ OPTIONS ]
  
    -i         [optional] Install prerequisites
    -p <TEXT>  [optional] Project prefix to use.  Defaults to "dev-demo"

EOF
}

get_and_validate_options() {
  # Transform long options to short ones
#   for arg in "$@"; do
#     shift
#     case "$arg" in
#       "--long-x") set -- "$@" "-x" ;;
#       "--long-y") set -- "$@" "-y" ;;
#       *)        set -- "$@" "$arg"
#     esac
#   done

  
  # parse options
  while getopts ':ip:h' option; do
      case "${option}" in
          i  ) prereq_flag=true;;
          p  ) p_flag=true; PROJECT_PREFIX="${OPTARG}";;
          h  ) display_usage; exit;;
          \? ) printf "%s\n\n" "  Invalid option: -${OPTARG}" >&2; display_usage >&2; exit 1;;
          :  ) printf "%s\n\n%s\n\n\n" "  Option -${OPTARG} requires an argument." >&2; display_usage >&2; exit 1;;
      esac
  done
  shift "$((OPTIND - 1))"

  if [[ -z "${PROJECT_PREFIX}" ]]; then
      printf '%s\n\n' 'ERROR - PROJECT_PREFIX must not be null' >&2
      display_usage >&2
      exit 1
  fi
}

main() {
    # import common functions
    . $SCRIPT_DIR/common-func.sh

    trap 'error' ERR
    trap 'cleanup' EXIT SIGTERM
    trap 'interrupt' SIGINT

    get_and_validate_options "$@"

    #
    # create the cicd project
    #
    cicd_prj="${PROJECT_PREFIX}-cicd"
    oc get ns $cicd_prj 2>/dev/null  || { 
        oc new-project $cicd_prj
    }

    #create the dev project if it doesn't already exist
    dev_prj="${PROJECT_PREFIX}-dev"
    oc get ns $dev_prj 2>/dev/null  || { 
        oc new-project $dev_prj
    }

    # Support project (optionally created in prerequisites)
    sup_prj="${PROJECT_PREFIX}-support"

    # 
    # Install Tekton resources
    #
    echo "Installing Tekton supporting resources"

    echo "Installing PVCs"
    oc apply -n $cicd_prj -R -f $DEMO_HOME/install/tekton/volumes

    echo "Installing Tasks"
    oc apply -n $cicd_prj -R -f $DEMO_HOME/install/tekton/tasks

    echo "Installing tokenized pipeline"
    sed "s/demo-dev/${dev_prj}/g" $DEMO_HOME/install/tekton/pipelines/payment-pipeline.yaml | sed "s/demo-support/${sup_prj}/g" | oc apply -n $cicd_prj -f -

    # Create a nexus server
    echo "Creating the nexus server in project $cicd_prj"
    oc apply -f $DEMO_HOME/install/nexus/nexus.yaml -n $cicd_prj

    # Create the gogs server
    echo "Creating gogs server in project $cicd_prj"
    oc apply -f $DEMO_HOME/install/gogs/gogs.yaml -n $cicd_prj
    GOGS_HOSTNAME=$(oc get route gogs -o template --template='{{.spec.host}}' -n $cicd_prj)
    echo "Initiatlizing git repository in Gogs and configuring webhooks"
    sed "s/@HOSTNAME/$GOGS_HOSTNAME/g" $DEMO_HOME/install/gogs/gogs-configmap.yaml | oc create -f - -n $cicd_prj
    oc rollout status deployment/gogs -n $cicd_prj

    # There can be a race when the system is installing the pipeline operator in the $cicd_prj
    echo -n "Waiting for Pipelines Operator to be installed in $cicd_prj..."
    while [[ "$(oc get $(oc get csv -oname | grep pipelines) -o jsonpath='{.status.phase}')" != "Succeeded" ]]; do
        echo -n "."
        sleep 1
    done

    # Allow the pipeline service account to push images into the dev account
    oc policy add-role-to-user -n $dev_prj system:image-pusher system:serviceaccount:$cicd_prj:pipeline
    
    # Add a cluster role that allows fined grained access to knative resources without granting edit
    oc apply -f $DEMO_HOME/install/tekton/roles/kn-deployer-role.yaml
    # ..and assign the pipeline service account that role in the dev project
    oc adm policy add-cluster-role-to-user -n $dev_prj kn-deployer system:serviceaccount:$cicd_prj:pipeline


    oc create -f $DEMO_HOME/install/gogs/gogs-init-taskrun.yaml -n $cicd_prj
    # This should fail if the taskrun fails
    tkn tr logs -L -f

    # configure the nexus server
    echo "Configuring the nexus server..."
    ${SCRIPT_DIR}/util-config-nexus.sh -n $cicd_prj -u admin -p admin123

    if [[ "${prereq_flag-""}" ]]; then
        echo "Installing pre-requisites in project $sup_prj"
        ${SCRIPT_DIR}/install-prereq.sh -k ${sup_prj}
    fi
 
    echo "Install configmaps"
    oc apply -R -n $dev_prj -f $DEMO_HOME/install/config/

    echo "Installing coolstore website (minus payment)"
    oc process -f $DEMO_HOME/install/templates/cool-store-no-payment-template.yaml -p PROJECT=$dev_prj | oc apply -f - -n $dev_prj

    echo "Correcting routes"
    oc project $dev_prj
    $DEMO_HOME/scripts/route-fix.sh

    echo "updating all images"
    # Fix up all image streams by pointing to pre-built images (which should trigger deployments)
    $DEMO_HOME/scripts/image-stream-setup.sh
}

main "$@"