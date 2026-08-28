#MTAudotDraw
#Copyright (C) 2022  Myles Treadwell
#
#This program is free software: you can redistribute it and/or modify
#it under the terms of the GNU General Public License as published by
#the Free Software Foundation, either version 3 of the License, or
#(at your option) any later version.
#
#This program is distributed in the hope that it will be useful,
#but WITHOUT ANY WARRANTY; without even the implied warranty of
#MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#GNU General Public License for more details.
#
#You should have received a copy of the GNU General Public License
#along with this program.  If not, see <http://www.gnu.org/licenses/>.

# MTAutoDraw - the window
#
# A launcher, not a host. This script never dot-sources the pipeline: it builds the UI and runs
# AutoDraw.ps1 as a CHILD pwsh process, streaming its output into the Log tab and reading
# RunSummary.json when it exits. Hosting the pipeline in-process cannot work - AutoDraw.ps1 ends in
# `exit`, which would close this window; it calls Start-Transcript, and a process gets one; it sets
# several dozen globals a second run would inherit; and any long synchronous call on the UI thread
# freezes the window.
#
# Everything that is not a control lives in GuiSettings.ps1, which references no WinForms type and
# can therefore be exercised without constructing a window.
#
# Depends on: GuiSettings.ps1
# Loaded by:  MTAutoDraw.cmd

[CmdletBinding()]
param(
    # Build every control, run the startup work, then exit without showing the window. Constructing
    # this many controls is where a typo becomes a crash, and that is worth a regression test even
    # though what the window looks like is not something a test can judge.
    [switch]$SelfTest,
    # A capture folder to run through the real Run button, with the message loop pumped by
    # DoEvents so the timer fires exactly as it does under ShowDialog. This is what proves output
    # appears WHILE the run is going rather than all at once when it ends - the one thing a plain
    # construction check cannot tell you, and the exact failure PowerShell eventing produced here.
    [string]$SelfTestRun
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

# Captured once at load time. $PSScriptRoot is a script-scope automatic, and every handler below
# runs long after the script body has finished - so the paths a run depends on are resolved here,
# where the answer is certainly right, rather than inside a click handler.
$script:RepoRoot = $PSScriptRoot

. (Join-Path $script:RepoRoot 'GuiSettings.ps1')

# A self-test must not touch the user's real state. -SelfTestRun opens a real window, so the closing
# handler runs and persists whatever the test put in the folder boxes - which is how a test run left
# a deleted temp folder sitting in the user's remembered Output path. Redirected before anything is
# read or written, so the test also cannot see the user's profiles.
$script:SelfTestDataRoot = $null
if ($SelfTest) {
    $script:SelfTestDataRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('mtad-selftest-state-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    Set-MTAutoDrawGuiDataRoot -Path $script:SelfTestDataRoot
}

# ------------------------------------------------------------------------------------------------
# State
#
# One place, so the event handlers below never have to guess where a value lives. Handlers attached
# with Add_* keep this script's scope and are invoked directly by the message loop, so they fire
# normally while the window is open.
# ------------------------------------------------------------------------------------------------
$script:SettingDefinitions = @(Get-MTAutoDrawSettingDefinition)
$script:SettingDefaults    = @{}
foreach ($definition in $script:SettingDefinitions) { $script:SettingDefaults[$definition.Name] = $definition.Default }

$script:SettingControls   = @{}     # setting name -> the control that edits it
$script:PythonPath        = Get-MTAutoDrawDefaultPythonPath
$script:PreflightResults  = @()

$script:RunProcess        = $null
$script:RunPumps          = @()
$script:RunOutputPath     = ''
$script:RunCancelled      = $false
$script:RunDrainPasses    = 0
$script:RunFirstLineAt    = $null

$script:SetupJob          = $null

# ------------------------------------------------------------------------------------------------
# Small control helpers
# ------------------------------------------------------------------------------------------------
function New-GuiLabel {
    param([string]$Text, [int]$Width = 120, [bool]$Bold = $false)

    $label = [Windows.Forms.Label]::new()
    $label.Text = $Text
    $label.AutoSize = $true
    $label.Margin = [Windows.Forms.Padding]::new(3, 6, 3, 3)
    if ($Bold) { $label.Font = [Drawing.Font]::new('Segoe UI', 9, [Drawing.FontStyle]::Bold) }
    return $label
}

function New-GuiButton {
    param([string]$Text, [int]$Width = 110)

    $button = [Windows.Forms.Button]::new()
    $button.Text = $Text
    $button.Width = $Width
    $button.Height = 27
    $button.Margin = [Windows.Forms.Padding]::new(3)
    return $button
}

# A folder picker row: label, path box, Browse. Returns the textbox so the caller can read it.
function Add-GuiFolderRow {
    param(
        [Parameter(Mandatory = $true)]$Parent,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][int]$Row,
        [string]$Description
    )

    $Parent.Controls.Add((New-GuiLabel -Text $Label), 0, $Row)

    $box = [Windows.Forms.TextBox]::new()
    $box.Dock = 'Fill'
    $box.Margin = [Windows.Forms.Padding]::new(3, 3, 3, 3)
    # Drag-and-drop, because the path a user has is usually already open in Explorer.
    $box.AllowDrop = $true
    $box.Add_DragEnter({
        param($sender, $eventArgs)
        if ($eventArgs.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) {
            $eventArgs.Effect = [Windows.Forms.DragDropEffects]::Copy
        }
    })
    $box.Add_DragDrop({
        param($sender, $eventArgs)
        $dropped = @($eventArgs.Data.GetData([Windows.Forms.DataFormats]::FileDrop))
        if ($dropped.Count -eq 0) { return }
        $path = $dropped[0]
        # A dropped file means the folder that holds it; a dropped folder means itself.
        if (Test-Path -LiteralPath $path -PathType Leaf) { $path = Split-Path -Parent $path }
        $sender.Text = $path
    })
    $Parent.Controls.Add($box, 1, $Row)

    $browse = New-GuiButton -Text 'Browse...' -Width 90
    $browse.Add_Click({
        $dialog = [Windows.Forms.FolderBrowserDialog]::new()
        if ($Description) { $dialog.Description = $Description }
        if ($box.Text -and (Test-Path -LiteralPath $box.Text)) { $dialog.SelectedPath = $box.Text }
        if ($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) { $box.Text = $dialog.SelectedPath }
        $dialog.Dispose()
    }.GetNewClosure())
    $Parent.Controls.Add($browse, 2, $Row)

    return $box
}

# ------------------------------------------------------------------------------------------------
# The form
# ------------------------------------------------------------------------------------------------
$Form = [Windows.Forms.Form]::new()
$Form.Text = 'MTAutoDraw'
$Form.StartPosition = 'CenterScreen'
$Form.MinimumSize = [Drawing.Size]::new(980, 680)
$Form.Size = [Drawing.Size]::new(1240, 840)
$Form.Font = [Drawing.Font]::new('Segoe UI', 9)

$Tabs = [Windows.Forms.TabControl]::new()
$Tabs.Dock = 'Fill'
$Form.Controls.Add($Tabs)

$StatusStrip = [Windows.Forms.StatusStrip]::new()
$StatusLabel = [Windows.Forms.ToolStripStatusLabel]::new()
$StatusLabel.Text = 'Ready'
[void]$StatusStrip.Items.Add($StatusLabel)
$Form.Controls.Add($StatusStrip)

function Set-GuiStatus {
    param([string]$Text)
    $StatusLabel.Text = $Text
    $StatusStrip.Refresh()
}

# ================================================================================================
# Tab 1 - Run
# ================================================================================================
$TabRun = [Windows.Forms.TabPage]::new()
$TabRun.Text = 'Run'
$TabRun.Padding = [Windows.Forms.Padding]::new(8)
[void]$Tabs.TabPages.Add($TabRun)

$runLayout = [Windows.Forms.TableLayoutPanel]::new()
$runLayout.Dock = 'Fill'
$runLayout.ColumnCount = 1
$runLayout.RowCount = 3
[void]$runLayout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::AutoSize))
[void]$runLayout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent, 100))
[void]$runLayout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::AutoSize))
$TabRun.Controls.Add($runLayout)

# --- Paths ---
$pathsGroup = [Windows.Forms.GroupBox]::new()
$pathsGroup.Text = 'Folders'
$pathsGroup.Dock = 'Fill'
$pathsGroup.AutoSize = $true
$pathsGroup.AutoSizeMode = 'GrowAndShrink'
$pathsGroup.Padding = [Windows.Forms.Padding]::new(8)

