#!/bin/bash
set -eo pipefail

original_dir=$PWD
scriptname=$(basename "${0}")
scriptdir=$(dirname "${0}")

verbose=0
oc_cmd=$(type -p oc)

#
# Input parameters
#
: "${BUILD_NUMBER:=0001}"
: "${TOOLCHAIN_ID:=0001}"
: "${PIPELINE_RUN:=0001}"

: "${NEW_CLUSTER_TYPE:=fyre-quick-burn}"
: "${WORKER_FLAVOR:=medium}"
: "${OCP_VERSION:=4.8}"

# In hours
: "${CLUSTER_EXPIRATION:=12}"
: "${CLUSTER_SITE:=svl}"
: "${FYRE_SITE:=${CLUSTER_SITE}}"

: "${FYRE_PRODUCT_GROUP:=416}"
: "${FYRE_EXPIRATION:=${CLUSTER_EXPIRATION}}"

: "${IBM_CLOUD_EXPIRATION:=${CLUSTER_EXPIRATION}}"
# https://ibm.biz/flavors

: "${IBM_CLOUD_CLUSTER_VPC_STORAGE_ID:=sdlc-cluster-storage}"

: "${ROSA_VERSION:=${OCP_VERSION}}"
# https://aws.amazon.com/ec2/instance-types/

# Parameters for creating new cluster
# For early releases, use subpaths in https://mirror.openshift.com/pub/openshift-v4/dependencies/rhcos/pre-release/
# like "latest", "latest-4.8" and "4.8.0-fc.4"
: "${ROF_VERSION:=${OCP_VERSION}}"

: "${ROKS_VERSION:=${OCP_VERSION}}"

: "${CLUSTER_WORKERS:=3}"
: "${CLUSTER_DISK:=50}"
: "${HARDWARE_MODE:=shared}"

: "${DOCKER_REPO:=docker.io}"
: "${US_ICR_IO_REPO:=us.icr.io}"
: "${CP_STG_ICR_IO_REPO:=cp.stg.icr.io}"
: "${CP_ICR_IO_REPO:=cp.icr.io}"
: "${ICP_ARTIFACTORY_DAILY_REPO:=hyc-cloud-private-daily-docker-local.artifactory.swg-devops.com}"

storage_type="default"

#
# Usage statement
#
function usage() {
    set +x
    echo "Manages OCP clusters."
    echo ""
    echo "Usage: ${scriptname} [OPTIONS]...[ARGS]"
    echo
    echo "   -t | --type <aro|aws|azure|fyre|fyre-quick-burn|ibmcloud|ibmcloud-gen2|ocp|rosa>"
    echo "                      Indicates the type of cluster to be built or configured. Default is: ${NEW_CLUSTER_TYPE}"
    echo "   -r | --rhacm-server <server_name>"
    echo "                      Uses RHACM to create the cluster. "
    echo "   -n | --cluster <name>"
    echo "                      Target cluster for the operation."
    echo "   -c | --create"
    echo "                      Creates a new cluster."
    echo "   -d | --delete"
    echo "                      Deletes an existing cluster."
    echo "   -s | --status"
    echo "                      Checks status of cluster."
    echo "        --config"
    echo "                      Configures cluster for Cloud Pak installation."
    echo "   -e | --ensure"
    echo "                      Ensures a cluster exists and is configured."
    echo "                      Equivalent to consecutive invocations of the script with"
    echo "                      --status, --create, and --config."
    echo "        [--backup-agent]"
    echo "                      Companion to the --config command."
    echo "                      Adds the Velero backup agent to the cluster."
    echo "   -g | --global-pull-secret <true|false>"
    echo "                      Companion to the --config command."
    echo "                      Adds Entitlement Registry key to the cluster's global pull secret."
    echo "        [--custom-pki]"
    echo "                      Companion to the --config command."
    echo "                      Configures the server consoles with a signed certificate."
    echo "        --cos-apikey"
    echo "                      Companion to the --backup-agent command."
    echo "                      API Key for the IBM Cloud account hosting the target backup cluster."
    echo "        --ocp-version <version>"
    echo "                      Companion to the --create command."
    echo "                      Version for the OCP cluster, such as 4, 4.9, or 4.9.13."
    echo "                      Unspecified minor versions or patch will be filled with"
    echo "                      the latest minor version or patch available in the target provider."
    echo "                      Default value is ${OCP_VERSION}."
    echo "        --workers <number>"
    echo "                      Companion to the --create command."
    echo "                      Number of workers for the default cluster worker pool."
    echo "                      Default value is ${CLUSTER_WORKERS}."
    echo "        [--worker-flavor <flavor>]"
    echo "                      Companion to the --create command."
    echo "                      Flavor (cpu/mem size) of workers, specific to the cloud provider."
    echo "        [--autoscale-workers <number>]"
    echo "                      Companion to the --create command, exclusive for ROKS clusters."
    echo "                      Maximum number of workers in an autoscale worker pool."
    echo "                      If unset or set to 0, autoscaling is not enabled."
    echo "        [--autoscale-worker-flavor <flavor>]"
    echo "                      Companion to the --create command, exclusive for ROKS clusters."
    echo "                      Flavor of workers when requesting autoscale nodes."
    echo "        [--storage <type>]"
    echo "                      Companion to the --config command."
    echo "                      Choice of storage for the target platform."
    echo "                      The choices are:"
    echo "                      \"default\": rook-cephfs for fyre, ibmc-file for ibmcloud, "
    echo "                      ODF for ibmcloud-gen2, aws, rosa, gcp."
    echo "                      \"none\": No additional storage added to the cluster."
    echo "                      If not specified, the default choice is \"${storage_type}\"."
    echo "        [--upgrade-cluster]"
    echo "                      Companion to the --config command."
    echo "                      Upgrades cluster to latest version after creation."
    echo "   -u | --username"
    echo "                      User for cluster owner if the cluster type is \"fyre\""
    echo "   -w | --wait"
    echo "                      Wait for cluster provisioning."
    echo "   -a | --apikey"
    echo "                      API Key in the target platform"
    echo "        --ocp-token"
    echo "                      Key or token for managed OCP platform if not ROKS."
    echo "   -l | --managed-cluster-labels <label1, label2, ..., labelN>"
    echo "                      Companion to the --create command."
    echo "                      Comma-separated list of labels for the cluster."
    echo ""
    echo "   -v | --verbose    Prints extra information about each command."
    echo "   -h | --help       Output this usage statement."

    if [ "${PIPELINE_DEBUG}" -eq 1 ]; then
        set -x
    fi
}

# shellcheck disable=SC1090
# shellcheck disable=SC1091
source "${scriptdir}/common.sh"

# shellcheck disable=SC1090
# shellcheck disable=SC1091
source "${scriptdir}/create-ocs-storageclass.sh"

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
# Adds the IBM Operator Catalog to the cluster.
#
# https://github.com/IBM/cloud-pak/blob/master/reference/operator-catalog-enablement.md
#
function add_ibm_operator_catalog() {
    local result=0

    # https://redhat-developer.github.io/redhat-helm-charts/

    log "INFO: Adding the IBM Operator Catalog to the cluster." 
    local use_helm_enablement=0
    if [ ${use_helm_enablement} -eq 1 ]; then
        # Avoiding Red Hat helm enablement due to general instability.
        result=1
        curl -sL https://get.helm.sh/helm-v3.5.2-linux-amd64.tar.gz | tar xzf - -C "${WORKDIR}" \
            && mv "${WORKDIR}/linux-amd64/helm" /usr/local/bin/helm \
            && helm repo add redhat-charts https://redhat-developer.github.com/redhat-helm-charts \
            && helm install ibm-operator-catalog redhat-charts/ibm-operator-catalog-enablement \
                --set license=true \
            && result=0
    else
        local catalog_json="${WORKDIR}/catalog.json"
        cat << EOF > "${catalog_json}"
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ibm-operator-catalog
  namespace: openshift-marketplace
spec:
  displayName: IBM Operator Catalog
  publisher: IBM
  sourceType: grpc
  image: docker.io/ibmcom/ibm-operator-catalog:latest
  updateStrategy:
    registryPoll:
      interval: 45m
EOF

        "${oc_cmd}" apply -f "${catalog_json}" || result=1
    fi
    if [ "${result}" -eq 0 ]; then
        log "INFO: Catalog charts installed. Waiting for READY status."
        local current_seconds=0
        local operation_limit_seconds=$(( $(date +%s) + 1200 ))
        result=1
        while [ ${current_seconds} -lt ${operation_limit_seconds} ]; do
            if [ "$("${oc_cmd}" get catalogsource ibm-operator-catalog \
                    --namespace openshift-marketplace \
                    -o jsonpath="{.status.connectionState.lastObservedState}")" == "READY" ]; then 
                result=0
                break
            fi
            log "INFO: Waiting for the IBM Operator Catalog to be ready."
            sleep 20
            current_seconds=$(( $(date +%s) ))
        done
    fi

    if [ "${result}" -eq 0 ]; then
        log "INFO: IBM Operator Catalog added to the cluster."
    else
        log "SEVERE: IBM Operator Catalog could not be added to the cluster."
        "${oc_cmd}" get CatalogSource --namespace openshift-marketplace
    fi

    return ${result}
}


#
# Adds a new secret to a docker json config file
#
# arg1 config file to be modified
# arg2 registry URL
# arg3 registry key
# arg4 registry password
# arg5 registry email
# arg6 indicates whether the secret is required 
#      (0=not required, 1=required)
#
function add_pull_secret() {
    local config_file="${1}"
    local registry_url=${2}
    local registry_user=${3}
    local registry_pwd=${4}
    local registry_email=${5}
    local required=${6:-0}

    local result=0

    if [ -z "${registry_user}" ] || [ -z "${registry_pwd}" ]; then
        if [ "${required}" -eq 1 ]; then
            log "ERROR: Missing registry parameters for registry [${registry_url}]" 
            return 1
        else
            log "INFO: Optional registry parameters for registry [${registry_url}] not supplied. Skipping." 
            return 0
        fi
    fi

    local temp_config_file="${WORKDIR}/temp-global-pull-secret.yaml"
    local new_auth
    new_auth=$(${oc_cmd} create secret docker-registry temp-secret \
        --docker-server="${registry_url}" \
        --docker-username="${registry_user}" \
        --docker-password="${registry_pwd}" \
        --docker-email="${registry_email}" \
        --dry-run=client \
        --output json \
        | jq -cr '.data.".dockerconfigjson"' \
        | base64 -d) || result=1
    jq ".auths += ${new_auth}.auths" "${config_file}" > "${temp_config_file}" || result=1
    if [ ${result} -eq 0 ]; then
        mv "${temp_config_file}" "${config_file}"
    fi

    return ${result}
}


