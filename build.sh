#!/bin/sh
# Build a Project Maya image from the git checkout. Needs Docker and the internet (for the
# base image, for llama.cpp at the pinned commit, and for the checkout when it is not
# already here). Nothing is pushed anywhere; the image stays in the local Docker.
#
#   ./build.sh                                   # clone project-maya at the pinned commit, build
#   ./build.sh --latest                          # use origin/main instead of the pinned commit
#   ./build.sh --arch 86 --tag project-maya:rtx30
#   ./build.sh --target maya --no-vision         # a smaller image: the GLM engine only
#   ./build.sh --user 1000:1000 --env-file .env
#   ./build.sh --ctx-only --ctx /tmp/maya-ctx    # assemble the context and stop (no docker)
#
# Options
#   --repo DIR          the project-maya checkout (default: ./project-maya, cloned if missing)
#   --commit SHA        the commit to check out (default 26aacb6bcea9333e4f408a68ee60c4c1c316bd68)
#   --latest            fetch and use origin/main instead of the pinned commit
#   --tag NAME          image name (default project-maya:<version>-cuda<major>)
#   --version V         label (default: read from the checkout's VERSION file)
#   --cuda-image IMAGE  the build stage's base (default nvidia/cuda:12.8.1-devel-ubuntu24.04)
#   --runtime-image IMAGE  the runtime stage's base (default nvidia/cuda:12.8.1-runtime-ubuntu24.04)
#   --arch LIST         CUDA architectures, ';' separated (default: detected, see below)
#   --target LIST       engine targets to build, ';' separated (default maya;maya-ds4;maya-mm3)
#   --no-vision         do not build maya-vision
#   --user UID:GID      the user the container runs as (default 1000:1000)
#   --env-file FILE     the .env to read (its KEY=VALUE lines fill the declared ARGs)
#   --ctx DIR           keep the build context here (default: a temporary folder, removed after)
#   --no-cache          docker build --no-cache
#   --ctx-only          assemble the context and stop
#   -h                  this help
# Environment: MAYA_DOCKER_BUILD_OPTS adds options to `docker build` (e.g. --network host).
#
# Arch detection, when --arch is not given: the host's nvidia-smi compute_cap, else a
# `docker run --gpus all <build base> nvidia-smi`, else the default list 70;80;86;89;120.
# CUDA 13 cannot build for Pascal or Volta, so the default base stays CUDA 12.8.1: it covers
# sm_60 up to sm_120. Pass --cuda-image/--runtime-image for a CUDA 13 build of sm_75+.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo=$(CDPATH= cd -- "$here/project-maya" 2>/dev/null && pwd -P) || repo="$here/project-maya"
commit=26aacb6bcea9333e4f408a68ee60c4c1c316bd68
tag="" version="" cuda_image="nvidia/cuda:12.8.1-devel-ubuntu24.04" runtime_image="nvidia/cuda:12.8.1-runtime-ubuntu24.04"
arch="" targets="maya;maya-ds4;maya-mm3" vision=1 user="1000:1000" envfile="" ctx="" nocache="" ctxonly="" latest=""
url=https://github.com/mw00/project-maya/

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo=$(CDPATH= cd -- "$2" && pwd -P); shift 2 ;;
    --commit) commit=$2; shift 2 ;;
    --latest) latest=1; shift ;;
    --tag) tag=$2; shift 2 ;;
    --version) version=$2; shift 2 ;;
    --cuda-image) cuda_image=$2; shift 2 ;;
    --runtime-image) runtime_image=$2; shift 2 ;;
    --arch) arch=$2; shift 2 ;;
    --target) targets=$2; shift 2 ;;
    --no-vision) vision=0; shift ;;
    --user) user=$2; shift 2 ;;
    --env-file) envfile=$2; shift 2 ;;
    --ctx) ctx=$2; shift 2 ;;
    --no-cache) nocache=--no-cache; shift ;;
    --ctx-only) ctxonly=1; shift ;;
    -h|--help) sed -n '2,35p' "$0"; exit 0 ;;
    *) echo "build.sh: unknown option $1" >&2; exit 2 ;;
  esac
done

# ---- 1. the checkout ----
if [ ! -d "$repo" ]; then
  echo "cloning $url into $repo"
  git clone "$url" "$repo"
