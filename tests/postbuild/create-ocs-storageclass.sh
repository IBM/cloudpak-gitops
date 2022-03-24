#!/bin/bash

#
# Sets up the OpenShift Data Framework on ROSA
#
# arg1 infrastructure type of cluster to be configured
# arg2 name of the cluster to be configured
# arg3 if "true", places ODF workloads on an isolated worker pool. 
#      setting it to "false" has no effect for ROSA clusters, 
#      since it always needs its own worker pool.
#
function setup_ocs_aws_storage() {
    local cluster_type=${1}
    local cluster_name=${2}
    local isolate_odf_workload=${3:-false}
    
    local result=0

    #Create the Project
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  labels:
    openshift.io/cluster-monitoring: "true"
  name: ${ODF_NAMESPACE}
EOF

    #Create the OCS Operator Group
    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-storage-operatorgroup
  namespace: ${ODF_NAMESPACE}
spec:
  targetNamespaces:
    - ${ODF_NAMESPACE}
EOF

    local odf=1
    local ocp_version
    ocp_version=$(oc get ClusterVersion version -o jsonpath='{.status.desired.version}'  | cut -d "." -f 1,2)
    if [ "${ocp_version}" == "4.6" ] || 
       [ "${ocp_version}" == "4.7" ] || 
       [ "${ocp_version}" == "4.8" ]; then
        odf=0
    elif [ "${ocp_version}" == "4.10" ]; then
        ocp_version=4.9
    fi

    local operator_name=odf-operator

    # Create subscription
    if [ "${odf}" -eq 0 ]; then
        operator_name=ocs-operator
    fi

    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${operator_name}
  namespace: ${ODF_NAMESPACE}
spec:
  channel: "stable-${ocp_version}"
  installPlanApproval: Automatic
  name: ${operator_name}
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

    # https://access.redhat.com/articles/6408481    
    if [ "${cluster_type}" == "rosa" ] || [ "${isolate_odf_workload}" == "true" ]; then
        oc get sub  -n openshift-storage -o name \
        | xargs -I {} oc patch {} \
            -n "${ODF_NAMESPACE}" \
            --patch '{"spec":{"config":{"tolerations":[{"effect":"NoSchedule","key":"odf-only","operator":"Equal","value":"true"}]}}}' \
            --type merge
    fi

    while true; do
        if oc get csv -l operators.coreos.com/${operator_name}.openshift-storage="" -n "${ODF_NAMESPACE}" | grep -i "succeeded"; then
            log "INFO: OCS/ODF Subscription is completed"
            break
        else
            log "INFO: Waiting for Subscription to complete"
            sleep 10
        fi
    done

    # https://docs.openshift.com/rosa/nodes/nodes/rosa-managing-worker-nodes.html#rosa-adding-node-labels_rosa-managing-worker-nodes
    local ocs_nodes=3
    if [ "${cluster_type}" == "rosa" ]; then
        local machine_pool=odf-cluster-mp
        local pool_not_found=0
        rosa list machinepool --cluster="${cluster_name}"  | grep "${machine_pool}" \
            || pool_not_found=1
        if [ ${pool_not_found} -eq 1 ]; then
            # local replicas_param=(--replicas="${ocs_nodes}" --instance-type=m5.4xlarge)
            local replicas_param=(--enable-autoscaling \
                    --min-replicas "${ocs_nodes}" \
                    --max-replicas $((ocs_nodes*2)) \
                    --instance-type=m5.2xlarge \
                    --taints "odf-only=true:NoSchedule")
            rosa create machinepool \
                --cluster="${cluster_name}" \
                --name=${machine_pool} \
                "${replicas_param[@]}" \
                --labels=cluster.ocs.openshift.io/openshift-storage="" \
            && rosa list machinepools --cluster="${cluster_name}" \
            || result=1
        fi

        local ocs_machines=0
        while [ ${ocs_machines} != ${ocs_nodes} ]; do
            log "INFO: Waiting for all machines to be running in the pool"
            sleep 10
            ocs_machines=$(oc get Machine \
                -n openshift-machine-api \
                -l machine.openshift.io/cluster-api-machine-type=${machine_pool} \
            | grep -c Running)
        done
        log "INFO: All OCS workers ready"
        oc get Machine \
                -n openshift-machine-api \
                -l machine.openshift.io/cluster-api-machine-type=${machine_pool}
    else
        if [ "${isolate_odf_workload}" == "false" ]; then
            for i in $(oc get nodes -l node-role.kubernetes.io/worker -o name | sort | head -n ${ocs_nodes}); do
                oc label "${i}" cluster.ocs.openshift.io/openshift-storage="" --overwrite=true \
                    || result=1
            done
        fi
    fi
    oc get nodes -l cluster.ocs.openshift.io/openshift-storage=""

    if [ ${result} -eq 1 ]; then
        log "ERROR: Unable to label nodes for the storage cluster."
        return 1
    fi

    if [ "${odf}" -eq 1 ]; then
        # https://access.redhat.com/articles/5683981
        cat <<EOF | oc apply -f -
apiVersion: odf.openshift.io/v1alpha1
kind: StorageSystem
metadata:
  name: ocs-storagecluster-storagesystem
  namespace: ${ODF_NAMESPACE}
spec:
  kind: storagecluster.ocs.openshift.io/v1
  name: ocs-storagecluster
  namespace: ${ODF_NAMESPACE}
EOF

        log "INFO: Enable console plugin"
        oc patch console.operator cluster \
            -n "${ODF_NAMESPACE}" \
            --type json \
            -p '[{"op": "add", "path": "/spec/plugins", "value": ["odf-console"]}]'
    fi

    local storage_cluster_yaml="${WORKDIR}/storage-cluster.yaml"
    cat <<EOF > "${storage_cluster_yaml}"
apiVersion: ocs.openshift.io/v1
kind: StorageCluster
metadata:
  annotations:
    uninstall.ocs.openshift.io/cleanup-policy: delete
    uninstall.ocs.openshift.io/mode: graceful
  name: ocs-storagecluster
  namespace: ${ODF_NAMESPACE}
  finalizers:
    - storagecluster.ocs.openshift.io
spec:
  encryption: {}
  externalStorage: {}
  managedResources:
    cephBlockPools: {}
    cephFilesystems: {}
    cephObjectStoreUsers: {}
    cephObjectStores: {}
  storageDeviceSets:
    - config: {}
      count: 1
      dataPVCTemplate:
        metadata:
          creationTimestamp: null
        spec:
          accessModes:
            - ReadWriteOnce
          resources:
            requests:
              storage: ${ODF_DISK_SIZE}
          storageClassName: gp2
          volumeMode: Block
        status: {}
      name: ocs-deviceset-gp2
      placement: {}
      portable: true
      replica: 3
      resources: {}
  version: ${ocp_version}.0
  failureDomain: rack
  nodeTopologies:
    labels:
      topology.rook.io/rack:
        - rack0
        - rack1
        - rack2
EOF

    if [ "${cluster_type}" == "rosa" ] || [ "${isolate_odf_workload}" == "true" ]; then
        cat << EOF >> "${storage_cluster_yaml}"
  placement:
    all:
      tolerations:
      - effect: NoSchedule
        key: odf-only
        operator: Equal
        value: "true"
    mds:
      tolerations:
      - effect: NoSchedule
        key: odf-only
        operator: Equal
        value: "true"
    noobaa-core:
      tolerations:
      - effect: NoSchedule
        key: odf-only
        operator: Equal
        value: "true"
    rgw:
      tolerations:
      - effect: NoSchedule
        key: odf-only
        operator: Equal
        value: "true"
EOF
    fi

    oc apply -f "${storage_cluster_yaml}"

    if [ "${cluster_type}" == "rosa" ] || [ "${isolate_odf_workload}" == "true" ]; then
        oc patch configmap rook-ceph-operator-config \
            -n "${ODF_NAMESPACE}" \
            --patch '{"data":{ "CSI_PLUGIN_TOLERATIONS": "\n- key: node.ocs.openshift.io/storage\n  operator: Equal\n  value: \"true\"\n  effect: NoSchedule\n- key: odf-only\n  operator: Equal\n  value: \"true\"\n  effect: NoSchedule" , "CSI_PROVISIONER_TOLERATIONS": "\n- key: node.ocs.openshift.io/storage\n  operator: Equal\n  value: \"true\"\n  effect: NoSchedule\n- key: odf-only\n  operator: Equal\n  value: \"true\"\n  effect: NoSchedule"}}' \
            --type strategic
    fi

    if [ ${odf} -eq 1 ]; then
        log "INFO: Wait for StorageSystem to be ready."
        oc wait StorageSystem \
            --all \
            -n "${ODF_NAMESPACE}" \
            --for=condition=Available=True \
            --timeout 1200s
    fi

    log "INFO: Wait for StorageCluster to be ready."
    while true; do
        if [[ $(oc get StorageCluster -n "${ODF_NAMESPACE}") =~ Ready ]]; then
            log "INFO: The StorageCluster is Ready"
            break
        else
            oc get StorageCluster,po,pvc -n "${ODF_NAMESPACE}" \
                | grep -Ev "1/1|2/2|3/3|4/4|5/5|6/6|Comple|Bound"
            sleep 10
        fi
    done

    local seconds=1200s
    for label in rook-ceph-operator rook-ceph-osd csi-cephfsplugin csi-rbdplugin noobaa rook-ceph-mon; do
        log "INFO Wait for ${label} pods to be ready."
        while true; do
            if [[ $(oc get pod -l app=${label} -n "${ODF_NAMESPACE}" | wc -l) -gt 0 ]]; then
                oc wait pod -l app=${label} -n "${ODF_NAMESPACE}" --for=condition=Ready --timeout=${seconds} \
                    || log "WARNING: Some pods for ${label} are not ready after ${seconds}."
                break;
            fi
        done
    done

    log "INFO: State of all pods."
    oc get pod -n "${ODF_NAMESPACE}"

    if [ ${odf} -eq 0 ]; then
        log "INFO: Enable toolbox"
        oc patch OCSInitialization ocsinit \
            -n "${ODF_NAMESPACE}" \
            --type json \
            --patch '[{ "op": "replace", "path": "/spec/enableCephTools", "value": true }]'
    fi

    log "INFO: State of all storage."
    oc get StorageCluster,sc

    return ${result}
}