#
# Modifies OCP global configuration to add pull secrets
#
function setup_global_pull_secrets() {

    local result=0

    local gps_file="${WORKDIR}/global-pull-secret.yaml"
    ${oc_cmd} get secret/pull-secret \
          --namespace openshift-config \
            --output "jsonpath={.data.\.dockerconfigjson}" \
        | base64 -d \
        | jq -cr . > "${gps_file}"

    local registry_optional=0
    local registry_required=1
    local registry_email="cicd@nonexistent.email.ibm.com"
    add_pull_secret "${gps_file}" \
        "${CP_ICR_IO_REPO}" \
        "${CP_ICR_IO_USERID}" \
        "${CP_ICR_IO_PASSWORD}"  \
        "${registry_email}" \
        ${registry_required} || result=1

    add_pull_secret "${gps_file}" \
        "${CP_STG_ICR_IO_REPO}" \
        "${CP_STG_ICR_IO_USERID}" \
        "${CP_STG_ICR_IO_PASSWORD}"  \
        "${registry_email}" \
        ${registry_optional} || result=1

    add_pull_secret "${gps_file}" \
        "${DOCKER_REPO}" \
        "${DOCKER_USERID}" \
        "${DOCKER_PASSWORD}" \
        "${registry_email}" \
        ${registry_optional} || result=1    

    add_pull_secret "${gps_file}" \
        "${US_ICR_IO_REPO}" \
        "${US_ICR_IO_USERID}" \
        "${US_ICR_IO_PASSWORD}"  \
        "${registry_email}" \
        ${registry_optional} || result=1

    add_pull_secret "${gps_file}" \
        "${ICP_ARTIFACTORY_DAILY_REPO}" \
        "${ARTIFACTORY_USER}" \
        "${ARTIFACTORY_APIKEY}" \
        "${registry_email}" \
        ${registry_optional} || result=1

    if [ ${result} -eq 0 ]; then
        log "INFO: Updating global pull secrets"
        ${oc_cmd} set data secret/pull-secret \
            --namespace openshift-config \
            --from-file=.dockerconfigjson="${gps_file}" || result=1
        if [ ${result} -eq 0 ]; then
            log "INFO: Updated global pull secrets"
        else
            log "ERROR: Update to global pull secrets failed."
        fi
    fi

    return ${result}
}


#
# Confgures the target IBM Cloud cluster with the autoscale addon.
#
# arg1 name of the cluster to be configured
# arg2 name of the autoscale worker pool
# arg3 max number of workers in the autoscale pool
#
function config_ibm_cloud_autoscale() {
    local cluster_name=${1}
    local worker_pool_name=${2}
    local autoscale_cluster_workers=${3}

    local result=0

    local add_addon=0
    local addon_output="${WORKDIR}/addon_output.txt"
    ibmcloud ks cluster addon ls --cluster="${cluster_name}" -q > "${addon_output}" 2>&1 \
    || {
        log "ERROR: Unable to list the cluster addons."
        return 1
    }

    grep cluster-autoscaler "${addon_output}" \
    && log "INFO: Auto-scaler add-on already added to the cluster." \
    || add_addon=1

    if [ ${add_addon} -eq 1 ]; then
        ibmcloud ks cluster addon enable cluster-autoscaler \
            --cluster "${cluster_name}" \
        && log "INFO: Added cluster-autoscaler." \
        || result=1
    fi

    if [ ${result} -eq 0 ]; then
        if [ ${add_addon} -eq 1 ]; then
            local addon_status=""
            local addon_file="${WORKDIR}/addon.json"
            while [ "${addon_status}" != "normal" ]
            do
                log "INFO: Waiting for autoscale addon status to be ready."
                sleep 30
                ibmcloud ks cluster addon ls \
                    --cluster "${cluster_name}" \
                    --output=json > "${addon_file}" \
                && addon_status=$(jq -r '.[] | select(.name=="cluster-autoscaler") .healthState' "${addon_file}") \
                && log "INFO: Addon status: ${addon_status}"
            done
        fi

        "${oc_cmd}" get pods --namespace=kube-system | grep ibm-iks-cluster-autoscaler \
            && "${oc_cmd}" get service --namespace=kube-system | grep ibm-iks-cluster-autoscaler

        local autoscale_config="${WORKDIR}/autoscale-config.json"
        # https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/config/autoscaling_options.go
        "${oc_cmd}" get cm iks-ca-configmap \
            -n kube-system \
            -o jsonpath="{.data.workerPoolsConfig\.json}" > "${autoscale_config}" \
        || result=1

        if [ ${result} -eq 0 ]; then
            local new_autoscale_config="${WORKDIR}/autoscale-config-new.json"
            if ! grep "${worker_pool_name}" "${autoscale_config}"; then
                jq --argjson max "${autoscale_cluster_workers}" \
                   --arg pool_name "${worker_pool_name}" \
                   '. +=  [{"name": $pool_name, "minSize": 2, "maxSize": $max, "enabled":true}]' "${autoscale_config}" > "${new_autoscale_config}" \
                && "${oc_cmd}" set data cm iks-ca-configmap \
                    -n kube-system \
                    --from-file=workerPoolsConfig\.json="${new_autoscale_config}" \
                && log "INFO: Updated IKS autoscaler configuration for cluster." \
                || result=1
            else
                log "WARNING: Cluster autoscaled pool already configured."
                jq . "${autoscale_config}"
            fi
        else
            log "ERROR: Unable to get cluster autoscale configuration data."
        fi
    fi

    if [ ${verbose} -eq 1 ]; then
        log "DEBUG: Attempting to describe the autoscaling pod."
        "${oc_cmd}" describe pod -l app=ibm-iks-cluster-autoscaler -n kube-system || true
    fi

    return ${result}
}