$pathsTable = [Windows.Forms.TableLayoutPanel]::new()
$pathsTable.Dock = 'Fill'
$pathsTable.ColumnCount = 3
$pathsTable.RowCount = 2
$pathsTable.AutoSize = $true
$pathsTable.AutoSizeMode = 'GrowAndShrink'
[void]$pathsTable.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::AutoSize))
[void]$pathsTable.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 100))
[void]$pathsTable.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::AutoSize))
$pathsGroup.Controls.Add($pathsTable)
$runLayout.Controls.Add($pathsGroup, 0, 0)

$InputBox = Add-GuiFolderRow -Parent $pathsTable -Label 'Capture folder' -Row 0 -Description 'The folder holding the collected .txt files'
$OutputBox = Add-GuiFolderRow -Parent $pathsTable -Label 'Output folder' -Row 1 -Description 'Where the .drawio files and exports are written'

# --- Curated settings ---
$settingsScroll = [Windows.Forms.FlowLayoutPanel]::new()
$settingsScroll.Dock = 'Fill'
$settingsScroll.AutoScroll = $true
$settingsScroll.FlowDirection = 'LeftToRight'
$settingsScroll.WrapContents = $true
$runLayout.Controls.Add($settingsScroll, 0, 1)

function Add-CuratedSettingControl {
    $groups = Get-MTAutoDrawCuratedSettingGroup
    foreach ($groupName in $groups.Keys) {
        $box = [Windows.Forms.GroupBox]::new()
        $box.Text = $groupName
        $box.AutoSize = $true
        $box.AutoSizeMode = 'GrowAndShrink'
        $box.Margin = [Windows.Forms.Padding]::new(4)
        $box.Padding = [Windows.Forms.Padding]::new(6)

        $stack = [Windows.Forms.FlowLayoutPanel]::new()
        $stack.FlowDirection = 'TopDown'
        $stack.WrapContents = $false
        $stack.AutoSize = $true
        $stack.AutoSizeMode = 'GrowAndShrink'
        $stack.Dock = 'Fill'
        $box.Controls.Add($stack)

        foreach ($entry in $groups[$groupName]) {
            $definition = $script:SettingDefinitions | Where-Object Name -eq $entry.Name | Select-Object -First 1
            if (-not $definition) { continue }

            $check = [Windows.Forms.CheckBox]::new()
            $check.Text = [string]$entry.Label
            $check.AutoSize = $true
            $check.Checked = [bool]$definition.Default
            $check.Tag = $definition.Name
            if ($entry.Master) { $check.Font = [Drawing.Font]::new('Segoe UI', 9, [Drawing.FontStyle]::Bold) }
            if ($definition.Help) {
                $tip = [Windows.Forms.ToolTip]::new()
                $tip.AutoPopDelay = 32000
                $tip.SetToolTip($check, $definition.Help)
            }
            $check.Add_CheckedChanged({ Update-MasterGating })
            $stack.Controls.Add($check)
            $script:SettingControls[$definition.Name] = $check
        }

        $settingsScroll.Controls.Add($box)
    }
}

# Unchecking a master leaves its children visible but disabled - a checkbox that does nothing is
# worse than one that is visibly inert.
function Update-MasterGating {
    $masters = Get-MTAutoDrawSettingMasterMap
    foreach ($masterName in $masters.Keys) {
        $masterControl = $script:SettingControls[$masterName]
        if (-not $masterControl) { continue }
        foreach ($childName in $masters[$masterName]) {
            $childControl = $script:SettingControls[$childName]
            if ($childControl) { $childControl.Enabled = $masterControl.Checked }
        }
    }
}

Add-CuratedSettingControl

# --- Bottom bar: log level, profiles, Run ---
$runBar = [Windows.Forms.FlowLayoutPanel]::new()
$runBar.Dock = 'Fill'
$runBar.AutoSize = $true
$runBar.AutoSizeMode = 'GrowAndShrink'
$runBar.FlowDirection = 'LeftToRight'
$runBar.WrapContents = $true
$runLayout.Controls.Add($runBar, 0, 2)

$runBar.Controls.Add((New-GuiLabel -Text 'Log level'))
$LogLevelCombo = [Windows.Forms.ComboBox]::new()
$LogLevelCombo.DropDownStyle = 'DropDownList'
$LogLevelCombo.Width = 90
[void]$LogLevelCombo.Items.AddRange(@('Error', 'Warn', 'Info', 'Debug', 'Trace'))
$LogLevelCombo.SelectedItem = 'Info'
$runBar.Controls.Add($LogLevelCombo)

$runBar.Controls.Add((New-GuiLabel -Text '    Profile'))
$ProfileCombo = [Windows.Forms.ComboBox]::new()
$ProfileCombo.DropDownStyle = 'DropDownList'
$ProfileCombo.Width = 180
$runBar.Controls.Add($ProfileCombo)

$ProfileLoadButton = New-GuiButton -Text 'Load' -Width 70
$ProfileSaveButton = New-GuiButton -Text 'Save as...' -Width 90
$ProfileDeleteButton = New-GuiButton -Text 'Delete' -Width 70
$runBar.Controls.Add($ProfileLoadButton)
$runBar.Controls.Add($ProfileSaveButton)
$runBar.Controls.Add($ProfileDeleteButton)

$RunButton = New-GuiButton -Text 'Run' -Width 120
$RunButton.Font = [Drawing.Font]::new('Segoe UI', 9, [Drawing.FontStyle]::Bold)
$CancelButton = New-GuiButton -Text 'Cancel' -Width 90
$CancelButton.Enabled = $false
$runBar.Controls.Add((New-GuiLabel -Text '    '))
$runBar.Controls.Add($RunButton)
$runBar.Controls.Add($CancelButton)

# ================================================================================================
# Tab 2 - Advanced
#
# Generated from configurationVariables.ps1, never hand-listed: the comments in that file are the
# best documentation these settings have, and a duplicated list would drift on the first commit that
# adds one.
# ================================================================================================
$TabAdvanced = [Windows.Forms.TabPage]::new()
$TabAdvanced.Text = 'Advanced'
$TabAdvanced.Padding = [Windows.Forms.Padding]::new(8)
[void]$Tabs.TabPages.Add($TabAdvanced)

$advancedLayout = [Windows.Forms.TableLayoutPanel]::new()
$advancedLayout.Dock = 'Fill'
$advancedLayout.ColumnCount = 1
$advancedLayout.RowCount = 3
[void]$advancedLayout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::AutoSize))
[void]$advancedLayout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent, 100))
[void]$advancedLayout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::AutoSize))
$TabAdvanced.Controls.Add($advancedLayout)

$advancedBar = [Windows.Forms.FlowLayoutPanel]::new()
$advancedBar.Dock = 'Fill'
$advancedBar.AutoSize = $true
$advancedBar.AutoSizeMode = 'GrowAndShrink'
$advancedLayout.Controls.Add($advancedBar, 0, 0)

$advancedBar.Controls.Add((New-GuiLabel -Text 'Filter'))
$AdvancedFilterBox = [Windows.Forms.TextBox]::new()
$AdvancedFilterBox.Width = 260
$advancedBar.Controls.Add($AdvancedFilterBox)
$AdvancedResetButton = New-GuiButton -Text 'Reset all to defaults' -Width 160
$advancedBar.Controls.Add($AdvancedResetButton)
$advancedBar.Controls.Add((New-GuiLabel -Text '  Values shown here are the file defaults; only what you change is saved to a profile.'))

$AdvancedTable = [Windows.Forms.TableLayoutPanel]::new()
$AdvancedTable.Dock = 'Fill'
$AdvancedTable.ColumnCount = 3
$AdvancedTable.AutoScroll = $true
$AdvancedTable.GrowStyle = 'AddRows'
[void]$AdvancedTable.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Absolute, 320))
[void]$AdvancedTable.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Absolute, 200))
[void]$AdvancedTable.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 100))
$advancedLayout.Controls.Add($AdvancedTable, 0, 1)

$script:AdvancedRows = @()

