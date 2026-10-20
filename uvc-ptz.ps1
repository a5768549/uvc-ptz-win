<#
.SYNOPSIS
  Pan / tilt / zoom control for USB (UVC) PTZ cameras on Windows.

.DESCRIPTION
  Talks to the camera through DirectShow IAMCameraControl, the same interface
  the "Camera Control" tab of a driver property page uses. Works with any UVC
  camera that exposes Pan, Tilt or Zoom. No driver, vendor app or extra module
  is needed; it runs on Windows PowerShell 5.1 and PowerShell 7.

.PARAMETER Device
  Friendly name (or part of it) of the camera to control. When omitted, the
  first camera that supports at least one of Pan, Tilt or Zoom is used.

.PARAMETER List
  Print every video capture device and the camera-control properties it
  supports, then exit.

.PARAMETER Set
  Set properties without opening the window, e.g. -Set Pan=0,Tilt=10,Zoom=200.
  Values are clamped to the camera's range and step. Prints the resulting values.

.EXAMPLE
  .\uvc-ptz.ps1
.EXAMPLE
  .\uvc-ptz.ps1 -List
.EXAMPLE
  .\uvc-ptz.ps1 -Device "HD Camera" -Set Pan=0,Tilt=0,Zoom=0
#>
[CmdletBinding()]
param(
    [string] $Device,
    [switch] $List,
    [string[]] $Set
)

$ErrorActionPreference = 'Stop'

$backendSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

