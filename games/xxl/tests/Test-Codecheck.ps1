$ErrorActionPreference='Stop'
$reader = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../tools/XXL-Codecheck.ps1') -Raw
$start=$reader.IndexOf("    Add-Type -TypeDefinition @'`n")+28
$start=$reader.IndexOf('using System;',$start)
$end=$reader.IndexOf("`n'@",$start)
$source=$reader.Substring($start,$end-$start).Replace('public static class XxlJitReader {','public static class XxlJitReaderFixture {')
$a=$source.IndexOf('  static byte[] ReadBytes('); $b=$source.IndexOf('  static ulong KernelHost(',$a)
$replacement=@'
  public static System.Collections.Generic.Dictionary<ulong,byte[]> Bytes=new System.Collections.Generic.Dictionary<ulong,byte[]>();
  static byte[] ReadBytes(IntPtr process, ulong address, int count) {
    byte[] b;return Bytes.TryGetValue(address,out b) && b.Length==count ? b : null;
  }
'@
$source=$source.Substring(0,$a)+$replacement+"`n"+$source.Substring($b)
$source=$source.Replace('  static byte[] ReadUserCode(','  public static byte[] ReadUserCode(')
Add-Type -TypeDefinition $source
function BE32([uint32]$value) { $b=[BitConverter]::GetBytes($value); [Array]::Reverse($b); return ,$b }
function Check([byte]$kind,[uint32]$pc,[uint32]$entry,[uint32]$physical,[string]$label) {
 $dict=[XxlJitReaderFixture]::Bytes; $dict.Clear()
 [uint64]$desc=12881387520
 $dict[$desc+2112+($pc -shr 28)]=[byte[]]@($kind)
 if(($kind-band 1)-ne 0) {$dict[$desc+1024+($pc-shr 24)*4]=(BE32 $entry)}
 else {
  $small=($kind-band 2)-eq 0
  $off=if($small){($pc-shr 23)*2}else{2048+($pc-shr 27)*2}
  $dict[$desc+$off]=[byte[]]@(0,128)
  $idx=if($small){($pc-shr 12)-band 2047}else{($pc-shr 16)-band 2047}
  $dict[[uint64]12885950464+$idx*4]=(BE32 $entry)
 }
 $translatedAddress=if($physical-ge 1073741824){[uint64]8589934592+$physical-1073741824}else{[uint64]12884901888+$physical}
 $dict[$translatedAddress]=[byte[]](0..31)
 [uint32]$got=0;[string]$status='';$code=[XxlJitReaderFixture]::ReadUserCode([IntPtr]::Zero,$pc,[ref]$got,[ref]$status)
 if($got-ne $physical-or $status-ne 'mapped'-or $code.Length-ne 32-or $code[31]-ne 31){throw "Failed $label : $status / $got"}
 Write-Output "PASS $label"
}
Check 4 3191144644 19087362 19087556 '4KB physical page'
Check 2 3191144644 19070978 19071172 '64KB physical page'
Check 1 3191144644 16777218 20250820 '16MB physical page'
Check 4 3191144644 3258187778 3258187972 'virtual frame translated to kernel'
[XxlJitReaderFixture]::Bytes.Clear()
[uint32]$got=0;[string]$status=''
$code=[XxlJitReaderFixture]::ReadUserCode([IntPtr]::Zero,3191144644,[ref]$got,[ref]$status)
if($null-ne $code-or $status-ne 'no_descriptor'){throw 'Missing mapping was not rejected'}
Write-Output 'PASS missing descriptor stays unreadable'
