#!/bin/bash

set -Eeuo pipefail

declare -r SCRIPT_DIR=$(cd -P $(dirname $0) && pwd)
declare PROJECT_PREFIX="dev-demo"
declare KAFKA_PROJECT="${PROJECT_PREFIX}-support"

display_usage() {
cat << EOF
$0: Developer Demo Uninstall --

  Usage: ${0##*/} [ OPTIONS ]
  
    -f         [optional] Full uninstall, removing pre-requisites
    -p <TEXT>  [optional] Project prefix to use.  Defaults to dev-demo
    -k <TEXT>  [optional] The name of the support project (e.g. where kafka is installed).  Will default to dev-demo-support
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
  while getopts ':k:p:fh' option; do
      case "${option}" in
          k  ) kafka_flag=true; KAFKA_PROJECT="${OPTARG}";;
          p  ) p_flag=true; PROJECT_PREFIX="${OPTARG}";;
          f  ) full_flag=true;;
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

  if [[ -z "${KAFKA_PROJECT}" ]]; then
      printf '%s\n\n' 'ERROR - Support project (KAFKA_PROJECT) must not be null' >&2
      display_usage >&2
      exit 1
  fi
}

remove-operator()
{
    OPERATOR_NAME=$1

    echo "Uninstalling operator: ${OPERATOR_NAME}"
    CURRENT_SERVERLESS_CSV=$(oc get sub ${OPERATOR_NAME} -n openshift-operators -o yaml | grep "currentCSV: ${OPERATOR_NAME}" | sed "s/.*currentCSV: //")
    oc delete sub ${OPERATOR_NAME} -n openshift-operators
    oc delete csv ${CURRENT_SERVERLESS_CSV} -n openshift-operators
}

remove-crds() 
{
    API_NAME=$1

    oc get crd -oname | grep "${API_NAME}" | xargs oc delete
}

main() {
    # import common functions
    . $SCRIPT_DIR/common-func.sh

    trap 'error' ERR
    trap 'cleanup' EXIT SIGTERM
    trap 'interrupt' SIGINT

    get_and_validate_options "$@"

    if [[ "${full_flag:-""}" ]]; then
        echo "Uninstalling knative eventing"
        oc delete knativeeventings.operator.knative.dev knative-eventing -n knative-eventing || true
        oc delete namespace knative-eventing || true

        echo "Uninstalling knative serving"
        oc delete knativeservings.operator.knative.dev knative-serving -n knative-serving || true
        oc delete namespace knative-serving || true

        remove-operator "serverless-operator" || true

        echo "Removing Serverless Operator related CRDs"
        remove-crds "knative.dev" || true

        remove-operator "knative-kafka-operator" || true

        remove-operator "amq-streams" || true

        remove-crds "kafka.strimzi.io" || true

        remove-operator "openshift-pipelines-operator" || true
    fi

    dev_prj="${PROJECT_PREFIX}-dev"

    echo "Deleting project $dev_prj"
    oc delete project "${dev_prj}" || true

    echo "Uninstalling support project $KAFKA_PROJECT"
    oc delete project "${KAFKA_PROJECT}" || true

    cicd_prj="${PROJECT_PREFIX}-cicd"
    echo "Uninstalling cicd project ${cicd_prj}"
    oc delete prject "${cicd_prj}" || true
}

main "$@"
