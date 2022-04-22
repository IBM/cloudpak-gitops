#!/bin/bash
set -eo pipefail

original_dir=$PWD
scriptname=$(basename "${0}")
scriptdir=$(dirname "${0}")
descriptors_dir="${scriptdir}/../descriptors"

verbose=0

#
# Input parameters
#
: "${NEW_CLUSTER_TYPE:=fyre-quick-burn}"

: "${FYRE_USERNAME:=need-fyre-username}"
: "${FYRE_API_KEY:=need-fyre-apikey}"
: "${FYRE_ROOT_PWD:=need-fyre-root-password}"

: "${IBM_CLOUD_API:=https://cloud.ibm.com}"
: "${IBM_CLOUD_USERNAME:=iamapikey}"
: "${IBM_CLOUD_API_KEY:=really needs to be set by caller}"

: "${GITOPS_REPO:=https://github.com/IBM/cloudpak-gitops.git}"
: "${GITOPS_BRANCH:=HEAD}"
: "${GITHUB_PAT:=""}"

: "${GITOPS_NAMESPACE:=openshift-gitops}"

: "${GITOPS_APP_NAMESPACE:=ibm-cloudpaks}"

github_user="x-oauth-basic"

#
# Usage statement
#
function usage() {
    set +x
    echo "Configures GitOps on an OCP cluster."
    echo ""
    echo "Usage: ${scriptname} [OPTIONS]...[ARGS]"
    echo
    echo "   -t | --type <aws|fyre|fyre-quick-burn|ibmcloud|ibmcloud-gen2|rosa>"
    echo "                      Indicates the type of cluster to be built. Default is: fyre-quick-burn"
    echo "   -r | --rhacm-server <server_name>"
    echo "                      Uses RHACM to create the cluster. "
    echo "   -n | --cluster <name>"
    echo "                      Name of the server containing the ArgoCD definitions."
    echo "   -s | --setup-server"
    echo "                      Adds OpenShift GitOps operator and dependencies"
    echo "                      to cluster with name <name>."
    echo "   -c | --setup-client"
    echo "                      Installs CLIs and log them into target cluster."
    echo "        --test"
    echo "                      Validates entire setup."
    echo "        --gitops-repo <git-url>"
    echo "                      Companion to the --setup-server command".
    echo "                      URL of the git repository containing the default GitOps repo"
    echo "                      when configuring gitops on the server. The default is:"
    echo "                      ${GITOPS_REPO}"
    echo "        --gitops-branch <git-branch>"
    echo "                      Companion to the --setup-server command".
    echo "                      branch of the git repository containing the default GitOps repo"
    echo "                      when configuring gitops on the server. The default is:"
    echo "                      ${GITOPS_BRANCH}"
    echo "   -l | --application-labels <label1, label2, ..., label N>"
    echo "                      Companion to the --setup-server command."
    echo "                      Comma-separated list of labels for installation of applications."
    echo "                      Labels are the name of the application in the gitops repository." 
    echo "                      The value for each label is the namespace for the installation of the application."
    echo "   -p | --github-pat"
    echo "                      Companion to the --setup-server command."
    echo "                      Personal access token for the gitops repo if it is a private repository."
    echo "   -u | --username"
    echo "                      User for cluster owner if the cluster type is \"fyre\"."
    echo "   -a | --apikey"
    echo "                      API Key in the target platform."
    echo "        --ocp-token"
    echo "                      Key or token for managed OCP platform if not ROKS."
    echo ""
    echo "   -v | --verbose     Prints extra information about each command."
    echo "   -h | --help        Output this usage statement."

    if [ "${PIPELINE_DEBUG}" -eq 1 ]; then
        set -x
    fi
}

# shellcheck disable=SC1090
# shellcheck disable=SC1091
source "${scriptdir}/common.sh"

#
# Clean up at end of task
#
cleanRun() {
    cd "${original_dir}"
    if [ -n "${WORKDIR}" ]; then
        rm -rf "${WORKDIR}"
    fi
}


