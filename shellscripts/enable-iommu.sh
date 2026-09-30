#!/usr/bin/env bash
#
# enable-iommu.sh
# Enables IOMMU and VFIO modules on Proxmox VE 7/8+
# Supports both proxmox-boot-tool (systemd-boot) and GRUB
#

set -euo pipefail

# 1. Require root
if [[ "${EUID}" -ne 0 ]]; then
    echo "[-] Error: This script must be run as root." >&2
    exit 1
fi

echo "[+] Detecting CPU architecture..."
if grep -q "GenuineIntel" /proc/cpuinfo; then
    CPU_VENDOR="intel"
    IOMMU_PARAM="intel_iommu=on iommu=pt"
    echo "    -> Intel CPU detected."
elif grep -q "AuthenticAMD" /proc/cpuinfo; then
    CPU_VENDOR="amd"
    IOMMU_PARAM="amd_iommu=on iommu=pt"
    echo "    -> AMD CPU detected."
else
    echo "[-] Error: Unknown CPU vendor. Aborting." >&2
    exit 1
fi

# 2. Check if IOMMU is already active
if [ -d /sys/kernel/iommu_groups ] && [ -n "$(ls -A /sys/kernel/iommu_groups 2>/dev/null)" ]; then
    echo "[!] Notice: IOMMU groups are already active on this system."
fi

# 3. Detect Bootloader & Update Kernel Commandline
echo "[+] Detecting bootloader configuration..."

if [ -f /etc/kernel/cmdline ] && [ -f /etc/kernel/proxmox-boot-uuids ]; then
    echo "    -> Using proxmox-boot-tool (systemd-boot / /etc/kernel/cmdline)"
    CMDLINE_FILE="/etc/kernel/cmdline"
    cp "${CMDLINE_FILE}" "${CMDLINE_FILE}.bak.$(date +%F_%T)"

    CURRENT_CMDLINE=$(cat "${CMDLINE_FILE}")
    CHANGED=0

    for param in ${IOMMU_PARAM}; do
        if ! grep -qw "${param}" "${CMDLINE_FILE}"; then
            CURRENT_CMDLINE="${CURRENT_CMDLINE} ${param}"
            CHANGED=1
        fi
    done

    if [ "${CHANGED}" -eq 1 ]; then
        # Ensure single line without leading/trailing whitespace
        echo "${CURRENT_CMDLINE}" | tr '\n' ' ' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' > "${CMDLINE_FILE}"
        echo "" >> "${CMDLINE_FILE}"
        echo "[+] Updated ${CMDLINE_FILE}"
        echo "[+] Refreshing proxmox-boot-tool..."
        proxmox-boot-tool refresh
    else
        echo "[i] Kernel parameters already present in ${CMDLINE_FILE}."
    fi

elif [ -f /etc/default/grub ]; then
    echo "    -> Using GRUB (/etc/default/grub)"
    GRUB_FILE="/etc/default/grub"
    cp "${GRUB_FILE}" "${GRUB_FILE}.bak.$(date +%F_%T)"

    CHANGED=0
    for param in ${IOMMU_PARAM}; do
        if ! grep -q "${param}" "${GRUB_FILE}"; then
            CHANGED=1
        fi
    done

    if [ "${CHANGED}" -eq 1 ]; then
        # Safely insert parameters inside GRUB_CMDLINE_LINUX_DEFAULT="..."
        sed -i -E "s/GRUB_CMDLINE_LINUX_DEFAULT=\"([^\"]*)\"/GRUB_CMDLINE_LINUX_DEFAULT=\"\1 ${IOMMU_PARAM}\"/" "${GRUB_FILE}"
        # Clean up any accidental double spaces
        sed -i -E 's/[[:blank:]]+/ /g' "${GRUB_FILE}"
        echo "[+] Updated ${GRUB_FILE}"
        echo "[+] Running update-grub..."
        update-grub
    else
        echo "[i] Kernel parameters already present in ${GRUB_FILE}."
    fi
else
    echo "[-] Error: Could not determine bootloader config file." >&2
    exit 1
fi

# 4. Configure VFIO Modules in /etc/modules
echo "[+] Configuring VFIO kernel modules in /etc/modules..."
cp /etc/modules "/etc/modules.bak.$(date +%F_%T)"

VFIO_MODULES=(
    "vfio"
    "vfio_iommu_type1"
    "vfio_pci"
)

# Note: vfio_virqfd is deliberately omitted because it is merged into vfio in Linux 6.2+

for mod in "${VFIO_MODULES[@]}"; do
    if ! grep -qx "${mod}" /etc/modules; then
        echo "${mod}" >> /etc/modules
        echo "    -> Added ${mod}"
    else
        echo "    -> ${mod} already listed"
    fi
done

# 5. Update initramfs
echo "[+] Updating initramfs (all kernels)..."
update-initramfs -u -k all

echo ""
echo "=========================================================="
echo " [SUCCESS] IOMMU configuration complete."
echo " Please reboot your Proxmox VE host to apply changes:"
echo "   # reboot"
echo "=========================================================="
