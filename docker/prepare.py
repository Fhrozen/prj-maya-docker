#!/usr/bin/env python3
"""Prepare a Project Maya container: the model, the pack and the config, without a CUDA
toolkit.

The runtime image has no nvcc, so maya.py's `check_pc()` refuses (it is the step that
looks for the toolkit). Everything else of the setup is reused as it is: this file builds
the same argparse Namespace maya.py's own parser would have built from the container's
environment, builds the `pc` dict from the GPUs the container sees, and then calls
maya.py's own step functions - choose_context, choose_model, choose_draft, tools_step,
build_step, model_step, drafter_step, pack_step, vision_step, write_config. No step is
reimplemented here.

Run it from the entry point (or by hand):

    python3 docker/prepare.py            # reads the environment below
    python3 docker/prepare.py --help

Settings (the same names the entry point and .env.example use):
    MODEL        a GLM-5.3-Flash quant (Maya-S-v2-IQ2_XXS, Maya-S24, ...); empty: the one
                 maya.py recommends for this card
    MODEL_PATH   model files you already have, as seen inside the container (a folder or
                 the first .gguf); must be writable - the pack is written inside it
    CONTEXT      context length in tokens (default maya.py's)
    PARALLEL     requests answered at the same time, 1-8
    VISION       on (default) or off
    DRAFT        mtp (default) or dflash2
    DOWNLOAD     1 (default): download what is missing; 0: stop instead of downloading
    GPUS         card numbers, e.g. 0 or 0,1
    MODELS_DIR   where downloads go (default /data/models)
    PORT, HOST, API_KEY   the server's settings, kept in the config
    MAYA_ENV     engine settings to write into the config, space separated KEY=VALUE

Only the GLM family is prepared here: DeepSeek, MiniMax and Qwen setups call check_pc(),
which needs the CUDA toolkit, so they must be set up on a machine that has it.
"""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
APP = HERE.parent
sys.path.insert(0, str(APP))
sys.path.insert(0, str(APP / "tools"))

import setup as S  # noqa: E402  (importing it runs nothing)
import maya as M  # noqa: E402
import maya_names as N  # noqa: E402


def env(name: str, default: str = "") -> str:
    return (os.environ.get(name) or default).strip()


def namespace() -> argparse.Namespace:
    """The argparse Namespace maya.py's parser would have built, from the environment.
    The defaults come from maya.py's own constants, so they cannot drift from it."""
    a = argparse.Namespace()
    a.backend = "cuda"
    a.setup = True
    a.check = False
    a.no_start = True
    a.yes = True
    a.plain = True
    a.copy = False
    a.download_model = env("DOWNLOAD", "1") == "1"
    a.model = env("MODEL")
    a.model_dir = env("MODEL_PATH") or None
    a.ds4_quant = None
    a.mm3_quant = None
    a.draft = env("DRAFT") or None
    a.no_vision = env("VISION", "on").lower() in ("off", "0", "no", "none")
    a.gguf_dir = None
    a.models_dir = env("MODELS_DIR") or str(Path("/data/models"))
    a.gpu = None
    a.gpus = env("GPUS") or None
    a.context = int(env("CONTEXT")) if env("CONTEXT").isdigit() else None
    a.parallel = int(env("PARALLEL")) if env("PARALLEL").isdigit() else None
    a.vram_reserve_mib = int(env("VRESERVE")) if env("VRESERVE").isdigit() else None
    a.mmap_experts = None
    a.port = int(env("PORT", "8080"))
    a.host = env("HOST") or None
    a.api_key = env("API_KEY") or None
    a.env = [p for p in env("MAYA_ENV").split() if "=" in p]
    a.nvcc = None
    a.host_compiler = None
    a.llama_dir = None
    a.rebuild = False
    a.repack = env("REPACK") == "1"
    a.report = False
    a.bench = False
    a.calibrate = False
    a.speed_calibration = False
    a.drafting = None
    a.no_speed_calibration = False
    a.config = None
    return a


def pc_dict(a: argparse.Namespace, family: str) -> dict:
    """The `pc` dict check_pc() would have built, without the toolkit and driver checks
    the runtime image cannot make. The GPUs are the ones the container sees."""
    found = S.gpus() or []
    gpus = M.choose_gpus(a, found, M.MIN_CC, family) if found else []
    archs = sorted({int(g["arch"]) for g in gpus}) if gpus else \
        [int(x) for x in (os.environ.get("MAYA_ARCHS") or "").split() if x.isdigit()]
    return {"backend": "cuda", "gpus": gpus, "archs": archs, "nvcc": None,
            "gated": False, "text_only": True}


def main() -> int:
    if "-h" in sys.argv[1:] or "--help" in sys.argv[1:]:
        print(__doc__)
        return 0

    N.alias_env(os.environ)
    a = namespace()
    if a.model:
        why = M.model_option(a)
        if why:
            print(f"[X] {why}", file=sys.stderr)
            return 1

    prev = M.read_json(M.configs()[0]) if M.configs() else {}
    family = M.choose_family(a, prev)
    if family != "glm":
        print(f"[X] prepare.py prepares GLM-5.3-Flash only; {family} setups run "
              "check_pc(), which needs the CUDA toolkit. Set that model up on a machine "
              "with nvcc, or mount its config and pack into the container.", file=sys.stderr)
        return 1
    M.check_parallel(a, family)

    pc = pc_dict(a, family)
    inst = prev.get("installer") or {}
    prev_args = prev.get("args") or []
    prev_ctx = int(prev_args[prev_args.index("--max-context") + 1]) \
        if "--max-context" in prev_args[:-1] else None

    models = Path(a.models_dir).expanduser().resolve()
    models.mkdir(parents=True, exist_ok=True)

    ctx = M.choose_context(a, prev_ctx)
    choice = M.choose_model(a, models, inst)
    draft = M.choose_draft(a, pc, inst)
    llama = M.tools_step(a)
    meta = M.build_step(a, pc, llama)
    got = M.model_step(a, models, choice)
    if got is None:
        print("[X] the model files are not there and nothing was downloaded "
              "(DOWNLOAD=1 to allow it).", file=sys.stderr)
        return 1
    d, shards, quant = got
    dflash = M.drafter_step(models) if draft == "dflash2" else None
    pack = M.pack_step(a, d, shards, llama, quant)
    vision = M.vision_step(a, pc, meta, llama, d, quant)
    cfg_path = M.write_config(a, pc, meta, pack, quant, ctx, models, vision, choice, dflash,
                              shards[0] if pc.get("backend") == "metal" else None)
    print(f"prepared: {cfg_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
