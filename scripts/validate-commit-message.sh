#!/usr/bin/env bash
set -euo pipefail

message_file=${1:?usage: validate-commit-message.sh MESSAGE_FILE}
subject=$(head -n 1 "$message_file")

if [[ "$subject" == "Initial commit" ]] \
  || [[ "$subject" =~ ^(feat|fix|docs|chore|perf)(\([^\)]+\))?(!)?:\ .+ ]]; then
  exit 0
fi

cat >&2 <<'EOF'
error: commit subject must use one of:
  feat: short description
  fix: short description
  docs: short description
  chore: short description
  perf: short description

Optional scopes and breaking markers are supported, for example:
  feat(export): add FLAC output
  feat!: change configuration format
EOF
exit 1
