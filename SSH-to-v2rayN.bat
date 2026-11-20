@echo off
title SSH to v2rayN
net session >nul 2>&1 || (
  powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath '%~f0'"
  exit /b
)
start "" powershell -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -Command "$f='%~f0'; try { $s=[IO.File]::ReadAllText($f,[Text.Encoding]::UTF8); iex $s.Substring($s.LastIndexOf('#PS_START')+9) } catch { Add-Type -AssemblyName PresentationFramework; [void][Windows.MessageBox]::Show($_.Exception.Message,'SSH to v2rayN') }"
exit /b

#PS_START

$ErrorActionPreference = 'Stop'
$SelfTest = $env:SSH2V_SELFTEST
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
$LogFile   = Join-Path $env:TEMP 'ssh2v2rayn.log'
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false
function Write-Log([string]$m) { try { Add-Content -LiteralPath $LogFile -Value ("[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $m) -Encoding UTF8 } catch {} }

# =====================================================================
#  SQLite (uses v2rayN's own e_sqlite3.dll - no external dependency)
# =====================================================================
if (-not ('Ssh2V.Sqlite' -as [type])) {
Add-Type -TypeDefinition @'
using System; using System.Collections.Generic; using System.Runtime.InteropServices; using System.Text;
namespace Ssh2V {
public static class Sqlite {
  [DllImport("kernel32", SetLastError=true, CharSet=CharSet.Unicode)] static extern IntPtr LoadLibrary(string p);
  const string L = "e_sqlite3"; const CallingConvention C = CallingConvention.Cdecl;
  [DllImport(L, CallingConvention=C)] static extern int sqlite3_open_v2(byte[] f, out IntPtr db, int flags, IntPtr vfs);
  [DllImport(L, CallingConvention=C)] static extern int sqlite3_close_v2(IntPtr db);
  [DllImport(L, CallingConvention=C)] static extern int sqlite3_busy_timeout(IntPtr db, int ms);
  [DllImport(L, CallingConvention=C)] static extern int sqlite3_prepare_v2(IntPtr db, byte[] sql, int n, out IntPtr st, IntPtr tail);
  [DllImport(L, CallingConvention=C)] static extern int sqlite3_step(IntPtr st);
  [DllImport(L, CallingConvention=C)] static extern int sqlite3_finalize(IntPtr st);
  [DllImport(L, CallingConvention=C)] static extern int sqlite3_column_count(IntPtr st);
  [DllImport(L, CallingConvention=C)] static extern IntPtr sqlite3_column_name(IntPtr st, int i);
  [DllImport(L, CallingConvention=C)] static extern int sqlite3_column_type(IntPtr st, int i);
  [DllImport(L, CallingConvention=C)] static extern long sqlite3_column_int64(IntPtr st, int i);
  [DllImport(L, CallingConvention=C)] static extern IntPtr sqlite3_column_text(IntPtr st, int i);
  [DllImport(L, CallingConvention=C)] static extern int sqlite3_column_bytes(IntPtr st, int i);
  [DllImport(L, CallingConvention=C)] static extern int sqlite3_bind_text(IntPtr st, int i, byte[] v, int n, IntPtr d);
  [DllImport(L, CallingConvention=C)] static extern int sqlite3_bind_int64(IntPtr st, int i, long v);
  [DllImport(L, CallingConvention=C)] static extern int sqlite3_bind_null(IntPtr st, int i);
  [DllImport(L, CallingConvention=C)] static extern IntPtr sqlite3_errmsg(IntPtr db);
  public static void Load(string path) {
    if (LoadLibrary(path) == IntPtr.Zero) throw new Exception("Cannot load " + path + " (error " + Marshal.GetLastWin32Error() + ")");
  }
  static byte[] U(string s) { return Encoding.UTF8.GetBytes(s + "\0"); }
  static string S(IntPtr p, int n) { if (p == IntPtr.Zero) return null; byte[] b = new byte[n]; Marshal.Copy(p, b, 0, n); return Encoding.UTF8.GetString(b); }
  static string Z(IntPtr p) { if (p == IntPtr.Zero) return null; int n = 0; while (Marshal.ReadByte(p, n) != 0) n++; return S(p, n); }
  public static IntPtr Open(string file) {
    IntPtr db; int rc = sqlite3_open_v2(U(file), out db, 0x02, IntPtr.Zero);
    if (rc != 0) throw new Exception("Cannot open database (rc=" + rc + ")");
    sqlite3_busy_timeout(db, 8000); return db;
  }
  public static void Close(IntPtr db) { if (db != IntPtr.Zero) sqlite3_close_v2(db); }
  public static List<Dictionary<string, object>> Query(IntPtr db, string sql, object[] args) {
    IntPtr st;
    if (sqlite3_prepare_v2(db, U(sql), -1, out st, IntPtr.Zero) != 0) throw new Exception(Z(sqlite3_errmsg(db)));
    var rows = new List<Dictionary<string, object>>();
    try {
      if (args != null) for (int i = 0; i < args.Length; i++) {
        object a = args[i];
        if (a == null) sqlite3_bind_null(st, i + 1);
        else if (a is int || a is long || a is short) sqlite3_bind_int64(st, i + 1, Convert.ToInt64(a));
        else if (a is bool) sqlite3_bind_int64(st, i + 1, ((bool)a) ? 1 : 0);
        else { byte[] b = Encoding.UTF8.GetBytes(a.ToString()); sqlite3_bind_text(st, i + 1, b, b.Length, new IntPtr(-1)); }
      }
      while (true) {
        int rc = sqlite3_step(st);
        if (rc == 101) break;
        if (rc != 100) throw new Exception(Z(sqlite3_errmsg(db)));
        var r = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
        int n = sqlite3_column_count(st);
        for (int i = 0; i < n; i++) {
          string name = Z(sqlite3_column_name(st, i)); int t = sqlite3_column_type(st, i);
          if (t == 1) r[name] = sqlite3_column_int64(st, i);
          else if (t == 5) r[name] = null;
          else { IntPtr p = sqlite3_column_text(st, i); r[name] = S(p, sqlite3_column_bytes(st, i)); }
        }
        rows.Add(r);
      }
    } finally { sqlite3_finalize(st); }
    return rows;
  }
}}
'@
}

# =====================================================================
#  v2rayN discovery
# =====================================================================
function Find-V2rayN([switch]$Quick) {
  $seen = @{}; $list = New-Object System.Collections.ArrayList
  $add = {
    param($exe)
    $key = $exe.ToLower(); if ($seen.ContainsKey($key)) { return }; $seen[$key] = 1
    $root = Split-Path $exe
    [void]$list.Add([pscustomobject]@{
      Exe = $exe; Root = $root
      Version = [string](Get-Item -LiteralPath $exe).VersionInfo.FileVersion
      HasDb = (Test-Path -LiteralPath (Join-Path $root 'guiConfigs\guiNDB.db'))
    })
  }
  $roots = @('C:\app')
  if (-not $Quick) {
    $roots += @('C:\v2rayN', $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA, $env:APPDATA,
                "$env:USERPROFILE\Desktop", "$env:USERPROFILE\Downloads", "$env:USERPROFILE\Documents")
    $skip = 'Windows', '$Recycle.Bin', 'System Volume Information', 'ProgramData', 'Program Files', 'Program Files (x86)', 'Users', 'Recovery', 'PerfLogs'
    foreach ($d in [IO.DriveInfo]::GetDrives()) {
      if ($d.DriveType -ne 'Fixed' -or -not $d.IsReady) { continue }
      Get-ChildItem -LiteralPath $d.RootDirectory.FullName -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $skip -notcontains $_.Name } | ForEach-Object { $roots += $_.FullName }
    }
  }
  foreach ($r in $roots) {
    if ($r -and (Test-Path -LiteralPath $r)) {
      Get-ChildItem -LiteralPath $r -Recurse -Depth 3 -Filter 'v2rayN.exe' -File -ErrorAction SilentlyContinue |
        ForEach-Object { & $add $_.FullName }
    }
  }
  $list | Sort-Object @{ e = { $_.HasDb }; Descending = $true }, @{ e = { try { [version]$_.Version } catch { [version]'0.0' } }; Descending = $true }
}

function Find-SqliteDll([string]$root) {
  $direct = Join-Path $root 'e_sqlite3.dll'
  if (Test-Path -LiteralPath $direct) { return $direct }
  $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'win-arm64' } elseif ([Environment]::Is64BitProcess) { 'win-x64' } else { 'win-x86' }
  $all = @(Get-ChildItem -LiteralPath $root -Recurse -Depth 4 -Filter 'e_sqlite3.dll' -File -ErrorAction SilentlyContinue)
  $pick = $all | Where-Object { $_.FullName -match [regex]::Escape($arch) } | Select-Object -First 1
  if (-not $pick) { $pick = $all | Select-Object -First 1 }
  if ($pick) { return $pick.FullName }
  return $null
}

function Find-SingBox([string]$root) {
  $p = Join-Path $root 'bin\sing_box\sing-box.exe'
  if (Test-Path -LiteralPath $p) { return $p }
  $f = Get-ChildItem -LiteralPath (Join-Path $root 'bin') -Recurse -Depth 3 -Filter 'sing-box.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($f) { return $f.FullName }
  return $null
}

function Use-Install($inst) {
  $dll = Find-SqliteDll $inst.Root
  if (-not $dll) { throw "e_sqlite3.dll در پوشه v2rayN پیدا نشد." }
  if (-not $script:SqliteLoaded) { [Ssh2V.Sqlite]::Load($dll); $script:SqliteLoaded = $dll }
  $script:V       = $inst
  $script:CfgDir  = Join-Path $inst.Root 'guiConfigs'
  $script:DbPath  = Join-Path $script:CfgDir 'guiNDB.db'
  $script:SingBox = Find-SingBox $inst.Root
  Write-Log "Using v2rayN at $($inst.Root) (v$($inst.Version))"
}

# =====================================================================
#  Database helpers
# =====================================================================
function Use-Db([scriptblock]$body) {
  $db = [Ssh2V.Sqlite]::Open($script:DbPath)
  try { & $body $db } finally { [Ssh2V.Sqlite]::Close($db) }
}
function Q($db, [string]$sql, $params) { [Ssh2V.Sqlite]::Query($db, $sql, [object[]]$params) }

function Backup-Db {
  $dir = Join-Path $script:CfgDir 'ssh-tool-backups'
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  Copy-Item -LiteralPath $script:DbPath -Destination (Join-Path $dir ("guiNDB-{0:yyyyMMdd-HHmmss}.db" -f (Get-Date))) -Force
  Get-ChildItem -LiteralPath $dir -Filter 'guiNDB-*.db' | Sort-Object LastWriteTime -Descending | Select-Object -Skip 10 | Remove-Item -Force
}

function Get-SshEntries {
  $rows = @(Use-Db { param($db) Q $db 'select IndexId, Remarks, Address, PreSocksPort from ProfileItem where ConfigType = 2' $null })
  foreach ($r in $rows) {
    if (-not $r['Address']) { continue }
    $path = Join-Path $script:CfgDir ([string]$r['Address'])
    if (-not (Test-Path -LiteralPath $path)) { continue }
    try { $j = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json } catch { continue }
    $ob = @($j.outbounds) | Where-Object { $_.type -eq 'ssh' } | Select-Object -First 1
    if (-not $ob) { continue }
    [pscustomobject]@{
      Id = [string]$r['IndexId']; Name = [string]$r['Remarks']; File = $path
      Server = [string]$ob.server; Port = [string]$ob.server_port; User = [string]$ob.user; Socks = $r['PreSocksPort']
      Detail = ('{0}@{1}:{2}    SOCKS {3}' -f $ob.user, $ob.server, $ob.server_port, $r['PreSocksPort'])
    }
  }
}

function Get-FreeSocksPort {
  $used = @{}
  foreach ($r in @(Use-Db { param($db) Q $db 'select PreSocksPort as p from ProfileItem where PreSocksPort is not null' $null })) {
    if ($r['p']) { $used[[int]$r['p']] = 1 }
  }
  try { [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() | ForEach-Object { $used[$_.Port] = 1 } } catch {}
  $p = 10900; while ($used.ContainsKey($p)) { $p++ }; return $p
}

function Get-Tag([string]$name) {
  $t = ($name -replace '[^\w\-\.]', '_').Trim('_'); if (-not $t) { $t = 'ssh' }; return $t
}

function New-SingBoxJson($o, [int]$listen) {
  $ob = [ordered]@{ type = 'ssh'; tag = (Get-Tag $o.Name); server = $o.Server; server_port = [int]$o.Port; user = $o.User }
  if ($o.KeyPath) { $ob.private_key_path = $o.KeyPath; if ($o.Password) { $ob.private_key_passphrase = $o.Password } }
  else { $ob.password = $o.Password }
  $cfg = [ordered]@{
    log       = [ordered]@{ level = 'warn' }
    inbounds  = @([ordered]@{ type = 'mixed'; tag = 'socks-in'; listen = '127.0.0.1'; listen_port = $listen })
    outbounds = @($ob, [ordered]@{ type = 'direct'; tag = 'direct' })
    route     = [ordered]@{ final = $ob.tag }
  }
  $cfg | ConvertTo-Json -Depth 8
}

function Add-SshEntry($o) {
  $file  = [guid]::NewGuid().ToString() + '.json'
  $socks = Get-FreeSocksPort
  $id    = [string](Get-Random -Minimum ([long]4000000000000000000) -Maximum ([long]4999999999999999999))
  [IO.File]::WriteAllText((Join-Path $script:CfgDir $file), (New-SingBoxJson $o $socks), $Utf8NoBom)
  try {
    Use-Db {
      param($db)
      $cols = @(Q $db 'pragma table_info(ProfileItem)' $null)
      $ver = $null
      if ($cols | Where-Object { $_['name'] -ieq 'ConfigVersion' }) {
        $v = @(Q $db 'select max(ConfigVersion) as v from ProfileItem' $null)
        if ($v.Count -and $v[0]['v']) { $ver = [int]$v[0]['v'] }
        elseif ($script:V.Version -like '6.*') { $ver = 2 } else { $ver = 4 }
      }
      $vals = [ordered]@{}
      foreach ($c in $cols) {
        $n = [string]$c['name']; $vals[$n] = $null
        if ([int64]$c['notnull'] -eq 1 -and $null -eq $c['dflt_value'] -and [int64]$c['pk'] -eq 0) {
          if ([string]$c['type'] -match 'INT|REAL|NUM') { $vals[$n] = 0 } else { $vals[$n] = '' }
        }
      }
      $set = @{ IndexId = $id; ConfigType = 2; CoreType = 24; Remarks = $o.Name; Address = $file; Port = 0
                PreSocksPort = $socks; DisplayLog = 1; IsSub = 0; AlterId = 0; ConfigVersion = $ver }
      foreach ($k in @($set.Keys)) {
        $match = @($vals.Keys) | Where-Object { $_ -ieq $k } | Select-Object -First 1
        if ($match -and $null -ne $set[$k]) { $vals[$match] = $set[$k] }
      }
      $names = (@($vals.Keys) | ForEach-Object { '"' + $_ + '"' }) -join ','
      $ph = (@('?') * $vals.Count) -join ','
      Q $db "insert into ProfileItem ($names) values ($ph)" (@($vals.Values)) | Out-Null
    }
  } catch {
    Remove-Item -LiteralPath (Join-Path $script:CfgDir $file) -Force -ErrorAction SilentlyContinue
    throw
  }
  Write-Log "Added SSH entry '$($o.Name)' -> $($o.Server):$($o.Port) socks $socks"
  return $socks
}

function Remove-SshEntry($e) {
  Use-Db {
    param($db)
    Q $db 'delete from ProfileItem where IndexId = ?' @($e.Id) | Out-Null
    try { Q $db 'delete from ProfileExItem where IndexId = ?' @($e.Id) | Out-Null } catch {}
  }
  Remove-Item -LiteralPath $e.File -Force -ErrorAction SilentlyContinue
  Write-Log "Removed SSH entry '$($e.Name)'"
}

function Restart-V2rayN {
  $root = $script:V.Root
  Get-Process -ErrorAction SilentlyContinue | Where-Object {
    try { $_.Path -and $_.Path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) } catch { $false }
  } | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Milliseconds 900
  Start-Process -FilePath $script:V.Exe -WorkingDirectory $root
  Write-Log 'Restarted v2rayN'
}

# =====================================================================
#  Parsing pasted text
# =====================================================================
function Dec([string]$s) { if (-not $s) { return '' }; try { return [Uri]::UnescapeDataString($s) } catch { return $s } }

function ConvertFrom-SshText([string]$text) {
  $out = New-Object System.Collections.ArrayList
  $t = "$text".Trim()
  if (-not $t) { return }
  if ($t.StartsWith('{') -or $t.StartsWith('[')) {
    try {
      $j = $t | ConvertFrom-Json
      if ($j -is [array]) { $cands = $j } elseif ($j.outbounds) { $cands = @($j.outbounds) } else { $cands = @($j) }
      foreach ($c in $cands) {
        if ($c.type -ne 'ssh') { continue }
        $port = if ($c.server_port) { [string]$c.server_port } else { '22' }
        [void]$out.Add(@{ Name = [string]$c.tag; Server = [string]$c.server; Port = $port; User = [string]$c.user
                          Password = $(if ($c.private_key_path) { [string]$c.private_key_passphrase } else { [string]$c.password })
                          KeyPath = [string]$c.private_key_path })
      }
      if ($out.Count) { return $out.ToArray() }
    } catch {}
  }
  foreach ($line in ($t -split "`r?`n")) {
    $l = $line.Trim(); if (-not $l) { continue }
    if ($l -match '^ssh://(?<u>[^:@/\s]+)(?::(?<pw>[^@\s]*))?@(?<h>[^:/?#\s]+)(?::(?<p>\d+))?[^#]*(?:#(?<n>.*))?$') {
      [void]$out.Add(@{ Name = (Dec $Matches['n']); Server = $Matches['h']; Port = $(if ($Matches['p']) { $Matches['p'] } else { '22' }); User = (Dec $Matches['u']); Password = (Dec $Matches['pw']); KeyPath = '' })
    } elseif ($l -match '^(?<h>[A-Za-z0-9\.\-]+):(?<p>\d{1,5}):(?<u>[^:\s]+):(?<pw>\S.*)$') {
      [void]$out.Add(@{ Name = ''; Server = $Matches['h']; Port = $Matches['p']; User = $Matches['u']; Password = $Matches['pw']; KeyPath = '' })
    } elseif ($l -match '^(?:ssh\s+)?(?:-p\s*(?<p0>\d+)\s+)?(?<u>[^@\s:]+)@(?<h>[A-Za-z0-9\.\-]+)(?::(?<p>\d+))?(?:\s+-p\s*(?<p2>\d+))?\s*$') {
      $p = @($Matches['p'], $Matches['p2'], $Matches['p0'], '22') | Where-Object { $_ } | Select-Object -First 1
      [void]$out.Add(@{ Name = ''; Server = $Matches['h']; Port = $p; User = $Matches['u']; Password = ''; KeyPath = '' })
    }
  }
  if ($out.Count) { return $out.ToArray() }
  # Free-form "Host: ... / Port: ... / Username: ... / Password: ..." (seller messages, EN/FA)
  $kv = @{ Name = ''; Server = ''; Port = ''; User = ''; Password = ''; KeyPath = '' }
  foreach ($line in ($t -split "`r?`n")) {
    if ($line -notmatch '^\s*(?<k>[^:=]{1,30}?)\s*[:=]\s*(?<v>\S.*?)\s*$') { continue }
    $k = $Matches['k'].Trim().ToLower(); $v = $Matches['v'].Trim()
    if     ($k -match 'user|login|یوزر|کاربر') { $kv.User = $v }
    elseif ($k -match 'pass|pwd|رمز|پسورد')     { $kv.Password = $v }
    elseif ($k -match 'port|پورت')              { $kv.Port = ($v -replace '\D', '') }
    elseif ($k -match 'host|server|address|^ip|آدرس|سرور|هاست|آی ?پی') { $kv.Server = $v }
    elseif ($k -match 'name|remark|نام|عنوان')  { $kv.Name = $v }
  }
  if ($kv.Server -match '^(?<h>[^:\s]+):(?<p>\d+)$') { $kv.Server = $Matches['h']; if (-not $kv.Port) { $kv.Port = $Matches['p'] } }
  if ($kv.Server -and $kv.User) { if (-not $kv.Port) { $kv.Port = '22' }; [void]$out.Add($kv) }
  return $out.ToArray()
}

function Test-Entry($o) {
  if (-not $o.Server) { return 'آدرس سرور را وارد کنید.' }
  if ($o.Server -notmatch '^[A-Za-z0-9\.\-]+$' -and $o.Server -notmatch '^\[?[0-9A-Fa-f:]+\]?$') { return 'آدرس سرور معتبر نیست.' }
  $p = 0; if (-not [int]::TryParse("$($o.Port)", [ref]$p) -or $p -lt 1 -or $p -gt 65535) { return 'پورت باید عددی بین ۱ تا ۶۵۵۳۵ باشد.' }
  if (-not $o.User) { return 'نام کاربری را وارد کنید.' }
  if ($o.KeyPath) { if (-not (Test-Path -LiteralPath $o.KeyPath)) { return 'فایل کلید پیدا نشد.' } }
  elseif (-not $o.Password) { return 'رمز عبور را وارد کنید.' }
  return $null
}

# =====================================================================
#  Connection test (runs in background runspace)
# =====================================================================
$TestScript = {
  param($server, $port, $singbox, $cfgJson, $listen)
  $r = @{ Msg = ''; Ms = 0; TcpMs = 0; Banner = ''; Log = '' }
  $sw = [Diagnostics.Stopwatch]::StartNew(); $c = New-Object Net.Sockets.TcpClient
  try {
    $iar = $c.BeginConnect($server, $port, $null, $null)
    if (-not $iar.AsyncWaitHandle.WaitOne(7000)) { $r.Msg = 'TCP'; return $r }
    $c.EndConnect($iar); $r.TcpMs = $sw.ElapsedMilliseconds
    $s = $c.GetStream(); $s.ReadTimeout = 6000; $b = New-Object byte[] 255
    $n = $s.Read($b, 0, 255); $r.Banner = [Text.Encoding]::ASCII.GetString($b, 0, $n).Trim()
  } catch { $r.Msg = 'TCP'; return $r } finally { $c.Close() }
  if (-not $r.Banner.StartsWith('SSH-')) { $r.Msg = 'NOSSH'; return $r }
  if (-not $singbox -or -not (Test-Path -LiteralPath $singbox)) { $r.Msg = 'TCPONLY'; return $r }
  $tmp = Join-Path $env:TEMP ('ssh2v-' + [guid]::NewGuid().ToString('N') + '.json')
  [IO.File]::WriteAllText($tmp, $cfgJson, (New-Object Text.UTF8Encoding $false))
  $p = $null; $et = $null; $ot = $null
  try {
    $si = New-Object Diagnostics.ProcessStartInfo
    $si.FileName = $singbox; $si.Arguments = 'run -c "' + $tmp + '"'; $si.UseShellExecute = $false
    $si.CreateNoWindow = $true; $si.RedirectStandardError = $true; $si.RedirectStandardOutput = $true; $si.WorkingDirectory = $env:TEMP
    $p = [Diagnostics.Process]::Start($si)
    $et = $p.StandardError.ReadToEndAsync(); $ot = $p.StandardOutput.ReadToEndAsync()
    $ready = $false
    for ($i = 0; $i -lt 40 -and -not $ready; $i++) {
      Start-Sleep -Milliseconds 100; if ($p.HasExited) { break }
      try { $t = New-Object Net.Sockets.TcpClient; $t.Connect('127.0.0.1', $listen); $t.Close(); $ready = $true } catch {}
    }
    if (-not $ready) { $r.Msg = 'SBFAIL' }
    else {
      $res = & curl.exe -s -o NUL -w '%{http_code} %{time_total}' -x ('socks5h://127.0.0.1:' + $listen) --max-time 20 'https://www.google.com/generate_204' 2>$null
      $parts = "$res".Trim() -split ' '
      if ($parts[0] -eq '204') { $r.Msg = 'OK'; $r.Ms = [int]([double]::Parse($parts[1], [Globalization.CultureInfo]::InvariantCulture) * 1000) }
      else { $r.Msg = 'FAIL' }
    }
  } catch { $r.Msg = 'SBFAIL'; $r.Log = $_.Exception.Message }
  finally {
    if ($p) {
      try { if (-not $p.HasExited) { $p.Kill(); [void]$p.WaitForExit(2000) } } catch {}
      try { $r.Log += [string]$et.Result + [string]$ot.Result } catch {}
    }
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
  }
  if ($r.Msg -eq 'FAIL') { if ($r.Log -match 'authenticat|password|permission denied|handshake') { $r.Msg = 'AUTH' } else { $r.Msg = 'NONET' } }
  if ($r.Log.Length -gt 300) { $r.Log = $r.Log.Substring(0, 300) }
  return $r
}

# =====================================================================
#  UI
# =====================================================================
$dark = $false
try { $dark = ((Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction Stop).AppsUseLightTheme -eq 0) } catch {}
if ($env:SSH2V_THEME -eq 'dark') { $dark = $true } elseif ($env:SSH2V_THEME -eq 'light') { $dark = $false }
$Tok = if ($dark) {
  @{ BG = '#0E1014'; SURFACE = '#161920'; SURFACE2 = '#1E222B'; FIELD = '#111318'; LINE = '#272C36'; LINEHOVER = '#363C48'
     TEXT = '#E7E9EE'; MUTED = '#8A92A0'; ACCENT = '#4C8DFF'; ACCENTTEXT = '#FFFFFF'; OK = '#3FB950'; ERR = '#FF6B63'; WARN = '#E3A93B' }
} else {
  @{ BG = '#F5F6F8'; SURFACE = '#FFFFFF'; SURFACE2 = '#F0F2F5'; FIELD = '#FFFFFF'; LINE = '#E2E5EA'; LINEHOVER = '#C9CED6'
     TEXT = '#15171C'; MUTED = '#6B7280'; ACCENT = '#2563EB'; ACCENTTEXT = '#FFFFFF'; OK = '#15803D'; ERR = '#C2261D'; WARN = '#B45309' }
}

$Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="SSH → v2rayN" Width="780" Height="790" MinWidth="700" MinHeight="660"
        WindowStartupLocation="CenterScreen" FlowDirection="RightToLeft"
        FontFamily="Segoe UI" FontSize="13" Foreground="{{TEXT}}" Background="{{BG}}"
        UseLayoutRounding="True" SnapsToDevicePixels="True" TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <SolidColorBrush x:Key="Surface"   Color="{{SURFACE}}"/>
    <SolidColorBrush x:Key="Surface2"  Color="{{SURFACE2}}"/>
    <SolidColorBrush x:Key="Field"     Color="{{FIELD}}"/>
    <SolidColorBrush x:Key="Line"      Color="{{LINE}}"/>
    <SolidColorBrush x:Key="LineHover" Color="{{LINEHOVER}}"/>
    <SolidColorBrush x:Key="Text"      Color="{{TEXT}}"/>
    <SolidColorBrush x:Key="Muted"     Color="{{MUTED}}"/>
    <SolidColorBrush x:Key="Accent"    Color="{{ACCENT}}"/>
    <SolidColorBrush x:Key="AccentText" Color="{{ACCENTTEXT}}"/>
    <SolidColorBrush x:Key="Ok"        Color="{{OK}}"/>
    <SolidColorBrush x:Key="Err"       Color="{{ERR}}"/>

    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="{StaticResource Surface}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="12"/>
      <Setter Property="Padding" Value="22,20"/>
    </Style>
    <Style x:Key="H2" TargetType="TextBlock">
      <Setter Property="FontSize" Value="15"/><Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="Hint" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Muted}"/><Setter Property="FontSize" Value="12"/>
    </Style>
    <Style x:Key="Label" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Muted}"/><Setter Property="FontSize" Value="12"/>
      <Setter Property="Margin" Value="0,0,0,6"/>
    </Style>

    <Style TargetType="TextBox">
      <Setter Property="Background" Value="{StaticResource Field}"/>
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="10,7"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="CaretBrush" Value="{StaticResource Text}"/>
      <Setter Property="SelectionBrush" Value="{StaticResource Accent}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="{TemplateBinding VerticalContentAlignment}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="{StaticResource LineHover}"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="{StaticResource Accent}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="PasswordBox">
      <Setter Property="Background" Value="{StaticResource Field}"/>
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="10,7"/>
      <Setter Property="CaretBrush" Value="{StaticResource Text}"/>
      <Setter Property="SelectionBrush" Value="{StaticResource Accent}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="PasswordBox">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="{StaticResource LineHover}"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="{StaticResource Accent}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="BtnBase" TargetType="Button">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Padding" Value="16,8"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.86"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.72"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="BtnPrimary" TargetType="Button" BasedOn="{StaticResource BtnBase}">
      <Setter Property="Background" Value="{StaticResource Accent}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Accent}"/>
      <Setter Property="Foreground" Value="{StaticResource AccentText}"/>
    </Style>
    <Style x:Key="BtnSecondary" TargetType="Button" BasedOn="{StaticResource BtnBase}">
      <Setter Property="Background" Value="{StaticResource Surface2}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
    </Style>
    <Style x:Key="BtnGhost" TargetType="Button" BasedOn="{StaticResource BtnBase}">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="Foreground" Value="{StaticResource Accent}"/>
      <Setter Property="Padding" Value="10,5"/>
    </Style>
    <Style x:Key="BtnDanger" TargetType="Button" BasedOn="{StaticResource BtnBase}">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="Foreground" Value="{StaticResource Err}"/>
      <Setter Property="FontWeight" Value="Normal"/>
      <Setter Property="Padding" Value="12,5"/>
    </Style>

    <Style x:Key="Seg" TargetType="RadioButton">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="b" Background="Transparent" CornerRadius="6" Padding="10,6" Margin="2">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="b" Property="Background" Value="{StaticResource Surface}"/>
                <Setter Property="Foreground" Value="{StaticResource Text}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Border x:Name="box" Width="18" Height="18" CornerRadius="5" BorderThickness="1.5"
                      BorderBrush="{StaticResource LineHover}" Background="{StaticResource Field}" VerticalAlignment="Center">
                <Path x:Name="tick" Data="M 3.5 9 L 7.5 12.5 L 14 5" Stroke="{StaticResource AccentText}" StrokeThickness="2"
                      StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Visibility="Collapsed" FlowDirection="LeftToRight"/>
              </Border>
              <ContentPresenter Margin="8,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="box" Property="Background" Value="{StaticResource Accent}"/>
                <Setter TargetName="box" Property="BorderBrush" Value="{StaticResource Accent}"/>
                <Setter TargetName="tick" Property="Visibility" Value="Visible"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border x:Name="Root" Background="{{BG}}" Padding="28,24">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <!-- Header -->
      <DockPanel Grid.Row="0">
        <Border DockPanel.Dock="Right" Background="{StaticResource Surface}" BorderBrush="{StaticResource Line}" BorderThickness="1"
                CornerRadius="10" Padding="14,8,6,8" VerticalAlignment="Center">
          <StackPanel Orientation="Horizontal">
            <Ellipse x:Name="DotV2" Width="8" Height="8" Fill="{StaticResource Muted}" VerticalAlignment="Center" Margin="0,0,10,0"/>
            <StackPanel VerticalAlignment="Center">
              <TextBlock x:Name="TxtV2Title" Text="v2rayN" FontWeight="SemiBold" FontSize="12" FlowDirection="LeftToRight" HorizontalAlignment="Right"/>
              <TextBlock x:Name="TxtV2" Text="…" Foreground="{StaticResource Muted}" FontSize="11" FlowDirection="LeftToRight"
                         HorizontalAlignment="Right" MaxWidth="240" TextTrimming="CharacterEllipsis"/>
            </StackPanel>
            <Button x:Name="BtnChange" Content="تغییر" Style="{StaticResource BtnGhost}" Margin="8,0,0,0" VerticalAlignment="Center"/>
          </StackPanel>
        </Border>
        <StackPanel VerticalAlignment="Center">
          <TextBlock Text="افزودن SSH به v2rayN" FontSize="22" FontWeight="SemiBold"/>
          <TextBlock Text="اتصال SSH با همان TUN و روتینگ v2rayN کار می‌کند" Style="{StaticResource Hint}" FontSize="12.5" Margin="0,4,0,0"/>
        </StackPanel>
      </DockPanel>

      <!-- New connection -->
      <Border Grid.Row="1" Style="{StaticResource Card}" Margin="0,20,0,0">
        <StackPanel>
          <TextBlock Text="اتصال جدید" Style="{StaticResource H2}"/>
          <TextBlock Text="متن اتصال را بچسبانید یا فیلدها را پر کنید. پشتیبانی: JSON سینگ‌باکس، ssh://، host:port:user:pass و متن فروشنده."
                     Style="{StaticResource Hint}" TextWrapping="Wrap" Margin="0,3,0,14"/>
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <Grid>
              <TextBox x:Name="TxtPaste" Height="66" AcceptsReturn="True" TextWrapping="Wrap" VerticalContentAlignment="Top"
                       VerticalScrollBarVisibility="Auto" FlowDirection="LeftToRight" FontFamily="Cascadia Mono, Consolas" FontSize="12"/>
              <TextBlock x:Name="HintPaste" Text="ssh://user:pass@host:22#name" Foreground="{StaticResource Muted}" Opacity="0.75"
                         Margin="12,9" IsHitTestVisible="False" FlowDirection="LeftToRight" HorizontalAlignment="Right"
                         VerticalAlignment="Top" FontFamily="Cascadia Mono, Consolas" FontSize="12"/>
            </Grid>
            <Button x:Name="BtnParse" Grid.Column="1" Content="خواندن" Style="{StaticResource BtnSecondary}" Margin="10,0,0,0" Padding="18,8"/>
          </Grid>

          <Grid Margin="0,18,0,0">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="1.15*"/><ColumnDefinition Width="14"/><ColumnDefinition Width="1.6*"/><ColumnDefinition Width="14"/><ColumnDefinition Width="0.75*"/>
            </Grid.ColumnDefinitions>
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="14"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>

            <StackPanel Grid.Row="0" Grid.Column="0">
              <TextBlock Text="نام" Style="{StaticResource Label}"/>
              <TextBox x:Name="TxtName"/>
            </StackPanel>
            <StackPanel Grid.Row="0" Grid.Column="2">
              <TextBlock Text="سرور (IP یا دامنه)" Style="{StaticResource Label}"/>
              <TextBox x:Name="TxtServer" FlowDirection="LeftToRight"/>
            </StackPanel>
            <StackPanel Grid.Row="0" Grid.Column="4">
              <TextBlock Text="پورت" Style="{StaticResource Label}"/>
              <TextBox x:Name="TxtPort" Text="22" FlowDirection="LeftToRight"/>
            </StackPanel>

            <StackPanel Grid.Row="2" Grid.Column="0">
              <TextBlock Text="نام کاربری" Style="{StaticResource Label}"/>
              <TextBox x:Name="TxtUser" FlowDirection="LeftToRight"/>
            </StackPanel>
            <StackPanel Grid.Row="2" Grid.Column="2">
              <TextBlock x:Name="LblKey" Text="فایل کلید خصوصی" Style="{StaticResource Label}" Visibility="Collapsed"/>
              <Grid x:Name="PanelKey" Visibility="Collapsed" Margin="0,0,0,12">
                <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <TextBox x:Name="TxtKey" FlowDirection="LeftToRight"/>
                <Button x:Name="BtnKey" Grid.Column="1" Content="انتخاب" Style="{StaticResource BtnSecondary}" Margin="8,0,0,0" Padding="12,6" FontWeight="Normal"/>
              </Grid>
              <TextBlock x:Name="LblSecret" Text="رمز عبور" Style="{StaticResource Label}"/>
              <Grid>
                <PasswordBox x:Name="TxtPass" FlowDirection="LeftToRight" Padding="10,7,56,7"/>
                <TextBox x:Name="TxtPassPlain" FlowDirection="LeftToRight" Padding="10,7,56,7" Visibility="Collapsed"/>
                <Button x:Name="BtnEye" Content="نمایش" Style="{StaticResource BtnGhost}" HorizontalAlignment="Left"
                        FontSize="11.5" FontWeight="Normal" Padding="8,3" Margin="4,0"/>
              </Grid>
            </StackPanel>
            <StackPanel Grid.Row="2" Grid.Column="4">
              <TextBlock Text="ورود با" Style="{StaticResource Label}"/>
              <Border Background="{StaticResource Surface2}" CornerRadius="8" Padding="1">
                <UniformGrid Columns="2">
                  <RadioButton x:Name="RbPass" Content="رمز" Style="{StaticResource Seg}" IsChecked="True" GroupName="auth"/>
                  <RadioButton x:Name="RbKey"  Content="کلید" Style="{StaticResource Seg}" GroupName="auth"/>
                </UniformGrid>
              </Border>
            </StackPanel>
          </Grid>

          <DockPanel Margin="0,20,0,0">
            <Button x:Name="BtnAdd" DockPanel.Dock="Left" Content="افزودن به v2rayN" Style="{StaticResource BtnPrimary}" Padding="22,9"/>
            <Button x:Name="BtnTest" DockPanel.Dock="Left" Content="تست اتصال" Style="{StaticResource BtnSecondary}" Margin="10,0,0,0" Padding="18,9"/>
            <Button x:Name="BtnClear" DockPanel.Dock="Left" Content="پاک کردن فرم" Style="{StaticResource BtnGhost}" Margin="6,0,0,0" FontWeight="Normal" Foreground="{StaticResource Muted}"/>
            <TextBlock x:Name="TxtStatus" VerticalAlignment="Center" Margin="12,0,0,0" TextWrapping="Wrap" FontSize="12.5"/>
          </DockPanel>
        </StackPanel>
      </Border>

      <!-- Existing -->
      <Border Grid.Row="2" Style="{StaticResource Card}" Margin="0,16,0,0" Padding="22,16,22,8">
        <DockPanel>
          <DockPanel DockPanel.Dock="Top" Margin="0,0,0,4">
            <Button x:Name="BtnRefresh" DockPanel.Dock="Right" Content="بازخوانی" Style="{StaticResource BtnGhost}" FontWeight="Normal"/>
            <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
              <TextBlock Text="SSH های موجود در v2rayN" Style="{StaticResource H2}"/>
              <Border Background="{StaticResource Surface2}" CornerRadius="9" Padding="8,1" Margin="8,0,0,0" VerticalAlignment="Center">
                <TextBlock x:Name="TxtCount" Text="0" FontSize="11.5" Foreground="{StaticResource Muted}"/>
              </Border>
            </StackPanel>
          </DockPanel>
          <Grid>
            <TextBlock x:Name="TxtEmpty" Text="هنوز اتصال SSH اضافه نشده" Style="{StaticResource Hint}" FontSize="12.5"
                       HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,18"/>
            <ScrollViewer VerticalScrollBarVisibility="Auto">
              <ItemsControl x:Name="ListSsh">
                <ItemsControl.ItemTemplate>
                  <DataTemplate>
                    <Border BorderBrush="{StaticResource Line}" BorderThickness="0,1,0,0" Padding="2,12">
                      <DockPanel>
                        <Button DockPanel.Dock="Right" Content="حذف" Style="{StaticResource BtnDanger}" Tag="{Binding Id}" VerticalAlignment="Center"/>
                        <StackPanel VerticalAlignment="Center">
                          <TextBlock Text="{Binding Name}" FontWeight="SemiBold" FontSize="13.5"/>
                          <TextBlock Text="{Binding Detail}" Foreground="{StaticResource Muted}" FontSize="12" Margin="0,3,0,0"
                                     FlowDirection="LeftToRight" HorizontalAlignment="Left" FontFamily="Cascadia Mono, Consolas"/>
                        </StackPanel>
                      </DockPanel>
                    </Border>
                  </DataTemplate>
                </ItemsControl.ItemTemplate>
              </ItemsControl>
            </ScrollViewer>
          </Grid>
        </DockPanel>
      </Border>

      <!-- Footer -->
      <DockPanel Grid.Row="3" Margin="2,14,2,0">
        <TextBlock DockPanel.Dock="Right" Text="پشتیبان قبل از هر تغییر · همه چیز روی همین کامپیوتر" Style="{StaticResource Hint}" FontSize="11.5" VerticalAlignment="Center"/>
        <CheckBox x:Name="ChkRestart" IsChecked="True" Content="بعد از هر تغییر، v2rayN خودکار ری‌استارت شود" VerticalAlignment="Center"/>
      </DockPanel>
    </Grid>
  </Border>
