#!/usr/bin/env bash
set -euo pipefail

# create-debian-cloudinit-template.sh
#
# Example:
#   ./create-debian-cloudinit-template.sh --codename trixie --vmid 9000 --name debian-13-template
#   ./create-debian-cloudinit-template.sh --codename bookworm --vmid 9012 --storage local-lvm
#
# Requires:
#   apt install -y wget ca-certificates libguestfs-tools qemu-utils

CODENAME=""
VMID=""
NAME=""
STORAGE=""
BRIDGE="vmbr0"
MEMORY="512"
CORES="2"
DISK_SIZE=""
PACKAGES="qemu-guest-agent,avahi-daemon,needrestart,sudo"
CACHE_DIR="/var/cache/proxmox-debian-cloudinit"
WORKDIR="${CACHE_DIR}/work"

IMAGE_CACHE="${CACHE_DIR}/debian-cloud-images.tsv"
IMAGE_ALIAS_PATTERN='^([0-9]+|stable|oldstable|oldoldstable)$'
REFRESH_IMAGES="false"
INTERACTIVE="true"
OVERWRITE_EXISTING="false"
LIST_CACHE="false"
CLEANUP="false"
VERBOSE="false"


usage() {
    cat <<EOF
Usage:
  $0 --vmid <id> [options]
  $0 --list-cache [--refresh-images]

Required:
  --vmid ID                 Proxmox VMID for template

Options:
  --codename NAME           Debian codename from the fetched cloud image list
                            Default: ask interactively from available images

  --name NAME               VM/template name
                            Default: debian-<version>-cloudinit-template

  --storage STORAGE         Proxmox storage target
                            Default: ask interactively from active storages

  --bridge BRIDGE           Network bridge
                            Default: vmbr0

  --memory MB               RAM in MB
                            Default: 512

  --cores N                 CPU cores
                            Default: 2

  --disk-size SIZE          Resize image before import, e.g. 16G, 32G
                            Default: keep upstream image size

  --packages LIST           Comma-separated packages to install in image
                            Default: qemu-guest-agent,avahi-daemon,needrestart,sudo

   --refresh-images          Refresh cached Debian cloud image list

   --list-cache              Print cached Debian cloud image list and exit

   --cleanup                 Remove downloaded image work files after completion

   --no-interactive          Fail instead of asking if --codename is missing

   --overwrite-existing      Destroy existing VM/template with same VMID first

   --verbose                 Print extra fetch/debug details

Examples:
  $0 --codename trixie --vmid 9000 --name debian-13-template
  $0 --codename bookworm --vmid 9012 --storage local-lvm --disk-size 16G
  $0 --codename bullseye --vmid 9011 --packages qemu-guest-agent,avahi-daemon,needrestart,sudo,curl,vim
EOF
}

log_verbose() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo "[verbose] $*"
    fi
}

write_normalized_debian_image_list() {
    local source="$1"
    local target="$2"

    {
        awk -F'\t' -v alias_pattern="$IMAGE_ALIAS_PATTERN" '$1 !~ alias_pattern && $2 != "sid" { print }' "$source" | sort -t $'\t' -k2,2Vr
        awk -F'\t' -v alias_pattern="$IMAGE_ALIAS_PATTERN" '$1 !~ alias_pattern && $2 == "sid" { print }' "$source"
    } | awk -F'\t' '!seen[$2]++ { print }' > "$target"
}

list_cached_debian_images() {
    echo "Cached Debian cloud images: $IMAGE_CACHE"
    echo

    awk -F'\t' '{ printf "%-12s %-8s %s\n", $1, $2, $5 }' "$IMAGE_CACHE"
}

cleanup_workdir() {
    if [[ -d "$WORKDIR" ]]; then
        echo "==> Cleaning workdir: $WORKDIR"
        rm -rf "$WORKDIR"
    else
        echo "==> Workdir already clean: $WORKDIR"
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --codename) CODENAME="$2"; shift 2 ;;
        --vmid) VMID="$2"; shift 2 ;;
        --name) NAME="$2"; shift 2 ;;
        --storage) STORAGE="$2"; shift 2 ;;
        --bridge) BRIDGE="$2"; shift 2 ;;
        --memory) MEMORY="$2"; shift 2 ;;
        --cores) CORES="$2"; shift 2 ;;
        --disk-size) DISK_SIZE="$2"; shift 2 ;;
        --packages) PACKAGES="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        --refresh-images)
            REFRESH_IMAGES="true"
            shift
            ;;
        --no-interactive)
            INTERACTIVE="false"
            shift
            ;;
        --overwrite-existing)
            OVERWRITE_EXISTING="true"
            shift
            ;;
        --list-cache)
            LIST_CACHE="true"
            shift
            ;;
        --cleanup)
            CLEANUP="true"
            shift
            ;;
        --verbose)
            VERBOSE="true"
            shift
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage
            exit 1
            ;;
    esac