#
# Creates a new cluster in the target zone
#
# arg1 type of cluster, e.g. ibmcloud or ibmcloud-gen2
# arg2 name of the cluster to be created.
# arg3 number of workers for the cluster
# arg4 flavor of workers for the cluster
# arg5 number of autoscaled workers for the cluster
# arg6 flavor of autoscaled workers for the cluster
# arg7 username for the target cloud
# arg8 apikey for the target cloud
# arg9 deployment zone for the new cluster
# arg10 whether or not to wait for the cluster to be up if still being created
#       1=wait | 0=do not wait
#
function create_ibm_cloud_cluster() {
    local cluster_type=${1}
    local cluster_name=${2}
    local cluster_workers=${3}
    local worker_flavor=${4}
    local autoscale_cluster_workers=${5}
    local autoscale_worker_flavor=${6}
    local username=${7}
    local api_key=${8}
    local cluster_zone=${9}
    local wait_cluster=${10:-0}

    local result=0

    login_ibm_cloud "" "${username}" "${api_key}" || return 1

    local roks_version
    roks_version=$(ibmcloud oc versions -s \
        | grep "^${ROKS_VERSION}\..*openshift" \
        | cut -d " " -f 1 \
        | sort --version-sort -r \
        | head -n 1)

    if [ -z "${roks_version}" ]; then
        log "ERROR: No suitable OCP version matching minor release [${ROKS_VERSION}]:"
        json "${ocp_contents}"
        return 1
    fi

    log "INFO: Creating IBM Cloud cluster [${cluster_name}] with version [${roks_version}]."
    case ${cluster_type} in
        ibmcloud)
            local private_vlan=""
            local public_vlan=""
            local vlan_json="${WORKDIR}/vlan.json"
            ibmcloud ks vlan ls --zone "${cluster_zone}" --output json > "${vlan_json}" \
            && private_vlan=$(jq -r '.[] | select(.type=="private") .id'  "${vlan_json}" | head -n 1) \
            && public_vlan=$(jq -r '.[] | select(.type=="public") .id'  "${vlan_json}" | head -n 1) \
            || result=1

            local private_vlan_param=()
            local public_vlan_param=()
            if [ "${private_vlan}" != "" ]; then 
                private_vlan_param=(--private-vlan "${private_vlan}")
            fi
            if [ "${public_vlan}" != "" ]; then 
                public_vlan_param=(--public-vlan "${public_vlan}")
            fi

            if [ ! ${result} -eq 0 ]; then
                log "ERROR: Unable to determine all VLAN parameters to create the cluster."
                return ${result}
            fi

            ibmcloud oc cluster create classic \
                --name "${cluster_name}" \
                --version "${roks_version}" \
                --zone "${cluster_zone}" \
                --flavor "${worker_flavor}" \
                --hardware "${HARDWARE_MODE}" \
                --workers "${cluster_workers}" \
                --entitlement cloud_pak \
                "${private_vlan_param[@]}" \
                "${public_vlan_param[@]}" || result=1
        ;;
        ibmcloud-gen2)
            local vpc_id=""
            local subnet_id=""
            local vlan_json="${WORKDIR}/vpc.json"
            ibmcloud ks vpcs --provider vpc-gen2 --output json > "${vlan_json}" || result=1
            if [ ${result} -eq 0 ]; then
                vpc_id=$(jq -r --arg vpc "${IBM_CLOUD_CLUSTER_VPC}" '.[] | select(.name==$vpc) .id'  "${vlan_json}") || 
                {
                    result=1
                    log "ERROR: Unable to find VPC id for ${IBM_CLOUD_CLUSTER_VPC}"
                }

                if [ -n "${vpc_id}" ]; then
                    subnet_id=$(ibmcloud ks subnets --provider vpc-gen2 --vpc-id "${vpc_id}" --zone "${cluster_zone}" --output JSON | jq -r --arg subnet "${IBM_CLOUD_CLUSTER_VPC_SUBNET}" '.[] | select(.name==$subnet) .id') || 
                    {
                        result=1
                        log "ERROR: Unable to find VPC subnet id for ${IBM_CLOUD_CLUSTER_VPC_SUBNET}"
                    }
                fi
            fi

            local storage_crn=""
            local storage_json="${WORKDIR}/storage.json"
            ibmcloud resource service-instances --output json  > "${storage_json}" || result=1
            if [ ${result} -eq 0 ]; then
                storage_crn=$(jq -r --arg storage_name "${IBM_CLOUD_CLUSTER_VPC_STORAGE_ID}" '.[] | select(.name==$storage_name) .id' "${storage_json}") || 
                {
                    result=1
                    log "ERROR: Unable to find storage [${IBM_CLOUD_CLUSTER_VPC_STORAGE_ID}] for new cluster."
                }
            fi

            if [ ! ${result} -eq 0 ]; then
                log "ERROR: Unable to determine all VPC parameters to create the cluster."
                return ${result}
            fi

            ibmcloud oc cluster create vpc-gen2 \
                --name "${cluster_name}" \
                --version "${roks_version}" \
                --zone "${cluster_zone}" \
                --flavor "${worker_flavor}" \
                --workers "${cluster_workers}" \
                --entitlement cloud_pak \
                --vpc-id "${vpc_id}" \
                --subnet-id "${subnet_id}" \
                --cos-instance "${storage_crn}" || result=1
        ;;
        *)
        echo "Unrecognized cluster type: ${cluster_type}"
        return 1
    esac

    local cluster_json_file="${WORKDIR}/cluster-${cluster_name}.json"
    local cluster_get=0
    ibmcloud oc cluster get -q --cluster "${cluster_name}" --output json > "${cluster_json_file}" \
        || cluster_get=1
    if [ "${result}" -eq 0 ] && [ "${cluster_get}" -eq 0 ]; then 
        log "INFO: Cluster creation request succeeded."
        local cluster_crn
        cluster_crn=$(jq -r .crn "${cluster_json_file}")

        local toolchain_id
        local pipeline_run
        local pipeline_region
        toolchain_id="${TOOLCHAIN_ID}"
        pipeline_run="${PIPELINE_RUN}"
        pipeline_region="${PIPELINE_RUN_URL/*yp:/}"

        # https://cloud.ibm.com/docs/key-protect?topic=key-protect-retrieve-access-token 
        local access_token
        access_token=$(curl -s -X POST \
            "https://iam.cloud.ibm.com/identity/token" \
            -H "content-type: application/x-www-form-urlencoded" \
            -H "accept: application/json" \
            -d "grant_type=urn%3Aibm%3Aparams%3Aoauth%3Agrant-type%3Aapikey&apikey=${api_key}" | \
            jq -r .access_token)

        # https://cloud.ibm.com/apidocs/tagging#attach-one-or-more-tags
        local tagging_contents="${WORKDIR}/${cluster_name}-tagging.json"
        local http_status
        http_status=$(curl -sX POST "https://tags.global-search-tagging.cloud.ibm.com/v3/tags/attach" \
            --header "accept: application/json" \
            --header "content-type: application/json" \
            --header "authorization: Bearer ${access_token}" \
            -d "{\"tag_names\": [\"toolchain-id:${toolchain_id}\", \"pipeline-run:${pipeline_run}\", \"pipeline-region:${pipeline_region}\", \
            \"build-number:${BUILD_NUMBER}\", \"expiration:${IBM_CLOUD_EXPIRATION}h\"], \"resources\": [ { \"resource_id\": \"${cluster_crn}\" } ] }" \
            -w "%{http_code}" \
            -o "${tagging_contents}")
        if [ ! "${http_status}" == "200" ]; then
            log "ERROR: Tagging of new cluster [${cluster_name}] failed."
            cat "${tagging_contents}"
            result=1
        fi

        if [ "${wait_cluster}" -eq 1 ] \
            || [ "${autoscale_cluster_workers}" -gt 0 ] \
            || [ "${cluster_type}" == "ibmcloud-gen2" ]; then
            wait_for_ibm_cloud_cluster "${cluster_name}" \
                || result=1
        fi
    else
        log "ERROR: Creation of cluster [${cluster_name}] failed."
        result=1
    fi

    if [ ${result} -eq 0 ] && [ "${autoscale_cluster_workers}" -gt 0 ]; then
        log "INFO: Setting up auto-scaling on cluster."
        login_ibm_cloud "${cluster_name}" "${username}" "${api_key}" || \
        {
            log "WARNING: Workaround for IBM login woes."
            sleep 240
            login_ibm_cloud "${cluster_name}" "${username}" "${api_key}" \
                || return 1
        }

        if ! kubectl get secrets -n kube-system | grep storage-secret-store; then
            log "ERROR: Storage secret store not configured for auto-scaling."
            result=1
        else
            local worker_pool_name=autoscale
            if [ "${cluster_type}" == "ibmcloud" ]; then
                # https://cloud.ibm.com/docs/containers?topic=containers-ca
                ibmcloud ks worker-pool create classic \
                    --cluster "${cluster_name}" \
                    --entitlement cloud_pak \
                    --flavor "${autoscale_worker_flavor}" \
                    --label node-role.kubernetes.io/worker="" \
                    --name ${worker_pool_name} \
                    --size-per-zone 2 \
                && ibmcloud ks zone add classic \
                    --cluster "${cluster_name}" \
                    --worker-pool ${worker_pool_name} \
                    --zone "${cluster_zone}" \
                    "${private_vlan_param[@]}" \
                    "${public_vlan_param[@]}" \
                || result=1
            elif [ "${cluster_type}" == "ibmcloud-gen2" ]; then
                # https://cloud.ibm.com/docs/containers?topic=containers-add_workers#vpc_pools
                ibmcloud ks worker-pool create vpc-gen2 \
                    --cluster "${cluster_name}" \
                    --entitlement cloud_pak \
                    --flavor "${autoscale_worker_flavor}" \
                    --label node-role.kubernetes.io/worker="" \
                    --name ${worker_pool_name} \
                    --size-per-zone 2 \
                && ibmcloud ks zone add vpc-gen2 \
                    --cluster "${cluster_name}" \
                    --subnet-id "${subnet_id}" \
                    --worker-pool ${worker_pool_name} \
                    --zone "${cluster_zone}" \
                || result=1
            else
                log "ERROR: Unsupported cluster type: ${cluster_type}."
                result=1
            fi

            if [ ${result} -eq 0 ]; then
                config_ibm_cloud_autoscale "${cluster_name}" "${worker_pool_name}" "${autoscale_cluster_workers}" || {
                    log "ERROR: Unable to add autoscaler worker pool."
                    result=1
                }
            fi
        fi
    fi

    if [ ${result} -eq 0 ]; then
        ibm_cloud_cmd_workers "${cluster_type}" "${cluster_name}" "check" 
    fi

    return ${result}
}


#
# Creates the payload for creating  Fyre cluster
# 
# arg1 name of the target file
# arg2 number of workers for the cluster
# arg3 worker size for the cluster
# arg4 version of the new OCP cluster
# arg5 whether the new version is experimental
#
function create_fyre_payload() {
    local cluster_creation_file=${1}
    local workers=${2}
    local cluster_size=${3}
    local ocp_version=${4}
    local ocp_experimental=${5}

    #  Reference API: https://w3.ibm.com/w3publisher/devit/fyre/ocp/ocp-apis

    local additional_disk=${CLUSTER_DISK}
    local expiration_time_hours=${FYRE_EXPIRATION}

    local cpus=8
    local memory=16
    case ${cluster_size} in
        medium)
            cpus=8
            memory=16
            ;;
        large)
            cpus=16
            memory=32
            ;;
        extra-large)
            cpus=16
            memory=64
            ;;
        *)
            log "ERROR: Unknown size of Fyre cluster: [${cluster_size}]. Allowed values are \"medium,\" \"large,\" and \"extra-large.\""
            return 1
    esac

    local toolchain_id
    local pipeline_run
    local pipeline_region
    toolchain_id="${TOOLCHAIN_ID}"
    pipeline_run="${PIPELINE_RUN}"
    pipeline_region="${PIPELINE_RUN_URL/*yp:/}"
    local description="toolchain-id:${toolchain_id}, pipeline-run:${pipeline_run}, pipeline-region:${pipeline_region}, sdlc:${BUILD_NUMBER}"

    if [ "${ocp_experimental}" -eq 0 ]; then
        if [ ${NEW_CLUSTER_TYPE} == "fyre-quick-burn" ]; then
            cat<<-EOF > "${cluster_creation_file}" 
            {
                "product_group_id": "${FYRE_PRODUCT_GROUP}",
                "name": "${cluster_name}",
                "description": "${description}",
                "quota_type": "quick_burn",
                "time_to_live": "${expiration_time_hours}",
                "size": "${cluster_size}",
                "ocp_version": "${ocp_version}",
                "expiration": "${expiration_time_hours}",
                "site": "${FYRE_SITE}"
            }
EOF
        else
            cat<<EOF > "${cluster_creation_file}"
            {
                "product_group_id": "${FYRE_PRODUCT_GROUP}",
                "name": "${cluster_name}",
                "description": "${description}",
                "ocp_version": "${ocp_version}",
                "expiration": "${expiration_time_hours}",
                "site": "${FYRE_SITE}",
                "worker": [
                    {
                        "cpu": "${cpus}",
                        "count": "${workers}",
                        "memory": "${memory}",
                        "additional_disk":  [
                            "${additional_disk}"
                        ]
                    }
                ]
            }
EOF
        fi 
    
    else
        local ocp_version_path=${ocp_version}
        local ocp_dependencies_version_path=${ocp_version}
        if [ "${ocp_version}" == "4.7" ]; then
            ocp_dependencies_version_path="latest-4.7"
            ocp_version_path="candidate-4.7"
        fi
        if [ ${NEW_CLUSTER_TYPE} == "fyre-quick-burn" ]; then
            cat<<EOF > "${cluster_creation_file}"
            {
                "product_group_id": "${FYRE_PRODUCT_GROUP}",
                "name": "${cluster_name}",
                "description": "${description}",
                "quota_type": "quick_burn",
                "time_to_live": "${expiration_time_hours}",
                "size": "${cluster_size}",
                "expiration": "${expiration_time_hours}",
                "platform": "x",
                "site": "${FYRE_SITE}",
                "fips": "no",
                "ssh_key": "/root/.ssh/id_rsa.pub",
                "custom_ocp":"yes",
                "kernel_url": "https://mirror.openshift.com/pub/openshift-v4/dependencies/rhcos/pre-release/${ocp_dependencies_version_path}/rhcos-live-kernel-x86_64",
                "initramfs_url": "https://mirror.openshift.com/pub/openshift-v4/dependencies/rhcos/pre-release/${ocp_dependencies_version_path}/rhcos-live-initramfs.x86_64.img",
                "metal_url":"https://mirror.openshift.com/pub/openshift-v4/dependencies/rhcos/pre-release/${ocp_dependencies_version_path}/rhcos-metal.x86_64.raw.gz",
                "rootfs_url": "https://mirror.openshift.com/pub/openshift-v4/dependencies/rhcos/pre-release/${ocp_dependencies_version_path}/rhcos-live-rootfs.x86_64.img",
                "install_url":"https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${ocp_version_path}/openshift-install-linux.tar.gz",
                "client_url":"https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${ocp_version_path}/openshift-client-linux.tar.gz"
            }