#
# Updates the target branch for all ArgoCD applications on a namespace
# 
# arg1 name of the new gitops branch
# arg2 namespace for the ArgoCD applications to be patched
#
function set_argo_branch() {
    local new_branch=${1}
    local namespace=${2:-openshift-gitops}
    
    kubectl get Application --namespace "${namespace}" \
        -o go-template='{{range .items}}{{.metadata.name}}{{"\n"}}{{end}}' \
        | xargs -Iargoapp \
            kubectl patch Application argoapp \
                --namespace "${namespace}" \
                --patch "\"spec\": { \"source\": { \"targetRevision\":\"${new_branch}\" } }" \
                --type merge
}


#
# Creates all secrets referenced in the gitops repo
#
# arg1 GitHub personal access token for the target git repository
#
function create_secrets() {
    local github_pat=${1}

    local result=0

    local target_namespace=cicd

    # shellcheck disable=SC2154
    oc project "${target_namespace}" > /dev/null 2>&1 \
        || oc new-project "${target_namespace}"

    log "INFO: Creating all secrets used in this repo."

    local registry_email="cicd@nonexistent.email.ibm.com"
    oc create secret docker-registry ibm-entitlement-key \
        --docker-server="${CP_ICR_IO_REPO}" \
        --docker-username="${CP_ICR_IO_USERID}" \
        --docker-password="${CP_ICR_IO_PASSWORD}" \
        --docker-email="${registry_email}" \
        --namespace="${GITOPS_NAMESPACE}"

    cat <<EOF | oc apply -f -
---
apiVersion: v1
kind: Secret
metadata:
  name: git-host-basic-auth-token
  annotations:
    tekton.dev/git-0: https://github.ibm.com
type: kubernetes.io/basic-auth
stringData:
  username: x-oauth-basic
  password: ${GITHUB_IBM_PAT} 
EOF

    cat <<EOF | oc apply -f -
---
apiVersion: v1
kind: Secret
metadata:
  name: git-host-access-token
type: Opaque
stringData:
  token: ${GITHUB_IBM_PAT} 
EOF

    cat <<EOF | oc apply -f -
---
apiVersion: v1
kind: Secret
metadata:
  name: gitops-webhook-secret
type: Opaque
stringData:
  webhook-secret-key: '0123456789'
EOF

    cat <<EOF | oc apply -f -
---
apiVersion: v1
kind: Secret
metadata:
  name: webhook-secret-dev-gitops-service
type: Opaque
stringData:
  webhook-secret-key: '0123456789'
EOF

    if [ ${result} -eq 0 ]; then
        log "INFO: Created all secrets used in this repo."
    else
        log "ERROR: Unabled to create all secrets used in this repo."
    fi

    return ${result}
}


#
# Replaces the TLS for Argo servers with the default ingress cert
#
# https://argoproj.github.io/argo-cd/operator-manual/tls/
#
function set_argo_tls() {
    local result=0

    local argo_secret_name=openshift-gitops-tls

    local cert
    local cert_key

    local ingress_secret_name
    ingress_secret_name=$(oc get ingresscontroller.operator default \
        --namespace openshift-ingress-operator \
        -o jsonpath='{.spec.defaultCertificate.name}') || result=1

    if [ -n "${ingress_secret_name}" ] && [ "${result}" -eq 0 ]; then
        cert=$(oc get secret "${ingress_secret_name}" \
            --namespace openshift-ingress \
            -o jsonpath='{.data.tls\.crt}') \
        && cert_key=$(oc get secret "${ingress_secret_name}" \
            --namespace openshift-ingress \
            -o jsonpath='{.data.tls\.key}') \
        && oc patch secret "${argo_secret_name}" \
            --namespace openshift-gitops \
            --type=merge -p \
            "{\"data\": { \"tls.crt\": \"${cert}\", \"tls.key\": \"${cert_key}\"}}" \
        && log "INFO: Successfully set ArgoCD TLS certificate on secret ${argo_secret_name}." \
        || result=1
    else
        log "INFO: Not setting ArgoCD TLS certificate: no default certificate name for the ingress."
    fi

    return ${result}
}