done

fetch_debian_cloud_image_list() {
    mkdir -p "$CACHE_DIR"

    if [[ -f "$IMAGE_CACHE" && "$REFRESH_IMAGES" != "true" ]]; then
        echo "==> Using cached Debian image list: $IMAGE_CACHE"
        return 0
    fi

    echo "==> Fetching Debian cloud image list"

    local tmp
    tmp="$(mktemp)"

    wget -qO- "https://cloud.debian.org/images/cloud/" |
        grep -oE 'href="[^"]+/"' |
        sed -E 's/href="([^"]+)\/"/\1/' |
        grep -Ev "^\.\.$|^current$|^daily$|^testing$|${IMAGE_ALIAS_PATTERN}" |
        while read -r codename; do
            local latest_url image version label daily_base daily_build_url
            log_verbose "Inspecting codename: $codename"

            if [[ "$codename" == "sid" ]]; then
                daily_base="https://cloud.debian.org/images/cloud/sid/daily/"
                log_verbose "sid mode: checking daily base: $daily_base"

                daily_build_url="$(
                    wget -qO- "$daily_base" 2>/dev/null |
                        grep -oE 'href="[0-9]{8}-[0-9]+/"' |
                        sed -E 's/href="([0-9]{8}-[0-9]+)\/"/\1/' |
                        sort -V |
                        tail -n1 || true
                )"
                log_verbose "sid mode: latest daily build id: ${daily_build_url:-<none>}"

                if [[ -n "$daily_build_url" ]]; then
                    latest_url="${daily_base}${daily_build_url}/"
                    log_verbose "sid mode: checking build URL: $latest_url"
                    image="$(
                        wget -qO- "$latest_url" 2>/dev/null |
                            grep -oE 'debian-sid-(generic|genericcloud)-amd64-daily-[0-9]{8}-[0-9]+\.qcow2' |
                            sort -V |
                            tail -n1 || true
                    )"

                    if [[ -z "$image" ]]; then
                        local sid_latest_url
                        sid_latest_url="${daily_base}latest/"
                        log_verbose "sid mode: fallback URL: $sid_latest_url"
                        latest_url="$sid_latest_url"
                        image="$(
                            wget -qO- "$latest_url" 2>/dev/null |
                                grep -oE 'debian-sid-(generic|genericcloud)-amd64-daily-[0-9]{8}-[0-9]+\.qcow2' |
                                sort -V |
                                tail -n1 || true
                        )"
                    fi
                else
                    latest_url=""
                    image=""
                fi
            else
                latest_url="https://cloud.debian.org/images/cloud/${codename}/latest/"
                log_verbose "stable mode: checking latest URL: $latest_url"
                image="$(
                    wget -qO- "$latest_url" 2>/dev/null |
                        grep -oE 'debian-[0-9]+-generic-amd64\.qcow2' |
                        sort -V |
                        tail -n1 || true
                )"
            fi

            log_verbose "codename=$codename picked image=${image:-<none>}"

            if [[ -n "$image" ]]; then
                if [[ "$codename" == "sid" ]]; then
                    version="sid"
                else
                    version="$(sed -E 's/^debian-([0-9]+)-generic-amd64\.qcow2$/\1/' <<< "$image")"
                fi

                if [[ "$version" == "sid" ]]; then
                    label="sid"
                else
                    label="Debian ${version}"
                fi

                printf '%s\t%s\t%s\t%s\t%s\n' \
                    "$codename" \
                    "$version" \
                    "$image" \
                    "$latest_url" \
                    "$label"
            fi
        done > "$tmp"

    write_normalized_debian_image_list "$tmp" "${tmp}.dedup"
    mv "${tmp}.dedup" "$tmp"

    if [[ ! -s "$tmp" ]]; then
        echo "ERROR: failed to fetch Debian cloud image list" >&2
        rm -f "$tmp"
        exit 1
    fi

    mv "$tmp" "$IMAGE_CACHE"
    chmod 0644 "$IMAGE_CACHE"
}

if [[ "$LIST_CACHE" == "true" ]]; then
    fetch_debian_cloud_image_list
    list_cached_debian_images
    exit 0
fi

if [[ -z "$VMID" ]]; then
    if [[ "$CLEANUP" == "true" ]]; then
        cleanup_workdir
        exit 0
    fi

    echo "ERROR: --vmid is required" >&2
    usage
    exit 1
fi

