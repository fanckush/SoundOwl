#!/usr/bin/env bash
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

git config core.hooksPath .githooks

echo "Git hooks enabled for this clone:"
echo "  pre-commit: lint staged Swift files"
echo "  commit-msg: validate the conventional commit subject"
echo "  pre-push:   run package and app unit tests"

echo
echo "Lint tools are pinned in scripts/lint.sh and downloaded on first use."
