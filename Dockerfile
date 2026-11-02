# Project Maya, built FROM SOURCE (NVIDIA CUDA). The engine is compiled here and the
# Python application tree is kept in the runtime image, so the source hash in
# build/MAYA-BUILD.json still matches the tree Maya reads at start (setup.py's
# source_hash / refresh_engine).
#
#   docker build -t project-maya .                                   # RTX 20/30/40/50 + Volta
#   docker build -t project-maya --build-arg CUDA_ARCHITECTURES=86 .  # one card only (faster)
#   docker build -t project-maya --build-arg BUILD_TARGETS=maya --build-arg BUILD_VISION=0 .
#
#   docker run --rm --gpus all -p 127.0.0.1:8080:8080 --ulimit memlock=-1 --shm-size 2g \
#              --cap-add SYS_NICE --stop-timeout 120 -v maya-data:/data \
#              -e MODEL=Maya-S-v2-IQ2_XXS -e API_KEY=change-me-please-123 project-maya
#
# docker build has no GPU, so the CUDA architectures are given here instead of read from
# nvidia-smi. The engine is a fat binary with a machine-code part per listed architecture
# (plus PTX for the newest, which later cards can JIT), and the runtime picks the one
# matching your card. CUDA 13 cannot build for Pascal or Volta, so the default stays 12.8.
#
# The CPU expert kernel (src/kernels/cpu/expert.cpp) is always compiled with -mavx512*, so
# the image needs an AVX-512 CPU: the engine refuses to start on a CPU without it.
#
# Plain legacy-builder features only: no heredocs, no --mount, no chmod flag on COPY.

ARG CUDA_IMAGE=nvidia/cuda:12.8.1-devel-ubuntu24.04
ARG RUNTIME_BASE=nvidia/cuda:12.8.1-runtime-ubuntu24.04

# ---- 1. compile the engines ----
FROM ${CUDA_IMAGE} AS build

ARG CUDA_ARCHITECTURES=70;80;86;89;120
ARG BUILD_TARGETS=maya;maya-ds4;maya-mm3
ARG BUILD_VISION=1
ARG MAYA_COMMIT=

ENV DEBIAN_FRONTEND=noninteractive PYTHONUNBUFFERED=1
# git is not optional here: CMakeLists.txt applies third_party/ggml/mmq-fused-swiglu.patch
# through find_package(Git)
# the apt name is ninja-build; plain `ninja` does not exist in Ubuntu 24.04
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential ca-certificates git cmake ninja-build python3 python3-pip python3-venv \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY project-maya /src

# setup.py's PY_PACKAGES, read from the checkout itself so the two cannot drift apart
RUN python3 -m venv /venv \
    && /venv/bin/python -c "import setup; print('\n'.join(setup.PY_PACKAGES))" > /packages.txt \
    && /venv/bin/pip install --no-cache-dir -r /packages.txt

# llama.cpp at the pinned commit (ggml for the engine, gguf-py for the pack builder, mtmd
# for the vision encoder), exactly as setup.py fetches it
RUN /venv/bin/python -c "import setup; print(setup.get_llama_cpp())"

