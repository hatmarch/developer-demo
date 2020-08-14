#!/bin/bash

declare -r SCRIPT_DIR=$(cd -P $(dirname $0) && pwd)

#
# Fix up all the hardcoded routes
#
for app in $(oc get route --no-headers | awk '{ print $1 }'); do
    echo "app is $app"
    oc delete route $app
    oc expose svc $app
done