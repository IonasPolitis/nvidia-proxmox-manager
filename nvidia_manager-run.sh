#!/bin/bash
set -e

# ==============================================================================
# Universal Proxmox & LXC NVIDIA Manager (v8.3)
# Methodology: Environment Detection, Version Parity, & Interactive Deployment
# Includes: Dynamic CUDA/cuDNN deployment for Ubuntu LXCs
# ==============================================================================

export DEBIAN_FRONTEND=noninteractive 

# --- Immediate Root Check ---
if [ "$EUID" -ne 0 ]; then 
    echo "❌ CRITICAL: Please run this script as root (e.g., using sudo)."
    exit 1
fi

# ==============================================================================
# 1. GLOBAL VARIABLES & ENVIRONMENT DETECTION
# ==============================================================================
CURRENT_KERNEL=$(uname -r)
NVIDIA_BASE_URL="https://download.nvidia.com/XFree86/Linux-x86_64"
VERBOSE=0
KERNEL_MODULE_FLAG=""
ALLOW_RUNNING_DRIVER_FLAG=""

# --- Logging Configuration ---
LOG_FILE="/var/log/nvidia_manager.log"
if [ -f "$LOG_FILE" ]; then
    mv "$LOG_FILE" "${LOG_FILE}.old"
fi
echo "=== NVIDIA Manager Deployment Started at $(date) ===" > "$LOG_FILE"

# --- Detect Environment (Host vs LXC) ---
if grep -qa 'container=lxc' /proc/1/environ 2>/dev/null || [ "$(systemd-detect-virt 2>/dev/null)" == "lxc" ]; then
    IS_LXC=1
    echo "🖥️  ENVIRONMENT DETECTED: LXC Container (User-Space Only Mode)" | tee -a "$LOG_FILE"
else
    IS_LXC=0
    echo "🖥️  ENVIRONMENT DETECTED: Bare-Metal Host (Full Kernel Mode)" | tee -a "$LOG_FILE"
fi

# ==============================================================================
# 2. HARDWARE DISCOVERY & VERSION RESOLUTION
# ==============================================================================

if [ "$IS_LXC" -eq 1 ]; then
    # --- LXC MODE: Read the Host's Kernel Version ---
    if [ ! -f "/proc/driver/nvidia/version" ]; then
        echo "❌ CRITICAL: Host NVIDIA driver not found. Please pass through the GPU /dev nodes to this LXC first." | tee -a "$LOG_FILE"
        exit 1
    fi
    # Extract the exact version running on the host kernel to ensure perfect parity
    TARGET_VER=$(awk '/NVRM version:/ {for(i=1;i<=NF;i++) if ($i ~ /^[0-9]+\.[0-9]+(\.[0-9]+)?$/) {print $i; exit}}' /proc/driver/nvidia/version)
    if [ -z "$TARGET_VER" ]; then
        echo "❌ CRITICAL: Could not parse host NVIDIA driver version from /proc/driver/nvidia/version." | tee -a "$LOG_FILE"
        exit 1
    fi
    DEVICE_PCI_ID="Passed-through from Host"
else
    # --- HOST MODE: Interrogate PCIe Bus (Filter for VGA [0300] / 3D [0302] controllers first) ---
    DEVICE_PCI_ID=$(lspci -nn | grep -iE '\[030[02]\]' | grep -i "10de" | grep -oP '10de:\K[0-9a-fA-F]{4}' | head -n 1 | tr '[:upper:]' '[:lower:]' || true)
    if [ -z "$DEVICE_PCI_ID" ]; then
        DEVICE_PCI_ID=$(lspci -nn | grep -i "10de" | grep -oP '10de:\K[0-9a-fA-F]{4}' | head -n 1 | tr '[:upper:]' '[:lower:]' || true)
    fi

    if [ -z "$DEVICE_PCI_ID" ]; then
        echo "❌ No NVIDIA GPU detected. Exiting..." | tee -a "$LOG_FILE"
        exit 1
    fi

    # Centralized Mapping Table
    case "$DEVICE_PCI_ID" in
        "1180"|"1184"|"11c0"|"0f"*) TARGET_BRANCH="47[0-9]" ;; # Kepler
        "0dc0"|"0de0"|"0de1")       TARGET_BRANCH="39[0-9]" ;; # Fermi
        "13"*|"14"*|"16"*|"17"*|"1b"*|"1c"*|"1d"*)
                                    TARGET_BRANCH="58[0-9]"    # Maxwell, Pascal (1050 Ti), Volta
                                    KERNEL_MODULE_FLAG="--kernel-module-type=proprietary"
                                    ;;
        *)                          TARGET_BRANCH="latest"  ;; # Turing, Ampere, Ada+
    esac
fi

# ==============================================================================
# 3. CORE FUNCTIONS
# ==============================================================================

msg() { 
    local TIMESTAMP
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$TIMESTAMP] $2" >> "$LOG_FILE"
    if [ "$VERBOSE" -eq 1 ]; then echo "$2"; else echo "$1 $2"; fi 
}

rollback() {
    msg "⏪" "CRITICAL FAILURE DETECTED. Initiating cleanup..."
    if [ -f "/var/log/nvidia-installer.log" ] && grep -q "^ERROR:" /var/log/nvidia-installer.log 2>/dev/null; then
        echo "=== NVIDIA Installer Log Tail (/var/log/nvidia-installer.log) ===" >> "$LOG_FILE"
        tail -n 25 /var/log/nvidia-installer.log >> "$LOG_FILE" 2>/dev/null || true
    fi
    msg "🧹" "Rollback: Removing temporary installer files..."
    rm -f /tmp/NVIDIA-Linux-*.run /tmp/cuda-keyring.deb
    if [ "$IS_LXC" -eq 1 ]; then
        apt-get clean > /dev/null 2>&1 || true
    fi
    msg "❌" "Cleanup complete."
    echo "🚨 ERROR DETAILS (Last 30 lines):" && tail -n 30 "$LOG_FILE"
    exit 1
}

