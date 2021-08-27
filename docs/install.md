# Installation

## Contents 

- [Prerequisites](#prerequisites)
- [Install the OpenShift GitOps operator](#install-the-openshift-gitops-operator)
- [Obtain an entitlement key](#obtain-an-entitlement-key)
- [Update the OCP global pull secret](#update-the-ocp-global-pull-secret)
  * [Update the global pull secret using the OpenShift console](#update-the-global-pull-secret-using-the-openshift-console)
  * [Special note about global pull secrets on ROKS](#special-note-about-global-pull-secrets-on-roks)
- [Adding Cloud Pak GitOps Application objects to your GitOps server](#adding-cloud-pak-gitops-application-objects-to-your-gitops-server)
  * [Using the OCP console](#using-the-ocp-console)
  * [Using a terminal](#using-a-terminal)

## Prerequisites

- An OpenShift Container Platform cluster, version 4.6 or later.

  The applications were tested on both managed and self-managed deployments.

- Cluster storage configured with storage classes supporting both [RWO and RWX storage](https://kubernetes.io/docs/concepts/storage/persistent-volumes/#access-modes).

  The applications were tested with [OpenShift Container Storage](https://docs.openshift.com/container-platform/4.7/storage/persistent_storage/persistent-storage-ocs.html), [Rook Ceph](https://github.com/rook/rook), and the built-in file storage in ROKS classic clusters.

- [An entitlement key to the IBM Entitled Registry](#obtaining-your-entitlement-key)

## Install the OpenShift GitOps operator

1. From the Administrator's perspective, navigate to the OperatorHub page.

1. Search for "Red Hat OpenShift GitOps". Click on the tile and then click on "Install"

1. Keep the defaults in the wizard and click on "Install"

1. Wait for it to show up in the list of "Installed Operators." If it doesn't install correctly, you can check its status on the "Installed Operators" page in the `openshift-operators` namespace.

## Obtain an entitlement key

If you don't already have an entitlement key to the IBM Entitled Registry, obtain your key using the following instructions:

1. Go to the [Container software library](https://myibm.ibm.com/products-services/containerlibrary).

1. Click "Copy key."

1. Copy the entitlement key to a safe place so you can use it when updating the global pull secret for the cluster.

1. (Optional) Verify the validity of the key by logging in to the IBM Entitled Registry using a container tool:

   ```sh
   docker login cp.icr.io --username cp --password entitlement_key
   ```

## Update the OCP global pull secret

[Update the OCP global pull secret](https://docs.openshift.com/container-platform/4.7/openshift_images/managing_images/using-image-pull-secrets.html) with the entitlement key.

Keep in mind that the registry user for that secret is "cp". A common mistakes is to assume the registry user is the name or email of the user owning the entitlement key.

### Update the global pull secret using the OpenShift console

1. Navigate to the "Workloads > Secrets" page in the "Administrator" perspective.

1. Select the object "pull-secret".

1. Click on "Actions -> Edit secret".

1. Scroll to the bottom of that page and click on "Add credentials", using the following values for each field:

   - "Registry Server Address" cp.icr.io
   - "Username": cp
   - "Password": paste the entitlement key you copied from the [Obtain an entitlement key](#obtain-an-entitlement-key) setp
   - "Email": any email, valid or not, will work. This fields is mostly a hint to other people who may see the entry in the configuration

1. Click on "Save"


### Special note about global pull secrets on ROKS

Updating the OCP global pull secret triggers the staggered restart of each node in the cluster. However, the [Red Hat OpenShift on IBM Cloud](https://www.ibm.com/cloud/openshift) platform requires an additional step: reload all workers nodes (in the case of ROKS classic clusters) or replace all workers nodes (in the case of ROKS VPC Gen2 clusters.)

You can perform the reloading or replacement of workers directly from the cluster page in the IBM Cloud console or use a terminal, following the instructions listed [here](https://cloud.ibm.com/docs/openshift?topic=openshift-registry&_ga=2.262606922.775805413.1629911830-822975074.1629149367#cluster_global_pull_secret).


## Adding Cloud Pak GitOps Application objects to your GitOps server

The instructions in this section assume you have administrative privileges to the cluster.

After completing the list of activities listed in the previous sections, you have the option of adding the Argo CD `Application` objects for a Cloud Pak using either the OpenShift Container Platform console or using commands in a terminal.

### Using the OCP console

1. Configure the [custom resource health](https://argoproj.github.io/argo-cd/operator-manual/health/) checkers in the Argo CD server:

   - In the Administrator perspective, navigate to "Administration -> CustomResourceDefinitions", locate the "ArgoCD" definition

   - Select the "Instances" tab. Click on the instance named either `argocd-cluster` (OCP 4.6) or `openshift-gitops` (OCP 4.7 and later.)

   - Copy-paste the `resourceCustomizations` section of the file "descriptors/resources/argocd-resource-health-patch.yaml" into the `spec` section of the object instance.

   - Click "Save" and ignore eventual warnings about the object being managed by other resources.

1. Launch the Argo CD console: Click on the grid-like icon in the upper-left section of the screen, where you should click on either "ArgoCD Console" (for OCP 4.6) or "Cluster Argo CD" (for OCP 4.7 and later.)

1. The Argo CD login screen will prompt you for an admin user and password. The default user is `admin .` The admin password is located in a secret in the `openshift-gitops` namespace.

   - The secret name is either `argocd-cluster-cluster` (for OCP 4.6) or `openshift-gitops-cluster` (for OCP 4.7 and later.)

   - Switch to the `openshift-gitops` project, locate the secret in the "Workloads -> Secrets" selections in the left-navigation tree of the Administrator view, scroll to the bottom, and click on "Reveal Values" to retrieve the value of the `admin.password` field.

   - Type in the user and password listed in the previous steps, and then click the "Sign In" button.

1. Once logged to the Argo CD console, click on the "New App+" button in the upper left of the Argo CD console and fill out the form with values matching the Cloud Pak of your choice, according to the table below:

    | Cloud Pak | Application Name | Path | Namespace |
    | --------- | ---------------- | ---- | --------- |
    | (base prereq for all cloudpaks, always add it first) | cp-shared-app | config/argocd-cloudpaks/cp-shared | ibm-cloudpaks |
    | Business Automation | cp4a-app | config/argocd-cloudpaks/cp4a | cp4a |
    | Integration Automation | cp4i-app | config/argocd-cloudpaks/cp4i | cp4i |
    | AIOps Automation | cp4aiops-app | config/argocd-cloudpaks/cp4aiops | openshift-operators |

    For all other fields, use the following values:

    | Field | Value |
    | ----- | ----- |
    | Project | default |
    | Sync policy | Automatic |
    | Self Heal | true |
    | Repository URL | https://github.com/IBM/cloudpak-gitops |
    | Revision | HEAD |
    | Cluster URL | https://kubernetes.default.svc |

1. Under "Parameters", if using OCP 4.7 or later, replace the value of the field `serviceaccount.argocd_application_controller` with the value `openshift-gitops-argocd-application-controller`

1. Still under "Parameters", set the values for the fields `storageclass.rwo.effective` and `storageclass.rwx.effective` with the appropriate storage classes. For OpenShift Container Storage, the values will be `ocs-storagecluster-ceph-rbd` and `ocs-storagecluster-cephfs`, respectively.

1. After filling out the form details, click the "Create" button

1. Wait for the synchronization to complete.

1. Enable auto-synchronization for the applications automatically created by the previous steps

   - For instance, if adding the "cp4a-app" application, it will automatically create two new applications, "cp4a-operators" and "cp4a-resources". The only exception is the "cp-shared-app" application, which does not bring in a "resources" application.

   - Click on the first application, such as "cp4a-operators", then select "App Details."

   - Scroll down to "Sync Policy" and select "Enable Auto-Sync."

   - Leave "Prune Resources" disabled

   - Enable "Self Heal" (this is required for some synchronizations where the first pass grants extra permissions to the Argo CD service account and the subsequent passes succeed with the extra permissions)

   - Exit the panel and wait for the synchronization to complete, then repeat the steps for the next application, which in this example would be "cp4a-resources".


### Using a terminal

1. Open a terminal and ensure you have the OpenShift CLI installed:
   ```sh
   oc version --client

   # Client Version: 4.8.2
   ```
   Ideally, the client's minor version should not be more than one iteration behind the version of the server. Most commands here are pretty basic and will work with more significant differences, but keep that in mind if you see errors about unrecognized commands and parameters.

   If you do not have the CLI installed, follow [these instructions](https://docs.openshift.com/container-platform/4.7/cli_reference/openshift_cli/getting-started-cli.html).

1. [Log in to the OpenShift CLI](https://docs.openshift.com/container-platform/4.7/cli_reference/openshift_cli/getting-started-cli.html#cli-logging-in_cli-developer-commands)

1. Configure the [custom resource health](https://argoproj.github.io/argo-cd/operator-manual/health/) checkers in the Argo CD server:

   Using OCP 4.6:

   ```sh
   oc patch ArgoCD/argocd-cluster \
            --namespace openshift-gitops \
            --type merge \
            --patch-file descriptors/resources/argocd-resource-health-patch.yaml
   ```

   Using OCP 4.7 and later:

   ```sh
   oc patch ArgoCD/openshift-gitops \
            --namespace openshift-gitops \
            --type merge \
            --patch-file descriptors/resources/argocd-resource-health-patch.yaml
   ```

1. [Install the Argo CD CLI](https://argoproj.github.io/argo-cd/cli_installation/)

1. Log in to the Argo CD server

   Using OCP 4.6:

   ```sh
    argo_route=argocd-cluster-server
    argo_secret=argocd-cluster-cluster
    sa_account=argocd-cluster-argocd-application-controller

    argo_pwd=$(oc get secret ${argo_secret} \
                  -n openshift-gitops 
                  -o jsonpath='{.data.admin\.password}' | base64 -d ; echo ) \
    && argo_url=$(oc get route ${argo_route} \
                    -n openshift-gitops \
                    -o jsonpath='{.spec.host}') 
    && argocd login "${argo_url}" \
         --username admin \
         --password "${argo_pwd}" \
         --insecure
   ```

   Using OCP 4.7 and later (the object names change a little from OCP 4.6:)

   ```sh
    argo_route=openshift-gitops-server
    argo_secret=openshift-gitops-cluster
    sa_account=openshift-gitops-argocd-application-controller

    argo_pwd=$(oc get secret ${argo_secret} \
                  -n openshift-gitops \
                  -o jsonpath='{.data.admin\.password}' | base64 -d ; echo ) \
    && argo_url=$(oc get route ${argo_route} \
                     -n openshift-gitops \
                     -o jsonpath='{.spec.host}') 
    && argocd login "${argo_url}" \
         --username admin \
         --password "${argo_pwd}" \
         --insecure
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
     # appname=<< choose a value from the "Application Name" column in the 
     # table of Cloud Paks above, such as cp4a-app, cp4i-app, 
     # cp4aiops-app, etc >>
     cp=cp4i
     app_name=${cp}-app
     # app_path=<< choose the respective value from the "path Name" 
     # column in the table of Cloud Paks above, such as 
     # config/argocd-cloudpaks/cp4i/cp4a, config/argocd-cloudpaks/cp4i, 
     # etc
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