function Add-AdvancedSettingControl {
    $curated = @(Get-MTAutoDrawCuratedSettingName)
    $advanced = @($script:SettingDefinitions | Where-Object { $_.Name -notin $curated } | Sort-Object Name)

    $AdvancedTable.SuspendLayout()
    $rowIndex = 0
    foreach ($definition in $advanced) {
        $nameLabel = [Windows.Forms.Label]::new()
        $nameLabel.Text = $definition.Name
        $nameLabel.AutoSize = $true
        $nameLabel.Margin = [Windows.Forms.Padding]::new(3, 7, 3, 3)

        $editor = $null
        switch ($definition.Type) {
            'Bool' {
                $editor = [Windows.Forms.CheckBox]::new()
                $editor.Checked = [bool]$definition.Default
                $editor.AutoSize = $true
            }
            'Enum' {
                $editor = [Windows.Forms.ComboBox]::new()
                $editor.DropDownStyle = 'DropDownList'
                $editor.Width = 180
                [void]$editor.Items.AddRange([string[]]$definition.Options)
                $editor.SelectedItem = [string]$definition.Default
            }
            'Int' {
                $editor = [Windows.Forms.NumericUpDown]::new()
                $editor.Width = 120
                # Wide enough for any layout limit in the file without inviting a negative pixel count.
                $editor.Minimum = 0
                $editor.Maximum = 1000000
                $editor.Value = [decimal][int]$definition.Default
            }
            default {
                $editor = [Windows.Forms.TextBox]::new()
                $editor.Width = 180
                $editor.Text = [string]$definition.Default
            }
        }
        $editor.Margin = [Windows.Forms.Padding]::new(3, 4, 3, 3)
        $editor.Tag = $definition.Name

        $helpLabel = [Windows.Forms.Label]::new()
        $helpLabel.Text = $definition.Help
        $helpLabel.AutoSize = $false
        $helpLabel.Dock = 'Fill'
        $helpLabel.Height = 34
        $helpLabel.ForeColor = [Drawing.Color]::DimGray
        $helpLabel.Margin = [Windows.Forms.Padding]::new(3, 5, 3, 3)
        if ($definition.Help) {
            $helpTip = [Windows.Forms.ToolTip]::new()
            $helpTip.AutoPopDelay = 32000
            $helpTip.SetToolTip($helpLabel, $definition.Help)
        }

        $AdvancedTable.Controls.Add($nameLabel, 0, $rowIndex)
        $AdvancedTable.Controls.Add($editor, 1, $rowIndex)
        $AdvancedTable.Controls.Add($helpLabel, 2, $rowIndex)

        $script:SettingControls[$definition.Name] = $editor
        $script:AdvancedRows += [pscustomobject]@{
            Name = $definition.Name; NameLabel = $nameLabel; Editor = $editor; HelpLabel = $helpLabel
        }
        $rowIndex++
    }
    $AdvancedTable.ResumeLayout()
}

Add-AdvancedSettingControl

$AdvancedFilterBox.Add_TextChanged({
    $filter = $AdvancedFilterBox.Text.Trim()
    $AdvancedTable.SuspendLayout()
    foreach ($row in $script:AdvancedRows) {
        $visible = (-not $filter) -or ($row.Name -like "*$filter*") -or ($row.HelpLabel.Text -like "*$filter*")
        $row.NameLabel.Visible = $visible
        $row.Editor.Visible = $visible
        $row.HelpLabel.Visible = $visible
    }
    $AdvancedTable.ResumeLayout()
})

$AdvancedResetButton.Add_Click({
    foreach ($row in $script:AdvancedRows) { Set-SettingControlValue -Name $row.Name -Value $script:SettingDefaults[$row.Name] }
    Set-GuiStatus 'Advanced settings reset to the file defaults.'
})

# ================================================================================================
# Tab 3 - Log
# ================================================================================================
$TabLog = [Windows.Forms.TabPage]::new()
$TabLog.Text = 'Log'
$TabLog.Padding = [Windows.Forms.Padding]::new(8)
[void]$Tabs.TabPages.Add($TabLog)

$logLayout = [Windows.Forms.TableLayoutPanel]::new()
$logLayout.Dock = 'Fill'
$logLayout.ColumnCount = 1
$logLayout.RowCount = 3
[void]$logLayout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::AutoSize))
[void]$logLayout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::AutoSize))
[void]$logLayout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent, 100))
$TabLog.Controls.Add($logLayout)

# The seven phases as a strip, driven by the phase column of the log lines themselves.
$PhaseStrip = [Windows.Forms.FlowLayoutPanel]::new()
$PhaseStrip.Dock = 'Fill'
$PhaseStrip.AutoSize = $true
$PhaseStrip.AutoSizeMode = 'GrowAndShrink'
$logLayout.Controls.Add($PhaseStrip, 0, 0)

$script:PhaseLabels = @{}
foreach ($phase in (Get-MTAutoDrawPhaseOrder)) {
    $phaseLabel = [Windows.Forms.Label]::new()
    $phaseLabel.Text = $phase
    $phaseLabel.AutoSize = $false
    $phaseLabel.Width = 96
    $phaseLabel.Height = 26
    $phaseLabel.TextAlign = 'MiddleCenter'
    $phaseLabel.BorderStyle = 'FixedSingle'
    $phaseLabel.ForeColor = [Drawing.Color]::Gray
    $phaseLabel.Margin = [Windows.Forms.Padding]::new(2)
    $PhaseStrip.Controls.Add($phaseLabel)
    $script:PhaseLabels[$phase] = $phaseLabel
}

$logBar = [Windows.Forms.FlowLayoutPanel]::new()
$logBar.Dock = 'Fill'
$logBar.AutoSize = $true
$logBar.AutoSizeMode = 'GrowAndShrink'
$logLayout.Controls.Add($logBar, 0, 1)

$logBar.Controls.Add((New-GuiLabel -Text 'Show'))
$LogFilterCombo = [Windows.Forms.ComboBox]::new()
$LogFilterCombo.DropDownStyle = 'DropDownList'
$LogFilterCombo.Width = 130
[void]$LogFilterCombo.Items.AddRange(@('Everything', 'Info and above', 'Warnings and errors', 'Errors only'))
$LogFilterCombo.SelectedItem = 'Everything'
$logBar.Controls.Add($LogFilterCombo)
$LogClearButton = New-GuiButton -Text 'Clear' -Width 80
$logBar.Controls.Add($LogClearButton)
$LogCopyButton = New-GuiButton -Text 'Copy all' -Width 90
$logBar.Controls.Add($LogCopyButton)

$LogBox = [Windows.Forms.RichTextBox]::new()
$LogBox.Dock = 'Fill'
$LogBox.ReadOnly = $true
$LogBox.WordWrap = $false
$LogBox.Font = [Drawing.Font]::new('Consolas', 9)
$LogBox.BackColor = [Drawing.Color]::White
$logLayout.Controls.Add($LogBox, 0, 2)

$LogClearButton.Add_Click({ $LogBox.Clear() })
$LogCopyButton.Add_Click({
    if ($LogBox.TextLength -gt 0) {
        [Windows.Forms.Clipboard]::SetText($LogBox.Text)
        Set-GuiStatus 'Log copied to the clipboard.'
    }
})

# Levels are ranked so the filter can be a threshold rather than a set of checkboxes. Anything the
# parser does not recognise (native stderr, a bare Write-Host) is always shown - hiding output we
# could not classify is how a real error goes missing.
$script:LogLevelRank = @{ 'ERROR' = 0; 'WARN' = 1; 'INFO' = 2; 'DEBUG' = 3; 'TRACE' = 4; 'PERF' = 2 }

function Test-LogLineVisible {
    param([AllowNull()]$Parsed)

    if (-not $Parsed) { return $true }
    $rank = $script:LogLevelRank[$Parsed.Level.ToUpperInvariant()]
    if ($null -eq $rank) { return $true }
    switch ($LogFilterCombo.SelectedItem) {
        'Errors only'         { return ($rank -le 0) }
        'Warnings and errors' { return ($rank -le 1) }
        'Info and above'      { return ($rank -le 2) }
        default               { return $true }
    }
}

function Get-LogLineColor {
    param([AllowNull()]$Parsed)

    if (-not $Parsed) { return [Drawing.Color]::FromArgb(120, 40, 140) }
    switch ($Parsed.Level.ToUpperInvariant()) {
        'ERROR' { return [Drawing.Color]::Firebrick }
        'WARN'  { return [Drawing.Color]::DarkGoldenrod }
        'INFO'  { return [Drawing.Color]::Black }
        'DEBUG' { return [Drawing.Color]::DimGray }
        'TRACE' { return [Drawing.Color]::Silver }
        'PERF'  { return [Drawing.Color]::Teal }
        'PASS'  { return [Drawing.Color]::ForestGreen }
        'FAIL'  { return [Drawing.Color]::Firebrick }
        default { return [Drawing.Color]::Black }
    }
}