execute() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] EXECUTING: $*" >> "$LOG_FILE"
    if [ "$VERBOSE" -eq 1 ]; then 
        "$@" 2>&1 | tee -a "$LOG_FILE"
        if [ "${PIPESTATUS[0]}" -ne 0 ]; then rollback; fi
    else
        if ! "$@" >> "$LOG_FILE" 2>&1; then rollback; fi
    fi
}

find_best_version_host() {
    msg "🌐" "Resolving the highest available driver for the $TARGET_BRANCH branch..."
    if [ "$TARGET_BRANCH" == "latest" ]; then
        TARGET_VER=$(curl -fsSL "${NVIDIA_BASE_URL}/latest.txt" | awk '{print $1}' || true)
    else
        TARGET_VER=$(curl -fsSL "${NVIDIA_BASE_URL}/" | grep -oP "(?<=href=[\"'])${TARGET_BRANCH}\.[0-9]+(\.[0-9]+)?(?=/[\"'])" | sort -rV | head -n 1 || true)
        if [ -z "$TARGET_VER" ]; then
            TARGET_VER=$(curl -fsSL "${NVIDIA_BASE_URL}/" | grep -oP "${TARGET_BRANCH}\.[0-9]+(\.[0-9]+)?" | sort -rV | head -n 1 || true)
        fi
    fi
    if [ -z "$TARGET_VER" ]; then
        msg "❌" "Failed to resolve version."
        exit 1
    fi
    msg "✅" "Resolved target driver version: $TARGET_VER"
}

clean_apt_conflicts() {
    msg "🧹" "Checking for conflicting APT-based NVIDIA packages..."
    local INSTALLED_APT_NVIDIA
    INSTALLED_APT_NVIDIA=$(dpkg -l 2>/dev/null | awk '/^(ii|rc)[[:space:]]+(nvidia-|libnvidia-|xserver-xorg-video-nvidia)/ {print $2}' || true)
    if [ -n "$INSTALLED_APT_NVIDIA" ]; then
        msg "🧹" "Purging conflicting APT-based NVIDIA packages..."
        # shellcheck disable=SC2086
        execute apt-get purge -yq $INSTALLED_APT_NVIDIA
        execute apt-get autoremove -yq
    fi
}

prepare_host_nouveau() {
    if [ "$IS_LXC" -eq 1 ]; then
        return 0
    fi
    echo -e "blacklist nouveau\nblacklist nvidiafb\noptions nouveau modeset=0" > /etc/modprobe.d/blacklist-nouveau.conf
    if lsmod | grep -q "^nouveau"; then
        msg "⚠️" "Nouveau kernel module is currently loaded. Attempting to unload it..."
        for vtcon in /sys/class/vtconsole/vtcon*/bind; do
            if [ -f "$vtcon" ]; then
                echo 0 > "$vtcon" 2>/dev/null || true
            fi
        done
        modprobe -r nouveau 2>/dev/null || true
    fi
}

unload_active_nvidia_modules() {
    if [ "$IS_LXC" -eq 1 ]; then
        return 0
    fi
    if ! lsmod | grep -qE "^nvidia"; then
        return 0
    fi

    msg "🔄" "Stopping nvidia-persistenced and unloading active NVIDIA kernel modules..."
    systemctl stop nvidia-persistenced 2>/dev/null || true
    pkill -9 -f nvidia-persistenced 2>/dev/null || true

    for mod in nvidia_uvm nvidia_drm nvidia_modeset nvidia_peermem nvidia; do
        if lsmod | grep -q "^${mod}[[:space:]]"; then
            modprobe -r "$mod" 2>/dev/null || rmmod "$mod" 2>/dev/null || true
        fi
    done

    if lsmod | grep -q "^nvidia[[:space:]]"; then
        msg "⚠️" "NVIDIA kernel module is still held open by active processes:"
        if [ -x "$(command -v fuser)" ]; then
            fuser -v /dev/nvidia* 2>&1 | tee -a "$LOG_FILE" || true
        fi
        read -p "Terminate processes using /dev/nvidia* so the old module can unload cleanly? [Y/n]: " KILL_GPU_PROCS
        if [[ ! "$KILL_GPU_PROCS" =~ ^[Nn]$ ]]; then
            if [ -x "$(command -v fuser)" ]; then
                fuser -k -TERM /dev/nvidia* > /dev/null 2>&1 || true
                sleep 2
                fuser -k -KILL /dev/nvidia* > /dev/null 2>&1 || true
            fi
            systemctl stop nvidia-persistenced 2>/dev/null || true
            pkill -9 -f nvidia-persistenced 2>/dev/null || true
            for mod in nvidia_uvm nvidia_drm nvidia_modeset nvidia_peermem nvidia; do
                if lsmod | grep -q "^${mod}[[:space:]]"; then
                    modprobe -r "$mod" 2>/dev/null || rmmod "$mod" 2>/dev/null || true
                fi
            done
        fi
    fi

    if lsmod | grep -q "^nvidia[[:space:]]"; then
        msg "⚠️" "Old NVIDIA kernel module could not be unloaded from RAM; enabling --allow-installation-with-running-driver."
        ALLOW_RUNNING_DRIVER_FLAG="--allow-installation-with-running-driver"
    else
        msg "✅" "Previous NVIDIA kernel modules unloaded cleanly."
    fi
}

