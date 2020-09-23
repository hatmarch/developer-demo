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
    -k         [optional] Install kafka cluster (only works with -i)

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
          k  ) kakfa_flag=true;;
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

    # create a staging project if it doesn't already exist
    stage_prj="${PROJECT_PREFIX}-stage"
    oc get ns $stage_prj 2>/dev/null  || { 
        oc new-project $stage_prj
    }

    # Support project (optionally created in prerequisites)
    sup_prj="${PROJECT_PREFIX}-support"
    oc get ns $sup_prj 2>/dev/null  || { 
        oc new-project $sup_prj
    }

    # # Create a nexus server
    # echo "Creating the nexus server in project $cicd_prj"
    # oc apply -f $DEMO_HOME/install/nexus/nexus.yaml -n $cicd_prj

    # Create the gogs server
    echo "Creating gogs server in project $cicd_prj"
    oc apply -f $DEMO_HOME/install/gogs/gogs.yaml -n $cicd_prj
    GOGS_HOSTNAME=$(oc get route gogs -o template --template='{{.spec.host}}' -n $cicd_prj)
    echo "Initiatlizing git repository in Gogs and configuring webhooks"
    sed "s/@HOSTNAME/$GOGS_HOSTNAME/g" $DEMO_HOME/install/gogs/gogs-configmap.yaml | oc apply -f - -n $cicd_prj
 
    # Install pre-reqs before tekton
    if [[ -n "${prereq_flag:-}" ]]; then
        if [[ -n "${kafka_flag:-}" ]]; then
            echo "Installing pre-requisites with kafka in ${sup_prj}"
            ${SCRIPT_DIR}/install-prereq.sh -s ${sup_prj} -k
        else
            echo "Installing pre-requisites without kafka"
            ${SCRIPT_DIR}/install-prereq.sh -s ${sup_prj}
        fi
    fi

    # 
    # Install Tekton resources
    #
    echo "Installing Tekton supporting resources"

    echo "Installing PVCs"
    oc apply -n $cicd_prj -R -f $DEMO_HOME/install/tekton/volumes

    echo "Installing Tasks (in $cicd_prj and $dev_prj)"
    oc apply -n $cicd_prj -R -f $DEMO_HOME/install/tekton/tasks
    oc apply -n $dev_prj -f $DEMO_HOME/install/tekton/tasks/oc-client-local-task.yaml

    echo "Installing tokenized pipeline"
    sed "s/demo-dev/${dev_prj}/g" $DEMO_HOME/install/tekton/pipelines/payment-pipeline.yaml | sed "s/demo-support/${sup_prj}/g" | oc apply -n $cicd_prj -f -

    echo "Installing Tekton Triggers"
    sed "s/demo-dev/${dev_prj}/g" $DEMO_HOME/install/tekton/triggers/triggertemplate.yaml | oc apply -n $cicd_prj -f -
    oc apply -n $cicd_prj -f $DEMO_HOME/install/tekton/triggers/gogs-triggerbinding.yaml
    oc apply -n $cicd_prj -f $DEMO_HOME/install/tekton/triggers/eventlistener-gogs.yaml

    # There can be a race when the system is installing the pipeline operator in the $cicd_prj
    echo -n "Waiting for Pipelines Operator to be installed in $cicd_prj..."
    while [[ "$(oc get $(oc get csv -oname -n $cicd_prj| grep pipelines) -o jsonpath='{.status.phase}' -n $cicd_prj 2>/dev/null)" != "Succeeded" ]]; do
        echo -n "."
        sleep 1
    done

    # Allow the pipeline service account to push images into the dev account
    oc policy add-role-to-user -n $dev_prj system:image-pusher system:serviceaccount:$cicd_prj:pipeline
    
    # Add a cluster role that allows fined grained access to knative resources without granting edit
    oc apply -f $DEMO_HOME/install/tekton/roles/kn-deployer-role.yaml
    # ..and assign the pipeline service account that role in the dev project
    oc adm policy add-cluster-role-to-user -n $dev_prj kn-deployer system:serviceaccount:$cicd_prj:pipeline

    # allow any pipeline in the dev project access to registries in the staging project
    oc policy add-role-to-user -n $stage_prj registry-editor system:serviceaccount:$dev_prj:pipeline

    # Allow tekton to deploy a knative service to the staging project
    oc adm policy add-role-to-user -n $stage_prj kn-deployer system:serviceaccount:$dev_prj:pipeline

    # Seeding the .m2 cache
    echo "Seeding the .m2 cache"
    oc apply -n $cicd_prj -f $DEMO_HOME/install/tekton/init/copy-to-workspace-task.yaml 
    oc create -n $cicd_prj -f install/tekton/init/seed-cache-task-run.yaml
    # This should cause everything to block and show output
    tkn tr logs -L -f -n $cicd_prj 

    # wait for gogs rollout to complete
    oc rollout status deployment/gogs -n $cicd_prj

    echo "Initializing gogs"
    oc create -n $cicd_prj -f $DEMO_HOME/install/gogs/gogs-init-taskrun.yaml
    # This should fail if the taskrun fails
    tkn tr logs -L -f -n $cicd_prj 

    # # configure the nexus server
    # echo "Configuring the nexus server..."
    # ${SCRIPT_DIR}/util-config-nexus.sh -n $cicd_prj -u admin -p admin123

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