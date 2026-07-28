# MCP servers

`.mcp.json` configures seven Model Context Protocol servers so an assistant can
inspect this platform without a human relaying console output.

| Server | Source | Reaches AWS? | Mode |
|---|---|---|---|
| `aws-api` | `awslabs.aws-api-mcp-server` | yes | read-only |
| `eks` | `awslabs.eks-mcp-server` | yes | read |
| `ecs` | `awslabs.ecs-mcp-server` | yes | read-only |
| `cloudwatch` | `awslabs.cloudwatch-mcp-server` | yes | read |
| `iam` | `awslabs.iam-mcp-server` | yes | `--readonly` |
| `terraform` | `hashicorp/terraform-mcp-server` (Docker) | no | registry lookups |
| `aws-docs` | `awslabs.aws-documentation-mcp-server` | no | docs lookups |

## Credentials

These inherit the ambient AWS session. `AWS_PROFILE` is `default`, which
`~/.aws/config` maps to `arn:aws:iam::113897201107:user/muktha-aws`.

Authenticate before starting a session:

```bash
aws login
aws sts get-caller-identity   # confirm it is muktha-aws, not root
```

If the session has expired, every AWS-backed server returns auth errors rather
than failing to start, which reads as a broken server when it is a broken
session.

## Why everything is read-only

An assistant answering "why is the service unhealthy?" should not be able to
change the service as a side effect. Provisioning goes through Terraform and a
reviewed plan; these servers exist to observe.

This is enforced per server, since each exposes a different switch:

- `aws-api`: `READ_OPERATIONS_ONLY=true` and `REQUIRE_MUTATION_CONSENT=true`
- `ecs`: `ALLOW_WRITE=false`, `ALLOW_SENSITIVE_DATA=false`
- `iam`: `--readonly`

Relaxing any of these is a deliberate decision, not a default.

## Two packages that are not what you would guess

**`awslabs.terraform-mcp-server` is yanked** on PyPI, superseded by HashiCorp's
own server. The replacement is a Docker image, so `docker` must be running for
that server to start.

**`awslabs.aws-diagram-mcp-server` is also yanked**, with no successor. It is
omitted rather than replaced: the diagrams in `docs/diagrams/` are mermaid,
which renders natively in GitHub and in artifacts, so nothing depended on it.

**`awslabs.ecs-mcp-server` installs a console script named `ecs-mcp-server`**,
not one matching the package name. `uvx awslabs.ecs-mcp-server` therefore exits
1 silently, having found no command to run. The config uses
`uvx --from awslabs.ecs-mcp-server@latest ecs-mcp-server`. The other five all
name their script after the package, so plain `uvx <package>` works.

## Verifying

Each server speaks MCP over stdio, so a handshake is the honest test:

```bash
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}' \
  | uvx --quiet --from awslabs.ecs-mcp-server@latest ecs-mcp-server
```

A JSON-RPC result with `serverInfo` means it works. `--help` is not a reliable
check: some of these servers do not implement it and exit non-zero.

## What they are used for here

- `terraform` and `aws-docs` for provider schemas, module lookups and service
  limits while writing IaC.
- `aws-api`, `eks`, `ecs`, `cloudwatch` for inspecting a deployed environment
  during the scenarios in `docs/scenarios/`.
- `iam` for auditing the permission boundary and role trust policies, which is
  exactly the kind of read that is tedious by hand and easy to get wrong.
