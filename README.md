# termux-server-setup

An interactive setup script that turns an Android phone into a small self-hosting server using [Termux](https://termux.dev). Answer a few questions, and it installs and configures your choice of:

| Service | What it's for | Port |
|---|---|---|
| **Jellyfin** | Media server (movies, music, photos) | 8096 |
| **File Browser Quantum** | Web UI for browsing and uploading files on your phone | 8080 |
| **copyparty** | Alternative web file manager / uploader | 3923 |
| **Syncthing** | Continuous file sync between devices | 8384 |
| **OpenSSH** | Log in to the phone from a computer | 8022 |
| **cloudflared** or **ngrok** | Public URL for a local service (tunnel) | n/a |

Everything runs natively in Termux. There is no proot or Linux container.

## Requirements

- An Android phone with **Termux installed from [F-Droid](https://f-droid.org/packages/com.termux/) or [GitHub](https://github.com/termux/termux-app/releases)**. The Play Store build is outdated and won't work properly.
- An internet connection.
- A 64-bit ARM (`aarch64`) or `x86_64` CPU for File Browser Quantum. ngrok also supports 32-bit ARM.
- Roughly 1.5 GiB or more free on internal storage. Jellyfin plus .NET needs several hundred MiB.
- Jellyfin also needs **at least 2 GiB free** on the volume that holds its data, or it refuses to start.

## Quick start

```bash
bash termux-server-setup.sh
```

The script is interactive, so run it in a Termux terminal. It reads answers from the terminal even when piped.

It's **safe to re-run**: existing pieces are detected and refreshed, and your Jellyfin data and existing configs are kept.

## What the script asks

1. **Storage access:** Tap *Allow* on the Android permission popup.
2. **OpenSSH:** Optionally installs it and has you set the Termux password. Default: yes.
3. **SD card:** If one is found, asks whether to keep all data on it. Default: yes.
4. **Jellyfin:** Install or not. Default: no.
5. **File manager:** File Browser Quantum, copyparty, both, or neither.
6. **Syncthing:** Install or not. Default: no.
7. **Tunnel:** cloudflared, ngrok, or neither. For ngrok you can paste your authtoken now or add it later.
8. **Confirmation:** A summary of what will be installed, then a final *Continue?*

After the last question it runs unattended. Slow steps run behind a spinner, and the last lines of the log are shown only if something fails. Colors and the spinner switch off automatically when output isn't a terminal. You can also set `NO_COLOR=1` to disable them.

## Commands it creates

Open a **new Termux session** (or run `source ~/.bashrc`) after setup so the aliases work.

| Command | Alias | What it does |
|---|---|---|
| `start-jellyfin` | `jf` | Start Jellyfin |
| `start-filebrowser` | `fb` | Start File Browser Quantum |
| `start-copyparty` | `cpy` | Start copyparty |
| `start-syncthing` | `st` | Start Syncthing |
| `start-tunnel [port]` | `tun` | Open a public tunnel to a local port (default `8096`) |
| `ssh-on` / `ssh-off` | | Start / stop the SSH server |
| `stop-servers [name...]` | `stop-all` (no args) | Stop one or all background services |
| `servers-help` | | Show the usage notes again |

Each service runs in the background in its own **tmux** session (`jellyfin`, `filebrowser`, `copyparty`, `syncthing`) and holds a wake lock so Android doesn't suspend it.

```bash
tmux attach -t jellyfin   # see its output (detach with Ctrl+b, then d)
stop-servers jellyfin     # stop just that one
stop-all                  # stop everything
```

## Using the services

Open `http://127.0.0.1:PORT` on the phone, or `http://PHONE_IP:PORT` from another device on the same network. The phone's IP is under *Settings > Wi-Fi*.

**Jellyfin:** Open the web UI (first start takes a minute or two), create your admin account, then add a media library and browse to a phone folder such as `/storage/emulated/0/Movies`. Phone software transcoding is slow, so prefer Direct Play.

**File Browser Quantum:** Login is `admin` with a random password, shown at the end of setup. The password is stored in `~/filebrowser/config.yaml`. It shares `/storage/emulated/0`.

**copyparty:** Login is `admin` with a random password, shown at the end of setup. The password is stored in `$PREFIX/bin/start-copyparty`. It shares `/storage/emulated/0`.

**Syncthing:** Open the web UI and set a GUI username and password under *Actions > Settings > GUI* before doing anything else. Then add your other devices by Device ID.

**SSH:** Run `ssh-on` on the phone, then connect from a computer:

```bash
ssh -p 8022 USER@PHONE_IP
```

Use the password you set during setup (change it any time with `passwd`). Run `whoami` in Termux to find `USER`.

**Tunnels:** Start the service first, then open a second Termux session and run, for example:

```bash
start-tunnel 8096   # Jellyfin
start-tunnel 8080   # File Browser
start-tunnel 3923   # copyparty
```

cloudflared prints a random `https://<random>.trycloudflare.com` URL that changes every time. ngrok shows its URL in its status screen. Press Ctrl+C to close the tunnel.

## Where things live

| Item | Location |
|---|---|
| Jellyfin data, config, cache, logs, temp | `~/.jellyfin` (or `<SD card>/termux-server/jellyfin`) |
| File Browser binary, config, database | `~/filebrowser/` |
| File Browser thumbnail cache | `~/filebrowser/cache` (or on the SD card) |
| copyparty index and thumbnails | on the SD card if used, otherwise inside the shared folder |
| ngrok config | `~/.config/ngrok/ngrok.yml` |
| Helper commands | `$PREFIX/bin/` (`svc-run`, `stop-servers`, `start-*`) |
| Aliases | `~/.bashrc`, between `# >>> termux-server-setup >>>` markers |
| Usage notes | `~/servers-readme.txt` |

### SD card behavior

If an SD card is detected, everything big and growing goes there: Jellyfin's database, metadata, cache, transcodes and temp files, plus thumbnail caches. Program files (Jellyfin, .NET, binaries) always stay on internal storage, because Android can't run programs from an SD card.

Before using the card, the script runs a SQLite locking test on it. Some SD filesystems fail it, which would cause "database is locked" errors in Jellyfin. If the test fails, the script falls back to internal storage automatically.

If you insert a card after first running Termux, run `termux-setup-storage`, allow it, then re-run the script.

## Keeping it running on Android

- Set *Settings > Apps > Termux > Battery* to **Unrestricted**.
- Keep the Termux notification visible, and don't swipe Termux away in Recents.
- On Android 12+, the "phantom process killer" can kill background processes. If services die randomly, enable *Developer options > Disable child process restrictions* (Android 14+), or disable it via adb.

## Updating

| What | How |
|---|---|
| Jellyfin | `pkg upgrade jellyfin-server` (or re-run the script) |
| File Browser | Re-run the script (downloads the latest release) |
| copyparty | `pip install --upgrade --no-cache-dir copyparty` |
| Everything else | `pkg upgrade` |

## Security

- **File Browser and copyparty share your entire phone storage** (`/storage/emulated/0`).
- The generated passwords are stored **in plain text** in `~/filebrowser/config.yaml` and `$PREFIX/bin/start-copyparty`, and they are printed in the end-of-setup notes and saved in `~/servers-readme.txt`.
- **A tunnel puts the service on the public internet.** Use strong passwords and keep the tunnel open only while you need it. Exposing the Syncthing GUI this way is not recommended.
- The script downloads binaries from GitHub (File Browser), ngrok's servers, and PyPI (copyparty). You're trusting those sources.

## Troubleshooting

| Problem | Try |
|---|---|
| Jellyfin refuses to start | It needs 2 GiB or more free where its data lives. Free up space or use the SD card. |
| Jellyfin shows "database is locked" | The data folder is on a filesystem without SQLite locking support. Re-run the script and decline the SD card option. |
| Package installs fail | Check your network, then run `termux-change-repo` and `pkg update`. |
| Phone files don't appear in a service | Run `termux-setup-storage` and allow storage access. |
| Services die randomly | See *Keeping it running on Android* above. |
| ngrok says it needs an authtoken | Get one from the [ngrok dashboard](https://dashboard.ngrok.com/get-started/your-authtoken), then run `ngrok config add-authtoken YOUR_TOKEN --config ~/.config/ngrok/ngrok.yml`. |
| File Browser exits at startup after an upgrade | An old-format config is moved to `config.yaml.v1.bak` and a new one is written. Your old password won't carry over. |

## Uninstalling

The script has no uninstaller. To remove what it created:

```bash
stop-all
rm -f $PREFIX/bin/{svc-run,stop-servers,start-jellyfin,start-filebrowser,start-copyparty,start-syncthing,start-tunnel}
rm -rf ~/.jellyfin ~/filebrowser ~/.config/ngrok ~/servers-readme.txt
sed -i '/# >>> termux-server-setup >>>/,/# <<< termux-server-setup <<</d' ~/.bashrc
```

If you used an SD card, also delete its `termux-server` folder (under `Android/data/com.termux/files`). To remove the packages themselves, use `pkg uninstall jellyfin-server syncthing cloudflared` (and `pip uninstall copyparty`).
