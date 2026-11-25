# Google Drive Pi NAS

Build and recovery notes for Raspberry Pi OS Lite on a separate boot device and one data SSD. Run the shell commands in Bash as the Pi login user with sudo access. Examples use hostname `nas`.

| Purpose | Storage | Access |
|---|---|---|
| NAS archive | Existing Google Drive folder mounted at `/srv/nas` | Windows Samba share `\\nas\nas` and read-only NFS at `/mnt/nas` on the streamer |
| rclone VFS cache | `/mnt/nasdata/rclone-cache` | Private to the Pi |
| Windows profile backup and retained versions | `/mnt/nasdata/syncthing/dframe` | Syncthing from Windows (Send Only) to Pi (Receive Only), LAN only |

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

**Recovery with a surviving SSD:** skip this entire section and mount the existing filesystem using its UUID. Partitioning and formatting erase data.

Choose the whole data disk by model, serial and capacity. USB and NVMe names vary. A stable whole-disk symlink under `/dev/disk/by-id/` is convenient. Confirm that the OS, boot and swap are elsewhere and that no target partition is mounted. Use interactive Parted so the target and layout are visible before formatting.

```bash
read -r -p 'Whole empty SSD device: ' DISK
lsblk -o NAME,TYPE,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINTS "$DISK"
sudo parted "$DISK"
```

At the Parted prompt, run `print` and verify the device. Use one ext4 partition spanning the available disk space.

```text
mklabel gpt
mkpart nasdata ext4 1MiB 100%
print
quit
```

Verify the new partition label and size, then enter its partition path.

```bash
sudo udevadm settle
lsblk -o PATH,TYPE,PARTLABEL,SIZE,FSTYPE,MOUNTPOINTS "$DISK"
read -r -p 'New nasdata partition path: ' DATA_PART
sudo mkfs.ext4 -L pinas-data "$DATA_PART"
```

## Mount the SSD filesystem

Use `lsblk -f` to obtain the data partition’s filesystem UUID. Create the directories and use `sudoedit /etc/fstab` to add this entry, substituting the UUID. Preserve the existing OS entries.

```fstab
UUID=<data-uuid> /mnt/nasdata ext4 defaults,nofail 0 2
```

```bash
sudo mkdir -p /mnt/nasdata /srv/nas
sudo chmod 000 /srv/nas
sudo systemctl daemon-reload
sudo mount /mnt/nasdata
findmnt --mountpoint /mnt/nasdata
```

Confirm the mounted filesystem matches the SSD before creating its subdirectories. The empty underlying Samba path has mode 000 so a disconnected Drive mount cannot silently accept files there from the Samba user.

```bash
mountpoint -q /mnt/nasdata && sudo install -d -m 700 /mnt/nasdata/rclone-cache
mountpoint -q /mnt/nasdata && sudo install -d -m 700 -o "$(id -un)" -g "$(id -gn)" /mnt/nasdata/syncthing/dframe
```

## Mount one fixed Google Drive folder

This system service uses a root-owned config. Run `sudo -H rclone config`, add a Google Drive remote named `gdrive`, and complete authorisation. On a headless Pi, answer **no** to browser-based authentication and run the exact `rclone authorize ...` command shown by the Pi in an existing Windows PowerShell session with rclone installed. Finish Google sign-in in the browser, then return to **PowerShell** for the JSON token printed between markers; paste the complete token at the Pi's `config_token>` prompt. If a separate console window closes too quickly, run the command directly in an existing PowerShell window rather than double-clicking a shortcut. Never commit the token, client secret or `rclone.conf` to Git. For a personal NAS containing ordinary files, consider the Drive advanced option `skip_gdocs = true` to hide Google-native Docs/Sheets/Slides from the filesystem without deleting them from Drive. Keep the resulting config private. The example below assumes an existing folder named `NAS` in My Drive. Set the remote path and cache target before installing the service. Choose a cache target that leaves room for the Windows profile backup and its version history. Open files and pending uploads can temporarily push the cache above its target. Check available space with `df -h /mnt/nasdata`.

```bash
sudo -H rclone lsf 'gdrive:NAS' --max-depth 1
sudoedit /etc/default/pinas-rclone
```

```ini
DRIVE_PATH="gdrive:NAS"
CACHE_LIMIT=250G
```

Create a dedicated group for Samba access before installing the service. The Pi login user remains the filesystem owner; the `nasaccess` group grants the dedicated Samba account access. The shell inserts the login user's numeric UID and the group's numeric GID into the unit. The service reads the two settings from the environment file at startup.

