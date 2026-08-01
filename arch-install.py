#!/usr/bin/env python3
from __future__ import annotations

import argparse
import getpass
import grp
import json
import os
import pwd
import shlex
import shutil
import subprocess
import sys
import time
from pathlib import Path


SCRIPT_ROOT = Path(__file__).resolve().parent
TARGET_MOUNT = Path("/mnt")
STAGE_DIR = TARGET_MOUNT / "root" / "linux-setup-installer"
CHROOT_STAGE_DIR = Path("/root/linux-setup-installer")
STAGE_CONFIG_PATH = STAGE_DIR / "install-config.json"
STAGE_LOG_PATH = STAGE_DIR / "chroot-install.log"
CHROOT_STAGE_LOG_PATH = CHROOT_STAGE_DIR / "chroot-install.log"

BASE_PACKAGES = [
    "base",
    "linux",
    "linux-firmware",
    "sudo",
    "bash",
    "bash-completion",
    "dbus",
    "python",
    "networkmanager",
    "openssh",
    "git",
    "curl",
    "zip",
    "unzip",
    "neovim",
    "ripgrep",
    "usbutils",
    "fd",
    "fzf",
    "ghostty",
    "kitty",
    "qutebrowser",
    "thunar",
    "xorg-xwayland",
    "sway",
    "waybar",
    "lightdm",
    "lightdm-gtk-greeter",
    "rofi-wayland",
    "python-gobject",
    "gtk3",
    "awww",
    "mpv",
    "gtklock",
    "fastfetch",
    "bottom",
    "gthumb",
    "ttc-iosevka",
    "ttf-iosevka-nerd",
    "grim",
    "slurp",
    "wl-clipboard",
    "wlr-randr",
    "xdg-user-dirs",
    "xdg-utils",
    "xdg-desktop-portal-wlr",
    "xdg-desktop-portal-gtk",
    "pipewire",
    "pipewire-pulse",
    "wireplumber",
    "base-devel",
    "meson",
    "ninja",
    "pkgconf",
    "go",
    "zig",
    "nodejs",
    "npm",
    "arm-none-eabi-gcc",
    "arm-none-eabi-newlib",
    "lua-language-server",
    "clang",
    "zls",
    "pyright",
    "picocom",
    "adwaita-cursors",
    "wayland",
    "wayland-protocols",
]

CPU_PACKAGES = {
    "intel": ["intel-ucode"],
    "amd": ["amd-ucode"],
}

GPU_PACKAGES = {
    "intel": ["mesa", "vulkan-intel"],
    "amd": ["mesa", "vulkan-radeon", "xf86-video-amdgpu"],
    "nvidia": ["nvidia-open", "nvidia-utils", "egl-wayland"],
    "vmware": ["mesa"],
}

VM_PACKAGES = [
    "open-vm-tools",
    "gtkmm3",
    "libxtst",
]

USER_GROUPS = [
    "wheel",
    "audio",
    "video",
    "input",
    "uucp",
    "lock",
]

STAGED_REPO_FILES = [
    "arch-install.py",
    "assets",
    "tools",
]

DEFAULT_CONFIG = {
    "hostname": "linux-pc",
    "timezone": "America/Denver",
    "locale": "en_US.UTF-8",
    "keymap": "us",
    "cpu_vendor": "intel",
    "gpu_stack": "intel",
    "is_vm": False,
}

INSTALLER_BUILD_ROOT = Path("/tmp/linux-setup-build")
MPVPAPER_REPO = "https://github.com/GhostNaN/mpvpaper.git"
MPVPAPER_REF = "1.8"
BACKGROUND_REPO = "https://github.com/djhoggatt/root-and-rail.git"
LOGIN_BACKGROUND_NAME = "canyon.png"
LOGIN_BACKGROUND_PATH = Path("/usr/share/backgrounds/linux-setup/login.png")
GO_GRIP_MODULE = "github.com/chrishrb/go-grip@latest"
SOURCE_BUILD_ZIG_VERSION = "0.15.2"
SOURCE_BUILD_ZIG_URL = (
    f"https://ziglang.org/download/{SOURCE_BUILD_ZIG_VERSION}/"
    f"zig-x86_64-linux-{SOURCE_BUILD_ZIG_VERSION}.tar.xz"
)
DZ60_VIA_UDEV_RULES = """# DZTECH DZ60RGB VIA/QMK HID interfaces
KERNEL=="hidraw*", SUBSYSTEM=="hidraw", ATTRS{idVendor}=="445a", ATTRS{idProduct}=="1121", MODE="0660", TAG+="uaccess", TAG+="udev-acl"
SUBSYSTEMS=="usb", ATTRS{idVendor}=="445a", ATTRS{idProduct}=="1121", TAG+="uaccess"
"""


