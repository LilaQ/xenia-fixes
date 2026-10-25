$ErrorActionPreference='Stop'
Add-Type -Path (Join-Path $PSScriptRoot '../diagnostics/Jc2ThreadReader.cs')
function Put64([byte[]]$b,[int]$at,[uint64]$value) { [BitConverter]::GetBytes($value).CopyTo($b,$at) }
$b=New-Object byte[] 2728
Put64 $b 2704 4294967296
Put64 $b 48 1879048176
Put64 $b 304 2184433640
if(-not [Jc2ThreadReader]::ValidContext($b)){throw 'Matching context rejected'}
Put64 $b 2704 8589934592
if([Jc2ThreadReader]::ValidContext($b)){throw 'Wrong memory base accepted'}
Put64 $b 2704 4294967296
Put64 $b 48 1879048177
if([Jc2ThreadReader]::ValidContext($b)){throw 'Unaligned stack accepted'}
Put64 $b 48 1879048176
Put64 $b 304 305419896
if([Jc2ThreadReader]::ValidContext($b)){throw 'Unrelated pointer accepted'}
Put64 $b 304 2198863872 # 0x83100000, TU1 SDK code
if([Jc2ThreadReader]::ValidContext($b)){throw 'TU1 context accepted without updated-code validation'}
if(-not [Jc2ThreadReader]::ValidContext($b,$true)){throw 'TU1 SDK context rejected'}
Put64 $b 304 2214592512 # upper bound 0x84000000
if([Jc2ThreadReader]::ValidContext($b,$true)){throw 'Out-of-bounds TU1 LR accepted'}
if([Jc2ThreadReader]::BE32([byte[]]@(129,99,0,12),0)-ne 2170748940){throw 'Big endian decoding failed'}
$tu0=[byte[]]@(129,99,0,12,43,11,0,0)
$tu1=[byte[]]@(61,64,131,82,129,127,0,8,63,192,131,38,129,42,178,12,127,9,88,64)
if(-not [Jc2ThreadReader]::ValidLiveReadCode($tu0,$null)){throw 'TU0 live-read signature rejected'}
if(-not [Jc2ThreadReader]::ValidLiveReadCode($null,$tu1)){throw 'TU1 live-read signature rejected'}
$tu1[19]=65
if([Jc2ThreadReader]::ValidLiveReadCode($null,$tu1)){throw 'Mismatched TU1 code accepted'}
if([Jc2ThreadReader]::ValidLiveReadCode($null,$null)){throw 'Missing code accepted'}
'TU0 and TU1 live-read signatures accepted; missing and mismatched code rejected.'
'Thread reader compiled; correct context accepted; wrong base, stack and LR rejected; big-endian read checked.'
foreach($range in @(@(1073741824,1),@(2147483647,1),@(2181038080,65536),@(2214592511,1),@(2684354560,65536),@(3758096383,1))) {
 if(-not [Jc2ThreadReader]::ValidLiveRange([uint32]$range[0],[int]$range[1])){throw 'Allowed live-read range rejected'}
}
foreach($range in @(@(2147483647,2),@(2214592511,2),@(3758096383,2),@(4294967295,2),@(0,1),@(2147483648,1),@(3758096384,1),@(2684354560,65537),@(2684354560,0))) {
 if([Jc2ThreadReader]::ValidLiveRange([uint32]$range[0],[int]$range[1])){throw 'Out-of-bounds live-read range accepted'}
}
'Bounded guest/GPU live-read ranges accepted; gaps, boundary crossings, overflow and invalid lengths rejected.'
$source=Get-Content -LiteralPath (Join-Path $PSScriptRoot '../diagnostics/Jc2ThreadReader.cs') -Raw
$source=$source.Replace('class Jc2ThreadReader {','class Jc2ThreadReaderFixture {')
$pattern='(?s)  static byte\[\] Read\(IntPtr process, ulong address, int count\) \{.*?\n  \}'
$replacement=@'
  public static Dictionary<string,byte[]> Memory=new Dictionary<string,byte[]>();
  public static List<ulong> Reads=new List<ulong>();
  static byte[] Read(IntPtr process,ulong address,int count) {
    Reads.Add(address);
    byte[] b;return Memory.TryGetValue(address.ToString("X")+":"+count,out b) ? b : null;
  }
