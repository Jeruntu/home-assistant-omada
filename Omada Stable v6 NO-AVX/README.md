# Home Assistant Omada Add-On v6 (No-AVX)

This add-on brings the Omada Controller v6 directly into Home Assistant.

**This is a special variant compiled with a MongoDB binary that does NOT require AVX instructions.**
This allows running Omada Controller v6 on older CPUs (like older Celerons, Pentiums, or some Xeons) that are otherwise incompatible with the standard MongoDB 5.0+ required by Omada v6.

## Compatibility

- **Supported:** x86_64 (amd64) CPUs without AVX support.
- **Also Supported:** Standard x86_64 CPUs (it works, but is slightly less optimized than the standard add-on).
- **ARM64:** This add-on also supports ARM64 (using the standard MongoDB binary, as ARM does not use AVX).

## Contribution

This add-on is a fork of Matt Bentleys
[docker-omada-controller](https://github.com/mbentley/docker-omada-controller)
and jkunczik [home-assistant-omada](https://github.com/jkunczik/home-assistant-omada).
It incorporates the No-AVX MongoDB build from [fenio/omada-controller-no-avx](https://github.com/fenio/omada-controller-no-avx).

Other than in the original docker omada controller,
this add-on stores all persistent data in the /data directory,
so that it is compatible with Home Assistant.

Pull requests for version updates or new features are always more than welcome.