#
# Sets up the OpenShift Data Framework on ROKS VPC Gen2 clusters.
#
# https://cloud.ibm.com/docs/openshift?topic=openshift-ocs-storage-install 
#
# arg1 name of the cluster to be configured
#
function setup_ocs_vpc_gen2_storage() {
    local cluster_name=${1}

    local result=0

    #Create the Project
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  labels:
    openshift.io/cluster-monitoring: "true"
  name: ${ODF_NAMESPACE}
EOF

    local cos_instance_name="${cluster_name}-${ROKS_CLUSTER_STORAGE_SI}"
    local cos_rw_cred="${cluster_name}-cos-cred-rw"

    ibmcloud resource service-instance "${cos_instance_name}" > /dev/null 2>&1 || 
    create_cos "${cos_instance_name}" "${cos_rw_cred}" ||
    {
        log "ERROR: Object storage instance ${cos_instance_name} does not exist."
        return 1
    }

    local resource_key_json="${WORKDIR}/resource_key.json"
    ibmcloud resource service-key "${cos_rw_cred}" --output json > "${resource_key_json}" \
        || 
        {
            log "ERROR: Unable to retrieve service key for COS."
            return 1
        }

    local access_key_id
    local access_key
    local roks_cos_creds=ibm-cloud-cos-creds
    access_key_id=$(jq -r '.[].credentials.cos_hmac_keys.access_key_id' "${resource_key_json}") \
    && access_key=$(jq -r '.[].credentials.cos_hmac_keys.secret_access_key' "${resource_key_json}") \
    && oc -n "${ODF_NAMESPACE}" delete secret "${roks_cos_creds}" --ignore-not-found=true \
    && oc -n "${ODF_NAMESPACE}" create secret generic "${roks_cos_creds}" \
        --type=Opaque \
        --from-literal=IBM_COS_ACCESS_KEY_ID="${access_key_id}" \
        --from-literal=IBM_COS_SECRET_ACCESS_KEY="${access_key}" \
    && oc get -n "${ODF_NAMESPACE}" secret "${roks_cos_creds}" \
    && rm -rf "${resource_key_json}" \
    || result=1

    if [ ${result} -eq 1 ]; then 
        log "ERROR: Unable to retrieve access keys for ${cos_instance_name}"
        return 1
    fi

    log "INFO: Enable the addon on the cluster and wait for it to be Ready."
    local odf_version
    odf_version=$(oc get ClusterVersion version -o jsonpath='{.status.desired.version}' | cut -d "." -f 1,2).0 \
    || {
        log "ERROR: Unable to determine cluster version."
        return 1
    }
    local addon_name=openshift-data-foundation
    if [ "${odf_version}" == "4.6.0" ]; then
        addon_name=openshift-container-storage
    else
        odf_version=4.7.0
    fi
    if ! ibmcloud oc cluster addon ls -c "${cluster_name}" | grep -q "${addon_name}"; then
        ibmcloud oc cluster addon enable "${addon_name}" \
            -c "${cluster_name}" \
            --version "${odf_version}" \
            --param "osdSize=${ODF_DISK_SIZE}" \
            --param "monStorageClassName=${STORAGE_CLASS}" \
            --param "osdStorageClassName=${STORAGE_CLASS}" \
            --param "odfDeploy=true" \
            --param "monSize=${MON_DISK_SIZE}" \
        && ibmcloud oc cluster addon ls -c "${cluster_name}" \
        || return 1
    fi

    log "INFO: Waiting for the storage add-on to be ready."
    local cluster_addon_file="${WORKDIR}/addon-status.txt"
    while [ ${result} -eq 0 ]; do
        ibmcloud oc cluster addon get \
            --addon "${addon_name}" \
            --cluster "${cluster_name}" > "${cluster_addon_file}" \
        || {
            log "ERROR: Unable to retrieve cluster add-on status."
            result=1
            break
        }

        grep -q Ready "${cluster_addon_file}" \
        && {
            log "INFO: ${addon_name} addon is Ready"
            break
        }

        log "INFO: ${addon_name} addon is installing"
        sleep 30
    done

    log "INFO: Waiting for ODF operator controller."
    oc wait pods -l name=ocs-controller -n kube-system --for=condition=Ready --timeout 1200s

    log "INFO: Wait for storagecluster to be ready."
    while true; do
        if [[ $(oc get storagecluster -n "${ODF_NAMESPACE}") =~ Ready ]]; then
            echo "The OCS storagecluster is Ready"
            break
        else
            oc get storagecluster,po,pvc -n "${ODF_NAMESPACE}" | grep -Ev "1/1|2/2|3/3|4/4|5/5|6/6|Comple|Bound"
        fi
    done

    local seconds=1200s
    for label in rook-ceph-operator rook-ceph-osd csi-cephfsplugin csi-rbdplugin noobaa rook-ceph-mon; do
        log "INFO Wait for ${label} pods to be ready."
        while true; do
            if [[ $(oc get pod -l app=${label} -n "${ODF_NAMESPACE}" | wc -l) -gt 0 ]]; then
                oc wait pod -l app=${label} -n "${ODF_NAMESPACE}" --for=condition=Ready --timeout=${seconds} \
                    || log "WARNING: Some pods for ${label} are not ready after ${seconds}."
                break;
            fi
        done
    done
    log "INFO: State of all pods."
    oc get pod -n "${ODF_NAMESPACE}"

    log "INFO: State of all storage."
    oc get storagecluster,sc

    return ${result}
}
