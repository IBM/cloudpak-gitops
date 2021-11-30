# Contributing

Making changes to this repository requires a working knowledge of Argo CD administration and configuration. This section describes the workflow of submitting a change. The change entails forking the repository, modifying it, installing the changes on a target cluster to validate them, then gathering the output of validation commands using the `argocd` command-line interface.

## Set up a local environment

1. Follow the [installation instructions](docs/install.md) to install the Cloud Pak in a target cluster.

1. Fork, clone, or branch the repository. Branching works too, but the instructions assume the contributor is not an author in this repository.

1. Click on the application and then click the "Edit" button.

1. If using forks or clones, switch to the "Parameters" tab and change the "repoURL" field to match the URL of your repository.

1. In the "Summary" tab, set the "TARGET REVISION" field to match the repository's branch where you are making changes.

1. You can also use a terminal to make the changes to the application, using the Argo CD CLI:

    ```sh
    argocd app set <app-name> \
        --repo <url-fork-or-clone> \
        --revision <branch-in-repo> \
        --helm-set repoURL=<url-fork-or-clone> \
        --helm-set targetRevision=<branch-in-repo>
    ```

    For instance, assuming you cloned this repo into https://github.com/nastacio/cloudpak-gitops, and you wanted to make changes to the `cp4i-app` Application in a branch named `new-feature`, you would run the command like this:

    ```sh
    argocd app set cp4i-app \
        --repo https://github.com/nastacio/cloudpak-gitops \
        --revision new-feature \
        --helm-set repoURL=https://github.com/nastacio/cloudpak-gitops \
        --helm-set targetRevision=new-feature
    ```

    Since the application has an automated synchronization policy, the synchronization with the new repository and branch would start immediately.

## Validating the changes

The previous section instructs Argo CD to use your repository and branch as the source of the applications. After that point, you can make further modifications to the branch using commands like `git push` and use the Argo CD console or command-line interface to refresh the application's state from the git repository.

Once the changes are validated, following the respective Cloud Pak documentation instructions, submit a pull request to the original repository.