EOF
        else
            cat<<EOF > "${cluster_creation_file}"
            {
                "product_group_id": "${FYRE_PRODUCT_GROUP}",
                "name": "${cluster_name}",
                "description": "${description}",
                "expiration": "${expiration_time_hours}",
                "platform": "x",
                "site": "${FYRE_SITE}",
                "fips": "no",
                "ssh_key": "/root/.ssh/id_rsa.pub",
                "custom_ocp":"yes",
                "kernel_url": "https://mirror.openshift.com/pub/openshift-v4/dependencies/rhcos/pre-release/${ocp_dependencies_version_path}/rhcos-live-kernel-x86_64",
                "initramfs_url": "https://mirror.openshift.com/pub/openshift-v4/dependencies/rhcos/pre-release/${ocp_dependencies_version_path}/rhcos-live-initramfs.x86_64.img",
                "metal_url":"https://mirror.openshift.com/pub/openshift-v4/dependencies/rhcos/pre-release/${ocp_dependencies_version_path}/rhcos-metal.x86_64.raw.gz",
                "rootfs_url": "https://mirror.openshift.com/pub/openshift-v4/dependencies/rhcos/pre-release/${ocp_dependencies_version_path}/rhcos-live-rootfs.x86_64.img",
                "install_url":"https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${ocp_version_path}/openshift-install-linux.tar.gz",
                "client_url":"https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${ocp_version_path}/openshift-client-linux.tar.gz",
                "worker": [
                    {
                        "cpu": "${cpus}",
                        "count": "${workers}",
                        "memory": "${memory}",
                        "additional_disk":  [
                            "${additional_disk}"
                        ]
                    }
                ]
            }
EOF
        fi
    fi

    if [ "${verbose}" -eq 1 ]; then
        json "${cluster_creation_file}"
    fi
}


#
# Creates a new cluster on Fyre platform.
#
# arg1 name of the cluster to be checked
# arg2 number of workers for the cluster
# arg3 worker size for the cluster
# arg4 username for the target cloud
# arg5 apikey for the target cloud
# arg6 whether or not to wait for the cluster to be up if still being created
#      1=wait | 0=do not wait
#
function create_fyre_cluster() {
    local cluster_name=${1}
    local cluster_workers=${2}
    local cluster_worker_size=${3}
    local username=${4}
    local api_key=${5}
    local wait_cluster=${6:-0}

    local result=0

    local ocp_contents=${WORKDIR}/fyre_ocp.json && touch "${ocp_contents}"
    local http_check_status
    http_check_status=$(curl -s -k -u "${username}:${api_key}" "https://ocpapi.svl.ibm.com/v1/check_hostname/${cluster_name}" \
        --header "accept: application/json" \
        -w "%{http_code}" \
        -o "${ocp_contents}") || result=1
    if [ "${http_check_status}" == "200" ]; then
        local name_status
        name_status=$(jq -r .status "${ocp_contents}")
        if [ "${name_status}" == "warning" ] || [ "${name_status}" == "error" ]; then
            log "ERROR: The cluster name [${cluster_name}] is not available for new clusters. HTTP Status: ${http_check_status}"
            json "${ocp_contents}"
            return 1
        fi
    else
        log "ERROR: Unable to check name availability for cluster name [${cluster_name}]. HTTP Status: ${http_check_status}"
        json "${ocp_contents}"
        return 1
    fi

    local ocp_experimental=0
    local http_status
    http_status=$(curl -s -k -u "${username}:${api_key}" "${FYRE_CLOUD_API}_available/x" \
        --header "accept: application/json" \
        -w "%{http_code}" \
        -o "${ocp_contents}") || result=1
    if [ ${result} -eq 1 ] || [ "${http_status}" != "200" ]; then
        log "ERROR: Getting OCP versions failed. HTTP Status: ${http_status}"
        json "${ocp_contents}"
        return 1
    else
        ocp_version=$(jq -r '.ocp_versions[]' "${ocp_contents}"  \
            | grep "${ROF_VERSION}" \
            | sort  --version-sort -r \
            | head -n 1)

        if [ -z "${ocp_version}" ]; then
            local latest_ocp_version
            latest_ocp_version=$(jq -r '.ocp_versions[]' "${ocp_contents}"  \
                | sort  --version-sort -r \
                | head -n 1)
            local greatest_ocp_version
            greatest_ocp_version=$(printf "%s\n%s" "${ROF_VERSION}" "${latest_ocp_version}" | sort --version-sort -r | head -n 1)
            if [ "${ROF_VERSION}" == "${greatest_ocp_version}" ]; then
                log "INFO: Specified version [${ROF_VERSION}] is higher than latest supported version [${latest_ocp_version}]. Will attempt to create as an experimental cluster."
                ocp_version=${ROF_VERSION}
                ocp_experimental=1
            else
                log "ERROR: Specified version [${ROF_VERSION}] is not supported and is lower than latest supported version [${latest_ocp_version}]"
                return 1
            fi
        fi 
    fi

    quota_type=regular
    if [ ${NEW_CLUSTER_TYPE} == "fyre-quick-burn" ]; then
        quota_type="quick burn"
    fi
    log "INFO: Creating Fyre cluster [${cluster_name}] with version [${ocp_version}] using ${quota_type} quota."

    local cluster_creation_file="${WORKDIR}/fyre_cluster_create.json"
    create_fyre_payload "${cluster_creation_file}" "${cluster_workers}" "${cluster_worker_size}" "${ocp_version}" "${ocp_experimental}" || return 1

    local creation_contents=${WORKDIR}/fyre_creation.json && touch "${creation_contents}"
    local http_status
    http_status=$(curl -X POST -s -k -u "${username}:${api_key}" "${FYRE_CLOUD_API}" \
        --header "accept: application/json" \
        --header "content-type: application/json" \
        --data @"${cluster_creation_file}" \
        -w "%{http_code}" \
        -o "${creation_contents}") || result=1
    if [ ${result} -eq 1 ] || [ "${http_status}" != "200" ]; then
        log "ERROR: Creation of cluster [${cluster_name}] failed. HTTP Status: ${http_status}"
        json "${creation_contents}"
        result=1
    else
        log "INFO: Cluster [${cluster_name}] creation request succeeded."
        json "${creation_contents}"

        if [ "${wait_cluster}" -eq 1 ]; then
            wait_for_fyre_cluster "${cluster_name}" "${username}" "${api_key}" || result=1
        fi
    fi

    return ${result}
}


#
# Creates a new cluster in ROSA.
#
# arg1 name of the cluster to be checked
# arg2 number of workers for the cluster
# arg3 max number of workers for the cluster
# arg4 size of workers for the cluster
# arg5 username for the target cloud
# arg6 apikey for the target cloud
# arg7 ROSA token
# arg8 whether or not to wait for the cluster to be up if still being created
#      1=wait | 0=do not wait
#
function create_rosa_cluster() {
    local cluster_name=${1}
    local min_cluster_workers=${2}
    local max_cluster_workers=${3}
    local cluster_worker_size=${4}
    local username=${5}
    local api_key=${6}
    local rosa_token=${7}
    local wait_cluster=${8:-0}

    local result=0

    login_rosa "" "${username}" "${api_key}" "${rosa_token}" \
        || return 1

    ocp_version=$(rosa list versions | grep "^${ROSA_VERSION}" | head -n 1 | cut -d " " -f 1)
    if [ -z "${ocp_version}" ]; then
        log "ERROR: Unable to determine ocp version matching ${ROSA_VERSION}"
        return 1
    fi

    local watch_logs_param=()
    if [ "${wait_cluster}" -eq 1 ]; then
        watch_logs_param=(--watch)
    fi
    local replicas_param=(--compute-nodes "${min_cluster_workers}")
    if [ "${max_cluster_workers}" -gt "${min_cluster_workers}" ]; then
        replicas_param=(\
            --enable-autoscaling \
            --min-replicas "${min_cluster_workers}" \
            --max-replicas "${max_cluster_workers}")
    fi

    rosa create cluster \
        --cluster-name "${cluster_name}" \
        --region "${AWS_CLOUD_REGION}" \
        --version "${ocp_version}" \
        --compute-machine-type "${cluster_worker_size}" \
        "${replicas_param[@]}" \
        "${watch_logs_param[@]}" \
    && wait_for_rosa_cluster "${cluster_name}" \
    && log "INFO: Cluster [${cluster_name}] creation request succeeded." \
    || result=1

    if [ ${result} -eq 1 ]; then
        log "ERROR: Creation of cluster [${cluster_name}] failed."
        result=1
    fi

    return ${result}
}


