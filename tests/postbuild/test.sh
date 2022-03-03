#!/bin/bash

set -eo pipefail
set -x

original_dir=$PWD
: "${PIPELINE_DEBUG:=0}"
if [ ${PIPELINE_DEBUG} -eq 1 ]; then
    set -x
    env
fi

git_repo=${1}
git_source_branch=${2}
git_target_branch=${3}

WORKDIR=$(mktemp -d) || exit 1
cd "${WORKDIR}"

#
# Analyze the differences between branches
# to determine which Cloud Paks to test
git clone "${git_repo}" cloudpak-gitops
cd cloudpak-gitops
git config pull.rebase false
git checkout "${git_source_branch}"
git pull origin "${git_source_branch}"
git diff "${git_target_branch}" --name-only | tee "${WORKDIR}/diff.txt"

labels=cp-shared:ibm-cloudpaks
for i in cp4i cp4d cp4a cp4aiops
do
    if grep "/$i/" "${WORKDIR}/diff.txt"; then
        labels="${labels},$i:$i"
    fi
done

echo ${labels}

echo "${labels}" > "${original_dir}/labels.txt"