apply_configurations() {
    # Skip deep kernel configurations if we are inside an LXC
    if [ "$IS_LXC" -eq 1 ]; then
        msg "⚙️" "LXC Environment: Skipping kernel module & initramfs configurations."
        return 0
    fi

    msg "⚙️" "Configuring modules and LXC rules on Host..."
    
    # 1. Blacklist Nouveau
    echo -e "blacklist nouveau\nblacklist nvidiafb\noptions nouveau modeset=0" > /etc/modprobe.d/blacklist-nouveau.conf
    
    # 2. Ensure modules load at boot
    # We use /etc/modules for legacy Proxmox persistence and /etc/modules-load.d/ for modern systemd
    echo "nvidia" > /etc/modules-load.d/nvidia.conf
    echo "nvidia-uvm" >> /etc/modules-load.d/nvidia.conf
    
    if [ -f /etc/modules ] && ! grep -q "nvidia-uvm" /etc/modules 2>/dev/null; then
        echo "nvidia-uvm" >> /etc/modules
    fi

    # 3. Update Initramfs
    execute update-initramfs -u -k all

    # 4. Force load the modules immediately (unless nouveau or an older nvidia module is still locked in the running kernel)
    if lsmod | grep -q "^nouveau"; then
        msg "⚠️" "Nouveau is still bound in the running kernel. NVIDIA modules will load automatically on reboot."
    elif [ -n "$ALLOW_RUNNING_DRIVER_FLAG" ]; then
        msg "⚠️" "An older NVIDIA kernel module remained loaded in RAM during installation. Please reboot the host to activate the new kernel module."
    else
        execute modprobe nvidia
        execute modprobe nvidia-uvm

        # 5. Force creation of device nodes (Fixes the "Device /dev/nvidia-uvm does not exist" error)
        if [ -x "$(command -v nvidia-modprobe)" ]; then
            execute nvidia-modprobe -u -c=0
        fi

        # 6. Persistence daemon
        if [ -x "$(command -v nvidia-persistenced)" ]; then
            nvidia-persistenced --user root > /dev/null 2>&1 || true
        fi
    fi

    cat <<EOF > /etc/udev/rules.d/70-nvidia-lxc.rules
KERNEL=="nvidia*", MODE="0666"
KERNEL=="nvidia-uvm*", MODE="0666"
KERNEL=="nvidia_uvm*", MODE="0666"
KERNEL=="nvidiactl", MODE="0666"
SUBSYSTEM=="drm", KERNEL=="renderD*", MODE="0666"
EOF
    udevadm control --reload-rules && udevadm trigger
}

recover_lxc_apt_state() {
    if [ "$IS_LXC" -eq 0 ]; then
        return 0
    fi
    # Always clear cached .deb files in LXCs to reclaim up to 5 GB of disk space
    apt-get clean > /dev/null 2>&1 || true

    local BROKEN_PKGS
    BROKEN_PKGS=$(dpkg -l 2>/dev/null | awk '/^(iU|iF|iH|rH)[[:space:]]+/ {print $2}' || true)
    if [ -n "$BROKEN_PKGS" ]; then
        msg "⚠️" "Detected partially unpacked packages from a previous interrupted install (e.g. disk full). Repairing APT state..."
        if ! dpkg --configure -a >> "$LOG_FILE" 2>&1 || ! apt-get -f install -yq -o APT::Keep-Downloaded-Packages=false >> "$LOG_FILE" 2>&1; then
            msg "🧹" "Purging incomplete CUDA/GUI packages that could not finish unpacking..."
            local BROKEN_CUDA_GUI
            BROKEN_CUDA_GUI=$(dpkg -l 2>/dev/null | awk '/^(iU|iF|iH)[[:space:]]+/ {pkg=$2; sub(/:.*/, "", pkg); print pkg}' || true)
            if [ -n "$BROKEN_CUDA_GUI" ]; then
                # shellcheck disable=SC2086
                dpkg --remove --force-remove-reinstreq --force-depends $BROKEN_CUDA_GUI >> "$LOG_FILE" 2>&1 || true
            fi
            dpkg --configure -a >> "$LOG_FILE" 2>&1 || true
            apt-get -f install -yq -o APT::Keep-Downloaded-Packages=false >> "$LOG_FILE" 2>&1 || true
            apt-get autoremove -yq >> "$LOG_FILE" 2>&1 || true
            apt-get clean > /dev/null 2>&1 || true
        fi
    fi
}

select_lxc_cuda_profile() {
    apt-get clean > /dev/null 2>&1 || true
    local FREE_MB
    FREE_MB=$(df -Pm / | awk 'NR==2 {print $4}')
    local FREE_GB=$((FREE_MB / 1024))

    echo "----------------------------------------------------------------------"
    msg "💾" "Available LXC Root Disk Space : ${FREE_GB} GB (${FREE_MB} MB free)"
    echo "   [R] Headless Runtime & Compiler (~3.5 GB - shared .so libs, nvcc, cuDNN runtime; recommended for LXCs)"
    echo "   [F] Full Developer SDK          (~13 GB  - adds Nsight GUI profilers, Java/X11, and static .a archives)"
    echo "   [S] Skip CUDA/cuDNN             (0 GB    - keep NVIDIA .run driver & NVENC/NVDEC only)"
    echo "----------------------------------------------------------------------"
    read -p "Select CUDA/cuDNN profile [R/f/s] (default: R): " CUDA_PROFILE_CHOICE

    case "$CUDA_PROFILE_CHOICE" in
        [Ss]* )
            CUDA_INSTALL_MODE="skip"
            ;;
        [Ff]* )
            if [ "$FREE_MB" -lt 12500 ]; then
                msg "⚠️" "Free space (${FREE_GB} GB) is below the ~12.5 GB needed to unpack the Full Developer SDK!"
                read -p "Switch to [R] Headless Runtime (~3.5 GB) to prevent 'No space left on device'? [Y/n]: " SWITCH_RUNTIME
                if [[ "$SWITCH_RUNTIME" =~ ^[Nn]$ ]]; then
                    CUDA_INSTALL_MODE="full"
                else
                    CUDA_INSTALL_MODE="runtime"
                fi
            else
                CUDA_INSTALL_MODE="full"
            fi
            ;;
        * )
            CUDA_INSTALL_MODE="runtime"
            ;;
    esac

    if [ "$CUDA_INSTALL_MODE" == "runtime" ] && [ "$FREE_MB" -lt 3600 ]; then
        msg "⚠️" "WARNING: Free disk space (${FREE_GB} GB / ${FREE_MB} MB) is very low even for Headless Runtime (~3.5 GB)."
        read -p "Continue anyway or [S]kip CUDA/cuDNN? [c/S]: " LOW_SPACE_ACTION
        if [[ ! "$LOW_SPACE_ACTION" =~ ^[Cc]$ ]]; then
            CUDA_INSTALL_MODE="skip"
        fi
    fi
}