def fail(message: str) -> None:
    print(f"\nERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def resolve_assets_dir() -> Path:
    candidates = [
        SCRIPT_ROOT / "assets",
        CHROOT_STAGE_DIR / "assets",
        Path("/root/assets"),
    ]
    for candidate in candidates:
        if candidate.exists():
            return candidate
    fail(
        "Could not locate the staged assets directory. Tried: "
        + ", ".join(str(candidate) for candidate in candidates)
    )


def run(
    command: list[str],
    *,
    check: bool = True,
    capture: bool = False,
    input_text: str | None = None,
    env: dict[str, str] | None = None,
    cwd: str | None = None,
) -> subprocess.CompletedProcess[str]:
    quoted = " ".join(shlex.quote(part) for part in command)
    print(f"\n==> {quoted}")
    try:
        return subprocess.run(
            command,
            check=check,
            text=True,
            input=input_text,
            capture_output=capture,
            env=env,
            cwd=cwd,
        )
    except subprocess.CalledProcessError as exc:
        if exc.stdout:
            print("\nstdout:", file=sys.stderr)
            print(exc.stdout, file=sys.stderr, end="" if exc.stdout.endswith("\n") else "\n")
        if exc.stderr:
            print("\nstderr:", file=sys.stderr)
            print(exc.stderr, file=sys.stderr, end="" if exc.stderr.endswith("\n") else "\n")
        raise


def require_root() -> None:
    if os.geteuid() != 0:
        fail("Run this script as root.")


def require_uefi() -> None:
    if not Path("/sys/firmware/efi/efivars").exists():
        fail("This script expects UEFI boot.")


def prompt(text: str, default: str | None = None) -> str:
    suffix = f" [{default}]" if default is not None else ""
    value = input(f"{text}{suffix}: ").strip()
    if value:
        return value
    if default is None:
        fail(f"{text} is required.")
    return default


def prompt_choice(text: str, options: list[str], default: str) -> str:
    value = input(f"{text} ({'/'.join(options)}) [{default}]: ").strip().lower()
    if not value:
        return default
    if value not in options:
        fail(f"Invalid choice: {value}")
    return value


def prompt_bool(text: str, default: bool) -> bool:
    suffix = "Y/n" if default else "y/N"
    value = input(f"{text} [{suffix}]: ").strip().lower()
    if not value:
        return default
    if value in {"y", "yes"}:
        return True
    if value in {"n", "no"}:
        return False
    fail(f"Invalid response: {value}")


def quiet_command_output(command: list[str]) -> str | None:
    try:
        result = subprocess.run(command, check=False, text=True, capture_output=True)
    except FileNotFoundError:
        return None
    if result.returncode != 0:
        return None
    return result.stdout


def detect_cpu_vendor() -> str | None:
    cpu_text = quiet_command_output(["lscpu"])
    if cpu_text is None:
        cpuinfo = Path("/proc/cpuinfo")
        if cpuinfo.exists():
            cpu_text = cpuinfo.read_text(encoding="utf-8", errors="replace")
    if not cpu_text:
        return None

    lowered = cpu_text.lower()
    if "genuineintel" in lowered or "intel" in lowered:
        return "intel"
    if "authenticamd" in lowered or "amd" in lowered:
        return "amd"
    return None


def detect_gpu_stack() -> str | None:
    pci_text = quiet_command_output(["lspci", "-nn"])
    display_lines: list[str] = []
    if pci_text:
        display_lines = [
            line.lower()
            for line in pci_text.splitlines()
            if "vga compatible controller" in line.lower() or "3d controller" in line.lower()
        ]

    if not display_lines:
        drm_root = Path("/sys/class/drm")
        if drm_root.exists():
            for vendor_file in drm_root.glob("card*/device/vendor"):
                try:
                    vendor = vendor_file.read_text(encoding="utf-8").strip().lower()
                except OSError:
                    continue
                if vendor == "0x15ad":
                    display_lines.append("vmware")
                elif vendor == "0x10de":
                    display_lines.append("nvidia")
                elif vendor == "0x1002":
                    display_lines.append("amd")
                elif vendor == "0x8086":
                    display_lines.append("intel")

    found = set()
    for line in display_lines:
        if "vmware" in line or "15ad" in line or "0405" in line:
            found.add("vmware")
        if "nvidia" in line or "10de" in line:
            found.add("nvidia")
        if "advanced micro devices" in line or " amd" in line or "ati " in line or "1002" in line:
            found.add("amd")
        if "intel" in line or "8086" in line:
            found.add("intel")

    for preferred in ["vmware", "nvidia", "amd", "intel"]:
        if preferred in found:
            return preferred
    return None


def detect_vmware_guest() -> bool:
    virt_type = quiet_command_output(["systemd-detect-virt"])
    if virt_type and virt_type.strip() == "vmware":
        return True

    sys_vendor = Path("/sys/class/dmi/id/sys_vendor")
    product_name = Path("/sys/class/dmi/id/product_name")
    for candidate in [sys_vendor, product_name]:
        if not candidate.exists():
            continue
        text = candidate.read_text(encoding="utf-8", errors="replace").strip().lower()
        if "vmware" in text:
            return True
    return False


def apply_detected_hardware_defaults(config: dict[str, object]) -> None:
    detected_cpu = detect_cpu_vendor()
    if detected_cpu not in CPU_PACKAGES:
        fail("Could not auto-detect a supported CPU vendor (intel or amd).")
    config["cpu_vendor"] = detected_cpu

    detected_gpu = detect_gpu_stack()
    if detected_gpu not in GPU_PACKAGES:
        fail("Could not auto-detect a supported GPU stack (intel, amd, nvidia, or vmware).")
    config["gpu_stack"] = detected_gpu
    config["is_vm"] = detected_gpu == "vmware" or detect_vmware_guest()


def prompt_password(label: str) -> str:
    first = getpass.getpass(f"{label}: ")
    second = getpass.getpass(f"Confirm {label.lower()}: ")
    if not first:
        fail(f"{label} cannot be empty.")
    if first != second:
        fail(f"{label} values did not match.")
    return first


def list_disks() -> list[dict[str, str]]:
    result = run(
        ["lsblk", "--json", "--nodeps", "--output", "PATH,SIZE,MODEL,TYPE,TRAN"],
        capture=True,
    )
    payload = json.loads(result.stdout)
    disks = []
    for device in payload.get("blockdevices", []):
        if device.get("type") != "disk":
            continue
        path = device.get("path", "")
        if path.startswith("/dev/loop") or path.startswith("/dev/zram"):
            continue
        disks.append(device)
    if not disks:
        fail("No installable disks were found.")
    return disks


def prompt_wipe_target(config: dict[str, object]) -> str:
    disks = list_disks()
    print("\nInstall summary:")
    print(f"Hostname: {config['hostname']}")
    print(f"Timezone: {config['timezone']}")
    print(f"Locale: {config['locale']}")
    print(f"Keymap: {config['keymap']}")
    print(f"Username: {config['username']}")
    print(f"CPU vendor: {config['cpu_vendor']}")
    print(f"GPU stack: {config['gpu_stack']}")
    print(f"VM install: {'yes' if config['is_vm'] else 'no'}")
    print("\nAvailable install targets:")
    valid_targets = set()
    for disk in disks:
        path = disk["path"]
        model = (disk.get("model") or "").strip() or "Unknown"
        transport = disk.get("tran") or "unknown"
        valid_targets.add(path)
        print(f"  {path}  {disk['size']}  {transport}  {model}")
    typed = input("\nType WIPE <disk-path> to wipe and install to that disk: ").strip()
    if not typed.startswith("WIPE "):
        fail("Confirmation must start with 'WIPE '.")
    target = typed[5:].strip()
    if target not in valid_targets:
        fail(f"Disk is not one of the listed install targets: {target}")
    run(["lsblk", "-o", "NAME,SIZE,TYPE,MOUNTPOINT", target], check=False)
    return target


def validate_disk(path: str) -> None:
    if not Path(path).exists():
        fail(f"Disk path does not exist: {path}")
    if Path(path).is_dir():
        fail(f"Expected a block device, got a directory: {path}")


def partition_paths(disk: str) -> tuple[str, str]:
    suffix = "p" if "nvme" in disk or "mmcblk" in disk else ""
    return f"{disk}{suffix}1", f"{disk}{suffix}2"


def refresh_clock_and_keys() -> None:
    run(["pacman", "-Sy", "--noconfirm"])
    run(["pacman", "-S", "--noconfirm", "--needed", "archlinux-keyring"])
    run(["timedatectl", "set-ntp", "true"])


def connect_network() -> dict[str, object]:
    connection_type = prompt_choice("Network connection type", ["wired", "wireless"], "wired")
    if connection_type == "wired":
        print("\nUsing the existing wired network connection.")
        return {"connection_type": "wired"}

    run(["rfkill", "unblock", "wifi"], check=False)
    run(["nmcli", "device", "status"], check=False)
    device = prompt("Wireless device")
    run(["nmcli", "device", "wifi", "rescan", "ifname", device], check=False)
    time.sleep(2)
    run(["nmcli", "--colors", "no", "device", "wifi", "list", "ifname", device], check=False)
    ssid = prompt("Wi-Fi network name (SSID)")
    passphrase = getpass.getpass("Wi-Fi passphrase (leave blank for open network): ")

    connect_command = ["nmcli", "--wait", "30", "device", "wifi", "connect", ssid, "ifname", device]
    if passphrase:
        connect_command.extend(["password", passphrase])
    run(connect_command)
    run(["nmcli", "--colors", "no", "device", "show", device], check=False)
    connection_name = run(
        ["nmcli", "--get-values", "GENERAL.CONNECTION", "device", "show", device],
        capture=True,
    ).stdout.strip()
    if not connection_name:
        fail(f"NetworkManager did not report an active connection for {device}.")
    connection_uuid = run(
        ["nmcli", "--get-values", "UUID", "connection", "show", connection_name],
        capture=True,
    ).stdout.strip()
    if not connection_uuid:
        fail(f"Could not determine NetworkManager UUID for connection {connection_name}.")
    return {
        "connection_type": "wireless",
        "wifi_device": device,
        "wifi_ssid": ssid,
        "wifi_connection_name": connection_name,
        "wifi_connection_uuid": connection_uuid,
    }


def cleanup_mounts() -> None:
    mounts = Path("/proc/mounts").read_text(encoding="utf-8")
    if "/mnt/boot" in mounts:
        run(["umount", "/mnt/boot"], check=False)
    if "/mnt" in mounts:
        run(["umount", "-R", "/mnt"], check=False)


def partition_disk(disk: str) -> None:
    run(["wipefs", "-af", disk])
    run(["sgdisk", "--zap-all", disk])
    run(["sgdisk", "-n", "1:0:+1G", "-t", "1:ef00", "-c", "1:EFI System", disk])
    run(["sgdisk", "-n", "2:0:0", "-t", "2:8300", "-c", "2:Arch Root", disk])
    run(["partprobe", disk])
    run(["udevadm", "settle"])


def format_and_mount(esp: str, root: str) -> None:
    run(["mkfs.fat", "-F", "32", esp])
    run(["mkfs.ext4", "-F", root])
    run(["mount", root, str(TARGET_MOUNT)])
    (TARGET_MOUNT / "boot").mkdir(parents=True, exist_ok=True)
    run(["mount", "-o", "umask=0077", esp, str(TARGET_MOUNT / "boot")])


def build_package_list(config: dict[str, object]) -> list[str]:
    cpu_vendor = str(config["cpu_vendor"])
    gpu_stack = str(config["gpu_stack"])
    if cpu_vendor not in CPU_PACKAGES:
        fail(f"Unsupported CPU vendor: {cpu_vendor}")
    if gpu_stack not in GPU_PACKAGES:
        fail(f"Unsupported GPU stack: {gpu_stack}")

    packages = list(BASE_PACKAGES)
    if bool(config.get("is_vm")):
        packages.extend(VM_PACKAGES)
    packages.extend(CPU_PACKAGES[cpu_vendor])
    packages.extend(GPU_PACKAGES[gpu_stack])
    return packages


def pacstrap_system(config: dict[str, object]) -> None:
    packages = build_package_list(config)
    run(["pacstrap", "-K", str(TARGET_MOUNT), *packages])
    result = run(["genfstab", "-U", str(TARGET_MOUNT)], capture=True)
    (TARGET_MOUNT / "etc" / "fstab").write_text(result.stdout, encoding="utf-8")


def copy_repo_path(source: Path, destination: Path) -> None:
    if source.is_dir():
        shutil.copytree(
            source,
            destination,
            dirs_exist_ok=True,
            ignore=shutil.ignore_patterns("__pycache__", "*.pyc", ".zig-cache", "zig-out"),
        )
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)