#
# Creates a new cluster using RHACM.
#
# arg1 Hostname for the RHACM server
# arg2 infrastructure type of cluster to be created
# arg3 name of the cluster to be created
# arg4 number of workers for the cluster
# arg5 flavor of workers for the cluster
# arg6 maximum number of autoscaled workers for the cluster
# arg7 if "odf-isolated", places ODF workloads on an isolated worker pool. 
#      setting it to "false" has no effect for ROSA clusters, 
#      since it always needs its own worker pool.
# arg8 labels for the managed server
# arg9 username for the RHACM server
# arg10 apikey for the RHACM server
# arg11 whether or not to wait for the cluster to be up if still being created
#      1=wait | 0=do not wait
#
function create_rhacm_cluster() {
    local rhacm_server=${1}
    local managed_cluster_type=${2}
    local managed_cluster_name=${3}
    local cluster_workers=${4}
    local worker_flavor=${5}
    local autoscale_cluster_workers=${6}
    local storage_type=${7}
    local cluster_labels=${8}
    local username=${9}
    local api_key=${10}
    local wait_cluster=${11:-0}

    local result=0

    local odf_params=()
    if [ "${storage_type}" == "odf-isolated" ]; then
        local odf_worker_flavor
        case "${managed_cluster_type}" in
            aws)
                odf_worker_flavor="m5.2xlarge"
                ;;
            *)
                log "INFO: Sizing ODF worker nodes to the same size as other cluster workers."
                odf_worker_flavor="${worker_flavor}"
        esac
        odf_params=(--odf-autoscale-workers 6 \
                --odf-autoscale-worker-flavor "${odf_worker_flavor}")
    fi

    PIPELINE_DEBUG=${PIPELINE_DEBUG} "${scriptdir}/rhacm.sh" \
        --type "ocp" \
        --cluster "${rhacm_server}" \
        --username "${username}" \
        --apikey "${api_key}" \
        --create \
        --managed-cluster-type "${managed_cluster_type}" \
        --managed-cluster "${managed_cluster_name}" \
        --ocp-version "${OCP_VERSION}" \
        --workers "${cluster_workers}" \
        --worker-flavor "${worker_flavor}" \
        --autoscale-workers "${autoscale_cluster_workers}" \
        --managed-cluster-labels "${cluster_labels}" \
        "${odf_params[@]}" \
    || result=1

    if [ ${result} -eq 1 ]; then
        log "ERROR: Creation of cluster [${managed_cluster_name}] failed."
        result=1
    else
        log "INFO: Cluster [${managed_cluster_name}] creation request succeeded."
    fi

    return ${result}
}


#
# Deletes the specified cluster.
#
# arg1 name of the cluster to be checked
# arg2 username for the target cloud
# arg3 apikey for the target cloud
# arg4 whether or not to wait for the cluster to be up if still being created
#      1=wait | 0=do not wait
#
function delete_ibm_cloud_cluster() {
    local cluster_name=${1}
    local username=${2}
    local api_key=${3}
    local wait_cluster=${4:-0}

    local result=0

    login_ibm_cloud "" "${username}" "${api_key}"
    if [ ${result} -eq 0 ]; then
        ibmcloud oc cluster rm  --cluster "${cluster_name}" -f --force-delete-storage -q \
            || result=1
    fi

    if [ ${result} -eq 0 ]; then
        log "INFO: Deletion requested for IBM Cloud cluster [${cluster_name}]"
    else
        log "ERROR: Unable to delete IBM Cloud cluster [${cluster_name}]."
    fi

    return ${result}
}


#
# Deletes the specified cluster.
#
# arg1 name of the cluster to be checked
# arg2 username for the target cloud
# arg3 apikey for the target cloud
# arg4 whether or not to wait for the cluster to be up if still being created
#      1=wait | 0=do not wait
#
function delete_fyre_cluster() {
    local cluster_name=$1
    local username=$2
    local api_key=$3
    local wait_cluster=${4:-0}

    local result=0

    local status_contents="${WORKDIR}/fyre_status_content.json"
    check_fyre_cluster "${cluster_name}" "${username}" "${api_key}" "${status_contents}" "${wait_cluster}" \
        || return 1

    local delete_contents="${WORKDIR}/fyre_cluster_delete.json" && touch "${delete_contents}"
    local http_status
    http_status=$(curl -s -k -X DELETE -u "${username}:${api_key}" \
        "${FYRE_CLOUD_API}/${cluster_name}" \
        --header "accept: application/json" \
        -w "%{http_code}" \
        -o "${delete_contents}")
    if [ ! "${http_status}" -eq 200 ]; then
        log "ERROR: Deletion failed for Fyre cluster ${cluster_name}. HTTP Status: ${http_status}"
        json "${delete_contents}"
        result=1
    else
        log "INFO: Deletion requested for Fyre cluster ${cluster_name}"
        if [ ${verbose} -eq 1 ]; then
            json "${delete_contents}"
        fi
    fi

    return ${result}
} 


#
# Deletes the specified cluster.
#
# arg1 Hostname for the RHACM server.
# arg2 name of the cluster to be deleted.
# arg3 username for the RHACM server.
# arg4 apikey for the RHACM server.
#
function delete_rhacm_cluster() {
    local rhacm_server=${1}
    local managed_cluster_name=${2}
    local username=${3}
    local api_key=${4}

    local result=0

    PIPELINE_DEBUG=${PIPELINE_DEBUG} "${scriptdir}/rhacm.sh" \
        --type "ocp" \
        --cluster "${rhacm_server}" \
        --username "${username}" \
        --apikey "${api_key}" \
        --delete \
        --managed-cluster "${managed_cluster_name}" \
    || result=1

    return ${result}
} 


#
# Deletes the specified cluster.
#
# arg1 name of the cluster to be checked
# arg2 username for the target cloud
# arg3 apikey for the target cloud
# arg4 ROSA token
# arg5 whether or not to wait for the cluster to be up if still being created
#      1=wait | 0=do not wait
#
function delete_rosa_cluster() {
    local cluster_name=${1}
    local username=${2}
    local api_key=${3}
    local rosa_token=${4}
    local wait_cluster=${5:-0}

    local result=0

    login_rosa "" "${username}" "${api_key}" "${rosa_token}" \
        || return 1
    if [ ${result} -eq 0 ]; then
        rosa delete cluster \
            --cluster="${cluster_name}" \
            --region "${AWS_CLOUD_REGION}" \
            --yes \
            --watch \
        || result=1
    fi

    if [ ${result} -eq 0 ]; then
        log "INFO: Deletion requested for ROSA cluster [${cluster_name}]"
    else
        log "ERROR: Unable to delete ROSA cluster [${cluster_name}]."
    fi

    return ${result}
}


#
# Deletes the specified cluster.
#
# arg1 infrastructure type of cluster to be deleted
# arg2 name of the cluster to be deleted
# arg3 username for the target cloud
# arg4 apikey for the target cloud
# arg5 OCP key if creating a managed OCP cluster (other than ROKS)
# arg6 whether or not to wait for the cluster to be up if still being created
#      1=wait | 0=do not wait
#
function delete_cluster() {
    local cluster_type=${1}
    local cluster_name=${2}
    local username=${3}
    local api_key=${4}
    local managed_ocp_token=${5}
    local rhacm_server=${6}
    local wait_cluster=${7:-0}

    if [ -n "${rhacm_server}" ]; then
        delete_rhacm_cluster "${rhacm_server}" "${cluster_type}" "${cluster_name}" "${cluster_workers}" "${worker_flavor}" "${username}" "${api_key}" "${wait_cluster}" \
            || return 1
    else
        case ${cluster_type} in
            ibmcloud|ibmcloud-gen2)
                delete_ibm_cloud_cluster "${cluster_name}" "${username}" "${api_key}" "${wait_cluster}" \
                    || return 1
            ;;
            fyre|fyre-quick-burn)
                delete_fyre_cluster "${cluster_name}" "${username}" "${api_key}" "${wait_cluster}" \
                    || return 1
            ;;
            rosa)
                delete_rosa_cluster "${cluster_name}" "${username}" "${api_key}" "${managed_ocp_token}" "${wait_cluster}" \
                    || return 1
            ;;
            *)
                echo "Unrecognized cluster type: ${cluster_type}"
                return 1
        esac
    fi
} 


#
# Checks whether the specified cluster is ready to accept requests.
#
# arg1 infrastructure type of cluster to be deleted
# arg2 name of the cluster to be checked
# arg3 username for the target cloud
# arg4 apikey for the target cloud
# arg5 OCP key if creating a managed OCP cluster (other than ROKS)
# arg6 whether or not to wait for the cluster to be up if still being created
#      1=wait | 0=do not wait
#
function check_cluster() {
    local cluster_type=${1}
    local cluster_name=${2}
    local username=${3}
    local api_key=${4}
    local managed_ocp_token=${5}
    local wait_cluster=${6:-0}

    local result=0

    case ${cluster_type} in
        aws)
            login_ocp_cluster "${cluster_name}" "${username}" "${api_key}"  \
                || result=1
        ;;
        fyre|fyre-quick-burn)
            local status_contents="${WORKDIR}/fyre_status_content.json"
            check_fyre_cluster "${cluster_name}" "${username}" "${api_key}" "${status_contents}" "${wait_cluster}" \
                || result=1
        ;;
        ibmcloud|ibmcloud-gen2)
            check_ibm_cloud_cluster "${cluster_type}" "${cluster_name}" "${username}" "${api_key}" "${wait_cluster}" \
                || result=1
        ;;
        rosa)
            check_rosa_cluster "${cluster_name}" "${username}" "${api_key}" "${managed_ocp_token}" "${wait_cluster}" \
                || return 1
        ;;
        *)
        log "ERROR: Unrecognized cluster type: ${cluster_type}"
        result=1
    esac

    return ${result}
}


#
# Creates specified cluster.
#
# arg1 infrastructure type of cluster to be created
# arg2 name of the cluster to be created
# arg3 number of workers for the cluster
# arg4 flavor of workers for the cluster
# arg5 number of autoscale workers for the cluster
# arg6 flavor of autoscale workers for the cluster
# arg7 type of data storage for the cluster. 
#      It may affect the parameters for the creation of the cluster.
# arg8 username for the target cloud
# arg9 apikey for the target cloud
# arg10 OCP key if creating a managed OCP cluster (other than ROKS)
# arg11 RHACM server. If not empty, creation done through RHACM server.
# arg12 Comma-separated list of labels for the cluster.
# arg13 whether or not to wait for the cluster to be up if still being created
#       1=wait | 0=do not wait
#
function create_cluster() {
    local cluster_type=${1}
    local cluster_name=${2}
    local cluster_workers=${3}
    local worker_flavor=${4}
    local autoscale_cluster_workers=${5}
    local autoscale_worker_flavor=${6}
    local storage_type=${7}
    local username=${8}
    local api_key=${9}
    local managed_ocp_token=${10}
    local rhacm_server=${11}
    local cluster_labels=${12}
    local wait_cluster=${13:-0}

    if [ -n "${rhacm_server}" ]; then
        create_rhacm_cluster "${rhacm_server}" "${cluster_type}" "${cluster_name}" "${cluster_workers}" "${worker_flavor}" "${autoscale_cluster_workers}" "${storage_type}" "${cluster_labels}" "${username}" "${api_key}" "${wait_cluster}" \
            || return 1
    else
        case ${cluster_type} in
            ibmcloud|ibmcloud-gen2)
                create_ibm_cloud_cluster "${cluster_type}" "${cluster_name}" "${cluster_workers}" "${worker_flavor}" "${autoscale_cluster_workers}" "${autoscale_worker_flavor}" "${username}" "${api_key}" "${IBM_CLOUD_CLUSTER_ZONE}" "${wait_cluster}" \
                    || return 1
            ;;
            fyre|fyre-quick-burn)
                create_fyre_cluster "${cluster_name}" "${cluster_workers}" "${worker_flavor}" "${username}" "${api_key}" "${wait_cluster}" \
                    || return 1
            ;;
            rosa)
                create_rosa_cluster "${cluster_name}" "${cluster_workers}" "${autoscale_cluster_workers}" "${worker_flavor}" "${username}" "${api_key}" "${managed_ocp_token}" "${wait_cluster}" \
                    || return 1
            ;;
            *)
                echo "Unrecognized cluster type: ${cluster_type}"
                return 1
        esac
    fi
}


