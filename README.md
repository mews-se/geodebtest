# geodebtest

[![License: Unlicense](https://img.shields.io/badge/license-Unlicense-blue.svg)](http://unlicense.org/)
[![Bash](https://img.shields.io/badge/language-bash-green.svg)]()
[![Version](https://img.shields.io/badge/version-v2026.08.01-orange.svg)]()

Benchmark tool for Debian mirrors in your own country. A generalized
version of [swedebtest](https://github.com/mews-se/swedebtest) that works
anywhere.

## Features

- Autodetects your country from your public IP (override with `--country`)
- Fetches the current official mirror list from Debian (no hardcoded mirrors)
- Verifies architecture support against each mirror instead of trusting the
  mirror list metadata (which is often stale)
- Measures ping, TTFB and download speed
- Ranks mirrors from best to worst
- Always includes the global CDN (`deb.debian.org`) as baseline
- Shows best overall and best local mirror, as `sources.list` lines
- Can apply the mirror you pick straight to your APT sources (see below)
- Warns when any APT source still references another Debian release than
  the running system (easy to miss after a release upgrade)

## Usage

```bash
chmod +x geodebtest.sh
./geodebtest.sh
```

Optional:

```bash
./geodebtest.sh --country DE
./geodebtest.sh --suite bookworm --runs 5
./geodebtest.sh --max-mirrors 20
```

## Example output

```
RANK SCORE HOST                           PING      TTFB      SPEED
1    780   deb.debian.org                 1.0 ms    0.016 s   84.76 MiB/s

Recommendation:
Best overall:
  deb.debian.org
  deb https://deb.debian.org/debian stable main contrib non-free non-free-firmware
```

## Applying a mirror

When run as root on a Debian system, the script offers to update your APT
sources after the benchmark: enter the RANK number of the mirror you want,
or press Enter to skip. Use `--no-apply` to disable the prompt entirely
(the prompt is also skipped automatically when there is no terminal, e.g.
in cron).

What it does:

- Updates `/etc/apt/sources.list` and `/etc/apt/sources.list.d/debian.sources`
  (whichever exist), replacing only Debian archive mirrors -
  `security.debian.org` and third-party repos (Docker etc.) are never touched
- Takes a timestamped backup of each file first, stored in a `backups/`
  folder next to the script (the 5 newest per file are kept)
- Validates the mirror and runs `apt-get update`; if it fails, the previous
  sources are restored automatically

## Notes

- Country detection uses Cloudflare's trace endpoint (cloudflare.com and
  1.1.1.1), with ipapi.co and ipinfo.io as fallbacks - the dedicated
  geo-IP services are often on DNS blocklists (Pi-hole etc.). Only your
  public IP is sent, nothing else.
- Mirror data comes from the official
  [Mirrors.masterlist](https://mirror-master.debian.org/status/Mirrors.masterlist).
- Countries with many mirrors are capped at 10 by default; raise with
  `--max-mirrors`.

## License

This project is released under The Unlicense.
