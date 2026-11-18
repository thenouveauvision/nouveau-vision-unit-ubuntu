# Nouveau-Vision Unit for Ubuntu

Native Ubuntu distribution and installation tooling for **Nouveau-Vision Unit (NVU)**.

Run a complete Nouveau-Vision Unit node, wallet, and web Dashboard on Ubuntu using the signed NVU APT repository.

## Current Release

| Component | Version |
|---|---:|
| NVUN | 1.0.0 |
| NVU Dashboard | 1.3.0 |
| NVU Debian package | 1.0.0-2 |
| NVU repository bootstrap | 1.0.0-1 |
| Architecture | amd64 |
| Qualified platform | Ubuntu 26.04 LTS |

## Install Nouveau-Vision Unit

### 1. Add the NVU Repository

On a new Ubuntu system, download the small repository bootstrap package:

```bash
curl -fsSLo nvu-repository_latest_all.deb \
  https://apt.nvu.us/bootstrap/nvu-repository_latest_all.deb
```

Optional integrity verification:

```bash
sha256sum nvu-repository_latest_all.deb
```

Expected SHA-256:

```text
41437ae83bd7ea5519aae561989dd83da66955bac0af501e01aa278562f23991
```

Install the repository bootstrap:

```bash
sudo apt install ./nvu-repository_latest_all.deb
```

This is a **one-time setup**.

The bootstrap package installs the NVU signing key and signed APT repository configuration. It does not install or deploy the NVU node.

### 2. Install NVU

Once the repository is configured:

```bash
sudo apt update
sudo apt install nvu
```

### 3. Deploy the Node

Replace `node.example.com` with the fully qualified domain name assigned to your server:

```bash
sudo nvu install --fqdn node.example.com
```

The installer performs its own preflight checks and deploys the complete native NVU stack.

## That's It

For a new Ubuntu server, the complete workflow is:

```bash
curl -fsSLo nvu-repository_latest_all.deb \
  https://apt.nvu.us/bootstrap/nvu-repository_latest_all.deb

sudo apt install ./nvu-repository_latest_all.deb
sudo apt update
sudo apt install nvu
sudo nvu install --fqdn node.example.com
```

## Qualify Your Installation

NVU includes a read-only full-stack qualification command:

```bash
sudo nvu qualify --fqdn node.example.com
```

A successful deployment reports:

```text
Result:
  INSTALLED

Qualification:
  PASS
```

## What NVU Installs

A complete native installation includes:

- **NVUN 1.0.0**
- Nouveau-Vision Unit full node
- unnamed default wallet
- private-key-enabled wallet
- **NVU Dashboard 1.3.0**
- production Dashboard runtime
- Unix-socket backend
- Apache HTTP/HTTPS frontend
- TLS certificate configuration
- systemd services
- installation and qualification tooling

## Package and Runtime Separation

NVU deliberately separates software distribution from runtime deployment.

Installing the Debian package:

```bash
sudo apt install nvu
```

installs the NVU management and deployment tooling.

It does **not** automatically:

- create a node
- create a wallet
- create RPC credentials
- deploy the Dashboard
- modify existing blockchain state
- configure Apache
- request a TLS certificate

Runtime deployment happens only when the administrator explicitly runs:

```bash
sudo nvu install --fqdn node.example.com
```

This allows normal APT package management to remain separate from node, wallet, and blockchain state.

## Software Updates

After the repository bootstrap has been installed, NVU participates in normal Ubuntu package management.

Check for updates:

```bash
sudo apt update
apt-cache policy nvu
```

Install available system and NVU package updates through your normal APT workflow.

The repository bootstrap itself is also distributed through the signed NVU repository, allowing future repository-key and configuration updates to be delivered through APT.

## Signed APT Repository

Repository:

```text
https://apt.nvu.us/
```

Repository signing identity:

```text
Nouveau-Vision APT Archive Signing Key <apt@nvu.us>
```

Signing-key fingerprint:

```text
B682 3905 FE3E 1403 AB1C 5F71 BAAE 51F5 17C4 7227
```

Full fingerprint:

```text
B6823905FE3E1403AB1C5F71BAAE51F517C47227
```

Public-key SHA-256:

```text
932acc8b4b3f9e5830d0bec38031cdc7d489eeee9bde7e894e54b32aa13f9107
```

The repository uses a package-managed keyring with repository-specific `Signed-By` configuration.

## Qualified Package Artifacts

### NVU

```text
Package:      nvu
Version:      1.0.0-2
Architecture: amd64
```

SHA-256:

```text
4404e74e76d7f5fee54b72786e4d8a3459eb3e67c6cc39a4f4ca4d3cb05981ab
```

### Repository Bootstrap

```text
Package:      nvu-repository
Version:      1.0.0-1
Architecture: all
```

SHA-256:

```text
41437ae83bd7ea5519aae561989dd83da66955bac0af501e01aa278562f23991
```

## Source Layout

```text
installer/
├── bin/                 NVU management commands
├── lib/                 installation and qualification modules
├── payload/
│   ├── dashboard/       NVU Dashboard source
│   └── nvun/            qualified NVUN binary metadata
└── templates/           runtime configuration templates

packaging/
└── debian/              Debian package metadata

docs/                    installation and technical documentation
```

Qualified NVUN runtime binaries are intentionally excluded from ordinary Git history.

The qualified binaries are distributed through the signed NVU Debian package.

## Dashboard Architecture

The native NVU Dashboard runs behind a Unix socket:

```text
/run/nvu-dashboard/nvu-dashboard.sock
```

Apache provides the public HTTP/HTTPS frontend and proxies Dashboard requests to the Unix socket.

The production Dashboard does not require a TCP backend listener.

## Default NVUN Network Ports

```text
9332    Local RPC
9333    NVUN peer-to-peer network
9334    Auxiliary local listener
```

RPC is bound locally by the qualified native installation.

## Project Links

- **Nouveau-Vision Unit:** https://nvu.us/
- **Signed APT Repository:** https://apt.nvu.us/
- **Ubuntu Distribution:** https://github.com/thenouveauvision/nouveau-vision-unit-ubuntu
- **Umbrel Distribution:** https://github.com/thenouveauvision/nouveau-vision-unit-umbrel
- **Nouveau-Vision:** https://nouveau-vision.com/

## Repository Scope

This repository is the public source and documentation home for the **native Ubuntu distribution of Nouveau-Vision Unit**.

The signed binary distribution is maintained separately at:

```text
https://apt.nvu.us/
```

## Support

Project information, network resources, and installation documentation:

https://nvu.us/
