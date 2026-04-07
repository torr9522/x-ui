# x-ui2 mirror

This repository is a self-hosted mirror of the install/update assets needed by
the `x-ui` shell installer and management script.

Mirrored items in this repository:

- `install.sh`
- `x-ui.sh`
- `x-ui-linux-amd64.tar.gz`
- `x-ui-linux-arm64.tar.gz`
- `mirror-deps/geoip.dat`
- `mirror-deps/geosite.dat`
- `mirror-deps/bbr.sh`
- `mirror-deps/get.acme.sh`

The scripts in this repository have been rewritten to fetch updates and
dependencies from this repository instead of the original upstream locations.

Install from this mirror:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/torr9522/x-ui2/x-ui2/install.sh)
```
