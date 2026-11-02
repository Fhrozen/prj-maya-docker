# prj-maya-docker

Docker support for [Project Maya](https://github.com/mw00/project-maya/): a
container that builds the engine from the checkout and runs the service.

Three deliverables, and nothing else is needed:

| File | What it does |
| --- | --- |
| `Dockerfile` | builds the engines, then the runtime image with the app tree |
| `build.sh` | gets the checkout, sets tag, user and env file, then builds |
| `docker-compose.yaml` | runs the service: port, volume, GPUs and the limits |

`docker/` holds the container scripts, and they are only called by those three:
`build.sh` copies them into the context, the `Dockerfile` puts them in the image,
compose runs the entry point. `tests/` is the one independent part, a static gate
that checks the shell, the Dockerfile and compose against what this README says.

## Quick start

```bash
cp .env.example .env            # edit MODEL and API_KEY
./build.sh                      # clones the checkout, builds the image
docker compose up -d
docker compose logs -f maya
curl -H "Authorization: Bearer $(grep ^API_KEY .env | cut -d= -f2)" \
  http://127.0.0.1:8080/health
```

The first start is slow: it downloads the model, builds the expert pack and then
loads it. That is normal, and the health check reports `preparing` while it
happens.

## build.sh

```text
./build.sh                                   # pinned commit, default tag
./build.sh --latest                          # origin/main instead
./build.sh --arch 86 --tag project-maya:rtx30
./build.sh --target maya --no-vision         # a smaller image
./build.sh --user 1000:1000 --env-file .env
./build.sh --ctx-only --ctx /tmp/maya-ctx    # assemble the context, stop there
```

- The checkout is cloned only when `project-maya/` is missing. Default commit
  [`26aacb6`](https://github.com/mw00/project-maya/commit/26aacb6bcea9333e4f408a68ee60c4c1c316bd68)
  (`26aacb6bcea9333e4f408a68ee60c4c1c316bd68`); `--commit` picks another,
  `--latest` moves to `origin/main`.
- The tag is `project-maya:<version>-cuda<major>`, with the version read from the
  checkout's `VERSION` file and the major from the base image (12 by default).
- Architectures are detected from `nvidia-smi` on the host, then from the
  container, then fall back to `70;80;86;89;120`. `docker build` has no GPU, so
  this is the only way the build knows its target.
- `.env` is created from `.env.example` when missing. `docker build` has no
  `--env-file`, so build.sh reads it and passes only the variables the Dockerfile
  declares as `ARG`.
- `MAYA_DOCKER_BUILD_OPTS` adds extra `docker build` options (e.g. `--network
  host`). It is appended after the build args and defaults to empty, so an unset
  variable does not stop the script.
- Nothing is pushed. The image stays in the local Docker.

## Running

`docker compose up -d` is the documented way. The parts of the service that are
not cosmetic:

- `ulimits memlock -1` — the expert pack is `mlock()`ed
  (`src/platform/memory.cpp`), and without the limit the engine refuses.
- `cap_add SYS_NICE` — the NUMA interleave is a raw `mbind` syscall, which
  Docker's default seccomp denies.
- `shm_size 2gb` — the engine shares buffers through `/dev/shm`.
- `stop_grace_period 2m` — a large model takes longer than 10s to release.
- `deploy.resources.reservations.devices` — the NVIDIA driver, with
  `NVIDIA_DRIVER_CAPABILITIES=compute,utility` set in the image for NVML.
- `volumes maya-data:/data` — the model, the pack, the config and the API key
  live here, so the container is disposable. `MAYA_DATA` makes it a bind-mounted
  host folder instead of a named volume.

`MAYA_USER` is empty by default, which keeps the image's user (1000:1000, the
`--user` build.sh was given). A new named volume takes the ownership the image
baked in, so running as a different uid cannot write `/data` on the first start:
chown the volume once, or use a bind mount, which keeps host ownership. A bind
mount folder owned by another uid is not writable by the container's user, and
the entry point says which folder, which uid and which owner are in the way.

## Settings

Only the variables in `.env.example` are read, by `docker/entrypoint.sh`,
`docker/prepare.py`, `maya.py` or compose itself. The ones that matter:

| Variable | Meaning |
| --- | --- |
| `MODEL` | a GLM quant; empty: what `maya.py` recommends for this card |
| `MODEL_PATH` | model files you already have, as seen inside the container |
| `CONTEXT` | context length in tokens (default 32768) |
| `PARALLEL` | concurrent requests, 1-8 (empty: the engine's choice) |
| `VISION` | on or off |
| `DRAFT` | `mtp` (default) or `dflash2` |
| `DOWNLOAD` | 1 downloads what is missing, 0 stops instead |
| `GPUS` | card numbers, e.g. `0` or `0,1` |
| `API_KEY` | the key clients send; kept in `/data/state/api-key` if unset |
| `HF_TOKEN` | read token for a gated repo |
| `MAYA_ENV` | advanced engine settings, space separated `KEY=VALUE` |

## Things to know before you build

- **AVX-512 is required.** `src/kernels/cpu/expert.cpp` is always compiled with
  `-mavx512*`, and `cpu_require_expert_support()` exits on a CPU without
  VNNI/VBMI. The entry point warns when `/proc/cpuinfo` has no `avx512f`.
- **CUDA 13 cannot build for Pascal or Volta**, so the default base is
  `nvidia/cuda:12.8.1` (sm_60 up to sm_120). Use a CUDA 13 base only for sm_75
  and newer.
- **The build needs the internet**: the base image, and llama.cpp at the pinned
  commit (`setup.get_llama_cpp()` / FetchContent). `git` is installed in the build
  stage because `CMakeLists.txt` applies `third_party/ggml/mmq-fused-swiglu.patch`
  through `find_package(Git)`.
- **Only the GLM family is prepared inside the container.** The DeepSeek, MiniMax
  and Qwen setups call `check_pc()`, which wants the CUDA toolkit; the runtime
  image has no `nvcc`, so those families must be set up on a machine that has it.
- **The pack must be written in a writable model folder.** A read-only
  `MODEL_PATH` mount makes the engine stop; the entry point warns about it.
- **Models are large** (93-340 GB) and some repos are gated, so `HF_TOKEN` is
  needed before a download. `DOWNLOAD=0` is there so a container never hangs on
  one.
- `MAYA_UPDATE_CHECK=0` is set in the image: `serve/update.py` calls the GitHub
  API, which is not what a service container should do on start.
- `STRATA_BUILD_TESTS` stays OFF, but `project-maya/tests/` is still in the context:
  `CMakeLists.txt` adds several `tests/` targets outside that option, so CMake
  generation fails without the folder. The test binaries are never built.
- The health check has `--start-period=2h` because the first start can take hours.

## Layout

```text
Dockerfile            build stages, runtime stage, entry point, healthcheck
build.sh              checkout, tag, user, env file, context, docker build
docker-compose.yaml   the service
.env.example          the variables the container reads
docker/entrypoint.sh  first-start prep, warnings, then the server
docker/healthcheck.sh /health probe
docker/prepare.py     maya.py's own steps, from the environment
docker/write-stamp.py build/MAYA-BUILD.json for the subset source_hash() reads
tests/test_docker.py  static gate (shell, Dockerfile, compose, .env.example)
.dockerignore         what the context keeps
```

## Tests

The gate is static, so it runs without Docker or a GPU:

```bash
python3 -m unittest tests/test_docker.py -v
```

It checks that the shell scripts parse, that the Dockerfile uses only
legacy-builder features, that the runtime contract (tini, healthcheck,
`STOPSIGNAL`, the `/data` volume, the port) is what this README says, that compose
matches the documented settings, that every `.env.example` variable is actually
read, that `build.sh --ctx-only` produces a context without `Strata/` or this
repo's `tests/`, and that the context's engine subset hashes the same as the
checkout it came from.

`Strata/` is in the workspace as a reference for packaging and Docker practice
only; it is excluded from the build context and is not part of the image.