def stage_support_files(config: dict[str, object]) -> Path:
    if STAGE_DIR.exists():
        shutil.rmtree(STAGE_DIR)
    STAGE_DIR.mkdir(parents=True, exist_ok=True)

    for relative_path in STAGED_REPO_FILES:
        source = SCRIPT_ROOT / relative_path
        destination = STAGE_DIR / relative_path
        copy_repo_path(source, destination)

    STAGE_CONFIG_PATH.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
    return CHROOT_STAGE_DIR / "install-config.json"


def run_chroot_phase(config_path: Path) -> None:
    quoted_script = shlex.quote(str(CHROOT_STAGE_DIR / "arch-install.py"))
    quoted_config = shlex.quote(str(config_path))
    quoted_log = shlex.quote(str(CHROOT_STAGE_LOG_PATH))
    run(
        [
            "arch-chroot",
            str(TARGET_MOUNT),
            "/bin/bash",
            "-lc",
            f"set -o pipefail; /usr/bin/python {quoted_script} --phase chroot --config {quoted_config} 2>&1 | tee {quoted_log}",
        ]
    )


def cleanup_stage_dir() -> None:
    shutil.rmtree(STAGE_DIR, ignore_errors=True)


def group_exists(name: str) -> bool:
    try:
        grp.getgrnam(name)
    except KeyError:
        return False
    return True


