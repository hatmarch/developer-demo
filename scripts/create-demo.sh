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

    #create the project if it doesn't already exist
    dev_prj="${PROJECT_PREFIX}-dev"
    oc get ns $dev_prj 2>/dev/null  || { 
        oc new-project $dev_prj
    }

    sup_prj="${PROJECT_PREFIX}-support"
    if [[ "${prereq_flag-""}" ]]; then
        echo "Installing pre-requisites in project $sup_prj"
        ${SCRIPT_DIR}/install-prereq.sh -k ${sup_prj}
    fi
 
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