#!/usr/bin/env bash
# tools/lockrig/lease.sh -- per-host test lease. A lease is a small file under
# $LEASE_DIR named <host>.lease. Because two operator sessions have collided on
# PROTEUS/CHIMERA/PEGASUS, lockrig MUST acquire a lease before touching a host and
# MUST refuse if another owner holds a live (unexpired) lease.
#
# Storage: $LOCKRIG_LEASE_DIR, defaulting to
#   ~/Projects/oc-mission-20261010/hostlease   (STUDIO)
# Override to share state across machines (e.g. the ARGONAS copy):
#   export LOCKRIG_LEASE_DIR=/mnt/argonas/datapath/.../hostlease   # NFS, shared
# The lease file records owner + purpose + timestamp + TTL so a stale lease
# (crashed session) self-expires and never wedges a host.
#
# Usage:
#   lease.sh acquire <host> --owner OWNER --purpose PURPOSE [--ttl SEC]
#   lease.sh release <host> --owner OWNER
#   lease.sh status  [<host>]
#   lease.sh reap                 # drop expired leases
#
# Exit codes: 0 ok/free/released, 2 usage, 3 refused (live lease by another owner).
set -u

LEASE_DIR="${LOCKRIG_LEASE_DIR:-$HOME/Projects/oc-mission-20261010/hostlease}"
DEFAULT_TTL=2700   # 45 min: a lockrig host run must finish well inside this

die() { echo "lease: $*" >&2; exit 2; }

now() { date +%s; }
iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

lease_file() { echo "$LEASE_DIR/$1.lease"; }

# read a KEY from a lease file
lget() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1; }

# Is the lease live? live = file exists and now < acquired+ttl (or no ttl)
lease_live() { # $1 file
  [ -f "$1" ] || return 1
  local acq ttl end n
  acq="$(lget "$1" ACQUIRED_EPOCH)"; ttl="$(lget "$1" TTL)"
  [ -n "$acq" ] || return 1
  [ -n "$ttl" ] || ttl=0; [ "$ttl" -gt 0 ] 2>/dev/null || return 0
  end=$((acq + ttl)); n="$(now)"
  [ "$n" -lt "$end" ]
}

cmd_acquire() {
  local host="" owner="" purpose="" ttl="$DEFAULT_TTL"
  [ $# -ge 1 ] || die "acquire needs a host"
  host="$1"; shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --owner) owner="${2:-}"; shift 2;;
      --purpose) purpose="${2:-}"; shift 2;;
      --ttl) ttl="${2:-}"; shift 2;;
      *) die "acquire: unknown arg $1";;
    esac
  done
  [ -n "$owner" ] || die "acquire: --owner required"
  [ -n "$purpose" ] || die "acquire: --purpose required"
  mkdir -p "$LEASE_DIR" || die "cannot create $LEASE_DIR"
  local f; f="$(lease_file "$host")"

  # serialize with a mkdir mutex (portable; macOS has no flock)
  local mutex="$LEASE_DIR/$host.lock.d"
  local tries=0
  while ! mkdir "$mutex" 2>/dev/null; do
    tries=$((tries+1)); [ "$tries" -gt 100 ] && die "could not acquire lease mutex for $host"
    sleep 0.1
  done
  trap 'rmdir "$mutex" 2>/dev/null' EXIT

  if lease_live "$f"; then
    local held; held="$(lget "$f" OWNER)"
    if [ "$held" = "$owner" ]; then
      # idempotent re-acquire by same owner: refresh timestamp/ttl
      :
    else
      echo "lease: REFUSED $host held by '$held' ($(lget "$f" PURPOSE)), acquired $(lget "$f" ACQUIRED_ISO) ttl=$(lget "$f" TTL)s" >&2
      rmdir "$mutex" 2>/dev/null; trap - EXIT
      return 3
    fi
  elif [ -f "$f" ]; then
    echo "lease: taking over EXPIRED lease on $host (was owner=$(lget "$f" OWNER))" >&2
  fi

  {
    echo "HOST=$host"
    echo "OWNER=$owner"
    echo "PURPOSE=$purpose"
    echo "ACQUIRED_EPOCH=$(now)"
    echo "ACQUIRED_ISO=$(iso)"
    echo "TTL=$ttl"
    echo "HOLDER_HOST=$(hostname -s 2>/dev/null || hostname)"
    echo "HOLDER_PID=$$"
  } > "$f"
  rmdir "$mutex" 2>/dev/null; trap - EXIT
  echo "lease: acquired $host by $owner (ttl ${ttl}s)"
  return 0
}

cmd_release() {
  local host="" owner=""
  [ $# -ge 1 ] || die "release needs a host"
  host="$1"; shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --owner) owner="${2:-}"; shift 2;;
      *) die "release: unknown arg $1";;
    esac
  done
  local f; f="$(lease_file "$host")"
  [ -f "$f" ] || { echo "lease: $host not leased"; return 0; }
  if [ -n "$owner" ] && [ "$(lget "$f" OWNER)" != "$owner" ]; then
    echo "lease: NOT releasing $host -- owned by '$(lget "$f" OWNER)', not '$owner'" >&2
    return 3
  fi
  rm -f "$f"
  echo "lease: released $host"
}

cmd_status() {
  mkdir -p "$LEASE_DIR"
  local host="${1:-}"
  if [ -n "$host" ]; then
    local f; f="$(lease_file "$host")"
    if lease_live "$f"; then
      echo "$host HELD owner=$(lget "$f" OWNER) purpose=$(lget "$f" PURPOSE) since=$(lget "$f" ACQUIRED_ISO) ttl=$(lget "$f" TTL)"
    elif [ -f "$f" ]; then
      echo "$host EXPIRED owner=$(lget "$f" OWNER) since=$(lget "$f" ACQUIRED_ISO)"
    else
      echo "$host FREE"
    fi
    return 0
  fi
  # all
  local found=0
  for f in "$LEASE_DIR"/*.lease; do
    [ -e "$f" ] || continue
    found=1
    local h; h="$(basename "$f" .lease)"
    if lease_live "$f"; then
      echo "$h HELD owner=$(lget "$f" OWNER) purpose=$(lget "$f" PURPOSE) since=$(lget "$f" ACQUIRED_ISO) ttl=$(lget "$f" TTL)"
    else
      echo "$h EXPIRED owner=$(lget "$f" OWNER) since=$(lget "$f" ACQUIRED_ISO)"
    fi
  done
  [ "$found" = 1 ] || echo "(no leases)"
}

cmd_reap() {
  mkdir -p "$LEASE_DIR"
  local f
  for f in "$LEASE_DIR"/*.lease; do
    [ -e "$f" ] || continue
    if ! lease_live "$f"; then
      echo "lease: reaping expired $(basename "$f" .lease) (owner=$(lget "$f" OWNER))"
      rm -f "$f"
    fi
  done
}

case "${1:-}" in
  acquire) shift; cmd_acquire "$@";;
  release) shift; cmd_release "$@";;
  status)  shift; cmd_status "$@";;
  reap)    shift; cmd_reap "$@";;
  *) cat >&2 <<USAGE
usage: lease.sh acquire <host> --owner OWNER --purpose PURPOSE [--ttl SEC]
       lease.sh release <host> --owner OWNER
       lease.sh status [<host>]
       lease.sh reap
env:   LOCKRIG_LEASE_DIR (default ~/Projects/oc-mission-20261010/hostlease)
USAGE
     exit 2;;
esac
