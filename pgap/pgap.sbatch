#!/bin/bash
#SBATCH --job-name=pgap
#SBATCH --cpus-per-task=16
#SBATCH --mem=64G
#SBATCH --time=1-00:00:00
#SBATCH --nodes=1
#SBATCH --output=logs/pgap-%j.out
#SBATCH --error=logs/pgap-%j.err

set -euo pipefail

# Prep dirs
mkdir -p logs
# Prefer node-local scratch if available; fall back to a big local path
if [ -n "${SLURM_JOB_ID:-}" ] && [ -d "/lscratch/${SLURM_JOB_ID}" ]; then
  export TMPDIR="/lscratch/${SLURM_JOB_ID}"
else
  export TMPDIR="/vf/users/wangy80/Bewley/TK220/tmp"
fi
mkdir -p "$TMPDIR"

# Modules / env
module load singularity
# module load apptainer   # if your site prefers apptainer, switch and adjust --docker path below
# source ~/bin/myconda    # only if you truly need conda; PGAP doesn't require it

# Singularity caches to local scratch to avoid NFS
export SINGULARITY_TMPDIR="$TMPDIR"
export SINGULARITY_CACHEDIR="$TMPDIR"
export PGAP_INPUT_DIR=/vf/users/wangy80/Bewley/TK220/pgap

# Optional: raise file descriptor limit
ulimit -n 8192 || true

# Paths
WORKDIR=/vf/users/wangy80/Bewley/TK220
INPUT=${WORKDIR}/Streptomyces/Input.yaml
OUTDIR=${WORKDIR}/pgap_anno
PGAP_SIF=${WORKDIR}/pgap_2025-05-06.build7983.sif

WRAP_DIR=/vf/users/wangy80/Bewley/TK220/bin
mkdir -p "$WRAP_DIR"
WRAP=$WRAP_DIR/singularity          # <— basename MUST be 'singularity'

cat > "$WRAP" <<'SH'
#!/usr/bin/env bash
REAL="/usr/local/current/singularity/4.2.2/bin/singularity"
LOG="/vf/users/wangy80/Bewley/TK220/singularity_debug.log"

# Ensure a runtime dir exists (avoids noisy warnings)
: "${XDG_RUNTIME_DIR:=${TMPDIR:-/tmp}/xdg}"
mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null || true

# If PGAP probes the version, just pass through
if [[ "$1" == "--version" || "$1" == "version" ]]; then
  exec "$REAL" "$@"
fi

# Rewrite argv:
# - Drop only cgroup/resource flags that break on rootless systems
# - If someone ever calls 'run' with docker-only flags, convert to exec and drop '--rm'
converted=()
skip=0
subcmd=""
for a in "$@"; do
  if [[ $skip -eq 1 ]]; then skip=0; continue; fi
  case "$a" in
    --cpus|--memory|--pids-limit|--cpu-shares|--cpuset-cpus|--cpuset-mems|--apply-cgroups)
      skip=1 ;;                              # drop flag + its value
    --rm) ;;                                 # docker-only, drop
    run) subcmd="run"; converted+=("exec") ;;# prefer exec
    -it|-ti) ;;                              # docker-isms; drop
    *) converted+=("$a") ;;
  esac
done

# Log final argv
{
  echo "===== $(date) ====="
  echo "PWD: $(pwd)"
  echo "EXEC: $REAL"
  printf 'ARGV:'; for x in "${converted[@]}"; do printf ' [%s]' "$x"; done; echo
} >> "$LOG"

# Add singularity debug for richer errors into LOG
exec "$REAL" -d "${converted[@]}" 2>>"$LOG"
SH
chmod +x "$WRAP"

export XDG_RUNTIME_DIR="${TMPDIR:-/tmp}/xdg"; mkdir -p "$XDG_RUNTIME_DIR"

# Run PGAP the supported way: host-side pgap.py orchestrates the container
# Notes:
# - Omit --memory so PGAP detects resources; or set --memory 64 if you want explicit GB.
# - Remove --no-internet only if your site blocks outbound traffic and you have a local data cache.
python3 ${WORKDIR}/pgap.py \
  -o "$OUTDIR" \
  --container-path "$PGAP_SIF" \
  --docker "$WRAP" \
  -r \
  "$INPUT"