```bash
sudo groupadd -f nasaccess
NAS_GID=$(getent group nasaccess | cut -d: -f3)
```

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
ExecStart=/usr/bin/rclone mount \${DRIVE_PATH} /srv/nas --allow-other --uid $(id -u) --gid ${NAS_GID} --umask 007 --cache-dir /mnt/nasdata/rclone-cache --vfs-cache-mode full --vfs-cache-max-size \${CACHE_LIMIT}
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

Use a dedicated, non-login Samba account instead of exposing the Pi administrator's account. Samba passwords are separate from Linux passwords; set a **nonblank** password when prompted. The `nasaccess` group permits access to the rclone mount (which is owned by the Pi login user with group permissions `0770`).

```bash
sudo useradd --no-create-home --shell /usr/sbin/nologin nasuser
sudo usermod -aG nasaccess nasuser
sudo smbpasswd -a nasuser
sudo smbpasswd -e nasuser
id nasuser
sudo -u nasuser ls /srv/nas
```

Append this share to `/etc/samba/smb.conf`:

```ini
[nas]
    path = /srv/nas
    browseable = yes
    read only = no
    guest ok = no
    valid users = nasuser
    force group = nasaccess
```

```bash
sudo testparm -s
sudo systemctl enable --now smbd
sudo systemctl restart smbd
```

Open `\\\\nas\\nas` in Windows Explorer and sign in as `nasuser` with its Samba password (use `nas\\nasuser` if Windows needs an explicit server-qualified username). Use the Pi's LAN IP if hostname resolution is unavailable. Create a small test file in the share's `Temp` folder and verify that it eventually appears in the Google Drive web interface. The apparent Windows write speed initially reflects the local NVMe cache; the file is not safely uploaded to Google Drive until rclone finishes write-back. Check `systemctl status pinas-rclone` for pending uploads. Do not discard the cache while uploads are pending.

## Windows personal Google Drive letter (optional)

On the Windows PC, Google Drive for desktop mounts the full Drive as **H:**. To keep the `NAS` and other sibling folders out of the everyday view, use a separate **G:** letter pointing to `H:\My Drive\David`. This is a view of the same files, not a copy or another sync. The Pi's Samba share remains `\\nas\nas`.

1. Save [`windows/GoogleDrive-G-Mapping.ps1`](windows/GoogleDrive-G-Mapping.ps1) to a permanent local path, e.g. `C:\Users\david\Scripts\GoogleDrive-G-Mapping.ps1`. Change `$source` if the Google Drive folder or drive letter differs.
2. In **Task Scheduler**, choose **Create Task** (not Basic Task). Name it **Google Drive Personal Mapping**. Use **Run only when user is logged on**, without **Run with highest privileges**.
3. Add an **At log on** trigger for the Windows account. Add a **Start a program** action with program `powershell.exe` and arguments:

   ```text
   -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\Users\david\Scripts\GoogleDrive-G-Mapping.ps1"
   ```

4. Optionally disable the AC-power-only condition. The script waits up to five minutes for `H:\My Drive\David`, then maps G: without overwriting another mapping. Check `%LOCALAPPDATA%\GoogleDrive-G-Mapping.log` for success/errors.
5. To **hide H: from This PC** (cosmetic only), open PowerShell **as Administrator, in the same Windows account**, and run this one-line command:

   ```powershell
   reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v NoDrives /t REG_DWORD /d 128 /f
   ```

   Value `128` (hex `0x80`) hides drive H. **Caution:** this overwrites any existing `NoDrives` bitmask; inspect and combine values first if other drives are already hidden. The policy is persistent and does **not** need to be set by the logon script. H: remains accessible by path; this is not an access-control measure. The alternative `HKCU\...\CurrentVersion\Explorer` location did not hide the drive in this setup.
6. **Sign out and back in**. Google Drive may take ~30 seconds to mount H: and for the script to create G:. Verify G: opens the David folder and H: does not appear in **This PC**. Google Drive's own navigation entry may still be shown separately.

To undo: run `subst G: /D`, disable or delete the scheduled task, and remove the `NoDrives` value with `reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v NoDrives /f` **only if that value was dedicated to hiding H:**. Sign out and back in to refresh Explorer.

## Read the same archive over NFS on the streamer

Samba writes to the Drive folder configured by `DRIVE_PATH`. A second rclone service reads that same remote for playback. A file added through Windows becomes visible on the streamer after upload and directory-cache refresh. Syncthing's Windows profile backup stays on the local SSD.

### On the NAS