function Add-LogLine {
    param([string]$Line)

    $parsed = ConvertFrom-MTAutoDrawLogLine -Line $Line
    # Format-MTAutoDrawLogLine lowercases the phase column; a PowerShell hashtable lookup is
    # case-insensitive, so 'parse' finds the 'Parse' label without any normalising here. A phase the
    # strip does not carry - a perf line, say - simply moves nothing.
    if ($parsed -and $script:PhaseLabels.ContainsKey($parsed.Phase)) {
        $label = $script:PhaseLabels[$parsed.Phase]
        $label.ForeColor = [Drawing.Color]::Black
        $label.Font = [Drawing.Font]::new('Segoe UI', 9, [Drawing.FontStyle]::Bold)
    }

    if (-not (Test-LogLineVisible -Parsed $parsed)) { return }

    $LogBox.SelectionStart = $LogBox.TextLength
    $LogBox.SelectionLength = 0
    $LogBox.SelectionColor = Get-LogLineColor -Parsed $parsed
    $LogBox.AppendText($Line + [Environment]::NewLine)
    $LogBox.SelectionColor = $LogBox.ForeColor
}

function Reset-PhaseStrip {
    foreach ($phaseName in @($script:PhaseLabels.Keys)) {
        $script:PhaseLabels[$phaseName].ForeColor = [Drawing.Color]::Gray
        $script:PhaseLabels[$phaseName].Font = [Drawing.Font]::new('Segoe UI', 9, [Drawing.FontStyle]::Regular)
    }
}

# ================================================================================================
# Tab 4 - Results
# ================================================================================================
$TabResults = [Windows.Forms.TabPage]::new()
$TabResults.Text = 'Results'
$TabResults.Padding = [Windows.Forms.Padding]::new(8)
[void]$Tabs.TabPages.Add($TabResults)

$resultsLayout = [Windows.Forms.TableLayoutPanel]::new()
$resultsLayout.Dock = 'Fill'
$resultsLayout.ColumnCount = 1
$resultsLayout.RowCount = 4
[void]$resultsLayout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::AutoSize))
[void]$resultsLayout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent, 30))
[void]$resultsLayout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent, 35))
[void]$resultsLayout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent, 35))
$TabResults.Controls.Add($resultsLayout)

$VerdictLabel = [Windows.Forms.Label]::new()
$VerdictLabel.Text = 'No run yet.'
$VerdictLabel.AutoSize = $true
$VerdictLabel.Font = [Drawing.Font]::new('Segoe UI', 12, [Drawing.FontStyle]::Bold)
$resultsLayout.Controls.Add($VerdictLabel, 0, 0)

function New-ResultsListView {
    param([string[]]$Columns, [int[]]$Widths)

    $view = [Windows.Forms.ListView]::new()
    $view.Dock = 'Fill'
    $view.View = 'Details'
    $view.FullRowSelect = $true
    $view.GridLines = $true
    for ($i = 0; $i -lt $Columns.Count; $i++) { [void]$view.Columns.Add($Columns[$i], $Widths[$i]) }
    return $view
}

$CountsView = New-ResultsListView -Columns @('Count', 'Value') -Widths @(320, 120)
$countsGroup = [Windows.Forms.GroupBox]::new()
$countsGroup.Text = 'Run counts'
$countsGroup.Dock = 'Fill'
$countsGroup.Controls.Add($CountsView)
$resultsLayout.Controls.Add($countsGroup, 0, 1)

$ProblemsView = New-ResultsListView -Columns @('Kind', 'Where', 'Detail') -Widths @(140, 220, 700)
$problemsGroup = [Windows.Forms.GroupBox]::new()
$problemsGroup.Text = 'Problems'
$problemsGroup.Dock = 'Fill'
$problemsGroup.Controls.Add($ProblemsView)
$resultsLayout.Controls.Add($problemsGroup, 0, 2)

$artifactsGroup = [Windows.Forms.GroupBox]::new()
$artifactsGroup.Text = 'Files produced'
$artifactsGroup.Dock = 'Fill'
$artifactsLayout = [Windows.Forms.TableLayoutPanel]::new()
$artifactsLayout.Dock = 'Fill'
$artifactsLayout.ColumnCount = 1
$artifactsLayout.RowCount = 2
[void]$artifactsLayout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent, 100))
[void]$artifactsLayout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::AutoSize))
$artifactsGroup.Controls.Add($artifactsLayout)
$resultsLayout.Controls.Add($artifactsGroup, 0, 3)

$ArtifactsView = New-ResultsListView -Columns @('File', 'Size') -Widths @(820, 100)
$artifactsLayout.Controls.Add($ArtifactsView, 0, 0)

$artifactsBar = [Windows.Forms.FlowLayoutPanel]::new()
$artifactsBar.Dock = 'Fill'
$artifactsBar.AutoSize = $true
$artifactsBar.AutoSizeMode = 'GrowAndShrink'
$artifactsLayout.Controls.Add($artifactsBar, 0, 1)

$OpenFileButton = New-GuiButton -Text 'Open' -Width 90
$OpenFolderButton = New-GuiButton -Text 'Open folder' -Width 110
$artifactsBar.Controls.Add($OpenFileButton)
$artifactsBar.Controls.Add($OpenFolderButton)

function Get-SelectedArtifactPath {
    if ($ArtifactsView.SelectedItems.Count -eq 0) { return $null }
    return [string]$ArtifactsView.SelectedItems[0].Tag
}

$OpenFileButton.Add_Click({
    $path = Get-SelectedArtifactPath
    if (-not $path) { Set-GuiStatus 'Select a file first.'; return }
    if (-not (Test-Path -LiteralPath $path)) { Set-GuiStatus "No longer on disk: $path"; return }
    Start-Process -FilePath $path
})
$OpenFolderButton.Add_Click({
    $path = Get-SelectedArtifactPath
    $target = if ($path) { Split-Path -Parent $path } else { $script:RunOutputPath }
    if (-not $target -or -not (Test-Path -LiteralPath $target)) { Set-GuiStatus 'No folder to open yet.'; return }
    # Quoted: an output path with a space in it is the normal case, not the exception.
    Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $target)
})
$ArtifactsView.Add_DoubleClick({ $OpenFileButton.PerformClick() })

# ================================================================================================
# Tab 5 - Setup
# ================================================================================================
$TabSetup = [Windows.Forms.TabPage]::new()
$TabSetup.Text = 'Setup'
$TabSetup.Padding = [Windows.Forms.Padding]::new(8)
[void]$Tabs.TabPages.Add($TabSetup)

$setupLayout = [Windows.Forms.TableLayoutPanel]::new()
$setupLayout.Dock = 'Fill'
$setupLayout.ColumnCount = 1
$setupLayout.RowCount = 4
[void]$setupLayout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::AutoSize))
[void]$setupLayout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent, 100))
[void]$setupLayout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::AutoSize))
[void]$setupLayout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, 150))
$TabSetup.Controls.Add($setupLayout)

$setupIntro = [Windows.Forms.Label]::new()
$setupIntro.Text = 'MTAutoDraw needs PowerShell 7, a Python interpreter with the textfsm package, and the tracked TextFSM templates. The interpreter is not in the repository, so a fresh clone will show it as missing.'
$setupIntro.AutoSize = $false
$setupIntro.Height = 34
$setupIntro.Dock = 'Fill'
$setupLayout.Controls.Add($setupIntro, 0, 0)

$PreflightView = New-ResultsListView -Columns @('Check', 'Status', 'Detail', 'How to fix') -Widths @(200, 70, 420, 480)
$setupLayout.Controls.Add($PreflightView, 0, 1)

$setupBar = [Windows.Forms.FlowLayoutPanel]::new()
$setupBar.Dock = 'Fill'
$setupBar.AutoSize = $true
$setupBar.AutoSizeMode = 'GrowAndShrink'
$setupLayout.Controls.Add($setupBar, 0, 2)

$RecheckButton = New-GuiButton -Text 'Re-check' -Width 100
$BrowsePythonButton = New-GuiButton -Text 'Use my own python.exe...' -Width 190
$SetupPythonButton = New-GuiButton -Text 'Set up Python' -Width 130
$setupBar.Controls.Add($RecheckButton)
$setupBar.Controls.Add($BrowsePythonButton)
$setupBar.Controls.Add($SetupPythonButton)