select_debian_codename() {
    if [[ -n "${CODENAME:-}" ]]; then
        return 0
    fi

    if [[ "$INTERACTIVE" != "true" ]]; then
        echo "ERROR: --codename is required when --no-interactive is used" >&2
        exit 1
    fi

    echo
    echo "Available Debian cloud images:"
    echo

    nl -w2 -s') ' < <(
        awk -F'\t' '{ printf "%-12s %s\n", $1, $5 }' "$IMAGE_CACHE"
    )

    echo
    read -rp "Select Debian image number: " choice

    if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
        echo "ERROR: invalid selection: $choice" >&2
        exit 1
    fi

    CODENAME="$(
        awk -F'\t' -v n="$choice" 'NR == n { print $1 }' "$IMAGE_CACHE"
    )"

    if [[ -z "$CODENAME" ]]; then
        echo "ERROR: selection out of range: $choice" >&2
        exit 1
    fi
}

select_storage() {
    if [[ -n "${STORAGE:-}" ]]; then
        return 0
    fi

    if [[ "$INTERACTIVE" != "true" ]]; then
        echo "ERROR: --storage is required when --no-interactive is used" >&2
        exit 1
    fi

    echo
    echo "Available active Proxmox storages:"
    echo

    local storage_rows
    storage_rows="$(pvesm status | awk 'NR>1 && $3 == "active" {print $1 "\t" $2 "\t" $4 "\t" $5 "\t" $6 "\t" $7}')"

    if [[ -z "$storage_rows" ]]; then
        echo "ERROR: no active storages found from: pvesm status" >&2
        exit 1
    fi

    nl -w2 -s') ' < <(
        awk -F'\t' '{ printf "%-16s type=%-8s used=%s%%\n", $1, $2, $6 }' <<< "$storage_rows"
    )

    echo
    read -rp "Select storage number: " storage_choice

    if ! [[ "$storage_choice" =~ ^[0-9]+$ ]]; then
        echo "ERROR: invalid selection: $storage_choice" >&2
        exit 1
    fi

    STORAGE="$(awk -F'\t' -v n="$storage_choice" 'NR == n { print $1 }' <<< "$storage_rows")"

    if [[ -z "$STORAGE" ]]; then
        echo "ERROR: selection out of range: $storage_choice" >&2
        exit 1
    fi

    echo "==> Selected storage: $STORAGE"
}


resolve_debian_image() {
    local row

    row="$(
        awk -F'\t' -v codename="$CODENAME" '$1 == codename { print; exit }' "$IMAGE_CACHE"
    )"

    if [[ -z "$row" && "$REFRESH_IMAGES" != "true" ]]; then
        log_verbose "Codename $CODENAME not found in cache, refreshing once"
        REFRESH_IMAGES="true"
        fetch_debian_cloud_image_list
        row="$(
            awk -F'\t' -v codename="$CODENAME" '$1 == codename { print; exit }' "$IMAGE_CACHE"
        )"
    fi

    if [[ -z "$row" ]]; then
        echo "ERROR: unsupported or unknown codename: $CODENAME" >&2
        echo >&2
        echo "Supported cached codenames:" >&2
        awk -F'\t' '{ printf "  %-12s %s\n", $1, $5 }' "$IMAGE_CACHE" >&2
        echo >&2
        echo "Try: $0 --refresh-images --codename $CODENAME ..." >&2
        exit 1
    fi

    DEBIAN_VERSION="$(cut -f2 <<< "$row")"
    IMAGE_NAME="$(cut -f3 <<< "$row")"
    BASE_URL="$(cut -f4 <<< "$row")"
    DEBIAN_LABEL="$(cut -f5 <<< "$row")"

    IMAGE_URL="${BASE_URL}${IMAGE_NAME}"
    SUMS_URL="${BASE_URL}SHA512SUMS"

    log_verbose "Resolved row: $row"
    log_verbose "Resolved image URL: $IMAGE_URL"
}

test_debian_image_metadata() {
    echo "==> Testing Debian image metadata"
    echo "    Codename: $CODENAME"
    echo "    Release:  ${DEBIAN_LABEL:-Debian $DEBIAN_VERSION}"
    echo "    Image:    $IMAGE_NAME"
    echo "    URL:      $IMAGE_URL"

    if ! wget --spider -q "$IMAGE_URL"; then
        echo "ERROR: image does not exist: $IMAGE_URL" >&2
        exit 1
    fi

    if ! wget --spider -q "$SUMS_URL"; then
        echo "ERROR: checksum file does not exist: $SUMS_URL" >&2
        exit 1
    fi

    if ! wget -qO- "$SUMS_URL" | awk -v name="$IMAGE_NAME" '$NF == name { found=1 } END { exit found ? 0 : 1 }'; then
        echo "ERROR: image not found in SHA512SUMS: $IMAGE_NAME" >&2
        exit 1
    fi
}


fetch_debian_cloud_image_list
select_debian_codename
select_storage
resolve_debian_image
test_debian_image_metadata

