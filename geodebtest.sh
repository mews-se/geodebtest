#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C
export LANG=C

SCRIPT_VERSION="v2026.07.31-3"

ARCH="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
SUITE="stable"
RUNS=3
COUNTRY=""
MAX_MIRRORS=10
PING_COUNT=4
CONNECT_TIMEOUT=5
MAX_TIME=60
APPLY=1
MAX_BACKUPS=5

# Prefix for /etc/apt paths, settable for testing against a fake tree.
APT_PREFIX="${GEODEBTEST_APT_PREFIX:-}"

MIRRORLIST_URL="https://mirror-master.debian.org/status/Mirrors.masterlist"
GLOBAL_MIRROR="deb.debian.org"
GLOBAL_PATH="/debian/"

usage() {
  cat <<EOF
Usage: $0 [--country SE] [--suite stable] [--arch amd64] [--runs 3] [--max-mirrors 10] [--no-apply]

Benchmarks the official Debian mirrors in your country (autodetected from
your public IP unless --country is given) against the global CDN
(${GLOBAL_MIRROR}) and recommends the fastest one.

After the results you can pick a mirror by rank and have the script update
your APT sources (classic sources.list and deb822 debian.sources), with a
timestamped backup and automatic rollback if apt-get update fails.
Use --no-apply to skip the interactive part (e.g. in scripts).

Examples:
  $0
  $0 --country DE
  $0 --suite bookworm --runs 5
EOF
}

require_value() {
  if [[ $# -lt 2 || -z "$2" ]]; then
    echo "Missing value for $1" >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --country)
      require_value "$@"
      if ! [[ "$2" =~ ^[A-Za-z]{2}$ ]]; then
        echo "--country requires a two-letter country code, got: $2" >&2
        exit 1
      fi
      COUNTRY="$(printf '%s' "$2" | tr '[:lower:]' '[:upper:]')"
      shift 2
      ;;
    --suite)
      require_value "$@"
      SUITE="$2"
      shift 2
      ;;
    --arch)
      require_value "$@"
      ARCH="$2"
      shift 2
      ;;
    --runs)
      require_value "$@"
      if ! [[ "$2" =~ ^[1-9][0-9]*$ ]]; then
        echo "--runs requires a positive integer, got: $2" >&2
        exit 1
      fi
      RUNS="$2"
      shift 2
      ;;
    --max-mirrors)
      require_value "$@"
      if ! [[ "$2" =~ ^[1-9][0-9]*$ ]]; then
        echo "--max-mirrors requires a positive integer, got: $2" >&2
        exit 1
      fi
      MAX_MIRRORS="$2"
      shift 2
      ;;
    --no-apply)
      APPLY=0
      shift
      ;;
    --version)
      echo "$SCRIPT_VERSION"
      exit 0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown parameter: $1" >&2
      exit 1
      ;;
  esac
done

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing command: $1" >&2
    exit 1
  }
}

for cmd in curl awk sed grep sort timeout mktemp wc head tail cut tr; do
  require_cmd "$cmd"
done

if ! command -v ping >/dev/null 2>&1; then
  echo "Warning: ping not found, ping tests will be skipped." >&2
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# Cloudflare's trace endpoint is tried first: dedicated geo-IP services are
# often on DNS blocklists (Pi-hole etc.), cloudflare.com rarely is.
detect_country() {
  local url cc
  for url in "https://www.cloudflare.com/cdn-cgi/trace" "https://1.1.1.1/cdn-cgi/trace"; do
    cc="$(curl -fsS --connect-timeout "$CONNECT_TIMEOUT" --max-time 10 "$url" 2>/dev/null \
      | awk -F= '/^loc=/ { print $2; exit }' | tr -d '[:space:]')" || continue
    if [[ "$cc" =~ ^[A-Za-z]{2}$ ]]; then
      printf '%s' "$cc" | tr '[:lower:]' '[:upper:]'
      return 0
    fi
  done

  for url in "https://ipapi.co/country/" "https://ipinfo.io/country"; do
    cc="$(curl -fsS --connect-timeout "$CONNECT_TIMEOUT" --max-time 10 "$url" 2>/dev/null \
      | tr -d '[:space:]')" || continue
    if [[ "$cc" =~ ^[A-Za-z]{2}$ ]]; then
      printf '%s' "$cc" | tr '[:lower:]' '[:upper:]'
      return 0
    fi
  done

  return 1
}