install_lxc_cuda_ubuntu() {
    msg "🧠" "Ubuntu LXC ($VERSION_ID): Initializing dynamic CUDA Toolkit & cuDNN deployment..."

    select_lxc_cuda_profile
    if [ "$CUDA_INSTALL_MODE" == "skip" ]; then
        msg "⏭️" "Skipping CUDA/cuDNN installation as requested."
        return 0
    fi

    local REPO_URL_PART
    REPO_URL_PART=$(echo "$VERSION_ID" | tr -d '.')

    msg "📥" "Adding official NVIDIA CUDA repository for Ubuntu $VERSION_ID (ubuntu${REPO_URL_PART})..."
    local KEYRING_URL
    KEYRING_URL="https://developer.download.nvidia.com/compute/cuda/repos/ubuntu${REPO_URL_PART}/x86_64/cuda-keyring_1.1-1_all.deb"

    execute wget -q "$KEYRING_URL" -O /tmp/cuda-keyring.deb
    execute dpkg -i --force-confmiss --force-confnew /tmp/cuda-keyring.deb
    if [ ! -s "/etc/apt/sources.list.d/cuda-ubuntu${REPO_URL_PART}-x86_64.list" ]; then
        echo "deb [signed-by=/usr/share/keyrings/cuda-archive-keyring.gpg] https://developer.download.nvidia.com/compute/cuda/repos/ubuntu${REPO_URL_PART}/x86_64/ /" > "/etc/apt/sources.list.d/cuda-ubuntu${REPO_URL_PART}-x86_64.list"
    fi
    execute apt-get update -yq

    local MAX_CUDA=""
    local COMPUTE_CAP=""
    local CUDA_PKG="cuda-toolkit"
    local CUDA_MAJOR="12"

    if [ -x "$(command -v nvidia-smi)" ]; then
        MAX_CUDA=$(nvidia-smi | grep -oP 'CUDA Version: \K[0-9]+\.[0-9]+' | head -n 1 || true)
        COMPUTE_CAP=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -n 1 | tr -d '[:space:]' || true)
    fi

    if [ -n "$MAX_CUDA" ]; then
        msg "🔍" "Driver reports Max Supported CUDA Version: $MAX_CUDA"
        CUDA_MAJOR=$(echo "$MAX_CUDA" | cut -d. -f1)

        # Pre-Turing GPUs (Maxwell 5.x, Pascal 6.x like GTX 1050 Ti, Volta 7.0) are not supported by CUDA 13.0+
        if [ -n "$COMPUTE_CAP" ]; then
            local COMPUTE_MAJOR COMPUTE_MINOR
            COMPUTE_MAJOR=$(echo "$COMPUTE_CAP" | cut -d. -f1)
            COMPUTE_MINOR=$(echo "$COMPUTE_CAP" | cut -d. -f2)
            if [ "$CUDA_MAJOR" -ge 13 ] && { [ "$COMPUTE_MAJOR" -lt 7 ] || { [ "$COMPUTE_MAJOR" -eq 7 ] && [ "${COMPUTE_MINOR:-0}" -lt 5 ]; }; }; then
                msg "⚠️" "GPU Compute Capability ($COMPUTE_CAP) is pre-Turing; capping CUDA Toolkit to 12.x for hardware compatibility."
                CUDA_MAJOR="12"
                CUDA_PKG=$(apt-cache search '^cuda-toolkit-12-[0-9]+$' 2>/dev/null | awk '{print $1}' | sort -rV | head -n 1 || true)
                if [ -z "$CUDA_PKG" ]; then
                    CUDA_PKG="cuda-toolkit-12-9"
                fi
                MAX_CUDA="12.x (capped for Compute Capability $COMPUTE_CAP)"
            fi
        fi

        if [ "$CUDA_PKG" == "cuda-toolkit" ]; then
            local FORMATTED_VER="${MAX_CUDA//./-}"
            if apt-cache show "cuda-toolkit-${FORMATTED_VER}" > /dev/null 2>&1; then
                CUDA_PKG="cuda-toolkit-${FORMATTED_VER}"
            else
                CUDA_PKG=$(apt-cache search "^cuda-toolkit-${CUDA_MAJOR}-[0-9]+$" 2>/dev/null | awk '{print $1}' | sort -rV | head -n 1 || true)
                if [ -z "$CUDA_PKG" ]; then
                    CUDA_PKG="cuda-toolkit"
                fi
            fi
        fi
    fi

    # Remove any conflicting cuDNN or CUDA 13+ packages from incompatible major versions
    local CONFLICTING_UBUNTU_PKGS
    CONFLICTING_UBUNTU_PKGS=$(dpkg -l 2>/dev/null | awk -v major="$CUDA_MAJOR" '
        /^(ii|rc)[[:space:]]+/ {
            pkg = $2
            sub(/:.*/, "", pkg)
            if (pkg ~ /cudnn/ && pkg ~ /-cuda-[0-9]+/ && pkg !~ ("-cuda-" major "($|-)")) {
                print pkg
            } else if (major == "12" && pkg ~ /^(cuda|libcu|libnpp|libnv).*-1[3-9](-[0-9]+)?(-config-common)?$/) {
                print pkg
            }
        }' || true)
    if [ -n "$CONFLICTING_UBUNTU_PKGS" ]; then
        msg "🧹" "Removing conflicting CUDA/cuDNN packages from incompatible major versions..."
        # shellcheck disable=SC2086
        execute apt-get purge -yq $CONFLICTING_UBUNTU_PKGS
        execute apt-get autoremove -yq
        apt-get clean > /dev/null 2>&1 || true
    fi

    local CUDA_VER_SUFFIX="${CUDA_PKG#cuda-toolkit-}"
    local UBUNTU_INSTALL_PKGS=()
    local APT_EXTRA_FLAGS=(-o APT::Keep-Downloaded-Packages=false)

    if [ "$CUDA_INSTALL_MODE" == "runtime" ] && [[ "$CUDA_PKG" == cuda-toolkit-* ]] && apt-cache show "cuda-libraries-${CUDA_VER_SUFFIX}" > /dev/null 2>&1; then
        APT_EXTRA_FLAGS+=(--no-install-recommends)
        UBUNTU_INSTALL_PKGS=("cuda-libraries-${CUDA_VER_SUFFIX}" "cuda-nvcc-${CUDA_VER_SUFFIX}")
        if apt-cache show "libcudnn9-cuda-${CUDA_MAJOR}" > /dev/null 2>&1; then
            UBUNTU_INSTALL_PKGS+=("libcudnn9-cuda-${CUDA_MAJOR}")
        else
            UBUNTU_INSTALL_PKGS+=("libcudnn9-cuda-12")
        fi
    else
        UBUNTU_INSTALL_PKGS=("$CUDA_PKG")
        if apt-cache show "cudnn9-cuda-${CUDA_MAJOR}" > /dev/null 2>&1 && apt-get install -s "$CUDA_PKG" "cudnn9-cuda-${CUDA_MAJOR}" > /dev/null 2>&1; then
            UBUNTU_INSTALL_PKGS+=("cudnn9-cuda-${CUDA_MAJOR}")
        elif apt-cache show "libcudnn9-cuda-${CUDA_MAJOR}" > /dev/null 2>&1; then
            UBUNTU_INSTALL_PKGS+=("libcudnn9-cuda-${CUDA_MAJOR}" "libcudnn9-dev-cuda-${CUDA_MAJOR}")
        else
            UBUNTU_INSTALL_PKGS+=("libcudnn9-cuda-12" "libcudnn9-dev-cuda-12")
        fi
    fi

    msg "🛠️" "Installing Ubuntu packages ($CUDA_INSTALL_MODE mode): ${UBUNTU_INSTALL_PKGS[*]}..."
    execute apt-get install -yq "${APT_EXTRA_FLAGS[@]}" "${UBUNTU_INSTALL_PKGS[@]}"
    apt-get clean > /dev/null 2>&1 || true

    if [ ! -e "/usr/local/cuda" ] && [ -d "/usr/local/cuda-${CUDA_VER_SUFFIX/-/.}" ]; then
        ln -sfn "/usr/local/cuda-${CUDA_VER_SUFFIX/-/.}" /usr/local/cuda
    fi
    ldconfig 2>/dev/null || true

    msg "⚙️" "Configuring CUDA system paths..."
    echo 'export PATH=/usr/local/cuda/bin:$PATH' > /etc/profile.d/cuda.sh
    echo 'export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH' >> /etc/profile.d/cuda.sh

    msg "🎉" "SUCCESS: CUDA $MAX_CUDA ($CUDA_INSTALL_MODE) & matching cuDNN deployed for Ubuntu $VERSION_ID."
    rm -f /tmp/cuda-keyring.deb
}

