function Mount-PSDCVhdDisk {
    <#
    .SYNOPSIS
        Initialize-PSDCVhdDisk initialized the VHD

    .DESCRIPTION
        Initialize-PSDCVhdDisk will initialize the VHD.
        It mounts the disk, creates a volume, creates the partition and sets it to active

    .PARAMETER Path
        The path to the VHD

    .PARAMETER Credential
        Allows you to use credentials for creating items in other locations To use:

        $scred = Get-Credential, then pass $scred object to the -Credential parameter.

    .PARAMETER PartitionStyle
        A partition can either be initialized as MBR or as GPT. GPT is the default.

    .PARAMETER AllocationUnitSize
        Set the allocation unit size for the disk.
        By default it's 64 KB because that's what SQL Server tends to write most of the time.

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
        Initialize-PSDCVhdDisk -Path $path

        Initialize the disk pointing to the path with all default settings

    .EXAMPLE
        Initialize-PSDCVhdDisk -Path $path -AllocationUnitSize 4KB

        Initialize the disk and format the partition with a 4Kb allocation unit size

    #>

    [CmdLetBinding(SupportsShouldProcess = $true)]
    [OutputType('System.String')]
    [OutputType('PSCustomObject')]

    Param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [string]$accessPath,
        [System.Management.Automation.PSCredential]
        $Credential,
        [ValidateSet('GPT', 'MBR')]
        [string]$PartitionStyle,
        [int]$AllocationUnitSize = 64KB,
        [switch]$EnableException
    )

    begin {

        # Check if the console is run in Administrator mode
        if ( -not (Test-PSDCElevated) ) {
            Stop-PSFFunction -Message "Module requires elevation. Please run the console in Administrator mode"
        }

        # Check the path to the vhd
        $pathExists = Invoke-PSFCommand -ComputerName $computer -Credential $Credential -ScriptBlock {
            param($p1)
            Test-Path -Path $p1
        } -ArgumentList $Path

        if (-not ($pathExists)) {
            Stop-PSFFunction -Message "Vhd path $Path cannot be found" -Target $Path -Continue
        }

        # Check the partition style
        if(-not $PartitionStyle){
            Write-PSFMessage -Message "Setting partition style to 'GPT'" -Level Verbose
            $PartitionStyle = 'GPT'
        }
    }

    process {
        # Test if there are any errors
        if (Test-PSFFunctionInterrupt) { return }

        Invoke-PSFCommand -ComputerName $computer -Credential $Credential -ScriptBlock {
            param($p1)
            $disk = Get-Disk | Where-Object {$_.Location -eq $p1}
            if (-not $disk) {
                $null = Mount-DiskImage -ImagePath $p1
                $disk = Get-Disk | Where-Object {$_.Location -eq $p1}
            }

            if ($disk.PartitionStyle -eq 'RAW') {
                Initialize-Disk -Number $disk.Number -PartitionStyle GPT -ErrorAction SilentlyContinue
            }


            return $d1
        } -ArgumentList $Path

        if ($PSCmdlet.ShouldProcess($disk, "Initializing disk")) {
            # Check if the disk is already initialized
            if ($disk.PartitionStyle -eq 'RAW') {
                try {
                    Write-PSFMessage -Message "Initializing disk $disk" -Level Verbose
                    $partition = Invoke-PSFCommand -ComputerName $computer -Credential $Credential -ScriptBlock {
                        param($p1)
                        $null = Initialize-Disk -Number $p1.Number -PartitionStyle GPT -ErrorAction SilentlyContinue | New-Partition -DiskNumber $disk.Number -UseMaximumSize | Format-Volume -Partition $partition -FileSystem NTFS -NewFileSystemLabel "PSDatabaseClone" -AllocationUnitSize $AllocationUnitSize -Confirm:$false
                    } -ArgumentList $disk
                }
                catch {
                    Stop-PSFFunction -Message "Couldn't initialize disk" -Target $disk -ErrorRecord $_ -Continue
                }
            }
        }

        if ($accessPath -And $PSCmdlet.ShouldProcess($disk, "Assigning access path")) {
            # Create the partition, set the drive letter and format the volume
            try {
                $null = Invoke-PSFCommand -ComputerName $computer -Credential $Credential -ScriptBlock {
                    param($p1, $p2)
                    $partition = Get-Partition -Disk $p1 | Where-Object {$_.Type -ne "Reserved"} | Select-Object -First 1

                    if (-not (Test-Path -Path $p2)) {
                        New-Item -ItemType Directory -Path $p2 -Force
                    }

                    # Create an access path for the disk
                    $null = Add-PartitionAccessPath -DiskNumber $p1.Number -PartitionNumber $partition.PartitionNumber -AccessPath $p2 -ErrorAction SilentlyContinue
                } -ArgumentList $disk, $accessPath
            }
            catch {
                # Dismount the drive
                #Dismount-DiskImage -DiskImage $Path

                Stop-PSFFunction -Message "Couldn't create the partition" -Target $disk -ErrorRecord $_ -Continue
            }
        }
    }

    end {
        # Test if there are any errors
        if (Test-PSFFunctionInterrupt) { return }

        Write-PSFMessage -Message "Finished mounting disk(s)" -Level Verbose
    }

}
