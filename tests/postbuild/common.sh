#!/bin/bash
set -eo pipefail

verbose=0
oc_cmd=$(type -p oc)
scriptdir=$(dirname "${0}")

: "${PIPELINE_DEBUG:=0}"
if [ ${PIPELINE_DEBUG} -eq 1 ]; then
    set -x
    env
    verbose=1
fi


# The "svl" in the FYRE_CLOUD_API is always fixed, regardless of FYRE_SITE
: "${FYRE_CLOUD_API:=https://ocpapi.svl.ibm.com/v1/ocp}"
: "${FYRE_USERNAME:=need-fyre-username}"
: "${FYRE_API_KEY:=need-fyre-apikey}"
: "${IBM_CLOUD_API:=https://cloud.ibm.com}"
: "${IBM_CLOUD_USERNAME:=iamapikey}"
: "${IBM_CLOUD_API_KEY:=really needs to be set by caller}"
: "${IBM_CLOUD_REGION:=us-south}"
: "${IBM_CLOUD_GROUP:=Default}"

: "${AWS_CLOUD_REGION:=us-east-1}"
: "${AWS_DEFAULT_OCP_DOMAIN:=cloudpak-bringup.com}"

: "${GCP_CLOUD_REGION:=us-east1}"
: "${GCP_DEFAULT_OCP_DOMAIN:=blue-chesterfield.com}"

: "${RHACM_SERVER:=replace-servername.replace-domain}"

: "${ODF_NAMESPACE:=openshift-storage}"
: "${ODF_DISK_SIZE:=500Gi}"
: "${MON_DISK_SIZE:=20Gi}"
: "${ROKS_CLUSTER_STORAGE_SI:=sdlc-cluster-storage}"
: "${STORAGE_CLASS:=ibmc-vpc-block-10iops-tier}"
 
: "${PKI_PATH:=${scriptdir}/../pki}"

#
# Prints a formatted message with the timestamp of execution
#
function log() {
    local msg=${1}
    echo "$(date +%Y-%m-%dT%H:%M:%S%z): ${msg}"
}


#
# Prints the contents of a file in JSON format
#
function json() {
    local file=${1}

    local jq_available=1
    type jq > /dev/null 2>&1 || jq_available=0
    if [ ${jq_available} -eq 1 ]; then
        jq . "${file}" | grep -v "password"
    else
        grep -v "password" "${file}"
        echo
    fi
}


#
# Verbose statement
#
function echo_verbose() {
    if [ ${verbose} -eq 1 ]; then
        echo "$1"
    fi
}


#
# If the OC CLI is older than 4.5, then installs the latest version
#
function check_install_oc() {
    local install=0
    oc_cmd=""

    log "INFO: Checking OpenShift client installation..." 
    type -p oc > /dev/null 2>&1 || install=1
    if [ ${install} -eq 0 ]; then
        oc_cmd=$(type -p oc)
        oc_version=$(oc version | grep "Client Version" | cut -d ":" -f 2 | tr -d " ")
        if [ "${oc_version}" == "" ] ||
           [[ ${oc_version} == "3."* ]] ||
           [[ ${oc_version} == 4\.[1-9].* ]]; then
            log "INFO: OpenShift client is older than 4.10." 
            install=1
        fi
    fi

    if [ ${install} -eq 1 ]; then
        log "INFO: Installing latest OpenShift client..." 
        # https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/openshift-client-mac.tar.gz
        curl -sL https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/openshift-client-linux.tar.gz | tar xzf - -C /usr/local/bin 
        log "INFO: Installed latest OpenShift client."
        ${oc_cmd} version
    fi
}


#
# CLI for AWS
#
function install_aws_cli() {
    local result=0

    # https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2-linux.html
    log "INFO: Checking AWS client installation..." 
    aws --version > /dev/null 2>&1 || result=1
    if [ ! ${result} -eq 0 ]; then
        local unpack_dir="${WORKDIR}"
        curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "${unpack_dir}/awscliv2.zip" \
        && unzip -qq "${unpack_dir}/awscliv2.zip" -d "${unpack_dir}" \
        && "${unpack_dir}/aws/install" -b /usr/local/bin \
        && result=0 \
        || result=1
    fi

    if [ ${result} -eq 0 ]; then
        log "INFO: Installed AWS CLI."
    else
        log "ERROR: AWS CLI installation failed."
    fi

    return ${result}
}



#
# CLI for Azure
#
# https://docs.microsoft.com/en-us/cli/azure/install-azure-cli-linux?pivots=apt&view=azure-cli-latest
#
function install_azure_cli() {
    local result=0

    log "INFO: Checking Azure client installation..." 
    az version > /dev/null 2>&1 || result=1
    if [ ! ${result} -eq 0 ]; then
        local unpack_dir="${WORKDIR}"
        curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash \
        && result=0 \
        || result=1
    fi

    if [ ${result} -eq 0 ]; then
        log "INFO: Installed Azure CLI."
    else
        log "ERROR: Azure CLI installation failed."
    fi

    return ${result}
}


#
# CLI for RedHat OpenShift on AWS.
#
function install_rosa_cli() {
    local result=0

    log "INFO: Checking ROSA client installation..." 
    rosa version > /dev/null 2>&1 || result=1
    if [ ! ${result} -eq 0 ]; then
        curl -sL https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/rosa/latest/rosa-linux.tar.gz \
            | tar xzf - -C /usr/local/bin --no-same-owner \
        && result=0 \
        || result=1
    fi

    if [ ${result} -eq 0 ]; then
        log "INFO: Installed latest ROSA CLI."
    else
        log "ERROR: ROSA CLI installation failed."
    fi

    return ${result}
}