def asset_file(relative_path: str) -> Path:
    path = resolve_assets_dir() / relative_path
    if not path.exists():
        fail(f"Expected asset is missing from the staged installer: {relative_path}")
    return path


def write_text(path: Path, content: str, mode: int, *, owner: tuple[int, int] | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    path.chmod(mode)
    if owner is not None:
        os.chown(path, owner[0], owner[1])


def ensure_dir(path: Path, *, owner: tuple[int, int] | None = None, mode: int = 0o755) -> None:
    path.mkdir(parents=True, exist_ok=True)
    path.chmod(mode)
    if owner is not None:
        os.chown(path, owner[0], owner[1])


def copy_file(
    source: Path,
    destination: Path,
    mode: int,
    *,
    owner: tuple[int, int] | None = None,
) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)
    destination.chmod(mode)
    if owner is not None:
        os.chown(destination, owner[0], owner[1])


def copy_live_networkmanager_profile(config: dict[str, object]) -> None:
    if str(config.get("connection_type", "wired")) != "wireless":
        return

    connection_uuid = str(config.get("wifi_connection_uuid", "")).strip()
    if not connection_uuid:
        fail("Wireless install was selected, but no NetworkManager UUID was staged.")

    source_dir = Path("/etc/NetworkManager/system-connections")
    if not source_dir.exists():
        fail(f"NetworkManager connection directory not found in live environment: {source_dir}")

    source_profile: Path | None = None
    for candidate in source_dir.glob("*.nmconnection"):
        try:
            contents = candidate.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        if f"uuid={connection_uuid}" in contents:
            source_profile = candidate
            break

    if source_profile is None:
        fail(
            "Could not find the generated NetworkManager profile for UUID "
            f"{connection_uuid} in {source_dir}."
        )

    destination = TARGET_MOUNT / "etc" / "NetworkManager" / "system-connections" / source_profile.name
    copy_file(source_profile, destination, 0o600)