if [[ -z "$NAME" ]]; then
    if [[ "$DEBIAN_VERSION" == "sid" ]]; then
        NAME="debian-sid-cloudinit-template"
    else
        NAME="debian-${DEBIAN_VERSION}-cloudinit-template"
    fi
fi

IMAGE_PATH="${WORKDIR}/${IMAGE_NAME}"
SUMS_PATH="${WORKDIR}/SHA512SUMS"
LOCALE_DIR="${WORKDIR}/locale-settings"

echo "==> Checking dependencies"

for cmd in wget sha512sum virt-customize qm qemu-img pvesm; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: missing command: $cmd" >&2
        echo "Install with: apt install -y wget ca-certificates libguestfs-tools qemu-utils" >&2
        exit 1
    fi
done

echo "==> Creating workdir: $WORKDIR"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

echo "==> Debian codename: $CODENAME"
echo "==> Image: $IMAGE_URL"

echo "==> Downloading image"
wget -O "$IMAGE_PATH" "$IMAGE_URL"

echo "==> Downloading SHA512SUMS"
wget -O "$SUMS_PATH" "$SUMS_URL"

echo "==> Verifying image checksum"
awk -v name="$IMAGE_NAME" '$NF == name { print; found=1 } END { exit found ? 0 : 1 }' "$SUMS_PATH" | sha512sum -c -

echo "==> Preparing local locale settings"
rm -rf "$LOCALE_DIR"
mkdir -p "$LOCALE_DIR/etc/default"

if [[ -f /etc/default/locale ]]; then
    cp /etc/default/locale "$LOCALE_DIR/etc/default/locale"
fi

if [[ -f /etc/locale.gen ]]; then
    mkdir -p "$LOCALE_DIR/etc"
    cp /etc/locale.gen "$LOCALE_DIR/etc/locale.gen"
fi

echo "==> Customizing image: installing packages: $PACKAGES"

# This boots a tiny libguestfs appliance and modifies the image offline.
# Much safer than qemu-nbd + manual mount + chroot.
virt-customize \
    -a "$IMAGE_PATH" \
    --install "$PACKAGES" \
    --copy-in "$LOCALE_DIR/etc:/" \
    --run-command 'systemctl enable qemu-guest-agent || true' \
    --run-command 'systemctl enable avahi-daemon || true' \
    --run-command 'locale-gen || true' \
    --run-command 'cloud-init clean || true' \
    --truncate /etc/machine-id

if [[ -n "$DISK_SIZE" ]]; then
    echo "==> Resizing image to $DISK_SIZE"
    qemu-img resize "$IMAGE_PATH" "$DISK_SIZE"
fi

echo "==> Creating Proxmox VM $VMID: $NAME"

if qm status "$VMID" >/dev/null 2>&1; then
    if [[ "$OVERWRITE_EXISTING" != "true" ]]; then
        echo "ERROR: VMID $VMID already exists" >&2
        echo "Use --overwrite-existing to replace it" >&2
        exit 1
    fi

    echo "==> Existing VMID $VMID found, overwriting"
    qm stop "$VMID" >/dev/null 2>&1 || true
    qm destroy "$VMID" --purge 1
fi

qm create "$VMID" \
    --name "$NAME" \
    --memory "$MEMORY" \
    --cores "$CORES" \
    --net0 "virtio,bridge=${BRIDGE}" \
    --ostype l26 \
    --agent enabled=1 \
    --serial0 socket \
    --vga serial0 \
    --scsihw virtio-scsi-single

echo "==> Importing disk to storage: $STORAGE"
qm importdisk "$VMID" "$IMAGE_PATH" "$STORAGE"

echo "==> Attaching imported disk"

# Find imported disk name. Usually vm-<VMID>-disk-0.
IMPORTED_DISK="$(qm config "$VMID" | awk -F': ' '/unused[0-9]+:/ {print $2; exit}')"

if [[ -z "$IMPORTED_DISK" ]]; then
    echo "ERROR: could not find imported unused disk in qm config" >&2
    qm config "$VMID"
    exit 1
fi

qm set "$VMID" \
    --scsi0 "$IMPORTED_DISK",discard=on,ssd=1 \
    --ide2 "$STORAGE:cloudinit" \
    --boot order=scsi0 \
    --ciuser root \
    --sshkey ~/.ssh/authorized_keys \
    --ipconfig0 ip=dhcp

echo "==> Converting VM to template"
qm template "$VMID" 

echo
echo "Done."
echo "Template VMID: $VMID"
echo "Template name: $NAME"
echo
echo "Clone example:"
echo "  qm clone $VMID 100 --name test-${CODENAME} --full true"
echo "  qm set 100 --sshkeys ~/.ssh/authorized_keys"
echo "  qm start 100"

if [[ "$CLEANUP" == "true" ]]; then
    cleanup_workdir
fi
