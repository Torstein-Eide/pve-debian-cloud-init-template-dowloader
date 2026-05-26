# Proxmox Debian Cloud-Init Template

Create Debian cloud-init templates for Proxmox VE from official Debian cloud images.

The script downloads a Debian cloud image, verifies its checksum, customizes it offline with `virt-customize`, imports it into Proxmox, attaches a cloud-init drive, and converts the VM into a template.

## Features

- Loads available Debian cloud images dynamically from the official Debian image index.
- Interactive Debian image and Proxmox storage selection.
- Optional image cache refresh.
- Installs `qemu-guest-agent`, `avahi-daemon`, `needrestart`, and `sudo` by default.
- Enables `qemu-guest-agent` and mDNS via `avahi-daemon` in the image.
- Copies local locale settings from the Proxmox host into the image when available.
- Uses `root` as the default cloud-init user.
- Optional disk resize before import.
- Optional overwrite of an existing VMID.

## Requirements

Run on a Proxmox VE host with these packages installed:

```bash
apt install -y wget ca-certificates libguestfs-tools qemu-utils
```

The script also requires Proxmox commands such as `qm` and `pvesm`.

## Usage

```bash
./create-debian-cloudinit-template.sh --vmid <id> [options]
```

Examples:

```bash
./create-debian-cloudinit-template.sh --codename trixie --vmid 9000 --name debian-13-template
./create-debian-cloudinit-template.sh --codename bookworm --vmid 9012 --storage local-lvm --disk-size 16G
./create-debian-cloudinit-template.sh --codename bullseye --vmid 9011 --packages qemu-guest-agent,avahi-daemon,needrestart,sudo,curl,vim
```

## Options

- `--vmid ID`: Proxmox VMID for the template. Required.
- `--codename NAME`: Debian codename from the dynamically fetched cloud image list. If omitted, the script asks interactively.
- `--name NAME`: VM/template name. Defaults to `debian-<version>-cloudinit-template`.
- `--storage STORAGE`: Proxmox storage target. If omitted, the script asks interactively.
- `--bridge BRIDGE`: Network bridge. Default: `vmbr0`.
- `--memory MB`: RAM in MB. Default: `512`.
- `--cores N`: CPU cores. Default: `2`.
- `--disk-size SIZE`: Resize image before import, for example `16G` or `32G`.
- `--packages LIST`: Comma-separated packages to install. Default: `qemu-guest-agent,avahi-daemon,needrestart,sudo`.
- `--refresh-images`: Refresh the cached Debian cloud image list.
- `--no-interactive`: Fail instead of asking for missing values.
- `--overwrite-existing`: Destroy an existing VM/template with the same VMID first.
- `--verbose`: Print extra fetch/debug details.

## Dynamic Image List

The script fetches available Debian cloud images from:

```text
https://cloud.debian.org/images/cloud/
```

It scans the Debian cloud image index for available release directories, then checks each release's `latest/` directory for a matching AMD64 QCOW2 cloud image.

For regular Debian releases, it looks for images like:

```text
debian-12-generic-amd64.qcow2
```

For Debian `sid`, it checks the daily image tree and selects the newest available daily image.

The discovered image list is cached in:

```text
/var/tmp/proxmox-debian-cloudinit/debian-cloud-images.tsv
```

Example out:

```text
==> Using cached Debian image list: /var/tmp/proxmox-debian-cloudinit/debian-cloud-images.tsv

Available Debian cloud images:

 1) bookworm     Debian 12
 2) bullseye     Debian 11
 3) buster       Debian 10
 4) sid          sid
 5) trixie       Debian 13

``` 

On later runs, the cached list is reused to avoid repeated network lookups. Use `--refresh-images` to force a fresh fetch.

The script filters out duplicate aliases such as numeric release directories, `stable`, `oldstable`, and `oldoldstable`, so the interactive menu shows each Debian release only once.

## Clone Example

After creating a template, clone and start a VM:

```bash
qm clone 9000 100 --name test-bookworm --full true
qm set 100 --sshkeys ~/.ssh/authorized_keys
qm start 100
```

## License

MIT. See [LICENSE](LICENSE).
