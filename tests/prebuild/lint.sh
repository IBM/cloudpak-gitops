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

shellcheck --version > /dev/null 2>&1 \
|| 
(
    log "INFO: Installing ShellCheck"
    apt-get update && \
    (
        apt-get install shellcheck -y \
        || log "ERROR: ShellCheck installation failed"
    )
)

yamllint -v > /dev/null 2>&1 \
|| 
{
    log "INFO: Installing yamllint"
    if [ "$(uname)" == "Darwin" ]; then
        brew install yamllint
    else
        if apt-get -h 2>&1 /dev/null; then
            apt-get update && \
            {
                apt-get install yamllint -y \
                    || log "ERROR: yamllint installation failed."
            }
        else
            log "ERROR: Unrecognized package manager."
            exit 1
        fi
    fi
}

install_helm_3=0
helm version --short --client > /dev/null 2>&1 || install_helm_3=1
helm version --short --client | grep "v2" > /dev/null 2>&1 && install_helm_3=1

if [ ${install_helm_3} -eq 1 ]; then
    install_helm_result=0
    log "INFO: Installing helm 3"
    if [ "$(uname)" == "Darwin" ]; then
        brew install helm
    else
        WORKDIR=/tmp
        curl -sL https://get.helm.sh/helm-v3.5.2-linux-amd64.tar.gz | tar xzf - -C "${WORKDIR}" \
            && install "${WORKDIR}/linux-amd64/helm" /usr/local/bin/helm \
            || install_helm_result=1
            
        if [ ${install_helm_result} -eq 1 ]; then
            log "ERROR: helm 3 installation failed."
        fi
    fi
fi

sc_result=0
log "INFO: Starting ShellCheck run"
shellcheck tests/prebuild/*.sh || sc_result=1
log "INFO: Completed ShellCheck run: ${sc_result}"

log "INFO: Starting yamllint run"
yl_result=0
yamllint -c "${scriptdir}/yamllint-config.yaml" config/ || yl_result=1
log "INFO: Completed yamllint run: ${yl_result}"

log "INFO: Starting helm lint run"
hl_result=0
find . -name Chart.yaml \
    | grep -v /config/rhacm/cloudpaks \
    | sed "s|/Chart.yaml||g" \
    | xargs helm lint \
|| hl_result=1
log "INFO: Completed helm lint run: ${hl_result}"

log "INFO: Starting helm template run"
ht_result=0
while read -r chart;
do
    htl=0
    helm template "${chart}" 1> /dev/null || htl=1
    if [ ${htl} -eq 1 ]; then
        ht_result=1;
    fi
done <<< "$(find . -name Chart.yaml \
    | grep -v /config/rhacm/cloudpaks \
    | sed "s|/Chart.yaml||g")"
log "INFO: Completed helm template run: ${ht_result}"

result=$((sc_result+yl_result+hl_result+ht_result))
log "INFO: Global test failures: ${result}"

exit "${result}"