Run `/usr/bin/rclone serve nfs --help` to check the installed binary supports this experimental NFSv3 server (introduced in rclone 1.65). If the command is missing, install a supported rclone version and verify the binary path used by both units. Reserve a NAS LAN IP and replace `NAS_LAN_IP` below. The endpoint has no authentication. Before starting it, restrict inbound TCP port 32049 on the NAS firewall to the streamer's reserved IP, including on a shared LAN.

Save this unit as `/etc/systemd/system/pinas-nfs.service`.

```ini
[Unit]
Description=Read-only Google Drive archive for the streamer
Wants=network-online.target
After=network-online.target

[Service]
Environment=HOME=/root
EnvironmentFile=/etc/default/pinas-rclone
ExecStart=/usr/bin/rclone serve nfs ${DRIVE_PATH} --addr NAS_LAN_IP:32049 --read-only --vfs-cache-mode off
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now pinas-nfs
sudo systemctl status pinas-nfs
```

### On the streamer

Install `nfs-common`, create the mount point with `sudo mkdir -p /mnt/nas`, and add this line to `/etc/fstab` using the same NAS IP. Both ports refer to the single rclone listener.

```fstab
NAS_LAN_IP:/ /mnt/nas nfs ro,vers=3,proto=tcp,mountproto=tcp,port=32049,mountport=32049,nolock,_netdev,nofail,x-systemd.automount 0 0
```

```bash
sudo systemctl daemon-reload
sudo systemctl start mnt-nas.automount
ls /mnt/nas
findmnt --mountpoint /mnt/nas --types nfs
```

Open a known FLAC from the Windows share and play the same file from `/mnt/nas` on the streamer. If restarting the NFS service produces a stale file handle, close playback, leave the mount directory and run `sudo systemctl restart mnt-nas.mount` on the streamer.

