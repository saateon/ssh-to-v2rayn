# SSH → v2rayN

ابزار گرافیکی تک‌فایل برای افزودن، تست و حذف اتصال SSH در v2rayN.
A single-file Windows GUI tool to add, test and remove SSH connections in v2rayN.

![preview](preview.png)

## امکانات / Features
- **Smart paste**: sing-box JSON, `ssh://user:pass@host:port#name`, `host:port:user:pass`, `ssh user@host -p 22`, and seller-style text (EN/FA). Multiple connections at once.
- **Real connection test**: runs sing-box, opens a page through the SSH, and tells you OK + latency / unreachable / wrong password / no internet.
- Password or private-key login
- Auto-restart v2rayN after each change (optional)
- Each SSH gets its own local SOCKS port, so v2rayN's **TUN** and routing work on it
- Dark/Light theme follows Windows

## استفاده / Usage
Double-click `SSH-to-v2rayN.bat`, accept UAC. It looks in `C:\app` first, then other places; use **تغییر** to pick another v2rayN.

## Notes
- No install, no Python: it uses PowerShell/WPF (built into Windows) and v2rayN's own `e_sqlite3.dll` / `sing-box`. Works with v2rayN 6.x and 7.x.
- A backup of `guiNDB.db` is made before every change (`guiConfigs\ssh-tool-backups`, last 10).
- Nothing is sent anywhere. Passwords are stored only in v2rayN's local config files, exactly like any other v2rayN profile.
- SSH carries **TCP only** — UDP (WebRTC STUN, voice/video calls, games) will not work through it.

## License
MIT