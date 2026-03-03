function Test-FirstDeviceByType {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GDirectory,

        [Parameter(Mandatory = $true)]
        [string]$GPathToScript,

        [Parameter(Mandatory = $true)]
        [ValidateSet(
            "Cisco",
            "CiscoASA",
            "Junos",
            "ArubaOS-CX",
            "Fortigate",
            "PaloAlto",
            "CheckPoint",
            "Arista vEOS-lab"
        )]
        [string]$DeviceType
    )

    # Normalize trailing slashes
    if ($GDirectory -notmatch "\\$") { $GDirectory = "$GDirectory\" }
    if ($GPathToScript -notmatch "\\$") { $GPathToScript = "$GPathToScript\" }

    # Globals your code expects
    $script:GDirectory = $GDirectory
    $script:GPathToScript = $GPathToScript

    # Isolated test run: don’t trip duplicate hostname guardrails
    $script:SkipHostnameErrorCheck = $true

    # Some debug code uses these
    if (-not $global:GLastExecutionTime) { $global:GLastExecutionTime = [System.Diagnostics.Stopwatch]::StartNew() }
    if (-not $global:GLapTime) { $global:GLapTime = $global:GLastExecutionTime.ElapsedMilliseconds }

    # -----------------------------------------------------------------
    # ALWAYS reload in-session: (2) + (3) + (4)
    # -----------------------------------------------------------------

    # Persistent store across calls: scriptPath -> functions added last time
    if (-not $global:MTAutoDraw_ScriptFunctionMap) {
        $global:MTAutoDraw_ScriptFunctionMap = @{}
    }

    function Remove-PreviouslyAddedFunctionsForScriptPath {
        param(
            [Parameter(Mandatory = $true)]
            [string]$ScriptPath
        )

        if (-not (Test-Path -Path $ScriptPath)) { return }

        $resolved = (Resolve-Path $ScriptPath).Path
        if ($global:MTAutoDraw_ScriptFunctionMap.ContainsKey($resolved)) {
            foreach ($fn in $global:MTAutoDraw_ScriptFunctionMap[$resolved]) {
                if (Test-Path -Path "Function:\$fn") {
                    Remove-Item -Path "Function:\$fn" -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }

    # (4) clear state that poisons reruns
    Remove-Variable -Scope Global -Name GMacAddressToVendorMapping -Force -ErrorAction SilentlyContinue
    Remove-Variable -Scope Script -Name ArrayOfHostIDs -Force -ErrorAction SilentlyContinue
    Remove-Variable -Scope Global -Name ArrayOfHostIDs -Force -ErrorAction SilentlyContinue

    # (2) hard-remove common entrypoints/helpers (covers renames and stubborn leftovers)
    $functionsToHardRemove = @(
        "Create-FileHostObjects",
        "Get-MacAddressToVendorMapping",
        "Execute-PythonTextFSM",
        "Process-CiscoHostFiles",
        "Process-CiscoASAHostFiles",
        "Process-JunosHostFiles",
        "Process-ArubaHostFiles",
        "Process-FortigateHostFiles",
        "Process-PaloAltoHostFiles",
        "Process-CheckPointHostFiles",
        "Process-AristaHostFiles"
    )

    foreach ($fn in $functionsToHardRemove) {
        if (Test-Path -Path "Function:\$fn") {
            Remove-Item -Path "Function:\$fn" -Force -ErrorAction SilentlyContinue
        }
    }

    # Decide vendor script path
    $vendorScript = $null
    switch ($DeviceType) {
        "Cisco"           { $vendorScript = "$($GPathToScript)CiscoConfigProcessingFunctions.ps1" }
        "CiscoASA"        { $vendorScript = "$($GPathToScript)CiscoASAConfigProcessingFunctions.ps1" }
        "Junos"           { $vendorScript = "$($GPathToScript)JunosConfigProcessingFunctions.ps1" }
        "ArubaOS-CX"      { $vendorScript = "$($GPathToScript)ArubaConfigProcessingFunctions.ps1" }
        "Fortigate"       { $vendorScript = "$($GPathToScript)FortigateConfigProcessingFunctions.ps1" }
        "PaloAlto"        { $vendorScript = "$($GPathToScript)PaloAltoConfigProcessingFunctions.ps1" }
        "CheckPoint"      { $vendorScript = "$($GPathToScript)CheckPointConfigProcessingFunctions.ps1" }
        "Arista vEOS-lab" { $vendorScript = "$($GPathToScript)AristaConfigProcessingFunctions.ps1" }
        default { throw "Unsupported DeviceType '$DeviceType'." }
    }

    $coreScripts = @(
        "$($GPathToScript)configurationVariables.ps1",
        "$($GPathToScript)ObjectFunctions.ps1",
        "$($GPathToScript)HelperFunctions.ps1",
        "$($GPathToScript)StartProcessingConfig.ps1"
    )

    $allScripts = @()
    $allScripts += $coreScripts
    $allScripts += $vendorScript

    foreach ($p in $allScripts) {
        if (-not (Test-Path -Path $p)) {
            throw "Missing script file: $p"
        }
    }

    # (3) remove functions those scripts added last time
    foreach ($p in $allScripts) {
        Remove-PreviouslyAddedFunctionsForScriptPath -ScriptPath $p
    }

    # -----------------------------------------------------------------
    # Load scripts (IMPORTANT: dot-source inline in THIS scope)
    # Also track what each script adds, inline (no helper dot-sourcing).
    # -----------------------------------------------------------------

    # configurationVariables.ps1
    $before = Get-ChildItem Function:\ | Select-Object -ExpandProperty Name
    . "$($GPathToScript)configurationVariables.ps1"
    $after = Get-ChildItem Function:\ | Select-Object -ExpandProperty Name
    $resolved = (Resolve-Path "$($GPathToScript)configurationVariables.ps1").Path
    $global:MTAutoDraw_ScriptFunctionMap[$resolved] = (Compare-Object $before $after | Where-Object { $_.SideIndicator -eq "=>" } | Select-Object -ExpandProperty InputObject)

    # ObjectFunctions.ps1
    $before = Get-ChildItem Function:\ | Select-Object -ExpandProperty Name
    . "$($GPathToScript)ObjectFunctions.ps1"
    $after = Get-ChildItem Function:\ | Select-Object -ExpandProperty Name
    $resolved = (Resolve-Path "$($GPathToScript)ObjectFunctions.ps1").Path
    $global:MTAutoDraw_ScriptFunctionMap[$resolved] = (Compare-Object $before $after | Where-Object { $_.SideIndicator -eq "=>" } | Select-Object -ExpandProperty InputObject)

    # HelperFunctions.ps1
    $before = Get-ChildItem Function:\ | Select-Object -ExpandProperty Name
    . "$($GPathToScript)HelperFunctions.ps1"
    $after = Get-ChildItem Function:\ | Select-Object -ExpandProperty Name
    $resolved = (Resolve-Path "$($GPathToScript)HelperFunctions.ps1").Path
    $global:MTAutoDraw_ScriptFunctionMap[$resolved] = (Compare-Object $before $after | Where-Object { $_.SideIndicator -eq "=>" } | Select-Object -ExpandProperty InputObject)

    # StartProcessingConfig.ps1
    $before = Get-ChildItem Function:\ | Select-Object -ExpandProperty Name
    . "$($GPathToScript)StartProcessingConfig.ps1"
    $after = Get-ChildItem Function:\ | Select-Object -ExpandProperty Name
    $resolved = (Resolve-Path "$($GPathToScript)StartProcessingConfig.ps1").Path
    $global:MTAutoDraw_ScriptFunctionMap[$resolved] = (Compare-Object $before $after | Where-Object { $_.SideIndicator -eq "=>" } | Select-Object -ExpandProperty InputObject)

    # Vendor script
    $before = Get-ChildItem Function:\ | Select-Object -ExpandProperty Name
    . $vendorScript
    $after = Get-ChildItem Function:\ | Select-Object -ExpandProperty Name
    $resolved = (Resolve-Path $vendorScript).Path
    $global:MTAutoDraw_ScriptFunctionMap[$resolved] = (Compare-Object $before $after | Where-Object { $_.SideIndicator -eq "=>" } | Select-Object -ExpandProperty InputObject)

    # Optional dependency used by HelperFunctions in some paths
    $ipv4Module = "$($GPathToScript)GETIPV4Subnet\GetIPv4Subnet.psm1"
    if (Test-Path -Path $ipv4Module) {
        Import-Module $ipv4Module -Force
    }

    # ------------------------------------------------------------
    # Override debug helpers to just print to console
    # ------------------------------------------------------------
    function global:write-HostDebugText {
        param(
            [Parameter(Mandatory = $true)]
            $text,
            $BackgroundColor,
            $ForegroundColor
        )

        $msg = $text.ToString()

        if ($null -ne $BackgroundColor -and $null -ne $ForegroundColor) {
            Write-Host $msg -BackgroundColor $BackgroundColor -ForegroundColor $ForegroundColor
            return
        }
        if ($null -ne $ForegroundColor) {
            Write-Host $msg -ForegroundColor $ForegroundColor
            return
        }

        Write-Host $msg
    }

    function global:Add-HostDebugText {
        param(
            [Parameter(Mandatory = $true)]
            $HostObject,
            [Parameter(Mandatory = $true)]
            $text,
            $BackgroundColor,
            $ForegroundColor
        )

        write-HostDebugText -text $text -BackgroundColor $BackgroundColor -ForegroundColor $ForegroundColor
    }

    # ------------------------------------------------------------
    # MAC vendor mapping (required by ARP/MAC parsing paths)
    # Always rebuild every run, and ensure relative CSV paths work
    # ------------------------------------------------------------
    Push-Location $GPathToScript
    try {
        $global:GMacAddressToVendorMapping = Get-MacAddressToVendorMapping
        if (-not $global:GMacAddressToVendorMapping) {
            $global:GMacAddressToVendorMapping = @{}
        }
    }
    finally {
        Pop-Location
    }

    # ------------------------------------------------------------
    # Build host objects from directory and pick first matching type
    # ------------------------------------------------------------
    $files = Get-ChildItem -Path $GDirectory -File -Recurse
    $script:ArrayOfHostIDs = Create-FileHostObjects -files $files

    $hostid = $script:ArrayOfHostIDs |
        Where-Object { $_.DeviceType -eq $DeviceType } |
        Select-Object -First 1

    if (-not $hostid) {
        throw "No devices with DeviceType '$DeviceType' found under '$GDirectory'."
    }

    Write-Host "=== Test-FirstDeviceByType ==="
    Write-Host "DeviceType : $DeviceType"
    Write-Host "HOSTID     : $($hostid.HOSTID)"
    Write-Host "showrun    : $($hostid.showrun)"
    Write-Host "ShowVersion: $($hostid.ShowVersion)"

    # ------------------------------------------------------------
    # Run the correct processing function and return the Device
    # ------------------------------------------------------------
    $device = $null
    switch ($DeviceType) {
        "Cisco"           { $device = Process-CiscoHostFiles      -hostid $hostid -ArrayOfObjects @() }
        "CiscoASA"        { $device = Process-CiscoASAHostFiles   -hostid $hostid -ArrayOfObjects @() }
        "Junos"           { $device = Process-JunosHostFiles      -hostid $hostid -ArrayOfObjects @() }
        "ArubaOS-CX"      { $device = Process-ArubaHostFiles      -hostid $hostid -ArrayOfObjects @() }
        "Fortigate"       { $device = Process-FortigateHostFiles  -hostid $hostid -ArrayOfObjects @() }
        "PaloAlto"        { $device = Process-PaloAltoHostFiles   -hostid $hostid -ArrayOfObjects @() }
        "CheckPoint"      { $device = Process-CheckPointHostFiles -hostid $hostid -ArrayOfObjects @() }
        "Arista vEOS-lab" { $device = Process-AristaHostFiles     -hostid $hostid -ArrayOfObjects @() }
        default { throw "No processing mapping for DeviceType '$DeviceType'." }
    }

    return $device
}