#
# Waits for all PVCs to be Ready
#
function oc_wait_pvcs() {
    local result=0

    local current_seconds=0
    local operation_limit_seconds=$(( $(date +%s) + 7200 ))
    local pending_pvc=1
    log "INFO: Waiting for all PVCs to be ready."
    while [[ ${current_seconds} -lt ${operation_limit_seconds} ]]; do
        local nodes_status=0
        local oc_pvc_output="${WORKDIR}/oc_pvc.txt"
        ${oc_cmd} get pvc --all-namespaces > "${oc_pvc_output}" \
            || nodes_status=1

        if [ ${nodes_status} -eq 0 ]; then
            grep "Pending" "${oc_pvc_output}" \
                || pending_pvc=0
            if [ "${pending_pvc}" -eq 0 ]; then
                log "INFO: All PVCs are ready."
                ${oc_cmd} get pvc --all-namespaces
                break
            fi
        fi
        log "INFO: Waiting on PVCs(s)..."
        if [ "${verbose}" -eq 1 ]; then
            grep "Pending" "${oc_pvc_output}"
        fi
        sleep 60
        current_seconds=$(( $(date +%s) ))
    done
    if [ ! "${pending_pvc}" -eq 0 ]; then
        result=1
        log "ERROR: Not all nodes are in a ready state."
    fi

    return ${result}
}


#
# Waits for all nodes to be Ready
#
function oc_wait_nodes() {
    local result=0

    local current_seconds=0
    local operation_limit_seconds=$(( $(date +%s) + 7200 ))
    local pending_nodes=1
    log "INFO: Waiting for all nodes to be ready."
    sleep 60
    while [[ ${current_seconds} -lt ${operation_limit_seconds} ]]; do
        local nodes_status=0
        local oc_nodes_output="${WORKDIR}/oc_nodes.txt"
        ${oc_cmd} get nodes > "${oc_nodes_output}" \
            || nodes_status=1

        if [ ${nodes_status} -eq 0 ]; then
            grep "NotReady\|SchedulingDisabled" "${oc_nodes_output}" \
                || pending_nodes=0
            if [ "${pending_nodes}" -eq 0 ]; then
                log "INFO: All nodes are ready."
                ${oc_cmd} get nodes
                break
            fi
        fi
        log "INFO: Waiting on worker(s)..."
        if [ "${verbose}" -eq 1 ]; then
            grep "NotReady\|SchedulingDisabled" "${oc_nodes_output}"
        fi
        sleep 60
        current_seconds=$(( $(date +%s) ))
    done
    if [ ! "${pending_nodes}" -eq 0 ]; then
        result=1
        log "ERROR: Not all nodes are in a ready state."
    fi

    oc wait Node --for=condition=Ready=true --all --timeout=7200s \
        || result=1

    if [ ! "${result}" -eq 0 ]; then
        result=1
        log "ERROR: Not all nodes are in a ready state."
    fi

    return "${result}"
}


