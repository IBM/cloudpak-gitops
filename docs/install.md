# Installation

## Contents

- [Prerequisites](#prerequisites)
- [Install the OpenShift GitOps operator](#install-the-openshift-gitops-operator)
  * [Using the OCP console](#using-the-ocp-console)
  * [Using a terminal](#using-a-terminal)
- [Obtain an entitlement key](#obtain-an-entitlement-key)
- [Update the OCP global pull secret](#update-the-ocp-global-pull-secret)
  * [Update the global pull secret using the OpenShift console](#update-the-global-pull-secret-using-the-openshift-console)
  * [Special note about global pull secrets on ROKS](#special-note-about-global-pull-secrets-on-roks)
- [Update the pull secret in the openshift-gitops namespace](#update-the-pull-secret-in-the-openshift-gitops-namespace)
- [Adding Cloud Pak GitOps Application objects to your GitOps server](#adding-cloud-pak-gitops-application-objects-to-your-gitops-server)
  * [Using the OCP console](#using-the-ocp-console-1)
  * [Using a terminal](#using-a-terminal-1)
- [Post-configuration steps](#post-configuration-steps)
  * [Local configuration steps](#local-configuration-steps)
    + [Cloud Pak for Data](#cloud-pak-for-data)
    + [Cloud Pak for Integration](#cloud-pak-for-integration)
- [Duplicate this repository](#duplicate-this-repository)

---

## Prerequisites

- An OpenShift Container Platform cluster, version 4.6 or later.

  The applications were tested on both managed and self-managed deployments.

- Adequate worker node capacity in the cluster for the Cloud Paks to be installed.

  Refer to the [Cloud Pak documentation](https://www.ibm.com/docs/en/cloud-paks) to determine the required capacity for the cluster.

- Cluster storage configured with storage classes supporting both [RWO and RWX storage](https://kubernetes.io/docs/concepts/storage/persistent-volumes/#access-modes).

  The applications were tested with [OpenShift Container Storage](https://docs.openshift.com/container-platform/4.8/storage/persistent_storage/persistent-storage-ocs.html), [Rook Ceph](https://github.com/rook/rook), [AWS EFS](https://aws.amazon.com/efs/), and the built-in file storage in ROKS classic clusters.

- [An entitlement key to the IBM Entitled Registry](#obtain-an-entitlement-key)

---

## Install the OpenShift GitOps operator

### Using the OCP console

1. From the Administrator's perspective, navigate to the OperatorHub page.

1. Search for "Red Hat OpenShift GitOps." Click on the tile and then click on "Install."

1. Keep the defaults in the wizard and click on "Install."

1. Wait for it to appear in the " Installed Operators list." If it doesn't install correctly, you can check its status on the "Installed Operators" page in the `openshift-operators` namespace.

### Using a terminal

1. Open a terminal and ensure you have the OpenShift CLI installed:

   ```sh
   oc version --client

   # Client Version: 4.8.2
   ```

   Ideally, the client's minor version should be at most one iteration behind the server version. Most commands here are pretty basic and will work with more significant differences, but keep that in mind if you see errors about unrecognized commands and parameters.

   If you do not have the CLI installed, follow [these instructions](https://docs.openshift.com/container-platform/4.7/cli_reference/openshift_cli/getting-started-cli.html).

1. [Login to the OpenShift CLI](https://docs.openshift.com/container-platform/4.7/cli_reference/openshift_cli/getting-started-cli.html#cli-logging-in_cli-developer-commands)

1. Create the `Subscription` resource for the operator:

   ```sh
   cat << EOF | oc apply -f -
   ---
   apiVersion: operators.coreos.com/v1alpha1
   kind: Subscription
   metadata:
      name: openshift-gitops-operator
      namespace: openshift-operators
   spec:
      channel: stable
      installPlanApproval: Automatic
      name: openshift-gitops-operator
      source: redhat-operators
      sourceNamespace: openshift-marketplace
   EOF
   ```

---

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

## Update the OCP global pull secret

[Update the OCP global pull secret](https://docs.openshift.com/container-platform/4.7/openshift_images/managing_images/using-image-pull-secrets.html) with the entitlement key.

Remember that that secret's registry user is `cp`. A common mistake is to assume the registry user is the name or email of the user owning the entitlement key.

### Update the global pull secret using the OpenShift console

1. Navigate to the "Workloads > Secrets" page in the "Administrator" perspective.

1. Select the object "pull-secret."

1. Click on "Actions -> Edit secret."

1. Scroll to the bottom of that page and click on "Add credentials," using the following values for each field:

   - "Registry Server Address" cp.icr.io
   - "Username": cp
   - "Password": paste the entitlement key you copied from the [Obtain an entitlement key](#obtain-an-entitlement-key) 
   - "Email": any email, valid or not, will work. This field is mostly a hint to other people who may see the entry in the configuration

1. Click on "Save."

### Special note about global pull secrets on ROKS

Updating the OCP global pull secret triggers the staggered restart of each node in the cluster. However, the [Red Hat OpenShift on IBM Cloud](https://www.ibm.com/cloud/openshift) platform requires an additional step: reload all workers nodes (in the case of ROKS classic clusters) or replace all workers nodes (in the case of ROKS VPC Gen2 clusters.)

You can perform the reloading or replacement of workers directly from the cluster page in the IBM Cloud console or use a terminal, following the instructions listed [here](https://cloud.ibm.com/docs/openshift?topic=openshift-registry&_ga=2.262606922.775805413.1629911830-822975074.1629149367#cluster_global_pull_secret).

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
        --docker-email="non-existent-replace-with0-yours@email.com" \
        --namespace=openshift-gitops
```

---

## Adding Cloud Pak GitOps Application objects to your GitOps server

**Important**: The instructions for installing and configuring the OpenShift GitOps operator are meant **exclusively for demonstration purposes**. For users who already manage their own OpenShift GitOps installation, read the contents of the `config/argocd/templates` folder carefully and assess whether the settings are compatible with your installation, especially when it comes to the `.spec.resourceCustomizations` field of the `ArgoCD` custom resource.

The instructions in this section assume you have administrative privileges to the Argo CD instance.

After completing the list of activities listed in the previous sections, you can add the Argo CD `Application` objects for a Cloud Pak using either the OpenShift Container Platform console or using commands in a terminal.

### Using the OCP console

1. Launch the Argo CD console: Click on the grid-like icon in the upper-left section of the screen, where you should click on "Cluster Argo CD."

1. The Argo CD login screen will prompt you for an admin user and password. The default user is `admin .` The admin password is located in secret `openshift-gitops-cluster` in the `openshift-gitops` namespace.

   - Switch to the `openshift-gitops` project, locate the secret in the "Workloads -> Secrets" selections in the left-navigation tree of the Administrator view, scroll to the bottom, and click on "Reveal Values" to retrieve the value of the `admin.password` field.

   - Type in the user and password listed in the previous steps, and click the "Sign In" button.

1. (add Argo app) Once logged to the Argo CD console, click on the "New App+" button in the upper left of the Argo CD console and fill out the form with values matching the Cloud Pak of your choice, according to the table below:

    For all other fields, use the following values:

    | Field | Value |
    | ----- | ----- |
    | Application Name | argo-app |
    | Path | config/argocd |
    | Namespace | openshift-gitops |
    | Project | default |
    | Sync policy | Automatic |
    | Self Heal | true |
    | Repository URL | <https://github.com/IBM/cloudpak-gitops> |
    | Revision | HEAD |
    | Cluster URL | <https://kubernetes.default.svc> |

1. (add Cloud Pak Shared app) Click on the "New App+" button again and fill out the form with values matching the Cloud Pak of your choice, according to the table below:

    For all other fields, use the following values:

    | Field | Value |
    | ----- | ----- |
    | Application Name | cp-shared-app |
    | Path | config/argocd-cloudpaks/cp-shared |
    | Namespace | ibm-cloudpaks |
    | Project | default |
    | Sync policy | Automatic |
    | Self Heal | true |
    | Repository URL | <https://github.com/IBM/cloudpak-gitops> |
    | Revision | HEAD |
    | Cluster URL | <https://kubernetes.default.svc> |

1. After filling out the form details, click the "Create" button

1. (add actual Cloud Pak) Click on the "New App+" button again and fill out the form with values matching the Cloud Pak of your choice, according to the table below:

    | Cloud Pak | Application Name | Path | Namespace |
    | --------- | ---------------- | ---- | --------- |
    | Business Automation | cp4a-app | config/argocd-cloudpaks/cp4a | cp4a |
    | Integration | cp4i-app | config/argocd-cloudpaks/cp4i | cp4i |
    | Watson AIOps | cp4waiops-app | config/argocd-cloudpaks/cp4waiops | cp4waiops |
    | Data | cp4d-app | config/argocd-cloudpaks/cp4d | cp4d |
    | Security | cp4s-app | config/argocd-cloudpaks/cp4s | cp4s |

    For all other fields, use the following values:

    | Field | Value |
    | ----- | ----- |
    | Project | default |
    | Sync policy | Automatic |
    | Self Heal | true |
    | Repository URL | <https://github.com/IBM/cloudpak-gitops> |
    | Revision | HEAD |
    | Cluster URL | <https://kubernetes.default.svc> |

1. After filling out the form details, click the "Create" button

1. Under "Parameters," set the values for the fields `storageclass.rwo` and `storageclass.rwx` with the appropriate storage classes. For OpenShift Container Storage, the values will be `ocs-storagecluster-ceph-rbd` and `ocs-storagecluster-cephfs`, respectively.

1. After filling out the form details, click the "Create" button

1. Wait for the synchronization to complete.

### Using a terminal

1. Open a terminal and ensure you have the OpenShift CLI installed:

   ```sh
   oc version --client

   # Client Version: 4.10.35
   ```

   Ideally, the client's minor version should be at most one iteration behind the server version. Most commands here are pretty basic and will work with more significant differences, but keep that in mind if you see errors about unrecognized commands and parameters.

   If you do not have the CLI installed, follow [these instructions](https://docs.openshift.com/container-platform/4.7/cli_reference/openshift_cli/getting-started-cli.html).

1. [Login to the OpenShift CLI](https://docs.openshift.com/container-platform/4.7/cli_reference/openshift_cli/getting-started-cli.html#cli-logging-in_cli-developer-commands)

1. [Install the Argo CD CLI](https://argoproj.github.io/argo-cd/cli_installation/)

1. Log in to the Argo CD server

   ```sh
   gitops_url=https://github.com/IBM/cloudpak-gitops
   gitops_branch=main
   argo_pwd=$(oc get secret openshift-gitops-cluster \
                  -n openshift-gitops \
                  -o go-template='{{index .data "admin.password"|base64decode}}') \
   && argo_url=$(oc get route openshift-gitops-server \
                  -n openshift-gitops \
                  -o jsonpath='{.spec.host}') \
   && argocd login "${argo_url}" \
         --username admin \
         --password "${argo_pwd}" \
         --insecure
   ```

1. Add the `argo` application. (this step assumes you still have the shell variables assigned from previous actions) :

   ```sh
   argocd proj create argocd-control-plane \
         --dest "https://kubernetes.default.svc,openshift-gitops" \
         --src ${gitops_url:?} \
         --upsert \
   && argocd app create argo-app \
         --project argocd-control-plane \
         --dest-namespace openshift-gitops \
         --dest-server https://kubernetes.default.svc \
         --repo ${gitops_url:?} \
         --path config/argocd \
         --helm-set-string targetRevision="${gitops_branch}" \
         --revision ${gitops_branch:?} \
         --sync-policy automated \
         --upsert 
    ```

1. Add the `cp-shared` application. (this step assumes you still have the shell variables assigned from previous steps) :

   ```sh
   cp_namespace=ibm-cloudpaks
   argocd app create cp-shared-app \
         --project default \
         --dest-namespace openshift-gitops \
         --dest-server https://kubernetes.default.svc \
         --repo ${gitops_url:?} \
         --path config/argocd-cloudpaks/cp-shared \
         --helm-set-string argocd_app_namespace="${cp_namespace}" \
         --helm-set-string metadata.argocd_app_namespace="${cp_namespace}" \
         --sync-policy automated \
         --revision ${gitops_branch:?} \
         --upsert
   ```

1. Add the respective Cloud Pak application (this step assumes you still have shell variables assigned from previous steps) :

   ```sh
   # appname=<< choose a value from the "Application Name" column in the 
   # table of Cloud Paks above, such as cp4a-app, cp4i-app, 
   # cp4waiops-app, cp4d-app, etc >>
   cp=cp4i
   app_name=${cp}-app
   # app_path=<< choose the respective value from the "path name." 
   # column in the table of Cloud Paks above, such as 
   # config/argocd-cloudpaks/cp4i/cp4a, config/argocd-cloudpaks/cp4i, 
   # etc
   app_path=config/argocd-cloudpaks/${cp}

   argocd app create "${app_name}" \
         --project default \
         --dest-namespace openshift-gitops \
         --dest-server https://kubernetes.default.svc \
         --helm-set-string metadata.argocd_app_namespace="${cp_namespace}" \
         --helm-set-string repoURL=${gitops_url:?} \
         --helm-set-string targetRevision="${gitops_branch}" \
         --path "${app_path}" \
         --repo ${gitops_url:?} \
         --revision "${gitops_branch}" \
         --sync-policy automated \
         --upsert 
    ```

1. List all the applications to see their overall status (this step assumes you still have shell variables assigned from previous steps):

   ```sh
   argocd app list -l app.kubernetes.io/instance=${app_name}
   ```

1. You can also use the ArgoCD command-line interface to wait for the application to be synchronized and healthy:

   ```sh
   argocd app wait "${app_name}" \
         --sync \
         --health \
         --timeout 3600
   ```

---

## Post-configuration steps

In a GitOps practice, the "post-configuration" phase would entail committing changes to the repository and waiting for the GitOps operator to synchronize those settings toward the target environments.

### Local configuration steps

This repository allows some light customizations to enable its reuse for demonstration purposes without requiring the cloning or forking of the repository.

#### Cloud Pak for Data

The main Argo Application for the Cloud Pak (`config/argocd-cloudpaks/cp4i`) has a parameter named `components`, which contains a comma-separated list of components names matching the values in the [product documentation](https://www.ibm.com/docs/en/cloud-paks/cp-data/4.6.x?topic=information-determining-which-components-install).

Alter the values in this array with the element names found in the product documentation (e.g., `wml` for Watson Machine Learning) to define the list of components installed in the target cluster.

#### Cloud Pak for Integration

The main Argo Application for the Cloud Pak (`config/argocd-cloudpaks/cp4i`) has a parameter array named `modules`, where you will find boolean values for various modules, such as `apic`, `mq`, and `platform`.

Set those values to `true` or `false` to define which Cloud Pak modules you want to install in the target cluster.

---

## Duplicate this repository

Given the demonstration purposes of this repository, it is unsuited for anchoring a true GitOps deployment for many reasons. The primary limitation is the repository not being designed to represent any concrete deployment environment (e.g., there is no environment-specific folder where you could list the Cloud Pak components for a specific cluster.)

In that sense, you can duplicate the repository on a different Git organization and use that repository as the starting point to deploy Cloud Paks in your environments. This is a non-comprehensive list of aspects you should address in that new repository:

- If you already have the OpenShift GitOps operator installed in your target clusters:
   1. Merge the `.spec.resourceCustomizations` resources found in `argocd/templates/argocd.yaml` into the `ArgoCD.argoproj.io` instance for your cluster
   1. Delete the entire folder `/argocd`
- Delete folders corresponding to Cloud Paks you don't plan on using. These Cloud Pak folders are located under the `/config/argocd-cloudpaks` and `/config` folders.