$SetupLogBox = [Windows.Forms.TextBox]::new()
$SetupLogBox.Multiline = $true
$SetupLogBox.ReadOnly = $true
$SetupLogBox.ScrollBars = 'Vertical'
$SetupLogBox.Dock = 'Fill'
$SetupLogBox.Font = [Drawing.Font]::new('Consolas', 9)
$setupLayout.Controls.Add($SetupLogBox, 0, 3)

function Add-SetupLog {
    param([string]$Text)
    $SetupLogBox.AppendText($Text + [Environment]::NewLine)
}

function Update-Preflight {
    Set-GuiStatus 'Checking prerequisites...'
    $PreflightView.BeginUpdate()
    $PreflightView.Items.Clear()
    $script:PreflightResults = @(Get-MTAutoDrawPreflight -PythonPath $script:PythonPath -OutputDirectory $OutputBox.Text)
    foreach ($result in $script:PreflightResults) {
        $item = [Windows.Forms.ListViewItem]::new($result.Check)
        [void]$item.SubItems.Add($result.Status)
        [void]$item.SubItems.Add($result.Detail)
        [void]$item.SubItems.Add($result.Fix)
        $item.ForeColor = switch ($result.Status) {
            'Pass'  { [Drawing.Color]::ForestGreen }
            'Fail'  { [Drawing.Color]::Firebrick }
            default { [Drawing.Color]::DimGray }
        }
        [void]$PreflightView.Items.Add($item)
    }
    $PreflightView.EndUpdate()

    $failures = @($script:PreflightResults | Where-Object Status -eq 'Fail').Count
    if ($failures -eq 0) { Set-GuiStatus 'Prerequisites are satisfied.' }
    else { Set-GuiStatus "$failures prerequisite check(s) failing - see the Setup tab." }
    return $failures
}

$RecheckButton.Add_Click({ [void](Update-Preflight) })

$BrowsePythonButton.Add_Click({
    $dialog = [Windows.Forms.OpenFileDialog]::new()
    $dialog.Title = 'Select python.exe'
    $dialog.Filter = 'python.exe|python.exe|Executables (*.exe)|*.exe'
    if ($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) {
        $script:PythonPath = $dialog.FileName
        Add-SetupLog "Using interpreter: $($script:PythonPath)"
        [void](Update-Preflight)
    }
    $dialog.Dispose()
})

# The guided fix. Runs in a background job so the window stays alive during the download, polled by
# its own timer. Every download is confirmed first, by name, URL and size - this is the only part of
# the GUI that reaches the internet, and it writes into the repository's gitignored python\ folder.
$SetupTimer = [Windows.Forms.Timer]::new()
$SetupTimer.Interval = 250

$SetupPythonButton.Add_Click({
    $plan = Get-MTAutoDrawPythonDownloadPlan
    $pythonDirectory = Join-Path (Get-MTAutoDrawRepositoryRoot) 'python'

    $message = @(
        'Set up a self-contained Python interpreter for MTAutoDraw?'
        ''
        "This downloads two files from the internet:"
        "  1. $($plan.PythonFileName)  ($($plan.ApproximateSize))"
        "     $($plan.PythonUrl)"
        "  2. $($plan.GetPipFileName)"
        "     $($plan.GetPipUrl)"
        ''
        "They are expanded into:"
        "  $pythonDirectory"
        ''
        'Then textfsm is installed into that interpreter with pip.'
        'Nothing outside that folder is modified.'
    ) -join [Environment]::NewLine

    $answer = [Windows.Forms.MessageBox]::Show($message, 'Set up Python', 'YesNo', 'Question')
    if ($answer -ne [Windows.Forms.DialogResult]::Yes) {
        Add-SetupLog 'Set up Python: declined. Nothing was downloaded and nothing was changed.'
        return
    }

    if (Test-Path -LiteralPath (Join-Path $pythonDirectory 'python.exe')) {
        $overwrite = [Windows.Forms.MessageBox]::Show(
            "An interpreter already exists at:`n$pythonDirectory`n`nOverwrite it?",
            'Set up Python', 'YesNo', 'Warning')
        if ($overwrite -ne [Windows.Forms.DialogResult]::Yes) {
            Add-SetupLog 'Set up Python: cancelled, the existing interpreter was left alone.'
            return
        }
    }

    $SetupPythonButton.Enabled = $false
    $BrowsePythonButton.Enabled = $false
    $RecheckButton.Enabled = $false
    Add-SetupLog "Starting setup of Python $($plan.Version)..."
    Set-GuiStatus 'Setting up Python...'

    $script:SetupJob = Start-Job -ScriptBlock {
        param($Plan, $PythonDirectory, $GuiSettingsPath)

        . $GuiSettingsPath
        $ErrorActionPreference = 'Stop'
        $staging = Join-Path ([System.IO.Path]::GetTempPath()) ("mtautodraw-python-" + [Guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $staging -Force
        try {
            $archive = Join-Path $staging $Plan.PythonFileName
            "Downloading $($Plan.PythonUrl)"
            Invoke-WebRequest -Uri $Plan.PythonUrl -OutFile $archive -UseBasicParsing
            "Downloaded $([Math]::Round((Get-Item -LiteralPath $archive).Length / 1MB, 1)) MB"

            "Expanding into $PythonDirectory"
            $pythonExe = Expand-MTAutoDrawPython -ArchivePath $archive -DestinationDirectory $PythonDirectory
            "Interpreter: $pythonExe"

            $getPip = Join-Path $staging $Plan.GetPipFileName
            "Downloading $($Plan.GetPipUrl)"
            Invoke-WebRequest -Uri $Plan.GetPipUrl -OutFile $getPip -UseBasicParsing

            "Bootstrapping pip"
            & $pythonExe $getPip '--no-warn-script-location' 2>&1 | ForEach-Object { "  $_" }

            "Installing textfsm"
            & $pythonExe '-m' 'pip' 'install' 'textfsm' '--no-warn-script-location' 2>&1 | ForEach-Object { "  $_" }

            "DONE"
        }
        finally {
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        }
    } -ArgumentList $plan, $pythonDirectory, (Join-Path $script:RepoRoot 'GuiSettings.ps1')

    $SetupTimer.Start()
})

$SetupTimer.Add_Tick({
    if (-not $script:SetupJob) { $SetupTimer.Stop(); return }

    foreach ($line in @(Receive-Job -Job $script:SetupJob -ErrorAction SilentlyContinue)) {
        Add-SetupLog ([string]$line)
    }

    if ($script:SetupJob.State -in @('Completed', 'Failed', 'Stopped')) {
        $SetupTimer.Stop()
        foreach ($line in @(Receive-Job -Job $script:SetupJob -ErrorAction SilentlyContinue)) { Add-SetupLog ([string]$line) }
        if ($script:SetupJob.State -eq 'Failed') {
            foreach ($reason in @($script:SetupJob.ChildJobs.JobStateInfo.Reason)) {
                if ($reason) { Add-SetupLog "FAILED: $($reason.Message)" }
            }
        }
        Remove-Job -Job $script:SetupJob -Force -ErrorAction SilentlyContinue
        $script:SetupJob = $null

        $script:PythonPath = Get-MTAutoDrawDefaultPythonPath
        $SetupPythonButton.Enabled = $true
        $BrowsePythonButton.Enabled = $true
        $RecheckButton.Enabled = $true
        [void](Update-Preflight)
    }
})

# ================================================================================================
# Settings <-> controls
# ================================================================================================
function Get-SettingControlValue {
    param([Parameter(Mandatory = $true)][string]$Name)

    $control = $script:SettingControls[$Name]
    if (-not $control) { return $null }
    if ($control -is [Windows.Forms.CheckBox]) { return [bool]$control.Checked }
    if ($control -is [Windows.Forms.NumericUpDown]) { return [int]$control.Value }
    if ($control -is [Windows.Forms.ComboBox]) { return [string]$control.SelectedItem }
    return [string]$control.Text
}

function Set-SettingControlValue {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()]$Value
    )

    $control = $script:SettingControls[$Name]
    if (-not $control -or $null -eq $Value) { return }
    if ($control -is [Windows.Forms.CheckBox]) { $control.Checked = [bool]$Value; return }
    if ($control -is [Windows.Forms.NumericUpDown]) {
        $number = 0
        if ([int]::TryParse([string]$Value, [ref]$number)) {
            if ($number -lt $control.Minimum) { $number = [int]$control.Minimum }
            if ($number -gt $control.Maximum) { $number = [int]$control.Maximum }
            $control.Value = [decimal]$number
        }
        return
    }
    if ($control -is [Windows.Forms.ComboBox]) { $control.SelectedItem = [string]$Value; return }
    $control.Text = [string]$Value
}

