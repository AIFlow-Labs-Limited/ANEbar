#!/usr/bin/env bash
set -euo pipefail

# Pull latest commit from upstream ANE into submodule tracking branch.
git submodule update --init --recursive

git submodule update --remote --recursive upstream/ANE

git -C upstream/ANE status --short --branch