fi
if [ ! -f "$repo/VERSION" ] || [ ! -f "$repo/CMakeLists.txt" ]; then
  echo "build.sh: $repo is not a project-maya checkout (VERSION and CMakeLists.txt are needed)" >&2
  exit 2
fi
if git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
  if [ -n "$latest" ]; then
    echo "using origin/main"
    git -C "$repo" fetch origin main && git -C "$repo" checkout -q origin/main
  elif [ "$(git -C "$repo" rev-parse HEAD)" != "$commit" ]; then
    echo "checking out $commit"
    git -C "$repo" fetch -q origin "$commit" 2>/dev/null || git -C "$repo" fetch -q origin main
    git -C "$repo" checkout -q "$commit"
  fi
fi
commit=$(git -C "$repo" rev-parse HEAD 2>/dev/null || echo "")
# the checkout's VERSION file can carry CRLF (it does), so strip it: a CR in a tag is
# not a valid repository name
version=${version:-$(head -1 "$repo/VERSION" 2>/dev/null | tr -d '\r')}
version=${version:-$(sed -n 's/^[[:space:]]*project([^)]*VERSION[[:space:]]*\([0-9][0-9.]*\).*/\1/p' "$repo/CMakeLists.txt" | tr -d '\r' | head -1)}
version=${version:-dev}

# ---- 2. the architectures ----
if [ -z "$arch" ]; then
  # compute_cap is printed as a decimal (8.6), and CMake wants the sm_ number (86)
  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi --query-gpu=compute_cap --format=csv,noheader >/dev/null 2>&1; then
    arch=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader,nounits | tr -d '.' | awk '!seen[$0]++' | tr '\n' ';' | sed 's/;$//')
    echo "architectures from this host's GPUs: $arch"
  elif command -v docker >/dev/null 2>&1 && docker run --rm --gpus all "$cuda_image" nvidia-smi --query-gpu=compute_cap --format=csv,noheader,nounits >/dev/null 2>&1; then
    arch=$(docker run --rm --gpus all "$cuda_image" nvidia-smi --query-gpu=compute_cap --format=csv,noheader,nounits | tr -d '.' | awk '!seen[$0]++' | tr '\n' ';' | sed 's/;$//')
    echo "architectures from the container's GPUs: $arch"
  else
    arch="70;80;86;89;120"
    echo "no GPU seen: building for the default list $arch"
  fi
fi
# maya.py's nvcc_range: Blackwell needs CUDA 12.8, and CUDA 13 cannot build for Pascal or
# Volta. The default base is CUDA 12.8.1, which covers every architecture from sm_60.
min=; max=
for a in $(echo "$arch" | tr ';,' '  '); do
  [ "$a" -lt 60 ] && { echo "build.sh: sm_$a is below compute capability 6.0, which Maya refuses" >&2; exit 2; }
  min=${min:-$a}; max=$a
done
if [ "$min" -lt 75 ]; then
  case "$cuda_image" in *13.*) echo "build.sh: CUDA 13 cannot build for sm_$min (Volta or Pascal); use a CUDA 12.x base" >&2; exit 2 ;; esac
fi