def install_codex() -> None:
    run(["npm", "install", "-g", "@openai/codex"])


def configure_system_identity(config: dict[str, object]) -> None:
    locale = str(config["locale"])
    timezone = str(config["timezone"])
    hostname = str(config["hostname"])
    keymap = str(config["keymap"])

    zoneinfo = Path("/usr/share/zoneinfo") / timezone
    if not zoneinfo.exists():
        fail(f"Timezone does not exist: {timezone}")

    localtime = Path("/etc/localtime")
    if localtime.exists() or localtime.is_symlink():
        localtime.unlink()
    localtime.symlink_to(zoneinfo)
    run(["hwclock", "--systohc"])

    locale_gen = Path("/etc/locale.gen")
    wanted_locale = f"{locale} UTF-8"
    if locale_gen.exists():
        updated_lines = []
        found = False
        for line in locale_gen.read_text(encoding="utf-8").splitlines():
            stripped = line.strip()
            if stripped == f"#{wanted_locale}" or stripped == wanted_locale:
                updated_lines.append(wanted_locale)
                found = True
            else:
                updated_lines.append(line)
        if not found:
            updated_lines.append(wanted_locale)
        locale_gen.write_text("\n".join(updated_lines) + "\n", encoding="utf-8")
    write_text(Path("/etc/locale.conf"), f"LANG={locale}\n", 0o644)
    write_text(Path("/etc/vconsole.conf"), f"KEYMAP={keymap}\n", 0o644)
    run(["locale-gen"])

    write_text(Path("/etc/hostname"), f"{hostname}\n", 0o644)
    write_text(
        Path("/etc/hosts"),
        (
            "127.0.0.1 localhost\n"
            "::1 localhost\n"
            f"127.0.1.1 {hostname}.localdomain {hostname}\n"
        ),
        0o644,
    )


def install_bootloader(config: dict[str, object]) -> None:
    root_partition = str(config["root_partition"])
    cpu_vendor = str(config["cpu_vendor"])
    root_uuid = run(["blkid", "-s", "UUID", "-o", "value", root_partition], capture=True).stdout.strip()
    if not root_uuid:
        fail(f"Could not determine UUID for root partition: {root_partition}")
    microcode = "intel-ucode.img" if cpu_vendor == "intel" else "amd-ucode.img"

    run(["bootctl", "--variables=no", "install"])
    loader_dir = Path("/boot/loader/entries")
    loader_dir.mkdir(parents=True, exist_ok=True)
    write_text(
        Path("/boot/loader/loader.conf"),
        "default arch.conf\ntimeout 3\nconsole-mode max\neditor no\n",
        0o644,
    )
    write_text(
        loader_dir / "arch.conf",
        (
            "title   Arch Linux\n"
            "linux   /vmlinuz-linux\n"
            f"initrd  /{microcode}\n"
            "initrd  /initramfs-linux.img\n"
            f"options root=UUID={root_uuid} rw quiet\n"
        ),
        0o644,
    )


def set_password(account: str, password: str) -> None:
    run(["chpasswd"], input_text=f"{account}:{password}\n")


def ensure_user(username: str, password: str) -> None:
    available_groups = [group for group in USER_GROUPS if group_exists(group)]
    group_arg = ",".join(available_groups)
    exists = subprocess.run(
        ["id", "-u", username],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    ).returncode == 0

    if exists:
        if group_arg:
            run(["usermod", "-aG", group_arg, "-s", "/bin/bash", username])
        else:
            run(["usermod", "-s", "/bin/bash", username])
    else:
        command = ["useradd", "-m", "-s", "/bin/bash"]
        if group_arg:
            command.extend(["-G", group_arg])
        command.append(username)
        run(command)
    set_password(username, password)


def user_ids(username: str) -> tuple[int, int]:
    entry = pwd.getpwnam(username)
    return entry.pw_uid, entry.pw_gid


def run_as_user(
    username: str,
    command: list[str],
    *,
    check: bool = True,
    extra_env: dict[str, str] | None = None,
) -> None:
    home = Path("/home") / username
    env = {
        "HOME": str(home),
        "USER": username,
        "LOGNAME": username,
        "SHELL": "/bin/bash",
        "XDG_CONFIG_HOME": str(home / ".config"),
        "XDG_DATA_HOME": str(home / ".local" / "share"),
        "XDG_STATE_HOME": str(home / ".local" / "state"),
        "PATH": f"{home / '.local' / 'bin'}:/usr/local/bin:/usr/bin:/bin",
    }
    if extra_env:
        env.update(extra_env)
    env_args = [f"{key}={value}" for key, value in env.items()]
    run(
        ["runuser", "-u", username, "--", "env", *env_args, *command],
        check=check,
        cwd=str(home),
    )


