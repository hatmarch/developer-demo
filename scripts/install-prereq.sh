#!/bin/bash

set -Eeuo pipefail

declare -r SCRIPT_DIR=$(cd -P $(dirname $0) && pwd)
declare PROJECT_PREFIX="dev-demo"

display_usage() {
cat << EOF
$0: Install Developer Demo Prerequisites --

  Usage: ${0##*/} [ OPTIONS ]
  
    -k <TEXT>  [optional] The project to install the kafka cluster to (kafka cluster not created if not provided)

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
  while getopts ':k:h' option; do
      case "${option}" in
          k  ) kafka_flag=true; KAFKA_PROJECT="${OPTARG}";;
          h  ) display_usage; exit;;
          \? ) printf "%s\n\n" "  Invalid option: -${OPTARG}" >&2; display_usage >&2; exit 1;;
          :  ) printf "%s\n\n%s\n\n\n" "  Option -${OPTARG} requires an argument." >&2; display_usage >&2; exit 1;;
      esac
  done
  shift "$((OPTIND - 1))"

  if [[ "${kafka_flag:-""}" && -z "${KAFKA_PROJECT:-}" ]]; then
      printf '%s\n\n' 'ERROR - KAFKA_PROJECT must not be null' >&2
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

    if [[ "${kafka_flag:-""}" ]]; then
        oc get ns "${KAFKA_PROJECT}" 2>/dev/null  || { 
            oc new-project "${KAFKA_PROJECT}"
        }

        # use the default parameter values
        oc process -f "$DEMO_HOME/install/kafka/kafka-template.yaml" | oc apply -n $KAFKA_PROJECT -f -

        # install the necessary kafka instance and topics
        oc apply -f "$DEMO_HOME/install/kafka/kafka-orders-topic.yaml" -n $KAFKA_PROJECT
        oc apply -f "$DEMO_HOME/install/kafka/kafka-payments-topic.yaml" -n $KAFKA_PROJECT

        # wait until the cluster is deployed
        echo "Waiting up to 30 minutes for kafka cluster to be ready"
        oc wait --for=condition=Ready kafka/my-cluster --timeout=30m -n $KAFKA_PROJECT
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
    sed "s#support-prj#${KAFKA_PROJECT}#" $DEMO_HOME/install/kafka-eventing/kafka-eventing.yaml | oc apply -f -

    # Ensure pipelines is installed
    wait_for_crd "crd/pipelines.tekton.dev"

    echo "Prerequisites installed successfully!"
}

main "$@"