</Window>
'@
foreach ($k in $Tok.Keys) { $Xaml = $Xaml.Replace("{{$k}}", $Tok[$k]) }
$win = [Windows.Markup.XamlReader]::Parse($Xaml)
$ui = @{}
foreach ($n in 'DotV2','TxtV2Title','TxtV2','BtnChange','TxtPaste','HintPaste','BtnParse','TxtName','TxtServer','TxtPort','TxtUser',
               'LblKey','PanelKey','TxtKey','BtnKey','LblSecret','TxtPass','TxtPassPlain','BtnEye','RbPass','RbKey',
               'BtnAdd','BtnTest','BtnClear','TxtStatus','BtnRefresh','TxtCount','TxtEmpty','ListSsh','ChkRestart') {
  $ui[$n] = $win.FindName($n)
}
$Brush = @{ ok = $win.Resources['Ok']; err = $win.Resources['Err']; muted = $win.Resources['Muted']
            warn = (New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($Tok.WARN))) }

function Set-Status([string]$msg, [string]$kind = 'muted') { $ui.TxtStatus.Text = $msg; $ui.TxtStatus.Foreground = $Brush[$kind] }
function Ask([string]$msg, [string]$title = 'SSH → v2rayN') {
  [Windows.MessageBox]::Show($win, $msg, $title, 'YesNo', 'Question', 'No', [Windows.MessageBoxOptions]::RtlReading) -eq 'Yes'
}
function Show-Error([string]$msg) {
  [void][Windows.MessageBox]::Show($win, $msg, 'SSH → v2rayN', 'OK', 'Error', 'OK', [Windows.MessageBoxOptions]::RtlReading)
}
function Update-Ui { $win.Dispatcher.Invoke([action] {}, [Windows.Threading.DispatcherPriority]::Background) }

