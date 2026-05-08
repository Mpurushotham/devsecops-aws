#!/usr/bin/env bash
# Initial workstation setup for DevSecOps on AWS project.
set -euo pipefail

echo "=== DevSecOps AWS Setup ==="

check_tool() {
  if command -v "$1" &>/dev/null; then
    echo "[OK] $1 $(${1} --version 2>&1 | head -1)"
  else
    echo "[MISSING] $1 — install required"
  fi
}

echo ""
echo "--- Checking required tools ---"
check_tool aws
check_tool terraform
check_tool kubectl
check_tool helm
check_tool docker
check_tool git
check_tool gh

echo ""
echo "--- Checking security tools ---"
check_tool checkov
check_tool tfsec
check_tool trivy
check_tool cosign

if ! command -v checkov &>/dev/null; then
  echo "Installing checkov..."
  pip3 install checkov
fi

if ! command -v tfsec &>/dev/null; then
  echo "Installing tfsec..."
  brew install tfsec 2>/dev/null || curl -sSL https://raw.githubusercontent.com/aquasecurity/tfsec/master/scripts/install_linux.sh | bash
fi

if ! command -v trivy &>/dev/null; then
  echo "Installing trivy..."
  brew install trivy 2>/dev/null || curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin
fi

if ! command -v cosign &>/dev/null; then
  echo "Installing cosign..."
  brew install cosign 2>/dev/null || true
fi

echo ""
echo "--- AWS Configuration ---"
if aws sts get-caller-identity &>/dev/null; then
  echo "[OK] AWS credentials configured"
  aws sts get-caller-identity
else
  echo "[ACTION] Run: aws configure"
fi

echo ""
echo "--- Pre-commit hooks ---"
if ! command -v pre-commit &>/dev/null; then
  pip3 install pre-commit
fi

if [ -f .pre-commit-config.yaml ]; then
  pre-commit install
  echo "[OK] Pre-commit hooks installed"
fi

echo ""
echo "Setup complete!"
