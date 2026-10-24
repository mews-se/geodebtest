# geodebtest

![Version](https://img.shields.io/badge/version-v2026.09.18-informational)
[![ShellCheck](https://github.com/mews-se/geodebtest/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/mews-se/geodebtest/actions/workflows/shellcheck.yml)
![Shell: Bash](https://img.shields.io/badge/shell-bash-4EAA25.svg?logo=gnubash&logoColor=white)
![Platform: Debian based](https://img.shields.io/badge/platform-Debian%20based-A81D33.svg?logo=debian&logoColor=white)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Benchmark tool for Debian mirrors in your own country. Autodetects your
location, fetches the official mirror list and finds the fastest mirrors
near you.

## Features

- Autodetects your country from your public IP (override with `--country`)
- Fetches the current official mirror list from Debian (no hardcoded mirrors)
- Verifies architecture support against each mirror instead of trusting the
  mirror list metadata (which is often stale)
- Includes the official country alias `ftp.<cc>.debian.org` even when the
  mirror list omits it
- Measures ping, TTFB and download speed
- Ranks mirrors from best to worst
- Always includes the global CDN (`deb.debian.org`) as baseline
- Shows best overall and best local mirror, as `sources.list` lines
- Can apply the mirror you pick straight to your APT sources (see below)
- Warns when any APT source still references another Debian release than
  the running system (easy to miss after a release upgrade)

## Usage

```bash
git clone https://github.com/mews-se/geodebtest.git
cd geodebtest
./geodebtest.sh
```

All options, as `--help` lists them:

```
./geodebtest.sh [--country SE] [--suite stable] [--arch amd64] [--runs 3] [--max-mirrors 10] [--no-apply] [--version]
```

The suite, run count and mirror cap shown are the defaults; without `--arch`
and `--country` the script uses the system's own architecture and the detected
country. For example:

```bash
./geodebtest.sh --country DE
./geodebtest.sh --suite bookworm --runs 5
./geodebtest.sh --max-mirrors 20
```

## Example output

```
RANK SCORE  HOST                            PING       TTFB       SPEED
--------------------------------------------------------------------------------
1    700    deb.debian.org                  1.9 ms     0.016 s    106.43 MiB/s    <<< BEST
2    630    mirror.netcologne.de            4.6 ms     0.024 s    81.87 MiB/s
3    580    ftp.de.debian.org               7.3 ms     0.031 s    58.71 MiB/s

Recommendation:
Best overall:
  deb.debian.org
  deb https://deb.debian.org/debian stable main contrib non-free non-free-firmware

Best local mirror (DE):
  mirror.netcologne.de
  deb https://mirror.netcologne.de/debian stable main contrib non-free non-free-firmware

Suite consistency check (system: trixie):
  OK - no APT source references another Debian release.
```

## Applying a mirror

When run as root on a Debian system, the script offers to update your APT
sources after the benchmark: enter the RANK number of the mirror you want,
or press Enter to skip. Use `--no-apply` to disable the prompt entirely
(the prompt is also skipped automatically when there is no terminal, e.g.
in cron). Without root the script says so before the benchmark starts, so
you can rerun it with `sudo` right away instead of finding out at the end.

What it does:

- Updates `/etc/apt/sources.list` and `/etc/apt/sources.list.d/debian.sources`
  (whichever exist), replacing only Debian archive mirrors;
  `security.debian.org` and third-party repos (Docker etc.) are never touched
- Takes a timestamped backup of each file first, stored in a `backups/`
  folder next to the script (the 5 newest per file are kept)
- Validates the mirror and runs `apt-get update`; if it fails, the previous
  sources are restored automatically

## Notes

- Country detection uses Cloudflare's trace endpoint (cloudflare.com and
  1.1.1.1) first, since the dedicated geo-IP services are often on DNS
  blocklists (Pi-hole etc.); ipapi.co and ipinfo.io are the fallbacks. Only
  your public IP is sent, nothing else.
- Mirror data comes from the official
  [Mirrors.masterlist](https://mirror-master.debian.org/status/Mirrors.masterlist).
- Countries with many mirrors are capped at 10 by default; raise with
  `--max-mirrors`.
- Needs bash, curl, awk, sed, grep and coreutils. `ping` is optional; without
  it the ping test is skipped.

## License

This project is licensed under the MIT License.
