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

# Output variables
labels=cp-shared:ibm-cloudpaks
workers=3
setup_gps=false

# Output files
labels_output_file="${original_dir}/test-sh-labels.txt"
workers_output_file="${original_dir}/test-sh-workers.txt"
gps_output_file="${original_dir}/test-sh-gps.txt"


#
# Extracts only the file names containing differences between the source
# and target branches.
#
function extract_branch_delta() {
    local output_file=${1}

    local result=1

    #
    # Analyze the differences between branches
    # to determine which Cloud Paks to test
    cd "${WORKDIR}"
    git clone "${git_repo}" cloudpak-gitops
    cd cloudpak-gitops
    git config pull.rebase false
    git checkout "${git_source_branch}"
    git pull origin "${git_source_branch}"
    git diff "${git_target_branch}" --name-only | tee "${output_file}" \
        && result=0
    cd "${original_dir}"

    return ${result}
}

WORKDIR=$(mktemp -d) || exit 1

branch_delta_output_file="${WORKDIR}/diff.txt"
extract_branch_delta "${branch_delta_output_file}"
# As of CP4D 4.0.6, cp4d has to be last
for cloudpak in cp4i cp4a cp4aiops cp4s cp4d
do
    if grep "/${cloudpak}/" "${branch_delta_output_file}"; then
        labels="${labels},${cloudpak}:${cloudpak}"
        workers=$((workers+3))
        if [ "${cloudpak}" == "cp4d" ]; then
            setup_gps=true
        fi
    fi
done

echo ${labels}

echo "${labels}" > "${labels_output_file}"
echo "${workers}" > "${workers_output_file}"
echo "${setup_gps}" > "${gps_output_file}"