install_lxc_cuda_debian() {
    msg "🧠" "Debian LXC ($VERSION_ID): Initializing dynamic CUDA Toolkit & cuDNN deployment..."

    select_lxc_cuda_profile
    if [ "$CUDA_INSTALL_MODE" == "skip" ]; then
        msg "⏭️" "Skipping CUDA/cuDNN installation as requested."
        return 0
    fi

    local DEBIAN_VER
    DEBIAN_VER=$(echo "$VERSION_ID" | cut -d. -f1)
    local REPO_URL_PART="$DEBIAN_VER"

    local MAX_CUDA=""
    local COMPUTE_CAP=""
    local CUDA_MAJOR="12"
    local CAPPED_PRE_TURING=0

    if [ -x "$(command -v nvidia-smi)" ]; then
        MAX_CUDA=$(nvidia-smi | grep -oP 'CUDA Version: \K[0-9]+\.[0-9]+' | head -n 1 || true)
        COMPUTE_CAP=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -n 1 | tr -d '[:space:]' || true)
    fi

    if [ -n "$MAX_CUDA" ]; then
        msg "🔍" "Driver reports Max Supported CUDA Version: $MAX_CUDA"
        CUDA_MAJOR=$(echo "$MAX_CUDA" | cut -d. -f1)
        if [ -n "$COMPUTE_CAP" ]; then
            local COMPUTE_MAJOR COMPUTE_MINOR
            COMPUTE_MAJOR=$(echo "$COMPUTE_CAP" | cut -d. -f1)
            COMPUTE_MINOR=$(echo "$COMPUTE_CAP" | cut -d. -f2)
            if [ "$CUDA_MAJOR" -ge 13 ] && { [ "$COMPUTE_MAJOR" -lt 7 ] || { [ "$COMPUTE_MAJOR" -eq 7 ] && [ "${COMPUTE_MINOR:-0}" -lt 5 ]; }; }; then
                msg "⚠️" "GPU Compute Capability ($COMPUTE_CAP) is pre-Turing; capping CUDA Toolkit to 12.x for hardware compatibility."
                CUDA_MAJOR="12"
                CAPPED_PRE_TURING=1
            fi
        fi
    fi

    # Debian 13+ native NVIDIA repo only hosts CUDA 13+; use debian12 repo for CUDA 12.x and allow its SHA-1 key binding in Sequoia
    if [ "$CUDA_MAJOR" == "12" ] && [ "$DEBIAN_VER" -ge 13 ]; then
        msg "ℹ️" "Debian $VERSION_ID CUDA repo only hosts CUDA 13+; using debian12 CUDA repository for CUDA 12.x support."
        REPO_URL_PART="12"
        if [ -f "/usr/share/apt/default-sequoia.config" ]; then
            msg "🔑" "Configuring Debian $VERSION_ID Sequoia policy to allow NVIDIA debian12 repository key..."
            mkdir -p /etc/crypto-policies/back-ends
            sed 's/2026-02-01/2036-02-01/g' /usr/share/apt/default-sequoia.config > /etc/crypto-policies/back-ends/apt-sequoia.config
            sed -i 's/2026-02-01/2036-02-01/g' /usr/share/apt/default-sequoia.config 2>/dev/null || true
        fi
        rm -f /etc/apt/sources.list.d/cuda-debian13*.list
    fi

    msg "📥" "Adding official NVIDIA CUDA repository for Debian (debian${REPO_URL_PART})..."
    local KEYRING_URL
    KEYRING_URL="https://developer.download.nvidia.com/compute/cuda/repos/debian${REPO_URL_PART}/x86_64/cuda-keyring_1.1-1_all.deb"

    execute wget -q "$KEYRING_URL" -O /tmp/cuda-keyring.deb
    execute dpkg -i --force-confmiss --force-confnew /tmp/cuda-keyring.deb
    if [ ! -s "/etc/apt/sources.list.d/cuda-debian${REPO_URL_PART}-x86_64.list" ]; then
        echo "deb [signed-by=/usr/share/keyrings/cuda-archive-keyring.gpg] https://developer.download.nvidia.com/compute/cuda/repos/debian${REPO_URL_PART}/x86_64/ /" > "/etc/apt/sources.list.d/cuda-debian${REPO_URL_PART}-x86_64.list"
    fi
    execute apt-get update -yq

    local CUDA_PKG="cuda-toolkit"
    if [ "$CAPPED_PRE_TURING" -eq 1 ]; then
        CUDA_PKG=$(apt-cache search '^cuda-toolkit-12-[0-9]+$' 2>/dev/null | awk '{print $1}' | sort -rV | head -n 1 || true)
        if [ -z "$CUDA_PKG" ]; then
            CUDA_PKG="cuda-toolkit-12-9"
        fi
        MAX_CUDA="12.x (capped for Compute Capability $COMPUTE_CAP)"
    else
        local FORMATTED_VER="${MAX_CUDA//./-}"
        if apt-cache show "cuda-toolkit-${FORMATTED_VER}" > /dev/null 2>&1; then
            CUDA_PKG="cuda-toolkit-${FORMATTED_VER}"
        else
            CUDA_PKG=$(apt-cache search "^cuda-toolkit-${CUDA_MAJOR}-[0-9]+$" 2>/dev/null | awk '{print $1}' | sort -rV | head -n 1 || true)
            if [ -z "$CUDA_PKG" ]; then
                CUDA_PKG="cuda-toolkit"
            fi
        fi
    fi

    local CONFLICTING_DEBIAN_PKGS
    CONFLICTING_DEBIAN_PKGS=$(dpkg -l 2>/dev/null | awk -v major="$CUDA_MAJOR" '
        /^(ii|rc)[[:space:]]+/ {
            pkg = $2
            sub(/:.*/, "", pkg)
            if (pkg ~ /cudnn/ && pkg ~ /-cuda-[0-9]+/ && pkg !~ ("-cuda-" major "($|-)")) {
                print pkg
            } else if (major == "12" && pkg ~ /^(cuda|libcu|libnpp|libnv).*-1[3-9](-[0-9]+)?(-config-common)?$/) {
                print pkg
            }
        }' || true)
    if [ -n "$CONFLICTING_DEBIAN_PKGS" ]; then
        msg "🧹" "Removing conflicting CUDA/cuDNN packages from incompatible major versions..."
        # shellcheck disable=SC2086
        execute apt-get purge -yq $CONFLICTING_DEBIAN_PKGS
        execute apt-get autoremove -yq
        apt-get clean > /dev/null 2>&1 || true
    fi

    local CUDA_VER_SUFFIX="${CUDA_PKG#cuda-toolkit-}"
    local DEBIAN_INSTALL_PKGS=()
    local APT_EXTRA_FLAGS=(-o APT::Keep-Downloaded-Packages=false)

    if [ "$CUDA_INSTALL_MODE" == "runtime" ] && [[ "$CUDA_PKG" == cuda-toolkit-* ]] && apt-cache show "cuda-libraries-${CUDA_VER_SUFFIX}" > /dev/null 2>&1; then
        APT_EXTRA_FLAGS+=(--no-install-recommends)
        DEBIAN_INSTALL_PKGS=("cuda-libraries-${CUDA_VER_SUFFIX}" "cuda-nvcc-${CUDA_VER_SUFFIX}")
        if apt-cache show "libcudnn9-cuda-${CUDA_MAJOR}" > /dev/null 2>&1; then
            DEBIAN_INSTALL_PKGS+=("libcudnn9-cuda-${CUDA_MAJOR}")
        else
            DEBIAN_INSTALL_PKGS+=("libcudnn9-cuda-12")
        fi
    else
        local DEBIAN_CUDNN_PKGS=()
        if apt-cache show "cudnn9-cuda-${CUDA_MAJOR}" > /dev/null 2>&1 && apt-get install -s "cudnn9-cuda-${CUDA_MAJOR}" > /dev/null 2>&1; then
            DEBIAN_CUDNN_PKGS=("cudnn9-cuda-${CUDA_MAJOR}")
        elif apt-cache show "libcudnn9-cuda-${CUDA_MAJOR}" > /dev/null 2>&1; then
            DEBIAN_CUDNN_PKGS=("libcudnn9-cuda-${CUDA_MAJOR}" "libcudnn9-dev-cuda-${CUDA_MAJOR}")
        else
            DEBIAN_CUDNN_PKGS=("libcudnn9-cuda-12" "libcudnn9-dev-cuda-12")
        fi

        DEBIAN_INSTALL_PKGS=("$CUDA_PKG" "${DEBIAN_CUDNN_PKGS[@]}")
        if ! apt-get install -s "${DEBIAN_INSTALL_PKGS[@]}" > /dev/null 2>&1; then
            if [[ "$CUDA_PKG" == cuda-toolkit-* ]] && apt-cache show "cuda-compiler-${CUDA_VER_SUFFIX}" > /dev/null 2>&1; then
                msg "⚠️" "Full $CUDA_PKG has unmet GUI/profiler dependencies (e.g. libtinfo5) on Debian $VERSION_ID; selecting headless CUDA stack (cuda-compiler-${CUDA_VER_SUFFIX}, cuda-libraries-${CUDA_VER_SUFFIX}, cuda-libraries-dev-${CUDA_VER_SUFFIX})..."
                DEBIAN_INSTALL_PKGS=("cuda-compiler-${CUDA_VER_SUFFIX}" "cuda-libraries-${CUDA_VER_SUFFIX}" "cuda-libraries-dev-${CUDA_VER_SUFFIX}" "${DEBIAN_CUDNN_PKGS[@]}")
            fi
        fi
    fi

    msg "🛠️" "Installing Debian packages ($CUDA_INSTALL_MODE mode): ${DEBIAN_INSTALL_PKGS[*]}..."
    execute apt-get install -yq "${APT_EXTRA_FLAGS[@]}" "${DEBIAN_INSTALL_PKGS[@]}"
    apt-get clean > /dev/null 2>&1 || true

    if [ ! -e "/usr/local/cuda" ] && [ -d "/usr/local/cuda-${CUDA_VER_SUFFIX/-/.}" ]; then
        ln -sfn "/usr/local/cuda-${CUDA_VER_SUFFIX/-/.}" /usr/local/cuda
    fi
    ldconfig 2>/dev/null || true

    msg "⚙️" "Configuring CUDA system paths..."
    echo 'export PATH=/usr/local/cuda/bin:$PATH' > /etc/profile.d/cuda.sh
    echo 'export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH' >> /etc/profile.d/cuda.sh

    msg "🎉" "SUCCESS: CUDA $MAX_CUDA ($CUDA_INSTALL_MODE) & matching cuDNN deployed for Debian $VERSION_ID."
    rm -f /tmp/cuda-keyring.deb
}

