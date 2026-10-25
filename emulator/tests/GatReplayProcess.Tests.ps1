$ErrorActionPreference='Stop'
$path=Join-Path (Split-Path -Parent $PSScriptRoot) 'tools/Gat-Replay-Compare.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
foreach($name in @('Get-GatReplayRequest','Invoke-GatReplayProcess')){
 $fn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
 Invoke-Expression $fn.Extent.Text
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('gat-process-check-'+[guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory $root
foreach($code in @(0,37)){
 $script="[Console]::Out.Write(('O'*200000));[Console]::Error.Write(('E'*200000));exit $code"
 $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
 $actual=Invoke-GatReplayProcess -Executable (Get-Process -Id $PID).Path -Arguments "-NoProfile -EncodedCommand $encoded" -WorkingDirectory $root -Stdout "$root/out" -Stderr "$root/err"
 if($actual -ne $code){throw "Wrong exit code $actual instead of $code"}
 if([IO.File]::ReadAllText("$root/out") -ne ('O'*200000)){throw 'stdout mismatch'}
 if([IO.File]::ReadAllText("$root/err") -ne ('E'*200000)){throw 'stderr mismatch'}
}
$request=Join-Path $root 'replay.request'
[IO.File]::WriteAllText($request,'before')
$quotedRequest=$request.Replace("'","''")
$script="[IO.File]::WriteAllText('$quotedRequest','');Start-Sleep -Milliseconds 1200;[IO.File]::Delete('$quotedRequest');Start-Sleep -Milliseconds 600;[IO.File]::WriteAllText('$quotedRequest','before');exit 0"
$encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
$actual=Invoke-GatReplayProcess -Executable (Get-Process -Id $PID).Path -Arguments "-NoProfile -EncodedCommand $encoded" -WorkingDirectory $root -Stdout "$root/gap-out" -Stderr "$root/gap-err" -RequestFile $request
if($actual -ne 0){throw 'Transient empty/missing request cancelled a valid process.'}
$script="[IO.File]::WriteAllText('$quotedRequest','after');Start-Sleep -Seconds 30;exit 99"
$encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
$timer=[Diagnostics.Stopwatch]::StartNew()
$cancelled=$false
try {
 $null=Invoke-GatReplayProcess -Executable (Get-Process -Id $PID).Path -Arguments "-NoProfile -EncodedCommand $encoded" -WorkingDirectory $root -Stdout "$root/out" -Stderr "$root/err" -RequestFile $request
} catch {
 if($_.Exception.Message -eq 'Replay superseded by a new request.'){$cancelled=$true}else{throw}
}
if(-not $cancelled -or $timer.Elapsed.TotalSeconds -gt 10){throw 'New request did not promptly stop the owned replay child.'}
Remove-Item -LiteralPath $root -Recurse -Force
'PASS: real child exits 0/37 preserved; concurrent 200KB stdout/stderr complete; new request cancels only the owned child.'
