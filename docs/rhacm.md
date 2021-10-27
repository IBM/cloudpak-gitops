# Red Hat Advanced Cluster Management for Kubernetes

## Contents

- [Overview](#overview)
- [Installation](#installation)
  * [OpenShift GitOps installed in the RHACM server](#openshift-gitops-installed-in-the-rhacm-server)
  * [OpenShift GitOps is not installed in the RHACM server](#openshift-gitops-is-not-installed-in-the-rhacm-server)
- [Contributing](#contributing)
- [References](#references)

## Overview

Red Hat Advanced Cluster Management for Kubernetes (referred to as RHACM throughout the rest of this page) provides end-to-end management visibility and control to manage your Kubernetes environment.

This repository contains governance policies and placement rules for Argo CD itself and the Argo CD Application resources representing the Cloud Paks.

## Installation

### OpenShift GitOps installed in the RHACM server

These steps assume you  logged in to the OCP server with the `oc` command-line interface:

1. [Install the Argo CD command-line interface](https://argoproj.github.io/argo-cd/cli_installation/)

1. Log in to the Argo CD server

   Using OCP 4.6:

   ```sh
   # OCP 4.6
   argo_route=argocd-cluster-server
   argo_secret=argocd-cluster-cluster
   sa_account=argocd-cluster-argocd-application-controller
   ```

   Using OCP 4.7 and later:

   ```sh
   # OCP 4.7+
   argo_route=openshift-gitops-server
   argo_secret=openshift-gitops-cluster
   sa_account=openshift-gitops-argocd-application-controller
   ```

1. Add the Argo application:

   ```sh
   #  Tthis step assumes you still have the shell variables assigned from previous actions
   argo_pwd=$(oc get secret ${argo_secret} \
               -n openshift-gitops \
               -o jsonpath='{.data.admin\.password}' | base64 -d ; echo ) \
   && argo_url=$(oc get route ${argo_route} \
                  -n openshift-gitops \
                  -o jsonpath='{.spec.host}') \
   && argocd login "${argo_url}" \
         --username admin \
         --password "${argo_pwd}"

   argocd app create rhacm-app \
         --project default \
         --dest-namespace openshift-gitops \
         --dest-server https://kubernetes.default.svc \
         --repo https://github.com/IBM/cloudpak-gitops \
         --path config/argocd-rhacm/ \
         --sync-policy automated \
         --helm-set-string serviceaccount.argocd_application_controller=${sa_account} \
         --revision main \
         --upsert 
    ```

### OpenShift GitOps is not installed in the RHACM server

These steps require the installation of the [Helm CLI](https://helm.sh/docs/intro/install/), version 3 or above, and assume you still have the shell variables assigned from previous actions) 

Log in to the OpenShift cluster using the `oc` CLI, then issue the following commands:

   ```sh
   git clone https://github.com/IBM/cloudpak-gitops
   helm template cloudpak-gitops/config/rhacm/seeds/ \
      --set-string serviceaccount.argocd_application_controller=${sa_account} | \
   oc apply -f -

   helm template cloudpak-gitops/config/rhacm/cloudpaks/ \
      --set-string serviceaccount.argocd_application_controller=${sa_account} | \
   oc apply -f -
   ```

## Contributing

If you used the approach where OpenShift GitOps is not installed in the same server as RHACM, fork this repository and use the resulting clone URI in the instructions above.

If using OpenShift GitOps installed in the RHACM server, you need to modify the settings of the Argo application to reference a fork of this repository instead of using the default reference to this repository.

The instructions for that setup are documented in the [CONTRIBUTING.md](../CONTRIBUTING.md) page, where you need to ensure you use the `rhacm-app` application name as the parameter for the `argocd app set` commands.

## References

- [Announcement of RHACM and GitOps integration](https://cloud.redhat.com/blog/red-hat-advanced-cluster-management-with-openshift-gitops)
- [RHACM guides](https://access.redhat.com/documentation/en-us/red_hat_advanced_cluster_management_for_kubernetes)
