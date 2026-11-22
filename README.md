# Google Drive Pi NAS

Build and recovery notes for Raspberry Pi OS Lite on a separate boot device and one data SSD. Run the shell commands in Bash as the Pi login user with sudo access. Examples use hostname `pinas`.

| Purpose | Storage | Access |
|---|---|---|
| NAS archive | Existing Google Drive folder mounted at `/srv/nas` | Windows Samba share `\\pinas\nas` |
| rclone VFS cache | SSD partition 1 at `/mnt/nasdata` | Private to the Pi |
| Laptop projects and retained versions | SSD partition 2 at `/mnt/projects` | Syncthing between laptop and Pi |

The archive streams from Drive. The cache holds recently accessed data and can temporarily hold the only copy of pending uploads.

## Prepare the new Pi

Install Raspberry Pi OS on the boot device first. Set the hostname and create the login user using Raspberry Pi Imager. On the running Pi:

```bash
sudo apt update
sudo apt install parted e2fsprogs rclone fuse3 samba syncthing
lsblk -o NAME,PATH,TYPE,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINTS
findmnt /
```

## Partition a new, empty data SSD

**Recovery with a surviving SSD:** skip this entire section and mount its existing filesystems using their UUIDs. Partitioning and formatting erase data.

Choose the whole data disk by model, serial and capacity. USB and NVMe names vary. A stable whole-disk symlink under `/dev/disk/by-id/` is convenient. Confirm that the OS, boot and swap are elsewhere and that no target partition is mounted. Use interactive Parted so the target and layout are visible before formatting.

```bash
read -r -p 'Whole empty SSD device: ' DISK
lsblk -o NAME,TYPE,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINTS "$DISK"
sudo parted "$DISK"
```

At the Parted prompt, run `print` and verify the device. Example layout for a nominal 1 TB disk: 300 GiB cache, remaining space for projects. Substitute your own boundaries. For a fixed 500 GiB projects partition following this cache, use `819201MiB` as the second end instead of `100%`.

```text
mklabel gpt
mkpart rclone-cache ext4 1MiB 307201MiB
mkpart projects ext4 307201MiB 100%
print
quit
```

Inspect the resulting paths. Enter the two **partition** paths from that listing after verifying their names and sizes.

```bash
sudo udevadm settle
lsblk -o PATH,TYPE,PARTLABEL,SIZE,FSTYPE,MOUNTPOINTS "$DISK"
read -r -p 'New rclone-cache partition path: ' CACHE_PART
read -r -p 'New projects partition path: ' PROJECTS_PART
sudo mkfs.ext4 -L pinas-cache "$CACHE_PART"
sudo mkfs.ext4 -L pinas-projects "$PROJECTS_PART"
```

## Mount the SSD filesystems

Use `lsblk -f` to obtain both filesystem UUIDs. Create the directories and use `sudoedit /etc/fstab` to add these two entries, substituting the UUIDs. Preserve the existing OS entries.

```fstab
UUID=<cache-uuid>     /mnt/nasdata   ext4 defaults,nofail 0 2
UUID=<projects-uuid>  /mnt/projects  ext4 defaults,nofail 0 2
```

```bash
sudo mkdir -p /mnt/nasdata /mnt/projects /srv/nas
sudo chmod 000 /srv/nas
sudo systemctl daemon-reload
sudo mount /mnt/nasdata
sudo mount /mnt/projects
findmnt --mountpoint /mnt/nasdata
findmnt --mountpoint /mnt/projects
```

Confirm both entries match the SSD before creating their subdirectories. The empty underlying Samba path has mode 000 so a disconnected Drive mount cannot silently accept files there from the Samba user.

```bash
mountpoint -q /mnt/nasdata && sudo install -d -m 700 /mnt/nasdata/rclone-cache
mountpoint -q /mnt/projects && sudo install -d -m 700 -o "$(id -un)" -g "$(id -gn)" /mnt/projects/laptop-projects
```

## Mount one fixed Google Drive folder

This system service uses a root-owned config. Run `sudo -H rclone config`, add a Google Drive remote named `gdrive`, and complete authorisation. For a headless Pi, follow rclone's authorisation prompt on a machine with a browser. Keep the resulting config private. The example below assumes an existing folder named `NAS` in My Drive. Set the remote path and cache target before installing the service. Leave space between the target and partition capacity for open files and writes awaiting upload.

