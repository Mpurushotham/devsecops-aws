# tflint configuration.
#
# Scope note: CI runs tflint with --chdir=terraform, so the vendored app/ tree
# is never linted. Third-party Terraform is not ours to restyle, and 11 of its
# findings would otherwise sit permanently in the output, training everyone to
# ignore the tool.

config {
  call_module_type = "local"
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.44.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}
