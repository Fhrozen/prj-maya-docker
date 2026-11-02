#!/usr/bin/env python3
"""Write build/MAYA-BUILD.json in the runtime image.

The engine stamp is what maya.py's `refresh_engine()` compares against
`setup.source_hash(setup.ENGINE_SOURCES)`. The runtime stage keeps exactly the subset
that hash reads (CMakeLists.txt, cmake/, src/, include/, third_party/ggml/), so writing
the stamp over the same tree here makes a start find the engine it expects and never try
to compile it again.

Run at build time from the runtime stage:

    MAYA_ARCHS="70 80 86" MAYA_TARGETS="maya maya-ds4" python3 docker/write-stamp.py

`nvcc` is None and `lib_dirs` is empty on purpose: the runtime image has no CUDA toolkit,
and the engine links the CUDA runtime from the base image's library path. `gpu_ids` is
empty because the build had no GPU (the architectures came from a build arg).
"""
from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
APP = HERE.parent
sys.path.insert(0, str(APP))
sys.path.insert(0, str(APP / "tools"))

import setup  # noqa: E402  (importing it runs nothing)


def main() -> int:
    archs = [a for a in os.environ.get("MAYA_ARCHS", "").split() if a]
    targets = [t for t in os.environ.get("MAYA_TARGETS", "").split() if t]
    vision = os.environ.get("MAYA_VISION", "1") == "1"
    stamp = Path(APP) / "build" / "MAYA-BUILD.json"
    stamp.parent.mkdir(parents=True, exist_ok=True)
    meta = {
        "src": setup.source_hash(setup.ENGINE_SOURCES),
        "archs": archs,
        "gpu_ids": [],
        "nvcc": None,
        "host_compiler": None,
        "llama": str(APP / "third_party" / "llama.cpp"),
        "lib_dirs": [],
        "date": time.strftime("%Y-%m-%d %H:%M"),
        "targets": sorted(targets or ["maya"]),
        "backend": "cuda",
        "source": "docker build",
    }
    stamp.write_text(json.dumps(meta, indent=1), encoding="utf-8")
    if vision:
        vstamp = Path(APP) / "build-vision" / "MAYA-BUILD.json"
        vstamp.parent.mkdir(parents=True, exist_ok=True)
        vmeta = {"src": setup.source_hash(("tools/vision",)), "archs": archs,
                 "llama": str(APP / "third_party" / "llama.cpp"), "backend": "cuda",
                 "date": meta["date"]}
        vstamp.write_text(json.dumps(vmeta, indent=1), encoding="utf-8")
    print(f"{stamp}: src {meta['src']}, targets {meta['targets']}, archs {archs}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
