# IBM Cloud Paks - GitOps Demo

## Contents

- [Overview](#overview)
  - [IBM Cloud Paks](#ibm-cloud-paks)
  - [GitOps](#gitops)
  - [Governance Policies](#governance-policies)
- [Installation](#installation)
  - [Individual clusters](#individual-clusters)
  - [Fleet of clusters with governance](#fleet-of-clusters-with-governance)
- [Contributing](#contributing)

---

## Overview

This repository contains Argo CD `Application` resources representing sample deployments of IBM Cloud Paks, and, as such, they are meant for inclusion in an Argo CD cluster. Different Cloud Paks are represented with different `Application` resources and grouped by a resource label tied to each Cloud Pak.

**Important**: This repository is meant as a demonstration of how Cloud Pak deployments can be deployed and managed with GitOps practices. Adoption in a production environment can start from a repository fork, followed by customization of folders and files to match the desired configuration.

You may decide to include one or more of these `Application` objects to the target cluster and then determine which ones you want to synchronize into the cluster.

### IBM Cloud Paks

[IBM Cloud® Paks](https://www.ibm.com/cloud/paks) help organizations build, modernize, and manage applications securely across any cloud.

The supported deployment mechanisms for Cloud Paks are documented in their respective [documentation pages](https://www.ibm.com/docs/en/cloud-paks) and typically included a UI-based deployment through the Operator Hub page or, in some cases, scripted alternatives based on command-line interfaces.

Supported versions:

| Cloud Pak | Version | Installation mode |
| ----------|---------|-------------------|
| Cloud Pak for Business Automation | [22.0.1](https://www.ibm.com/docs/en/cloud-paks/cp-biz-automation/22.0.1) | Starter Path|
| Cloud Pak for Data | [4.5.3](https://www.ibm.com/docs/en/cloud-paks/cp-data/4.5.x?topic=overview) | Express Installation |
| Cloud Pak for Integration | [2022.2](https://www.ibm.com/docs/en/cloud-paks/cp-integration/2022.2) | Starter Path |
| Cloud Pak for Security | [1.10](https://www.ibm.com/docs/en/cloud-paks/cp-security/1.10) | Starter Path |
| Cloud Pak for Watson AIOps | [3.5.1](https://www.ibm.com/docs/en/cloud-paks/cloud-pak-watson-aiops/3.5.1) | Starter Path |

### GitOps

GitOps is a declarative way to implement continuous deployment for cloud-native applications. The Red Hat® OpenShift® Container Platform offers the [OpenShift GitOps operator](https://docs.openshift.com/container-platform/4.7/cicd/gitops/understanding-openshift-gitops.html), which manages the entire lifecycle for [Argo CD](https://argoproj.github.io/argo-cd/) and its components.

### Governance Policies

Practicing GitOps at scale, with dozens or even hundreds of clusters, benefits from a level of abstraction where each cluster follows a few select policies. This repository contains a simple deployment of governance policies for the deployment of OpenShift GitOps and Cloud Paks to a fleet of clusters.

## Installation

### Individual clusters

Argo applications are added to the Argo CD server. An application defines the source of the Kubernetes resources and the target cluster where those resources should be deployed. The Argo CD server "installs" a Cloud Pak by synchronizing the applications representing the Cloud Pak into the target cluster.

Refer to the [installation page](docs/install.md) for instructions on configuring an OCP server with the OpenShift GitOps operator and then adding the Cloud Pak GitOps resources to the default GitOps server created by the operator.

### Fleet of clusters with governance

Use governance policies and placement rules to configure entire clusters with GitOps infrastructure and manage Cloud Pak deployments from Red Hat Advanced Cluster Management for Kubernetes (RHACM.)

Refer to the [RHACM page](docs/rhacm.md) for an overview and instructions on how to add RHACM to an existing OpenShift cluster.

## Contributing

Making changes to this repository requires a working knowledge of Argo CD administration and configuration. This section describes the workflow of submitting a change. A change entails forking the repository, modifying it, installing the changes on a target cluster to validate them, then gathering the output of validation commands using the `argocd` command-line interface.

Navigate to the [contributing](CONTRIBUTING.md) page for details on validating changes and submitting a pull request with all the required information.