install_lxc_cuda_stack() {
    # If we are on the bare-metal host, skip this entirely.
    if [ "$IS_LXC" -eq 0 ]; then
        return 0
    fi

    source /etc/os-release
    if [[ "$ID" == "ubuntu" ]]; then
        install_lxc_cuda_ubuntu
    elif [[ "$ID" == "debian" ]]; then
        install_lxc_cuda_debian
    else
        msg "⚠️" "CUDA auto-install currently only supports Ubuntu or Debian LXCs. Skipping..."
        return 0
    fi
}

# ==============================================================================
# 4. START OF THE PIPELINE
# ==============================================================================

read -p "Run in Verbose mode? [y/N]: " PROMPT_VERBOSE
if [[ "$PROMPT_VERBOSE" =~ ^[Yy]$ ]]; then
    VERBOSE=1
else
    VERBOSE=0
fi

msg "🔍" "Analyzing environment for GPU [$DEVICE_PCI_ID]..."
if [ "$IS_LXC" -eq 1 ]; then
    recover_lxc_apt_state
else
    dpkg --configure -a > /dev/null 2>&1 || true
fi

# If on Host, we need to go scrape the web for the version.
if [ "$IS_LXC" -eq 0 ]; then
    find_best_version_host
else
    msg "✅" "LXC Parity Lock: Inheriting Version $TARGET_VER from Host."