#
# Waits on the IBM Cloud cluster to be ready to accept requests.
#
# arg1 cluster_name
#
function wait_for_ibm_cloud_cluster() {
    local cluster_name=$1

    local result=0

    local deployed_id=""
    local current_seconds=0
    local operation_limit_seconds=$(( $(date +%s) + 14400 ))
    local cluster_status_file="${WORKDIR}/cluster_status.json"
    while [[ "${deployed_id}" == "" ]]  && [[ ${current_seconds} -lt ${operation_limit_seconds} ]]; do
        ibmcloud oc cluster get -s --cluster "${cluster_name}" --json > "${cluster_status_file}"
        local vpc_gen2
        vpc_gen2=$(jq 'select(.provider=="vpc-gen2") .provider' "${cluster_status_file}")
        if [ "${vpc_gen2}" != "" ]; then
            deployed_id=$(jq -r '. | select(.ingress.status=="healthy")
                | select(.state=="normal" or .state=="warning")
                | select(.lifecycle.masterStatus=="Ready")
                | select(.lifecycle.masterState=="deployed") .id' "${cluster_status_file}")
        else
            deployed_id=$(jq -r '. | select(.ingressHostname!="")
                | select(.state=="normal" or .state=="warning")
                | select(.masterStatus=="Ready")
                | select(.masterState=="deployed") .id' "${cluster_status_file}")
        fi
        if [ "${deployed_id}" != "" ]; then
            log "INFO: Cluster ${cluster_name} is ready."
            if [ "${PIPELINE_DEBUG}" -eq 1 ]; then
                json "${cluster_status_file}"
            fi
            break
        fi
        local deployment_status=""
        if [ "${vpc_gen2}" != "" ]; then
            deployment_status=$(jq -r '("state=" + .state
                + ":masterStatus=" + .lifecycle.masterStatus
                + ":masterState=" +  .lifecycle.masterState
                + ":ingress=" + .ingress.Hostname)' "${cluster_status_file}")
        else
            deployment_status=$(jq -r '("state=" + .state
                + ":masterStatus=" + .masterStatus
                + ":masterState=" +  .masterState
                + ":ingress=" + .ingress.hostname)' "${cluster_status_file}")
        fi
        log "INFO: Pending deployment for cluster [${cluster_name}]. Status is [${deployment_status}]. Waiting..."
        sleep 60
        current_seconds=$(( $(date +%s) ))
    done

    if [ "${deployed_id}" == "" ]; then
        log "ERROR: Cluster request for ${cluster_name} failed. Last known status is [${deployment_status}]."
        result=1
    fi

    return ${result}
}


#
# Checks whether user is already logged in, otherwise logs the user in.
# 
# arg1 name of the cluster for the login
# arg2 username for the target cloud
# arg3 apikey for the target cloud
#
function login_ibm_cloud() {
    local cluster_name=${1}
    local username=${2}
    local api_key=${3}

    local result=0
 
    log "INFO: Login in to IBM cloud."
    local login_output="${WORKDIR}/login.txt"
    ibmcloud login --apikey "${api_key}" \
        -a "${IBM_CLOUD_API}" \
        -q \
        -g "${IBM_CLOUD_GROUP}" \
        -r "${IBM_CLOUD_REGION}" > "${login_output}" 2>&1 \
            || result=1
    if [ ${result} -eq 1 ] || [ ${verbose} -eq 1 ]; then
        cat "${login_output}"
    fi

    if [ ${result} -eq 0 ] && [ -n "${cluster_name}" ]; then
        ibmcloud oc cluster config --cluster "${cluster_name}" -q \
            || 
        {
            log "ERROR: Unable to locate cluster [${cluster_name}]."
            result=1
        }
        if [ ${result} -eq 0 ]; then
            log "INFO: Login to IBM cloud was successful."
            local oc_cmd_login="${WORKDIR}/oc_login.txt"
            "${oc_cmd}" login -u apikey -p "${api_key}" > "${oc_cmd_login}" 2>&1 \
                || result=1

            if [ ${result} -eq 0 ]; then
                log "INFO: Login to OpenShift was successful."
            else
                log "ERROR: Unable to login to OpenShift cluster [${cluster_name}]."
                cat "${oc_cmd_login}"
            fi
        fi
    fi

    return ${result}
}


#
# Checks whether the cluster passed as a parameter exists on IBM Cloud. 
# 
# arg1 cluster type, e.g. ibmcloud or ibmcloud-gen2
# arg2 name of the cluster to be checked
# arg3 username for the target cloud
# arg4 apikey for the target cloud
# arg5 whether or not to wait for the cluster to be up if still being created
#      1=wait | 0=do not wait
#
function check_ibm_cloud_cluster() {
    local cluster_type=${1}
    local cluster_name=${2}
    local username=${3}
    local api_key=${4}
    local wait_cluster=${5:-0}

    local result=0

    login_ibm_cloud "" "${username}" "${api_key}" \
        || result=1
    if [ ${result} -eq 1 ]; then
        log "ERROR: Status check failed for IBM Cloud cluster [${cluster_name}]."
        result=1
    else
        local cluster_id
        local cluster_provider=classic
        if [ "${cluster_type}" == "ibmcloud-gen2" ]; then
            cluster_provider=vpc-gen2
        fi

        cluster_id=$(ibmcloud oc cluster ls --provider "${cluster_provider}" --output json | \
            jq -r --arg cluster_name "${cluster_name}" '.[] | select(.name==$cluster_name) .id')

        if [ -n "${cluster_id}" ]; then
            log "INFO: Cluster [${cluster_name}] located in IBM Cloud in resource group [${IBM_CLOUD_GROUP}]."
            result=0
            if [ "${wait_cluster}" -eq 1 ]; then
                wait_for_ibm_cloud_cluster "${cluster_name}" || result=1
            fi
        else
            log "INFO: Cluster [${cluster_name}] not found in IBM Cloud in resource group [${IBM_CLOUD_GROUP}]."
        fi
    fi

    return ${result}
}


#
# Waits on the ROSA cluster to be ready to accept requests.
#
# arg1 cluster_name
#
function wait_for_rosa_cluster() {
    local cluster_name=$1

    local result=0

    local deployed_id=""
    local deployment_status=""
    local current_seconds=0
    local operation_limit_seconds=$(( $(date +%s) + 7200 ))
    local cluster_status_file="${WORKDIR}/cluster_status.json"
    while [[ "${deployed_id}" == "" ]]  && [[ ${current_seconds} -lt ${operation_limit_seconds} ]]; do
        deployment_status=$(rosa describe cluster -c "${cluster_name}" -o json | tee "${cluster_status_file}" | jq -r .state)
        if [ "${deployment_status}" == "ready" ]; then
            log "INFO: Cluster [${cluster_name}] is ready."
            break;
        fi
        log "INFO: Pending deployment for cluster [${cluster_name}]. Status is [${deployment_status}]. Waiting..."
        sleep 60
        current_seconds=$(( $(date +%s) ))
    done

    if [ "${deployment_status}" != "ready" ]; then
        log "ERROR: Cluster [${cluster_name}] is not ready. Deployment status is: ${deployment_status}."
        result=1
    fi

    if [ "${PIPELINE_DEBUG}" -eq 1 ]; then
        json "${cluster_status_file}"
    fi

    return ${result}
}


#
# Checks whether the cluster passed as a parameter exists on AWS Cloud. 
# 
# arg1 name of the cluster to be checked
# arg2 username for the target cloud
# arg3 apikey for the target cloud
# arg4 ROSA token
# arg5 whether or not to wait for the cluster to be up if still being created
#      1=wait | 0=do not wait
#
function check_rosa_cluster() {
    local cluster_name=${1}
    local username=${2}
    local api_key=${3}
    local rosa_token=${4}
    local wait_cluster=${5:-0}

    local result=0

    login_rosa "" "${username}" "${api_key}" "${rosa_token}" \
        || result=1
    if [ ${result} -eq 1 ]; then
        log "ERROR: Status check failed for ROSA cluster [${cluster_name}]."
        result=1
    else
        rosa describe cluster --cluster "${cluster_name}" \
            || result=1
        if [ "${result}" -eq 0 ]; then
            log "INFO: Cluster [${cluster_name}] located in AWS."
            if [ "${wait_cluster}" -eq 1 ]; then
                wait_for_rosa_cluster "${cluster_name}" || result=1
            fi
        else
            log "INFO: Cluster [${cluster_name}] not found in AWS."
        fi
    fi

    return ${result}
}


#
# Waits on the Fyre cluster to be ready to accept requests.
#
# arg1 cluster_name
# arg2 username for the target cloud
# arg3 apikey for the target cloud
#
function wait_for_fyre_cluster() {
    local cluster_name=$1
    local username=$2
    local api_key=$3

    local result=0

    local deployed_id=""
    local deployment_status=""
    local current_seconds=0
    local operation_limit_seconds=$(( $(date +%s) + 7200 ))
    local cluster_status_file="${WORKDIR}/cluster_status.json"
    while [[ "${deployed_id}" == "" ]]  && [[ ${current_seconds} -lt ${operation_limit_seconds} ]]; do
        http_status=$(curl -s -k -u "${username}:${api_key}" \
            "${FYRE_CLOUD_API}/${cluster_name}" \
            --header "accept: application/json" \
            -w "%{http_code}" \
            -o "${cluster_status_file}")
        if [ "${http_status}" -eq 200 ]; then
            deployment_status=$(jq -r '.clusters[].deployment_status' "${cluster_status_file}")
            if [ "${deployment_status}" == "deployed" ]; then
                log "INFO: Cluster [${cluster_name}] is ready."
                break
            elif [ "${deployment_status}" == "failed" ]; then
                log "ERROR: Cluster [${cluster_name}] creation failed."
                break
            fi
        else
            log "WARNING: Unable to assert deployment status for cluster [${cluster_name}]."
            deployment_status="unknown"
        fi
        log "INFO: Pending deployment for cluster [${cluster_name}]. Status is [${deployment_status}]. Waiting..."
        sleep 60
        current_seconds=$(( $(date +%s) ))
    done

    if [ "${deployment_status}" != "deployed" ]; then
        log "ERROR: Cluster [${cluster_name}] is not ready. Deployment status is: ${deployment_status}."
        result=1
    fi

    if [ "${PIPELINE_DEBUG}" -eq 1 ]; then
        json "${cluster_status_file}"
    fi

    return ${result}
}


#
# Checks whether the cluster passed as a parameter exists on Fyre. 
# 
# arg1 name of the cluster in Fyre
#
function check_fyre_cluster() {
    local cluster_name=$1
    local username=$2
    local api_key=$3
    local status_contents=${4}
    local wait_cluster=${5:-0}

    local result=0
    local http_status
        http_status=$(curl -s -k -u "${username}:${api_key}" "${FYRE_CLOUD_API}/${cluster_name}" \
            --header "accept: application/json" \
        -w "%{http_code}" \
        -o "${status_contents}") || result=1
    if [ ${result} -eq 1 ] || [ "${http_status}" != "200" ]; then
        log "ERROR: Cluster check failed for Fyre cluster ${cluster_name}. HTTP Status: ${http_status}."
        json "${status_contents}"
        echo
        result=1
    else
        result=1
        details=$(jq -r '.details' "${status_contents}")
        if [[ ${details} == *"not found"* ]]; then
            log "INFO: Cluster [${cluster_name}] was recently deleted."
            json "${status_contents}"
            result=1
        else
            local error
            error=$(jq -r .status "${status_contents}")
            if [ "${error}" != "error" ]; then 
                log "INFO: Cluster [${cluster_name}] located on Fyre. Status is [$(jq -r .clusters[].deployment_status "${status_contents}")]."
                result=0
                if [ "${wait_cluster}" -eq 1 ]; then
                    wait_for_fyre_cluster "${cluster_name}" "${username}" "${api_key}" || result=1
                fi
            else
                log "ERROR: Cluster check failed for Fyre cluster [${cluster_name}]. HTTP Status: ${http_status}."
                json "${status_contents}"
                echo
                result=1
            fi
        fi
    fi

    return ${result}
}


#
# Checks whether the cluster passed as a parameter exists. 
# 
# arg1 hostname of the cluster
# arg2 username for the cluster
# arg3 apikey for cluster
#
function login_ocp_cluster() {
    local cluster_name=${1}
    local username=${2}
    local api_key=${3}

    local result=0

    local login_output="${WORKDIR}/oc-login-output.txt"
    local effective_hostname="${cluster_name}"
    if [[ ! "${effective_hostname}" == *\.* ]]; then
        effective_hostname="${effective_hostname}.${AWS_DEFAULT_OCP_DOMAIN}"
    fi
    "${oc_cmd}" login \
        --username="${username}" \
        --password="${api_key}" \
        --server="https://api.${effective_hostname}:6443" \
        --insecure-skip-tls-verify=true > "${login_output}" 2>&1 \
        || result=1

    if [ ${result} -eq 1 ]; then
        log "ERROR: Login to OCP cluster ${cluster_name} failed."
        if [ "${verbose}" -eq 1 ]; then
            cat "${login_output}"
        fi
    else
        log "INFO: Successful login to OCP [${cluster_name}]."
    fi

    return ${result}
}


#
# Checks whether user is already logged in, otherwise logs the user in.
# 
# arg1 name of the cluster for the login
# arg2 username for the target cloud
# arg3 apikey for the target cloud
#
function login_fyre() {
    local cluster_name=${1}
    local username=${2}
    local api_key=${3}

    local result=0
 
    local status_contents="${WORKDIR}/fyre_status_content.json"
    check_fyre_cluster "${cluster_name}" "${username}" "${api_key}" "${status_contents}" \
        && 
    {
        local kubeadmin_password
        local api_url
        local oc_cmd_login="${WORKDIR}/oc_login.txt"

        kubeadmin_password=$(jq -r .clusters[].kubeadmin_password "${status_contents}") \
        && api_url=$(jq -r '.clusters[].access_url' "${status_contents}" | sed "s|https://console-openshift-console|api|g") \
        && log "INFO: Obtained API URL: ${api_url}." \
        && "${oc_cmd}" login -u kubeadmin -p "${kubeadmin_password}" \
                --insecure-skip-tls-verify=true \
                --server="https://${api_url}:6443" > "${oc_cmd_login}" 2>&1 \
        && log "INFO: Successful API login." \
        || 
        {
            result=1
            cat "${oc_cmd_login}"
        }
    } || result=1

    return ${result}
}


#
# Checks whether user is already logged in, otherwise logs the user in.
# 
# arg1 name of the cluster for the login
# arg2 username for the target cloud
# arg3 apikey for the target cloud
#
function login_rosa() {
    local cluster_hostname=${1}
    local username=${2}
    local api_key=${3}
    local rosa_token=${4}

    local result=0

    local cluster_name=${cluster_hostname//.*/}
 
    log "INFO: Login in to AWS cloud."
    mkdir -p ~/.aws
    grep "\[profile default\]" ~/.aws/config > /dev/null 2>&1 \
    || cat <<EOF >> ~/.aws/config
[profile default]
region = ${AWS_CLOUD_REGION}
output = json
EOF

    grep "\[default\]" ~/.aws/credentials > /dev/null 2>&1 \
    || cat <<EOF >> ~/.aws/credentials
[default]
aws_access_key_id = ${username}
aws_secret_access_key = ${api_key}
EOF

    rosa login --token="${rosa_token}" \
        || result=1

    if [ ${result} -eq 0 ] && [ -n "${cluster_name}" ]; then
        if [ ${result} -eq 0 ]; then
            log "INFO: Login to AWS cloud was successful."

            local rosa_admin_file=${WORKDIR}/rosa_admin.txt
            local no_admin=0
            rosa describe admin --cluster="${cluster_name}" | tee "${rosa_admin_file}"
            grep "oc login" "${rosa_admin_file}" \
                || no_admin=1

            if [ ${no_admin} -eq 1 ]; then
                rosa create admin --cluster="${cluster_name}" | tee "${rosa_admin_file}" || result=1

                if [ ${result} -eq 0 ]; then
                    result=1
                    # shellcheck disable=SC2034
                    for i in {1..20}
                    do 
                        eval "$(grep "oc login" "${rosa_admin_file}") --insecure-skip-tls-verify=true" > /dev/null 2>&1 \
                        && {
                            result=0
                            break
                        }
                        log "INFO: Admin still not valid, waiting some more."
                        sleep 20
                    done
                    if [ ${result} -eq 1 ]; then
                        log "ERROR: Admin login not valid after multiple attempts."
                    fi
                fi
            else
                login_ocp_cluster "${cluster_hostname}" "${username}" "${api_key}" \
                || result=1
            fi

            if [ ${result} -eq 0 ]; then
                log "INFO: Login to OpenShift was successful."
            else
                log "ERROR: Unable to login to OpenShift cluster [${cluster_hostname}]."
                cat "${rosa_admin_file}"
            fi
        fi
    fi

    return ${result}
}


#
# Login to target cloud infrastructure
#
# arg1 infrastructure type of cluster to be deleted
# arg2 name of the cluster to be checked
# arg3 username for the target cloud
# arg4 apikey for the target cloud
# arg5 OCP key if creating a managed OCP cluster (other than ROKS)
#
function login_cluster() {
    local cluster_type=${1}
    local cluster_name=${2}
    local username=${3}
    local api_key=${4}
    local managed_ocp_token=${5}
    local retries=${6:-1}

    local result

    for attempt in $(seq 1 "${retries}")
    do
        result=0
        case ${cluster_type} in
            aws|ocp)
                login_ocp_cluster "${cluster_name}" "${username}" "${api_key}" \
                    || result=1
            ;;
            fyre|fyre-quick-burn)
                login_fyre "${cluster_name}" "${username}" "${api_key}" \
                    || result=1
            ;;
            ibmcloud|ibmcloud-gen2)
                login_ibm_cloud "${cluster_name}" "${username}" "${api_key}" \
                    || result=1
            ;;
            rosa)
                login_rosa "${cluster_name}" "${username}" "${api_key}" "${managed_ocp_token}" \
                    || result=1
            ;;
            *)
            echo "Unrecognized cluster type: ${cluster_type}"
            return 1
        esac

        if [ ${result} -eq 0 ]; then
            break;
        else
            log "WARNING: Login failed on attempt ${attempt}"
            sleep 60
        fi
    done

    if [ ${result} -eq 1 ]; then
        log "ERROR: Successive login attempts failed."
    fi

    return ${result}
}


