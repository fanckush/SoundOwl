#!/usr/bin/env bash
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

# Pinned so local runs, the pre-commit hook and CI all lint with the same rules.
# To bump: change the version and set the sha256 of the release zip.
swiftformat_version=0.63.1
swiftformat_sha256=385ef1a263ba28685157b98c5536b9c9105e124518f28b7ef8a2bee4b167eaeb
swiftlint_version=0.65.1
swiftlint_sha256=c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0

tools_dir="$repo_root/.build/tools"

# Downloads a release zip once, verifies it and prints the path of the binary.
fetch_tool() {
  local name=$1 version=$2 sha256=$3 url=$4
  local dir="$tools_dir/$name-$version"
  if [[ ! -x "$dir/$name" ]]; then
    echo ">> Downloading $name $version" >&2
    local tmp
    tmp=$(mktemp -d)
    curl -fsSL "$url" -o "$tmp/$name.zip"
    if ! echo "$sha256  $tmp/$name.zip" | shasum -a 256 -c --status; then
      echo "error: checksum mismatch for $name $version" >&2
      rm -rf "$tmp"
      exit 1
    fi
    mkdir -p "$dir"
    unzip -q -o "$tmp/$name.zip" "$name" -d "$dir"
    rm -rf "$tmp"
  fi
  echo "$dir/$name"
}

swiftformat=$(fetch_tool swiftformat "$swiftformat_version" "$swiftformat_sha256" \
  "https://github.com/nicklockwood/SwiftFormat/releases/download/$swiftformat_version/swiftformat.zip")
swiftlint=$(fetch_tool swiftlint "$swiftlint_version" "$swiftlint_sha256" \
  "https://github.com/realm/SwiftLint/releases/download/$swiftlint_version/portable_swiftlint.zip")

if [[ "${1:-}" == "--staged" ]]; then
  if git diff --cached --quiet --diff-filter=ACMR -- '*.swift'; then
    echo "No staged Swift files to lint."
    exit 0
  fi

  echo ">> Checking staged Swift files with SwiftFormat $swiftformat_version"
  git diff --cached --name-only --diff-filter=ACMR -z -- '*.swift' \
    | xargs -0 "$swiftformat" --lint --cache ignore

  echo ">> Checking staged Swift files with SwiftLint $swiftlint_version"
  git diff --cached --name-only --diff-filter=ACMR -z -- '*.swift' \
    | xargs -0 "$swiftlint" lint --strict --no-cache --config .swiftlint.yml
elif [[ "${1:-}" == "--fix" ]]; then
  echo ">> Formatting repository with SwiftFormat $swiftformat_version"
  "$swiftformat" --cache ignore .

  echo ">> Fixing repository with SwiftLint $swiftlint_version"
  "$swiftlint" lint --fix --no-cache --config .swiftlint.yml
else
  echo ">> Checking repository with SwiftFormat $swiftformat_version"
  "$swiftformat" --lint --cache ignore .

  echo ">> Checking repository with SwiftLint $swiftlint_version"
  "$swiftlint" lint --strict --no-cache --config .swiftlint.yml
fi
