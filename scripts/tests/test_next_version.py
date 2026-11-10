import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "next_version.py"
SPEC = importlib.util.spec_from_file_location("next_version", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
next_version = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = next_version
SPEC.loader.exec_module(next_version)


class VersionTests(unittest.TestCase):
    def test_stable_tags_are_strict(self) -> None:
        self.assertEqual(next_version.Version.from_tag("v1.2.3"), next_version.Version(1, 2, 3))
        for invalid in ["1.2.3", "v1.2", "v01.2.3", "v1.2.3-beta.1"]:
            with self.assertRaises(ValueError):
                next_version.Version.from_tag(invalid)

    def test_pre_major_breaking_change_bumps_minor(self) -> None:
        self.assertEqual(next_version.Version(0, 4, 7).bump("major").tag, "v0.5.0")
        self.assertEqual(next_version.Version(1, 4, 7).bump("major").tag, "v2.0.0")


class AnalysisTests(unittest.TestCase):
    def assert_bump(self, expected: str, *messages: str) -> None:
        self.assertEqual(next_version.analyze(messages).bump, expected)

    def test_each_supported_type(self) -> None:
        self.assert_bump("minor", "feat: add menu")
        self.assert_bump("minor", "feat(menu): add control")
        self.assert_bump("patch", "fix: restore panel")
        self.assert_bump("patch", "perf: reduce polling")
        self.assert_bump("none", "docs: explain recovery", "chore: update tooling")

    def test_highest_bump_wins(self) -> None:
        self.assert_bump("minor", "fix: one", "feat: two", "perf: three")
        self.assert_bump("major", "feat: one", "fix!: change protocol")

    def test_breaking_footer_is_detected(self) -> None:
        self.assert_bump("major", "fix: adjust protocol\n\nBREAKING CHANGE: frames are incompatible")
        self.assert_bump("major", "chore: reorganize\n\nBREAKING-CHANGE: paths changed")

    def test_unknown_commits_do_not_affect_the_bump(self) -> None:
        analysis = next_version.analyze(["Merge pull request #1", "something informal", "fix: real bug"])
        self.assertEqual(analysis.bump, "patch")
        self.assertEqual(analysis.commit_count, 3)
        self.assertEqual(analysis.unknown_count, 2)


class RepositoryTests(unittest.TestCase):
    def run_git(self, repository: Path, *arguments: str) -> str:
        # The scratch repository mustn't inherit the developer's signing setup.
        return subprocess.run(
            ["git", "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false", *arguments],
            cwd=repository, check=True, text=True, stdout=subprocess.PIPE,
        ).stdout.strip()

    def commit(self, repository: Path, message: str) -> None:
        self.run_git(repository, "commit", "--allow-empty", "-m", message)

    def test_calculates_from_highest_reachable_stable_tag(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repository = Path(directory)
            self.run_git(repository, "init", "-q")
            self.run_git(repository, "config", "user.name", "Test")
            self.run_git(repository, "config", "user.email", "test@example.com")
            self.commit(repository, "Initial commit")
            self.run_git(repository, "tag", "v0.1.0")
            self.run_git(repository, "tag", "v0.0.9")
            self.run_git(repository, "tag", "v0.2.0-beta.1")
            self.commit(repository, "fix: repair startup")
            result = next_version.calculate(repository, "HEAD")
            self.assertEqual(result["current_tag"], "v0.1.0")
            self.assertEqual(result["bump"], "patch")
            self.assertEqual(result["next_tag"], "v0.1.1")


if __name__ == "__main__":
    unittest.main()