#
# https://docs.openshift.com/container-platform/4.6/security/certificates/replacing-default-ingress-certificate.html
# +
# https://access.redhat.com/solutions/4542531
#
# arg1 domain name in the certificate to be applied.
#
function apply_signed_cert() {
    local domain_name=${1}

    local result=0

    local ca_signing_path="${PKI_PATH:?}/ca/intermediate"
    local cert_key="${ca_signing_path}/csr/server-${domain_name}.key"
    local cert_file="${ca_signing_path}/newcerts/server-${domain_name}.pem"
    local cert_chain_file="${WORKDIR}/cert_chain_file.pem"

    local router_secret_name=router-certs
    local api_secret_name=api-certs
    local server_show
    server_show=$("${oc_cmd}" whoami --show-server | cut -f 2 -d ':' | cut -f 3 -d '/' | sed 's/-api././') \
        && "${oc_cmd}" delete configmap custom-ca \
            --namespace openshift-config \
            --ignore-not-found=true \
        && "${oc_cmd}" create configmap custom-ca \
            --from-file=ca-bundle.crt="${ca_signing_path}/certs/ca-chain.cert.pem" \
            --namespace openshift-config \
        && "${oc_cmd}" patch proxy/cluster \
            --type=merge \
            --patch='{"spec":{"trustedCA":{"name":"custom-ca"}}}' \
        && "${oc_cmd}" delete secret tls "${router_secret_name}" \
            --namespace openshift-ingress \
            --ignore-not-found=true \
        && cat \
            "${cert_file}" \
            "${ca_signing_path}/certs/ca-chain.cert.pem" > "${cert_chain_file}" \
        && "${oc_cmd}" create secret tls "${router_secret_name}" \
            --cert="${cert_chain_file}" \
            --key="${cert_key}" \
            --namespace openshift-ingress \
        && "${oc_cmd}" patch ingresscontroller.operator default \
            --type=merge -p "{\"spec\":{\"defaultCertificate\": {\"name\": \"${router_secret_name}\" }}}" \
            --namespace openshift-ingress-operator \
        && "${oc_cmd}" delete secret tls "${api_secret_name}" \
            --namespace openshift-config \
            --ignore-not-found=true \
        && "${oc_cmd}" create secret tls "${api_secret_name}" \
            --cert="${cert_chain_file}" \
            --key="${cert_key}" \
            --namespace openshift-config \
        && "${oc_cmd}" patch apiserver cluster \
            --type merge \
            --patch="{\"spec\": {\"servingCerts\": {\"namedCertificates\": [ { \"names\": [  \"${server_show}\"  ], \"servingCertificate\": {\"name\": \"${api_secret_name}\" }}]}}}" \
        && log "INFO: Waiting for cluster operators to start cycling" \
        && sleep 60 \
        && log "INFO: Waiting for cluster operators to be ready." \
        && "${oc_cmd}" wait ClusterOperator kube-apiserver --for=condition=Progressing=False --timeout=1200s \
        && "${oc_cmd}" wait ClusterOperator authentication --for=condition=Progressing=False --timeout=1200s \
        || result=1

    if [ ${result} -eq 0 ]; then
        log "INFO: Successfully configured OpenShift cluster ingress."
    else
        log "ERROR: Unable to configure OpenShift cluster ingress."
    fi

    return ${result}
}