function Get-Secret { if ($ui.TxtPassPlain.Visibility -eq 'Visible') { $ui.TxtPassPlain.Text } else { $ui.TxtPass.Password } }
function Set-Secret([string]$s) { $ui.TxtPass.Password = $s; $ui.TxtPassPlain.Text = $s }

function Set-AuthMode([bool]$key) {
  $vis = if ($key) { 'Visible' } else { 'Collapsed' }
  $ui.LblKey.Visibility = $vis; $ui.PanelKey.Visibility = $vis
  $ui.LblSecret.Text = if ($key) { 'رمز کلید (اختیاری)' } else { 'رمز عبور' }
}

function Get-FormEntry {
  $o = @{ Name = $ui.TxtName.Text.Trim(); Server = $ui.TxtServer.Text.Trim(); Port = $ui.TxtPort.Text.Trim()
          User = $ui.TxtUser.Text.Trim(); Password = (Get-Secret); KeyPath = '' }
  if ($ui.RbKey.IsChecked) { $o.KeyPath = $ui.TxtKey.Text.Trim() }
  if (-not $o.Name -and $o.User) { $o.Name = "SSH-$($o.User)" }
  $err = Test-Entry $o
  if ($err) { Set-Status $err 'err'; return $null }
  return $o
}
function Set-Form($o) {
  $ui.TxtName.Text = [string]$o.Name; $ui.TxtServer.Text = [string]$o.Server; $ui.TxtPort.Text = [string]$o.Port
  $ui.TxtUser.Text = [string]$o.User; Set-Secret ([string]$o.Password)
  $isKey = [bool]$o.KeyPath
  $ui.RbKey.IsChecked = $isKey; $ui.RbPass.IsChecked = -not $isKey; $ui.TxtKey.Text = [string]$o.KeyPath; Set-AuthMode $isKey
}
function Clear-Form { Set-Form @{ Name = ''; Server = ''; Port = '22'; User = ''; Password = ''; KeyPath = '' }; $ui.TxtPaste.Text = '' }

