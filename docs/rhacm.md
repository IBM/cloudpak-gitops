# Red Hat Advanced Cluster Management for Kubernetes

## Contents

- [Red Hat Advanced Cluster Management for Kubernetes](#red-hat-advanced-cluster-management-for-kubernetes)
  - [Contents](#contents)
  - [Overview](#overview)
  - [Prerequisites](#prerequisites)
  - [Installation](#installation)
    - [Install the OpenShift GitOps operator](#install-the-openshift-gitops-operator)
    - [Install RHACM on OCP cluster via Argo CD](#install-rhacm-on-ocp-cluster-via-argo-cd)
  - [Obtain an entitlement key](#obtain-an-entitlement-key)
  - [Update the pull secret in the openshift-gitops namespace](#update-the-pull-secret-in-the-openshift-gitops-namespace)
  - [Using the policies](#using-the-policies)
    - [Policies](#policies)
    - [Label your clusters](#label-your-clusters)
    - [Examples](#examples)
  - [The "rhacm-users" group](#the-rhacm-users-group)
  - [Contributing](#contributing)
  - [References](#references)

---

## Overview

Red Hat Advanced Cluster Management for Kubernetes (referred to as RHACM throughout the rest of this page) provides end-to-end management visibility and control to manage your Kubernetes environment.

This repository contains governance policies and placement rules for Argo CD itself and the Argo CD Application resources representing the Cloud Paks.

---

## Prerequisites

- An OpenShift Container Platform cluster, version 4.12 or later.

  The applications were tested on both managed and self-managed deployments.

- Adequate worker node capacity in the cluster for RHACM to be installed.

  Refer to the [RHACM documentation](https://access.redhat.com/documentation/en-us/red_hat_advanced_cluster_management_for_kubernetes/2.8/html/install/installing#sizing-your-cluster) to determine the required capacity for the cluster.

- [An entitlement key to the IBM Entitled Registry](#obtain-an-entitlement-key). This key is required in the RHACM cluster so it can be copied over to the managed clusters when a cluster matches a policy to install a Cloud Pak.

---

## Installation

### Install the OpenShift GitOps operator

Follow the instructions in the [Red Hat OpenShift GitOps Installation page](https://docs.openshift.com/gitops/1.8/installing_gitops/installing-openshift-gitops.html) with special care to **use the `gitops-1.8` subscription channel instead of `latest`** (at least, until issue [#289](https://github.com/IBM/cloudpak-gitops/issues/289) is addressed.)

### Install RHACM on OCP cluster via Argo CD

These steps assume you logged in to the OCP server with the `oc` command-line interface:

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
   gitops_url=https://github.com/IBM/cloudpak-gitops
   gitops_branch=main
   argocd proj create rhacm-control-plane \
         --dest "https://kubernetes.default.svc,open-cluster-management" \
         --src ${gitops_url:?} \
         --upsert \
   && argocd app create rhacm-app \
         --project rhacm-control-plane \
         --dest-namespace open-cluster-management \
         --dest-server https://kubernetes.default.svc \
         --repo ${gitops_url:?} \
         --path config/argocd-rhacm/ \
         --helm-set repoURL=${gitops_url:?} \
         --helm-set targetRevision=${gitops_branch:?} \
         --sync-policy automated \
         --revision ${gitops_branch:?}  \
         --upsert \
   && argocd app wait -l app.kubernetes.io/instance=rhacm-app \
         --sync \
         --health
   ```

## Obtain an entitlement key

If you don't already have an entitlement key to the IBM Entitled Registry, obtain your key using the following instructions:

1. Go to the [Container software library](https://myibm.ibm.com/products-services/containerlibrary).

1. Click the "Copy key."

1. Copy the entitlement key to a safe place to update the cluster's global pull secret.

1. (Optional) Verify the validity of the key by logging in to the IBM Entitled Registry using a container tool:

   ```sh
   export IBM_ENTITLEMENT_KEY=the key from the previous steps
   podman login cp.icr.io --username cp --password "${IBM_ENTITLEMENT_KEY:?}"
   ```

---

## Update the pull secret in the openshift-gitops namespace

Global pull secrets require granting too much privilege to the OpenShift GitOps service account, so we have started transitioning to the definition of pull secrets at a namespace level.

The Application resources are transitioning to use `PreSync` hooks to copy the entitlement key from a `Secret` named `ibm-entitlement-key` in the `openshift-gitops` namespace, so issue the following command to create that secret:

```sh
# Note that if you just created the OpenShift GitOps operator
# the namespace may not be ready yet, so you may need to wait 
# a minute or two
oc create secret docker-registry ibm-entitlement-key \
        --docker-server=cp.icr.io \
        --docker-username=cp \
        --docker-password="${IBM_ENTITLEMENT_KEY:?}" \
        --docker-email="non-existent-replace-with-yours@email.com" \
        --namespace=openshift-gitops
```

---

## Using the policies

Once Argo completes synchronizing the applications, your cluster will have policies, placement rules, and placement bindings to deploy Cloud Paks to matching clusters.

### Policies

- `openshift-gitops-argo-app`: Configures an Argo server with custom health checks for Cloud Paks.
- `openshift-gitops-cloudpaks-cp-shared`: Deploys common Cloud Pak prerequisites.
- `openshift-gitops-cloudpaks-cp4a`: Deploys the Argo applications for Cloud Pak for Business Automation.
- `openshift-gitops-cloudpaks-cp4d`: Deploys the Argo applications for Cloud Pak for Data.
- `openshift-gitops-cloudpaks-cp4aiops`: Deploys the Argo applications for Cloud Pak for AIOps.
- `openshift-gitops-cloudpaks-cp4i`: Deploys the Argo applications for Cloud Pak for Integration.
- `openshift-gitops-cloudpaks-cp4s`: Deploys the Argo applications for Cloud Pak for Security.
- `openshift-gitops-installed`: Deploys OpenShift GitOps.

### Label your clusters

Labels:

- `gitops-branch` + `cp4a`: Placement for Cloud Pak for Business Automation.
- `gitops-branch` + `cp4d`: Placement for Cloud Pak for Data.
- `gitops-branch` + `cp4i`: Placement for Cloud Pak for Integration.
- `gitops-branch` + `cp4s`: Placement for Cloud Pak for Security.
- `gitops-branch` + `cp4aiops`: Placement for Cloud Pak for AIOps.
- `gitops-remote` + `true`: Assign cluster to the `gitops-cluster` cluster-set, registering it to the [GitOps Cluster](https://access.redhat.com/documentation/en-us/red_hat_advanced_cluster_management_for_kubernetes/2.8/html/applications/managing-applications#gitops-config).

Values for each label:

- `gitops-branch`: Branch of this repo for the Argo applications. Unless you are developing and testing on a new branch, use the default value `main`.
- cp4a: Namespace for deploying the Cloud Pak.
- `cp4aiops`: Namespace for deploying the Cloud Pak.
- `cp4d`: Namespace for deploying the Cloud Pak.
- `cp4i`: Namespace for deploying the Cloud Pak.
- `cp4s`: Namespace for deploying the Cloud Pak.

### Examples

Labeling an OCP cluster with `gitops-branch=main` and `cp4i=cp4ins` deploys the following policies to a target cluster:

- `openshift-gitops-installed`
- `openshift-gitops-argo-app`
- `openshift-gitops-cloudpaks-cp-shared`
- `openshift-gitops-cloudpaks-cp4i`

Labeling an OCP cluster with `gitops-branch=main` and `cp4i=cp4ins` deploys the following policies to a target cluster:

- `openshift-gitops-installed`: The latest version of the OpenShift GitOps operator.
- `openshift-gitops-argo-app`: The Argo configuration is pulled from the `main` branch of this repository.
- `openshift-gitops-cloudpaks-cp-shared`: The Argo configuration is pulled from this repository's `main` branch.
- `openshift-gitops-cloudpaks-cp4i`: The Cloud Pak is deployed to the namespace `cp4ins`

## The "rhacm-users" group

The repository creates the roles and role bindings for a "rhacm-users" user group.

Users in that group will be granted permission to manage clusters in the "default" cluster set, but WITHOUT the permission to manage cloud credentials. That arrangement is ideal for environments where a set of people manages the clusters but not necessarily the underlying cloud accounts.

Refer to OpenShift's [documentation](https://docs.openshift.com/container-platform/4.11/post_installation_configuration/preparing-for-users.html) for more information on user management, such as configuring identity providers and adding users to the Openshift cluster

Once you have the respective users added to the cluster, you can add them to the group via OCP console using the "Add users" option in the panel for the user group (under "User Management" -> "Groups" in the left navigation bar) or using the following command from a terminal window:

```sh
oc adm groups add-users rhacm-users "${username:?}"
```

---

## Contributing

If you used the approach where OpenShift GitOps is not installed in the same server as RHACM, fork this repository and use the resulting clone URI in the instructions above.

If using OpenShift GitOps installed in the RHACM server, you need to modify the settings of the Argo application to reference a fork of this repository instead of using the default reference to this repository.

The instructions for that setup are documented in the [CONTRIBUTING.md](../CONTRIBUTING.md) page, where you need to ensure you use the `rhacm-app` application name as the parameter for the `argocd app set` commands.

---

## References

- [Announcement of RHACM and GitOps integration](https://cloud.redhat.com/blog/red-hat-advanced-cluster-management-with-openshift-gitops)
- [RHACM guides](https://access.redhat.com/documentation/en-us/red_hat_advanced_cluster_management_for_kubernetes)
