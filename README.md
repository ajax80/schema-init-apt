# schema-init apt repository

Signed apt repo for [schema-init](https://github.com/ajax80/schema-init), built
by CI and served from https://ajax80.github.io/schema-init-apt.

- `stable`: tagged releases
- `dev`: every master commit (newest 10 per arch kept)

Architectures: `armhf` (ARMv6, every Raspberry Pi including Zero/1), `arm64`,
`amd64`. On amd64 it is packages only: `schema-pi` is for Raspberry Pi.

## Install

Signing key fingerprint: `3ABC 17E5 9514 3A99 E5F2  4246 62CB 71B0 B40C 9EF8`

```sh
sudo curl -fsSLo /usr/share/keyrings/schema-init-archive-keyring.gpg \
    https://ajax80.github.io/schema-init-apt/schema-init-archive-keyring.gpg
gpg --show-keys /usr/share/keyrings/schema-init-archive-keyring.gpg   # check the fingerprint
```

`/etc/apt/sources.list.d/schema-init.sources` (use `Suites: stable` for releases):

```
Types: deb
URIs: https://ajax80.github.io/schema-init-apt
Suites: dev
Components: main
Signed-By: /usr/share/keyrings/schema-init-archive-keyring.gpg
```

```sh
sudo apt update
sudo apt install schema-init
sudo schema-pi enable    # Raspberry Pi: opt in to schema-init as PID 1
```

Installing the package never changes PID 1; `schema-pi disable` reverts.

Publishes run one at a time. A queued publish that a newer one cancelled is
recovered by re-dispatching it: `gh workflow run publish.yml -f run_id=<deb.yml run id> -f channel=<dev|stable>`.