function Set-Ready([bool]$ok) { foreach ($b in 'BtnAdd','BtnTest','BtnRefresh','BtnParse') { $ui[$b].IsEnabled = $ok } }

function Show-Install {
  if ($script:V) {
    $ui.TxtV2Title.Text = if ($script:V.Version) { "v2rayN  $($script:V.Version)" } else { 'v2rayN' }
    $ui.TxtV2.Text = $script:V.Root; $ui.TxtV2.ToolTip = $script:V.Root
    $ui.DotV2.Fill = $Brush.ok
  } else {
    $ui.TxtV2Title.Text = 'v2rayN'; $ui.TxtV2.Text = 'پیدا نشد'; $ui.DotV2.Fill = $Brush.err
  }
}

function Select-Install($inst) {
  try {
    if (-not $inst.HasDb) { throw 'این v2rayN هنوز یک‌بار اجرا نشده (guiNDB.db وجود ندارد). یک‌بار v2rayN را باز و بسته کنید.' }
    Use-Install $inst
    Show-Install; Set-Ready $true; Refresh-List
    Set-Status '' 'muted'
  } catch {
    $script:V = $null; Show-Install; Set-Ready $false
    Set-Status $_.Exception.Message 'err'; Write-Log "Select-Install failed: $($_.Exception.Message)"
  }
}

