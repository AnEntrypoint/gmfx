from __future__ import annotations

import hashlib
import json
import os
import pathlib
import re
import subprocess
import tempfile
import textwrap
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
RELEASE_WORKFLOW_PATH = REPO_ROOT / ".github" / "workflows" / "release.yml"
PUBLISH_LIBFX_WORKFLOW_PATH = (
    REPO_ROOT / ".github" / "workflows" / "publish-libfx.yml"
)
PGSO_WORKFLOW_PATH = (
    REPO_ROOT / ".github" / "workflows" / "pgso-macos-arm64.yml"
)
PGSO_LINUX_WORKFLOW_PATH = (
    REPO_ROOT / ".github" / "workflows" / "pgso-linux-arm64.yml"
)
PGSO_LINUX_X86_64_WORKFLOW_PATH = (
    REPO_ROOT / ".github" / "workflows" / "pgso-linux-x86_64.yml"
)
DEV_RELEASE_WORKFLOW_PATH = REPO_ROOT / ".github" / "workflows" / "dev-release.yml"
PGSO_SETUP_ACTION_PATH = REPO_ROOT / ".github" / "actions" / "setup-pgso" / "action.yml"


class MacosSigningWorkflowTests(unittest.TestCase):
    def test_validation_builds_existing_versions_without_publishing(self) -> None:
        release = RELEASE_WORKFLOW_PATH.read_text(encoding="utf-8")
        check_job = release.split("  check-version:\n", 1)[1].split(
            "\n  build-linux-aarch64:", 1
        )[0]
        check_script = textwrap.dedent(check_job.split("        run: |\n", 1)[1])
        for validate, tag_exists, expected_needed, expected_publish in (
            ("true", True, "true", "false"),
            ("true", False, "true", "false"),
            ("false", True, "false", "false"),
            ("false", False, "true", "true"),
        ):
            with self.subTest(validate=validate, tag_exists=tag_exists):
                with tempfile.TemporaryDirectory(prefix="fx-release-check-") as tmp:
                    root = pathlib.Path(tmp)
                    (root / "src").mkdir()
                    (root / "src/main.zig").write_text(
                        'pub const version = "0.0.8";\n'
                    )
                    git = root / "git"
                    git.write_text(f"#!/bin/sh\nexit {0 if tag_exists else 1}\n")
                    git.chmod(0o755)
                    output = root / "outputs"
                    env = dict(
                        os.environ,
                        PATH=f"{root}:{os.environ['PATH']}",
                        GITHUB_OUTPUT=str(output),
                        VALIDATE_ONLY=validate,
                    )
                    result = subprocess.run(
                        ["bash", "-euo", "pipefail", "-c", check_script],
                        cwd=root, env=env, capture_output=True, text=True,
                    )
                    self.assertEqual(0, result.returncode, result.stderr)
                    self.assertIn(f"needed={expected_needed}\n", output.read_text())
                    self.assertIn(f"publish={expected_publish}\n", output.read_text())
                    self.assertIn("version=v0.0.8\n", output.read_text())

    def test_every_privileged_publish_job_uses_an_environment_gate(self) -> None:
        release = RELEASE_WORKFLOW_PATH.read_text(encoding="utf-8")
        publish_libfx = PUBLISH_LIBFX_WORKFLOW_PATH.read_text(encoding="utf-8")

        release_job = release.split("  release:\n", 1)[1]
        npm_publish_job = publish_libfx.split("  publish:\n", 1)[1]

        self.assertIn("environment: release", release_job)
        self.assertIn("environment: npm", npm_publish_job)

    def test_macos_binaries_are_signed_ad_hoc_without_apple_credentials(self) -> None:
        release = RELEASE_WORKFLOW_PATH.read_text(encoding="utf-8")
        intel_job = release.split("  build-macos-x86_64:\n", 1)[1].split(
            "\n  build-macos-arm64:\n", 1
        )[0]
        sign_release = release.split("  sign-macos-arm64:\n", 1)[1].split(
            "\n  release:\n", 1
        )[0]

        self.assertIn("runs-on: macos-15-intel", intel_job)
        self.assertIn("needs: [check-version, build-macos-arm64]", sign_release)
        self.assertIn(
            "needs: [check-version, package-linux, build-macos-x86_64, sign-macos-arm64]",
            release,
        )
        for name, job in (("intel", intel_job), ("arm64", sign_release)):
            with self.subTest(job=name):
                sign = job.index("codesign --force -s -")
                verify = job.index("codesign --verify --strict")
                self.assertLess(sign, verify)
                self.assertNotIn("--check-notarization", job)
        report = sign_release.index("python3 -m scripts.pgso report")
        sign = sign_release.index("codesign --force -s -")
        package = sign_release.index("tar -czf")
        self.assertLess(report, sign)
        self.assertLess(sign, package)

        for path in sorted((REPO_ROOT / ".github").rglob("*.yml")):
            with self.subTest(path=path.name):
                text = path.read_text(encoding="utf-8")
                self.assertNotIn("APPLE_", text)
                self.assertNotIn("apple-signing", text)
                self.assertNotIn("notariz", text.lower())
                self.assertNotIn("sign-and-notarize", text)

        self.assertFalse((REPO_ROOT / "scripts" / "sign-and-notarize-macos.sh").exists())

    def test_pgso_release_chain_pins_every_external_action(self) -> None:
        mutable_references: list[str] = []
        pending = [RELEASE_WORKFLOW_PATH]
        checked: set[pathlib.Path] = set()
        while pending:
            path = pending.pop()
            if path in checked:
                continue
            checked.add(path)
            for line_number, line in enumerate(
                path.read_text(encoding="utf-8").splitlines(),
                start=1,
            ):
                local = re.search(r"uses:\s+\./(\S+)", line)
                if local:
                    target = REPO_ROOT / local.group(1)
                    pending.append(target if target.suffix == ".yml" else target / "action.yml")
                    continue
                match = re.search(r"uses:\s+([^\s@]+)@([^\s#]+)", line)
                if match and not re.fullmatch(r"[0-9a-f]{40}", match.group(2)):
                    mutable_references.append(
                        f"{path.relative_to(REPO_ROOT)}:{line_number}: {line.strip()}"
                    )

        for path in (
            PGSO_WORKFLOW_PATH,
            PGSO_LINUX_WORKFLOW_PATH,
            PGSO_LINUX_X86_64_WORKFLOW_PATH,
            PGSO_SETUP_ACTION_PATH,
        ):
            self.assertIn(path, checked)
        self.assertEqual([], mutable_references)