fetch_mirrorlist() {
  local out="$WORKDIR/Mirrors.masterlist"
  curl -fsSL --connect-timeout "$CONNECT_TIMEOUT" --max-time 60 \
    "$MIRRORLIST_URL" -o "$out" || return 1
  [[ -s "$out" ]] || return 1
  printf '%s' "$out"
}

# Prints "host<TAB>path" for every mirror in the given country that serves
# the archive over http for the requested architecture.
parse_mirrors() {
  local list="$1"
  awk -v country="$COUNTRY" -v arch="$ARCH" '
    BEGIN { RS = ""; FS = "\n" }
    {
      site = ""; cc = ""; path = ""; archs = ""
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^Site: /)                      { site = substr($i, 7) }
        else if ($i ~ /^Country: /)              { cc = substr($i, 10, 2) }
        else if ($i ~ /^Archive-http: /)         { path = substr($i, 15) }
        else if ($i ~ /^Archive-architecture: /) { archs = substr($i, 23) }
      }
      if (site != "" && cc == country && path != "") {
        if (archs == "" || index(" " archs " ", " " arch " ") > 0) {
          print site "\t" path
        }
      }
    }
  ' "$list"
}

is_number() {
  [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

format_score() {
  local x="${1:-}"
  x="${x//$'\r'/}"
  x="${x/,/.}"
  if ! is_number "$x"; then
    printf "N/A"
    return
  fi
  awk -v x="$x" 'BEGIN { printf "%.0f", x }'
}

format_ms() {
  local x="${1:-}"
  x="${x/,/.}"
  if ! is_number "$x"; then
    printf "N/A"
    return
  fi
  awk -v x="$x" 'BEGIN { printf "%.1f ms", x }'
}

format_s() {
  local x="${1:-}"
  x="${x/,/.}"
  if ! is_number "$x"; then
    printf "N/A"
    return
  fi
  awk -v x="$x" 'BEGIN { printf "%.3f s", x }'
}

human_speed() {
  local b="${1:-}"
  b="${b/,/.}"
  if ! is_number "$b"; then
    printf "N/A"
    return
  fi
  awk -v b="$b" 'BEGIN {
    split("B/s KiB/s MiB/s GiB/s", u, " ");
    i=1;
    while (b >= 1024 && i < 4) {
      b /= 1024;
      i++
    }
    printf "%.2f %s", b, u[i];
  }'
}

median_of_file() {
  local file="$1"

  if [[ ! -s "$file" ]]; then
    echo "NA"
    return
  fi

  local sorted_file count
  sorted_file="$(mktemp "${WORKDIR}/median.XXXXXX")"

  grep -E '^[0-9]+([.][0-9]+)?$' "$file" | sort -n > "$sorted_file" || true
  count="$(wc -l < "$sorted_file" | tr -d '[:space:]')"

  if [[ -z "$count" || "$count" -eq 0 ]]; then
    rm -f "$sorted_file"
    echo "NA"
    return
  fi

  if (( count % 2 == 1 )); then
    sed -n "$(( (count + 1) / 2 ))p" "$sorted_file"
  else
    local mid1 mid2 v1 v2
    mid1=$(( count / 2 ))
    mid2=$(( mid1 + 1 ))
    v1="$(sed -n "${mid1}p" "$sorted_file")"
    v2="$(sed -n "${mid2}p" "$sorted_file")"
    awk -v a="$v1" -v b="$v2" 'BEGIN { printf "%.6f\n", (a + b) / 2 }'
  fi

  rm -f "$sorted_file"
}

pick_scheme() {
  local host="$1"
  local path="$2"

  if curl -fL -o /dev/null -sS --connect-timeout "$CONNECT_TIMEOUT" --max-time 10 \
    "https://${host}${path}" >/dev/null 2>&1; then
    printf "https"
    return 0
  fi

  if curl -fL -o /dev/null -sS --connect-timeout "$CONNECT_TIMEOUT" --max-time 10 \
    "http://${host}${path}" >/dev/null 2>&1; then
    printf "http"
    return 0
  fi

  return 1
}

pick_large_file() {
  local base="$1"

  local candidates=(
    "${base}dists/${SUITE}/main/Contents-${ARCH}.gz"
    "${base}dists/${SUITE}/Contents-all.gz"
    "${base}dists/${SUITE}/main/binary-${ARCH}/Packages.xz"
    "${base}dists/${SUITE}/main/binary-${ARCH}/Packages.gz"
  )

  local url
  for url in "${candidates[@]}"; do
    if curl -L -sS --connect-timeout "$CONNECT_TIMEOUT" --max-time 10 -I "$url" 2>/dev/null \
      | grep -qE '^HTTP/[0-9.]+ 200'; then
      printf "%s\n" "$url"
      return 0
    fi
  done

  return 1
}

pick_small_file() {
  local base="$1"

  local candidates=(
    "${base}dists/${SUITE}/Release"
    "${base}dists/${SUITE}/main/binary-${ARCH}/Packages.gz"
    "${base}dists/${SUITE}/main/binary-${ARCH}/Packages.xz"
  )

  local url
  for url in "${candidates[@]}"; do
    if curl -L -sS --connect-timeout "$CONNECT_TIMEOUT" --max-time 10 -I "$url" 2>/dev/null \
      | grep -qE '^HTTP/[0-9.]+ 200'; then
      printf "%s\n" "$url"
      return 0
    fi
  done

  return 1
}

ping_stats() {
  local host="$1"

  if ! command -v ping >/dev/null 2>&1; then
    echo "NA NA"
    return
  fi

  local out loss avg
  if ! out="$(timeout 10 ping -c "$PING_COUNT" -n "$host" 2>/dev/null)"; then
    echo "NA NA"
    return
  fi

  loss="$(printf '%s\n' "$out" | awk -F', ' '/packet loss/ {gsub(/% packet loss/,"",$3); print $3; exit}')"
  avg="$(printf '%s\n' "$out" | awk -F'=' '/min\/avg\/max/ {gsub(/ ms/, "", $2); split($2, a, "/"); print a[2]; exit}')"

  echo "${loss:-NA} ${avg:-NA}"
}

curl_timing() {
  local url="$1"
  local out

  out="$(
    curl -L -o /dev/null -sS \
      --connect-timeout "$CONNECT_TIMEOUT" \
      --max-time "$MAX_TIME" \
      -w '%{time_starttransfer}\t%{time_total}\t%{speed_download}\t%{http_code}\n' \
      "$url" 2>/dev/null
  )" || {
    printf 'NA\tNA\tNA\t000\n'
    return
  }

  printf '%s\n' "${out//$'\r'/}"
}