function Refresh-List {
  if (-not $script:V) { return }
  try {
    $items = @(Get-SshEntries)
    $ui.ListSsh.ItemsSource = $items
    $ui.TxtCount.Text = [string]$items.Count
    $ui.TxtEmpty.Visibility = if ($items.Count) { 'Collapsed' } else { 'Visible' }
    $script:Entries = $items
  } catch { Set-Status ("خواندن لیست ناموفق بود: " + $_.Exception.Message) 'err' }
}

function Invoke-AfterChange([string]$okMsg) {
  if ($ui.ChkRestart.IsChecked) {
    try { Restart-V2rayN; Set-Status "$okMsg · v2rayN ری‌استارت شد" 'ok' } catch { Set-Status "$okMsg · ری‌استارت v2rayN ناموفق بود" 'warn' }
  } else { Set-Status "$okMsg · برای دیدن تغییر، v2rayN را از Tray ببندید و دوباره باز کنید" 'ok' }
}

function Add-Entries($list) {
  $added = 0; $skipped = 0; $last = ''
  Backup-Db
  foreach ($o in $list) {
    if (-not $o.Name) { $o.Name = "SSH-$($o.User)" }
    if (Test-Entry $o) { $skipped++; continue }
    $dup = @($script:Entries) | Where-Object { $_.Server -eq $o.Server -and $_.Port -eq [string]$o.Port -and $_.User -eq $o.User } | Select-Object -First 1
    if ($dup) {
      if ($list.Count -gt 1) { $skipped++; continue }
      if (-not (Ask ("این اتصال قبلاً با نام «{0}» وجود دارد.`nجایگزین شود؟" -f $dup.Name))) { Set-Status 'تغییری انجام نشد.' 'muted'; return 0 }
      Remove-SshEntry $dup
    }
    [void](Add-SshEntry $o); $added++; $last = $o.Name
    Refresh-List
  }
  Refresh-List
  if ($added -eq 1 -and $list.Count -eq 1) { $msg = "«$last» اضافه شد" } else { $msg = "$added اتصال اضافه شد" + $(if ($skipped) { " · $skipped مورد رد شد (تکراری یا ناقص)" } else { '' }) }
  if ($added) { Invoke-AfterChange $msg } else { Set-Status $msg 'warn' }
  return $added
}

