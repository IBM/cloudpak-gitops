#!/bin/bash

set -eo pipefail
set +x

scriptdir=$(dirname "${0}")

#
# Prints a timestamped message to stdout.
#
function log() {
    local msg="${1}"
    echo "$(date +%Y-%m-%dT%H:%M:%S%z): ${msg}"
}

yamllint -v > /dev/null 2>&1 \
|| 
{
    log "INFO: Installing yamllint"
    apt-get update && \
    {
        apt-get install yamllint -y \
            || log "ERROR: yamllint installation failed."
    }
}

install_helm_3=0
helm version --short --client > /dev/null 2>&1 || install_helm_3=1
helm version --short --client | grep "v2" > /dev/null 2>&1 && install_helm_3=1

if [ ${install_helm_3} -eq 1 ]; then
    log "INFO: Installing helm 3"
    WORKDIR=/tmp
    curl -sL https://get.helm.sh/helm-v3.5.2-linux-amd64.tar.gz | tar xzf - -C "${WORKDIR}" \
        && install "${WORKDIR}/linux-amd64/helm" /usr/local/bin/helm \
        || log "ERROR: helm 3 installation failed."
fi

log "INFO: Starting yamllint run"
yl_result=0
yamllint -c "${scriptdir}/yamllint-config.yaml" config/ || yl_result=1
log "INFO: Completed yamllint run: ${yl_result}"

log "INFO: Starting helm lint run"
hl_result=0
find . -name Chart.yaml | sed "s|/Chart.yaml||g" | xargs helm lint || hl_result=1
log "INFO: Completed helm lint run: ${hl_result}"

result=$((hl_result+yl_result))
log "INFO: Global test failures: ${result}"

exit "${result}"