score_mirror() {
  local loss="${1:-NA}"
  local avg_ping="${2:-NA}"
  local ttfb="${3:-NA}"
  local total="${4:-NA}"
  local speed="${5:-NA}"
  local ok="${6:-0}"
  local scheme="${7:-http}"

  loss="${loss/,/.}"
  avg_ping="${avg_ping/,/.}"
  ttfb="${ttfb/,/.}"
  total="${total/,/.}"
  speed="${speed/,/.}"

  awk -v loss="$loss" -v ping="$avg_ping" -v ttfb="$ttfb" -v total="$total" -v speed="$speed" -v ok="$ok" -v scheme="$scheme" '
    function isnum(x) { return (x ~ /^[0-9]+([.][0-9]+)?$/) }
    BEGIN {
      if (ok != 1) {
        print "0"
        exit
      }

      score = 0

      if (isnum(loss)) score += (100 - loss) * 2
      else score += 60

      if (isnum(ping)) {
        if (ping < 3) score += 80
        else if (ping < 5) score += 70
        else if (ping < 10) score += 55
        else if (ping < 20) score += 40
        else score += 15
      } else {
        score += 20
      }

      if (isnum(ttfb)) {
        if (ttfb < 0.02) score += 110
        else if (ttfb < 0.05) score += 95
        else if (ttfb < 0.10) score += 75
        else if (ttfb < 0.20) score += 50
        else score += 15
      }

      if (isnum(total)) {
        if (total < 0.20) score += 90
        else if (total < 0.35) score += 75
        else if (total < 0.60) score += 55
        else if (total < 1.00) score += 35
        else if (total < 2.00) score += 15
        else score += 5
      }

      if (isnum(speed)) {
        if (speed > 120000000) score += 260
        else if (speed > 90000000) score += 230
        else if (speed > 70000000) score += 205
        else if (speed > 50000000) score += 175
        else if (speed > 30000000) score += 135
        else if (speed > 15000000) score += 90
        else if (speed > 5000000) score += 45
        else if (speed > 1000000) score += 20
        else score += 5
      }

      if (scheme == "https") score += 5

      printf "%.2f\n", score
    }'
}