# ---------------- events ----------------
$ui.TxtPaste.Add_TextChanged({ $ui.HintPaste.Visibility = if ($ui.TxtPaste.Text) { 'Collapsed' } else { 'Visible' } })
$ui.RbPass.Add_Checked({ Set-AuthMode $false })
$ui.RbKey.Add_Checked({ Set-AuthMode $true })
$ui.BtnEye.Add_Click({
  if ($ui.TxtPass.Visibility -eq 'Visible') {
    $ui.TxtPassPlain.Text = $ui.TxtPass.Password; $ui.TxtPass.Visibility = 'Collapsed'; $ui.TxtPassPlain.Visibility = 'Visible'; $ui.BtnEye.Content = 'پنهان'
  } else {
    $ui.TxtPass.Password = $ui.TxtPassPlain.Text; $ui.TxtPassPlain.Visibility = 'Collapsed'; $ui.TxtPass.Visibility = 'Visible'; $ui.BtnEye.Content = 'نمایش'
  }
})
$ui.BtnKey.Add_Click({
  $d = New-Object Microsoft.Win32.OpenFileDialog; $d.Title = 'فایل کلید خصوصی SSH'; $d.Filter = 'All files|*.*'
  $sshDir = Join-Path $env:USERPROFILE '.ssh'; if (Test-Path $sshDir) { $d.InitialDirectory = $sshDir }
  if ($d.ShowDialog($win)) { $ui.TxtKey.Text = $d.FileName }
})
$ui.BtnClear.Add_Click({ Clear-Form; Set-Status '' 'muted' })