#
# Ensures cluster has the latest upgrades
#
function check_upgrade_cluster() {
    # https://docs.openshift.com/container-platform/4.6/updating/updating-cluster-cli.html
    local no_upgrade_available
    no_upgrade_available=$(${oc_cmd} adm upgrade | grep -c "No updates available.")
    if [ "${no_upgrade_available}" -eq 1 ]; then
        log "INFO: No upgrade available for the cluster."
        return
    fi

    local result=1

    "${oc_cmd}" adm upgrade --to-latest=true
    sleep 240
    local operation_limit_seconds=$(( $(date +%s) + 7200 ))
    local progress_marker="An upgrade is in progress"
    while [[ ${current_seconds} -lt ${operation_limit_seconds} ]]; do
        ${oc_cmd} adm upgrade
        working_str=$("${oc_cmd}" adm upgrade | grep "${progress_marker}")
        if [[ ${working_str} != *"${progress_marker}"* ]]; then
            log "INFO: Cluster upgraded."
            if [ "${PIPELINE_DEBUG}" -eq 1 ]; then
                ${oc_cmd} adm upgrade
                result=0
            fi
            break
        fi
        log "INFO: ${working_str}"
        sleep 60
        current_seconds=$(( $(date +%s) ))
    done

    return ${result}
}


#
# Configures Ceph storage on a Fyre cluster.
#
function setup_ceph_storage() {
    local result=1

    log "INFO: Configuring Ceph storage."
    "${oc_cmd}" get storageclass rook-cephfs >/dev/null 2>&1 \
        && log "INFO: cephfs storage class already exists in cluster." \
        && return 0

    local ca_work_dir="${WORKDIR}/clone"
    local ceph_dir="${ca_work_dir}/cluster/examples/kubernetes/ceph"

    git clone --depth 1 -b release-1.6 https://github.com/rook/rook.git "${ca_work_dir}" \
        && log "INFO: Applying Ceph storage." \
        && "${oc_cmd}" create -f "${ceph_dir}/common.yaml" \
        && "${oc_cmd}" create -f "${ceph_dir}/crds.yaml" \
        && "${oc_cmd}" create -f "${ceph_dir}/operator-openshift.yaml" \
        && "${oc_cmd}" create -f "${ceph_dir}/cluster.yaml" \
        && "${oc_cmd}" create -f "${ceph_dir}/csi/rbd/storageclass.yaml" \
        && "${oc_cmd}" create -f "${ceph_dir}/csi/rbd/pvc.yaml" \
        && "${oc_cmd}" create -f "${ceph_dir}/filesystem.yaml" \
        && "${oc_cmd}" create -f "${ceph_dir}/csi/cephfs/storageclass.yaml" \
        && "${oc_cmd}" create -f "${ceph_dir}/csi/cephfs/pvc.yaml" \
        && "${oc_cmd}" create -f "${ceph_dir}/toolbox.yaml" \
        && "${oc_cmd}" patch storageclass rook-cephfs -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' \
        && log "INFO: Waiting for the cluster to be ready." \
        && "${oc_cmd}" wait CephCluster rook-ceph -n rook-ceph --for=condition="Ready" --timeout=3600s \
        && "${oc_cmd}" wait Deployment rook-ceph-tools -n rook-ceph --for=condition="Available" --timeout=600s \
        && log "INFO: Ceph storage configured." \
        && oc_wait_pvcs \
        && result=0

    if [ ! ${result} -eq 0 ]; then
        log "ERROR: Ceph storage configuration failed."
    fi

    return ${result}
}


#
# Configures IBM Cloud File storage on an ibmcloud cluster.
#
# arg1 infrastructure type of cluster to be deleted
# arg2 name of the cluster to be configured
# 
function setup_ibm_cloud_storage() {
    local cluster_type=${1}
    local cluster_name=${2}

    local result=0

    if [ "${cluster_type}" == "ibmcloud-gen2" ]; then
        setup_ocs_vpc_gen2_storage "${cluster_name}" || 
        {
            log "ERROR: Unable to setup storage for ROKS Gen2 cluster."
            result=1
        }
    else
        log "INFO: Using native storage classes in ROKS classic cluster."
    fi

    return ${result}
}


#
# Performs a command on all workers for the cluster.
#
# arg1 type, e.g. ibmcloud or ibmcloud-gen2
# arg2 name of the cluster to be configured
# arg3 name of the command to execute against the worker
#
function ibm_cloud_cmd_workers() {
    local cluster_type=${1}
    local cluster_name=${2}
    local worker_command=${3}

    local result=0

    if [ "${worker_command}" == "reload" ] || [ "${worker_command}" == "replace" ]; then
        while read -r worker_name
        do
            ibmcloud oc worker "${worker_command}" --cluster "${cluster_name}" --worker "${worker_name}" -f || result=1
        done <<< "$(ibmcloud oc workers --cluster "${cluster_name}" --output JSON | jq -r .[].id)"
        if [ "${result}" -eq 1 ]; then
            log "ERROR: Unable to ${worker_command} all workers"
            return "${result}"
        fi

        # It takes a while for the workers to respond, so we wait a while
        # to first check if their status is not "normal"
        log "INFO: About to wait for operation ${worker_command} to complete..."
        sleep 120
    fi

    ibmcloud oc workers --cluster "${cluster_name}"

    local current_seconds=0
    local operation_limit_seconds=$(( $(date +%s) + 7200 ))
    local pending_workers=0
    while [[ ${current_seconds} -lt ${operation_limit_seconds} ]]; do
        local worker_status_json="${WORKDIR}/worker_status.json"
        local worker_status=0
        ibmcloud oc workers --cluster "${cluster_name}" --output json > "${worker_status_json}" \
            ||  worker_status=1
        if [ ${worker_status} -eq 0 ]; then
            if [ "${cluster_type}" == "ibmcloud" ]; then
                pending_workers=$(jq -r ".[].state" "${worker_status_json}" | grep -c -v "normal")
            else
                pending_workers=$(jq -r '.[] | select(.lifecycle.actualState!="deployed" or .health.state!="normal") .lifecycle.actualState' "${worker_status_json}" | grep -c -v "deployed")
            fi
            if [ "${pending_workers}" == "0" ]; then
                log "INFO: All workers are in a normal state."
                result=0
                break
            fi
            log "INFO: Pending ${worker_command} for all workers. Waiting on ${pending_workers} worker(s)..."
        else
            log "WARNING: Unable to get status for cluster workers."
        fi
        if [ "${verbose}" -eq 1 ]; then
            ibmcloud oc workers --cluster "${cluster_name}" | grep -v normal \
                || log "WARNING: Unable to get status for cluster workers."
        fi
        sleep 60
        current_seconds=$(( $(date +%s) ))
    done
    if [ ! "${pending_workers}" -eq 0 ]; then
        result=1
        log "ERROR: Not all workers are in a normal state."
    fi

    return "${result}"
}


#
# Deletes all pods that are failed due to node affinity
#
# These pods get to that state because this configuration process 
# may reboot all workers or nodes in parallel to speed up the 
# provisioning time. New pods will have been restarted on the nodes
# when the nodes are up, but these failed ones need to be deleted to 
# avoid all the "noise" in the OpenShift console.
#
function delete_failed_node_affinity_pods() {
    log "INFO: Deleting eventual pods failed due to node affinity problems."
    "${oc_cmd}" delete pod --all-namespaces --field-selector status.phase=Failed \
        || return 1
}


#
#
#
function approve_csrs() {
    local result=0

    log "INFO: Approving outstanding CSRs"
    ${oc_cmd} get csr -o name \
    && 
    {
        ${oc_cmd} get csr -o name \
            | xargs -Irepl "${oc_cmd}" adm certificate approve repl
    } \
    || result=1

    return ${result}
}


#
# Configures the PKI aspects of the cluster, using custom certs instead of
# self-signed certs for ingress.
#
# arg1 infrastructure type of cluster to be configured
# arg2 apply custom PKI settings, 0 or 1
#
function config_pki() {
    local cluster_type=${1}
    local custom_pki=${2}

    local result=0

    if [ "${custom_pki}" -eq "1" ];then
        if [ "${cluster_type}" == "aws" ]; then
            config_ingress_letsencrypt "${cluster_type}" || result=1
        else
            config_ingress || result=1
        fi
    fi

    return ${result}
}