def install_machine_files() -> None:
    copy_file(asset_file("etc/sudoers.d/10-wheel"), Path("/etc/sudoers.d/10-wheel"), 0o440)
    copy_file(
        asset_file("usr/local/bin/qutebrowser-hint-overlay-workaround"),
        Path("/usr/local/bin/qutebrowser-hint-overlay-workaround"),
        0o755,
    )
    write_text(Path("/etc/udev/rules.d/51-dz60-via.rules"), DZ60_VIA_UDEV_RULES, 0o644)
    copy_file(
        asset_file("etc/lightdm/lightdm.conf"),
        Path("/etc/lightdm/lightdm.conf"),
        0o644,
    )
    copy_file(
        asset_file("etc/lightdm/lightdm-gtk-greeter.conf"),
        Path("/etc/lightdm/lightdm-gtk-greeter.conf"),
        0o644,
    )


def build_user_zig_tool(username: str, source: Path, output: Path) -> None:
    source_build_zig = str(ensure_source_build_zig())
    run_as_user(
        username,
        [
            source_build_zig,
            "build-exe",
            str(source),
            "-O",
            "ReleaseSafe",
            "-femit-bin=" + str(output),
        ],
    )


def build_sway_workspace_tool(username: str) -> None:
    home = Path("/home") / username
    source_dir = SCRIPT_ROOT / "tools" / "sway-workspace"
    if not source_dir.exists():
        source_dir = CHROOT_STAGE_DIR / "tools" / "sway-workspace"
    if not source_dir.exists():
        fail(f"sway-workspace source directory is missing: {source_dir}")

    source_build_zig = str(ensure_source_build_zig())
    run(
        [
            source_build_zig,
            "build",
            "-Doptimize=ReleaseSafe",
            "--prefix",
            str(home / ".local"),
            "install",
        ],
        cwd=str(source_dir),
    )


def configure_default_applications(username: str) -> None:
    run_as_user(username, ["xdg-mime", "default", "thunar.desktop", "inode/directory"])
    run_as_user(
        username,
        [
            "xdg-mime",
            "default",
            "org.qutebrowser.qutebrowser.desktop",
            "x-scheme-handler/http",
            "x-scheme-handler/https",
            "text/html",
        ],
    )
    run_as_user(username, ["gio", "mime", "inode/directory", "thunar.desktop"], check=False)


def install_qutebrowser_workarounds() -> None:
    run(["python", "/usr/local/bin/qutebrowser-hint-overlay-workaround"])


def install_user_files(config: dict[str, object]) -> None:
    username = str(config["username"])
    home = Path("/home") / username
    owner = user_ids(username)

    directories = [
        home / ".cache",
        home / ".config",
        home / ".config" / "fastfetch",
        home / ".config" / "ghostty",
        home / ".config" / "gtklock",
        home / ".config" / "nvim",
        home / ".config" / "qutebrowser",
        home / ".config" / "qutebrowser" / "styles",
        home / ".config" / "rofi",
        home / ".config" / "sway",
        home / ".config" / "waybar",
        home / ".config" / "wireplumber",
        home / ".config" / "wireplumber" / "wireplumber.conf.d",
        home / ".local",
        home / ".local" / "bin",
        home / ".local" / "share",
        home / ".local" / "share" / "applications",
        home / ".local" / "state",
        home / "backgrounds",
        home / "code",
        home / "desktop",
        home / "docs",
        home / "docs" / "music",
        home / "docs" / "pictures",
        home / "docs" / "pictures" / "screenshots",
        home / "docs" / "public",
        home / "docs" / "templates",
        home / "docs" / "videos",
        home / "downloads",
    ]
    for directory in directories:
        ensure_dir(directory, owner=owner)

    asset_copy_map = [
        ("home/.bashrc", home / ".bashrc", 0o644),
        ("home/.gitconfig", home / ".gitconfig", 0o644),
        ("home/.config/ghostty/config", home / ".config" / "ghostty" / "config", 0o644),
        ("home/.config/gtklock/config.ini", home / ".config" / "gtklock" / "config.ini", 0o644),
        ("home/.config/qutebrowser/config.py", home / ".config" / "qutebrowser" / "config.py", 0o644),
        (
            "home/.config/qutebrowser/styles/translucent-page.css",
            home / ".config" / "qutebrowser" / "styles" / "translucent-page.css",
            0o644,
        ),
        ("home/.config/sway/config", home / ".config" / "sway" / "config", 0o644),
        ("home/.config/waybar/config", home / ".config" / "waybar" / "config", 0o644),
        ("home/.config/waybar/style.css", home / ".config" / "waybar" / "style.css", 0o644),
        (
            "home/.config/wireplumber/wireplumber.conf.d/51-raybit-soft-mixer.conf",
            home / ".config" / "wireplumber" / "wireplumber.conf.d" / "51-raybit-soft-mixer.conf",
            0o644,
        ),
        ("home/.config/fastfetch/config.jsonc", home / ".config" / "fastfetch" / "config.jsonc", 0o644),
        ("home/.config/nvim/init.lua", home / ".config" / "nvim" / "init.lua", 0o644),
        ("home/.config/rofi/config.rasi", home / ".config" / "rofi" / "config.rasi", 0o644),
        ("home/.config/user-dirs.dirs", home / ".config" / "user-dirs.dirs", 0o644),
        ("home/monitor-config.py", home / "monitor-config.py", 0o755),
        ("home/.local/bin/git-tools", home / ".local" / "bin" / "git-tools", 0o755),
        ("home/.local/bin/github-tools", home / ".local" / "bin" / "github-tools", 0o755),
        ("home/.local/bin/jira-tools", home / ".local" / "bin" / "jira-tools", 0o755),
        ("home/.local/bin/lock-screen", home / ".local" / "bin" / "lock-screen", 0o755),
        ("home/.local/bin/monitor-layout", home / ".local" / "bin" / "monitor-layout", 0o755),
        ("home/.local/bin/screenshot-region", home / ".local" / "bin" / "screenshot-region", 0o755),
        ("home/.local/bin/waybar-audio-menu.zig", home / ".local" / "bin" / "waybar-audio-menu.zig", 0o644),
        (
            "home/.local/bin/waybar-network-menu.zig",
            home / ".local" / "bin" / "waybar-network-menu.zig",
            0o644,
        ),
        ("home/.local/bin/waybar-power-menu", home / ".local" / "bin" / "waybar-power-menu", 0o755),
        ("home/.local/bin/wallpaper-rotate.zig", home / ".local" / "bin" / "wallpaper-rotate.zig", 0o644),
        (
            "home/.local/share/applications/com.mitchellh.ghostty.desktop",
            home / ".local" / "share" / "applications" / "com.mitchellh.ghostty.desktop",
            0o644,
        ),
    ]
    if bool(config.get("is_vm")):
        asset_copy_map.append(
            ("home/.local/bin/ghostty-launch", home / ".local" / "bin" / "ghostty-launch", 0o755)
        )
    for source_name, destination, mode in asset_copy_map:
        copy_file(asset_file(source_name), destination, mode, owner=owner)

    configure_default_applications(username)

    build_user_zig_tool(
        username,
        home / ".local" / "bin" / "wallpaper-rotate.zig",
        home / ".local" / "bin" / "wallpaper-rotate",
    )
    build_user_zig_tool(
        username,
        home / ".local" / "bin" / "waybar-audio-menu.zig",
        home / ".local" / "bin" / "waybar-audio-menu",
    )
    build_user_zig_tool(
        username,
        home / ".local" / "bin" / "waybar-network-menu.zig",
        home / ".local" / "bin" / "waybar-network-menu",
    )
    build_sway_workspace_tool(username)