$ui.BtnParse.Add_Click({
  $found = @(ConvertFrom-SshText $ui.TxtPaste.Text)
  if (-not $found.Count) { Set-Status 'در متن چیزی شبیه اتصال SSH پیدا نشد.' 'err'; return }
  if ($found.Count -eq 1) { Set-Form $found[0]; Set-Status 'فیلدها پر شد. تست کنید یا مستقیم اضافه کنید.' 'ok'; return }
  if (Ask ("{0} اتصال SSH در متن پیدا شد.`nهمه به v2rayN اضافه شوند؟" -f $found.Count)) {
    try { [void](Add-Entries $found); $ui.TxtPaste.Text = '' } catch { Set-Status ("افزودن ناموفق بود: " + $_.Exception.Message) 'err'; Write-Log "Bulk add failed: $($_.Exception.Message)" }
  } else { Set-Form $found[0]; Set-Status "اولین اتصال از $($found.Count) مورد در فرم قرار گرفت." 'muted' }
})

$ui.BtnAdd.Add_Click({
  $o = Get-FormEntry; if (-not $o) { return }
  try { if ((Add-Entries @($o)) -gt 0) { Clear-Form } }
  catch { Set-Status ("افزودن ناموفق بود: " + $_.Exception.Message) 'err'; Write-Log "Add failed: $($_.Exception.Message)" }
})