#
# Adds the bootstrap argocd repository to the server.
#
# arg1 Git URL for the default gitops repository.
# arg2 Git branch for the default gitops repository.
# arg3 GitHub personal access token for the target git repository.
# arg4 Comma-separated list of labels for pre-installation of applications.
#
function add_argo_cd_app() {
    local gitops_repo=${1}
    local gitops_branch=${2}
    local github_pat=${3}
    local app_labels=${4}

    local result=0

    while [ ! "$(oc get namespace "${GITOPS_NAMESPACE}" -o jsonpath="{.status.phase}")" == "Active" ] ||
          [ "$(oc get configmap/argocd-cm --namespace ${GITOPS_NAMESPACE}  | wc -l)" -eq 0 ];
    do
        log "INFO: Waiting for the ${GITOPS_NAMESPACE} namespace to be deployed."
        sleep 60
    done

    log "INFO: Adding the base GitOps application from ${gitops_repo}."
    local github_secret=github-cloudpak-bring-up

    # Creates a secret for accessing the default gitops repo.
    local git_secret_file="${WORKDIR}/argo-git-secret.yaml"
    cat<<EOF > "${git_secret_file}"
kind: Secret
apiVersion: v1
metadata:
  name: ${github_secret}
  annotations:
    managed-by: argocd.argoproj.io
stringData:
  password: ${github_pat}
  username: x-oauth-basic
type: Opaque
EOF

    oc apply \
        -f "${git_secret_file}" \
        --namespace "${GITOPS_NAMESPACE}" \
    || result=1

    log "INFO: Update Argo configuration with Git repo secret."
    # https://argoproj.github.io/argo-cd/operator-manual/declarative-setup/ 
    local argo_patch_json="${WORKDIR}/argo-patch.json"
    cat<<EOF > "${argo_patch_json}"
{
    "data": {"repositories": "- passwordSecret:\n    key: password\n    name: ${github_secret}\n  type: git\n  url: ${gitops_repo}\n  usernameSecret:\n    key: username\n    name: ${github_secret}\n"
    }
}
EOF

    oc patch configmap/argocd-cm \
        --namespace "${GITOPS_NAMESPACE}" \
        --type merge \
        --patch-file "${argo_patch_json}" \
        && log "INFO: Argo configuration patched with Git credentials." \
        || result=1

    local gitrepo_workdir="${WORKDIR}/gitrepo"
    local gitops_repo_pwd="${gitops_repo//:\/\//:\/\/${github_user}:${github_pat}@}"
    git clone --depth 1  "${gitops_repo_pwd}" "${gitrepo_workdir}"

    log "INFO: Adding the bootstrap application to the server."
    install_helm || \
    {
        log "ERROR: Unable to install helm client."
        return 1
    }

    install_argocd || \
    {
        log "ERROR: Unable to install argocd client."
        return 1
    }

    local app_path=config/argocd

    argocd app create argo-app \
        --project default \
        --dest-namespace "${GITOPS_NAMESPACE}" \
        --dest-server https://kubernetes.default.svc \
        --helm-set-string repoURL="${gitops_repo}" \
        --helm-set-string targetRevision="${gitops_branch}" \
        --repo "${gitops_repo}" \
        --path "${app_path}" \
        --sync-policy automated \
        --revision "${gitops_branch}" \
        --upsert \
        || result=1

    if [ ${result} -eq 0 ]; then
        log "INFO: Added the base GitOps application from ${gitops_repo}."
    else    
        log "ERROR: Failed to add the base GitOps application from ${gitops_repo}."
    fi

    local default_cp_namespace=${GITOPS_APP_NAMESPACE}
    local argo_apps=()
    for cp in ${app_labels//,/ }
    do
        argo_apps+=("${cp}")
    done

    for cp_labeled in "${argo_apps[@]}"
    do
        local cp=${cp_labeled//:*/}
        local cp_namespace=${cp_labeled//*:/}
        if [ -z "${cp_namespace}" ]; then
            cp_namespace="${default_cp_namespace}"
        fi
        local app_name="${cp}-app"
        local cp_result=0
        local app_path="config/argocd-cloudpaks/${cp}"
        if [ "${cp}" == "rhacm" ]; then
            app_path="config/argocd-rhacm"
        fi
        argocd app create "${app_name}" \
            --project default \
            --dest-namespace "${GITOPS_NAMESPACE}" \
            --dest-server https://kubernetes.default.svc \
            --helm-set-string metadata.argocd_app_namespace="${cp_namespace}" \
            --helm-set-string repoURL="${gitops_repo}" \
            --helm-set-string targetRevision="${gitops_branch}" \
            --path "${app_path}" \
            --repo "${gitops_repo}" \
            --revision "${gitops_branch}" \
            --sync-policy automated \
            --self-heal \
            --upsert \
        && log "INFO: Creation of ${app_name} complete" \
        || cp_result=1

        if [ ${cp_result} -eq 0 ]; then
            log "INFO: Synchronizing ${app_name}" \
            && sleep 30 \
            && argocd app wait \
                --selector app.kubernetes.io/instance="${app_name}" \
                --sync \
                --health \
                --operation \
                --timeout 10800 \
            && log "INFO: Synchronization of ${app_name} complete." \
            || cp_result=1

            argocd app get "${app_name}" || result=1
        else
            log "WARNING: Failed to add the Cloud Pak ${app_name} application from ${gitops_repo}."
        fi
    done

    return ${result}
}


#
# Configures the ArgoCD admin password for AWS and Fyre clusters.
#
# arg1 infrastructure type of the target cluster
# arg2 name of the cluster to be configured
# arg3 username for the target cloud
# arg4 apikey for the target cloud
#
function set_argo_admin_pwd() {
    local cluster_type=${1}
    local cluster_name=${2}
    local username=${3}
    local api_key=${4}

    local result=0

    case ${cluster_type} in
        aws|fyre|fyre-quick-burn)
            local kubeadmin_password
            if [[ "${cluster_type}" == *fyre* ]]; then
                local status_contents="${WORKDIR}/fyre_status_content.json"
                check_fyre_cluster "${cluster_name}" "${username}" "${api_key}" "${status_contents}" \
                && kubeadmin_password="$(jq -r .clusters[].kubeadmin_password "${status_contents}")" \
                || result=1
            else
                kubeadmin_password="${api_key}"
            fi

            if [ ${result} -eq 0 ]; then
                oc patch secret openshift-gitops-cluster \
                    --namespace openshift-gitops \
                    --patch "\"data\" : {\"admin.password\": \"$(echo -n "${kubeadmin_password}" | base64)\" }" \
                    --type merge \
                && log "INFO: Patched gitops admin credential." \
                || result=1

                log "INFO: Logging out of Argo context [${argo_url}]." \
                && argocd context \
                && argocd logout "${argo_url}" \
                && sleep 10 \
                && log "INFO: Login Argo admin at [${argo_url}] with new credential." \
                && argocd login "${argo_url}" --username admin --password "${kubeadmin_password}" --insecure
            fi
        ;;
        *)
        log "INFO: Will not change Argo admin password for cluster type: ${cluster_type}"
    esac

    if [ ${result} -eq 1 ]; then
        log "ERROR: Unable to set ArgoCD admin password."
    fi

    return ${result}
}


#
# Adds the Red Hat GitOps operator and dependencies to the cluster.
#
# arg1 infrastructure type of the target cluster
# arg2 name of the cluster to be configured
# arg3 username for the target cloud
# arg4 apikey for the target cloud
# arg5 OCP key if creating a managed OCP cluster (other than ROKS)
# arg6 RHACM server. If not empty, creation done through RHACM server.
# arg7 Git URL for the default gitops repository.
# arg8 Git branch for the default gitops repository.
# arg9 GitHub personal access token for the target git repository
# arg10 Comma-separated list of labels for pre-installation of applications. 
#
function setup_gitops_server() {
    local cluster_type=${1}
    local cluster_name=${2}
    local username=${3}
    local api_key=${4}
    local managed_ocp_token=${5}
    local rhacm_server=${6}
    local gitops_repo=${7}
    local gitops_branch=${8}
    local github_pat=${9}
    local app_labels=${10}

    local result=0

    if [ -n "${rhacm_server}" ]; then
        PIPELINE_DEBUG=${PIPELINE_DEBUG} "${scriptdir}/rhacm.sh" \
            --type "ocp" \
            --cluster "${rhacm_server}" \
            --username "${username}" \
            --apikey "${api_key}" \
            --login \
            --managed-cluster "${cluster_name}" \
        || result=1
    else
        login_cluster "${cluster_type}" "${cluster_name}" "${username}" "${api_key}" "${managed_ocp_token}" 5 \
        || return 1
    fi

    log "INFO: Adding GitOps operators to the cluster."
    oc apply -f "${descriptors_dir}/operators/gitops-operators.yaml" \
        || {
            log "ERROR: Unable to apply operator descriptors."
            return 1
        }

    log "INFO: Applied GitOps operators."
    local current_seconds=0
    local operation_limit_seconds=$(( $(date +%s) + 7200 ))
    result=1
    while [ ${current_seconds} -lt ${operation_limit_seconds} ]; do
        if [[ "$(oc get csv -l "operators.coreos.com/openshift-gitops-operator.openshift-operators=""" -n openshift-operators | grep -c Succeeded)" -gt 0 ]]; then 
            log "INFO: GitOps CSVs in Succeeded state."
            result=0
            break
        fi
        log "INFO: Waiting for GitOps CSVs to be ready."
        sleep 20
        current_seconds=$(( $(date +%s) ))
    done

    if [ "${result}" -eq 1 ]; then
        log "WARNING: Timed out waiting for GitOps operators to be ready."
    fi

    create_secrets "${github_pat}" || \
    {
        result=1
        log "ERROR: Failed to set secrets."
    }

    add_argo_cd_app "${gitops_repo}" "${gitops_branch}" "${github_pat}" "${app_labels}" \
        && log "INFO: ArgoCD added to the cluster." \
        || result=1

    if [ "${result}" -eq 1 ]; then
        log "ERROR: GitOps operators or instances could not be added to the cluster."
        oc get csv -n openshift-operators
    fi

    set_argo_branch "${gitops_branch}" || \
        log "WARNING: Unable to set target branch."

    set_argo_tls || \
    {
        result=1
        log "ERROR: Failed to set Argo TLS."
    }

    # Patch ArgoCD admin password
    set_argo_admin_pwd "${cluster_type}" "${cluster_name}" "${username}" "${api_key}" \
        || result=1

    if [ "${result}" -eq 0 ]; then
        log "INFO: GitOps setup complete on cluster ${cluster_name}."
    else
        log "ERROR: GitOps setup failed on cluster ${cluster_name}."
    fi

    return ${result}
}


#
# Installs the helm client if not already installed.
#
function install_helm() {
    local result=1
    curl -sL https://get.helm.sh/helm-v3.5.2-linux-amd64.tar.gz | tar xzf - -C "${WORKDIR}" \
        && install "${WORKDIR}/linux-amd64/helm" /usr/local/bin/helm \
        && result=0

    return ${result}
}

#
# Installs and logs in the argocd client if not already installed.
#
# It sets the "argo_route", "argo_secret", and "argo_url" variables
# globally.
#
function install_argocd() {
    local result=0

    local argo_secret=openshift-gitops-cluster

    log "INFO: Checking argocd client installation"
    local argo_route_found=0
    argo_url=$(oc get route openshift-gitops-server -n openshift-gitops -ojsonpath='{.spec.host}') \
        && argo_route_found=1
    if [ ${argo_route_found} -eq 1 ]; then
        type -p argocd > /dev/null 2>&1 \
        ||
        {
            log "INFO: Installing argocd client from ${argo_url}"
            local current_seconds=0
            local operation_limit_seconds=$(( $(date +%s) + 600 ))
            local download_result=1
            while [ ${download_result} -eq 1 ] &&
                  [ ${current_seconds} -lt ${operation_limit_seconds} ]
            do
                curl -skL "${argo_url}/download/argocd-linux-amd64" -o "${WORKDIR}/argocd" \
                    && install -m 755 "${WORKDIR}/argocd" /usr/local/bin/argocd \
                    && download_result=0
                if [ ${download_result} -eq 1 ]; then
                    log "INFO: Waiting for argocd client to be available."
                    sleep 30
                fi
            done

            if [ ${download_result} -eq 1 ]; then
                log "WARNING: Unable to download argocd client."
                result=1
            fi
        }

        if [ ${result} -eq 0 ]; then
            argocd context "${argo_url}" > /dev/null 2>&1 \
            || {
                log "INFO: Logging in argocd client to ${argo_url}"
                local argo_pwd
                argo_pwd=$(oc get secret ${argo_secret} -n openshift-gitops -ojsonpath='{.data.admin\.password}' | base64 -d ; echo ) \
                    && log "INFO: Retrieve ArgoCD admin password with:" \
                    && echo "oc get secret ${argo_secret} -n openshift-gitops -ojsonpath='{.data.admin\.password}' | base64 -d ; echo" \
                    && argocd login "${argo_url}" --username admin --password "${argo_pwd}" --insecure \
                    || result=1
            }
        fi

    else
        log "ERROR: Route to ArgoCD server was not found."
        result=1
    fi

    return ${result}
}


#
# Installs CLIs and logs them into target cluster.
#
# arg1 infrastructure type of the target cluster
# arg2 name of the cluster to be configured
# arg3 username for the target cloud
# arg4 apikey for the target cloud
# arg5 OCP key if creating a managed OCP cluster (other than ROKS)
#
function setup_gitops_clients() {
    local cluster_type=${1}
    local cluster_name=${2}
    local username=${3}
    local api_key=${4}
    local managed_ocp_token=${5}

    local result=0

    install_helm || result=1

    log "INFO: Checking tekton client installation"
    local tekton_version=0.17.1
    tkn version > /dev/null 2>&1 ||
    {
        log "INFO: Installing tekton client."
        curl -skL "https://github.com/tektoncd/cli/releases/download/v${tekton_version}/tkn_${tekton_version}_Linux_x86_64.tar.gz" | \
            tar xzf - -C "${WORKDIR}" \
            && install -m 755 "${WORKDIR}/tkn" /usr/local/bin/tkn \
            || result=1
    }

    log "INFO: Checking gitops client installation"
    login_cluster "${cluster_type}" "${cluster_name}" "${username}" "${api_key}" "${managed_ocp_token}" \
        || result=1

    kam version > /dev/null 2>&1 ||
    {
        local kam_version=0.0.39

        log "INFO: Installing kam client."
        curl -sL "https://github.com/redhat-developer/kam/releases/download/v${kam_version}/kam_linux_amd64" -o "${WORKDIR}/kam" \
            && install -m 755 "${WORKDIR}/kam" /usr/local/bin/kam \
            || result=1
    }

    install_argocd || result=1

    log "INFO: tekton client version"
    tkn version \
        || log "ERROR: tekton client still cannot be found."

    log "INFO: gitops client version"
    kam version \
        || log "ERROR: gitops client still cannot be found."

    log "INFO: argoclient version"
    argocd version \
        log "ERROR: argocd client still cannot be found."

    if [ "${result}" -eq 0 ]; then
        log "INFO: All clients installed and logged in."
    else
        log "ERROR: One or more clients failed to install or login."
    fi

    return ${result}
}


WORKDIR=$(mktemp -d) || exit 1
trap cleanRun EXIT

apikey=""
cluster_name=""
cluster_type="${NEW_CLUSTER_TYPE}"
setup_server=0
setup_client=0
gitops_repo="${GITOPS_REPO}"
gitops_branch="${GITOPS_BRANCH}"
github_pat="${GITHUB_PAT}"
test=0
username=""
rhacm_server=""
app_labels=""
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
    --gitops-repo)
    gitops_repo=$1
    shift
    ;;
    --gitops-branch)
    gitops_branch=$1
    shift
    ;;
    -p|--github-pat)
    github_pat=$1
    shift
    ;;
    -s|--setup-server)
    setup_server=1
    ;;
    -c|--setup-client)
    setup_client=1
    ;;
    -l|--application-labels)
    app_labels=$1
    shift
    ;;
    --test)
    test=1
    ;;
    -a|--apikey)
    apikey=$1
    shift
    ;;
    --ocp-token)
    managed_ocp_token=$1
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
    -h|--help)
    usage
    exit
    ;;
    -v|--verbose)
    # shellcheck disable=SC2034
    verbose=1
    ;;
    *)
    echo "Unrecognized parameter: ${key}"
    usage
    exit 1
esac
done

cmd_count=$((setup_server + setup_client))

if [ ${cmd_count} -eq 0 ]; then
    log "ERROR: No command was specified [setup-server, setup-client]."
    exit 1
fi
if [ ${cmd_count} -gt 1 ]; then
    log "ERROR: Only one command can be specified [setup-server, setup-client]."
    exit 1
fi

if [ -z "${cluster_name}" ]; then
    log "ERROR: A cluster name was not specified."
    exit 1
fi

cluster_type=${NEW_CLUSTER_TYPE}

case ${cluster_type} in
    aws|gcp)
        if [ -z "${rhacm_server}" ]; then
            : "${username:=kubeadmin}"
            : "${apikey:=${AWS_API_KEY}}"
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
    ibmcloud|ibmcloud-gen2)
        : "${username:=${IBM_CLOUD_USERNAME}}"
        : "${apikey:=${IBM_CLOUD_API_KEY}}"
    ;;
    ocp)
        if [ -z "${rhacm_server}" ]; then
            : "${username:=kubeadmin}"
        fi
    ;;
    rosa)
        : "${username:=${AWS_ACCESS_KEY_ID}}"
        : "${apikey:=${AWS_SECRET_ACCESS_KEY}}"
        : "${managed_ocp_token:=${ROSA_TOKEN}}"

        if [ -z "${managed_ocp_token}" ]; then
            log "ERROR: A ROSA token was not specified."
            exit 1
        fi

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

check_install_oc || exit 1

result=0

if [ "${setup_server}" -eq 1 ]; then
    if [[ "${gitops_repo}" == *github.ibm.com* ]] && [ -z "${github_pat}" ]; then
        log "ERROR: You must provide an access token for the GHE repository: ${gitops_repo}"
        exit 1
    fi

    setup_gitops_server "${cluster_type}" "${cluster_name}" "${username}" "${apikey}" "${managed_ocp_token}" "${rhacm_server}" "${gitops_repo}" "${gitops_branch}" "${github_pat}" "${app_labels}" \
        || result=1
elif [ "${setup_client}" -eq 1 ]; then
    setup_gitops_clients "${cluster_type}" "${cluster_name}" "${username}" "${apikey}" "${managed_ocp_token}" \
        || result=1
fi

if [ ${result} -eq 0 ] && [ ${test} -eq 1 ]; then
    test_script_dir="${scriptdir}/../tests/postbuild"
    CLUSTER_TYPE="${NEW_CLUSTER_TYPE}" CLUSTER_NAME="${cluster_name}" "${test_script_dir}/test-pipeline.sh"
fi

exit ${result}