fi

INSTALLED_VER=""
if [ -x "$(command -v nvidia-smi)" ]; then
    INSTALLED_VER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n 1 | tr -d '[:space:]' | grep -oE '^[0-9]+\.[0-9]+(\.[0-9]+)?$' || true)
    if [ -z "$INSTALLED_VER" ]; then
        INSTALLED_VER=$(nvidia-smi --version 2>/dev/null | awk -F':' '/NVIDIA-SMI version/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' | grep -oE '^[0-9]+\.[0-9]+(\.[0-9]+)?$' || true)
    fi
    if [ -z "$INSTALLED_VER" ] && [ -x "$(command -v nvidia-uninstall)" ]; then
        INSTALLED_VER=$(nvidia-uninstall --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n 1 || true)
    fi
    if [ -z "$INSTALLED_VER" ] && [ "$IS_LXC" -eq 0 ] && [ -f "/proc/driver/nvidia/version" ]; then
        INSTALLED_VER=$(awk '/NVRM version:/ {for(i=1;i<=NF;i++) if ($i ~ /^[0-9]+\.[0-9]+(\.[0-9]+)?$/) {print $i; exit}}' /proc/driver/nvidia/version 2>/dev/null || true)
    fi
    if [ -z "$INSTALLED_VER" ] && [ "$IS_LXC" -eq 0 ]; then
        INSTALLED_VER=$(modinfo -F version nvidia 2>/dev/null | head -n 1 | tr -d '[:space:]' || true)
    fi
    if [ -z "$INSTALLED_VER" ] && [ "$IS_LXC" -eq 0 ] && [ -d "/var/lib/dkms/nvidia" ]; then
        INSTALLED_VER=$(ls -1 /var/lib/dkms/nvidia 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+(\.[0-9]+)?$' | sort -rV | head -n 1 || true)
    fi
elif [ "$IS_LXC" -eq 0 ] && { [ -f "/proc/driver/nvidia/version" ] || lsmod | grep -qE "^nvidia"; }; then
    msg "⚠️" "Detected incomplete/uninstalled driver state (kernel module in RAM, but nvidia-smi missing on disk). Proceeding with recovery installation..."
fi
if [ -z "$INSTALLED_VER" ]; then
    INSTALLED_VER="none"
fi

# ==============================================================================
# 5. INTERACTIVE PROMPT & EXECUTION
# ==============================================================================

if [ "$INSTALLED_VER" != "none" ]; then
    echo "----------------------------------------------------------------------"
    msg "ℹ️" "Existing NVIDIA driver detected : Version $INSTALLED_VER"
    msg "🎯" "Target resolved driver          : Version $TARGET_VER"
    echo "----------------------------------------------------------------------"
    
    if [ "$TARGET_VER" == "$INSTALLED_VER" ]; then
        msg "✅" "Your system is already running the recommended driver."
        read -p "Action required - [F]orce Reinstall, [R]emove, or [C]ancel: " PROMPT_ACTION
    else
        msg "🚀" "A different driver version is recommended/required."
        read -p "Action required - [U]pdate, [R]emove, or [C]ancel: " PROMPT_ACTION
    fi
    
    case "$PROMPT_ACTION" in
        [Uu]*|[Ff]* ) msg "🔄" "Proceeding with deployment workflow..." ;;
        [Rr]* )
            msg "🗑️" "Initiating complete uninstallation..."
            unload_active_nvidia_modules
            if [ -x "$(command -v nvidia-uninstall)" ]; then
                execute nvidia-uninstall --silent
            fi
            clean_apt_conflicts
            msg "✅" "SUCCESS: NVIDIA drivers completely removed."
            rm -f /tmp/NVIDIA-Linux-*.run
            if [ "$IS_LXC" -eq 0 ]; then
                read -p "Reboot required. Reboot now? [y/N]: " REBOOT_NOW
                if [[ "$REBOOT_NOW" =~ ^[Yy]$ ]]; then
                    reboot
                fi
            fi
            exit 0
            ;;
        * ) msg "🛑" "Operation cancelled by user."; exit 0 ;;
    esac