# Everything the controls currently say, as a name -> value map.
function Get-AllSettingValue {
    $values = @{}
    foreach ($definition in $script:SettingDefinitions) {
        $value = Get-SettingControlValue -Name $definition.Name
        if ($null -ne $value) { $values[$definition.Name] = $value }
    }
    return $values
}

# ================================================================================================
# Profiles
# ================================================================================================
function Update-ProfileList {
    param([string]$Select)

    $ProfileCombo.Items.Clear()
    foreach ($name in (Get-MTAutoDrawProfileName)) { [void]$ProfileCombo.Items.Add($name) }
    if ($Select -and $ProfileCombo.Items.Contains($Select)) { $ProfileCombo.SelectedItem = $Select }
}

$ProfileSaveButton.Add_Click({
    $suggested = if ($ProfileCombo.SelectedItem) { [string]$ProfileCombo.SelectedItem } else { 'My site' }
    $name = [Microsoft.VisualBasic.Interaction]::InputBox('Save these settings as:', 'Save profile', $suggested)
    if (-not $name) { return }

    $changed = Get-MTAutoDrawChangedSetting -Definitions $script:SettingDefinitions -Values (Get-AllSettingValue)
    $profileData = New-MTAutoDrawProfile -Name $name -InputDirectory $InputBox.Text -OutputDirectory $OutputBox.Text `
        -LogLevel ([string]$LogLevelCombo.SelectedItem) -Settings $changed
    try {
        $path = Save-MTAutoDrawProfile -ProfileData $profileData -Name $name
        Update-ProfileList -Select $name
        Set-GuiStatus "Saved profile '$name' ($($changed.Count) setting(s) differ from the defaults) -> $path"
    }
    catch {
        [void][Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Save profile', 'OK', 'Error')
    }
})

$ProfileLoadButton.Add_Click({
    if (-not $ProfileCombo.SelectedItem) { Set-GuiStatus 'Pick a profile to load.'; return }
    $name = [string]$ProfileCombo.SelectedItem
    try {
        $profileData = Read-MTAutoDrawProfile -Name $name
    }
    catch {
        [void][Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Load profile', 'OK', 'Error')
        return
    }

    # Start from the file defaults so a profile that no longer mentions a setting returns it to its
    # default rather than leaving whatever the previous profile put there.
    foreach ($definition in $script:SettingDefinitions) { Set-SettingControlValue -Name $definition.Name -Value $definition.Default }
    foreach ($key in $profileData.Settings.Keys) { Set-SettingControlValue -Name $key -Value $profileData.Settings[$key] }

    if ($profileData.InputDirectory) { $InputBox.Text = $profileData.InputDirectory }
    if ($profileData.OutputDirectory) { $OutputBox.Text = $profileData.OutputDirectory }
    if ($profileData.LogLevel) { $LogLevelCombo.SelectedItem = $profileData.LogLevel }
    Update-MasterGating
    Set-GuiStatus "Loaded profile '$name' ($($profileData.Settings.Count) setting(s) differ from the defaults)."
})

$ProfileDeleteButton.Add_Click({
    if (-not $ProfileCombo.SelectedItem) { Set-GuiStatus 'Pick a profile to delete.'; return }
    $name = [string]$ProfileCombo.SelectedItem
    $answer = [Windows.Forms.MessageBox]::Show("Delete the profile '$name'?", 'Delete profile', 'YesNo', 'Warning')
    if ($answer -ne [Windows.Forms.DialogResult]::Yes) { return }
    Remove-MTAutoDrawProfile -Name $name
    Update-ProfileList
    Set-GuiStatus "Deleted profile '$name'."
})

# ================================================================================================
# Running the pipeline
# ================================================================================================
$RunTimer = [Windows.Forms.Timer]::new()
$RunTimer.Interval = 100

# ------------------------------------------------------------------------------------------------
# Reading the child's output
#
# NOT Register-ObjectEvent/BeginOutputReadLine, which is what this first used and which does not
# work here. A PowerShell -Action handler only runs when the engine is idle, and ShowDialog()
# occupies the runspace inside a single statement for the entire life of the window. Measured on an
# 11-second run, the eventing version delivered 0 lines while the window was open and all 66 the
# moment it closed - a Log tab that sits empty while the run is plainly working.
#
# Worth knowing when testing this: a DoEvents pump does NOT reproduce the failure. Looping on
# DoEvents returns to the engine between pumps, so it goes idle and the eventing version appears to
# work. Only a real ShowDialog shows the bug, which is why -SelfTestRun uses one.
#
# Instead each stream is read with plain .NET ReadAsync, and the timer below polls the resulting
# Task. No PowerShell eventing is involved, so nothing depends on the engine being free.
# ------------------------------------------------------------------------------------------------
function New-StreamPump {
    param([Parameter(Mandatory = $true)]$Stream)

    return [pscustomobject]@{
        Stream  = $Stream
        Buffer  = [byte[]]::new(65536)
        # A Decoder, not Encoding.GetString: a UTF-8 character can straddle two reads, and the
        # decoder is the thing that remembers the leading bytes across the boundary.
        Decoder = [System.Text.Encoding]::UTF8.GetDecoder()
        Task    = $null
        Partial = ''
        Done    = $false
    }
}

# Returns whatever complete lines have arrived since the last call. Never blocks: if the pending
# read has not completed, it returns nothing and leaves the task running.
function Read-StreamPump {
    param([Parameter(Mandatory = $true)]$Pump)

    $lines = [System.Collections.Generic.List[string]]::new()
    if ($Pump.Done) { return $lines }

    if ($null -eq $Pump.Task) {
        $Pump.Task = $Pump.Stream.ReadAsync($Pump.Buffer, 0, $Pump.Buffer.Length)
    }

    while ($Pump.Task -and $Pump.Task.IsCompleted) {
        $count = 0
        try { $count = $Pump.Task.Result }
        catch { $Pump.Done = $true; break }   # the pipe closed under us; the exit check reports it

        if ($count -le 0) {
            # End of stream. Whatever is left has no trailing newline but is still a line.
            $Pump.Done = $true
            if ($Pump.Partial) { $lines.Add($Pump.Partial); $Pump.Partial = '' }
            break
        }

        $chars = [char[]]::new($count)
        $charCount = $Pump.Decoder.GetChars($Pump.Buffer, 0, $count, $chars, 0)
        $Pump.Partial += [string]::new($chars, 0, $charCount)

        $index = $Pump.Partial.IndexOf("`n")
        while ($index -ge 0) {
            $lines.Add($Pump.Partial.Substring(0, $index).TrimEnd([char]13))
            $Pump.Partial = $Pump.Partial.Substring($index + 1)
            $index = $Pump.Partial.IndexOf("`n")
        }

        $Pump.Task = $Pump.Stream.ReadAsync($Pump.Buffer, 0, $Pump.Buffer.Length)
    }

    return $lines
}

function Get-PwshPath {
    # The interpreter running this window, so a child run is the same build. Falls back to the PATH.
    $current = (Get-Process -Id $PID).Path
    if ($current -and (Test-Path -LiteralPath $current)) { return $current }
    return 'pwsh'
}

function Set-RunUiState {
    param([bool]$Running)

    $RunButton.Enabled = -not $Running
    $CancelButton.Enabled = $Running
    $InputBox.Enabled = -not $Running
    $OutputBox.Enabled = -not $Running
    $ProfileLoadButton.Enabled = -not $Running
    $ProfileSaveButton.Enabled = -not $Running
    $ProfileDeleteButton.Enabled = -not $Running
    $SetupPythonButton.Enabled = -not $Running
}