#
# Configures the ingress of the OpenShift cluster with a signed cert.
#
function config_ingress() {
    local cluster_type=${1}

    local result=0

    if [ "${cluster_type}" == "aws" ]; then
        config_ingress_letsencrypt "${cluster_type}" || result=1
    else
        if [ -z "${PKI_PWD}" ]; then
            log "INFO: No PKI password was supplied. Skipping ingress configuration."
            return 0
        fi

        local domain_name
        # shellcheck disable=SC2154
        domain_name=$(oc get ingress.config.openshift.io cluster -o jsonpath="{.spec.domain}") \
            && log "INFO: Generate signed certificate." \
            && PKI_PATH=${PKI_PATH} "${scriptdir}/generate-ca.sh" --domain "${domain_name}" --signpass "${PKI_PWD}" \
            && log "INFO: Signed certificate generated successfully." \
            && apply_signed_cert "${domain_name}" \
            || result=1
    fi

    return ${result}
}


#
# Configures the ingress of the OpenShift cluster with a cert from Let's Encrypt.
#
# https://cloud.redhat.com/blog/requesting-and-installing-lets-encrypt-certificates-for-openshift-4
#
# arg1 cluster type, e.g. ibmcloud or ibmcloud-gen2
# 
function config_ingress_letsencrypt() {
    local cluster_type=${1}

    local result=0

    local acme_dir="${WORKDIR}/acme.sh"
    local LE_API
    local LE_WILDCARD
    local CERTDIR="${acme_dir}/certificates"

    # Not needed anymore, due to:
    # https://community.letsencrypt.org/t/the-acme-sh-will-change-default-ca-to-zerossl-on-august-1st-2021
    # "${acme_dir}/acme.sh/acme.sh" --register-account -m dnastacio@gmail.com \

    rm -rf "${acme_dir}/acme.sh" \
    && git clone https://github.com/acmesh-official/acme.sh.git \
        -b 3.0.0 \
        --depth 1 \
        "${acme_dir}/acme.sh" \
    && LE_API=$(oc whoami --show-server | cut -f 2 -d ':' | cut -f 3 -d '/' | sed 's/-api././') \
    && LE_WILDCARD=$(oc get ingresscontroller default -n openshift-ingress-operator -o jsonpath='{.status.domain}') \
    && log "INFO: Starting issuance of Let's Encrypt certs" \
    && "${acme_dir}/acme.sh/acme.sh" --issue -d "${LE_API}" -d "*.${LE_WILDCARD}" --server  letsencrypt --dns dns_aws \
    && mkdir -p "${CERTDIR}" \
    && "${acme_dir}/acme.sh/acme.sh" \
            --install-cert -d "${LE_API}" -d "*.${LE_WILDCARD}" \
            --cert-file "${CERTDIR}/cert.pem" \
            --key-file "${CERTDIR}/key.pem" \
            --fullchain-file "${CERTDIR}/fullchain.pem" \
            --ca-file "${CERTDIR}/ca.cer" \
    && log "INFO: Applying ingress cert" \
    && oc create secret tls router-certs \
            --cert="${CERTDIR}/fullchain.pem" \
            --key="${CERTDIR}/key.pem" \
            -n openshift-ingress \
    && oc patch ingresscontroller default \
            -n openshift-ingress-operator \
            --type=merge \
            --patch='{"spec": { "defaultCertificate": { "name": "router-certs" }}}' \
    || result=1

    if [ ${result} -eq 0 ] && [ "${cluster_type}" == "aws" ]; then
        log "INFO: Applying API server cert" \
        && oc create secret tls api-certs \
                --cert="${CERTDIR}/fullchain.pem" \
                --key="${CERTDIR}/key.pem" \
                -n openshift-config \
        && oc patch apiserver cluster \
                --type merge \
                --patch="{\"spec\": {\"servingCerts\": {\"namedCertificates\": [ { \"names\": [  \"$LE_API\"  ], \"servingCertificate\": {\"name\": \"api-certs\" }}]}}}" \
        || result=1
    fi

    if [ ${result} -eq 0 ]; then
        local wait_result=0

        log "INFO: Waiting for cluster operators to resume." \
        && sleep 60 \
        && oc wait pod -l ingresscontroller.operator.openshift.io/deployment-ingresscontroller=default \
                -n openshift-ingress \
                --for=condition=Ready \
                --timeout=600s \
        && oc wait pod -l app=oauth-openshift \
                -n openshift-authentication \
                --for=condition=Ready \
                --timeout=600s \
        && oc wait ClusterOperator kube-apiserver \
                --for=condition=Progressing=False \
                --timeout=600s \
        && oc wait ClusterOperator authentication \
                --for=condition=Progressing=False \
                --timeout=600s \
        || wait_result=1
        
        if [ ${wait_result} -eq 1 ]; then
            log "WARNING: Operators are not reporting ready, but progressing anyway."
        fi
    fi

    return ${result}
}