namespace UvcPtz
{
    [ComImport]
    [Guid("29840822-5B84-11D0-BD3B-00A0C911CE86")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface ICreateDevEnum
    {
        [PreserveSig]
        int CreateClassEnumerator([In] ref Guid pType, [Out] out IEnumMoniker ppEnumMoniker, [In] int dwFlags);
    }

    [ComImport]
    [Guid("55272A00-42CB-11CE-8135-00AA004BB851")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IPropertyBag
    {
        [PreserveSig]
        int Read([MarshalAs(UnmanagedType.LPWStr)] string pszPropName, [MarshalAs(UnmanagedType.Struct)] out object pVar, IntPtr pErrorLog);

        [PreserveSig]
        int Write([MarshalAs(UnmanagedType.LPWStr)] string pszPropName, [In, MarshalAs(UnmanagedType.Struct)] ref object pVar);
    }

    public enum CameraProperty
    {
        Pan = 0,
        Tilt = 1,
        Roll = 2,
        Zoom = 3,
        Exposure = 4,
        Iris = 5,
        Focus = 6
    }

    [Flags]
    public enum CameraControlFlags
    {
        None = 0,
        Auto = 1,
        Manual = 2
    }

    [ComImport]
    [Guid("C6E13370-30AC-11D0-A18C-00A0C9118956")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAMCameraControl
    {
        [PreserveSig]
        int GetRange(CameraProperty property, out int min, out int max, out int step, out int defaultValue, out CameraControlFlags capabilities);

        [PreserveSig]
        int Set(CameraProperty property, int value, CameraControlFlags flags);

        [PreserveSig]
        int Get(CameraProperty property, out int value, out CameraControlFlags flags);
    }

    public sealed class PropertyRange
    {
        public CameraProperty Property { get; internal set; }
        public int Min { get; internal set; }
        public int Max { get; internal set; }
        public int Step { get; internal set; }
        public int DefaultValue { get; internal set; }
        public CameraControlFlags Capabilities { get; internal set; }
    }

    public sealed class DeviceInfo
    {
        public string Name { get; internal set; }
        public bool HasCameraControl { get; internal set; }
        public List<PropertyRange> Properties { get; internal set; }
        public List<string> Unsupported { get; internal set; }
    }

    internal static class Native
    {
        internal static readonly Guid VideoInputDeviceCategory = new Guid("860BB310-5D01-11D0-BD3B-00A0C911CE86");
        internal static readonly Guid SystemDeviceEnum = new Guid("62BE5D10-60EB-11D0-BD3B-00A0C911CE86");
        internal static readonly Guid IUnknown = new Guid("00000000-0000-0000-C000-000000000046");

        internal static void Release(object value)
        {
            if (value != null && Marshal.IsComObject(value))
            {
                Marshal.FinalReleaseComObject(value);
            }
        }

        // Calls visit(name, filter) for each video capture device. Return true from visit to keep
        // ownership of the filter (it will not be released here) and stop enumerating.
        internal static void Enumerate(Func<string, object, bool> visit)
        {
            var deviceEnum = (ICreateDevEnum)Activator.CreateInstance(Type.GetTypeFromCLSID(SystemDeviceEnum));
            IEnumMoniker monikerEnum = null;
            try
            {
                var category = VideoInputDeviceCategory;
                if (deviceEnum.CreateClassEnumerator(ref category, out monikerEnum, 0) != 0 || monikerEnum == null)
                {
                    return;
                }
                var monikers = new IMoniker[1];
                while (monikerEnum.Next(1, monikers, IntPtr.Zero) == 0)
                {
                    var moniker = monikers[0];
                    object bag = null;
                    object filter = null;
                    var keep = false;
                    try
                    {
                        var bagGuid = typeof(IPropertyBag).GUID;
                        moniker.BindToStorage(null, null, ref bagGuid, out bag);
                        object friendlyName;
                        ((IPropertyBag)bag).Read("FriendlyName", out friendlyName, IntPtr.Zero);
                        var name = friendlyName == null ? "(unnamed)" : friendlyName.ToString();
                        var unknown = IUnknown;
                        moniker.BindToObject(null, null, ref unknown, out filter);
                        keep = visit(name, filter);
                        if (keep)
                        {
                            filter = null;
                            return;
                        }
                    }
                    finally
                    {
                        if (!keep) Release(filter);
                        Release(bag);
                        Release(moniker);
                    }
                }
            }
            finally
            {
                Release(monikerEnum);
                Release(deviceEnum);
            }
        }

        internal static PropertyRange TryGetRange(IAMCameraControl control, CameraProperty property, out int hr)
        {
            int min, max, step, defaultValue;
            CameraControlFlags caps;
            hr = control.GetRange(property, out min, out max, out step, out defaultValue, out caps);
            if (hr < 0 || max <= min)
            {
                return null;
            }
            return new PropertyRange { Property = property, Min = min, Max = max, Step = Math.Max(1, step), DefaultValue = defaultValue, Capabilities = caps };
        }
    }

    public static class Devices
    {
        public static List<DeviceInfo> List()
        {
            var result = new List<DeviceInfo>();
            Native.Enumerate((name, filter) =>
            {
                var info = new DeviceInfo { Name = name, Properties = new List<PropertyRange>(), Unsupported = new List<string>() };
                var control = filter as IAMCameraControl;
                info.HasCameraControl = control != null;
                if (control != null)
                {
                    foreach (CameraProperty property in Enum.GetValues(typeof(CameraProperty)))
                    {
                        int hr;
                        var range = Native.TryGetRange(control, property, out hr);
                        if (range != null) info.Properties.Add(range);
                        else info.Unsupported.Add(property.ToString());
                    }
                }
                result.Add(info);
                return false;
            });
            return result;
        }
    }

    public sealed class CameraController : IDisposable
    {
        private object filter;
        private IAMCameraControl control;

        public string DeviceName { get; private set; }

        public CameraController(string match)
        {
            Native.Enumerate((name, candidate) =>
            {
                var candidateControl = candidate as IAMCameraControl;
                if (candidateControl == null) return false;
                if (!String.IsNullOrEmpty(match))
                {
                    if (name.IndexOf(match, StringComparison.OrdinalIgnoreCase) < 0) return false;
                }
                else
                {
                    int hr;
                    var movable = Native.TryGetRange(candidateControl, CameraProperty.Pan, out hr) != null
                        || Native.TryGetRange(candidateControl, CameraProperty.Tilt, out hr) != null
                        || Native.TryGetRange(candidateControl, CameraProperty.Zoom, out hr) != null;
                    if (!movable) return false;
                }
                filter = candidate;
                control = candidateControl;
                DeviceName = name;
                return true;
            });

            if (control == null)
            {
                throw new InvalidOperationException(String.IsNullOrEmpty(match)
                    ? "No camera that supports UVC pan, tilt or zoom was found."
                    : "No camera named like '" + match + "' that supports camera control was found.");
            }
        }

        public PropertyRange GetRange(CameraProperty property)
        {
            EnsureOpen();
            int hr;
            return Native.TryGetRange(control, property, out hr);
        }

        public int Get(CameraProperty property)
        {
            EnsureOpen();
            int value;
            CameraControlFlags flags;
            var hr = control.Get(property, out value, out flags);
            if (hr < 0) Marshal.ThrowExceptionForHR(hr);
            return value;
        }

        public int Set(CameraProperty property, int value)
        {
            EnsureOpen();
            var range = GetRange(property);
            if (range == null) throw new NotSupportedException(property + " is not supported by " + DeviceName + ".");
            value = Math.Max(range.Min, Math.Min(range.Max, value));
            value = range.Min + ((value - range.Min) / range.Step) * range.Step;
            var hr = control.Set(property, value, CameraControlFlags.Manual);
            if (hr < 0) Marshal.ThrowExceptionForHR(hr);
            return Get(property);
        }

        private void EnsureOpen()
        {
            if (control == null) throw new ObjectDisposedException("CameraController");
        }

        public void Dispose()
        {
            control = null;
            Native.Release(filter);
            filter = null;
        }
    }
}
'@

if (-not ('UvcPtz.CameraController' -as [type])) {
    Add-Type -TypeDefinition $backendSource -Language CSharp
}

if ($List) {
    $devices = [UvcPtz.Devices]::List()
    if ($devices.Count -eq 0) {
        Write-Output 'No video capture devices found.'
        exit 1
    }
    foreach ($info in $devices) {
        Write-Output ("{0}" -f $info.Name)
        if (-not $info.HasCameraControl) {
            Write-Output '  camera control: not supported'
            continue
        }
        foreach ($range in $info.Properties) {
            Write-Output ("  {0,-8} min={1} max={2} step={3} default={4} caps={5}" -f $range.Property, $range.Min, $range.Max, $range.Step, $range.DefaultValue, $range.Capabilities)
        }
        if ($info.Unsupported.Count -gt 0) {
            Write-Output ("  not supported: {0}" -f ($info.Unsupported -join ', '))
        }
    }
    exit 0
}

if ($Set) {
    $controller = [UvcPtz.CameraController]::new($Device)
    try {
        foreach ($pair in ($Set -join ',').Split(',')) {
            $parts = $pair.Split('=')
            if ($parts.Count -ne 2) { throw "Expected Name=Value, got '$pair'." }
            $property = [UvcPtz.CameraProperty] $parts[0].Trim()
            $actual = $controller.Set($property, [int] $parts[1].Trim())
            Write-Output ("{0} {1}={2}" -f $controller.DeviceName, $property, $actual)
        }
    }
    finally {
        $controller.Dispose()
    }
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$controller = $null
try {
    $controller = [UvcPtz.CameraController]::new($Device)
    $ranges = @{}
    foreach ($property in 'Pan', 'Tilt', 'Zoom') {
        $ranges[$property] = $controller.GetRange([UvcPtz.CameraProperty] $property)
    }

    [Windows.Forms.Application]::EnableVisualStyles()
    $font = [Drawing.Font]::new('Segoe UI', 10)

    $form = [Windows.Forms.Form]::new()
    $form.Text = 'UVC PTZ'
    $form.ClientSize = [Drawing.Size]::new(620, 460)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.KeyPreview = $true
    $form.Font = $font

    $title = [Windows.Forms.Label]::new()
    $title.Text = "Camera: $($controller.DeviceName)"
    $title.Location = [Drawing.Point]::new(20, 16)
    $title.AutoSize = $true
    $title.Font = [Drawing.Font]::new('Segoe UI', 12, [Drawing.FontStyle]::Bold)
    $form.Controls.Add($title)

    $status = [Windows.Forms.Label]::new()
    $status.Text = 'Connected. Arrow keys pan/tilt, +/- zoom, Home recenters.'
    $status.Location = [Drawing.Point]::new(20, 424)
    $status.AutoSize = $true
    $status.ForeColor = [Drawing.Color]::DarkGreen
    $form.Controls.Add($status)

    function New-Slider([string] $Property, [int] $X, [int] $Y, [int] $Width, [int] $Height, [bool] $Vertical) {
        $range = $ranges[$Property]
        $slider = [Windows.Forms.TrackBar]::new()
        $slider.Location = [Drawing.Point]::new($X, $Y)
        $slider.Size = [Drawing.Size]::new($Width, $Height)
        if ($Vertical) { $slider.Orientation = 'Vertical' }
        if ($null -eq $range) {
            $slider.Enabled = $false
            return $slider
        }
        $slider.Minimum = $range.Min
        $slider.Maximum = $range.Max
        $slider.SmallChange = $range.Step
        $slider.LargeChange = [Math]::Max($range.Step, [int](($range.Max - $range.Min) / 20))
        $slider.TickFrequency = [Math]::Max(1, [int](($range.Max - $range.Min) / 20))
        return $slider
    }

    function New-ValueLabel([int] $X, [int] $Y, [int] $Width) {
        $label = [Windows.Forms.Label]::new()
        $label.Location = [Drawing.Point]::new($X, $Y)
        $label.Size = [Drawing.Size]::new($Width, 26)
        return $label
    }
    function New-CenteredLabel([int] $X, [int] $Y, [int] $Width) {
        $label = New-ValueLabel $X $Y $Width
        $label.TextAlign = 'MiddleCenter'
        return $label
    }

    $sliders = @{
        Pan  = New-Slider 'Pan' 20 94 570 45 $false
        Tilt = New-Slider 'Tilt' 452 186 55 140 $true
        Zoom = New-Slider 'Zoom' 20 372 570 45 $false
    }
    $labels = @{
        Pan  = New-ValueLabel 20 66 400
        Tilt = New-CenteredLabel 380 152 170
        Zoom = New-ValueLabel 20 344 400
    }
    foreach ($key in $sliders.Keys) {
        $form.Controls.Add($sliders[$key])
        $form.Controls.Add($labels[$key])
    }

    function Update-Labels {
        foreach ($property in 'Pan', 'Tilt', 'Zoom') {
            $range = $ranges[$property]
            $labels[$property].Text = if ($null -eq $range) {
                "${property}: not supported"
            } else {
                "${property}: $($sliders[$property].Value) ($($range.Min) to $($range.Max))"
            }
        }
    }

    function Set-Status([string] $Text, [bool] $Ok) {
        $status.Text = $Text
        $status.ForeColor = if ($Ok) { [Drawing.Color]::DarkGreen } else { [Drawing.Color]::DarkRed }
    }

    function Set-Property([string] $Property, [int] $Value) {
        if ($null -eq $ranges[$Property]) { return }
        try {
            $actual = $controller.Set([UvcPtz.CameraProperty] $Property, $Value)
            $slider = $sliders[$Property]
            $slider.Value = [Math]::Max($slider.Minimum, [Math]::Min($slider.Maximum, $actual))
            Update-Labels
            Set-Status "$Property = $actual" $true
        }
        catch {
            Set-Status "Failed: $($_.Exception.Message)" $false
        }
    }

    function Step-Property([string] $Property, [int] $Direction) {
        $range = $ranges[$Property]
        if ($null -eq $range) { return }
        $step = [Math]::Max($range.Step, [int](($range.Max - $range.Min) / 36))
        Set-Property $Property ($sliders[$Property].Value + $Direction * $step)
    }

    function Read-Current {
        foreach ($property in 'Pan', 'Tilt', 'Zoom') {
            if ($null -eq $ranges[$property]) { continue }
            $value = $controller.Get([UvcPtz.CameraProperty] $property)
            $slider = $sliders[$property]
            $slider.Value = [Math]::Max($slider.Minimum, [Math]::Min($slider.Maximum, $value))
        }
        Update-Labels
    }

    function Reset-Position([bool] $IncludeZoom) {
        foreach ($property in 'Pan', 'Tilt', 'Zoom') {
            if ($property -eq 'Zoom' -and -not $IncludeZoom) { continue }
            $range = $ranges[$property]
            if ($null -ne $range) { Set-Property $property $range.DefaultValue }
        }
    }

    foreach ($property in 'Pan', 'Tilt', 'Zoom') {
        $name = $property
        $sliders[$name].Add_Scroll({ Set-Property $name $sliders[$name].Value }.GetNewClosure())
    }

    function New-Button([string] $Text, [int] $X, [int] $Y, [scriptblock] $OnClick, [int] $Width = 80) {
        $button = [Windows.Forms.Button]::new()
        $button.Text = $Text
        $button.Location = [Drawing.Point]::new($X, $Y)
        $button.Size = [Drawing.Size]::new($Width, 38)
        $button.TabStop = $false
        $button.Add_Click($OnClick)
        $form.Controls.Add($button)
    }

    # A 3 x 3 grid of equal buttons: zoom and reset in the corners, a direction pad in the cross.
    $column = { param($i) 20 + $i * 130 }
    $row = { param($j) 190 + $j * 50 }
    New-Button 'Zoom -' (& $column 0) (& $row 0) { Step-Property 'Zoom' -1 } 120
    New-Button 'Up' (& $column 1) (& $row 0) { Step-Property 'Tilt' 1 } 120
    New-Button 'Zoom +' (& $column 2) (& $row 0) { Step-Property 'Zoom' 1 } 120
    New-Button 'Left' (& $column 0) (& $row 1) { Step-Property 'Pan' -1 } 120
    New-Button 'Center' (& $column 1) (& $row 1) { Reset-Position $false } 120
    New-Button 'Right' (& $column 2) (& $row 1) { Step-Property 'Pan' 1 } 120
    New-Button 'Reset all' (& $column 0) (& $row 2) { Reset-Position $true } 120
    New-Button 'Down' (& $column 1) (& $row 2) { Step-Property 'Tilt' -1 } 120
    New-Button 'Re-read' (& $column 2) (& $row 2) {
        try { Read-Current; Set-Status 'Read current position.' $true }
        catch { Set-Status "Read failed: $($_.Exception.Message)" $false }
    } 120

    $form.Add_KeyDown({
        param($sender, $event)
        switch ($event.KeyCode) {
            'Left' { Step-Property 'Pan' -1; $event.Handled = $true }
            'Right' { Step-Property 'Pan' 1; $event.Handled = $true }
            'Up' { Step-Property 'Tilt' 1; $event.Handled = $true }
            'Down' { Step-Property 'Tilt' -1; $event.Handled = $true }
            'Add' { Step-Property 'Zoom' 1; $event.Handled = $true }
            'Oemplus' { Step-Property 'Zoom' 1; $event.Handled = $true }
            'Subtract' { Step-Property 'Zoom' -1; $event.Handled = $true }
            'OemMinus' { Step-Property 'Zoom' -1; $event.Handled = $true }
            'Home' { Reset-Position $false; $event.Handled = $true }
        }
    })

    $form.Add_FormClosed({ $controller.Dispose() })

    Read-Current
    [void] $form.ShowDialog()
}
catch {
    if ($null -ne $controller) { $controller.Dispose() }
    if ($List -or $Set) { throw }
    Add-Type -AssemblyName System.Windows.Forms
    [void] [Windows.Forms.MessageBox]::Show("Could not open the PTZ camera:`r`n$($_.Exception.Message)", 'UVC PTZ', 'OK', 'Error')
    exit 1
}