RUN set -e; \
    real=""; for a in $(echo "$CUDA_ARCHITECTURES" | tr ';,' '  '); do real="$real;${a}-real"; done; real=${real#;}; \
    last=$(echo "$CUDA_ARCHITECTURES" | tr ';,' '  ' | awk '{print $NF}'); \
    /venv/bin/cmake -G Ninja -S . -B build -DCMAKE_BUILD_TYPE=Release \
        -DSTRATA_ENABLE_CUDA=ON -DSTRATA_BUILD_TESTS=OFF -DSTRATA_PORTABLE=ON -DSTRATA_NATIVE_EXPERTS=ON \
        "-DCMAKE_CUDA_ARCHITECTURES=${real};${last}-virtual" \
        -DSTRATA_GGML_DIR=/src/third_party/llama.cpp -DMAYA_BUILD_ID="${MAYA_COMMIT}"; \
    for t in $(echo "$BUILD_TARGETS" | tr ';,' '  '); do \
        /venv/bin/cmake --build build --target "$t" -j "$(nproc)"; \
    done; \
    if [ "$BUILD_VISION" = "1" ]; then \
        /venv/bin/python tools/vision/glm5next_patch.py /src/third_party/llama.cpp; \
        /venv/bin/cmake -G Ninja -S tools/vision -B build-vision -DCMAKE_BUILD_TYPE=Release \
            -DLLAMA_DIR=/src/third_party/llama.cpp -DSTRATA_VISION_CUDA=ON -DSTRATA_PORTABLE=ON \
            "-DCMAKE_CUDA_ARCHITECTURES=${real};${last}-virtual"; \
        /venv/bin/cmake --build build-vision --target maya-vision -j "$(nproc)"; \
    fi

# what the runtime image keeps of llama.cpp: gguf-py (the pack builder reads it through
# tools/_paths.py) and the file setup.py looks for (ggml/CMakeLists.txt). The rest of the
# checkout is only needed to compile, and is left in the build stage.
RUN set -e; \
    mkdir -p /stage/build /stage/build-vision/bin /stage/llama/ggml; \
    for t in $(echo "$BUILD_TARGETS" | tr ';,' '  '); do \
        [ -f "build/$t" ] && cp "build/$t" /stage/build/ || true; \
    done; \
    [ -f build-vision/bin/maya-vision ] && cp build-vision/bin/maya-vision /stage/build-vision/bin/ || true; \
    cp -a /src/third_party/llama.cpp/gguf-py /stage/llama/; \
    cp /src/third_party/llama.cpp/ggml/CMakeLists.txt /stage/llama/ggml/; \
    cp /src/VERSION /stage/; \
    du -sh /stage

# ---- 2. the runtime image ----
FROM ${RUNTIME_BASE}

ARG MAYA_VERSION=dev
ARG MAYA_COMMIT=
ARG CUDA_ARCHITECTURES=70;80;86;89;120
ARG BUILD_TARGETS=maya;maya-ds4;maya-mm3
ARG BUILD_VISION=1
ARG USER_ID=1000
ARG GROUP_ID=1000

ENV DEBIAN_FRONTEND=noninteractive
# no libgomp (GGML_OPENMP is OFF), no libnuma (mbind is a raw syscall), no zlib: nothing in
# src/ links them. libatomic1 is what the static libgcc needs on x86-64.
RUN apt-get update && apt-get install -y --no-install-recommends \
        tini ca-certificates libatomic1 python3 python3-venv \
    && rm -rf /var/lib/apt/lists/*

# the application tree Maya runs from (the source subset is kept so setup.source_hash
# still matches the engine stamp), the venv, the compiled engines and the trimmed llama.cpp
COPY project-maya /opt/maya
COPY docker/entrypoint.sh docker/healthcheck.sh docker/prepare.py docker/write-stamp.py /opt/maya/docker/
COPY --from=build /venv /opt/maya/venv
COPY --from=build /stage/build /opt/maya/build
COPY --from=build /stage/build-vision /opt/maya/build-vision
COPY --from=build /stage/llama /opt/maya/third_party/llama.cpp
COPY --from=build /stage/VERSION /opt/maya/VERSION

# The scripts keep the executable bit from the checkout; this is the fallback for a
# checkout that lost it (a zip or a Windows share).
RUN chmod 0755 /opt/maya/docker/entrypoint.sh /opt/maya/docker/healthcheck.sh

# build/MAYA-BUILD.json over exactly the subset source_hash() reads, so a start finds the
# engine it expects and refresh_engine() has nothing to compile. The archs and targets come
# from the build args, not from a hardcoded list, so the stamp describes this image.
ENV MAYA_VISION=${BUILD_VISION}
# the assignment must be exported: write-stamp.py reads the environment, and a plain
# `VAR=x && cmd` in a RUN is a shell variable, not an environment variable
RUN cd /opt/maya \
    && export MAYA_ARCHS="$(echo "$CUDA_ARCHITECTURES" | tr ';,' '  ')" \
    && export MAYA_TARGETS="$(echo "$BUILD_TARGETS" | tr ';,' '  ')" \
    && python3 docker/write-stamp.py

# the base image already has a uid/gid 1000 (ubuntu), so the name may not be created.
# Ownership and USER are numeric, so the chosen uid works whichever name it maps to.
RUN set -e; \
    groupadd -g "$GROUP_ID" maya 2>/dev/null || true; \
    useradd -u "$USER_ID" -g "$GROUP_ID" -m -s /bin/sh maya 2>/dev/null || true; \
    mkdir -p /data/app /data/models /data/config /data/state /data/home; \
    chown -R "$USER_ID:$GROUP_ID" /opt/maya /data

USER ${USER_ID}:${GROUP_ID}
WORKDIR /opt/maya

ENV HOME=/data/home XDG_CONFIG_HOME=/data/config XDG_STATE_HOME=/data/state \
    MAYA_APP=/data/app MAYA_IMAGE_APP=/opt/maya PORT=8080 \
    LANG=C.UTF-8 PYTHONUNBUFFERED=1 PYTHONNOUSERSITE=1 MAYA_UPDATE_CHECK=0 \
    NVIDIA_VISIBLE_DEVICES=all NVIDIA_DRIVER_CAPABILITIES=compute,utility

VOLUME ["/data"]
EXPOSE 8080

LABEL org.opencontainers.image.title="Project Maya" \
      org.opencontainers.image.source="https://github.com/mw00/project-maya" \
      org.opencontainers.image.version="${MAYA_VERSION}" \
      org.opencontainers.image.revision="${MAYA_COMMIT}" \
      com.maya.backend="cuda" \
      com.maya.archs="${CUDA_ARCHITECTURES}" \
      com.maya.targets="${BUILD_TARGETS}"

# the first start can download and build a pack for hours, so a long start period
HEALTHCHECK --interval=30s --timeout=8s --start-period=2h --retries=3 \
    CMD ["/opt/maya/docker/healthcheck.sh"]

STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/bin/tini", "--", "/opt/maya/docker/entrypoint.sh"]
CMD ["run"]
