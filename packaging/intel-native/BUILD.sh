#!/usr/bin/env bash
# Build pinned public Intel sources in a disposable Debian Forky container.
set -euo pipefail
: "${PROJ:?Set PROJ to the owned build directory under HOME/Projects}"
PROJ=$(realpath "$PROJ")
case "$PROJ/" in "$HOME/Projects/"*) ;; *) echo 'PROJ must be under HOME/Projects' >&2; exit 1;; esac
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CI=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)
CI_REL=$(realpath --relative-to="$PROJ" "$CI")
case "$CI_REL" in ../*|..) echo 'Source checkout must be inside PROJ' >&2; exit 1;; esac
[ -z "$(git -C "$CI" status --porcelain)" ] || { echo 'Source checkout must be clean' >&2; exit 1; }
mkdir -p "$PROJ"/{tmp,home,caches,logs,artifacts}
chmod 1777 "$PROJ/tmp"
FSTYPE=$(findmnt -n -o FSTYPE -T "$PROJ")
case "$FSTYPE" in ''|tmpfs|ramfs|devtmpfs) echo 'PROJ filesystem must be known and disk-backed' >&2; exit 1;; esac
export TMPDIR="$PROJ/tmp"
SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(git -C "$CI" show -s --format=%ct HEAD)}
case "$SOURCE_DATE_EPOCH" in ''|*[!0-9]*) echo 'SOURCE_DATE_EPOCH must be numeric' >&2; exit 1;; esac
[ "$SOURCE_DATE_EPOCH" -gt 0 ] || { echo 'SOURCE_DATE_EPOCH must be > 0' >&2; exit 1; }
export SOURCE_DATE_EPOCH
SRC="$PROJ/caches/source"
for pair in 'openvino:e213a14725769a6a2bf86fc86650aa78a9c05d3e' 'npu-driver:aea583dcd86a4723a8d3bb06ad94b6eb2f80c6f2' 'npu_compiler:0b38f7d42113ff329ac2bdd33583d123de4ccf2f'; do
  name=${pair%%:*}; pin=${pair#*:}
  [ "$(git -C "$SRC/$name" rev-parse HEAD)" = "$pin" ] || { echo "Wrong source pin: $name" >&2; exit 1; }
  [ -z "$(git -C "$SRC/$name" status --porcelain)" ] || { echo "Dirty source: $name" >&2; exit 1; }
done
DOCKER_IMAGE=${DOCKER_IMAGE:-debian:forky}
DOCKER_NAME=${DOCKER_NAME:-ncz-intel-native-$$}
JOBS=${JOBS:-4}
SNAPSHOT=20261012T023456Z
created=0
cleanup() { if [ "$created" = 1 ]; then docker stop "$DOCKER_NAME" >/dev/null; fi; }
trap cleanup EXIT
# The task bind contains every build/cache/home/temp path. /tmp is also a
# disk-backed task bind for tools that ignore TMPDIR. Host CA data is read-only.
docker run --rm -d --init --name "$DOCKER_NAME" --cpus "$JOBS" \
  --memory "${BUILD_MEMORY:-16g}" --pids-limit 4096 \
  -v "$PROJ:/work" -v "$PROJ/tmp:/tmp" \
  -e HOME=/work/home -e TMPDIR=/work/tmp -e XDG_CACHE_HOME=/work/caches/xdg \
  -e GOPATH=/work/caches/go -e GOCACHE=/work/caches/go-build \
  -e GOMODCACHE=/work/caches/go/pkg/mod -e CCACHE_DIR=/work/caches/ccache \
  -e GIT_TERMINAL_PROMPT=0 -e DEBIAN_FRONTEND=noninteractive \
  -w /work "$DOCKER_IMAGE" sleep infinity > "$PROJ/logs/container.id"
created=1
printf '%s\n' "$DOCKER_NAME" > "$PROJ/logs/container.name"
docker exec -e SNAPSHOT="$SNAPSHOT" -e CI_REL="$CI_REL" "$DOCKER_NAME" bash -ceu '
  . /etc/os-release
  [ "$VERSION_CODENAME" = forky ]
  mkdir -p "$HOME" "$TMPDIR" "$XDG_CACHE_HOME" "$GOPATH" "$GOCACHE" "$GOMODCACHE" "$CCACHE_DIR"
  chmod 1777 "$TMPDIR"
  for source_name in openvino npu-driver npu_compiler; do
    git config --global --add safe.directory "/work/caches/source/$source_name"
  done
  if [ ! -s /etc/ssl/certs/ca-certificates.crt ]; then
    apt-get -o APT::Update::Error-Mode=any update
    bash "/work/$CI_REL/build/apt-sim-zero-removals.sh" /work/logs/ca-bootstrap-simulation.log -y --no-install-recommends ca-certificates
    dpkg-query -W ca-certificates openssl > /work/logs/ca-bootstrap-versions.txt
  fi
  rm -f /etc/apt/sources.list /etc/apt/sources.list.d/debian.sources
  printf "Types: deb\nURIs: https://snapshot.debian.org/archive/debian/%s/\nSuites: forky\nComponents: main\nSigned-By: /usr/share/keyrings/debian-archive-keyring.gpg\nCheck-Valid-Until: no\n" "$SNAPSHOT" > /etc/apt/sources.list.d/ncz-snapshot.sources
  apt-get -o APT::Update::Error-Mode=any update
  bash "/work/$CI_REL/build/apt-sim-zero-removals.sh" /work/logs/build-deps-simulation.log \
    -y --no-install-recommends cmake ninja-build build-essential ccache git git-lfs pkgconf \
    patchelf dpkg-dev lintian libtbb-dev libpugixml-dev libsnappy-dev libffi-dev \
    python3 libpython3-dev pybind11-dev nlohmann-json3-dev libflatbuffers-dev rapidjson-dev \
    libva-dev ocl-icd-opencl-dev opencl-headers libgtest-dev libgmock-dev \
    libyaml-cpp-dev libze-dev libdrm-dev libssl-dev libxml2-utils fdupes ca-certificates file
  dpkg-query -W > /work/logs/build-deps-versions.txt
  apt-get check
  dpkg --audit
' > "$PROJ/logs/build-deps.log" 2>&1
for item in openvino-2026.4.1 linux-npu-driver-1.38.0; do
  case "$item" in openvino-*) source_name=openvino;; *) source_name=npu-driver;; esac
  log="$PROJ/logs/$item-build.log"
  case "$item" in
    openvino-*)
      docker exec -e SRC_DIR="/work/caches/source/$source_name" -e BUILD_DIR="/work/caches/build/$item" \
        -e OUT_DIR="/work/artifacts/$item" \
        -e CI_REL="$CI_REL" -e ITEM="$item" -e JOBS="$JOBS" -e SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
        "$DOCKER_NAME" bash -ceu '
          bash "/work/$CI_REL/packaging/intel-native/CONFIGURE-$ITEM.sh"
          bash "/work/$CI_REL/packaging/intel-native/PACKAGE-$ITEM.sh"
        ' > "$log" 2>&1 || { tail -20 "$log"; exit 1; }
      ;;
    *)
      docker exec -e SRC_DIR="/work/caches/source/$source_name" -e BUILD_DIR="/work/caches/build/$item" \
        -e OUT_DIR="/work/artifacts/$item" \
        -e CI_REL="$CI_REL" -e ITEM="$item" -e JOBS="$JOBS" -e SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" "$DOCKER_NAME" bash -ceu '
          bash "/work/$CI_REL/packaging/intel-native/CONFIGURE-$ITEM.sh"
          cmake --build "$BUILD_DIR" --parallel "$JOBS" --target npu_compiler_source
          python3 "/work/$CI_REL/packaging/intel-native/APPLY-NPU-LLVM-PATCH.py" \
            "$BUILD_DIR/compiler/src/npu_compiler" \
            "/work/$CI_REL/packaging/intel-native/patches/0001-mlir-required-parse-guard.patch" \
            /work/logs/npu-compiler-patched-source.json
          bash "/work/$CI_REL/packaging/intel-native/PACKAGE-$ITEM.sh"
        ' > "$log" 2>&1 || { tail -20 "$log"; exit 1; }
      ;;
  esac
  mkdir -p "$PROJ/artifacts/$item"
  if [ "$item" != openvino-2026.4.1 ]; then
    find "$PROJ/caches/build/$item" -maxdepth 3 -name '*.deb' -exec cp -t "$PROJ/artifacts/$item" -- {} +
  fi
  compgen -G "$PROJ/artifacts/$item/*.deb" >/dev/null || { echo "No .deb produced: $item" >&2; exit 1; }
  sha256sum "$PROJ/artifacts/$item/"*.deb > "$PROJ/logs/$item-sha256.txt"
  tail -5 "$log"
done