def prime_neovim(username: str) -> None:
    run_as_user(
        username,
        ["nvim", "--headless", "+Lazy! sync", "+qa"],
    )


def enable_services(config: dict[str, object]) -> None:
    run(["systemctl", "enable", "NetworkManager.service"])
    run(["systemctl", "enable", "systemd-timesyncd.service"])
    run(["systemctl", "enable", "sshd.service"])
    if bool(config.get("is_vm")):
        run(["systemctl", "enable", "vmtoolsd.service"], check=False)
        run(["systemctl", "enable", "vmware-vmblock-fuse.service"], check=False)
    run(["systemctl", "disable", "ly@tty2.service"], check=False)
    run(["systemctl", "enable", "lightdm.service"])


def clone_repo(repo_url: str, destination: Path, ref: str | None = None) -> None:
    if destination.exists():
        shutil.rmtree(destination)
    clone_command = ["git", "clone", repo_url, str(destination)]
    if ref is None:
        clone_command[2:2] = ["--depth", "1"]
    run(clone_command)
    if ref is not None:
        run(["git", "checkout", "--detach", ref], cwd=str(destination))


def ensure_source_build_zig() -> Path:
    INSTALLER_BUILD_ROOT.mkdir(parents=True, exist_ok=True)
    zig_dir = INSTALLER_BUILD_ROOT / f"zig-{SOURCE_BUILD_ZIG_VERSION}"
    zig = zig_dir / "zig"
    if zig.exists():
        return zig

    archive = INSTALLER_BUILD_ROOT / f"zig-{SOURCE_BUILD_ZIG_VERSION}.tar.xz"
    extracted = INSTALLER_BUILD_ROOT / f"zig-x86_64-linux-{SOURCE_BUILD_ZIG_VERSION}"
    run(["curl", "-fL", SOURCE_BUILD_ZIG_URL, "-o", str(archive)])
    run(["tar", "-C", str(INSTALLER_BUILD_ROOT), "-xf", str(archive)])
    if not (extracted / "zig").exists():
        fail(f"Downloaded Zig {SOURCE_BUILD_ZIG_VERSION}, but {extracted / 'zig'} is missing.")
    extracted.rename(zig_dir)
    return zig


def install_mpvpaper() -> None:
    mpvpaper_dir = INSTALLER_BUILD_ROOT / "mpvpaper"
    INSTALLER_BUILD_ROOT.mkdir(parents=True, exist_ok=True)

    clone_repo(MPVPAPER_REPO, mpvpaper_dir, MPVPAPER_REF)
    run(["meson", "setup", "build", "--prefix", "/usr/local"], cwd=str(mpvpaper_dir))
    run(["meson", "compile", "-C", "build"], cwd=str(mpvpaper_dir))
    run(["meson", "install", "-C", "build"], cwd=str(mpvpaper_dir))

    man_source = mpvpaper_dir / "mpvpaper.man"
    if man_source.exists():
        copy_file(man_source, Path("/usr/local/share/man/man1/mpvpaper.1"), 0o644)


