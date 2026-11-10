#!/usr/bin/env python3
"""Calculate the next stable SemVer from Conventional Commit messages."""

from __future__ import annotations

import argparse
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


STABLE_TAG = re.compile(r"^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$")
SUBJECT = re.compile(
    r"^(?P<type>feat|fix|docs|chore|perf)(?:\([^()\r\n]+\))?(?P<breaking>!)?:\s+\S"
)
BREAKING_FOOTER = re.compile(r"^BREAKING(?: CHANGE|-CHANGE):\s*\S", re.MULTILINE)


@dataclass(frozen=True, order=True)
class Version:
    major: int
    minor: int
    patch: int

    @classmethod
    def from_tag(cls, tag: str) -> "Version":
        match = STABLE_TAG.fullmatch(tag)
        if match is None:
            raise ValueError(f"not a stable release tag: {tag}")
        return cls(*(int(part) for part in match.groups()))

    @property
    def tag(self) -> str:
        return f"v{self.major}.{self.minor}.{self.patch}"

    def bump(self, level: str) -> "Version":
        if level == "major":
            # Before 1.0, breaking changes advance the minor line. Reaching 1.0 is intentional.
            if self.major == 0:
                return Version(0, self.minor + 1, 0)
            return Version(self.major + 1, 0, 0)
        if level == "minor":
            return Version(self.major, self.minor + 1, 0)
        if level == "patch":
            return Version(self.major, self.minor, self.patch + 1)
        if level == "none":
            return self
        raise ValueError(f"unknown bump level: {level}")


@dataclass(frozen=True)
class Analysis:
    bump: str
    commit_count: int
    unknown_count: int


def analyze(messages: Iterable[str]) -> Analysis:
    rank = {"none": 0, "patch": 1, "minor": 2, "major": 3}
    bump = "none"
    commit_count = 0
    unknown_count = 0

    for message in messages:
        if not message.strip():
            continue
        commit_count += 1
        subject = message.splitlines()[0]
        match = SUBJECT.match(subject)
        if match is None:
            unknown_count += 1
            continue
        if match.group("breaking") or BREAKING_FOOTER.search(message):
            candidate = "major"
        elif match.group("type") == "feat":
            candidate = "minor"
        elif match.group("type") in {"fix", "perf"}:
            candidate = "patch"
        else:
            candidate = "none"
        if rank[candidate] > rank[bump]:
            bump = candidate

    return Analysis(bump=bump, commit_count=commit_count, unknown_count=unknown_count)


def git(repository: Path, *arguments: str) -> str:
    return subprocess.run(
        ["git", *arguments],
        cwd=repository,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
    ).stdout


def latest_stable_tag(repository: Path, head: str) -> tuple[str, Version]:
    tags = git(repository, "tag", "--merged", head, "--list", "v*").splitlines()
    versions = [(Version.from_tag(tag), tag) for tag in tags if STABLE_TAG.fullmatch(tag)]
    if not versions:
        raise RuntimeError("no stable vMAJOR.MINOR.PATCH tag is reachable from the selected commit")
    version, tag = max(versions)
    return tag, version


def messages_since(repository: Path, tag: str, head: str) -> list[str]:
    output = subprocess.run(
        ["git", "log", "-z", "--format=%B", f"{tag}..{head}"],
        cwd=repository,
        check=True,
        stdout=subprocess.PIPE,
    ).stdout
    return [item.decode("utf-8", errors="replace") for item in output.split(b"\0") if item.strip()]


def calculate(repository: Path, head: str) -> dict[str, str]:
    tag, version = latest_stable_tag(repository, head)
    analysis = analyze(messages_since(repository, tag, head))
    next_version = version.bump(analysis.bump)
    return {
        "current_tag": tag,
        "current_version": tag.removeprefix("v"),
        "bump": analysis.bump,
        "next_tag": "" if analysis.bump == "none" else next_version.tag,
        "next_version": "" if analysis.bump == "none" else next_version.tag.removeprefix("v"),
        "commit_count": str(analysis.commit_count),
        "unknown_count": str(analysis.unknown_count),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository", type=Path, default=Path.cwd())
    parser.add_argument("--head", default="HEAD")
    arguments = parser.parse_args()
    for key, value in calculate(arguments.repository.resolve(), arguments.head).items():
        print(f"{key}={value}")


if __name__ == "__main__":
    main()
