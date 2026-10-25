<#
.SYNOPSIS
  Looks at a window of RAM Doctor through UI Automation, the way Narrator does, from OUTSIDE the window's process (a UI
  Automation client must never run on the UI thread it inspects). Used by tests\gui\Flow.Test.ps1.

.DESCRIPTION
  -Hwnd     the window (decimal handle)
  -Invoke   optional: the name of a button to press through UI Automation (Invoke pattern, or the MSAA default action)
  -InvokeFile  the same, read from a UTF-8 file (an Arabic name does not survive a command line)
  -Out      file that receives one line per element:  type|name|focusable|invoke|toggle|expand|legacyRole
            plus, with -Invoke, a last line  INVOKED <name>  or  NOTFOUND <name>  or  FAILED <name> <reason>

  It talks to the native UI Automation (UIAutomationCore, the same provider tree Narrator gets: WinForms controls come in
  through its MSAA proxy), not to the managed System.Windows.Automation client, whose own client-side proxies show every
  WinForms control as a plain pane.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][long]$Hwnd, [string]$Invoke = '', [string]$InvokeFile = '', [Parameter(Mandatory)][string]$Out)

$code = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
namespace RdUia
{
    [ComImport, Guid("352ffba8-0973-437c-a61f-f64cafd81df9"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IUIAutomationCondition { }

    [ComImport, Guid("14314595-b4bc-4055-95f2-58f2e42c9855"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IUIAutomationElementArray { int get_Length(); IUIAutomationElement GetElement(int index); }

    [ComImport, Guid("d22108aa-8ac5-49a5-837b-37bbb3d7591e"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IUIAutomationElement
    {
        void SetFocus();
        void GetRuntimeId_();
        void FindFirst_();
        IUIAutomationElementArray FindAll(int scope, IUIAutomationCondition condition);
        void FindFirstBuildCache_(); void FindAllBuildCache_(); void BuildUpdatedCache_();
        [return: MarshalAs(UnmanagedType.Struct)] object GetCurrentPropertyValue(int propertyId);
        void GetCurrentPropertyValueEx_(); void GetCachedPropertyValue_(); void GetCachedPropertyValueEx_(); void GetCurrentPatternAs_(); void GetCachedPatternAs_();
        [return: MarshalAs(UnmanagedType.IUnknown)] object GetCurrentPattern(int patternId);
    }

    [ComImport, Guid("30cbe57d-d9d0-452a-ab13-7ac5ac4825ee"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IUIAutomation
    {
        void CompareElements_(); void CompareRuntimeIds_(); void GetRootElement_();
        IUIAutomationElement ElementFromHandle(IntPtr hwnd);
        void ElementFromPoint_(); void GetFocusedElement_(); void GetRootElementBuildCache_(); void ElementFromHandleBuildCache_();
        void ElementFromPointBuildCache_(); void GetFocusedElementBuildCache_(); void CreateTreeWalker_(); void ControlViewWalker_();
        void ContentViewWalker_(); void RawViewWalker_(); void RawViewCondition_(); void ControlViewCondition_(); void ContentViewCondition_();
        void CreateCacheRequest_();
        IUIAutomationCondition CreateTrueCondition();
    }

    [ComImport, Guid("fb377fbe-8ea6-46d5-9c73-6499642d3059"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IUIAutomationInvokePattern { void Invoke(); }

    [ComImport, Guid("828055ad-355b-4435-86d5-3b51c14a9b1b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IUIAutomationLegacyIAccessiblePattern { void Select(int flags); void DoDefaultAction(); }

    [ComImport, Guid("ff48dba4-60ef-4201-aa87-54103eef594e")]
    public class CUIAutomation { }

    public static class Probe
    {
        const int Descendants = 4;
        static string Str(IUIAutomationElement e, int id) { object o = e.GetCurrentPropertyValue(id); return o == null ? "" : Convert.ToString(o, System.Globalization.CultureInfo.InvariantCulture); }
        static string Type(int ct)
        {
            switch (ct)
            {
                case 50000: return "Button"; case 50002: return "CheckBox"; case 50006: return "Image"; case 50007: return "ListItem";
                case 50008: return "List"; case 50012: return "ProgressBar"; case 50020: return "Text"; case 50032: return "Window";
                case 50033: return "Pane"; case 50004: return "Edit"; case 50026: return "Group";
                default: return "Type" + ct;
            }
        }
        static List<IUIAutomationElement> All(long hwnd)
        {
            IUIAutomation a = (IUIAutomation)new CUIAutomation();
            IUIAutomationElement root = a.ElementFromHandle(new IntPtr(hwnd));
            List<IUIAutomationElement> l = new List<IUIAutomationElement>();
            l.Add(root);
            IUIAutomationElementArray arr = root.FindAll(Descendants, a.CreateTrueCondition());
            int n = arr.get_Length();
            for (int i = 0; i < n; i++) l.Add(arr.GetElement(i));
            return l;
        }
        public static List<string> Dump(long hwnd)
        {
            List<string> r = new List<string>();
            foreach (IUIAutomationElement e in All(hwnd))
            {
                int ct = Convert.ToInt32(e.GetCurrentPropertyValue(30003));
                r.Add(Type(ct) + "|" + Str(e, 30005).Replace("|", "/").Replace("\r", " ").Replace("\n", " ") + "|" + Str(e, 30009) + "|" + Str(e, 30031) + "|" + Str(e, 30041) + "|" + Str(e, 30028) + "|" + Str(e, 30095));
            }
            return r;
        }
        public static string Invoke(long hwnd, string name)
        {
            foreach (IUIAutomationElement e in All(hwnd))
            {
                if (Str(e, 30005) != name) continue;
                try
                {
                    if (Convert.ToBoolean(e.GetCurrentPropertyValue(30031))) { ((IUIAutomationInvokePattern)e.GetCurrentPattern(10000)).Invoke(); return "INVOKED " + name; }
                    ((IUIAutomationLegacyIAccessiblePattern)e.GetCurrentPattern(10018)).DoDefaultAction();
                    return "INVOKED " + name;
                }
                catch (Exception ex) { return "FAILED " + name + " " + ex.Message; }
            }
            return "NOTFOUND " + name;
        }
    }
}
'@
if ($InvokeFile -and (Test-Path -LiteralPath $InvokeFile)) { $Invoke = [IO.File]::ReadAllText($InvokeFile, [Text.Encoding]::UTF8).Trim() }
$lines = New-Object System.Collections.Generic.List[string]
try {
    if (-not ('RdUia.Probe' -as [type])) { Add-Type -TypeDefinition $code -Language CSharp }
    foreach ($l in [RdUia.Probe]::Dump($Hwnd)) { $lines.Add($l) }
    if ($Invoke) { $lines.Add([RdUia.Probe]::Invoke($Hwnd, $Invoke)) }
} catch { $lines.Add('ERROR ' + $_.Exception.Message) }
[IO.File]::WriteAllLines($Out, $lines, (New-Object System.Text.UTF8Encoding($false)))
