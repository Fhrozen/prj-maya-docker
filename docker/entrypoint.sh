#!/bin/sh
# Entry point of the Project Maya container: the model, the pack and the config are made
# on the first start (docker/prepare.py, which reuses maya.py's own step functions), then
# the server is started and stays up, stopping cleanly on SIGTERM (`docker stop`).
#
#   docker run ... project-maya              start the server (default)
#   docker run ... project-maya sh           a shell
#   docker run ... project-maya python3 docker/prepare.py --help
#
# Settings (all optional; the names match what maya.py's setup asks for):
#   MODEL        a Maya quant (Maya-S-v2-IQ2_XXS, Maya-S24, ...) or a family name
#                (glm, deepseek, minimax, qwen). Empty: the model set up before, else the
#                one maya.py recommends for this card.
#   MODEL_PATH   model files you already have, as seen inside the container (mount them
#                below; the pack is written next to them, so the mount must be writable)
#   CONTEXT      context length in tokens (default 32768)
#   PARALLEL     requests answered at the same time, 1 to 8 (empty: the engine's choice)
#   VISION       on | off (the image encoder; its files are downloaded with the model)
#   DRAFT        mtp | dflash2 (empty: the model's MTP block)
#   DOWNLOAD     1 (default): download the model when its files are not there. 0: stop
#                instead, so a container is never left waiting on a huge download.
#   GPUS         card numbers, e.g. 0 or 0,1 (empty or "all": the engine's choice)
#   PORT         port inside the container (default 8080)
#   HOST         where the server listens (default 0.0.0.0 inside the container)
#   API_KEY      the key clients must send. The server does not serve beyond loopback
#                without a key, so one is always on: yours, or one made on the first start
#                and kept in /data/state.
#   HF_TOKEN     Hugging Face read token, for a gated repo
#   MAYA_ENV     advanced engine settings, space separated KEY=VALUE (like maya.py --env)
set -u

APP=${MAYA_APP:-/data/app}
IMAGE_APP=${MAYA_IMAGE_APP:-/opt/maya}
PYBIN="$APP/venv/bin/python3"
[ -x "$PYBIN" ] || PYBIN=$(command -v python3 || echo python3)
KEY_FILE=/data/state/api-key
PHASE_FILE=/run/maya-phase
PORT=${PORT:-8080}

say()  { printf '%s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '[X] %s\n' "$*" >&2; exit "${2:-1}"; }
phase() { printf '%s\n' "$1" > "$PHASE_FILE" 2>/dev/null || true; }

# ---- other commands: `docker run image sh`, `docker run image python3 tools/...`
if [ "$#" -gt 0 ] && [ "$1" != "run" ] && [ "$1" != "serve" ]; then
  exec "$@"
fi

mkdir -p /data/app /data/models /data/config /data/state /data/home /run 2>/dev/null \
  || die "/data is not writable. Mount a volume there: -v maya-data:/data"

if ! grep -q " /data " /proc/self/mountinfo 2>/dev/null; then
  warn "/data is not a volume, so the model, the pack and your config are lost when this container is removed. Add: -v maya-data:/data"
fi

# ---- the app tree: the image's copy is the read-only source, /data/app the working one
# (Maya writes its config, its log and its run script next to the tree it runs from, so
# the volume keeps them across container removals).
version_file=$IMAGE_APP/VERSION
image_version=$([ -r "$version_file" ] && tr -d ' \r\n' < "$version_file" || echo "?")
if [ ! -e "$APP/.image-version" ]; then
  say "First start: copying the application tree into /data/app ..."
  cp -a "$IMAGE_APP/." "$APP/" || die "could not populate $APP from $IMAGE_APP"
elif [ "$(tr -d ' \r\n' < "$APP/.image-version" 2>/dev/null)" != "$image_version" ]; then
  say "This image is version $image_version, $APP was made by $(tr -d ' \r\n' < "$APP/.image-version" 2>/dev/null): copying the tree again (the model, the pack and the config in /data are kept)."
  cp -a "$IMAGE_APP/." "$APP/" || die "could not refresh $APP from $IMAGE_APP"
fi
printf '%s\n' "$image_version" > "$APP/.image-version" 2>/dev/null || true

# ---- plain warnings (never refusals)
cpuinfo=${MAYA_CPUINFO:-/proc/cpuinfo}
if [ -r "$cpuinfo" ] && grep -q '^flags' "$cpuinfo" && ! grep -m1 '^flags' "$cpuinfo" | grep -qw avx512f; then
  warn "This computer's CPU has no AVX-512. The CPU expert kernel is compiled for it and the engine stops with 'needs AVX512-VNNI/VBMI' here. Use a native GGUF pack with the CPU expert lane off, or run this image on a CPU with AVX-512."
fi
limit=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo max)
case "$limit" in max|"") ;; *[!0-9]*) ;; *)
  gb=$((limit / 1073741824))
  warn "This container has a memory limit of ${gb} GB. Maya pins nearly all the RAM it is given for its expert tier, so a low limit can end in the container being killed. Raise or remove the limit, and give the container the memlock ulimit (--ulimit memlock=-1)."
esac
if [ -z "${API_KEY:-}" ] && [ ! -r "$KEY_FILE" ]; then
  warn "No API_KEY: one is made on the first start and kept in $KEY_FILE. Use 16 characters or more if you set your own ('openssl rand -hex 24' makes a good one)."
elif [ -n "${API_KEY:-}" ] && [ "${#API_KEY}" -lt 16 ]; then
  warn "API_KEY is short (${#API_KEY} characters). Use 16 or more; 'openssl rand -hex 24' makes a good one."
fi
if grep -q " /data/models " /proc/self/mountinfo 2>/dev/null; then
  ro=$(awk '$5 ~ "/data/models" && $0 ~ ":ro" {print; exit}' /proc/self/mountinfo)
  [ -n "$ro" ] && warn "/data/models is mounted read-only. The pack is written next to the model files, so Maya stops there: mount it writable, or set MODEL_PATH to a writable folder."
fi

# ---- the model, the pack, the config (reuses maya.py's own steps; nothing is duplicated)
phase preparing
if ! "$PYBIN" "$APP/docker/prepare.py"; then
  die "the preparation stopped (the reason is above). Nothing was started."
fi

key=${API_KEY:-}
[ -z "$key" ] && [ -r "$KEY_FILE" ] && key=$(cat "$KEY_FILE")
[ -z "$key" ] && { mkdir -p /data/state && key=$("$PYBIN" -c 'import secrets; print(secrets.token_hex(24))') && printf '%s\n' "$key" > "$KEY_FILE"; }

cfg=$(ls -1 "$APP"/maya-*.json 2>/dev/null | head -1)
[ -n "$cfg" ] || die "no config was written in $APP"

phase running
say "Starting Maya from $cfg on port $PORT."
say "Dashboard: http://127.0.0.1:$PORT/   API: http://127.0.0.1:$PORT/v1"

set -- "$PYBIN" "$APP/maya.py" --config "$cfg" --yes --plain \
     --host "${HOST:-0.0.0.0}" --port "$PORT" --api-key "$key"
if [ -n "${GPUS:-}" ] && [ "$GPUS" != "all" ]; then set -- "$@" --gpus "$GPUS"; fi
for pair in ${MAYA_ENV:-}; do set -- "$@" --env "$pair"; done

exec "$@"
