#!/bin/bash

set -eo pipefail
set -x

original_dir=$PWD
: "${PIPELINE_DEBUG:=0}"
if [ ${PIPELINE_DEBUG} -eq 1 ]; then
    set -x
    env
fi

# Input variables
git_repo=${1}
git_source_branch=${2}
git_target_branch=${3}
release_delta=${4}


#
# Clean up at end of task
#
cleanRun() {
    cd "${original_dir}"
    if [ -n "${WORKDIR}" ]; then
        rm -rf "${WORKDIR}"
    fi
}
trap cleanRun EXIT


echo "${release_delta}"
