#!/usr/bin/env bash
# tools/lockrig/lease.sh -- per-host test lease. A lease is a small file under
# $LEASE_DIR named <host>.lease. Because two operator sessions have collided on
# shared test machines, lockrig MUST acquire a lease before touching a host and
# MUST refuse if another owner holds a live (unexpired) lease.
#
# Storage: $LOCKRIG_LEASE_DIR, defaulting to
#   ~/.local/state/ncz/hostlease
# Override to share state across machines (e.g. a shared NFS directory):
#   export LOCKRIG_LEASE_DIR=/path/on/shared/nfs/hostlease
# Additional lease directories (sessions that keep their own lease directory)
# are named by $LOCKRIG_LEASE_DIRS (colon-separated) or, when that is unset, by
# "${XDG_CONFIG_HOME:-~/.config}/ncz/lease-dirs" (one directory per line, '#'
# comments). Every command treats the primary and the additional directories
# as one lease store: acquire refuses when ANY of them holds a live lease by
# another owner and then writes the lease to ALL of them; release removes it
# from all of them (refusing if any copy belongs to another owner); status
# merges them; reap drops expired leases in each.
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

LEASE_DIR="${LOCKRIG_LEASE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/ncz/hostlease}"
LEASE_DIR="${LEASE_DIR%/}"
DEFAULT_TTL=2700   # 45 min: a lockrig host run must finish well inside this