is_local_mirror() {
  [[ "$1" != "$GLOBAL_MIRROR" ]]
}

measure_mirror() {
  local host="$1"
  local path="$2"
  local result_dir="$WORKDIR/$host"
  mkdir -p "$result_dir"

  local scheme base small_url large_url
  if ! scheme="$(pick_scheme "$host" "${path}dists/${SUITE}/Release")"; then
    printf '0\t%s\tNA\tNA\tNA\tNA\tNA\tNA\n' "$host"
    return
  fi

  base="${scheme}://${host}${path}"

  if ! small_url="$(pick_small_file "$base")"; then
    printf '0\t%s\tNA\tNA\tNA\tNA\tNA\t%s\n' "$host" "$base"
    return
  fi

  if ! large_url="$(pick_large_file "$base")"; then
    printf '0\t%s\tNA\tNA\tNA\tNA\tNA\t%s\n' "$host" "$base"
    return
  fi

  local loss pavg
  read -r loss pavg < <(ping_stats "$host")

  local i
  for ((i=1; i<=RUNS; i++)); do
    curl_timing "$small_url" > "$result_dir/small_$i.txt"
    curl_timing "$large_url" > "$result_dir/large_$i.txt"
  done

  : > "$result_dir/ttfb.txt"
  : > "$result_dir/total.txt"
  : > "$result_dir/speed.txt"

  local f
  for f in "$result_dir"/small_*.txt; do
    [[ -f "$f" ]] || continue
    awk -F'\t' '$1 ~ /^[0-9.]+$/ {print $1}' "$f" >> "$result_dir/ttfb.txt"
  done

  for f in "$result_dir"/large_*.txt; do
    [[ -f "$f" ]] || continue
    awk -F'\t' '$2 ~ /^[0-9.]+$/ {print $2}' "$f" >> "$result_dir/total.txt"
    awk -F'\t' '$3 ~ /^[0-9.]+$/ {print $3}' "$f" >> "$result_dir/speed.txt"
  done

  local mttfb mtotal mspeed
  mttfb="$(median_of_file "$result_dir/ttfb.txt")"
  mtotal="$(median_of_file "$result_dir/total.txt")"
  mspeed="$(median_of_file "$result_dir/speed.txt")"

  local ok=0
  if awk -F'\t' '$4 == "200" { found = 1 } END { exit !found }' "$result_dir"/small_*.txt \
    && awk -F'\t' '$4 == "200" { found = 1 } END { exit !found }' "$result_dir"/large_*.txt; then
    ok=1
  fi

  local score
  score="$(score_mirror "$loss" "$pavg" "$mttfb" "$mtotal" "$mspeed" "$ok" "$scheme")"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$score" \
    "$host" \
    "$loss" \
    "$pavg" \
    "$mttfb" \
    "$mtotal" \
    "$mspeed" \
    "$base"
}

if [[ -z "$COUNTRY" ]]; then
  echo "Detecting country from public IP..." >&2
  if ! COUNTRY="$(detect_country)"; then
    echo "Could not detect country. Use --country XX to set it manually." >&2
    exit 1
  fi
  echo "Detected country: $COUNTRY" >&2
fi

echo "Fetching Debian mirror list..." >&2
if ! MIRRORLIST="$(fetch_mirrorlist)"; then
  echo "Could not fetch mirror list from $MIRRORLIST_URL" >&2
  exit 1
fi

MIRRORS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && MIRRORS+=("$line")
done < <(parse_mirrors "$MIRRORLIST")

