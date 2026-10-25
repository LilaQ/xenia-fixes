$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'PatchManager.Core.psm1') -Force
function Assert($ok,$msg){if(!$ok){throw $msg}}
$root=Join-Path $PSScriptRoot ('.test-'+[guid]::NewGuid().ToString('N'))
try{
    foreach($dir in @('config','patches','PatchManager','zip-source/upstream/patches')){[IO.Directory]::CreateDirectory((Join-Path $root $dir))|Out-Null}
    $old=@'
title_name = "Test"
title_id = "12345678"
hash = "0000000000000001"
[[patch]]
 name = "60 FPS"
 is_enabled = true
 [[patch.be32]]
  address = 0x82000000
  value = 0x60000000
'@
    $path=Join-Path $root 'patches/12345678 - Test.patch.toml';Write-Atomic $path $old
    $new=$old.Replace('0000000000000001','0000000000000002').Replace('is_enabled = true','is_enabled = false')+@'

[[patch]]
 name = "New cheat"
 is_enabled = true
 [[patch.be8]]
  address = 0x82000010
  value = 0x01
'@
    Write-Atomic (Join-Path $root 'zip-source/upstream/patches/12345678 - Test.patch.toml') $new
    Write-Atomic (Join-Path $root 'PatchManager/library.json') '[{"title_id":"12345678","id":"test","title":"Test","system":"Microsoft Xbox 360","app":false}]'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip=Join-Path $root 'fixture.zip';[IO.Compression.ZipFile]::CreateFromDirectory((Join-Path $root 'zip-source'),$zip)
    $module=Get-Module PatchManager.Core
    & $module {param($zipPath)
        $script:fixtureZip=$zipPath
        function script:Invoke-RestMethod { [pscustomobject]@{sha=('a'*40)} }
        function script:Invoke-WebRequest {param($OutFile);Copy-Item -LiteralPath $script:fixtureZip -Destination $OutFile}
    } $zip
    Update-Upstream $root|Out-Null
    $f=Get-PatchFile $path
    Assert ($f.Blocks[0].Enabled -and !$f.Blocks[1].Enabled -and $f.Hashes[0] -eq '0000000000000002') 'Update lost selections, enabled a new cheat or modified the upstream hash'
    Assert ((Get-Content -LiteralPath (Join-Path $root 'config/12345678.config.toml') -Raw).Contains('framerate_limit = 60')) 'Missing FPS dependency'
    $before=[IO.File]::ReadAllText($path);$newPath=Join-Path $root 'new.txt';$failed=$false
    try{& $module {param($r,$p,$n)
        Invoke-ChangeTransaction $r 'rollback-test' @($p,$n) {Write-Atomic $p 'changed';Write-Atomic $n 'new';throw 'Simulated failure'}
    } $root $path $newPath}catch{$failed=$true}
    Assert ($failed -and [IO.File]::ReadAllText($path) -eq $before -and !(Test-Path -LiteralPath $newPath)) 'Transaction rollback failed'
    'PASS: GitHub update flow, selections retained, new options disabled, upstream hashes retained, dependency and transactional rollback'
}finally{if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}}
