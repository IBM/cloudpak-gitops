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
    local result=0

    #
    # Analyze the differences between branches
    # to determine which Cloud Paks to test
    git clone "${git_repo}" cloudpak-gitops \
    && cd cloudpak-gitops \
    && git config pull.rebase false \
    && git checkout "${git_source_branch}" \
    && git pull origin "${git_source_branch}" \
    || result=1

    return ${result}
}


#
# Determines the new release number and creates a draft release with it. 
#
# arg1 - Bump in semver version relative to last tag
#
function merge_and_promote() {
    local release_delta=${1}

    local result=0

    latest_version=$(git tag -l --sort=version:refname "v*" | tail -n 1)
    latest_major_version=$(echo "${latest_version//.*/}" | cut -d "v" -f 2)
    latest_minor_version=$(echo "${latest_version}" | cut -d "." -f 2)
    latest_patch_version="${latest_version//v*./}"

    if [ -n "${release_delta}" ]; then
        delta_major_version="${release_delta//.*/}"
        delta_minor_version=$(echo "${release_delta}" | cut -d "." -f 2)
        delta_patch_version="${release_delta//*./}"
    else
        delta_major_version=0
        delta_minor_version=0
        delta_patch_version=1
    fi

    new_major_version=$((latest_major_version+delta_major_version))
    new_minor_version=$((latest_minor_version+delta_minor_version))
    new_patch_version=$((latest_patch_version+delta_patch_version))

    new_version="v${new_major_version}.${new_minor_version}.${new_patch_version}"

    squash_title=$(gh pr view "${git_source_branch}" \
        --repo "${git_repo}" \
        --json title \
        -t '{{.title}}') \
    && squash_body=$(gh pr view "${git_source_branch}" \
        --repo "${git_repo}" \
        --json body \
        -t '{{.body}}') \
    && gh pr merge "${git_source_branch}" \
        --repo "${git_repo}" \
        -b "${squash_body}" \
        -t "${squash_title}" \
        --squash \
        --auto \
    && merge_id=$(gh pr view "${git_source_branch}" \
        --repo "${git_repo}" \
        --json mergeCommit \
        -t '{{.mergeCommit.oid}}') \
    && git remote -v \
    && git config user.name "GitHub Actions Bot" \
    && git config user.email "<>" \
    && git pull \
    && git tag \
        -m "${squash_title}" \
        "${new_version}" \
        "${merge_id}" \
    && git push "${git_repo/\/\////GitHub\ Actions\ Bot:$GITHUB_TOKEN@}" "${new_version}" \
    && gh release create "${new_version}" \
        --repo "${git_repo}" \
        --prerelease \
        --draft \
        --generate-notes \
        --target "${merge_id}" \
        --title "Release ${new_version}" \
    || result=1

    echo "${new_version}"

    return ${result}
}

WORKDIR=$(mktemp -d) || exit 1
cd "${WORKDIR}"

extract_branch

is_draft=$(gh pr view "${git_source_branch}" --repo "${git_repo}" --json isDraft -t '{{.isDraft}}')
if [ "${is_draft}" == "true" ]; then
    echo "Pull request is still a draft. Skipping"
    gh pr view "${git_source_branch}"
else
    merge_and_promote "${release_delta}"
fi
