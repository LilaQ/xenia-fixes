#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $PSScriptRoot 'PatchManager.Core.psm1') -Force
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
# The cabinet's SMB account cannot write the user's Desktop. Create the shortcut
# locally as the signed-in Windows user when this tool is first started.
try {
    $desktopLink=Join-Path ([Environment]::GetFolderPath('Desktop')) 'Xenia Patch-Manager.lnk'
    if(!(Test-Path -LiteralPath $desktopLink)) {
        $shell=New-Object -ComObject WScript.Shell;$shortcut=$shell.CreateShortcut($desktopLink)
        $shortcut.TargetPath=Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
        $shortcut.Arguments='-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$PSCommandPath+'"'
        $shortcut.WorkingDirectory=$root;$shortcut.IconLocation=(Join-Path $root 'xenia_canary.exe');$shortcut.Save()
    }
} catch { [Windows.Forms.MessageBox]::Show('Desktop-Verknüpfung konnte nicht erstellt werden: '+$_.Exception.Message,'Patch-Manager')|Out-Null }
$mutex=New-Object Threading.Mutex($false,'Local\XeniaPatchManager')
if(!$mutex.WaitOne(0)){[Windows.Forms.MessageBox]::Show('Der Patch-Manager ist bereits geöffnet.')|Out-Null;exit}
$form=New-Object Windows.Forms.Form
$form.Text='Xenia Patch-Manager';$form.Size=New-Object Drawing.Size(1050,760);$form.MinimumSize=New-Object Drawing.Size(880,650);$form.StartPosition='CenterScreen'
$form.Font=New-Object Drawing.Font('Segoe UI',10)
$layout=New-Object Windows.Forms.TableLayoutPanel;$layout.Dock='Fill';$layout.ColumnCount=2;$layout.RowCount=1
$layout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',34)))|Out-Null;$layout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',66)))|Out-Null;$form.Controls.Add($layout)
$left=New-Object Windows.Forms.TableLayoutPanel;$left.Dock='Fill';$left.ColumnCount=1;$left.RowCount=3
$left.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',38)))|Out-Null;$left.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',30)))|Out-Null;$left.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100)))|Out-Null;$layout.Controls.Add($left,0,0)
$search=New-Object Windows.Forms.TextBox;$search.Dock='Fill';$search.Margin=New-Object Windows.Forms.Padding(8);$left.Controls.Add($search,0,0)
$only=New-Object Windows.Forms.CheckBox;$only.Text='Nur Spiele mit Patches';$only.Checked=$true;$only.Dock='Fill';$only.Margin=New-Object Windows.Forms.Padding(8,0,8,0);$left.Controls.Add($only,0,1)
$list=New-Object Windows.Forms.ListBox;$list.Dock='Fill';$list.DisplayMember='Display';$list.Margin=New-Object Windows.Forms.Padding(8);$left.Controls.Add($list,0,2)
$right=New-Object Windows.Forms.TableLayoutPanel;$right.Dock='Fill';$right.ColumnCount=1;$right.RowCount=6
foreach($height in @(38,52)){$right.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',$height)))|Out-Null}
$right.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',60)))|Out-Null;$right.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',40)))|Out-Null
foreach($height in @(44,70)){$right.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',$height)))|Out-Null};$layout.Controls.Add($right,1,0)
$version=New-Object Windows.Forms.ComboBox;$version.Dock='Fill';$version.DropDownStyle='DropDownList';$version.DisplayMember='File';$version.Margin=New-Object Windows.Forms.Padding(8);$right.Controls.Add($version,0,0)
$guard=New-Object Windows.Forms.Label;$guard.Dock='Fill';$guard.Margin=New-Object Windows.Forms.Padding(8);$guard.Text='Spiel auswählen.';$right.Controls.Add($guard,0,1)
$grid=New-Object Windows.Forms.DataGridView;$grid.Dock='Fill';$grid.Margin=New-Object Windows.Forms.Padding(8);$grid.AllowUserToAddRows=$false;$grid.AllowUserToDeleteRows=$false;$grid.RowHeadersVisible=$false;$grid.AutoGenerateColumns=$false;$grid.AutoSizeColumnsMode='Fill';$grid.SelectionMode='FullRowSelect';$grid.MultiSelect=$false;$grid.BackgroundColor=[Drawing.SystemColors]::Window
$check=New-Object Windows.Forms.DataGridViewCheckBoxColumn;$check.Name='Enabled';$check.HeaderText='An';$check.FillWeight=12;$grid.Columns.Add($check)|Out-Null
$name=New-Object Windows.Forms.DataGridViewTextBoxColumn;$name.Name='Name';$name.HeaderText='Patch';$name.ReadOnly=$true;$name.FillWeight=88;$grid.Columns.Add($name)|Out-Null;$right.Controls.Add($grid,0,2)
$details=New-Object Windows.Forms.TextBox;$details.Dock='Fill';$details.Multiline=$true;$details.ReadOnly=$true;$details.ScrollBars='Vertical';$details.Margin=New-Object Windows.Forms.Padding(8);$right.Controls.Add($details,0,3)
$buttons=New-Object Windows.Forms.FlowLayoutPanel;$buttons.Dock='Fill';$buttons.Margin=New-Object Windows.Forms.Padding(8,0,8,0)
$save=New-Object Windows.Forms.Button;$save.Text='Speichern';$save.AutoSize=$true;$save.Enabled=$false;$buttons.Controls.Add($save)
$update=New-Object Windows.Forms.Button;$update.Text='GitHub aktualisieren';$update.AutoSize=$true;$buttons.Controls.Add($update);$right.Controls.Add($buttons,0,4)
$status=New-Object Windows.Forms.Label;$status.Dock='Fill';$status.Margin=New-Object Windows.Forms.Padding(8);$status.Text='Lädt …';$right.Controls.Add($status,0,5)
$script:files=@();$script:library=@();$script:selected=$null;$script:dirty=$false;$script:loading=$false;$script:job=$null
function Save-Selection {
    if(!$script:selected){return $true}
    try{
        $grid.EndEdit()|Out-Null;$choices=@{};foreach($row in $grid.Rows){$choices[[string]$row.Cells['Name'].Value]=[bool]$row.Cells['Enabled'].Value}
        $backup=Save-PatchFile $root $script:selected $choices
        $script:selected=Get-PatchFile $script:selected.Path;$script:files=@(Get-AllPatchFiles $root);$script:dirty=$false;$save.Enabled=$false
        $status.Text="Gespeichert. Gilt nach Xenia-Neustart. FPS-Patches: maximal 60 FPS.`r`nBackup: $backup"
        return $true
    }catch{[Windows.Forms.MessageBox]::Show($_.Exception.Message,'Nicht gespeichert','OK','Error')|Out-Null;return $false}
}
function Check-Unsaved {
    if(!$script:dirty){return $true}
    $answer=[Windows.Forms.MessageBox]::Show('Änderungen vor dem Wechsel speichern?','Patch-Manager','YesNoCancel','Question')
    if($answer -eq 'Cancel'){return $false}
    if($answer -eq 'Yes'){return (Save-Selection)}
    $script:dirty=$false;return $true
}
function Show-Patches {
    $script:loading=$true;$script:selected=$version.SelectedItem;$grid.Rows.Clear();$details.Clear()
    if($script:selected){
        $guard.Text="Titel-ID: $($script:selected.TitleId)   |   Hash: $($script:selected.Hashes -join ', ')`r`nXenia aktiviert nur passende Spielversionen. Optionen mit TU brauchen dieses Update."
        foreach($b in $script:selected.Blocks){$index=$grid.Rows.Add($b.Enabled,$b.Name);$grid.Rows[$index].Tag=$b}
    }else{$guard.Text='Für dieses Spiel gibt es im aktuellen Bestand keine Patches.'}
    $script:dirty=$false;$save.Enabled=$false;$script:loading=$false
}
function Show-Versions {
    $script:loading=$true;$version.Items.Clear()
    if($list.SelectedItem){foreach($f in $script:files|Where-Object TitleId -eq $list.SelectedItem.title_id){$version.Items.Add($f)|Out-Null}}
    $script:loading=$false
    if($version.Items.Count){$version.SelectedIndex=0}else{Show-Patches}
}
function Fill-Games {
    if(!(Check-Unsaved)){return}
    $script:loading=$true;$list.Items.Clear();$available=@{};foreach($f in $script:files){$available[$f.TitleId]=$true}
    foreach($g in $script:library|Sort-Object title,system){
        if($only.Checked -and !$available.ContainsKey([string]$g.title_id)){continue}
        if($search.Text -and $g.title.IndexOf($search.Text,[StringComparison]::OrdinalIgnoreCase) -lt 0){continue}
        $type=if($g.system -eq 'Microsoft Xbox 360'){'360'}else{'XBLA'}
        $entry=[pscustomobject]@{Display=($g.title+' ['+$type+']');title_id=$g.title_id};$list.Items.Add($entry)|Out-Null
    }
    $script:loading=$false
    if($list.Items.Count){$list.SelectedIndex=0}else{Show-Versions}
}
function Reload-Library {
    $script:files=@(Get-AllPatchFiles $root);$script:library=@(Get-Library $root|Where-Object{!$_.app}|Sort-Object id -Unique);Fill-Games
}
function Start-Update {
    if($script:job -or !(Check-Unsaved)){return}
    $update.Enabled=$false;$save.Enabled=$false;$grid.Enabled=$false;$list.Enabled=$false;$version.Enabled=$false;$status.Text='GitHub wird geprüft … Bestehende Optionen werden erhalten.'
    $script:job=Start-Job -ArgumentList $PSScriptRoot,$root -ScriptBlock {param($folder,$emulator);$ErrorActionPreference='Stop';Import-Module (Join-Path $folder 'PatchManager.Core.psm1');Update-Upstream $emulator}
    $timer.Start()
}
$timer=New-Object Windows.Forms.Timer;$timer.Interval=250
$timer.Add_Tick({
    if($script:job -and $script:job.State -in @('Completed','Failed','Stopped')){
        $timer.Stop()
        try{$output=@(Receive-Job $script:job -ErrorAction Stop);Reload-Library;$status.Text=($output -join "`r`n")+"`r`nNeue Optionen bleiben aus. Änderungen wirken nach Xenia-Neustart."}
        catch{$status.Text='GitHub-Update fehlgeschlagen; lokale Patches bleiben verfügbar: '+$_.Exception.Message}
        finally{Remove-Job $script:job -Force;$script:job=$null;$update.Enabled=$true;$grid.Enabled=$true;$list.Enabled=$true;$version.Enabled=$true}
    }
})
$grid.Add_CurrentCellDirtyStateChanged({if($grid.IsCurrentCellDirty){$grid.CommitEdit([Windows.Forms.DataGridViewDataErrorContexts]::Commit)|Out-Null}})
$grid.Add_CellValueChanged({if(!$script:loading -and $script:selected){$script:dirty=$true;$save.Enabled=$true}})
$grid.Add_SelectionChanged({if($grid.SelectedRows.Count){$b=$grid.SelectedRows[0].Tag;if($b){$details.Text=$b.Name+"`r`n`r`n"+$b.Description}}})
$list.Add_SelectedIndexChanged({if(!$script:loading){if(Check-Unsaved){Show-Versions}else{$script:loading=$true;for($i=0;$i -lt $list.Items.Count;$i++){if($script:selected -and $list.Items[$i].title_id -eq $script:selected.TitleId){$list.SelectedIndex=$i;break}};$script:loading=$false}}})
$version.Add_SelectedIndexChanged({if(!$script:loading){if(Check-Unsaved){Show-Patches}else{$script:loading=$true;for($i=0;$i -lt $version.Items.Count;$i++){if($version.Items[$i].File -eq $script:selected.File){$version.SelectedIndex=$i;break}};$script:loading=$false}}})
$search.Add_TextChanged({Fill-Games});$only.Add_CheckedChanged({Fill-Games});$save.Add_Click({Save-Selection|Out-Null});$update.Add_Click({Start-Update})
$form.Add_Shown({try{Reload-Library;Start-Update}catch{[Windows.Forms.MessageBox]::Show($_.Exception.Message,'Patch-Manager','OK','Error')|Out-Null}})
$form.Add_FormClosing({param($sender,$eventArgs);if($script:job){$eventArgs.Cancel=$true;$status.Text='Bitte das laufende GitHub-Update abwarten.'}elseif(!(Check-Unsaved)){$eventArgs.Cancel=$true}})
try{[Windows.Forms.Application]::Run($form)}finally{$timer.Dispose();$mutex.ReleaseMutex();$mutex.Dispose()}