TOTAL_FOUND="${#MIRRORS[@]}"
if (( TOTAL_FOUND == 0 )); then
  echo "No registered Debian mirrors found for country ${COUNTRY} (arch ${ARCH})." >&2
  echo "Testing only the global CDN ${GLOBAL_MIRROR}." >&2
elif (( TOTAL_FOUND > MAX_MIRRORS )); then
  echo "Found ${TOTAL_FOUND} mirrors in ${COUNTRY}, testing the first ${MAX_MIRRORS} (raise with --max-mirrors)." >&2
  MIRRORS=("${MIRRORS[@]:0:MAX_MIRRORS}")
else
  echo "Found ${TOTAL_FOUND} mirrors in ${COUNTRY}." >&2
fi

MIRRORS+=("${GLOBAL_MIRROR}"$'\t'"${GLOBAL_PATH}")

RESULTS="$WORKDIR/results.tsv"
: > "$RESULTS"

echo "Testing Debian mirrors for country=${COUNTRY}, suite=${SUITE}, arch=${ARCH}, runs=${RUNS}..." >&2
echo "TTFB is measured with a smaller file, throughput with a larger file." >&2
echo >&2

for entry in "${MIRRORS[@]}"; do
  host="${entry%%$'\t'*}"
  path="${entry#*$'\t'}"
  echo "Testing $host ..." >&2
  measure_mirror "$host" "$path" >> "$RESULTS"
done

SORTED="$WORKDIR/sorted.tsv"
sort -t$'\t' -k1,1nr -k7,7nr -k5,5n "$RESULTS" > "$SORTED"

echo
printf "%-4s %-6s %-31s %-10s %-10s %-15s\n" \
  "RANK" "SCORE" "HOST" "PING" "TTFB" "SPEED"
printf "%s\n" "--------------------------------------------------------------------------------"

rank=1
while IFS=$'\t' read -r score host loss avg ttfb total speed base; do
  marker=""
  if [[ "$rank" -eq 1 ]] && awk -v s="$score" 'BEGIN { exit (s + 0 > 0) ? 0 : 1 }'; then
    marker=" <<< BEST"
  fi

  printf "%-4s %-6s %-31s %-10s %-10s %-15s%s\n" \
    "$rank" \
    "$(format_score "$score")" \
    "$host" \
    "$(format_ms "$avg")" \
    "$(format_s "$ttfb")" \
    "$(human_speed "$speed")" \
    "$marker"

  rank=$((rank + 1))
done < "$SORTED"

score_is_positive() {
  awk -v s="${1:-0}" 'BEGIN { exit (s + 0 > 0) ? 0 : 1 }'
}

BEST_LINE=""
BEST_LOCAL_LINE=""
while IFS= read -r line; do
  score="$(printf '%s\n' "$line" | cut -f1)"
  score_is_positive "$score" || continue

  if [[ -z "$BEST_LINE" ]]; then
    BEST_LINE="$line"
  fi

  host="$(printf '%s\n' "$line" | cut -f2)"
  if [[ -z "$BEST_LOCAL_LINE" ]] && is_local_mirror "$host"; then
    BEST_LOCAL_LINE="$line"
  fi

  [[ -n "$BEST_LINE" && -n "$BEST_LOCAL_LINE" ]] && break
done < "$SORTED"

if [[ -z "$BEST_LINE" ]]; then
  echo
  echo "No mirror responded successfully - no recommendation." >&2
  echo "Check the suite name (--suite ${SUITE}) and your network connection." >&2
  exit 1
fi

BEST_HOST="$(printf '%s\n' "$BEST_LINE" | cut -f2)"
BEST_BASE="$(printf '%s\n' "$BEST_LINE" | cut -f8)"

echo
echo "Recommendation:"
echo "Best overall:"
echo "  $BEST_HOST"
echo "  deb ${BEST_BASE%/} ${SUITE} main contrib non-free non-free-firmware"

if [[ -n "$BEST_LOCAL_LINE" ]]; then
  BEST_LOCAL_HOST="$(printf '%s\n' "$BEST_LOCAL_LINE" | cut -f2)"
  BEST_LOCAL_BASE="$(printf '%s\n' "$BEST_LOCAL_LINE" | cut -f8)"
  echo
  echo "Best local mirror (${COUNTRY}):"
  echo "  $BEST_LOCAL_HOST"
  echo "  deb ${BEST_LOCAL_BASE%/} ${SUITE} main contrib non-free non-free-firmware"