uid=${user%%:*}; gid=${user##*:}
# the tag says which CUDA the image was built with, so a CUDA 13 base does not get a
# cuda12 tag
cuda_major=$(printf '%s' "$cuda_image" | sed -n 's/.*:\([0-9]*\)\.\([0-9]*\).*/\1/p')
cuda_major=${cuda_major:-12}
[ -n "$tag" ] || tag="project-maya:$version-cuda$cuda_major"

# ---- 3. the build context ----
own_ctx=""
if [ -z "$ctx" ]; then ctx=$(mktemp -d "${TMPDIR:-/tmp}/maya-docker-ctx.XXXXXX"); own_ctx=1; fi
mkdir -p "$ctx/docker" "$ctx/project-maya"
cleanup() { if [ -n "$own_ctx" ] && [ -z "$ctxonly" ]; then rm -rf "$ctx"; fi; }
trap cleanup EXIT

# the app tree, exactly as .dockerignore keeps it: the engine source subset, the Python
# application, the shipped expert profiles and the setup's offline wheels
cd "$repo"
# --anchored is needed for the build outputs: an unanchored `build*` also matches
# cmake/build_id.cmake, which is part of setup.ENGINE_SOURCES and must be in the context
# for the stamp to match the tree Maya reads.
tar --exclude='.git' --exclude='__pycache__' --exclude='./build*' \
    --exclude='bench' --exclude='ref' --exclude='docs' --exclude='.github' --exclude='.venv' \
    --exclude='third_party/llama.cpp' --exclude='*.zip' --exclude='*.log' \
    --exclude='maya-*.json' --exclude='run-*.sh' --exclude='run-*.bat' \
    --exclude='token-savings.json' --exclude='maya-report.txt' \
    --exclude='data/*' -cf - . | tar -xf - -C "$ctx/project-maya"
for f in data/expert-profile-*.bin; do
  [ -f "$f" ] && cp "$f" "$ctx/project-maya/data/" || true
done

cp "$here/.dockerignore" "$ctx/.dockerignore"
cp "$here/Dockerfile" "$ctx/Dockerfile"
for f in entrypoint.sh healthcheck.sh prepare.py write-stamp.py; do
  tr -d '\r' < "$here/docker/$f" > "$ctx/docker/$f"
  chmod 0755 "$ctx/docker/$f"
done

# ---- 4. the environment file ----
if [ -z "$envfile" ] && [ -f "$here/.env" ]; then envfile="$here/.env"; fi
if [ -z "$envfile" ] && [ -f "$here/.env.example" ] && [ -z "$ctxonly" ]; then
  cp "$here/.env.example" "$here/.env"
  echo "created $here/.env from .env.example (edit it: the model and the API key)"
  envfile="$here/.env"
fi

echo "context: $ctx"
echo "repo $repo (commit ${commit:-unknown}), version $version, arch $arch, targets $targets, vision $vision, user $user, tag $tag"
[ -n "$ctxonly" ] && { echo "context kept (--ctx-only)"; exit 0; }

command -v docker >/dev/null 2>&1 || { echo "build.sh: docker is not installed" >&2; exit 1; }

# `docker build` has no --env-file (only `docker run` does), so the file is read here and
# only the variables the Dockerfile declares as ARGs are passed. A line that is empty, a
# comment, or not KEY=VALUE is skipped; quotes around a value are removed.
set -- $nocache
if [ -n "$envfile" ]; then
  if [ ! -f "$envfile" ]; then
    echo "build.sh: the env file $envfile does not exist" >&2
    exit 2
  fi
  echo "env file: $envfile"
  while IFS= read -r line || [ -n "$line" ]; do
    line=$(printf '%s' "$line" | tr -d '\r')
    case "$line" in ''|\#*) continue ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    key=${line%%=*}; value=${line#*=}
    case "$key" in CUDA_IMAGE|RUNTIME_BASE|CUDA_ARCHITECTURES|BUILD_TARGETS|BUILD_VISION|MAYA_VERSION|MAYA_COMMIT|USER_ID|GROUP_ID)
      case "$value" in \"*\"|\'*\') value=${value#?}; value=${value%?} ;; esac
      [ -z "$value" ] && continue
      set -- "$@" --build-arg "$key=$value"
    esac
  done < "$envfile"
fi
set -- "$@" --build-arg "CUDA_IMAGE=$cuda_image" --build-arg "RUNTIME_BASE=$runtime_image" \
     --build-arg "CUDA_ARCHITECTURES=$arch" --build-arg "BUILD_TARGETS=$targets" \
     --build-arg "BUILD_VISION=$vision" --build-arg "MAYA_VERSION=$version" \
     --build-arg "MAYA_COMMIT=$commit" --build-arg "USER_ID=$uid" --build-arg "GROUP_ID=$gid"
# shellcheck disable=SC2068
docker build $MAYA_DOCKER_BUILD_OPTS "$@" -t "$tag" "$ctx"
docker image inspect "$tag" --format 'built {{.RepoTags}} {{.Size}} bytes'
echo "Not pushed anywhere. Run it with docker-compose.yaml, or:"
echo "  docker run --rm --gpus all -p 127.0.0.1:8080:8080 --ulimit memlock=-1 --shm-size 2g \\"
echo "    --cap-add SYS_NICE --stop-timeout 120 -v maya-data:/data -e MODEL=Maya-S-v2-IQ2_XXS \\"
echo "    -e API_KEY=change-me-please-123 $tag"