'@
if([regex]::Matches($source,$pattern).Count-ne 1){throw 'Fixture cannot locate memory reader'}
$source=[regex]::Replace($source,$pattern,$replacement).Replace('  static int DumpGuest(','  public static int DumpGuest(').Replace('  static Dictionary<uint,byte[]> ReadGameState(', '  public static Dictionary<uint,byte[]> ReadGameState(')
# Mock only the native context/handle APIs; Capture retains its real validation,
# suspension cleanup, stack reads and TU-specific state selection.
$nativeMocks=@{
 'OpenProcess'='static IntPtr OpenProcess(uint access,bool inherit,int id) { return new IntPtr(1); }'
 'OpenThread'='static IntPtr OpenThread(uint access,bool inherit,uint id) { return new IntPtr(id); }'
 'SuspendThread'='static uint SuspendThread(IntPtr thread) { Suspends++; return 0; }'
 'ResumeThread'='static uint ResumeThread(IntPtr thread) { Resumes++; return 0; }'
 'GetThreadContext'='static bool GetThreadContext(IntPtr thread,IntPtr context) { if(FailContext) throw new InvalidOperationException("fixture context failure"); Marshal.WriteInt64(context,168,0x5000); Marshal.WriteInt64(context,248,0xA0001000); return true; }'
 'CloseHandle'='static bool CloseHandle(IntPtr handle) { Closes++; return true; }'
}
foreach($name in $nativeMocks.Keys) {
 $nativePattern='(?m)^  \[DllImport\([^\r\n]*\)\] static extern [^\r\n]*\b'+$name+'\([^\r\n]*;'
 if([regex]::Matches($source,$nativePattern).Count-ne 1){throw ('Fixture cannot locate '+$name)}
 $source=[regex]::Replace($source,$nativePattern,('  '+$nativeMocks[$name]))
}
$source=$source.Replace('class Jc2ThreadReaderFixture {','class Jc2ThreadReaderFixture { public static int Suspends,Resumes,Closes; public static bool FailContext;')
Add-Type -TypeDefinition $source
$folder=Join-Path ([IO.Path]::GetTempPath()) ('jc2-reader-test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $folder|Out-Null
try {
 $dict=[Jc2ThreadReaderFixture]::Memory
 $dict['17018F880:1920']=New-Object byte[] 1920
 $n=[Jc2ThreadReaderFixture]::DumpGuest([IntPtr]::Zero,$folder,1880684672,4096)
 if($n-ne 1920-or (Get-Item -LiteralPath (Join-Path $folder 'guest-7018F880-1920.bin')).Length-ne 1920){throw 'Guard-page stack prefix was not preserved'}
 $n=[Jc2ThreadReaderFixture]::DumpGuest([IntPtr]::Zero,$folder,1880684672,128)
 if($n-ne 0){throw 'Missing memory reported as captured'}
 $dict['1BEDB8000:128']=New-Object byte[] 128
 if([Jc2ThreadReaderFixture]::DumpGuest([IntPtr]::Zero,$folder,[uint32]3202056192,128)-ne 0){throw 'GPU alias followed by thread capture'}
 if([Jc2ThreadReaderFixture]::DumpGuest([IntPtr]::Zero,$folder,[uint32]3202056192,128,$true)-ne 128){throw 'GPU live-read alias rejected'}
 'Guard-page stack prefix retained; unreadable memory rejected.'
} finally { Remove-Item -LiteralPath $folder -Recurse -Force }
$globals=New-Object byte[] 12288
([byte[]]@(65,0,0,0)).CopyTo($globals,676) # world manager 0x41000000
$world=New-Object byte[] 16384
([byte[]]@(66,0,0,0)).CopyTo($world,13712) # actor 0x42000000
$dict['182F20000:12288']=$globals
$dict['141000000:16384']=$world
$dict['142000000:8192']=New-Object byte[] 8192
$state=[Jc2ThreadReaderFixture]::ReadGameState([IntPtr]::Zero)
if($state[1090519040].Length-ne 16384-or $state[1107296256].Length-ne 8192){throw 'Main-loop manager or actor snapshot missing'}
if($state.Count-ne 4){throw 'Unexpected manager pointer followed'}
'Main-loop manager and actor captured; null manager pointers ignored.'
$captureFolder=Join-Path ([IO.Path]::GetTempPath()) ('jc2-capture-test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $captureFolder|Out-Null
try {
 $context=New-Object byte[] 2728
 Put64 $context 2704 4294967296
 Put64 $context 48 1879048176
 Put64 $context 304 2198863872
 ([BitConverter]::GetBytes([uint32]6)).CopyTo($context,2648)
 $dict['5000:2728']=$context
 $dict['16FFFFFF0:16']=New-Object byte[] 16
 $tu1[19]=64
 $dict['182BE5274:20']=$tu1
 [Jc2ThreadReaderFixture]::Reads.Clear()
 $samples=[Jc2ThreadReaderFixture]::Capture(0,[uint32[]]@(1,2,3,4,5,6),$captureFolder)
 if($samples.Count-ne 1 -or $samples[0].StackBytes-ne 16 -or $samples[0].GuestThread-ne 6){throw 'TU1 main-thread stack capture failed'}
 if([Jc2ThreadReaderFixture]::Suspends-ne 600 -or [Jc2ThreadReaderFixture]::Resumes-ne 600){throw 'Suspended CPU thread not resumed'}
 if([Jc2ThreadReaderFixture]::Reads.Contains([uint64]6491865088)){throw 'TU0 state layout read during TU1 capture'} # 0x182F20000
 [Jc2ThreadReaderFixture]::FailContext=$true
 $beforeSuspend=[Jc2ThreadReaderFixture]::Suspends
 $beforeResume=[Jc2ThreadReaderFixture]::Resumes
 $beforeClose=[Jc2ThreadReaderFixture]::Closes
 $failed=$false
 try {[Jc2ThreadReaderFixture]::Capture(0,[uint32[]]@(1,2,3,4,5,6),$captureFolder)|Out-Null}catch{
  if($_.Exception.InnerException.Message-ne 'fixture context failure'){throw}
  $failed=$true
 }
 if(-not $failed -or [Jc2ThreadReaderFixture]::Suspends-ne $beforeSuspend+1 -or [Jc2ThreadReaderFixture]::Resumes-ne $beforeResume+1 -or [Jc2ThreadReaderFixture]::Closes-ne $beforeClose+7){throw 'Context failure left suspended threads or unclosed handles'}
 'TU1 capture retained main stack, skipped TU0 manager layout, resumed every thread and cleaned up on context failure.'
} finally {Remove-Item -LiteralPath $captureFolder -Recurse -Force}
foreach($count in @(0,65537)) {
 $rejected=$false
 try {[Jc2ThreadReader]::ReadRanges(0,[uint32[]]@(1090519040),[int[]]@($count),$folder)}catch{
  if($_.Exception.InnerException -is [ArgumentException]){$rejected=$true}else{throw}
 }
 if(-not $rejected){throw 'Invalid live-read length accepted'}
}
$rejected=$false
try {[Jc2ThreadReader]::ReadRanges(0,([uint32[]](@(1090519040)*128)),([int[]](@(65536)*128)),$folder)}catch{
 if($_.Exception.InnerException -is [ArgumentException]){$rejected=$true}else{throw}
}
if(-not $rejected){throw 'Oversized live-read request accepted'}
$tokens=$null;$errors=$null
[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../diagnostics/JC2-Live-Lesen.ps1'),[ref]$tokens,[ref]$errors)|Out-Null
if($errors.Count){throw ($errors|Out-String)}
'Live-read length and total-size limits rejected invalid requests; PowerShell script parsed.'