#
# Configure common services
#
# https://www.ibm.com/docs/en/cpfs?topic=operator-replacing-foundational-services-endpoint-certificates
#
function config_foundation_service_certs() {
    local result=0

    local cert
    local cert_key
    ingress_secret_name=$(oc get ingresscontroller.operator default \
        --namespace openshift-ingress-operator \
        -o jsonpath='{.spec.defaultCertificate.name}') \
    && cert=$(oc get secret "${ingress_secret_name}" \
        --namespace openshift-ingress \
        -o jsonpath='{.data.tls\.crt}' | base64 -d  | sed -e '/END CERTIFICATE/q' |  base64 -w0) \
    && cert_key=$(oc get secret "${ingress_secret_name}" \
        --namespace openshift-ingress \
        -o jsonpath='{.data.tls\.key}') \
    && cacert=$(oc get secret "${ingress_secret_name}" \
        --namespace openshift-ingress \
        -o jsonpath='{.data.tls\.crt}' | base64 -d | sed -e '1,/END CERTIFICATE/d' |  base64 -w0) \
    && oc patch managementingress default \
        -n ibm-common-services \
        --type merge \
        --patch '{"spec":{"ignoreRouteCert":true}}' \
    && oc delete certificates.v1alpha1.certmanager.k8s.io route-cert \
        -n ibm-common-services \
        --ignore-not-found=true \
    && oc patch secret route-tls-secret \
        -n ibm-common-services \
        --type=merge -p \
        "{\"data\": { \"ca.crt\": \"${cacert}\", \"tls.crt\": \"${cert}\", \"tls.key\": \"${cert_key}\"}}" \
    && oc delete secret ibmcloud-cluster-ca-cert \
        -n ibm-common-services \
        --ignore-not-found=true \
    && oc delete pod -l app=auth-idp \
        -n ibm-common-services \
    && log "INFO: Waiting for authentication pods to resume." \
    && oc wait pod -l app=auth-idp \
        --for=condition=Ready --timeout=600s \
        -n ibm-common-services \
    || result=1

    echo "Commands to retrieve Cloud Pak Console URL, user, and credentials, respectively:"
    echo "echo \$(oc get route -n ibm-common-services cp-console -o jsonpath={.status.ingress[].host})"
    echo "echo \$(oc get secret -n ibm-common-services platform-auth-idp-credentials -o jsonpath={.data.admin_username} | base64 --decode)"
    echo "echo \$(oc get secret -n ibm-common-services platform-auth-idp-credentials -o jsonpath={.data.admin_password} | base64 --decode)"

    return ${result}
}