# extra_dirs: the additional lease directories, one per line, deduplicated,
# without the primary.
extra_dirs() {
  local raw="" d cfg="${XDG_CONFIG_HOME:-$HOME/.config}/ncz/lease-dirs"
  if [ -n "${LOCKRIG_LEASE_DIRS+x}" ]; then
    raw="$(printf '%s' "$LOCKRIG_LEASE_DIRS" | tr ':' '\n')"
  elif [ -r "$cfg" ]; then
    raw="$(sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e 's/^[[:space:]]*//' "$cfg")"
  fi
  printf '%s\n' "$raw" | while IFS= read -r d; do
    [ -n "$d" ] || continue
    case "$d" in "~"/*) d="$HOME/${d#\~/}";; esac
    d="${d%/}"
    [ "$d" = "${LEASE_DIR%/}" ] && continue
    printf '%s\n' "$d"
  done | awk '!seen[$0]++'
}
# all_dirs: the primary directory first, then the additional ones.
all_dirs() { printf '%s\n' "$LEASE_DIR"; extra_dirs; }

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

  # serialize with a mkdir mutex in EVERY lease directory (portable; macOS has
  # no flock), taken in sorted order so sessions that list the directories in
  # a different order cannot deadlock each other
  local d f held m
  LOCKED=""
  unlock_all() { local x; while IFS= read -r x; do [ -n "$x" ] && rmdir "$x" 2>/dev/null; done <<< "$LOCKED"; LOCKED=""; }
  trap 'unlock_all' EXIT
  while IFS= read -r d; do
    mkdir -p "$d" 2>/dev/null || { unlock_all; trap - EXIT; die "cannot create $d"; }
    m="$d/$host.lock.d"
    local tries=0
    while ! mkdir "$m" 2>/dev/null; do
      tries=$((tries+1))
      [ "$tries" -gt 100 ] && { unlock_all; trap - EXIT; die "could not acquire lease mutex for $host in $d"; }
      sleep 0.1
    done
    LOCKED="${LOCKED:+$LOCKED
}$m"
  done < <(all_dirs | sort -u)

  # a live lease by another owner in ANY directory refuses
  while IFS= read -r d; do
    f="$d/$host.lease"
    if lease_live "$f"; then
      held="$(lget "$f" OWNER)"
      if [ "$held" != "$owner" ]; then
        echo "lease: REFUSED $host held by '$held' ($(lget "$f" PURPOSE)), acquired $(lget "$f" ACQUIRED_ISO) ttl=$(lget "$f" TTL)s [$d]" >&2
        unlock_all; trap - EXIT
        return 3
      fi
      # same owner: idempotent re-acquire refreshes timestamp/ttl
    elif [ -f "$f" ]; then
      echo "lease: taking over EXPIRED lease on $host (was owner=$(lget "$f" OWNER)) [$d]" >&2
    fi
  done < <(all_dirs)

  local body
  body="$(
    echo "HOST=$host"
    echo "OWNER=$owner"
    echo "PURPOSE=$purpose"
    echo "ACQUIRED_EPOCH=$(now)"
    echo "ACQUIRED_ISO=$(iso)"
    echo "TTL=$ttl"
    echo "HOLDER_HOST=$(hostname -s 2>/dev/null || hostname)"
    echo "HOLDER_PID=$$"
  )"
  # write every copy; if any write fails, remove the copies already written so
  # the directories never disagree, and fail
  local written=""
  while IFS= read -r d; do
    if printf '%s\n' "$body" > "$d/$host.lease" 2>/dev/null; then
      written="${written:+$written
}$d/$host.lease"
    else
      while IFS= read -r f; do [ -n "$f" ] && rm -f "$f"; done <<< "$written"
      unlock_all; trap - EXIT
      die "cannot write the lease in $d; no lease taken"
    fi
  done < <(all_dirs)
  unlock_all; trap - EXIT
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
  local d f found=0
  # check every copy first, so a refusal leaves all of them in place
  while IFS= read -r d; do
    f="$d/$host.lease"
    [ -f "$f" ] || continue
    found=1
    if [ -n "$owner" ] && [ "$(lget "$f" OWNER)" != "$owner" ]; then
      echo "lease: NOT releasing $host -- owned by '$(lget "$f" OWNER)', not '$owner' [$d]" >&2
      return 3
    fi
  done < <(all_dirs)
  [ "$found" = 1 ] || { echo "lease: $host not leased"; return 0; }
  while IFS= read -r d; do rm -f "$d/$host.lease"; done < <(all_dirs)
  echo "lease: released $host"
}

# status_line HOST: one line for HOST merged over all directories. A live copy
# wins over an expired one; live copies with different owners are a CONFLICT.
status_line() {
  local host="$1" d f o live="" expired="" owners=""
  while IFS= read -r d; do
    f="$d/$host.lease"
    [ -f "$f" ] || continue
    if lease_live "$f"; then
      [ -n "$live" ] || live="$f"
      o="$(lget "$f" OWNER)"
      printf '%s\n' "$owners" | grep -qxF -- "$o" || owners="${owners:+$owners
}$o"
    else
      [ -n "$expired" ] || expired="$f"
    fi
  done < <(all_dirs)
  if [ -n "$live" ]; then
    # owners holds each distinct live owner once, one per line
    if [ "$(printf '%s\n' "$owners" | grep -c .)" -gt 1 ]; then
      echo "$host CONFLICT owners=$(printf '%s' "$owners" | tr '\n' ',')"
    else
      echo "$host HELD owner=$(lget "$live" OWNER) purpose=$(lget "$live" PURPOSE) since=$(lget "$live" ACQUIRED_ISO) ttl=$(lget "$live" TTL)"
    fi
  elif [ -n "$expired" ]; then
    echo "$host EXPIRED owner=$(lget "$expired" OWNER) since=$(lget "$expired" ACQUIRED_ISO)"
  else
    echo "$host FREE"
  fi
}

cmd_status() {
  mkdir -p "$LEASE_DIR"
  local host="${1:-}"
  if [ -n "$host" ]; then
    status_line "$host"
    return 0
  fi
  # all hosts in any directory
  local d f hosts
  hosts="$(while IFS= read -r d; do
             for f in "$d"/*.lease; do [ -e "$f" ] && basename "$f" .lease; done
           done < <(all_dirs) | sort -u)"
  if [ -z "$hosts" ]; then echo "(no leases)"; return 0; fi
  while IFS= read -r host; do status_line "$host"; done <<< "$hosts"
}

cmd_reap() {
  mkdir -p "$LEASE_DIR"
  local d f
  while IFS= read -r d; do
    for f in "$d"/*.lease; do
      [ -e "$f" ] || continue
      if ! lease_live "$f"; then
        echo "lease: reaping expired $(basename "$f" .lease) (owner=$(lget "$f" OWNER)) [$d]"
        rm -f "$f"
      fi
    done
  done < <(all_dirs)
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
env:   LOCKRIG_LEASE_DIR  primary lease directory (default ~/.local/state/ncz/hostlease)
       LOCKRIG_LEASE_DIRS additional lease directories, colon-separated (default: the
                          lines of ~/.config/ncz/lease-dirs; set empty for none)
USAGE
     exit 2;;
esac