#
# Configures specified IBM Cloud cluster.
#
# arg1 type, e.g. ibmcloud or ibmcloud-gen2
# arg2 name of the cluster to be configured
# arg3 username for the target cloud
# arg4 apikey for the target cloud
# arg5 type of storage to be added to the cluster.
# arg6 configure global pull secret, 0 (no) or 1 (yes)
#
function configure_ibm_cloud_cluster() {
    local cluster_type=${1}
    local cluster_name=${2}
    local username=${3}
    local api_key=${4}
    local storage_type=${5}
    local set_global_pull_secret=${6}

    local result=0

    login_ibm_cloud "${cluster_name}" "${username}" "${api_key}" || \
    {
        log "WARNING: Workaround for IBM login woes."
        sleep 120
        login_ibm_cloud "${cluster_name}" "${username}" "${api_key}" \
            || result=1
    }

    if [ ${result} -eq 0 ]; then
        if [ "${upgrade_cluster_latest}" -eq 1 ]; then
            check_upgrade_cluster
        fi
        approve_csrs || \
        {
            log "WARNING: Workaround for IBM Cloud IAM synchronization woes."
            oc logout || true
            ibmcloud logout || true
            sleep 120
            login_ibm_cloud "${cluster_name}" "${username}" "${api_key}" \
                && approve_csrs \
                || result=1
        }

        # Reload workers after setting up global pull secret
        # https://marketplace.redhat.com/en-us/documentation/deployment-troubleshooting#install-red-hat-marketplace-operator-script-was-successful-but-cluster-status-is-not-registered

        local operation=reload
        if [ "${cluster_type}" == "ibmcloud-gen2" ]; then
            operation=replace
        fi
        if [ "${set_global_pull_secret}" -eq 1 ]; then
            setup_global_pull_secrets \
                && ibm_cloud_cmd_workers "${cluster_type}" "${cluster_name}" ${operation} \
                && oc_wait_nodes \
                || result=1
        fi

        if [ "${storage_type}" != "none" ]; then
            setup_ibm_cloud_storage "${cluster_type}" "${cluster_name}" \
                || result=1
        fi
    fi

    return ${result}
}


#
# Configures specified AWS cluster.
#
# arg1 infrastructure type of cluster to be configured
# arg2 name of the cluster to be configured
# arg3 username for the target cloud
# arg4 apikey for the target cloud
# arg5 OCP key if creating a managed OCP cluster (other than ROKS)
# arg6 apply custom PKI settings, 0 or 1
# arg7 type of storage to be added to the cluster.
# arg8 configure global pull secret, 0 (no) or 1 (yes)
#
function configure_aws_cluster() {
    local cluster_type=${1}
    local cluster_name=${2}
    local username=${3}
    local api_key=${4}
    local managed_ocp_token=${5}
    local custom_pki=${6}
    local storage_type=${7}
    local set_global_pull_secret=${8}

    local result=0

    check_cluster "${cluster_type}" "${cluster_name}" "${username}" "${api_key}" \
    && login_cluster "${cluster_type}" "${cluster_name}" "${username}" "${api_key}" "${managed_ocp_token}" \
    || result=1

    if [ ${result} -eq 0 ]; then
        if [ "${upgrade_cluster_latest}" -eq 1 ]; then
            check_upgrade_cluster
        fi
        approve_csrs \
            || result=1

        if [ "${set_global_pull_secret}" -eq 1 ]; then
            setup_global_pull_secrets \
                || result=1
        fi

        oc_wait_nodes \
            || result=1

        if [ "${cluster_type}" != "rosa" ]; then
            config_pki "${cluster_type}" "${custom_pki}" \
                || result=1
        fi

        local odf_isolated="false"
        if [ "${storage_type}" == "odf-isolated" ]; then
            odf_isolated="true"
        fi
        if [ "${storage_type}" != "none" ]; then
            setup_ocs_aws_storage "${cluster_type}" "${cluster_name}" "${odf_isolated}" \
            || result=1
        fi
    fi

    return ${result}
}


#
# Configures specified cluster managed in RHACM
#
# arg1 Hostname for the RHACM server.
# arg2 type of the cluster to be configured.
# arg3 name of the cluster to be configured.
# arg4 username for the RHACM server.
# arg5 apikey for the RHACM server.
# arg6 apply custom PKI settings, 0 or 1
# arg7 type of storage to be added to the cluster.
# arg8 configure global pull secret, 0 (no) or 1 (yes)
#
function configure_rhacm_cluster() {
    local rhacm_server=${1}
    local managed_cluster_type=${2}
    local managed_cluster_name=${3}
    local username=${4}
    local api_key=${5}
    local custom_pki=${6}
    local storage_type=${7}
    local set_global_pull_secret=${8}

    local result=0

    PIPELINE_DEBUG=${PIPELINE_DEBUG} "${scriptdir}/rhacm.sh" \
        --type "ocp" \
        --cluster "${rhacm_server}" \
        --username "${username}" \
        --apikey "${api_key}" \
        --login \
        --managed-cluster "${managed_cluster_name}" \
    || result=1

    if [ ${result} -eq 0 ]; then
        if [ "${upgrade_cluster_latest}" -eq 1 ]; then
            check_upgrade_cluster
        fi
        approve_csrs \
            || result=1

        if [ "${set_global_pull_secret}" -eq 1 ]; then
            setup_global_pull_secrets \
                || result=1
        fi

        oc_wait_nodes \
            || result=1

        config_pki "${managed_cluster_type}" "${custom_pki}" \
            || result=1

        if [ "${storage_type}" != "none" ]; then
            local odf_isolated="false"
            if [ "${storage_type}" == "odf-isolated" ]; then
                odf_isolated="true"
            fi
            setup_ocs_aws_storage "${cluster_type}" "${cluster_name}" "${odf_isolated}" \
            || result=1
        fi
    fi

    return ${result}
}


#
# Configures specified Fyre cluster.
#
# arg1 name of the cluster to be configured
# arg2 username for the target cloud
# arg3 apikey for the target cloud
# arg4 apply custom PKI settings, 0 or 1
# arg5 type of storage to be added to the cluster.
# arg6 configure global pull secret, 0 (no) or 1 (yes)
#
function configure_fyre_cluster() {
    local cluster_name=${1}
    local username=${2}
    local api_key=${3}
    local custom_pki=${4}
    local storage_type=${5}
    local set_global_pull_secret=$6

    local result=0

    local status_contents="${WORKDIR}/fyre_status_content.json"
    check_fyre_cluster "${cluster_name}" "${username}" "${api_key}" "${status_contents}" || result=1

    if [ ${result} -eq 0 ]; then
        local kubeadmin_password
        local ip_address
        kubeadmin_password=$(jq -r .clusters[].kubeadmin_password "${status_contents}")
        ip_address=$(jq -r '.clusters[].vms[].ips[] | select (.type=="public") | .address' "${status_contents}")

        local oc_cmd_login="${WORKDIR}/oc_login.txt"
        ${oc_cmd} login -u kubeadmin -p "${kubeadmin_password}" \
                    --insecure-skip-tls-verify=true \
                    --server="https://${ip_address}:6443"  > /dev/null 2>&1 \
            | tee "${oc_cmd_login}" || result=1
        if [ ${result} -eq 1 ]; then
            cat "${oc_cmd_login}"
        else 
            if [ "${upgrade_cluster_latest}" -eq 1 ]; then
                check_upgrade_cluster
            fi
            approve_csrs \
                || result=1

            if [ "${set_global_pull_secret}" -eq 1 ]; then
                setup_global_pull_secrets \
                    && oc_wait_nodes \
                    && ${oc_cmd} get machineconfigpool \
                    || result=1
            fi

            config_pki "fyre" "${custom_pki}" \
                || result=1

            if [ "${storage_type}" != "none" ]; then
                setup_ceph_storage \
                    || result=1
            fi

        fi
    fi

    return ${result}
}


#
# Configures specified cluster.
#
# arg1 infrastructure type of cluster to be configured
# arg2 name of the cluster to be configured
# arg3 username for the target cloud
# arg4 apikey for the target cloud
# arg5 OCP key if creating a managed OCP cluster (other than ROKS)
# arg6 RHACM server. If not empty, creation done through RHACM server.
# arg7 apply custom PKI settings, 0 (no) or 1 (yes)
# arg8 install the velero backup framework, 0 (no) or 1 (yes)
# arg9 API key for the COS instance
# arg10 type of storage to be added to the cluster.
# arg11 configure global pull secret, 0 (no) or 1 (yes)
#
function configure_cluster() {
    local cluster_type=${1}
    local cluster_name=${2}
    local username=${3}
    local api_key=${4}
    local managed_ocp_token=${5}
    local rhacm_server=${6}
    local custom_pki=${7}
    local backup_agent=${8}
    local cos_apikey=${9}
    local storage_type=${10}
    local set_global_pull_secret=${11}

    if [ "$(uname)" != "Linux" ]; then
        log "ERROR: This step is only supported from Linux systems. Tested with a docker container using the ibmcom/pipeline-base-image image"
        return 1
    fi

    local result=0

    if [ -n "${rhacm_server}" ]; then
        configure_rhacm_cluster "${rhacm_server}" "${cluster_type}" "${cluster_name}" "${username}" "${api_key}" "${custom_pki}" "${storage_type}" "${set_global_pull_secret}" \
            || return 1
    else
        case ${cluster_type} in
            aws|rosa)
                configure_aws_cluster "${cluster_type}" "${cluster_name}" "${username}" "${api_key}" "${managed_ocp_token}" "${custom_pki}"  "${storage_type}" "${set_global_pull_secret}" \
                    || result=1
            ;;
            fyre|fyre-quick-burn)
                configure_fyre_cluster "${cluster_name}" "${username}" "${api_key}" "${custom_pki}" "${storage_type}" "${set_global_pull_secret}" \
                    || result=1
            ;;
            ibmcloud|ibmcloud-gen2)
                configure_ibm_cloud_cluster "${cluster_type}" "${cluster_name}" "${username}" "${api_key}" "${storage_type}" "${set_global_pull_secret}" \
                    || result=1
            ;;
            *)
            log "ERROR: Unrecognized cluster type: ${cluster_type}"
            return 1
        esac
    fi

    if [ "${result}" -eq 0 ]; then
        oc_wait_nodes \
            && add_ibm_operator_catalog \
            && delete_failed_node_affinity_pods \
            || result=1

        if [ "${backup_agent}" == "1" ]; then
            PIPELINE_DEBUG=${PIPELINE_DEBUG} "${scriptdir}/velero.sh" \
                --type "${cluster_type}" \
                --cluster "${cluster_name}" \
                --setup-server \
                --username "${username}" \
                --apikey "${api_key}" \
                --cos-apikey "${cos_apikey}" \
            || result=1
        fi
    fi

    return ${result}
}


WORKDIR=$(mktemp -d) || exit 1
trap cleanRun EXIT

