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


#
# Extracts only the file names containing differences between the source
# and target branches.
#
function extract_branch() {
    result=1

    #
    # Analyze the differences between branches
    # to determine which Cloud Paks to test
    git clone "${git_repo}" cloudpak-gitops -b "${git_target_branch}"
    cd cloudpak-gitops
    git config pull.rebase false
    git checkout "${git_source_branch}"
    git pull origin "${git_source_branch}"

    return ${result}
}


#
#
#
function merge_and_promote() {
    release_delta=$1

    latest_version=$(git tag -l --sort=version:refname "v*" | tail -n 1)
    latest_major_version=$(echo "${latest_version//.*/}" | cut -d "v" -f 2)
    latest_minor_version=$(echo "${latest_version}" | cut -d "." -f 2)
    latest_patch_version="${latest_version//v*./}"

    delta_major_version="${release_delta//.*/}"
    delta_minor_version=$(echo "${release_delta}" | cut -d "." -f 2)
    delta_patch_version="${release_delta//*./}"

    new_major_version=$((latest_major_version+delta_major_version))
    new_minor_version=$((latest_minor_version+delta_minor_version))
    new_patch_version=$((latest_patch_version+delta_patch_version))

    new_version="v${new_major_version}.${new_minor_version}.${new_patch_version}"

    echo "${new_version}"

}

WORKDIR=$(mktemp -d) || exit 1
cd "${WORKDIR}"

extract_branch
merge_and_promote "${release_delta}"
