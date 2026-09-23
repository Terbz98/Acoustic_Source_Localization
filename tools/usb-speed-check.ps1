# usb-speed-check.ps1
# Reports the NEGOTIATED USB link speed of the ZYLIA ZM-1 (and every other USB device).
# Run this after every cable/port change. Speed code 3 = SuperSpeed = good.
#                                          Speed code 2 = High Speed = last 3 mics will drop.
# Usage:  powershell -ExecutionPolicy Bypass -File D:\專題\usb-speed-check.ps1

$src = @'
using System;
using System.Runtime.InteropServices;

public static class UsbProbe {
    const uint GENERIC_WRITE = 0x40000000;
    const uint FILE_SHARE_READ = 1, FILE_SHARE_WRITE = 2;
    const uint OPEN_EXISTING = 3;
    const uint IOCTL_EX = 0x220448;

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CreateFileW(string n, uint a, uint s, IntPtr sec, uint d, uint f, IntPtr t);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DeviceIoControl(IntPtr h, uint c, byte[] i, int isz, byte[] o, int osz, out int r, IntPtr ov);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr h);

    public static string Probe(string hubPath, int maxPorts) {
        IntPtr h = CreateFileW(hubPath, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
                               IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
        if (h == (IntPtr)(-1)) return "";
        string outp = "";
        try {
            for (int port = 1; port <= maxPorts; port++) {
                byte[] buf = new byte[2048];
                BitConverter.GetBytes(port).CopyTo(buf, 0);
                int ret;
                if (!DeviceIoControl(h, IOCTL_EX, buf, buf.Length, buf, buf.Length, out ret, IntPtr.Zero))
                    continue;
                ushort vid = BitConverter.ToUInt16(buf, 12);
                ushort pid = BitConverter.ToUInt16(buf, 14);
                if (vid == 0 && pid == 0) continue;
                byte speed = buf[23];
                string sname;
                switch (speed) {
                    case 0: sname = "LowSpeed   1.5 Mbps"; break;
                    case 1: sname = "FullSpeed   12 Mbps"; break;
                    case 2: sname = "HighSpeed  480 Mbps  (USB 2.0)"; break;
                    case 3: sname = "SuperSpeed 5+ Gbps   (USB 3.x)"; break;
                    default: sname = "unknown(" + speed + ")"; break;
                }
                bool zylia = (vid == 0x0403 && pid == 0x73F8);
                outp += String.Format("  Port {0,2}  VID_{1:X4}&PID_{2:X4}  bcdUSB {3:X4}  ->  speed {4} = {5}{6}\n",
                                      port, vid, pid, BitConverter.ToUInt16(buf, 6), speed, sname,
                                      zylia ? "   <=== ZYLIA ZM-1" : "");
                if (zylia && speed != 3)
                    outp += "        !!! ZM-1 IS NOT ON SUPERSPEED -- mics 17/18/19 will drop samples !!!\n";
                if (zylia && speed == 3)
                    outp += "        OK: SuperSpeed link. All 19 mics should stream cleanly.\n";
            }
        } finally { CloseHandle(h); }
        return outp;
    }
}
'@
Add-Type -TypeDefinition $src -Language CSharp

Write-Output "USB link speeds  --  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
$found = $false
Get-PnpDevice -PresentOnly -Class USB | Where-Object { $_.FriendlyName -match 'Hub' } | ForEach-Object {
    $path = '\\?\' + ($_.InstanceId -replace '\\', '#') + '#{f18a0e88-c30c-11d0-8815-00a0c906bed8}'
    $res = [UsbProbe]::Probe($path, 32)
    if ($res) {
        Write-Output ""
        Write-Output ("=== " + $_.FriendlyName)
        Write-Output $res
        if ($res -match 'ZYLIA') { $found = $true }
    }
}
if (-not $found) { Write-Output ""; Write-Output "  (ZM-1 not detected -- is it plugged in and powered?)" }