# The Run button's work, as a function rather than a scriptblock, so -SelfTestRun can start a run
# without a visible window. Button.PerformClick() is a no-op on a control that has never been shown -
# CanSelect is false - so a self-test that clicked the button would silently do nothing.
function Start-PipelineRun {
    param(
        # No dialogs: fail by returning $false and saying why, so an automated run cannot hang on a
        # modal box nobody is there to answer.
        [switch]$Unattended
    )

    if (-not $InputBox.Text -or -not (Test-Path -LiteralPath $InputBox.Text -PathType Container)) {
        if ($Unattended) { Write-Host 'Run refused: the capture folder does not exist.'; return $false }
        [void][Windows.Forms.MessageBox]::Show('Choose a capture folder that exists.', 'Run', 'OK', 'Warning')
        return $false
    }
    if (-not $OutputBox.Text) {
        if ($Unattended) { Write-Host 'Run refused: no output folder.'; return $false }
        [void][Windows.Forms.MessageBox]::Show('Choose an output folder.', 'Run', 'OK', 'Warning')
        return $false
    }

    $failures = Update-Preflight
    if ($failures -gt 0) {
        if ($Unattended) { Write-Host "Run refused: $failures prerequisite check(s) failing."; return $false }
        $answer = [Windows.Forms.MessageBox]::Show(
            "$failures prerequisite check(s) are failing. The run will almost certainly stop early.`n`nOpen the Setup tab instead?",
            'Prerequisites', 'YesNo', 'Warning')
        if ($answer -eq [Windows.Forms.DialogResult]::Yes) { $Tabs.SelectedTab = $TabSetup; return $false }
    }

    # Only what differs from the file defaults, plus the interpreter when the user chose their own.
    $changed = Get-MTAutoDrawChangedSetting -Definitions $script:SettingDefinitions -Values (Get-AllSettingValue)
    if ($script:PythonPath -ne (Get-MTAutoDrawDefaultPythonPath)) { $changed['GPathToPythonExe'] = $script:PythonPath }

    $dataRoot = Get-MTAutoDrawGuiDataRoot
    if (-not (Test-Path -LiteralPath $dataRoot)) { $null = New-Item -ItemType Directory -Path $dataRoot -Force }
    $settingsPath = Write-MTAutoDrawSettingsFile -Settings $changed -Path (Join-Path $dataRoot 'last-run-settings.json')

    $script:RunOutputPath = $OutputBox.Text
    $script:RunCancelled = $false
    $LogBox.Clear()
    Reset-PhaseStrip
    $Tabs.SelectedTab = $TabLog

    $arguments = [System.Collections.Generic.List[string]]::new()
    $arguments.Add('-NoProfile')
    $arguments.Add('-File')
    $arguments.Add((Join-Path $script:RepoRoot 'AutoDraw.ps1'))
    $arguments.Add('-GDirectory');        $arguments.Add($InputBox.Text)
    $arguments.Add('-GOutPutDirectory');  $arguments.Add($OutputBox.Text)
    $arguments.Add('-GPathToScript');     $arguments.Add($script:RepoRoot)
    $arguments.Add('-LogLevel');          $arguments.Add([string]$LogLevelCombo.SelectedItem)
    if ($changed.Count -gt 0) { $arguments.Add('-SettingsPath'); $arguments.Add($settingsPath) }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Get-PwshPath
    foreach ($argument in $arguments) { $startInfo.ArgumentList.Add($argument) }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $startInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $startInfo.WorkingDirectory = $script:RepoRoot

    $script:RunProcess = [System.Diagnostics.Process]::new()
    $script:RunProcess.StartInfo = $startInfo
    $script:RunDrainPasses = 0

    Set-RunUiState -Running $true
    Set-GuiStatus 'Running...'
    [void]$script:RunProcess.Start()

    # Created after Start: the redirected streams do not exist until the process does.
    $script:RunPumps = @(
        New-StreamPump -Stream $script:RunProcess.StandardOutput.BaseStream
        New-StreamPump -Stream $script:RunProcess.StandardError.BaseStream
    )
    $RunTimer.Start()
    return $true
}

$RunButton.Add_Click({ [void](Start-PipelineRun) })

$CancelButton.Add_Click({
    if (-not $script:RunProcess -or $script:RunProcess.HasExited) { return }
    $script:RunCancelled = $true
    try {
        # The tree, not just pwsh: a run spawns python.exe children for every TextFSM parse.
        $script:RunProcess.Kill($true)
        Set-GuiStatus 'Cancelling...'
    }
    catch { Set-GuiStatus "Could not cancel: $($_.Exception.Message)" }
})

# The only place run output reaches a control. Drains in batches so a chatty run does not repaint
# per line, and never calls WaitForExit - the same tick notices the process is gone.
$RunTimer.Add_Tick({
    if (-not $script:RunProcess) { return }

    $batch = [System.Collections.Generic.List[string]]::new()
    foreach ($pump in $script:RunPumps) {
        foreach ($line in (Read-StreamPump -Pump $pump)) { $batch.Add($line) }
    }

    if ($batch.Count -gt 0) {
        $script:RunDrainPasses++
        if (-not $script:RunFirstLineAt) { $script:RunFirstLineAt = [DateTime]::UtcNow }
        $LogBox.SuspendLayout()
        foreach ($entry in $batch) { Add-LogLine -Line $entry }
        $LogBox.ResumeLayout()
        $LogBox.SelectionStart = $LogBox.TextLength
        $LogBox.ScrollToCaret()
    }

    # Both streams at end AND the process gone: draining first means the tail of a fast run is not
    # lost to an early exit check.
    $pumpsDone = @($script:RunPumps | Where-Object { -not $_.Done }).Count -eq 0
    if ($script:RunProcess.HasExited -and $pumpsDone) {
        $RunTimer.Stop()
        Complete-Run
    }
})

function Complete-Run {
    $exitCode = $script:RunProcess.ExitCode

    $script:RunPumps = @()
    $script:RunProcess.Dispose()
    $script:RunProcess = $null

    Set-RunUiState -Running $false

    if ($script:RunCancelled) {
        Set-GuiStatus 'Run cancelled.'
        $VerdictLabel.Text = 'Cancelled'
        $VerdictLabel.ForeColor = [Drawing.Color]::DimGray
        Add-LogLine -Line '--- cancelled by the user ---'
        return
    }

    Show-RunSummary -ExitCode $exitCode
    $Tabs.SelectedTab = $TabResults
}

# Everything on the Results tab comes from RunSummary.json, which the pipeline writes on every run,
# including a failed one. A missing file is itself the finding: the run stopped before the pipeline
# could speak, and the exit code is all there is.
function Show-RunSummary {
    param([int]$ExitCode)

    $CountsView.Items.Clear()
    $ProblemsView.Items.Clear()
    $ArtifactsView.Items.Clear()

    $summaryPath = Join-Path $script:RunOutputPath 'RunSummary.json'
    if (-not (Test-Path -LiteralPath $summaryPath)) {
        $VerdictLabel.Text = "Failed before the run could report (exit $ExitCode)"
        $VerdictLabel.ForeColor = [Drawing.Color]::Firebrick
        Set-GuiStatus "No RunSummary.json in $($script:RunOutputPath) - see the Log tab."
        return
    }

    $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json

    $VerdictLabel.Text = "$($summary.Verdict)  -  exit $($summary.ExitCode)  -  $($summary.Counts.ProcessedDevices) device(s)"
    $VerdictLabel.ForeColor = switch ($summary.Verdict) {
        'Pass'  { [Drawing.Color]::ForestGreen }
        'Warn'  { [Drawing.Color]::DarkGoldenrod }
        default { [Drawing.Color]::Firebrick }
    }

    foreach ($property in $summary.Counts.PSObject.Properties) {
        $item = [Windows.Forms.ListViewItem]::new($property.Name)
        [void]$item.SubItems.Add([string]$property.Value)
        [void]$CountsView.Items.Add($item)
    }

    if ($summary.FatalError) {
        $item = [Windows.Forms.ListViewItem]::new('Fatal')
        [void]$item.SubItems.Add('')
        [void]$item.SubItems.Add([string]$summary.FatalError)
        $item.ForeColor = [Drawing.Color]::Firebrick
        [void]$ProblemsView.Items.Add($item)
    }
    foreach ($processingError in @($summary.ProcessingErrors)) {
        if (-not $processingError) { continue }
        $item = [Windows.Forms.ListViewItem]::new([string]$processingError.Parser)
        [void]$item.SubItems.Add([string]$processingError.HostID)
        [void]$item.SubItems.Add([string]$processingError.Message)
        $item.ForeColor = [Drawing.Color]::Firebrick
        [void]$ProblemsView.Items.Add($item)
    }
    foreach ($unsupported in @($summary.UnsupportedGroups)) {
        if (-not $unsupported) { continue }
        $item = [Windows.Forms.ListViewItem]::new('Unsupported')
        [void]$item.SubItems.Add([string]$unsupported.HOSTID)
        [void]$item.SubItems.Add("No parser matched this capture group")
        $item.ForeColor = [Drawing.Color]::DarkGoldenrod
        [void]$ProblemsView.Items.Add($item)
    }
    if ($ProblemsView.Items.Count -eq 0) {
        [void]$ProblemsView.Items.Add([Windows.Forms.ListViewItem]::new('Nothing reported'))
    }

    foreach ($artifact in @($summary.Artifacts)) {
        if (-not $artifact) { continue }
        $item = [Windows.Forms.ListViewItem]::new([System.IO.Path]::GetFileName($artifact))
        $size = if (Test-Path -LiteralPath $artifact) {
            '{0:N1} KB' -f ((Get-Item -LiteralPath $artifact).Length / 1KB)
        } else { 'missing' }
        [void]$item.SubItems.Add($size)
        $item.Tag = $artifact
        # The diagrams are what the user came for, so they are the ones that stand out.
        if ($artifact -like '*.drawio') { $item.Font = [Drawing.Font]::new('Segoe UI', 9, [Drawing.FontStyle]::Bold) }
        [void]$ArtifactsView.Items.Add($item)
    }

    Set-GuiStatus "Run finished: $($summary.Verdict) (exit $($summary.ExitCode))."
}

