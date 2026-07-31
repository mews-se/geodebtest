# geodebtest

[![License: Unlicense](https://img.shields.io/badge/license-Unlicense-blue.svg)](http://unlicense.org/)
[![Bash](https://img.shields.io/badge/language-bash-green.svg)]()
[![Version](https://img.shields.io/badge/version-v2026.07.31-orange.svg)]()

Benchmark tool for Debian mirrors in your own country. A generalized
version of [swedebtest](https://github.com/mews-se/swedebtest) that works
anywhere.

## Features

- Autodetects your country from your public IP (override with `--country`)
- Fetches the current official mirror list from Debian (no hardcoded mirrors)
- Measures ping, TTFB and download speed
- Ranks mirrors from best to worst
- Always includes the global CDN (`deb.debian.org`) as baseline
- Shows best overall and best local mirror, as `sources.list` lines

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

## Notes

- Country detection uses ipapi.co with ipinfo.io as fallback. Only your
  public IP is sent, nothing else.
- Mirror data comes from the official
  [Mirrors.masterlist](https://mirror-master.debian.org/status/Mirrors.masterlist).
- Countries with many mirrors are capped at 10 by default; raise with
  `--max-mirrors`.

## License

This project is released under The Unlicense.
