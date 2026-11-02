#!/usr/bin/env python3
"""Static gate for the Docker deliverables.

Runs without Docker, without a GPU and without the checkout: it checks the shell scripts
parse, that the Dockerfile stays inside legacy-builder features, that the runtime contract
matches what README.md documents, that docker-compose.yaml carries the settings the README
explains, that every .env.example variable is read by something, and that build.sh --ctx-only
produces the context the README describes.

    python3 -m unittest tests/test_docker.py -v
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DOCKER_DIR = ROOT / "docker"
README = (ROOT / "README.md").read_text(encoding="utf-8")
DOCKERFILE = (ROOT / "Dockerfile").read_text(encoding="utf-8")
COMPOSE_TEXT = (ROOT / "docker-compose.yaml").read_text(encoding="utf-8")
ENV_EXAMPLE = (ROOT / ".env.example").read_text(encoding="utf-8")
BUILD_SH = (ROOT / "build.sh").read_text(encoding="utf-8")
DOCKER_IGNORE = (ROOT / ".dockerignore").read_text(encoding="utf-8")

SHELL_SCRIPTS = [DOCKER_DIR / "entrypoint.sh", DOCKER_DIR / "healthcheck.sh", ROOT / "build.sh"]
PYTHON_SCRIPTS = [DOCKER_DIR / "prepare.py", DOCKER_DIR / "write-stamp.py"]

# what README.md says the runtime contract is; the Dockerfile must say the same thing
EXPECTED_ENTRYPOINT = ['"/usr/bin/tini"', '"--"', '"/opt/maya/docker/entrypoint.sh"']
EXPECTED_HEALTHCHECK = {"interval": "30s", "timeout": "8s", "start-period": "2h", "retries": "3"}
EXPECTED_EXPOSE = "8080"
EXPECTED_VOLUME = "/data"


def env_names(text: str) -> set[str]:
    """Variable names a file reads: ${VAR} in shell, env("VAR") in Python, ${VAR} in compose."""
    found = set(re.findall(r"\$\{?([A-Z][A-Z0-9_]*)", text))
    found |= set(re.findall(r'env\("([A-Z][A-Z0-9_]+)"', text))
    return found


def env_example_vars() -> dict[str, str]:
    vars_ = {}
    for line in ENV_EXAMPLE.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        name, _, value = line.partition("=")
        vars_[name.strip()] = value.strip()
    return vars_


def compose_service() -> dict:
    import yaml

    doc = yaml.safe_load(COMPOSE_TEXT)
    return doc["services"]["maya"]


class ShellTests(unittest.TestCase):
    def test_shell_scripts_parse(self) -> None:
        for path in SHELL_SCRIPTS:
            self.assertTrue(path.is_file(), f"{path.name} is missing")
            subprocess.run(["sh", "-n", str(path)], check=True)

    def test_scripts_are_lf_only(self) -> None:
        for path in SHELL_SCRIPTS + PYTHON_SCRIPTS:
            self.assertNotIn(b"\r", path.read_bytes(), f"{path.name} has CRLF line endings")

    def test_scripts_are_executable_and_shebang(self) -> None:
        for path in SHELL_SCRIPTS + PYTHON_SCRIPTS:
            self.assertTrue(os.access(path, os.X_OK), f"{path.name} is not executable")
            first = path.read_text(encoding="utf-8").splitlines()[0]
            self.assertTrue(first.startswith("#!"), f"{path.name} has no shebang")

    def test_build_sh_is_posix_safe(self) -> None:
        self.assertIn("set -eu", BUILD_SH)
        # --gpus must not be quoted: the daemon rejects a quoted value
        for line in BUILD_SH.splitlines():
            if "--gpus" in line and not line.lstrip().startswith("#"):
                self.assertNotIn('"--gpus', line, f"quoted --gpus in build.sh: {line}")
                self.assertNotIn("'--gpus", line, f"quoted --gpus in build.sh: {line}")

    def test_build_sh_never_pushes(self) -> None:
        self.assertNotIn("docker push", BUILD_SH)
        self.assertIn("Nothing is pushed", README)

    def test_build_sh_does_not_pass_env_file_to_docker_build(self) -> None:
        # `docker build` has no --env-file, only `docker run` does. The file is read by
        # build.sh and only the ARGs the Dockerfile declares are passed.
        build_line = [line for line in BUILD_SH.splitlines() if line.startswith("docker build")]
        self.assertTrue(build_line, "build.sh does not call docker build")
        for line in build_line:
            self.assertNotIn("--env-file", line, f"docker build cannot take --env-file: {line}")
        declared = set(re.findall(r"^ARG (\w+)", DOCKERFILE, re.M))
        passed = set(re.findall(r'--build-arg "(\w+)=', BUILD_SH))
        self.assertTrue(passed <= declared, f"build.sh passes undeclared ARGs: {sorted(passed - declared)}")

    def test_build_sh_default_commit_is_the_pinned_one(self) -> None:
        self.assertIn("26aacb6bcea9333e4f408a68ee60c4c1c316bd68", BUILD_SH)
        self.assertIn("26aacb6", README)
        self.assertIn("github.com/mw00/project-maya/", BUILD_SH)

    def test_tag_and_readme_agree(self) -> None:
        # the tag's CUDA part comes from the base image, so a CUDA 13 base is not tagged
        # cuda12; compose's default must be what build.sh produces with its default base
        self.assertIn("project-maya:<version>-cuda<major>", README)
        self.assertIn("project-maya:$version-cuda$cuda_major", BUILD_SH)
        self.assertIn("project-maya:1.1.49-cuda12", COMPOSE_TEXT)
        self.assertIn("project-maya:1.1.49-cuda12", ENV_EXAMPLE)


class DockerfileTests(unittest.TestCase):
    def test_legacy_builder_only(self) -> None:
        # the Dockerfile is read line by line so a comment cannot trip a feature check
        for line in DOCKERFILE.splitlines():
            if line.lstrip().startswith("#"):
                continue
            self.assertIsNone(re.search(r"<<\s*-?['\"]?\w+", line), f"heredoc in Dockerfile: {line}")
            self.assertNotIn("--mount=", line, f"BuildKit mount in Dockerfile: {line}")
            self.assertIsNone(re.search(r"COPY\s+--chmod", line), f"COPY --chmod in Dockerfile: {line}")

    def test_two_stages(self) -> None:
        self.assertEqual(len(re.findall(r"^[A-Za-z]*FROM ", DOCKERFILE, re.M)), 2)
        self.assertIn("AS build", DOCKERFILE)

    def test_runtime_contract(self) -> None:
        self.assertIn('STOPSIGNAL SIGTERM', DOCKERFILE)
        self.assertIn(f'VOLUME ["{EXPECTED_VOLUME}"]', DOCKERFILE)
        self.assertIn(f"EXPOSE {EXPECTED_EXPOSE}", DOCKERFILE)
        entry = re.search(r"^ENTRYPOINT \[.*\]$", DOCKERFILE, re.M)
        self.assertIsNotNone(entry, "no ENTRYPOINT")
        for part in EXPECTED_ENTRYPOINT:
            self.assertIn(part, entry.group(0))
        health = re.search(r"^HEALTHCHECK[^\n]*(?:\\\n[^\n]*)*", DOCKERFILE, re.M)
        self.assertIsNotNone(health, "no HEALTHCHECK")
        for key, value in EXPECTED_HEALTHCHECK.items():
            self.assertIn(f"--{key}={value}", health.group(0))
        # numeric, because the base image already owns uid 1000 under another name
        self.assertIn("USER ${USER_ID}:${GROUP_ID}", DOCKERFILE)
        self.assertIn('chown -R "$USER_ID:$GROUP_ID"', DOCKERFILE)

    def test_healthcheck_and_entrypoint_files_exist(self) -> None:
        for name in ("entrypoint.sh", "healthcheck.sh", "prepare.py", "write-stamp.py"):
            self.assertTrue((DOCKER_DIR / name).is_file(), f"docker/{name} is missing")
            self.assertIn(f"docker/{name}", DOCKERFILE, f"docker/{name} is not copied into the image")

    def test_stamp_uses_the_build_args_not_hardcoded_defaults(self) -> None:
        run = re.search(r"RUN cd /opt/maya.*write-stamp\.py", DOCKERFILE, re.S)
        self.assertIsNotNone(run, "write-stamp.py is not run in the runtime stage")
        self.assertIn("CUDA_ARCHITECTURES", run.group(0), "the stamp's archs are not from the ARG")
        self.assertIn("BUILD_TARGETS", run.group(0), "the stamp's targets are not from the ARG")

    def test_runtime_base_has_the_cuda_math_libraries(self) -> None:
        # cublas is a DT_NEEDED of the engine, and only the runtime flavour carries it
        self.assertIn("nvidia/cuda:12.8.1-runtime-ubuntu24.04", DOCKERFILE)
        self.assertIn("nvidia/cuda:12.8.1-devel-ubuntu24.04", DOCKERFILE)

    def test_git_is_in_the_build_stage_for_the_patch(self) -> None:
        build_stage = DOCKERFILE.split("AS build")[1].split("FROM ${RUNTIME_BASE}")[0]
        self.assertIn("git", build_stage)
        patch = ROOT / "project-maya" / "third_party" / "ggml" / "mmq-fused-swiglu.patch"
        if patch.is_file():
            self.assertIn("mmq-fused-swiglu.patch", DOCKERFILE.split("AS build")[1])

    def test_runtime_apt_list_matches_what_the_engine_needs(self) -> None:
        runtime = DOCKERFILE.split("FROM ${RUNTIME_BASE}")[1]
        install = " ".join(line for line in runtime.splitlines() if "apt-get install" in line or line.strip().startswith("tini "))
        self.assertTrue(install, "the runtime stage installs nothing")
        for package in ("tini", "ca-certificates", "libatomic1", "python3", "python3-venv"):
            self.assertIn(package, install)
        # nothing in src/ links them, so they must not be installed
        for package in ("libgomp", "libnuma", "zlib", "curl", "openssl"):
            self.assertNotIn(package, install, f"{package} is not needed by the engine")

    def test_readme_and_dockerfile_agree_on_the_base_images(self) -> None:
        self.assertIn("12.8.1", README)
        self.assertIn("nvidia/cuda:12.8.1", DOCKERFILE)
        self.assertIn("runtime-ubuntu24.04", DOCKERFILE, "the runtime stage must use the runtime flavour")
        self.assertIn("CUDA 13 cannot build for Pascal or Volta", README)
        self.assertIn("AVX-512", README)

    def test_dockerignore_excludes_the_reference_and_the_host_files(self) -> None:
        for pattern in ("Strata/", ".git/", "tests/", "bench/", "ref/", "docs/"):
            self.assertIn(pattern, DOCKER_IGNORE)
        # the checkout's C++ test sources must stay: CMake generation needs them
        self.assertNotIn("project-maya/tests/", DOCKER_IGNORE)
        # the shipped expert profiles are the one part of data/ the engine reads
        self.assertIn("data/expert-profile-*.bin", DOCKER_IGNORE)


class ComposeTests(unittest.TestCase):
    def test_compose_parses_and_matches_the_readme(self) -> None:
        svc = compose_service()
        self.assertIn("docker compose up -d", README)
        self.assertEqual(svc["container_name"], "maya")
        self.assertEqual(svc["restart"], "unless-stopped")
        self.assertEqual(svc["env_file"], ".env")
        self.assertIn("project-maya:", svc["image"])

    def test_documented_settings_are_present(self) -> None:
        svc = compose_service()
        for claim in ("memlock", "SYS_NICE", "shm_size", "stop_grace_period", "nvidia"):
            self.assertIn(claim, README, f"README does not document {claim}")
        ulimits = svc["ulimits"]["memlock"]
        self.assertEqual(ulimits["soft"], -1)
        self.assertEqual(ulimits["hard"], -1)
        self.assertIn("SYS_NICE", svc["cap_add"])
        self.assertEqual(svc["shm_size"], "2gb")
        self.assertEqual(svc["stop_grace_period"], "2m")
        device = svc["deploy"]["resources"]["reservations"]["devices"][0]
        self.assertEqual(device["driver"], "nvidia")
        self.assertIn("gpu", device["capabilities"])

    def test_port_and_volume_are_the_documented_ones(self) -> None:
        svc = compose_service()
        self.assertIn(f":{EXPECTED_EXPOSE}", svc["ports"][0])
        self.assertIn("127.0.0.1", svc["ports"][0])
        self.assertIn("maya-data:/data", svc["volumes"][0])
        self.assertIn("maya-data", compose_service_volumes())

    def test_compose_reads_only_documented_variables(self) -> None:
        used = env_names(COMPOSE_TEXT)
        documented = set(env_example_vars())
        self.assertTrue(used <= documented, f"compose uses undocumented variables: {sorted(used - documented)}")


def compose_service_volumes() -> dict:
    import yaml

    return yaml.safe_load(COMPOSE_TEXT)["volumes"]


def source_hash(root: Path, parts: tuple[str, ...], commit: str) -> str:
    """setup.source_hash(), recomputed over a folder so the context can be compared to
    the checkout it came from."""
    import hashlib

    h = hashlib.sha256(commit.encode())
    for part in parts:
        base = root / part
        files = [base] if base.is_file() else sorted(x for x in base.rglob("*") if x.is_file())
        for f in files:
            h.update(f.relative_to(root).as_posix().encode() + b"\0" + f.read_bytes().replace(b"\r\n", b"\n"))
    return h.hexdigest()[:16]


ENGINE_PARTS = ("CMakeLists.txt", "cmake", "src", "include", "third_party/ggml")


def llama_commit() -> str:
    if (ROOT / "project-maya" / "setup.py").is_file():
        sys.path.insert(0, str(ROOT / "project-maya"))
        import setup

        return setup.LLAMA_CPP_COMMIT
    return "3cf03257f219afbe7334045ff7c6a06ac68c627d"


def checkout_hash() -> str:
    return source_hash(ROOT / "project-maya", ENGINE_PARTS, llama_commit())


def context_hash(app: Path) -> str:
    return source_hash(app, ENGINE_PARTS, llama_commit())


class EnvTests(unittest.TestCase):
    def test_every_env_example_variable_is_read(self) -> None:
        readers = env_names((DOCKER_DIR / "entrypoint.sh").read_text(encoding="utf-8"))
        readers |= env_names((DOCKER_DIR / "prepare.py").read_text(encoding="utf-8"))
        readers |= env_names(COMPOSE_TEXT)
        maya_py = ROOT / "project-maya" / "maya.py"
        if maya_py.is_file():
            readers |= env_names(maya_py.read_text(encoding="utf-8"))
        documented = set(env_example_vars())
        self.assertTrue(documented, ".env.example has no variables")
        orphan = sorted(documented - readers)
        self.assertFalse(orphan, f".env.example variables nothing reads: {orphan}")

    def test_readme_documents_the_variables_it_lists(self) -> None:
        table = set(re.findall(r"^\| `([A-Z][A-Z0-9_]*)` \|", README, re.M))
        documented = set(env_example_vars())
        self.assertTrue(table <= documented, f"README table names not in .env.example: {sorted(table - documented)}")

    def test_readme_table_is_within_markdownlint_limit(self) -> None:
        for line in README.splitlines():
            if line.startswith("|") and len(line) > 80:
                self.fail(f"README table row longer than 80: {line}")

    def test_fenced_blocks_have_a_language(self) -> None:
        for line in README.splitlines():
            if line.startswith("```") and line != "```" and len(line) > 3:
                self.assertTrue(re.fullmatch(r"```[a-z]+", line), f"fence without a language: {line}")


class ContextTests(unittest.TestCase):
    def test_ctx_only_keeps_the_documented_subset(self) -> None:
        if not shutil.which("bash"):
            self.skipTest("bash is needed to run build.sh")
        ctx = tempfile.mkdtemp(prefix="maya-ctx-")
        try:
            subprocess.run(
                ["bash", str(ROOT / "build.sh"), "--ctx-only", "--ctx", ctx],
                check=True, capture_output=True, text=True,
            )
            names = {p.relative_to(ctx).as_posix().split("/")[0] for p in Path(ctx).iterdir()}
            self.assertIn("Dockerfile", names)
            self.assertIn(".dockerignore", names)
            self.assertIn("docker", names)
            self.assertIn("project-maya", names)
            for forbidden in ("Strata", ".git"):
                self.assertNotIn(forbidden, names, f"context contains {forbidden}")
            # this repo's own tests folder is host-side; the checkout's is not, because
            # CMakeLists.txt adds tests/ targets outside STRATA_BUILD_TESTS
            self.assertNotIn("tests", names, "context contains this repo's tests folder")
            app = Path(ctx) / "project-maya"
            for keep in ("maya.py", "setup.py", "serve", "src", "tools", "third_party/wheels", "tests"):
                self.assertTrue((app / keep).exists(), f"context lost {keep}")
            for drop in ("docs", "bench", "ref", "third_party/llama.cpp"):
                self.assertFalse((app / drop).exists(), f"context kept {drop}")
            profiles = list((app / "data").glob("expert-profile-*.bin"))
            self.assertTrue(profiles, "context lost the shipped expert profiles")
            self.assertEqual(context_hash(app), checkout_hash(),
                             "the context's ENGINE_SOURCES subset no longer hashes the "
                             "same as the checkout, so build/MAYA-BUILD.json would not "
                             "match the tree Maya reads at start")
            # build.sh normalises line endings for the files it owns; the checkout's own
            # Windows batch files legitimately keep CRLF
            for path in list(Path(ctx).rglob("docker/*")) + [Path(ctx) / "Dockerfile", Path(ctx) / ".dockerignore"]:
                if path.is_file():
                    self.assertNotIn(b"\r", path.read_bytes(), f"CRLF in the context: {path}")
                    if path.suffix == ".sh":
                        self.assertTrue(os.access(path, os.X_OK), f"shell script lost the executable bit: {path}")
        finally:
            shutil.rmtree(ctx, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