[rclone NFS server documentation](https://rclone.org/commands/rclone_serve_nfs/)

## Back up the Windows user profile with Syncthing

This is a **local-only backup**, separate from the Google Drive archive. The Windows Framework laptop runs Syncthing through **SyncTrayzor v2**; the Pi runs the Raspberry Pi OS `syncthing` package as `syncthing@pi.service`. The source is `C:\Users\David`; the Pi destination is `/mnt/nasdata/syncthing/dframe`. The Windows folder is **Send Only** and the Pi folder is **Receive Only**, with **Staggered File Versioning on the Pi**. The folder ID must be **identical** on both devices (the displayed folder label can differ).

### Pi service and SSD dependency

Install the package (also listed in the initial package-install command), prepare the destination **only after the SSD is mounted**, and make Syncthing depend on the SSD mount. Do not let a missing SSD silently redirect the backup onto the boot card.

```bash
sudo apt install syncthing
mountpoint -q /mnt/nasdata || { echo "SSD not mounted"; exit 1; }
sudo install -d -m 700 -o pi -g pi /mnt/nasdata/syncthing/dframe
sudo mkdir -p /etc/systemd/system/syncthing@pi.service.d
sudo tee /etc/systemd/system/syncthing@pi.service.d/storage.conf >/dev/null <<'EOF'
[Unit]
RequiresMountsFor=/mnt/nasdata
ConditionPathIsMountPoint=/mnt/nasdata
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now syncthing@pi.service
systemctl status syncthing@pi.service
```

The override above is a **recommended recovery safeguard** from the original build instructions; verify it is installed on the running Pi with `systemctl cat syncthing@pi.service`. If the Pi login user is not `pi`, substitute the actual username in the commands and service name.

### Pair devices and configure the folders

1. On Windows, install and launch **SyncTrayzor v2** and open its Syncthing dashboard. Add the Windows profile folder `C:\Users\David` with a chosen folder ID, set **Folder Type = Send Only**, and enable **Watch for Changes**.
2. On the Pi, open its Syncthing dashboard and pair the devices using their device IDs. Accept the shared folder using the **same folder ID**, set **Folder Path = /mnt/nasdata/syncthing/dframe**, **Folder Type = Receive Only**, and **File Versioning = Staggered File Versioning**.
3. Configure version retention in the Pi dashboard to suit available disk space. Versioned files live under the destination's `.stversions` directory. Deleted files should disappear from the live destination but can be restored from version history (subject to retention and successful synchronization).
4. Allow the initial scan and transfer to finish. Check **Up to Date** and **Out of Sync Items** on both devices. A 3600-second full rescan is normal: with filesystem watching enabled, ordinary changes usually propagate within seconds, without waiting for the hourly scan.

### Windows ignore patterns

Enter these under the Windows source folder's **Edit → Ignore Patterns**. This is the set configured during the build, not an automatically generated exclusion list. Syncthing's `(?d)` marker permits cleanup of ignored files on the receiving side. Review patterns if new folders or development workflows are added.

```text
(?d)AppData
(?d)Downloads
(?d)NTUSER.*
(?d)ntuser.ini
(?d)OneDrive
(?d)Google Drive
(?d).cache
(?d)Application Data
(?d)Local Settings
(?d)Cookies
(?d)NetHood
(?d)PrintHood
(?d)Recent
(?d)SendTo
(?d)Start Menu
(?d)Templates
(?d)**/node_modules
(?d)**/.venv
(?d)**/venv
(?d)**/__pycache__
(?d)**/.git/objects
.codex/.codex-provisioning-*.guard
```

**Review `(?d)**/.git/objects` carefully:** it excludes local Git object history (including unpushed commits) from this backup. For a more complete developer backup, remove this exclusion and allow Git repositories to synchronize in full. Avoid adding broad exclusions for build directories if they might contain important originals.

### LAN-only connections and dashboard

On **both** Windows and Pi, under **Actions → Settings → Connections**, disable **Global Discovery**, **Relaying**, and **NAT Traversal**; leave **Local Discovery** enabled. Confirm the connected device uses a local IP and no relay address. Syncthing's device synchronization typically uses TCP/QUIC port **22000** and local discovery uses UDP **21027**. No router port forwarding is required.

The Pi dashboard was initially accessed through an SSH tunnel:

```bash
ssh -L 8384:127.0.0.1:8384 pi@nas
```

Then browse `http://localhost:8384` on Windows. For the **LAN-accessible** dashboard, configure **Actions → Settings → GUI** on the Pi: bind the GUI to the Pi's LAN address (or `0.0.0.0:8384` if appropriately firewalled), set a strong GUI username/password, and enable HTTPS. Access it at `https://nas:8384` (a self-signed certificate warning is expected). Restrict port **8384** to trusted LAN clients; never forward it from the internet. The LAN GUI change was discussed during setup; confirm its exact bind, HTTPS and authentication settings on the Pi rather than assuming they are already active.

### Recovery and operational checks

```bash
systemctl is-active syncthing@pi.service
systemctl cat syncthing@pi.service
findmnt --mountpoint /mnt/nasdata
df -h /mnt/nasdata
journalctl -u syncthing@pi.service -p warning --since "24 hours ago"
```

Create a small file under `C:\Users\David`, wait for it to appear in `/mnt/nasdata/syncthing/dframe`, then delete it on Windows. The live Pi copy should be deleted too, with a recoverable version in `.stversions` if versioning captured it. This create/delete/versioning flow was successfully tested during setup; test **restoration** separately. Syncthing is not an immutable or off-site backup: the Pi SSD holds the only version-history copy, and SSD failure can lose that history. After a reinstall, pair the new Syncthing device identity and verify folder paths and directions **before** enabling synchronization to avoid unwanted deletions.

## Verify and recover

1. Reboot after configuring rclone to verify that the NVMe SSD mounts first and `pinas-rclone` starts automatically. Check both `/mnt/nasdata` and `/srv/nas` with `findmnt --mountpoint PATH` for each. Check `systemctl status pinas-rclone smbd "syncthing@$(id -un)"`.
2. Write a small test file via Explorer. Confirm it appears in the intended folder in the Google Drive web interface after write-back. Open a Drive file through Samba to check reads.
3. Create a test file in the Windows user profile, wait for Syncthing to report up to date, then edit it. Confirm the Pi has the new content and an older version is available.
4. If rclone reports permission denied creating `/mnt/nasdata/rclone-cache`, first check the SSD mount and kernel log. On the USB test Pi, remounting the data disk resolved this symptom. Preserve the cache during recovery because writes may still be queued. Inspect `journalctl -u pinas-rclone -b` before restarting the service.
5. After boot-device failure, restore Raspberry Pi OS, remount the surviving data partition, restore or reauthorise the remote, and recreate the services above. Restore the original login UID/GID or correct the Syncthing backup directory ownership. A fresh Syncthing identity needs pairing again. After data-SSD failure, Drive can supply uploaded archive files and the laptop can supply current Windows profile files. Versions held solely on the failed SSD require a separate backup.

References: [rclone mount](https://rclone.org/commands/rclone_mount/), [Samba share settings](https://www.samba.org/samba/docs/current/man-html/smb.conf.5.html), [Syncthing versioning](https://docs.syncthing.net/users/versioning.html).