fi

# --- Optionally apply the chosen mirror to the APT sources -------------------

SOURCES_LIST="${APT_PREFIX}/etc/apt/sources.list"
DEB822_SOURCES="${APT_PREFIX}/etc/apt/sources.list.d/debian.sources"

# Backups must not live in sources.list.d - APT scans that directory and
# prints an "invalid filename extension" notice on every run. They are
# kept in a backups/ folder next to the script instead.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || pwd)"
BACKUP_DIR="${SCRIPT_DIR}/backups"

backup_file() {
  local file="$1"
  local backup
  mkdir -p "$BACKUP_DIR"
  backup="${BACKUP_DIR}/$(basename "$file").bak_$(date +%Y%m%d_%H%M%S)"
  cp -p "$file" "$backup"
  printf '%s' "$backup"

  # Keep only the newest MAX_BACKUPS backups per file.
  ls -1t "${BACKUP_DIR}/$(basename "$file").bak_"* 2>/dev/null \
    | tail -n +"$(( MAX_BACKUPS + 1 ))" \
    | while IFS= read -r old; do rm -f "$old"; done
}

# All Site: hosts in the masterlist that serve the archive, any country.
# Used to tell Debian archive lines apart from third-party repos.
known_mirror_hosts() {
  local out="$WORKDIR/known_hosts.txt"
  awk '
    BEGIN { RS = ""; FS = "\n" }
    {
      site = ""; path = ""
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^Site: /)              { site = substr($i, 7) }
        else if ($i ~ /^Archive-http: /) { path = substr($i, 15) }
      }
      if (site != "" && path != "") print site
    }
  ' "$MIRRORLIST" > "$out"
  printf '%s' "$out"
}