#
# Creates an object storage instance
# 
# arg1 name of the object storage instance to be associated with the cluster
# arg2 name of the Read/Write credential to the object storage
#
function create_cos() {
    local cos_instance_name=${1}
    local cos_rw_cred=${2}

    local result=0

    ibmcloud resource service-instance-create \
        "${cos_instance_name}" \
        cloud-object-storage \
        standard \
        global \
        -g "${IBM_CLOUD_GROUP}" \
    && ibmcloud resource service-key-create \
        "${cos_rw_cred}" Writer \
        -g "${IBM_CLOUD_GROUP}" \
        --instance-name "${cos_instance_name}" \
        --parameters '{"HMAC": true}' \
    || result=1

    return ${result}
}

#
# Get cluster name
# Assumes you are already logged into the cluster
#
function get_cluster_name() {
    local result=0

    cluster_name=$(oc get DNS cluster -o jsonpath="{.spec.baseDomain}" | cut -d "." -f 1)

    if [ -z "${cluster_name}" ]; then
        log "ERROR: Failed to obtain cluster name."
        result=1
        
    else
        log "INFO: Cluster name is ${cluster_name}."
    fi

    return ${result}
}


#
# Upload a file fo a Github repository.
#
# arg1 file to be uploaded
# arg2 timestamp for the file generation. Typically used for cross-referencing the file 
#      upload to other activities.
# arg3 URL for the target GitHub repository. E.g. https://github.com
# arg4 organization/repository for the upload.
# arg5 full pathname inside the repository.
# arg6 username for the upload.
# arg7 password for the user
# arg8 if "1", builds the request, but does not upload the file. Useful for validating
#      whether the operation will succeed.
function upload_file_github() {
    local upload_file=${1}
    local upload_timestamp=${2}
    local github_url=${3:-https://github.ibm.com}
    local github_repository=${4}
    local github_path=${5}
    local github_user=${6}
    local github_password=${7}
    local dryrun=${8:-"0"}

    local result=0

    local payload_file="${WORKDIR}/payload.json"
    cat<<EOF > "${payload_file}"
{
  "message":"Uploaded data for ${upload_timestamp}",
  "content":"$(base64 "${upload_file}")"
}
EOF

    if [ "${dryrun}" -eq 1 ]; then
        log "INFO: Dry-run, otherwise would upload the json file to ${github_repository}."
    else
        local output_file="${WORKDIR}/curl-post-file-results.json"
        local http_status
        http_status=$(curl -s \
            -X PUT \
            -H "Accept: application/vnd.github.v3+json" \
            -u "${github_user}":"${github_password}" \
            "${github_url}/api/v3/repos/${github_repository}/contents/${github_path}" \
            --data @"${payload_file}" \
            -w "%{http_code}" \
            -o "${output_file}") \
        || result=1

        if [ "${http_status}" -eq 200 ] || [ "${http_status}" -eq 201 ]; then
            log "INFO: Added file to repository."
        else
            log "ERROR: Adding file failed. HTTP Status: ${http_status}"
            cat "${output_file}"
        fi
    fi
    
    return ${result}
}


#
# Adds a comment to a GitHub issue.
#
# arg1 github issue number
# arg2 all validation errors in the issue
# arg3 URL for the target GitHub repository. E.g. https://github.com
# arg4 organization/repository for the upload.
# arg5 username for the upload.
# arg6 password for the user
# arg7 if "1", builds the request, but does not upload the file. Useful for validating
#      whether the operation will succeed.
#
function comment_on_issue_github() {
    local issue_number=${1}
    local comment=${2}
    local github_url=${3:-https://github.ibm.com}
    local github_repository=${4}
    local github_user=${5}
    local github_password=${6}
    local dryrun=${7:-"0"}

    local result=0

    local payload_file="${WORKDIR}/payload.json"
    cat<<EOF > "${payload_file}"
{
  "body": "${comment}"
}
EOF

    if [ "${dryrun}" -eq 1 ]; then
        log "INFO: Dry-run, otherwise would post validation comment to issue ${issue_number}"
    else
        local output_file="${WORKDIR}/curl-post-issue-results.json"
        local http_status
        http_status=$(curl -s -X POST \
            -u "${github_user}":"${github_password}" \
            "${github_url}/api/v3/repos/${github_repository}/issues/${issue_number}/comments" \
            --data @"${payload_file}" \
            -w "%{http_code}" \
            -o "${output_file}") \
        || result=1
        if [ "${http_status}" -eq 200 ] || [ "${http_status}" -eq 201 ]; then
            log "INFO: Added comment to issue: ${issue_number}"
        else
            log "ERROR: Adding comment failed for issue: ${issue_number}. HTTP Status: ${http_status}"
            cat "${output_file}"
        fi
    fi

    return ${result}
}


