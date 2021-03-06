﻿function New-PSDCClone {
    <#
    .SYNOPSIS
        New-PSDCClone creates a new clone

    .DESCRIPTION
        New-PSDCClone willcreate a new clone based on an image.
        The clone will be created in a certain directory, mounted and attached to a database server.

    .PARAMETER SqlInstance
        SQL Server name or SMO object representing the SQL Server to connect to

    .PARAMETER SqlCredential
        Allows you to login to servers using SQL Logins as opposed to Windows Auth/Integrated/Trusted. To use:

        $scred = Get-Credential, then pass $scred object to the -SqlCredential parameter.

        Windows Authentication will be used if SqlCredential is not specified. SQL Server does not accept Windows credentials being passed as credentials.
        To connect as a different Windows user, run PowerShell as that user.

    .PARAMETER PSDCSqlCredential
        Allows you to login to servers using SQL Logins as opposed to Windows Auth/Integrated/Trusted.
        This works similar as SqlCredential but is only meant for authentication to the PSDatabaseClone database server and database.

    .PARAMETER Credential
        Allows you to login to servers using Windows Auth/Integrated/Trusted. To use:

        $scred = Get-Credential, then pass $scred object to the -Credential parameter.

    .PARAMETER ParentVhd
        Points to the parent VHD to create the clone from

    .PARAMETER Destination
        Destination directory to save the clone to

    .PARAMETER CloneName
        Name of the clone

    .PARAMETER Database
        Database name for the clone

    .PARAMETER LatestImage
        Automatically get the last image ever created for an specific database

    .PARAMETER Disabled
        Registers the clone in the configuration as disabled.
        If this setting is used the clone will not be recovered when the repair command is run

    .PARAMETER Force
        Forcefully create items when needed

    .PARAMETER EnableException
        By default, when something goes wrong we try to catch it, interpret it and give you a friendly warning message.
        This avoids overwhelming you with "sea of red" exceptions, but is inconvenient because it basically disables advanced scripting.
        Using this switch turns this "nice by default" feature off and enables you to catch exceptions with your own try/catch.

    .PARAMETER WhatIf
        If this switch is enabled, no actions are performed but informational messages will be displayed that explain what would happen if the command were to run.

    .PARAMETER Confirm
        If this switch is enabled, you will be prompted for confirmation before executing any operations that change state.

    .NOTES
        Author: Sander Stad (@sqlstad, sqlstad.nl)

        Website: https://psdatabaseclone.org
        Copyright: (C) Sander Stad, sander@sqlstad.nl
        License: MIT https://opensource.org/licenses/MIT

    .LINK
        https://psdatabaseclone.org/

    .EXAMPLE
        New-PSDCClone -SqlInstance SQLDB1 -ParentVhd C:\Temp\images\DB1_20180623203204.vhdx -Destination C:\Temp\clones\ -CloneName DB1_Clone1

        Create a new clone based on the image DB1_20180623203204.vhdx and attach the database to SQLDB1 as DB1_Clone1

    .EXAMPLE
        New-PSDCClone -SqlInstance SQLDB1 -Database DB1, DB2 -LatestImage

        Create a new clone on SQLDB1 for the databases DB1 and DB2 with the latest image for those databases

    .EXAMPLE
        New-PSDCClone -SqlInstance SQLDB1, SQLDB2 -Database DB1 -LatestImage

        Create a new clone on SQLDB1 and SQLDB2 for the databases DB1 with the latest image
    #>
    [CmdLetBinding(DefaultParameterSetName = 'ByLatest', SupportsShouldProcess = $true)]
    [OutputType('PSDCClone')]

    param(
        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [object[]]$SqlInstance,
        [System.Management.Automation.PSCredential]
        $SqlCredential,
        [System.Management.Automation.PSCredential]
        $PSDCSqlCredential,
        [System.Management.Automation.PSCredential]
        $Credential,
        [parameter(Mandatory = $true, ParameterSetName = "ByParent")]
        [string]$ParentVhd,
        [string]$Destination,
        [string]$CloneName,
        [parameter(Mandatory = $true, ParameterSetName = "ByLatest")]
        [string[]]$Database,
        [parameter(Mandatory = $true, ParameterSetName = "ByLatest")]
        [switch]$LatestImage,
        [switch]$Disabled,
        [switch]$Force,
        [switch]$EnableException
    )

    begin {
        # Check if the console is run in Administrator mode
        if ( -not (Test-PSDCElevated) ) {
            Stop-PSFFunction -Message "Module requires elevation. Please run the console in Administrator mode"
        }

        # Check if the setup has ran
        if (-not (Get-PSFConfigValue -FullName psdatabaseclone.setup.status)) {
            Stop-PSFFunction -Message "The module setup has NOT yet successfully run. Please run 'Set-PSDCConfiguration'"
            return
        }

        # Get the information store
        $informationStore = Get-PSFConfigValue -FullName psdatabaseclone.informationstore.mode

        if ($informationStore -eq 'SQL') {
            # Get the module configurations
            $pdcSqlInstance = Get-PSFConfigValue -FullName psdatabaseclone.database.Server
            $pdcDatabase = Get-PSFConfigValue -FullName psdatabaseclone.database.name
            if (-not $PSDCSqlCredential) {
                $pdcCredential = Get-PSFConfigValue -FullName psdatabaseclone.informationstore.credential -Fallback $null
            }
            else {
                $pdcCredential = $PSDCSqlCredential
            }

            # Test the module database setup
            if ($PSCmdlet.ShouldProcess("Test-PSDCConfiguration", "Testing module setup")) {
                try {
                    Test-PSDCConfiguration -SqlCredential $pdcCredential -EnableException
                }
                catch {
                    Stop-PSFFunction -Message "Something is wrong in the module configuration" -ErrorRecord $_ -Continue
                }
            }
        }

        Write-PSFMessage -Message "Started clone creation" -Level Verbose

        # Random string
        $random = -join ((65..90) + (97..122) | Get-Random -Count 5 | ForEach-Object {[char]$_})

        # Check the disabled parameter
        $active = 1
        if ($Disabled) {
            $active = 0
        }
    }

    process {
        # Test if there are any errors
        if (Test-PSFFunctionInterrupt) { return }

        # Loop through all the instances
        foreach ($instance in $SqlInstance) {

            # Try connecting to the instance
            Write-PSFMessage -Message "Attempting to connect to Sql Server $SqlInstance.." -Level Verbose
            try {
                $server = Connect-DbaInstance -SqlInstance $instance -SqlCredential $SqlCredential

                # Setup the computer object
                $computer = [PsfComputer]$server.ComputerName
            }
            catch {
                Stop-PSFFunction -Message "Could not connect to Sql Server instance $instance" -ErrorRecord $_ -Target $instance
                return
            }

            if (-not $computer.IsLocalhost) {
                # Get the result for the remote test
                $resultPSRemote = Test-PSDCRemoting -ComputerName $server.Name -Credential $Credential

                # Check the result
                if ($resultPSRemote.Result) {
                    try {
                        Invoke-PSFCommand -ComputerName $computer -Credential $Credential -ScriptBlock { Import-Module PSDatabaseClone }
                    }
                    catch {
                        Stop-PSFFunction -Message "Couldn't import module remotely" -Target $command
                        return
                    }
                }
                else {
                    Stop-PSFFunction -Message "Couldn't connect to host remotely.`nVerify that the specified computer name is valid, that the computer is accessible over the network, and that a firewall exception for the WinRM service is enabled and allows access from this computer" -Target $resultPSRemote -Continue
                }
            }

            # Check destination
            if (-not $Destination) {
                $Destination = $server.DefaultFile
                if ($server.DefaultFile.EndsWith("\")) {
                    $Destination = $Destination.Substring(0, $Destination.Length - 1)
                }

                $Destination += "\clone"
            }
            else {
                # If the destination is a network path
                if ($Destination.StartsWith("\\")) {
                    Write-PSFMessage -Message "The destination cannot be an UNC path. Trying to convert to local path" -Level Verbose

                    if ($PSCmdlet.ShouldProcess($Destination, "Converting UNC path '$Destination' to local path")) {
                        try {
                            # Check if computer is local
                            $Destination = Invoke-PSFCommand -ComputerName $computer -Credential $Credential -ScriptBlock {
                                param($p1)
                                Convert-PSDCUncPathToLocalPath -UncPath $p1
                            } -ArgumentList $Destination
                        }
                        catch {
                            Stop-PSFFunction -Message "Something went wrong getting the local image path" -Target $Destination
                            return
                        }
                    }
                }

                # Remove the last "\" from the path it would mess up the mount of the VHD
                if ($Destination.EndsWith("\")) {
                    $Destination = $Destination.Substring(0, $Destination.Length - 1)
                }

                # Test if the destination can be reached
                $result = Invoke-PSFCommand -ComputerName $computer -Credential $Credential -ScriptBlock {
                    param($p1)
                    Test-Path -Path $p1
                } -ArgumentList $Destination
                if (-not $result) {
                    Stop-PSFFunction -Message "Could not find destination path $Destination" -Target $SqlInstance
                }
            }

            # Loopt through all the databases
            foreach ($db in $Database) {

                if ($LatestImage) {
                    $images = Get-PSDCImage -Database $db
                    $result = $images[-1] | Sort-Object CreatedOn
                }

                # Check the results
                if ($null -eq $result) {
                    Stop-PSFFunction -Message "No image could be found for database $db" -Target $pdcSqlInstance -Continue
                }
                else {
                    $ParentVhd = $result.ImageLocation
                }

                # Take apart the vhd directory
                if ($PSCmdlet.ShouldProcess($ParentVhd, "Setting up parent VHD variables")) {
                    $uri = new-object System.Uri($ParentVhd)
                    $vhdComputer = [PsfComputer]$uri.Host

                    $result = Invoke-PSFCommand -ComputerName $vhdComputer -Credential $Credential -ScriptBlock {
                        param($p1)
                        Test-Path -Path $p1
                    } -ArgumentList $ParentVhd
                    if ($result) {
                        $parentVhdFileName = $ParentVhd.Split("\")[-1]
                        $parentVhdFile = $parentVhdFileName.Split(".")[0]
                    }
                    else {
                        Stop-PSFFunction -Message "Parent vhd could not be found" -Target $SqlInstance -Continue
                    }
                }

                # Check clone name parameter
                if ($PSCmdlet.ShouldProcess($ParentVhd, "Setting up clone variables")) {
                    if (-not $CloneName) {
                        $cloneDatabase = $parentVhdFile
                        $CloneName = $parentVhdFile
                        $mountDirectory = "$($parentVhdFile)_$($random)"
                    }
                    elseif ($CloneName) {
                        $cloneDatabase = $CloneName
                        $mountDirectory = "$($CloneName)_$($random)"
                    }
                }

                # Check if the database is already present
                if ($PSCmdlet.ShouldProcess($cloneDatabase, "Verifying database existence")) {
                    if ($server.Databases.Name -contains $cloneDatabase) {
                        Stop-PSFFunction -Message "Database $cloneDatabase is already present on $SqlInstance" -Target $SqlInstance
                    }
                }

                # Setup access path location
                $accessPath = "$Destination\$mountDirectory"

                # Check if access path is already present
                $result = Invoke-PSFCommand -ComputerName $computer -Credential $Credential -ScriptBlock {
                    param($p1)
                    if (-not (Test-Path -Path $p1)) {
                        try {
                            $null = New-Item -Path $p1 -ItemType Directory -Force
                        }
                        catch {
                            Stop-PSFFunction -Message "Couldn't create access path directory" -ErrorRecord $_ -Target $p1 -Continue
                        }
                    }
                } -ArgumentList $accessPath

                # Check if the clone vhd does not yet exist
                $result = Invoke-PSFCommand -ComputerName $computer -Credential $Credential -ScriptBlock {
                    param($p1, $p2)
                    Test-Path -Path "$p1\$p2.vhdx"
                } -ArgumentList $Destination, $CloneName
                if ($result) {
                    Stop-PSFFunction -Message "Clone $CloneName already exists" -Target $accessPath -Continue
                }

                # Create the new child vhd
                if ($PSCmdlet.ShouldProcess($ParentVhd, "Creating clone")) {
                    try {
                        Write-PSFMessage -Message "Creating clone from $ParentVhd" -Level Verbose
                        New-PSDCVhdDisk -Destination $Destination -Name $CloneName -ParentVhd $ParentVhd
                        $command = "create vdisk file='$Destination\$CloneName.vhdx' parent='$ParentVhd'"
                        <# $null = Invoke-PSFCommand -ComputerName $computer -Credential $Credential -ScriptBlock {
                            param($p1)
                            $tempFile = (New-TemporaryFile).Name
                            Set-Content -Path $tempFile -Value $p1 -Force
                            diskpart /s $tempFile
                        } -ArgumentList $command #>
                    }
                    catch {
                        Stop-PSFFunction -Message "Could not create clone" -Target $vhd -Continue -ErrorRecord $_
                    }
                }

                # Mount the vhd
                $vhdPath = "$Destination\$CloneName.vhdx"
                if ($PSCmdlet.ShouldProcess($vhdPath, "Mounting clone")) {
                    try {
                        Write-PSFMessage -Message "Mounting clone" -Level Verbose
                        Mount-PSDCVhdDisk -Path $vhdPath -AccessPath $accessPath
                        <# $disk = Invoke-PSFCommand -ComputerName $computer -Credential $Credential -ScriptBlock {
                            param($p1)
                            $null = Mount-DiskImage -ImagePath $p1
                            Get-Disk | Where-Object {$_.Location -eq $p1}
                        } -ArgumentList $vhdPath #>
                    }
                    catch {
                        Stop-PSFFunction -Message "Couldn't mount vhd $Destination\$CloneName.vhdx" -ErrorRecord $_ -Target $disk -Continue
                    }
                }

                # Check if the disk is offline
                <# if ($PSCmdlet.ShouldProcess($disk.Number, "Initializing disk")) {
                    $null = Invoke-PSFCommand -ComputerName $computer -Credential $Credential -ScriptBlock {
                        param($p1)
                        Initialize-Disk -Number $p1.Number -PartitionStyle GPT -ErrorAction SilentlyContinue
                    } -ArgumentList $disk
                } #>

                # Mounting disk to access path
                <# if ($PSCmdlet.ShouldProcess($disk.Number, "Mounting volume to accesspath")) {
                    try {
                        $null = Invoke-PSFCommand -ComputerName $computer -Credential $Credential -ScriptBlock {
                            param($p1, $p2)
                            $partition = Get-Partition -Disk $p1 | Where-Object {$_.Type -ne "Reserved"} | Select-Object -First 1

                            # Create an access path for the disk
                            $null = Add-PartitionAccessPath -DiskNumber $p1.Number -PartitionNumber $partition.PartitionNumber -AccessPath $p2 -ErrorAction SilentlyContinue
                        } -ArgumentList $disk, $accessPath
                    }
                    catch {
                        Stop-PSFFunction -Message "Couldn't create access path for partition" -ErrorRecord $_ -Target $partition -Continue
                    }
                } #>

                # Set privileges for access path
                <# try {
                    # Check if computer is local
                    if ($computer.IsLocalhost) {
                        $accessRule = New-Object System.Security.AccessControl.FilesystemAccessrule("Everyone", "FullControl", "Allow")

                        foreach ($file in $(Get-ChildItem $accessPath -Recurse)) {
                            $acl = Get-Acl $file.FullName

                            # Add this access rule to the ACL
                            $acl.SetAccessRule($accessRule)

                            # Write the changes to the object
                            Set-Acl -Path $file.Fullname -AclObject $acl
                        }
                    }
                    else {
                        [string]$commandText = "`$accessRule = New-Object System.Security.AccessControl.FilesystemAccessrule(`"Everyone`", `"FullControl`", `"Allow`")
                            foreach (`$file in `$(Get-ChildItem -Path `"$accessPath`" -Recurse)) {
                                `$acl = Get-Acl `$file.Fullname

                                # Add this access rule to the ACL
                                `$acl.SetAccessRule(`$accessRule)

                                # Write the changes to the object
                                Set-Acl -Path `$file.Fullname -AclObject `$acl
                            }"

                        $command = [scriptblock]::Create($commandText)

                        $null = Invoke-PSFCommand -ComputerName $computer -ScriptBlock $command -ArgumentList $accessPath -Credential $DestinationCredential
                    }
                }
                catch {
                    Stop-PSFFunction -Message "Couldn't create access path directory" -ErrorRecord $_ -Target $accessPath -Continue
                } #>

                # Get all the files of the database
                $databaseFiles = Invoke-PSFCommand -ComputerName $computer -Credential $Credential -ScriptBlock {
                    param($p1)
                    Get-ChildItem -Path $p1 -Filter *.*df -Recurse
                } -ArgumentList $accessPath

                # Setup the database filestructure
                $dbFileStructure = New-Object System.Collections.Specialized.StringCollection

                # Loop through each of the database files and add them to the file structure
                foreach ($dbFile in $databaseFiles) {
                    $null = $dbFileStructure.Add($dbFile.FullName)
                }

                # Mount the database
                if ($PSCmdlet.ShouldProcess($cloneDatabase, "Mounting database $cloneDatabase")) {
                    try {
                        Write-PSFMessage -Message "Mounting database from clone" -Level Verbose
                        $null = Mount-DbaDatabase -SqlInstance $SqlInstance -SqlCredential $SqlCredential -Database $cloneDatabase -FileStructure $dbFileStructure
                    }
                    catch {
                        Stop-PSFFunction -Message "Couldn't mount database $cloneDatabase" -Target $SqlInstance -Continue
                    }
                }

                # Write the data to the database
                try {
                    # Get the data of the host
                    if ($computer.IsLocalhost) {
                        $computerinfo = [System.Net.Dns]::GetHostByName(($env:computerName))

                        $hostname = $computerinfo.HostName
                        $ipAddress = $computerinfo.AddressList[0]
                        $fqdn = $computerinfo.HostName
                    }
                    else {
                        $command = [scriptblock]::Create('[System.Net.Dns]::GetHostByName(($env:computerName))')
                        $computerinfo = Invoke-PSFCommand -ComputerName $computer -ScriptBlock $command -Credential $Credential

                        $command = [scriptblock]::Create('$env:COMPUTERNAME')
                        $result = Invoke-PSFCommand -ComputerName $computer -ScriptBlock $command -Credential $Credential

                        $hostname = $result.ToString()
                        $ipAddress = $computerinfo.AddressList[0]
                        $fqdn = $computerinfo.HostName
                    }

                    if ($informationStore -eq 'SQL') {
                        # Setup the query to check of the host is already added
                        $query = "
                            IF EXISTS (SELECT HostName FROM Host WHERE HostName ='$hostname')
                            BEGIN
                                SELECT CAST(1 AS BIT) AS HostKnown;
                            END;
                            ELSE
                            BEGIN
                                SELECT CAST(0 AS BIT) AS HostKnown;
                            END;
                        "

                        # Execute the query
                        $hostKnown = (Invoke-DbaQuery -SqlInstance $pdcSqlInstance -SqlCredential $pdcCredential -Database $pdcDatabase -Query $query -EnableException).HostKnown
                    }
                    elseif ($informationStore -eq 'File') {
                        $hosts = Get-ChildItem -Path PSDCJSONFolder:\ -Filter *hosts.json | ForEach-Object { Get-Content $_.FullName | ConvertFrom-Json}

                        $hostKnown = [bool]($hostname -in $hosts.HostName)
                    }
                }
                catch {
                    Stop-PSFFunction -Message "Couldnt execute query to see if host was known" -Target $query -ErrorRecord $_ -Continue
                }

                # Add the host if the host is known
                if (-not $hostKnown) {
                    if ($PSCmdlet.ShouldProcess($hostname, "Adding hostname to database")) {

                        if ($informationStore -eq 'SQL') {

                            Write-PSFMessage -Message "Adding host $hostname to database" -Level Verbose

                            $query = "
                                DECLARE @HostID INT;
                                EXECUTE dbo.Host_New @HostID = @HostID OUTPUT, -- int
                                                    @HostName = '$hostname',   -- varchar(100)
                                                    @IPAddress = '$ipAddress', -- varchar(20)
                                                    @FQDN = '$fqdn'			   -- varchar(255)

                                SELECT @HostID AS HostID
                            "

                            try {
                                $hostID = (Invoke-DbaQuery -SqlInstance $pdcSqlInstance -SqlCredential $pdcCredential -Database $pdcDatabase -Query $query -EnableException).HostID
                            }
                            catch {
                                Stop-PSFFunction -Message "Couldnt execute query for adding host" -Target $query -ErrorRecord $_ -Continue
                            }
                        }
                        elseif ($informationStore -eq 'File') {
                            [array]$hosts = $null

                            # Get all the images
                            $hosts = Get-ChildItem -Path PSDCJSONFolder:\ -Filter *hosts.json | ForEach-Object { Get-Content $_.FullName | ConvertFrom-Json}

                            # Setup the new host id
                            if ($hosts.Count -ge 1) {
                                $hostID = ($hosts[-1].HostID | Sort-Object HostID) + 1
                            }
                            else {
                                $hostID = 1
                            }

                            # Add the new information to the array
                            $hosts += [PSCustomObject]@{
                                HostID    = $hostID
                                HostName  = $hostname
                                IPAddress = $ipAddress.IPAddressToString
                                FQDN      = $fqdn
                            }

                            # Test if the JSON folder can be reached
                            if (-not (Test-Path -Path "PSDCJSONFolder:\")) {
                                $command = [scriptblock]::Create("Import-Module PSDatabaseClone -Force")

                                try {
                                    Invoke-PSFCommand -ComputerName $computer -ScriptBlock $command -Credential $Credential
                                }
                                catch {
                                    Stop-PSFFunction -Message "Couldn't import module remotely" -Target $command
                                    return
                                }
                            }

                            # Setup the json file
                            $jsonHostFile = "PSDCJSONFolder:\hosts.json"

                            # Convert the data back to JSON
                            $hosts | ConvertTo-Json | Set-Content $jsonHostFile
                        }
                    }
                }
                else {
                    if ($informationStore -eq 'SQL') {
                        Write-PSFMessage -Message "Selecting host $hostname from database" -Level Verbose
                        $query = "SELECT HostID FROM Host WHERE HostName = '$hostname'"

                        try {
                            $hostID = (Invoke-DbaQuery -SqlInstance $pdcSqlInstance -SqlCredential $pdcCredential -Database $pdcDatabase -Query $query -EnableException).HostID
                        }
                        catch {
                            Stop-PSFFunction -Message "Couldnt execute query for retrieving host id" -Target $query -ErrorRecord $_ -Continue
                        }
                    }
                    elseif ($informationStore -eq 'File') {
                        $hostID = ($hosts | Where-Object {$_.Hostname -eq $hostname} | Select-Object HostID -Unique).HostID
                    }
                }

                # Setup the clone location
                $cloneLocation = "$Destination\$CloneName.vhdx"

                if ($informationStore -eq 'SQL') {
                    # Get the image id from the database
                    Write-PSFMessage -Message "Selecting image from database" -Level Verbose
                    try {
                        $query = "SELECT ImageID, ImageName FROM dbo.Image WHERE ImageLocation = '$ParentVhd'"
                        $image = Invoke-DbaQuery -SqlInstance $pdcSqlInstance -SqlCredential $pdcCredential -Database $pdcDatabase -Query $query -EnableException
                    }
                    catch {
                        Stop-PSFFunction -Message "Couldnt execute query for retrieving image id" -Target $query -ErrorRecord $_ -Continue
                    }

                    if ($PSCmdlet.ShouldProcess("$Destination\$CloneName.vhdx", "Adding clone to database")) {
                        if ($null -ne $image.ImageID) {
                            # Setup the query to add the clone to the database
                            Write-PSFMessage -Message "Adding clone $cloneLocation to database" -Level Verbose
                            $query = "
                                DECLARE @CloneID INT;
                                EXECUTE dbo.Clone_New @CloneID = @CloneID OUTPUT,                   -- int
                                                    @ImageID = $($image.ImageID),             -- int
                                                    @HostID = $hostId,			                    -- int
                                                    @CloneLocation = '$cloneLocation',	            -- varchar(255)
                                                    @AccessPath = '$accessPath',                    -- varchar(255)
                                                    @SqlInstance = '$($server.DomainInstanceName)', -- varchar(50)
                                                    @DatabaseName = '$cloneDatabase',               -- varchar(100)
                                                    @IsEnabled = $active                            -- bit

                                SELECT @CloneID AS CloneID
                            "

                            Write-PSFMessage -Message "Query New Clone`n$query" -Level Debug

                            # execute the query
                            try {
                                $result = Invoke-DbaQuery -SqlInstance $pdcSqlInstance -SqlCredential $pdcCredential -Database $pdcDatabase -Query $query -EnableException
                                $cloneID = $result.CloneID
                            }
                            catch {
                                Stop-PSFFunction -Message "Couldnt execute query for adding clone" -Target $query -ErrorRecord $_ -Continue
                            }

                        }
                        else {
                            Stop-PSFFunction -Message "Image couldn't be found" -Target $imageName -Continue
                        }
                    }
                }
                elseif ($informationStore -eq 'File') {
                    # Get the image
                    $image = Get-PSDCImage -ImageLocation $ParentVhd

                    [array]$clones = $null

                    # Get all the images
                    $clones = Get-PSDCClone

                    # Setup the new image id
                    if ($clones.Count -ge 1) {
                        $cloneID = ($clones[-1].CloneID | Sort-Object CloneID) + 1
                    }
                    else {
                        $cloneID = 1
                    }

                    # Add the new information to the array
                    $clones += [PSCustomObject]@{
                        CloneID       = $cloneID
                        ImageID       = $image.ImageID
                        ImageName     = $image.ImageName
                        ImageLocation = $ParentVhd
                        HostID        = $hostId
                        HostName      = $hostname
                        CloneLocation = $cloneLocation
                        AccessPath    = $accessPath
                        SqlInstance   = $($server.DomainInstanceName)
                        DatabaseName  = $cloneDatabase
                        IsEnabled     = $active
                    }

                    # Test if the JSON folder can be reached
                    if (-not (Test-Path -Path "PSDCJSONFolder:\")) {
                        $command = [scriptblock]::Create("Import-Module PSDatabaseClone -Force")

                        try {
                            Invoke-PSFCommand -ComputerName $computer -ScriptBlock $command -Credential $Credential
                        }
                        catch {
                            Stop-PSFFunction -Message "Couldn't import module remotely" -Target $command
                            return
                        }
                    }

                    # Set the clone file
                    $jsonCloneFile = "PSDCJSONFolder:\clones.json"

                    # Convert the data back to JSON
                    $clones | ConvertTo-Json | Set-Content $jsonCloneFile
                }

                # Add the results to the custom object
                $clone = New-Object PSDCClone

                $clone.CloneID = $cloneID
                $clone.CloneLocation = $cloneLocation
                $clone.AccessPath = $accessPath
                $clone.SqlInstance = $server.DomainInstanceName
                $clone.DatabaseName = $cloneDatabase
                $clone.IsEnabled = $active
                $clone.ImageID = $image.ImageID
                $clone.ImageName = $image.ImageName
                $clone.ImageLocation = $ParentVhd
                $clone.HostName = $hostname

                return $clone

            } # End for each database

        } # End for each sql instance

    } # End process

    end {
        # Test if there are any errors
        if (Test-PSFFunctionInterrupt) { return }

        Write-PSFMessage -Message "Finished creating database clone" -Level Verbose
    }
}
