#!/bin/bash

set -euo pipefail

declare BASE_TAG=${1:-latest}
declare SHELL_TAG=${2:-}

DOCKER_BUILDKIT=1 docker build --progress=plain --secret id=myuser,src=../docker-secrets/myuser.txt --secret id=mypass,src=../docker-secrets/mypass.txt -f Dockerfile-devcontainer-base -t quay.io/mhildenb/dev-demo-base:$BASE_TAG .

docker tag quay.io/mhildenb/dev-demo-base:$BASE_TAG quay.io/mhildenb/dev-demo-base:latest
docker push quay.io/mhildenb/dev-demo-base:$BASE_TAG
docker push quay.io/mhildenb/dev-demo-base:latest

if [[ -n $SHELL_TAG ]]; then
    docker tag quay.io/mhildenb/dev-demo-base:latest quay.io/mhildenb/dev-demo-shell:${SHELL_TAG}
    docker tag quay.io/mhildenb/dev-demo-shell:${SHELL_TAG} quay.io/mhildenb/dev-demo-shell:latest

    docker push quay.io/mhildenb/dev-demo-shell:${SHELL_TAG}
    docker push quay.io/mhildenb/dev-demo-shell:latest
fi