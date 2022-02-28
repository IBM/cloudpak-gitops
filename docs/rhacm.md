# Red Hat Advanced Cluster Management for Kubernetes

## Contents

- [Overview](#overview)
- [Installation](#installation)
  * [Install OpenShift GitOps and policies in the RHACM server](#install-openshift-gitops-and-policies-in-the-rhacm-server)
  * [Install RHACM on OCP cluster via Argo](#install-rhacm-on-ocp-cluster-via-argo)
- [Using the policies](#using-the-policies)
  * [Policies](#policies)
  * [Label your clusters](#label-your-clusters)
  * [Examples](#examples)
- [Contributing](#contributing)
- [References](#references)

---

## Overview

Red Hat Advanced Cluster Management for Kubernetes (referred to as RHACM throughout the rest of this page) provides end-to-end management visibility and control to manage your Kubernetes environment.

This repository contains governance policies and placement rules for Argo CD itself and the Argo CD Application resources representing the Cloud Paks.

## Installation

### Install OpenShift GitOps and policies in the RHACM server

These steps require the installation of the [Helm CLI](https://helm.sh/docs/intro/install/), version 3 or above, and assume you still have the shell variables assigned from previous actions) 

Log in to the OpenShift cluster using the `oc` CLI, then issue the following commands:

   ```sh
   gitops_url=https://github.com/IBM/cloudpak-gitops
   gitops_branch=main
   git clone ${gitops_url:?} --branch ${gitops_branch:?} cloudpak-gitops

   # There will be a few errors in the following output, about 
   # "no matches for kind ...". That is expected as the various
   # components come up.
   helm template cloudpak-gitops/config/rhacm/seeds/ | oc apply -f -
   oc wait Subscription.operators.coreos.com advanced-cluster-management \
      -n open-cluster-management \
      --for=condition=CatalogSourcesUnhealthy=False \
      --timeout 1200s
   sleep 60
   oc wait InstallPlan \
      --all \
      -n open-cluster-management \
      --for condition=Installed=true


   helm template cloudpak-gitops/config/rhacm/seeds/ | oc apply -f -
   oc wait multiclusterhub.operator.open-cluster-management.io multiclusterhub \
      -n open-cluster-management \
      --for=condition=Complete=True \
      --timeout 1200s

   helm template cloudpak-gitops/config/rhacm/seeds/ | oc apply -f - 
   helm template cloudpak-gitops/config/rhacm/cloudpaks/ | oc apply -f -
   ```

### Install RHACM on OCP cluster via Argo

These steps assume you  logged in to the OCP server with the `oc` command-line interface:

1. [Install the Argo CD command-line interface](https://argoproj.github.io/argo-cd/cli_installation/)

1. Log in to the Argo CD server

   ```sh
   argo_pwd=$(oc get secret openshift-gitops-cluster \
               -n openshift-gitops \
               -o jsonpath='{.data.admin\.password}' | base64 -d ; echo ) \
   && argo_url=$(oc get route openshift-gitops-server \
                  -n openshift-gitops \
                  -o jsonpath='{.spec.host}') \
   && argocd login "${argo_url}" \
         --username admin \
         --password "${argo_pwd}"
   ```

1. Add the Argo application:

   ```sh
   #  This step assumes you still have the shell variables assigned from previous steps
   argocd app create rhacm-app \
         --project default \
         --dest-namespace openshift-gitops \
         --dest-server https://kubernetes.default.svc \
         --repo ${gitops_url:?} \
         --path config/argocd-rhacm/ \
         --sync-policy automated \
         --revision ${gitops_branch:?}  \
         --helm-set repoURL=${gitops_url:?} \
         --helm-set targetRevision=${gitops_branch:?} \
         --upsert
   argocd app wait rhacm-app \
         --sync \
         --health
   ```


## Using the policies

Once Argo completes synchronizing the applications, your cluster will have policies, placement rules, and placement bindings to deploy Cloud Paks to matching clusters.

### Policies

- `openshift-gitops-argo-app`: Configures an Argo server with custom health checks for Cloud Paks.
- `openshift-gitops-cloudpaks-cp-shared`: Deploys common Cloud Pak prerequisites.
- `openshift-gitops-cloudpaks-cp4a`: Deploys the Argo applications for Cloud Pak for Business Automation.
- `openshift-gitops-cloudpaks-cp4d`: Deploys the Argo applications for Cloud Pak for Data.
- `openshift-gitops-cloudpaks-cp4aiops`: Deploys the Argo applications for Cloud Pak for Watson AIOps.
- `openshift-gitops-cloudpaks-cp4i`: Deploys the Argo applications for Cloud Pak for Integration.
- `openshift-gitops-installed`: Deploys OpenShift GitOps.

### Label your clusters

Labels:

- `gitops-branch` + `cp4a`: Placement for Cloud Pak for Business Automation.
- `gitops-branch` + `cp4aiops`: Placement for Cloud Pak  for Cloud Pak for Watson AIOps.
- `gitops-branch` + `cp4d`: Placement for Cloud Pak for Data.
- `gitops-branch` + `cp4i`: Placement for Cloud Pak for Integration.

Values for each label:

- `gitops-branch`: Branch of this repo for the Argo applications. Unless you are developing and testing on a new branch, use the default value `main`.
- cp4a: Namespace for deploying the Cloud Pak. Unless you want multiple Cloud Paks in different namespaces of the cluster, use the default value `ibm-cloudpaks`.
- `cp4aiops`: Namespace for deploying the Cloud Pak. Unless you want multiple Cloud Paks in different namespaces of the cluster, use the default value `ibm-cloudpaks`.
- `cp4d`: Namespace for deploying the Cloud Pak. As of release 4.0.6, and as a product limitation, do not use the same namespace as other Cloud Paks if installing  Cloud Pak for Data to the same cluster.
- `cp4i`: Namespace for deploying the Cloud Pak. Unless you want multiple Cloud Paks in different namespaces of the cluster, use the default value `ibm-cloudpaks`.

### Examples

Labeling an OCP cluster with `gitops-branch=main` and `cp4i=ibm-cloudpaks` deploys the following policies to a target cluster:

- `openshift-gitops-installed`
- `openshift-gitops-argo-app`
- `openshift-gitops-cloudpaks-cp-shared`
- `openshift-gitops-cloudpaks-cp4i`

Labeling an OCP cluster with `gitops-branch=main` and `cp4i=ibm-cloudpaks` deploys the following policies to a target cluster:

- `openshift-gitops-installed`: The latest version of the OpenShift GitOps operator.
- `openshift-gitops-argo-app`: The Argo configuration is pulled from the `main` branch of this repository.
`openshift-gitops-cloudpaks-cp-shared`: The Argo configuration is pulled from this repository's `main` branch.
- `openshift-gitops-cloudpaks-cp4i`: The Cloud Pak is deployed to the namespace `ibm-cloudpaks`


## Contributing

If you used the approach where OpenShift GitOps is not installed in the same server as RHACM, fork this repository and use the resulting clone URI in the instructions above.

If using OpenShift GitOps installed in the RHACM server, you need to modify the settings of the Argo application to reference a fork of this repository instead of using the default reference to this repository.

The instructions for that setup are documented in the [CONTRIBUTING.md](../CONTRIBUTING.md) page, where you need to ensure you use the `rhacm-app` application name as the parameter for the `argocd app set` commands.

## References

- [Announcement of RHACM and GitOps integration](https://cloud.redhat.com/blog/red-hat-advanced-cluster-management-with-openshift-gitops)
- [RHACM guides](https://access.redhat.com/documentation/en-us/red_hat_advanced_cluster_management_for_kubernetes)