# Rewrites archive mirror URLs in a classic sources.list. A line is only
# rewritten if its host is a registered Debian mirror, a *.debian.org name,
# or serves from the path /debian (typical for delisted mirrors). Third-party
# repos (docker etc.) and security.debian.org are left untouched.
update_classic_sources() {
  local file="$1"
  local base="$2"
  local known
  known="$(known_mirror_hosts)"
  local tmp
  tmp="$(mktemp "${WORKDIR}/sources.XXXXXX")"

  awk -v base="${base%/}" -v knownfile="$known" '
    BEGIN {
      while ((getline h < knownfile) > 0) K[h] = 1
      close(knownfile)
    }
    function is_archive_url(url,    rest, slash, host, path) {
      if (url !~ /^https?:\/\//) return 0
      rest = url
      sub(/^https?:\/\//, "", rest)
      slash = index(rest, "/")
      if (slash == 0) { host = rest; path = "" }
      else { host = substr(rest, 1, slash - 1); path = substr(rest, slash) }
      if (host == "security.debian.org") return 0
      if (host in K) return 1
      if (host ~ /\.debian\.org$/) return 1
      if (path == "/debian" || path == "/debian/") return 1
      return 0
    }
    /^[[:space:]]*deb(-src)?([[:space:]]|\[)/ {
      for (i = 1; i <= NF; i++) {
        if (is_archive_url($i)) {
          $i = base
          break
        }
      }
    }
    { print }
  ' "$file" > "$tmp"

  if cmp -s "$file" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi

  cat "$tmp" > "$file"
  rm -f "$tmp"
}

# Rewrites URIs in a deb822 debian.sources. Stanzas mentioning security
# are left untouched.
update_deb822_sources() {
  local file="$1"
  local base="$2"
  local tmp
  tmp="$(mktemp "${WORKDIR}/deb822.XXXXXX")"

  awk -v base="${base%/}" '
    BEGIN { RS = ""; FS = "\n"; OFS = "\n" }
    {
      if (NR > 1) printf "\n"
      if ($0 ~ /security\.debian\.org/ || $0 ~ /Suites:[^\n]*-security/) {
        print $0
        next
      }
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^URIs:/) $i = "URIs: " base
      }
      print $0
    }
  ' "$file" > "$tmp"

  if cmp -s "$file" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi

  cat "$tmp" > "$file"
  rm -f "$tmp"
}

apply_mirror() {
  local base="$1"
  local host="$2"

  # Validate the mirror once more right before touching anything.
  if ! curl -fsSL -o /dev/null --connect-timeout "$CONNECT_TIMEOUT" --max-time 15 \
    "${base%/}/dists/${SUITE}/Release"; then
    echo "Validation failed: ${base%/}/dists/${SUITE}/Release is not reachable. Aborting." >&2
    return 1
  fi

  local -a changed_files=()
  local -a backups=()
  local backup

  if [[ -f "$DEB822_SOURCES" ]] && grep -q '^URIs:' "$DEB822_SOURCES"; then
    backup="$(backup_file "$DEB822_SOURCES")"
    if update_deb822_sources "$DEB822_SOURCES" "$base"; then
      changed_files+=("$DEB822_SOURCES")
      backups+=("$backup")
      echo "Updated $DEB822_SOURCES (backup: $backup)"
    else
      rm -f "$backup"
      echo "$DEB822_SOURCES already uses this mirror, no change."
    fi
  fi

  if [[ -f "$SOURCES_LIST" ]] && grep -qE '^[[:space:]]*deb(-src)?([[:space:]]|\[)' "$SOURCES_LIST"; then
    backup="$(backup_file "$SOURCES_LIST")"
    if update_classic_sources "$SOURCES_LIST" "$base"; then
      changed_files+=("$SOURCES_LIST")
      backups+=("$backup")
      echo "Updated $SOURCES_LIST (backup: $backup)"
    else
      rm -f "$backup"
      echo "$SOURCES_LIST already uses this mirror, no change."
    fi
  fi

  if [[ ! -f "$DEB822_SOURCES" && ! -f "$SOURCES_LIST" ]]; then
    echo "No APT sources found ($SOURCES_LIST or $DEB822_SOURCES). Nothing to update." >&2
    return 1
  fi

  if (( ${#changed_files[@]} == 0 )); then
    return 0
  fi

  if ! command -v apt-get >/dev/null 2>&1; then
    echo "apt-get not available - skipping verification (test mode)."
    return 0
  fi

  echo "Running apt-get update to verify the new sources..."
  if apt-get update; then
    echo
    echo "Done. APT now uses ${host}."
    return 0
  fi

  echo "apt-get update failed - restoring previous sources." >&2
  local i
  for i in "${!changed_files[@]}"; do
    cat "${backups[$i]}" > "${changed_files[$i]}"
    echo "Restored ${changed_files[$i]} from ${backups[$i]}" >&2
  done
  return 1
}

offer_apply() {
  (( APPLY == 1 )) || return 0

  # Interactive part needs a terminal; skip silently in pipes/cron.
  if ! { true < /dev/tty; } 2>/dev/null; then
    return 0
  fi

  if ! command -v apt-get >/dev/null 2>&1 && [[ -z "$APT_PREFIX" ]]; then
    return 0
  fi

  if [[ "$(id -u)" -ne 0 && -z "$APT_PREFIX" ]]; then
    echo
    echo "Note: not running as root - rerun with sudo to be able to update the APT sources."
    return 0
  fi

  local total
  total="$(wc -l < "$SORTED" | tr -d '[:space:]')"

  echo
  printf "Update APT sources to a mirror? Enter RANK [1-%s] or press Enter to skip: " "$total"

  local choice
  read -r choice < /dev/tty

  if [[ -z "$choice" ]]; then
    echo "Skipped."
    return 0
  fi

  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > total )); then
    echo "Invalid choice: $choice - skipping." >&2
    return 0
  fi

  local line score host base
  line="$(sed -n "${choice}p" "$SORTED")"
  score="$(printf '%s\n' "$line" | cut -f1)"
  host="$(printf '%s\n' "$line" | cut -f2)"
  base="$(printf '%s\n' "$line" | cut -f8)"

  if ! score_is_positive "$score" || [[ "$base" == "NA" ]]; then
    echo "Mirror ${host} did not respond during the benchmark - refusing to apply it." >&2
    return 1
  fi

  echo "Applying ${host} (${base%/}) ..."
  apply_mirror "$base" "$host"
}

offer_apply
