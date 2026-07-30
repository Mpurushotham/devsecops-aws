# Vendored: AWS Retail Store Sample Application

This directory is a vendored copy of an upstream AWS sample. It is **not**
maintained here, and local edits will be lost on the next refresh.

| | |
|---|---|
| Upstream | https://github.com/aws-containers/retail-store-sample-app |
| Version | `v1.6.2` |
| Commit | `1a28474f2461459f42e6b393db59e7d1434d4aec` |
| License | MIT-0 (see `LICENSE`) |
| Vendored on | 2026-07-28 |

## Why this application

The platform in this repository needs a workload that is realistic enough to
prove the pipeline actually works. A single "hello world" container exercises
almost none of it.

This sample is AWS's own reference application for container platforms, and it
is the workload used in the EKS and ECS workshops. It gives us:

- **Five services in four languages** — UI (Java), catalog (Go), cart (Java),
  checkout (Node.js), orders (Java). A single-language app would not have
  exposed whether the build and scan pipeline generalises.
- **Real dependencies** — MySQL, DynamoDB, Redis, RabbitMQ. These force the
  network policy, security group and IRSA work to be correct rather than
  theoretical.
- **Both deployment targets** — upstream ships ECS and EKS Terraform under
  `terraform/`, and Helm charts under `src/*/chart`, so the same application
  can be deployed both ways and compared.

## Why it is vendored rather than submoduled

A submodule would keep the tree smaller, but it also means a clone of this
repository is not self-contained and CI has to be told to recurse. Since the
point of this directory is to be a reproducible deployment target, having the
exact reviewed bytes committed is worth the 27 MB.

## Relationship to `src/app`

`src/app` is the small first-party FastAPI service. It is what the CI pipeline
in `.github/workflows/devsecops-pipeline.yml` builds, tests and deploys, and it
is deliberately small so the pipeline stays fast.

This directory is the richer deployment scenario, exercised through the
documented flows in `docs/scenarios/`.

## Scanner scope

Third-party code is scanned for awareness but does not gate this repository's
CI. Findings in upstream code are not ours to fix and would block unrelated
changes; see `.semgrepignore` and ADR 0008. Refreshing the vendored copy is the
correct response to an upstream vulnerability, not patching in place.

## Refreshing

```bash
git clone --depth 1 --branch <new-tag> \
  https://github.com/aws-containers/retail-store-sample-app.git /tmp/retail
rm -rf app && mkdir app
(cd /tmp/retail && tar --exclude='.git' -cf - .) | (cd app && tar -xf -)
```

Then update the version, commit and date in the table above.
