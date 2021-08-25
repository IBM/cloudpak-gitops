# IBM Cloud Paks - GitOps

## Contents 

- [Overview](#overview)
  * [IBM Cloud Paks](#ibm-cloud-paks)
  * [GitOps](#gitops)
- [Prerequisites](#prerequisites)
  * [Special note about global pull secrets on ROKS](#special-note-about-global-pull-secrets-on-roks)
  * [Installing the Red Hat OpenShift GitOps operator](#installing-the-red-hat-openshift-gitops-operator)
  * [Obtaining your entitlement key](#obtaining-your-entitlement-key)
- [Adding Cloud Pak GitOps Applications to your GitOps server](#adding-cloud-pak-gitops-applications-to-your-gitops-server)

## Overview

This repository contains Argo CD `Application` resources representing basic deployments of IBM Cloud Paks, and, as such, they are meant for inclusion in an Argo CD cluster. Different Cloud Paks are represented with different `Application` resources and grouped by a resource label tied to each Cloud Pak.

You may decide to include one or more of these `Application` objects to the target cluster and then determine which ones you want to synchronize into the cluster.

### IBM Cloud Paks

[IBM Cloud® Paks](https://www.ibm.com/cloud/paks) helps organizations build, modernize, and manage applications securely across any cloud.

The supported deployment mechanisms for Cloud Paks are documented in their respective [documentation pages](https://www.ibm.com/docs/en/cloud-paks) and typically included a UI-based deployment through the Operator Hub page or, in some cases, scripted alternatives based on command-line interfaces.

### GitOps 

GitOps is a declarative way to implement continuous deployment for cloud-native applications. The Red Hat® OpenShift® Container Platform offers the [OpenShift GitOps operator](https://docs.openshift.com/container-platform/4.7/cicd/gitops/understanding-openshift-gitops.html), which manages the entire lifecycle for [Argo CD](https://argoproj.github.io/argo-cd/) and its components.


## Prerequisites

- OpenShift Container Platform 4.6 or later version
- Storage classes supporting both [RWO and RWX storage](https://kubernetes.io/docs/concepts/storage/persistent-volumes/#access-modes), such as [OpenShift Container Storage](https://docs.openshift.com/container-platform/4.7/storage/persistent_storage/persistent-storage-ocs.html). If you have OpenShift Container Storage installed in the container, you will have then.
- [Install the OpenShift GitOps operator](#installing-the-red-hat-openshift-gitops-operator)
- [Obtain an entitlement key to the IBM Entitled Registry](#obtaining-your-entitlement-key)
- [Update the OCP global pull secret](https://docs.openshift.com/container-platform/4.7/openshift_images/managing_images/using-image-pull-secrets) with an entitlement key to the IBM Entitled Registry

### Special note about global pull secrets on ROKS

Updating the OCP global pull secret typically triggers the staggered restart of each node in the cluster. However, the [Red Hat OpenShift on IBM Cloud](https://www.ibm.com/cloud/openshift) platform required an additional step: you will need to reload all workers in the case of ROKS classic clusters and replace all workers in the case of ROKS VPC Gen2 clusters.

You can perform the reloading or replacement of workers directly from the cluster page in the IBM Cloud console or the command-line interface using the instructions highlighted [here](https://cloud.ibm.com/docs/openshift?topic=openshift-registry&_ga=2.262606922.775805413.1629911830-822975074.1629149367#cluster_global_pull_secret).

### Installing the Red Hat OpenShift GitOps operator

1. Go to the OperatorHub on OpenShift Webconsole and look for the "OpenShift GitOps" operator
1. Install the operator using the defaults in the wizard, and wait for it to show up in the list of "Installed Operators." If it doesn't install correctly, you can check its status in the "Installed Operators" tab in the `openshift-operators` namespace.

### Obtaining your entitlement key

1. Go to the [Container software library](https://myibm.ibm.com/products-services/containerlibrary).
1. Click `Copy key.`
1. Copy the entitlement key to a safe place so you can use it when updating the global pull secret for the cluster.
1. (Optional) Verify the validity of the key by logging in to the IBM Entitled Registry using a container tool
     ```
    docker login cp.icr.io --username cp --password entitlement_key
    ```

## Adding Cloud Pak GitOps Application to your GitOps server

The instructions in this section assume you have administrative privileges to the cluster.

After completing the list of activities listed in the Prerequisites section, you have the option of adding the Argo CD `Application` objects for a Cloud Pak using either the OpenShift Container Platform console or using commands in a terminal.

### Using the OCP console

1. Launch the Argo CD console: Click on the grid-like icon in the upper-left section of the screen, where you should click on either "ArgoCD Console" (for OCP 4.6) or "Cluster Argo CD" (for OCP 4.7 and later)
1. The default user is `admin .` The admin password is located in a secret in the `openshift-gitops` namespace.
   - The secret name is either `argocd-cluster-cluster` (for OCP 4.6) or `openshift-gitops-cluster` (for OCP 4.7 and later)
   - Switch to the "openshift-gitops" project, locate the secret in the "Workloads -> Secrets" page, scroll to the bottom, and click on "Reveal Values" to see the value of the `admin.password` field.
   - Click "Sign In," and you should see the Argo CD console
1. Once logged to the Argo CD console, click on the "New App+" button in the upper left of the Argo CD console and fill out the form with values matching each Cloud Pak, according to the table below:
    | Cloud Pak | Application Name | Path | Namespace |
    | --------- | ---------------- | ---- | --------- |
    | (base prereq for all cloudpaks, always add it first) | cp-shared | config/argocd-cloudpaks/cp-shared | ibm-cloudpaks |
    | Business Automation | cp4a-app | config/argocd-cloudpaks/cp4a | cp4a |
    | Integration Automation | cp4i-app | config/argocd-cloudpaks/cp4i | cp4i |
    | AIOps Automation | cp4aiops-app | config/argocd-cloudpaks/cp4aiops | openshift-operators |

    For all other fields, use these values:
    | Field | Value |
    | ----- | ----- |
    | Project | default |
    | Sync policy | Automatic |
    | Self Heal | true |
    | Repository URL | https://github.com/IBM/cloudpak-gitops |
    | Revision | HEAD |
    | Cluster URL | https://kubernetes.default.svc |
1. After filling out the form details, click on the "Create" button
1. Wait for the synchronization to complete.
1. Enable auto-synchronization for the applications automatically created by the previous steps
   - For instance, if adding the "cp4a-app" application, it will automatically create two new applications, "cp4a-operators" and "cp4a-resources".
   - Click on the first application, such as "cp4a-operators", then select "App Details."
   - Scroll down to "Sync Policy" and select "Enable Auto-Sync."
   - Leave "Prune Resources" disabled
   - Enable "Self Heal" (this is required for some synchronizations where the first pass grants extra permissions to the Argo CD service account and the subsequent passes succeed with the extra permissions)

### Using a terminal

1. Open a terminal and ensure you have the OpenShift CLI installed:
   ```sh
   oc version --client

   # Client Version: 4.8.2
   ```
   Ideally, the client's minor version should not be more than one iteration behind the version of the server. Most commands here are pretty basic and will work with more significant differences, but keep that in mind if you see errors about unrecognized commands and parameters.

   If you do not have the CLI installed, follow [these instructions](https://docs.openshift.com/container-platform/4.7/cli_reference/openshift_cli/getting-started-cli.html).
1. [Login to the OpenShift CLI](https://docs.openshift.com/container-platform/4.7/cli_reference/openshift_cli/getting-started-cli.html#cli-logging-in_cli-developer-commands)
1. [Install the Argo CD CLI](https://argoproj.github.io/argo-cd/cli_installation/)
1. Login to the Argo CD server
   Using OCP 4.6
   ```sh
    argo_route=argocd-cluster-server
    argo_secret=argocd-cluster-cluster
    sa_account=argocd-cluster-argocd-application-controller

    argo_pwd=$(oc get secret ${argo_secret} -n openshift-gitops -ojsonpath='{.data.admin\.password}' | base64 -d ; echo ) \
    && argo_url=$(oc get route ${argo_route} -n openshift-gitops -ojsonpath='{.spec.host}') 
    && argocd login "${argo_url}" --username admin --password "${argo_pwd}" --insecure
   ```

   Using OCP 4.7 and later (the object names change a little from OCP 4.6)
   ```sh
    argo_route=openshift-gitops-server
    argo_secret=openshift-gitops-cluster
    sa_account=openshift-gitops-argocd-application-controller

    argo_pwd=$(oc get secret ${argo_secret} -n openshift-gitops -ojsonpath='{.data.admin\.password}' | base64 -d ; echo ) \
    && argo_url=$(oc get route ${argo_route} -n openshift-gitops -ojsonpath='{.spec.host}') 
    && argocd login "${argo_url}" --username admin --password "${argo_pwd}" --insecure
   ```
1. Add the `cp-shared` application. (this step assumes you still have shell variables assigned from previous steps) :
   ```sh
     argocd app create cp-shared-app \
            --project default \
            --dest-namespace openshift-gitops \
            --dest-server https://kubernetes.default.svc \
            --helm-set-string serviceaccount.argocd_application_controller=${sa_account} \
            --repo https://github.com/IBM/cloudpak-gitops \
            --path config/argocd-cloudpaks/cp-shared \
            --sync-policy automated \
            --revision main \
            --upsert 
    ```
1. Add the respective Cloud Pak application. (this step assumes you still have shell variables assigned from previous steps) :
   ```sh
     # appname=<< choose a value from the "Application Name" column in the table of Cloud Paks above, such as cp4a-app, cp4i-app, cp4aiops-app, etc >>
     cp=cp4i
     app_name=${cp}-app
     # app_path=<< choose the respective value from the "path Name" column in the table of Cloud Paks above, such as config/argocd-cloudpaks/cp4i/cp4a, config/argocd-cloudpaks/cp4i, etc
     app_path=config/argocd-cloudpaks/${cp}

     argocd app create "${app_name}" \
            --project default \
            --dest-namespace openshift-gitops \
            --dest-server https://kubernetes.default.svc \
            --helm-set-string serviceaccount.argocd_application_controller=${sa_account} \
            --repo https://github.com/IBM/cloudpak-gitops \
            --path "${app_path}" \
            --sync-policy automated \
            --upsert 
    argocd app wait "${app_name}"
    ```
1. Enable auto-synchronization for the apps automatically added by the previous step. The auto-synchronization is disabled by default in the repo if you want to further configure the applications before starting the synchronization.
   ```sh
   argocd app set ${cp}-operators \
            --sync-policy automated \
            --self-heal
   argocd app wait ${cp}-operators \
            --timeout 1200
   argocd app set ${cp}-resources \
            --sync-policy automated \
            --self-heal
   argocd app wait ${cp}-resources \
            --timeout 7200
   ```
1. List all the applications to see their overall status
   ```sh
   argocd app list -l app.kubernetes.io/instance=${app_name}
   ```
