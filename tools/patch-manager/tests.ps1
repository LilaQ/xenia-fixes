$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'PatchManager.Core.psm1') -Force
function Assert($Condition,$Message){if(!$Condition){throw $Message}}
$root=Join-Path $PSScriptRoot ('.test-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory((Join-Path $root 'patches'))|Out-Null
[IO.Directory]::CreateDirectory((Join-Path $root 'config'))|Out-Null
[IO.Directory]::CreateDirectory((Join-Path $root 'PatchManager'))|Out-Null
try{
    $text=@'
title_name = "Test Game"
title_id = "12345678"
hash = [
 "0000000000000001", # base
 "0000000000000002"
]
[[patch]]
 name = "60 FPS"
 desc = "Safe \"quoted\" description"
 is_enabled = false # preserve this
 [[patch.be32]]
  address = 0x82000000
  value = 0x60000000
[[patch]]
 name = "Other option"
 desc = """Multi-line
 description"""
 is_enabled = false
 [[patch.be16]]
  address = 0x82000000
  value = 0x4800
'@
    $path=Join-Path $root 'patches/12345678 - Test.patch.toml';Write-Atomic $path $text
    $f=Get-PatchFile $path
    Assert ($f.Hashes.Count -eq 2 -and $f.Blocks.Count -eq 2) 'Header/parser failure'
    Assert ($f.Blocks[0].Description.Contains('"quoted"')) 'Escaped description failure'
    Assert ($f.Blocks[1].Description.Contains('description')) 'Multiline description failure'
    $changed=Set-PatchChoices $f @{'60 FPS'=$true}
    Assert ($changed -eq $text.Replace('is_enabled = false # preserve this','is_enabled = true # preserve this')) 'Changes outside the requested flag'
    Write-Atomic $path $changed;$f=Get-PatchFile $path;Assert-NoConflicts @($f)
    $bad=Set-PatchChoices $f @{'Other option'=$true};$badPath=Join-Path $root 'bad.patch.toml';Write-Atomic $badPath $bad
    $rejected=$false;try{Assert-NoConflicts @((Get-PatchFile $badPath))}catch{$rejected=$true};Assert $rejected 'Conflicting writes were accepted'
    $configPath=Join-Path $root 'config/12345678.config.toml';$before="[GPU]`nframerate_limit = 45 # owner setting`nvsync = true`n[HID]`nhid = `"xinput`"`n"
    Write-Atomic $configPath $before;Update-PatchSettings $root @($f)
    $after=[IO.File]::ReadAllText($configPath);Assert ($after.Contains('framerate_limit = 60') -and $after.Contains('hid = "xinput"')) 'FPS cap or unrelated input preservation failed'
    Write-Atomic $path (Set-PatchChoices $f @{'60 FPS'=$false});Update-PatchSettings $root @((Get-PatchFile $path))
    $restored=[IO.File]::ReadAllText($configPath);Assert ($restored.Contains('framerate_limit = 45') -and $restored.Contains('# owner setting')) 'Original setting not restored'
    Remove-Item -LiteralPath $configPath;Write-Atomic $path $changed;Update-PatchSettings $root @((Get-PatchFile $path));Assert (Test-Path -LiteralPath $configPath) 'New override not created'
    Write-Atomic $path $text;Update-PatchSettings $root @((Get-PatchFile $path));Assert (!(Test-Path -LiteralPath $configPath)) 'Unused override not removed'
    $saveFile=Get-PatchFile $path;$backup=Save-PatchFile $root $saveFile @{'60 FPS'=$true}
    Assert ((Get-PatchFile $path).Blocks[0].Enabled -and (Test-Path -LiteralPath (Join-Path $backup 'patches/12345678 - Test.patch.toml'))) 'Save or backup failed'
    Write-Atomic (Join-Path $root 'PatchManager/optimized-settings.json') '{"Overrides":[{"TitleId":"12345678","Options":{"GPU.framerate_limit":"120"}}]}'
    Write-Atomic $configPath "[GPU]`nframerate_limit = 120 # imported recommendation`nvsync = true`n"
    Write-Atomic (Join-Path $root 'PatchManager/settings.json') '{"Managed":[]}'
    Update-PatchSettings $root @((Get-PatchFile $path))
    Assert ([IO.File]::ReadAllText($configPath).Contains('framerate_limit = 120')) 'Imported presentation limit was overwritten'
    Write-Atomic $path $text;Update-PatchSettings $root @((Get-PatchFile $path))
    Assert ([IO.File]::ReadAllText($configPath).Contains('framerate_limit = 120')) 'Imported setting was lost when disabling its patch'
    'PASS: parser, multiline/hash arrays, flag-only changes, byte conflicts, per-title cap, preservation, restore, removal and backup'
}finally{if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}}
