# 0003: ArgoCD for Kubernetes delivery, GitHub Actions for ECS

**Status:** Accepted
**Date:** 2026-07-28

## Problem

CI could deploy to Kubernetes directly with `helm upgrade`, which is what
`eks-deploy.yml` did. That works, but it means:

- CI holds long-lived cluster credentials, or an OIDC role with cluster-admin.
- The cluster's actual state is whatever the last successful job did, which is
  not written down anywhere.
- Drift from a manual `kubectl edit` is invisible until the next deploy
  overwrites it, or does not.

## Decision

Kubernetes state is declared in `gitops/` and reconciled by ArgoCD running
inside the cluster. CI's job ends at publishing a signed image and updating a
tag in git.

ECS keeps the push model: there is no in-cluster reconciler for ECS, and
introducing one would be more machinery than the problem warrants.

## Why app-of-apps

Terraform creates exactly one Application, `root`. Everything else is
discovered from the repository. Adding a workload is a file in
`gitops/applications/`, reviewed as a diff, with no Terraform run and no
`kubectl` access required.

## Environment policy

| | dev | staging | prod |
|---|---|---|---|
| Tracks | `main` | `main` | release tag |
| Auto-sync | yes | yes | no |
| Self-heal | yes | yes | no |
| Prune | yes | yes | on manual sync |

Production differs deliberately. Auto-sync on a branch means any merge reaches
production unattended. Self-heal in production would also revert an emergency
manual fix while an incident is still open, which is the worst possible moment
to be fighting a controller.

## Consequences

**Gained.** Cluster state is reviewable and revertible. Drift self-corrects in
non-production. CI never holds cluster-admin.

**Cost.** ArgoCD is another control plane to run, upgrade and secure, and it
holds cluster-admin on the cluster it manages. That is why anonymous access is
off, `policy.default` is `role:readonly`, and the chart version is pinned so a
sync cannot upgrade the delivery mechanism itself.

**Failure mode to know.** Deleting the cluster without first deleting the root
Application leaves finalizers unresolvable and the namespace stuck in
`Terminating`.
