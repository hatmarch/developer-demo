#!/bin/bash

set -Eeuo pipefail

declare -r SCRIPT_DIR=$(cd -P $(dirname $0) && pwd)
declare PROJECT_PREFIX="dev-demo"

display_usage() {
cat << EOF
$0: Install Developer Demo Prerequisites --

  Usage: ${0##*/} [ OPTIONS ]
  
    -s <TEXT>  [required] The name of the support project (where the kafka cluster will eventually go)
    -k         [optional] Whether to actually create a kafka cluster in the support project

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
  while getopts ':s:kh' option; do
      case "${option}" in
          k  ) kafka_flag=true;;
          s  ) sup_prj="${OPTARG}";;
          h  ) display_usage; exit;;
          \? ) printf "%s\n\n" "  Invalid option: -${OPTARG}" >&2; display_usage >&2; exit 1;;
          :  ) printf "%s\n\n%s\n\n\n" "  Option -${OPTARG} requires an argument." >&2; display_usage >&2; exit 1;;
      esac
  done
  shift "$((OPTIND - 1))"

  if [[ -z "${sup_prj:-}" ]]; then
      printf '%s\n\n' 'ERROR - Support project must not be null, specify with -s' >&2
      display_usage >&2
      exit 1
  fi
}

wait_for_crd()
{
    local CRD=$1
    local PROJECT=$(oc project -q)
    if [[ "${2:-}" ]]; then
        # set to the project passed in
        PROJECT=$2
    fi

    # Wait for the CRD to appear
    while [ -z "$(oc get $CRD 2>/dev/null)" ]; do
        sleep 1
    done 
    oc wait --for=condition=Established $CRD --timeout=6m -n $PROJECT
}

main()
{
    # import common functions
    . $SCRIPT_DIR/common-func.sh

    trap 'error' ERR
    trap 'cleanup' EXIT SIGTERM
    trap 'interrupt' SIGINT

    get_and_validate_options "$@"

    #
    # Subscribe to Operators
    #

    #
    # Install Pipelines (Tekton)
    #
    echo "Installing OpenShift pipelines"
    oc apply -f "$DEMO_HOME/install/tekton/tekton-subscription.yaml"

    # install the serverless operator
    oc apply -f "$DEMO_HOME/install/serverless/subscription.yaml" 

    # install the kafka operator (AMQStreams)
    oc apply -f "$DEMO_HOME/install/kafka/subscription.yaml" 

    oc apply -f "$DEMO_HOME/install/kafka-eventing/subscription.yaml"

    #
    # Install Kafka Instances
    #

    # make sure CRD is available before adding CRs
    echo "Waiting for the operator to install the Kafka CRDs"
    wait_for_crd "crd/kafkas.kafka.strimzi.io"

    if [[ -n "${kafka_flag:-}" ]]; then
        oc get ns "${sup_prj}" 2>/dev/null  || { 
            oc new-project "${sup_prj}"
        }

        # use the default parameter values
        oc process -f "$DEMO_HOME/install/kafka/kafka-template.yaml" | oc apply -n $sup_prj -f -

        # install the necessary kafka instance and topics
        oc apply -f "$DEMO_HOME/install/kafka/kafka-orders-topic.yaml" -n $sup_prj
        oc apply -f "$DEMO_HOME/install/kafka/kafka-payments-topic.yaml" -n $sup_prj

        # wait until the cluster is deployed
        echo "Waiting up to 30 minutes for kafka cluster to be ready"
        oc wait --for=condition=Ready kafka/my-cluster --timeout=30m -n $sup_prj
        echo "Kafka cluster is ready."
    fi

    #
    # Install Serving
    #

    echo "Waiting for the operator to install the Knative CRDs"
    wait_for_crd "crd/knativeservings.operator.knative.dev"

    oc apply -f "$DEMO_HOME/install/serverless/cr.yaml"

    echo "Waiting for the knative serving instance to finish installing"
    oc wait --for=condition=InstallSucceeded knativeserving/knative-serving --timeout=6m -n knative-serving

    #
    # Install Knative Eventing
    #
    echo "Waiting for the operator to install the Knative Event CRD"
    wait_for_crd "crd/knativeeventings.operator.knative.dev"

    oc apply -f "$DEMO_HOME/install/knative-eventing/knative-eventing.yaml" 
    echo "Waiting for the knative eventing instance to finish installing"
    oc wait --for=condition=InstallSucceeded knativeeventing/knative-eventing -n knative-eventing --timeout=6m

    # NOTE: kafka eventing needs to be installed in same project as knative eventing (this is baked into the yaml) but it also
    # needs to properly reference the cluster that we'll be using
    sed "s#support-prj#${sup_prj}#" $DEMO_HOME/install/kafka-eventing/kafka-eventing.yaml | oc apply -f -

    echo "Installing CodeReady Workspaces"
    ${SCRIPT_DIR}/install-crw.sh codeready

    # Ensure pipelines is installed
    wait_for_crd "crd/pipelines.tekton.dev"

    echo "Prerequisites installed successfully!"
}

main "$@"