def install_backgrounds(username: str) -> None:
    background_checkout = INSTALLER_BUILD_ROOT / "root-and-rail"
    clone_repo(BACKGROUND_REPO, background_checkout)

    home = Path("/home") / username
    target_dir = home / "backgrounds"
    owner = user_ids(username)
    ensure_dir(target_dir, owner=owner)

    images_dir = background_checkout / "images"
    if not images_dir.exists():
        fail("root-and-rail checkout is missing the images directory.")
    copied = 0
    installed_login_background = False
    for source in images_dir.iterdir():
        if not source.is_file():
            continue
        if source.stat().st_size == 0:
            fail(f"Background image is empty in source checkout: {source}")
        destination = target_dir / source.name
        copy_file(source, destination, 0o644, owner=owner)
        if destination.stat().st_size == 0:
            fail(f"Background image copy produced an empty file: {destination}")
        if source.name == LOGIN_BACKGROUND_NAME:
            copy_file(source, LOGIN_BACKGROUND_PATH, 0o644)
            installed_login_background = True
        copied += 1
    if copied == 0:
        fail("No background images were copied into the user background directory.")
    if not installed_login_background:
        fail(f"Login background was not found in root-and-rail checkout: {LOGIN_BACKGROUND_NAME}")


def install_go_grip(username: str) -> None:
    home = Path("/home") / username
    gobin = home / ".local" / "bin"
    ensure_dir(gobin, owner=user_ids(username))
    run_as_user(
        username,
        ["go", "install", GO_GRIP_MODULE],
        extra_env={"GOBIN": str(gobin)},
    )


def finalize_home_ownership(username: str) -> None:
    run(["chown", "-R", f"{username}:{username}", str(Path("/home") / username)])


def load_config(path_arg: str | None) -> dict[str, object]:
    if not path_arg:
        fail("A config path is required for the chroot phase.")
    path = Path(path_arg)
    if not path.exists():
        fail(f"Config file does not exist: {path}")
    return json.loads(path.read_text(encoding="utf-8"))


def collect_config() -> dict[str, object]:
    config = dict(DEFAULT_CONFIG)
    apply_detected_hardware_defaults(config)
    config["hostname"] = prompt("Hostname", str(config["hostname"]))
    config["timezone"] = prompt("Timezone", str(config["timezone"]))
    config["locale"] = prompt("Locale", str(config["locale"]))
    config["keymap"] = prompt("Keymap", str(config["keymap"]))
    config["username"] = prompt("Username")
    config["root_password"] = prompt_password("Root password")
    config["user_password"] = prompt_password(f"Password for {config['username']}")
    config["target_disk"] = prompt_wipe_target(config)
    return config


def run_iso_install() -> None:
    require_root()
    require_uefi()
    network_config = connect_network()

    config = collect_config()
    config.update(network_config)
    validate_disk(str(config["target_disk"]))

    esp_partition, root_partition = partition_paths(str(config["target_disk"]))
    config["esp_partition"] = esp_partition
    config["root_partition"] = root_partition

    refresh_clock_and_keys()
    cleanup_mounts()
    partition_disk(str(config["target_disk"]))
    format_and_mount(esp_partition, root_partition)
    pacstrap_system(config)
    copy_live_networkmanager_profile(config)

    config_path = stage_support_files(config)
    try:
        run_chroot_phase(config_path)
    except subprocess.CalledProcessError:
        print(
            f"\nChroot setup failed. Inspect {STAGE_LOG_PATH} from the live environment for the failing command.",
            file=sys.stderr,
        )
        raise
    cleanup_stage_dir()

    print("\nInstall complete.")
    print("Reboot and log in through LightDM.")
    print("If LightDM asks for a session, choose 'Sway'.")


def run_chroot_setup(config_path: str | None) -> None:
    require_root()
    config = load_config(config_path)
    print(f"Using assets from {resolve_assets_dir()}")

    try:
        configure_system_identity(config)
        install_bootloader(config)
        set_password("root", str(config["root_password"]))
        ensure_user(str(config["username"]), str(config["user_password"]))
        install_machine_files()
        install_codex()
        install_user_files(config)
        install_qutebrowser_workarounds()
        prime_neovim(str(config["username"]))
        install_mpvpaper()
        install_backgrounds(str(config["username"]))
        install_go_grip(str(config["username"]))
        enable_services(config)
        finalize_home_ownership(str(config["username"]))
    except Exception:
        if config_path:
            print(
                f"\nChroot setup failed. Preserving config at {config_path} and log at {CHROOT_STAGE_LOG_PATH}.",
                file=sys.stderr,
            )
        raise
    if config_path:
        Path(config_path).unlink(missing_ok=True)

    print("\nChroot setup complete.")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--phase", choices=["iso", "chroot"], default="iso")
    parser.add_argument("--config", help="Path to the staged install config")
    args = parser.parse_args()

    if args.phase == "iso":
        run_iso_install()
    else:
        run_chroot_setup(args.config)


if __name__ == "__main__":
    main()
