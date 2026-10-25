Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
function Read-Json($Path, $Default) {
    if (Test-Path -LiteralPath $Path) { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) }
    return $Default
}
function Write-Atomic($Path, [string]$Text) {
    $parent = Split-Path $Path -Parent
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $temp = $Path + '.new-' + [guid]::NewGuid().ToString('N')
    try { [IO.File]::WriteAllText($temp, $Text, (New-Object Text.UTF8Encoding($false))); Move-Item -LiteralPath $temp -Destination $Path -Force }
    finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
}
function Get-StringField([string]$Text, [string]$Key) {
    $pattern = '(?ms)^\s*' + [regex]::Escape($Key) + '\s*=\s*(?:"""(.*?)"""|''(' + '[^'']*' + ')''|"((?:\\.|[^"\\])*)")'
    $m = [regex]::Match($Text, $pattern)
    if (!$m.Success) { return '' }
    if ($m.Groups[1].Success) { return $m.Groups[1].Value.Trim() }
    if ($m.Groups[2].Success) { return $m.Groups[2].Value }
    return [regex]::Unescape($m.Groups[3].Value)
}
function Get-PatchFile([string]$Path) {
    $text = [IO.File]::ReadAllText($Path)
    $chunks = [regex]::Split($text, '(?m)^\[\[patch\]\][ \t]*(?:#[^\r\n]*)?\r?$')
    $tid = Get-StringField $chunks[0] 'title_id'
    $hash = [regex]::Match($chunks[0], '(?ms)^hash\s*=\s*(\[.*?\]|"[0-9A-Fa-f]+")').Groups[1].Value
    $hash = [regex]::Replace($hash, '(?m)#[^\r\n]*', '')
    $hashes = @([regex]::Matches($hash, '"([0-9A-Fa-f]{16})"') | ForEach-Object { $_.Groups[1].Value.ToUpperInvariant() })
    if ($tid -notmatch '^[0-9A-Fa-f]{8}$' -or !$hashes.Count) { throw "Invalid patch header: $Path" }
    $blocks = @()
    for ($i = 1; $i -lt $chunks.Count; $i++) {
        $chunk = $chunks[$i]; $name = Get-StringField $chunk 'name'
        $enabled = [regex]::Matches($chunk, '(?m)^\s*is_enabled\s*=\s*(true|false)\b')
        if (!$name -or $enabled.Count -ne 1) { throw "Invalid patch block: $Path ($i)" }
        $blocks += [pscustomobject]@{ Index=$i-1; Name=$name; Description=(Get-StringField $chunk 'desc'); Enabled=($enabled[0].Groups[1].Value -eq 'true'); Text=$chunk }
    }
    if (@($blocks | Group-Object Name | Where-Object Count -gt 1).Count) { throw "Duplicate patch names: $Path" }
    return [pscustomobject]@{ Path=$Path; File=[IO.Path]::GetFileName($Path); TitleId=$tid.ToUpperInvariant(); Title=(Get-StringField $chunks[0] 'title_name'); Hashes=$hashes; Text=$text; Blocks=$blocks }
}
function Set-PatchChoices($File, $Choices) {
    $i = -1
    $chunks = [regex]::Split($File.Text, '(?m)(?=^\[\[patch\]\][ \t]*(?:#[^\r\n]*)?\r?$)')
    for ($n=1; $n -lt $chunks.Count; $n++) {
        $i++; $name=$File.Blocks[$i].Name
        if ($Choices.Contains($name)) {
            $value = if ($Choices[$name]) { 'true' } else { 'false' }
            $chunks[$n] = [regex]::Replace($chunks[$n], '(?m)^(\s*is_enabled\s*=\s*)(true|false)\b', ('${1}'+$value))
        }
    }
    return ($chunks -join '')
}
function Get-Library($Root) {
    $lb = Split-Path (Split-Path $Root -Parent) -Parent
    $cache = Join-Path $Root 'PatchManager/library.json'
    $titles=@{}
    foreach ($system in @('Microsoft Xbox 360','Microsoft Xbox Live Arcade')) {
        $xmlPath=Join-Path $lb ('Data/Platforms/'+$system+'.xml')
        if (!(Test-Path -LiteralPath $xmlPath)) { continue }
        [xml]$xml=Get-Content -LiteralPath $xmlPath -Raw -Encoding UTF8
        foreach ($g in $xml.LaunchBox.Game) { $titles[[string]$g.ID]=[string]$g.Title }
    }
    $items=@(Read-Json $cache @())
    if (!$items.Count) { throw 'The installed library cache is missing. No patch files were changed.' }
    foreach ($item in $items) { if ($titles.ContainsKey([string]$item.id)) { $item.title=$titles[[string]$item.id] } }
    return $items
}
function Get-AllPatchFiles($Root) {
    $folder=Join-Path $Root 'patches'
    if (!(Test-Path -LiteralPath $folder)) { return @() }
    return @(Get-ChildItem -LiteralPath $folder -Filter '*.patch.toml' -File | Sort-Object Name | ForEach-Object { Get-PatchFile $_.FullName })
}
function Get-Writes($Block) {
    $writes=@(); $entries=[regex]::Matches($Block.Text,'(?ms)\[\[patch\.(be8|be16|be32|be64|f32|f64|string|array)\]\](.*?)(?=\[\[patch\.|\z)')
    foreach ($e in $entries) {
        $kind=$e.Groups[1].Value; $s=$e.Groups[2].Value
        $a=[regex]::Match($s,'(?m)^\s*address\s*=\s*(0x[0-9a-fA-F]+|[0-9]+)')
        if (!$a.Success) { throw "Invalid address: $($Block.Name)" }
        $address=if($a.Groups[1].Value.StartsWith('0x')) {[Convert]::ToUInt64($a.Groups[1].Value.Substring(2),16)} else {[Convert]::ToUInt64($a.Groups[1].Value)}
        if ($kind -eq 'string') { $bytes=[Text.Encoding]::UTF8.GetBytes((Get-StringField $s 'value')) }
        elseif ($kind -eq 'array') {
            $v=Get-StringField $s 'value'; $v=$v -replace '\s','';$v=$v -replace '^0x','';if($v -notmatch '^(?:[0-9a-fA-F]{2})+$'){throw 'Unsupported array encoding'}
            $bytes=@(); for($i=0;$i -lt $v.Length;$i+=2){$bytes += [Convert]::ToByte($v.Substring($i,2),16)}
        } else {
            $v=[regex]::Match($s,'(?m)^\s*value\s*=\s*([^#\r\n]+)').Groups[1].Value.Trim()
            if ($kind -eq 'f32') { $bytes=[BitConverter]::GetBytes([float]::Parse($v,[Globalization.CultureInfo]::InvariantCulture));[array]::Reverse($bytes) }
            elseif ($kind -eq 'f64') { $bytes=[BitConverter]::GetBytes([double]::Parse($v,[Globalization.CultureInfo]::InvariantCulture));[array]::Reverse($bytes) }
            else {
                $length=[int]$kind.Substring(2)/8
                $number=if($v.StartsWith('0x')){[Convert]::ToUInt64($v.Substring(2),16)}else{[Convert]::ToUInt64($v)}
                $all=[BitConverter]::GetBytes($number);[array]::Reverse($all);$bytes=$all[(8-$length)..7]
            }
        }
        for($i=0;$i -lt $bytes.Count;$i++){ $writes += [pscustomobject]@{Address=$address+$i;Value=[byte]$bytes[$i]} }
    }
    return $writes
}
function Assert-NoConflicts($Files) {
    $seen=@{}
    foreach($f in $Files) {
        foreach($b in $f.Blocks | Where-Object Enabled) {
            foreach($h in $f.Hashes) {
                foreach($w in Get-Writes $b) {
                    $key="$($f.TitleId):${h}:$($w.Address)"
                    if($seen.ContainsKey($key) -and $seen[$key].Value -ne $w.Value){throw "Conflicting patches: $($seen[$key].Name) / $($b.Name) [$($f.TitleId)]"}
                    $seen[$key]=[pscustomobject]@{Value=$w.Value;Name=$b.Name}
                }
            }
        }
    }
}
function New-Backup($Root, [string]$Reason, $Paths) {
    $folder=Join-Path $Root ('PatchManager/Backups/'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'-'+$Reason)
    [IO.Directory]::CreateDirectory($folder)|Out-Null
    foreach($p in $Paths) {
        if(Test-Path -LiteralPath $p){$relative=$p.Substring($Root.Length).TrimStart([char[]]'\/');$dest=Join-Path $folder $relative;[IO.Directory]::CreateDirectory((Split-Path $dest -Parent))|Out-Null;Copy-Item -LiteralPath $p -Destination $dest -Force}
    }
    return $folder
}
function Write-ManagerLog($Root, [string]$Message) {
    $path=Join-Path $Root 'PatchManager/PatchManager.log'
    [IO.File]::AppendAllText($path, ((Get-Date -Format s)+' '+$Message+[Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
}
function Update-PatchSettings($Root,$Files) {
    # Partial configs are loaded by TitleID after the existing LaunchBox config.
    # Only keys owned by this manager are restored when the last related patch is disabled.
    $statePath=Join-Path $Root 'PatchManager/settings.json';$state=Read-Json $statePath ([pscustomobject]@{Managed=@()})
    $desired=@{}
    foreach($f in $Files){foreach($b in $f.Blocks | Where-Object Enabled){
        if($b.Name -match '^(60 FPS|Unlock FPS|FPS Uncap|120 FPS)$'){$desired[$f.TitleId]=@{}}
    }}
    foreach($tid in @($desired.Keys)){$desired[$tid]['GPU.framerate_limit']='60'}
    if($desired.ContainsKey('5454082B')){$desired['5454082B']['GPU.vsync']='false'}
    if($desired.ContainsKey('58410955')){$desired['58410955']['CPU.break_on_debugbreak']='false'}
    if($desired.ContainsKey('58410954')){$desired['58410954']['CPU.break_on_debugbreak']='false'}
    # Imported game recommendations may need a different presentation limit.
    # Keep those explicit values when maintaining patch companion settings.
    $optimized=Read-Json (Join-Path $Root 'PatchManager/optimized-settings.json') ([pscustomobject]@{Overrides=@()})
    foreach($preset in @($optimized.Overrides)){
        $tid=[string]$preset.TitleId
        if(!$desired.ContainsKey($tid)){continue}
        foreach($key in @($desired[$tid].Keys)){
            $value=$preset.Options.PSObject.Properties[$key]
            if($value){$desired[$tid][$key]=[string]$value.Value}
        }
    }
    $managed=@($state.Managed);$ids=@(@($desired.Keys)+@($managed|ForEach-Object{$_.TitleId})|Select-Object -Unique)
    $newManaged=@()
    foreach($tid in $ids){
        $path=Join-Path $Root ('config/'+$tid+'.config.toml');$text=if(Test-Path -LiteralPath $path){[IO.File]::ReadAllText($path)}else{''}
        $old=@($managed|Where-Object TitleId -eq $tid);$original=if($old.Count){$old[0].Original}else{[pscustomobject]@{}}
        $keys=@('GPU.framerate_limit','GPU.vsync','CPU.break_on_debugbreak')
        foreach($key in $keys){
            $split=$key.Split('.');$section=$split[0];$name=$split[1]
            $pattern='(?ms)(^\['+[regex]::Escape($section)+'\][^\r\n]*\r?\n)(.*?)(?=^\[|\z)';$m=[regex]::Match($text,$pattern)
            $linePattern='(?m)^([ \t]*'+[regex]::Escape($name)+'[ \t]*=[ \t]*)([^#\r\n]*)([^\r\n]*)';$line=[regex]::Match($m.Groups[2].Value,$linePattern)
            $property=$original.PSObject.Properties[$key]
            if($desired.ContainsKey($tid) -and $desired[$tid].ContainsKey($key)){
                if(!$property){$original|Add-Member -NotePropertyName $key -NotePropertyValue $(if($line.Success){$line.Groups[2].Value.Trim()}else{$null})}
                $value=$desired[$tid][$key]
                if($line.Success){$body=[regex]::Replace($m.Groups[2].Value,$linePattern,('${1}'+$value+' ${3}'));$text=$text.Substring(0,$m.Index)+$m.Groups[1].Value+$body+$text.Substring($m.Index+$m.Length)}
                elseif($m.Success){$text=$text.Insert($m.Index+$m.Groups[1].Length,"$name = $value`n")}
                else{$text += "`n[$section]`n$name = $value`n"}
            }elseif($property){
                if($null -eq $property.Value){$body=[regex]::Replace($m.Groups[2].Value,($linePattern+'\r?\n?'),'')}
                else{$body=[regex]::Replace($m.Groups[2].Value,$linePattern,('${1}'+$property.Value+' ${3}'))}
                if($m.Success){$text=$text.Substring(0,$m.Index)+$m.Groups[1].Value+$body+$text.Substring($m.Index+$m.Length)}
                $original.PSObject.Properties.Remove($key)
            }
        }
        if($desired.ContainsKey($tid)){$newManaged += [pscustomobject]@{TitleId=$tid;Original=$original}}
        $text=[regex]::Replace($text,'(?m)^\[(GPU|CPU)\]\s*(?=\[|\z)','')
        if($text.Trim()){Write-Atomic $path $text}else{if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Force}}
    }
    Write-Atomic $statePath (([pscustomobject]@{Managed=$newManaged}|ConvertTo-Json -Depth 10))
}
function Get-SettingsPaths($Root,$Files) {
    $paths=@((Join-Path $Root 'PatchManager/settings.json'))
    $state=Read-Json $paths[0] ([pscustomobject]@{Managed=@()})
    $ids=@(@($Files|ForEach-Object TitleId)+@($state.Managed|ForEach-Object TitleId)|Select-Object -Unique)
    foreach($tid in $ids){$paths += Join-Path $Root ('config/'+$tid+'.config.toml')}
    return $paths
}
function Invoke-ChangeTransaction($Root,$Reason,$Paths,[scriptblock]$Action) {
    $snapshot=@{}
    foreach($path in $Paths|Select-Object -Unique){$snapshot[$path]=if(Test-Path -LiteralPath $path){[IO.File]::ReadAllBytes($path)}else{$null}}
    $backup=New-Backup $Root $Reason $Paths
    try{& $Action;return $backup}
    catch{
        $failure=$_
        foreach($path in $snapshot.Keys){
            if($null -eq $snapshot[$path]){if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Force}}
            else{[IO.File]::WriteAllBytes($path,$snapshot[$path])}
        }
        throw $failure
    }
}
function Save-PatchFile($Root,$File,$Choices) {
    if([IO.File]::ReadAllText($File.Path) -ne $File.Text){throw 'Patch changed outside the manager. Reload before saving.'}
    $new=Set-PatchChoices $File $Choices
    $temp=Join-Path $Root ('PatchManager/save-'+[guid]::NewGuid().ToString('N')+'.patch.toml')
    try{
        Write-Atomic $temp $new;$parsed=Get-PatchFile $temp
        $all=@(Get-AllPatchFiles $Root | Where-Object File -ne $File.File)+@($parsed);Assert-NoConflicts $all
        # Banjo-Kazooie's FPS patch is inseparable from its timing corrections.
        if($parsed.TitleId -eq '58410954' -and @($parsed.Blocks|Where-Object{$_.Name -eq '60 FPS' -and $_.Enabled}).Count){
            $required=@('Swimfix','Global Fix','Special Fix','Timer Fix','Gravity Fix','Walker Fix','Egg Gravity Fix','Concert Timer Fix')
            foreach($name in $required){if(!@($parsed.Blocks|Where-Object{$_.Name -eq $name -and $_.Enabled}).Count){throw "60 FPS requires: $name"}}
        }
        if($parsed.TitleId -eq '4541080F'){
            $engine=@($all|Where-Object{$_.File -match '\(engine_360.dll\)' -and @($_.Blocks|Where-Object{$_.Name -eq 'Unlock FPS' -and $_.Enabled}).Count})
            $shader=@($all|Where-Object{$_.File -match '\(shaderapidx9_360.dll\)' -and @($_.Blocks|Where-Object{$_.Name -eq 'Unlock FPS' -and $_.Enabled}).Count})
            # The edited temporary file has a random filename; identify its role using the original name.
            if($File.File -match '\(engine_360.dll\)' -and @($parsed.Blocks|Where-Object{$_.Name -eq 'Unlock FPS' -and $_.Enabled}).Count){$engine=@($parsed)}
            if($File.File -match '\(shaderapidx9_360.dll\)' -and @($parsed.Blocks|Where-Object{$_.Name -eq 'Unlock FPS' -and $_.Enabled}).Count){$shader=@($parsed)}
            if($engine.Count -and !$shader.Count){throw 'Orange Box: enable Unlock FPS for shaderapidx9_360.dll first.'}
        }
        $paths=@($File.Path)+@(Get-SettingsPaths $Root $all)
        $backup=Invoke-ChangeTransaction $Root 'options' $paths {Write-Atomic $File.Path $new;Update-PatchSettings $Root (Get-AllPatchFiles $Root)}
        Write-ManagerLog $Root ('Saved '+$File.File+'; backup '+$backup)
        return $backup
    }finally{if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Force}}
}
function Update-Upstream($Root) {
    [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
    $headers=@{'User-Agent'='Xenia-Patch-Manager';'Accept'='application/vnd.github+json'}
    $commit=Invoke-RestMethod -Uri 'https://api.github.com/repos/xenia-canary/game-patches/commits/main' -Headers $headers -TimeoutSec 30
    $sha=[string]$commit.sha;if($sha -notmatch '^[0-9a-f]{40}$'){throw 'Invalid upstream commit'}
    $metaPath=Join-Path $Root 'PatchManager/upstream.json';$previous=Read-Json $metaPath $null
    if($null -ne $previous -and $previous.Commit -eq $sha){return ('Aktuell: '+$sha.Substring(0,8))}
    $work=Join-Path $Root ('PatchManager/update-'+[guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($work)|Out-Null
    try{
        $zipPath=Join-Path $work 'upstream.zip';Invoke-WebRequest -Uri ('https://codeload.github.com/xenia-canary/game-patches/zip/'+$sha) -Headers $headers -OutFile $zipPath -TimeoutSec 120 -UseBasicParsing
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip=[IO.Compression.ZipFile]::OpenRead($zipPath);$ids=@{};foreach($i in Get-Library $Root){$ids[[string]$i.title_id]=$true}
        $live=@{};foreach($f in Get-AllPatchFiles $Root){$live[$f.File]=$f}
        $staged=@()
        try{foreach($entry in $zip.Entries){
            if($entry.FullName -notmatch '/patches/([^/]+\.patch\.toml)$'){continue}
            $name=$Matches[1];if($name -notmatch '^([0-9A-Fa-f]{8}) - [^\\/]+\.patch\.toml$'){throw 'Invalid patch filename'}
            if(!$ids.ContainsKey($Matches[1].ToUpperInvariant())){continue}
            if($entry.Length -gt 1048576){throw 'Unexpected patch size'}
            $dest=Join-Path $work $name;$reader=New-Object IO.StreamReader($entry.Open());try{$text=$reader.ReadToEnd()}finally{$reader.Dispose()}
            Write-Atomic $dest $text;$f=Get-PatchFile $dest
            # New options remain off. Existing choices are preserved by option name,
            # while the upstream title/hash/address guards are kept unchanged.
            $choices=@{};foreach($b in $f.Blocks){$choices[$b.Name]=$false}
            if($live.ContainsKey($name)){foreach($b in $live[$name].Blocks){if($choices.ContainsKey($b.Name)){$choices[$b.Name]=$b.Enabled}}}
            Write-Atomic $dest (Set-PatchChoices $f $choices);$staged += Get-PatchFile $dest
        }}finally{$zip.Dispose()}
        if(!$staged.Count){throw 'No applicable patch files in upstream archive'}
        $stagedNames=@{};foreach($f in $staged){$stagedNames[$f.File]=$true}
        $remaining=@($live.Values|Where-Object{!$stagedNames.ContainsKey($_.File)})
        Assert-NoConflicts (@($staged)+$remaining)
        $paths=@($staged|ForEach-Object{Join-Path $Root ('patches/'+$_.File)})+@($metaPath)+@(Get-SettingsPaths $Root (@($staged)+$remaining))
        $backup=Invoke-ChangeTransaction $Root 'github' $paths {
            foreach($f in $staged){Write-Atomic (Join-Path $Root ('patches/'+$f.File)) $f.Text}
            Update-PatchSettings $Root (Get-AllPatchFiles $Root)
            Write-Atomic $metaPath (([pscustomobject]@{Commit=$sha;Files=@($staged|ForEach-Object File)}|ConvertTo-Json -Depth 5))
        }
        Write-ManagerLog $Root ('Updated '+$sha+'; '+$staged.Count+' files; backup '+$backup)
        return ('Aktualisiert: '+$staged.Count+' Dateien, '+$sha.Substring(0,8)+'; neue Optionen ausgeschaltet.')
    }finally{if(Test-Path -LiteralPath $work){Remove-Item -LiteralPath $work -Recurse -Force}}
}
Export-ModuleMember -Function Get-PatchFile,Get-AllPatchFiles,Get-Library,Set-PatchChoices,Get-Writes,Assert-NoConflicts,Save-PatchFile,Update-Upstream,Update-PatchSettings,Read-Json,Write-Atomic