fi

msg "🏗️" "Deploying NVIDIA Driver $TARGET_VER via .run binary..."

# Branch the installation dependencies and flags based on the environment
if [ "$IS_LXC" -eq 1 ] && [ -f "/usr/share/apt/default-sequoia.config" ]; then
    mkdir -p /etc/crypto-policies/back-ends
    sed 's/2026-02-01/2036-02-01/g' /usr/share/apt/default-sequoia.config > /etc/crypto-policies/back-ends/apt-sequoia.config
    sed -i 's/2026-02-01/2036-02-01/g' /usr/share/apt/default-sequoia.config 2>/dev/null || true
    rm -f /etc/apt/sources.list.d/cuda-debian*.list
fi
execute apt-get update -yq
if [ "$IS_LXC" -eq 1 ]; then
    execute apt-get install -yq build-essential pkg-config libglvnd-dev wget curl ca-certificates
    INSTALL_FLAGS=(--silent --no-kernel-module --no-questions --no-cc-version-check)
else
    HEADER_PKG="proxmox-headers-$CURRENT_KERNEL"
    if ! apt-cache show "$HEADER_PKG" > /dev/null 2>&1; then
        if apt-cache show "pve-headers-$CURRENT_KERNEL" > /dev/null 2>&1; then
            HEADER_PKG="pve-headers-$CURRENT_KERNEL"
        elif apt-cache show "proxmox-default-headers" > /dev/null 2>&1; then
            HEADER_PKG="proxmox-default-headers"
        fi
    fi
    execute apt-get install -yq build-essential dkms pkg-config libglvnd-dev pahole psmisc wget curl ca-certificates "$HEADER_PKG"
    if [ ! -d "/lib/modules/$CURRENT_KERNEL/build" ]; then
        msg "❌" "Kernel headers build directory (/lib/modules/$CURRENT_KERNEL/build) is missing for running kernel $CURRENT_KERNEL."
        exit 1
    fi
    prepare_host_nouveau
    unload_active_nvidia_modules
    INSTALL_FLAGS=(--silent --dkms --no-questions --no-cc-version-check --no-nouveau-check)
    if [ -n "$KERNEL_MODULE_FLAG" ]; then
        INSTALL_FLAGS+=("$KERNEL_MODULE_FLAG")
    fi
    if [ -n "$ALLOW_RUNNING_DRIVER_FLAG" ]; then
        INSTALL_FLAGS+=("$ALLOW_RUNNING_DRIVER_FLAG")
    fi
fi

clean_apt_conflicts

INSTALLER="NVIDIA-Linux-x86_64-${TARGET_VER}.run"
msg "📥" "Downloading $INSTALLER..."
execute wget -q "${NVIDIA_BASE_URL}/${TARGET_VER}/${INSTALLER}" -O "/tmp/$INSTALLER"
if [ ! -s "/tmp/$INSTALLER" ]; then
    msg "❌" "Downloaded installer /tmp/$INSTALLER is empty or missing."
    rollback
fi
chmod +x "/tmp/$INSTALLER"

msg "🛠️" "Installing binary..."
execute "/tmp/$INSTALLER" "${INSTALL_FLAGS[@]}"

apply_configurations
install_lxc_cuda_stack

msg "🎉" "SUCCESS: NVIDIA $TARGET_VER deployed."
rm -f "/tmp/$INSTALLER"

if [ "$IS_LXC" -eq 0 ]; then
    read -p "Host Reboot required. Reboot now? [y/N]: " REBOOT_NOW
    if [[ "$REBOOT_NOW" =~ ^[Yy]$ ]]; then
        reboot
    fi
else
    msg "💡" "LXC deployment complete. You may need to restart any services (like Docker/Plex) using the GPU."
fi