apikey=""
cluster_name=""
cluster_type="${NEW_CLUSTER_TYPE}"
cluster_workers="${CLUSTER_WORKERS}"
worker_flavor="${WORKER_FLAVOR}"
autoscale_cluster_workers=""
autoscale_worker_flavor="${WORKER_FLAVOR}"
set_global_pull_secret=0
create=0
ensure=0
delete=0
check=0
config=0
wait_cluster=0
upgrade_cluster_latest=0
custom_pki=0
backup_agent=0
cos_apikey=""
username=""
rhacm_server=""
managed_cluster_labels=""
while [[ $# -gt 0 ]]
do
key="$1"
shift
case ${key} in
    -t|--type)
    NEW_CLUSTER_TYPE=$1
    cluster_type=$1
    shift
    ;;
    -n|--cluster)
    cluster_name=$1
    shift
    ;;
    -c|--create)
    create=1
    ;;
    -e|--ensure)
    ensure=1
    ;;
    -d|--delete)
    delete=1
    ;;
     -s|--status)
    check=1
    ;;
    --config)
    config=1
    ;;
    --storage)
    storage_type=$1
    shift
    ;;
    --upgrade-cluster)
    upgrade_cluster_latest=1
    ;;
     -w|--wait)
    wait_cluster=1
    ;;
    -a|--apikey)
    apikey=$1
    shift
    ;;
    --custom-pki)
    custom_pki=1
    ;;
    -g|--global-pull-secret)
    if [ "${1}" == "true" ]; then
        set_global_pull_secret=1
    fi
    shift
    ;;
    --backup-agent)
    backup_agent=1
    ;;
    --cos-apikey)
    cos_apikey=$1
    shift
    ;;
    --ocp-token)
    managed_ocp_token=$1
    shift
    ;;
    --ocp-version)
    OCP_VERSION=$1
    shift
    ;;
    --workers)
    cluster_workers=$1
    shift
    ;;
    --worker-flavor)
    worker_flavor=$1
    shift
    ;;
    --autoscale-workers)
    autoscale_cluster_workers=$1
    shift
    ;;
    --autoscale-worker-flavor)
    autoscale_worker_flavor=$1
    shift
    ;;
    -u|--username)
    username=$1
    shift
    ;;
    -r|--rhacm-server)
    rhacm_server=$1
    shift
    ;;
    -l|--managed-cluster-labels)
    managed_cluster_labels=$1
    shift
    ;;
    -h|--help)
    usage
    exit
    ;;
    -v|--verbose)
    verbose=1
    ;;
    *)
    echo "Unrecognized parameter: ${key}"
    usage
    exit 1
esac
done

cmd_count=$((create+delete+check+ensure+config))

if [ ${cmd_count} -eq 0 ]; then
    log "ERROR: No command was specified [create, delete, check, ensure, or config]."
    exit 1
fi
if [ ${cmd_count} -gt 1 ]; then
    log "ERROR: Only one command can be specified [create, delete, check, ensure, or config]."
    exit 1
fi

if [ -z "${cluster_name}" ]; then
    log "ERROR: A cluster name was not specified."
    exit 1
fi

log "INFO: Processing auto-scaling parameters."
case ${cluster_type} in
    aws|gcp|rosa)
        if [ -n "${autoscale_cluster_workers}" ] && [ "${autoscale_cluster_workers}" != "0" ]; then
            if [ -n "${autoscale_worker_flavor}" ]; then
                log "WARNING: autoscale-worker-flavor is ignored as auto-scaling applies to default worker pool when creating this type of cluster."
            fi
        fi
        ;;
    ibmcloud|ibmcloud-gen2)
        if [ -n "${autoscale_cluster_workers}" ] && [ "${autoscale_cluster_workers}" != "0" ]; then
            if [ -z "${autoscale_worker_flavor}" ]; then
                log "ERROR: autoscale-worker-flavor must be specified if autoscale-workers is set."
                exit 1
            fi
            autoscale_cluster_workers=$((autoscale_cluster_workers))
            test "${autoscale_cluster_workers}" -gt 0 || {
                log "ERROR: --autoscale-workers parameter [${autoscale_cluster_workers}] should be a positive integer number."
                exit 1
            }
        fi
        ;;
    *)
esac

case ${cluster_type} in
    aws|gcp)
        if [ -z "${rhacm_server}" ]; then
            log "ERROR: ${cluster_type} cluster operations only supported through RHACM."
            exit 1
        fi
    ;;
    fyre|fyre-quick-burn)
        : "${username:=${FYRE_USERNAME}}"
        : "${apikey:=${FYRE_API_KEY}}"

        if [ -z "${username}" ]; then
            log "ERROR: A Fyre username was not specified."
            exit 1
        fi
    ;;
    ibmcloud)
        : "${username:=${IBM_CLOUD_USERNAME}}"
        : "${apikey:=${IBM_CLOUD_API_KEY}}"
        : "${cos_apikey:=${apikey}}"

        if [ "${IBM_CLOUD_REGION}" == "us-east" ]; then
            : "${IBM_CLOUD_CLUSTER_ZONE:=wdc04}"
        else
            : "${IBM_CLOUD_CLUSTER_ZONE:=dal13}"
        fi
        [ "${worker_flavor}" == "medium" ] \
            && worker_flavor=b3c.8x32

    ;;
    ibmcloud-gen2)
        : "${username:=${IBM_CLOUD_USERNAME}}"
        : "${apikey:=${IBM_CLOUD_API_KEY}}"
        : "${cos_apikey:=${apikey}}"

        if [ "${IBM_CLOUD_REGION}" == "us-east" ]; then
            : "${IBM_CLOUD_CLUSTER_VPC:=sdlc-vpc-us-east}"
            : "${IBM_CLOUD_CLUSTER_VPC_SUBNET:=sdlc-vpc-east-1}"
        else
            : "${IBM_CLOUD_CLUSTER_VPC:=sdlc-vpc}"
            : "${IBM_CLOUD_CLUSTER_VPC_SUBNET:=sdlc-vpc-subnet-1}"
        fi
        : "${IBM_CLOUD_CLUSTER_ZONE:=${IBM_CLOUD_REGION}-1}"
        [ "${worker_flavor}" == "medium" ] \
            && worker_flavor=bx2.8x32

        # IBM stopped providing a clean update from older versions of the CLI
        # so this is necessary.
        if ibmcloud version | grep -q "version 1"; then
            if [ "$(uname)" == "Linux" ]; then
                curl -fsSL https://clis.cloud.ibm.com/install/linux | sh
            else
                log "ERROR: ibmcloud CLI needs to be version 2 or later. See update instructions at: https://cloud.ibm.com/docs/cli?topic=cli-getting-started"
            fi
        fi
        ibmcloud plugin update kubernetes-service
    ;;
    ocp)
        if [ "${config}" -eq 0 ]; then
            log "ERROR: Only configuration is supported for generic OCP clusters."
            exit 1
        fi
    ;;
    rhacm)
        : "${username:=${RHACM_USERNAME}}"
        : "${apikey:=${RHACM_PASSWORD}}"
    ;;
    rosa)
        : "${username:=${AWS_ACCESS_KEY_ID}}"
        : "${apikey:=${AWS_SECRET_ACCESS_KEY}}"
        : "${managed_ocp_token:=${ROSA_TOKEN}}"

        if [ -z "${managed_ocp_token}" ]; then
            log "ERROR: A ROSA token was not specified."
            exit 1
        fi

        [ "${worker_flavor}" == "medium" ] \
            && worker_flavor=m5.2xlarge

        aws_rosa_cli=0
        install_aws_cli \
            && install_rosa_cli \
            || aws_rosa_cli=1

        if [ ${aws_rosa_cli} -eq 1 ]; then
            log "ERROR: Unable to install ROSA and AWS CLIs."
            exit 1
        fi
    ;;
    *)
        echo "Unrecognized cluster type: ${cluster_type}"
        exit 1
esac

if [ -z "${username}" ]; then
    log "ERROR: An username was not specified."
    exit 1
fi

if [ -z "${apikey}" ]; then
    log "ERROR: An API key was not specified."
    exit 1
fi

if [ ${backup_agent} -eq 1 ] && [ -z "${cos_apikey}" ]; then
    log "ERROR: An Object Storage API key was not specified."
    exit 1
fi

check_install_oc || exit 1

result=0

if [ ${ensure} -eq 1 ]; then
    login_cluster "${cluster_type}" "${cluster_name}" "${username}" "${apikey}" "" 1 \
    || {
        create_cluster "${cluster_type}"  "${cluster_name}" "${cluster_workers}" "${worker_flavor}" "${autoscale_cluster_workers}" "${autoscale_worker_flavor}" "${storage_type}" "${username}" "${apikey}" "${managed_ocp_token}" "${rhacm_server}" "${managed_cluster_labels}" "${wait_cluster}" \
        || {
            check_cluster "${cluster_type}" "${cluster_name}" "${username}" "${apikey}" "${managed_ocp_token}" "${wait_cluster}" 1 \
            || result=1
        }
    }
    if [ ${result} -eq 0 ]; then
        configure_cluster "${cluster_type}" "${cluster_name}" "${username}" "${apikey}" "${managed_ocp_token}" "${rhacm_server}" "${custom_pki}" "${backup_agent}" "${cos_apikey}" "${storage_type}" "${set_global_pull_secret}" \
        || result=1
    fi
elif [ ${create} -eq 1 ]; then
    create_cluster "${cluster_type}"  "${cluster_name}" "${cluster_workers}" "${worker_flavor}" "${autoscale_cluster_workers}" "${autoscale_worker_flavor}" "${storage_type}" "${username}" "${apikey}" "${managed_ocp_token}" "${rhacm_server}" "${managed_cluster_labels}" "${wait_cluster}"
    result=$?
elif [ ${delete} -eq 1 ]; then
    delete_cluster  "${cluster_type}" "${cluster_name}" "${username}" "${apikey}" "${managed_ocp_token}" "${rhacm_server}" "${wait_cluster}"
    result=$?
elif [ ${check} -eq 1 ]; then
    check_cluster "${cluster_type}" "${cluster_name}" "${username}" "${apikey}" "${managed_ocp_token}" "${wait_cluster}"
    result=$?
elif [ ${config} -eq 1 ]; then
    configure_cluster "${cluster_type}" "${cluster_name}" "${username}" "${apikey}" "${managed_ocp_token}" "${rhacm_server}" "${custom_pki}" "${backup_agent}" "${cos_apikey}" "${storage_type}" "${set_global_pull_secret}" 
    result=$?
fi

exit ${result}
