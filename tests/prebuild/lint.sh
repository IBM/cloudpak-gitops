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
            || log "ERROR: yamllint installation failed"
    }
}

result=0

log "INFO: Starting yamllint run"
yamllint -c "${scriptdir}/yamllint-config.yaml" config/ || result=1
log "INFO: Completed yamllint run"

exit "${result}"