# ================================================================================================
# Window state, and start
# ================================================================================================
function Save-GuiState {
    try {
        $dataRoot = Get-MTAutoDrawGuiDataRoot
        if (-not (Test-Path -LiteralPath $dataRoot)) { $null = New-Item -ItemType Directory -Path $dataRoot -Force }
        [ordered]@{
            InputDirectory  = $InputBox.Text
            OutputDirectory = $OutputBox.Text
            LogLevel        = [string]$LogLevelCombo.SelectedItem
            PythonPath      = $script:PythonPath
            Width           = $Form.Width
            Height          = $Form.Height
        } | ConvertTo-Json | Set-Content -LiteralPath (Get-MTAutoDrawGuiStatePath) -Encoding utf8
    }
    catch { }   # Losing window state is never worth blocking a close over.
}

function Restore-GuiState {
    try {
        $statePath = Get-MTAutoDrawGuiStatePath
        if (-not (Test-Path -LiteralPath $statePath)) { return }
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        if ($state.InputDirectory) { $InputBox.Text = [string]$state.InputDirectory }
        if ($state.OutputDirectory) { $OutputBox.Text = [string]$state.OutputDirectory }
        if ($state.LogLevel) { $LogLevelCombo.SelectedItem = [string]$state.LogLevel }
        if ($state.PythonPath) { $script:PythonPath = [string]$state.PythonPath }
        if ($state.Width -and $state.Height) {
            $Form.Size = [Drawing.Size]::new([int]$state.Width, [int]$state.Height)
        }
    }
    catch { }
}

$Form.Add_FormClosing({
    param($sender, $eventArgs)
    if ($script:RunProcess -and -not $script:RunProcess.HasExited) {
        $answer = [Windows.Forms.MessageBox]::Show('A run is still going. Stop it and close?', 'MTAutoDraw', 'YesNo', 'Warning')
        if ($answer -ne [Windows.Forms.DialogResult]::Yes) { $eventArgs.Cancel = $true; return }
        try { $script:RunProcess.Kill($true) } catch { }
    }
    Save-GuiState
})

$Form.Add_Shown({
    Restore-GuiState
    Update-ProfileList
    Update-MasterGating
    [void](Update-Preflight)
})

# InputBox lives in Microsoft.VisualBasic - loaded here rather than at the top because it is only
# needed when a profile is saved, and a missing assembly should not stop the window from opening.
try { Add-Type -AssemblyName Microsoft.VisualBasic } catch { }

if ($SelfTest) {
    # The same startup work Add_Shown does, run directly - that handler never fires without a window.
    Restore-GuiState
    Update-ProfileList
    Update-MasterGating
    $failures = Update-Preflight
    Write-Host "Controls built: $($script:SettingControls.Count) setting editors, $($script:AdvancedRows.Count) advanced rows."
    Write-Host "Preflight: $(@($script:PreflightResults).Count) checks, $failures failing."

    # The Run button builds its command line from $script:RepoRoot. If that is wrong, the failure is
    # a dialog at click time; checking it here turns it into a build failure instead.
    $pipelinePath = Join-Path $script:RepoRoot 'AutoDraw.ps1'
    if (-not (Test-Path -LiteralPath $pipelinePath)) {
        Write-Host "SELFTEST FAILED: AutoDraw.ps1 not found at $pipelinePath" -ForegroundColor Red
        $Form.Dispose()
        exit 1
    }
    Write-Host "Pipeline resolves: $pipelinePath"

    if ($SelfTestRun) {
        if (-not (Test-Path -LiteralPath $SelfTestRun -PathType Container)) {
            Write-Host "SELFTEST FAILED: capture folder not found: $SelfTestRun" -ForegroundColor Red
            $Form.Dispose(); exit 1
        }

        $runOutput = Join-Path ([System.IO.Path]::GetTempPath()) ('mtad-selftest-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path $runOutput -Force
        $InputBox.Text = $SelfTestRun
        $OutputBox.Text = $runOutput

        # Under a REAL ShowDialog, not a DoEvents pump. The difference is the whole point: a DoEvents
        # loop returns to the PowerShell engine between pumps, so the engine goes idle and anything
        # depending on that idleness still works. ShowDialog blocks the engine inside one statement
        # for the life of the window, which is the condition the live log has to survive.
        $script:SelfTestStartedAt = [DateTime]::UtcNow
        $script:SelfTestDeadline = $script:SelfTestStartedAt.AddMinutes(10)
        $script:SelfTestRunBegan = $false
        $script:SelfTestFailure = ''

        $kickTimer = [Windows.Forms.Timer]::new()
        $kickTimer.Interval = 300
        $kickTimer.Add_Tick({
            $kickTimer.Stop()
            $null = Start-PipelineRun -Unattended
            if ($script:RunProcess) { $script:SelfTestRunBegan = $true }
            else { $script:SelfTestFailure = 'the run never started'; $Form.Close() }
        })

        $watchTimer = [Windows.Forms.Timer]::new()
        $watchTimer.Interval = 250
        $watchTimer.Add_Tick({
            if ($script:SelfTestRunBegan -and -not $script:RunProcess) { $watchTimer.Stop(); $Form.Close(); return }
            if ([DateTime]::UtcNow -gt $script:SelfTestDeadline) {
                $script:SelfTestFailure = 'the run did not finish within the deadline'
                $watchTimer.Stop(); $Form.Close()
            }
        })

        $Form.Add_Shown({ $kickTimer.Start(); $watchTimer.Start() })
        [void]$Form.ShowDialog()

        $totalSeconds = ([DateTime]::UtcNow - $script:SelfTestStartedAt).TotalSeconds
        $firstLineSeconds = if ($script:RunFirstLineAt) { ($script:RunFirstLineAt - $script:SelfTestStartedAt).TotalSeconds } else { -1 }
        Write-Host ("Run finished in {0:N1}s; log lines {1}; drain passes {2}; first line at {3:N1}s" -f `
            $totalSeconds, $LogBox.Lines.Count, $script:RunDrainPasses, $firstLineSeconds)
        Write-Host "Verdict shown: $($VerdictLabel.Text)"
        Remove-Item -LiteralPath $runOutput -Recurse -Force -ErrorAction SilentlyContinue

        if ($script:SelfTestFailure) {
            Write-Host "SELFTEST FAILED: $($script:SelfTestFailure)." -ForegroundColor Red
            $Form.Dispose(); exit 1
        }
        # Several passes carrying content is the whole point. One pass would mean everything landed
        # in a single burst at the end, which is exactly what "nothing is happening" looks like.
        if ($script:RunDrainPasses -lt 3) {
            Write-Host "SELFTEST FAILED: output was not live - only $($script:RunDrainPasses) drain pass(es)." -ForegroundColor Red
            $Form.Dispose(); exit 1
        }
        if ($LogBox.Lines.Count -lt 10) {
            Write-Host "SELFTEST FAILED: only $($LogBox.Lines.Count) line(s) reached the log." -ForegroundColor Red
            $Form.Dispose(); exit 1
        }
        # The first line must arrive early in the run, not with the last batch.
        if ($firstLineSeconds -lt 0 -or $firstLineSeconds -gt ($totalSeconds * 0.5)) {
            Write-Host "SELFTEST FAILED: first line at ${firstLineSeconds}s of a ${totalSeconds}s run." -ForegroundColor Red
            $Form.Dispose(); exit 1
        }
    }

    $Form.Dispose()
    if ($script:SelfTestDataRoot) {
        Remove-Item -LiteralPath $script:SelfTestDataRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    exit 0
}

[void]$Form.ShowDialog()
$Form.Dispose()