$ui.BtnTest.Add_Click({
  $o = Get-FormEntry; if (-not $o) { return }
  $l = New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback), 0; $l.Start(); $lp = $l.LocalEndpoint.Port; $l.Stop()
  $json = New-SingBoxJson $o $lp
  Set-Ready $false; Set-Status 'در حال تست اتصال…' 'muted'
  $script:TestPs = [powershell]::Create()
  [void]$script:TestPs.AddScript($TestScript).AddArgument($o.Server).AddArgument([int]$o.Port).AddArgument($script:SingBox).AddArgument($json).AddArgument($lp)
  $script:TestH = $script:TestPs.BeginInvoke()
  $script:TestTimer = New-Object Windows.Threading.DispatcherTimer
  $script:TestTimer.Interval = [TimeSpan]::FromMilliseconds(200)
  $script:TestTimer.Add_Tick({
    if (-not $script:TestH.IsCompleted) { return }
    $script:TestTimer.Stop()
    $r = $null; try { $r = @($script:TestPs.EndInvoke($script:TestH)) | Select-Object -Last 1 } catch {}
    $script:TestPs.Dispose(); Set-Ready $true
    if (-not $r) { Set-Status 'تست انجام نشد.' 'err'; return }
    switch ($r.Msg) {
      'OK'      { Set-Status ("✓ اتصال کامل برقرار است · {0} میلی‌ثانیه" -f $r.Ms) 'ok' }
      'TCP'     { Set-Status 'سرور در دسترس نیست (IP/پورت اشتباه یا فیلتر).' 'err' }
      'NOSSH'   { Set-Status 'این پورت باز است ولی SSH نیست.' 'err' }
      'AUTH'    { Set-Status 'نام کاربری یا رمز اشتباه است.' 'err' }
      'NONET'   { Set-Status 'ورود موفق بود ولی اینترنت از طریق این SSH باز نشد.' 'warn' }
      'TCPONLY' { Set-Status ("سرور SSH در دسترس است ({0} میلی‌ثانیه) · sing-box پیدا نشد، رمز تست نشد." -f $r.TcpMs) 'warn' }
      default   { Set-Status 'اجرای sing-box برای تست ناموفق بود.' 'err'; Write-Log "Test SBFAIL: $($r.Log)" }
    }
  })
  $script:TestTimer.Start()
})

$ui.BtnRefresh.Add_Click({ Refresh-List; Set-Status 'لیست به‌روز شد.' 'muted' })

$ui.ListSsh.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent, [Windows.RoutedEventHandler] {
  param($s, $e)
  $id = [string]$e.OriginalSource.Tag; if (-not $id) { return }
  $entry = @($script:Entries) | Where-Object { $_.Id -eq $id } | Select-Object -First 1; if (-not $entry) { return }
  if (-not (Ask ("«{0}» از v2rayN حذف شود؟" -f $entry.Name))) { return }
  try { Backup-Db; Remove-SshEntry $entry; Refresh-List; Invoke-AfterChange ("«{0}» حذف شد" -f $entry.Name) }
  catch { Set-Status ("حذف ناموفق بود: " + $_.Exception.Message) 'err' }
})

$ui.BtnChange.Add_Click({
  Set-Status 'در حال جستجوی v2rayN…' 'muted'; Update-Ui
  $all = @(Find-V2rayN)
  Set-Status '' 'muted'
  $menu = New-Object Windows.Controls.ContextMenu
  $menu.FlowDirection = 'LeftToRight'
  foreach ($i in $all) {
    $mi = New-Object Windows.Controls.MenuItem
    $mi.Header = ('{0}   (v{1}){2}' -f $i.Root, $i.Version, $(if ($i.HasDb) { '' } else { '  - not initialized' }))
    $mi.Tag = $i; $mi.IsChecked = ($script:V -and $script:V.Exe -eq $i.Exe)
    $mi.Add_Click({ param($s, $e) Select-Install $s.Tag })
    [void]$menu.Items.Add($mi)
  }
  if ($all.Count) { [void]$menu.Items.Add((New-Object Windows.Controls.Separator)) }
  $browse = New-Object Windows.Controls.MenuItem; $browse.Header = 'Browse for v2rayN.exe …'
  $browse.Add_Click({
    $d = New-Object Microsoft.Win32.OpenFileDialog; $d.Filter = 'v2rayN|v2rayN.exe'; $d.Title = 'v2rayN.exe'
    if ($d.ShowDialog($win)) {
      $root = Split-Path $d.FileName
      Select-Install ([pscustomobject]@{ Exe = $d.FileName; Root = $root; Version = [string](Get-Item $d.FileName).VersionInfo.FileVersion
                                          HasDb = (Test-Path (Join-Path $root 'guiConfigs\guiNDB.db')) })
    }
  })
  [void]$menu.Items.Add($browse)
  $menu.PlacementTarget = $ui.BtnChange; $menu.Placement = 'Bottom'; $menu.IsOpen = $true
})

# ---------------- start ----------------
function Initialize-App {
  $found = @(Find-V2rayN -Quick)
  if (-not $found.Count) { Set-Status 'در C:\app پیدا نشد؛ در حال جستجوی جاهای دیگر…' 'muted'; Update-Ui; $found = @(Find-V2rayN) }
  if ($found.Count) { Select-Install $found[0] }
  else { Show-Install; Set-Ready $false; Set-Status 'v2rayN پیدا نشد. از «تغییر» مسیر v2rayN.exe را انتخاب کنید.' 'err' }
}

if ($SelfTest) { return }   # self-test harness drives the functions directly

$win.Add_ContentRendered({ Initialize-App })
[void]$win.ShowDialog()