class LinuxReleaseWorkflowTests(unittest.TestCase):
    def release_job(self, name: str) -> str:
        release = RELEASE_WORKFLOW_PATH.read_text(encoding="utf-8")
        return re.split(
            r"\n  (?=\S)", release.split(f"\n  {name}:\n", 1)[1], maxsplit=1
        )[0]

    def test_release_ships_the_qualified_pgso_candidate_for_each_linux_target(self) -> None:
        release = RELEASE_WORKFLOW_PATH.read_text(encoding="utf-8")
        self.assertNotIn("\n  build-linux:\n", release)
        self.assertNotIn("zig build -Doptimize=ReleaseSafe -Dtarget=${{ matrix.target }}", release)

        for job, workflow_path in (
            ("build-linux-aarch64", PGSO_LINUX_WORKFLOW_PATH),
            ("build-linux-x86_64", PGSO_LINUX_X86_64_WORKFLOW_PATH),
        ):
            with self.subTest(job=job):
                caller = self.release_job(job)
                self.assertIn(f"uses: ./.github/workflows/{workflow_path.name}", caller)
                self.assertIn("evidence-retention-days: 90", caller)
                self.assertNotIn("secrets:", caller)
                workflow = workflow_path.read_text(encoding="utf-8")
                triggers = workflow.split("\njobs:\n", 1)[0]
                self.assertIn("  workflow_call:\n", triggers)
                self.assertIn("value: ${{ jobs.candidate.outputs.artifact-id }}", triggers)
                self.assertIn("artifact-id: ${{ steps.upload.outputs.artifact-id }}", workflow)
                self.assertIn(
                    "retention-days: ${{ inputs.evidence-retention-days || 14 }}", workflow
                )

        package = self.release_job("package-linux")
        self.assertIn("needs: [check-version, build-linux-aarch64, build-linux-x86_64]", package)
        self.assertIn("runs-on: ${{ matrix.runner }}", package)
        for name, runner, arch, build in (
            ("linux-aarch64", "ubuntu-24.04-arm", "aarch64", "build-linux-aarch64"),
            ("linux-x86_64", "ubuntu-24.04", "x86_64", "build-linux-x86_64"),
        ):
            with self.subTest(name=name):
                self.assertIn(
                    f"          - name: {name}\n"
                    f"            runner: {runner}\n"
                    f"            arch: {arch}\n"
                    f"            artifact-id: ${{{{ needs.{build}.outputs.artifact-id }}}}\n",
                    package,
                )
        self.assertIn('test "$(uname -m)" = "$ARCH"', package)
        self.assertIn("artifact-ids: ${{ matrix.artifact-id }}", package)
        self.assertNotIn("environment:", package)
        report = package.index("python3 -m scripts.pgso report")
        digest = package.index("- name: Confirm the candidate is the qualified binary")
        smoke = package.index('candidate/fx" --version')
        archive = package.index("tar -czf")
        self.assertLess(report, digest)
        self.assertLess(digest, smoke)
        self.assertLess(smoke, archive)
        self.assertIn("ARCHIVE: fx-${{ matrix.name }}.tar.gz", package)
        self.assertIn("          name: fx-${{ matrix.name }}\n", package)

    def test_release_rejects_a_candidate_that_is_not_the_qualified_binary(self) -> None:
        package = self.release_job("package-linux")
        step = package.split(
            "      - name: Confirm the candidate is the qualified binary\n", 1
        )[1].split("\n      - name:", 1)[0]
        script = textwrap.dedent(step.split("        run: |\n", 1)[1])
        qualified = hashlib.sha256(b"qualified").hexdigest()
        for shipped, expected_exit in ((b"qualified", 0), (b"rebuilt", 1)):
            with self.subTest(shipped=shipped):
                with tempfile.TemporaryDirectory(prefix="fx-linux-release-") as tmp:
                    root = pathlib.Path(tmp)
                    candidate = root / "fx-pgso/candidate/fx"
                    candidate.parent.mkdir(parents=True)
                    candidate.write_bytes(shipped)
                    (root / "fx-pgso/manifest.json").write_text(
                        json.dumps(
                            {"evidence": {"artifacts": {"candidate": {"sha256": qualified}}}}
                        ),
                        encoding="utf-8",
                    )
                    result = subprocess.run(
                        ["bash", "-euo", "pipefail", "-c", script],
                        cwd=root,
                        env=dict(os.environ, RUNNER_TEMP=str(root)),
                        capture_output=True,
                        text=True,
                    )
                    self.assertEqual(expected_exit, result.returncode, result.stderr)
                    if expected_exit:
                        self.assertIn("is not the qualified", result.stderr)


if __name__ == "__main__":
    unittest.main()