```bash
sudo -H rclone lsf 'gdrive:NAS' --max-depth 1
sudoedit /etc/default/pinas-rclone
```

```ini
DRIVE_PATH="gdrive:NAS"
CACHE_LIMIT=250G
```

Run this block as the login user who will access the Samba share. The shell inserts that user's numeric UID and GID into the unit. The service reads the two settings from the environment file at startup.

```bash
sudo tee /etc/systemd/system/pinas-rclone.service >/dev/null <<EOF
[Unit]
Description=Google Drive NAS mount
Wants=network-online.target
After=network-online.target
RequiresMountsFor=/mnt/nasdata
ConditionPathIsMountPoint=/mnt/nasdata

[Service]
Type=notify
Environment=HOME=/root
EnvironmentFile=/etc/default/pinas-rclone
ExecStart=/usr/bin/rclone mount \${DRIVE_PATH} /srv/nas --allow-other --uid $(id -u) --gid $(id -g) --umask 077 --cache-dir /mnt/nasdata/rclone-cache --vfs-cache-mode full --vfs-cache-max-size \${CACHE_LIMIT}
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now pinas-rclone
findmnt --mountpoint /srv/nas
```

## Share the archive with Windows

Append this share to `/etc/samba/smb.conf`, substituting the actual Pi login for `PI_LOGIN`.

```ini
[nas]
    path = /srv/nas
    browseable = yes
    read only = no
    guest ok = no
    valid users = PI_LOGIN
```

```bash
sudo smbpasswd -a "$(id -un)"
sudo testparm -s && sudo systemctl enable --now smbd && sudo systemctl reload smbd
```

Open `\\pinas\nas` in Explorer and sign in with the Samba credentials. Use the Pi's LAN IP if hostname resolution is unavailable.

## Receive laptop projects on partition 2

Use the packaged Syncthing service under the Pi login. Give it a dependency on the projects mount before enabling it.

```bash
unit="syncthing@$(id -un).service"
sudo mkdir -p "/etc/systemd/system/$unit.d"
sudo tee "/etc/systemd/system/$unit.d/storage.conf" >/dev/null <<'EOF'
[Unit]
RequiresMountsFor=/mnt/projects
ConditionPathIsMountPoint=/mnt/projects
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now "$unit"
```

From the laptop, use `ssh -L 8385:127.0.0.1:8384 PI_LOGIN@pinas` and open `http://localhost:8385` for the Pi's Syncthing interface. Pair the two devices. Share the laptop Projects folder as **Send Only**. Accept it on the Pi at `/mnt/projects/laptop-projects` as **Receive Only** and enable **Staggered File Versioning** there. Current files and retained versions share the second partition. This folder is outside the Drive mount and Samba share.

## Verify and recover

1. After reboot, check all three mount points with `findmnt --mountpoint PATH` for each. Check `systemctl status pinas-rclone smbd "syncthing@$(id -un)"`.
2. Write a small test file via Explorer. Confirm it appears in the intended folder in the Google Drive web interface after write-back. Open a Drive file through Samba to check reads.
3. Create a test project file on the laptop, wait for Syncthing to report up to date, then edit it. Confirm the Pi has the new content and an older version is available.
4. If rclone reports permission denied creating `/mnt/nasdata/rclone-cache`, first check the SSD mount and kernel log. On the USB test Pi, remounting the data disk resolved this symptom. Preserve the cache during recovery because writes may still be queued. Inspect `journalctl -u pinas-rclone -b` before restarting the service.
5. After boot-device failure, restore Raspberry Pi OS, remount the surviving partitions, restore or reauthorise the remote, and recreate the services above. Restore the original login UID/GID or correct the projects directory ownership. A fresh Syncthing identity needs pairing again. After data-SSD failure, Drive can supply uploaded archive files and the laptop can supply current projects. Versions held solely on the failed SSD require a separate backup.

References: [rclone mount](https://rclone.org/commands/rclone_mount/), [Samba share settings](https://www.samba.org/samba/docs/current/man-html/smb.conf.5.html), [Syncthing versioning](https://docs.syncthing.net/users/versioning.html).
