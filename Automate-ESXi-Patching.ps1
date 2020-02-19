
function create-Baseline
{
    [CmdletBinding()]
    param
    (
    [Parameter(Mandatory=$true)]
    [string]$BaselineName,

    [Parameter(Mandatory=$true)]
    [datetime]$toDate
    )

    do
    {
        #checking if baseline exist
        try
        {
            $baseline = get-patchBaseline -name $BaselineName            

        }

        catch
        {
            #creating baseline
            Write-host "Baseline Does not exist"
            Write-host "Creating Baseline"

            $patches = Get-Patch -before $toDate
            $newPatchBaseline = New-PatchBaseline -static -Name $BaselineName -IncludePatch $patches
        }

    }while ($baseline.name -ne $BaselineName)

    Write-host "Baseline name '$baselinename' Validated"

    return $baseline

}

function ValidateDate
{
    param([string]$date=$_)
    $result = 0
    [bool]$valid = $false
    if (!([DateTime]::TryParse($date, [ref]$result))){
        Write-Host "Your date $date was invalid. Please try again." -ForegroundColor Red
        $date = Read-Host "Please enter the date with the following format yyyy/mm/dd: "
        ValidateDate $date
    }
    else{
        $valid = $true
        Return $date
    }
}

function ValidateCluster
{
    [CmdletBinding()]
    param
    (
    [Parameter(Mandatory=$true)]
    [Object[]]$Baseline,

    [Parameter(Mandatory=$true)]
    [string]$clustername
    )

    #cluster name validation
    do
    {
        try
        {    
            if($input = $false)  
            {  
                $cluster= read-host "Please enter the cluster name:"
            }
            $cluster = get-cluster $clustername -ErrorAction Stop
            $hosts = $cluster| get-vmhost
            write-host "Cluster Validated"
            $input = $true
        }

        catch
        {
            write-host "Cluster does not exist. Please check and input again." -ForegroundColor Red
            $input = $false
        }
    }while ($input -ne $true)

    #ESXi version check
    $hostversions = $cluster | Get-VMHost | Select @{N="Version";E={$_.ExtensionData.Config.Product.version}} -unique

    if($hostversions.version.count -gt 1)
    {
        write-host "ESXi Version mismatch in the cluster. Please check and run the script again. stopping the script"
        exit
    }

    #check Admission Control Settings
    $admissionControl = $cluster.HAAdmissionControlEnabled
    
    if($admissionControl -eq $true)
    {
        $cluster | Set-Cluster -HAAdmissionControlEnabled:$false -Confirm:$false
        Write-Information "HA Admission control is set to disabled in the cluster" -InformationAction Continue
    }

    else
    {
        Write-Information "HA Admission control is already disabled in the cluster" -InformationAction Continue
    }
    
    return $true

}

function DisableAlarm
{
param([string]$VMhost=$_)

    #disable alarms for the host
    $alarmMgr = Get-View AlarmManager 
    $esx = Get-vmhost $VMhost 
    # To disable alarm actions 
    $alarmMgr.EnableAlarmActions($esx.Extensiondata.MoRef,$false)

}

function EnableAlarm
{
param([string]$VMhost=$_)

    #disable alarms for the host
    $alarmMgr = Get-View AlarmManager 
    $esx = Get-vmhost $VMhost 
    # To disable alarm actions 
    $alarmMgr.EnableAlarmActions($esx.Extensiondata.MoRef,$true)

}

function prevalidateHost
{
[CmdletBinding()]
    param
    (
    [Parameter(Mandatory=$true)]
    [object[]]$VMhost,

    [Parameter(Mandatory=$true)]
    [string]$baselinename
    )

    try
    {
        $baseline = get-baseline $baselinename
        $VMhost = get-vmhost $VMhost

        if(Get-Content 'ExcludeHosts.txt' | Select-String $VMHost)
        {
            write-Host "This host has been added to the Exclude List. Skipping $VMhost...!!!"
            return $false
        }
       
        # Attach baseline to all hosts in cluster
        Attach-Baseline -Entity $VMhost -Baseline $baseline -ErrorAction stop
        
        # Test compliance against all hosts in cluster
        Test-Compliance -Entity $VMhost -UpdateType HostPatch -Verbose -ErrorAction stop
        
        #check compliance
        $compliance = Get-Compliance -Entity (get-vmhost $VMhost) -Baseline $baseline
        
        if($compliance.status -eq 'Compliant')
        {
            write-host "Host is compliant with the baseline. No need to patch. Failing Host validation"
            return $false
        }

        #Copy patches to noncompliant hosts
        Copy-Patch -Entity $VMhost -Confirm:$false -ErrorAction stop

        return $true
    }
    catch
    {
        Write-Information "This host encountered a problem when applying the baseline. Please mark this host for manual update" -InformationAction Continue
        
        write-host $_.Exception.Message

        Write-Information "Adding to Exclude List" -InformationAction Continue

        Add-Content -path ExcludeHosts.txt -value "`n$VMhost"

        return $false

    }

}

function patchHost
{
[CmdletBinding()]
    param
    (
    [Parameter(Mandatory=$true)]
    [string]$VMhostname,

    [Parameter(Mandatory=$true)]
    [string]$baselinename
    )

    $baseline = get-baseline $baselinename
    $VMhost = get-vmhost $VMhostname

    while($VMhost.connectionstate -ne "Maintenance")
    {
        write-host "Host is not in maintenance mode"
        $maininput = read-host "Please press Enter after putting the host into maintenance mode:"
        $VMhost = get-vmhost $VMhost
    }

    try
    {
        $UpdateTask = Update-Entity -Baseline $baseline -Entity $VMhost -RunAsync -Confirm:$false -ErrorAction Stop

        while ($UpdateTask.PercentComplete -ne 100)
            {
                Write-Progress -Activity "Waiting for $VMhost to finish patch installation" -PercentComplete $UpdateTask.PercentComplete
                Start-Sleep -seconds 10
                write-host "waiting"
                $UpdateTask = Get-Task -id $UpdateTask.id
            }
        
        write-host "Server is Back up"    
     }
     catch
     {
        write-host "Remediate Task failed since vcenter timeout value exceeded. Checking state of host manually."

        $VMhost = Get-VMHost -Name $VMhost

        if($VMhost.ConnectionState -eq "NotResponding")
        {
            write-host "Host is currently rebooting"
            
            # Wait for server to reboot
            do {
            sleep 60
                $ServerState = (get-vmhost $VMhost).ConnectionState
                Write-Host "Waiting for Reboot …"
            }
            while ($ServerState -ne "Maintenance")

            write-host "Server is back up"

        }
        else
        {
            write-host "remediate task failed"
            
            do
            {
                $input = read-host "Please press 1 to go to next host or press 2 to remediate the host again"
            }
            while( ($input -eq 1) -or ($input -eq 2) )

            if($input -eq 1)
            {
                write-host "Adding host to exclude list"
                Add-Content -path ExcludeHosts.txt -value "`r`n$VMhost"
                return $false
            }
            elseif($input -eq 2)
            {
                patchHost -baselinename $baselineName -VMhost $VMhost
            }
            
        }        
     }

     #checking compliance
     $compliance = Get-Compliance -Entity (get-vmhost $VMhost) -Baseline $baseline
        
        if($compliance.status -eq 'Compliant')
        {
            write-host "Host is compliant with the baseline. Leaving Maintenance mode"
            return $true
        }

        else
        {
            write-host "Host is not compliance with the attached baseline : $baselinename. Please check this host manually"
            write-host "Adding host to exclude list"
            Add-Content -path ExcludeHosts.txt -value "`r`n$VMhost"
            return $false
        }

}

function checkSLP
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        [Object[]]$VMhost,

        [System.Management.Automation.CredentialAttribute()]
        $Credential
    )


   
        Get-VMHostService -VMHost $VMhost | where{$_.Key -eq 'TSM-SSH'} | Start-VMHostService -Confirm:$false -ErrorAction Stop
        $session = New-SSHSession -ComputerName $VMhost -Credential $Credential –AcceptKey
   
        $cmdsub = "chkconfig --list | grep slpd"
        
        write-host "beforeuhdgfoduhn"
        $output = Invoke-SSHCommand -SSHSession $session -Command $cmdSub | Select -ExpandProperty Output
        $output = $output.split()[-1]
        $output

        if($output -eq "off")
        {
            $cmdsub2 = @'

esxcli network firewall ruleset set -r CIMSLP -e 1;

chkconfig slpd on;

chkconfig --list | grep slpd;

/etc/init.d/slpd start

'@       

            Invoke-SSHCommand -SSHSession $session -Command $cmdSub2 | Select -ExpandProperty Output  
            Write-Host "SLP Successfully turned on"   

        }   
        
        if($output -eq "on")
        {
            Write-Host "SLP already turned on"
        
        } 

}


function validateESXiCred
{
[CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        [Object[]]$VMhost,

        [System.Management.Automation.CredentialAttribute()]
        $Credential

    )

    try
    {
       # write-host "inside function"
        $sshenable = get-VMHostService -VMHost $VMhost | where{$_.Key -eq 'TSM-SSH'} | Start-VMHostService -Confirm:$false -ErrorAction Stop
       # write-host "SSh on"
        $session = New-SSHSession -ComputerName $VMhost -Credential $Credential –AcceptKey -ErrorAction stop
       # write-host "SSession ok"
        return $true
    }
    catch
    {
        return $false
    }

}
################################################MAIN SCRIPT#########################################################

$initialTimeout = (Get-PowerCLIConfiguration -Scope Session).WebOperationTimeoutSeconds
Set-PowerCLIConfiguration -Scope Session -WebOperationTimeoutSeconds 1800000 -Confirm:$false
    
$date= read-host "Please enter date YYYY/MM/DD (example 2015/11/09):"
#$date= "2020-02-10"
$date = ValidateDate($date)

$baselineName = read-host "Please enter the Baseline Name : "
#$baselineName = "Test2"
$baseline = create-Baseline -BaselineName $baselineName -toDate $date -ErrorAction Stop

#validate cluster and return the hosts object
$cluster= read-host "Please enter the cluster name:"
#$cluster= "CLU-001"
$clusterValidated = validateCluster -Baseline $baseline -clustername $cluster

#get the hosts which are about to patch
$hosts = get-cluster $cluster | get-vmhost

#get-credentials for esxi host
write-host "Please enter username and password for ESXi hosts:"
$cred = Get-Credential

foreach($VMhost in $hosts)
{
    $result = prevalidateHost -baseline $baselineName -VMhost $VMhost

    if ($result -eq $false)
    {
        write-host "Host validation failed. Skipping Host $VMhost"
        continue
    }
    
    write-host "Disabling Alarms"    
    disableAlarm($VMhost)

    #set Maintenance Mode
    Set-VMHost $VMhost -State Maintenance -Confirm:$false -ErrorAction Inquire | Select-Object Name,State | Format-Table -AutoSize

    while($VMhost.State -ne [VMware.VimAutomation.ViCore.Types.V1.Host.VMHostState]::Maintenance)
    {
        sleep 5
        $VMhost = Get-VMHost -Name $VMhost
    }

    $remediateResult = patchHost -baselinename $baselineName -VMhost $VMhost.name

    if($remediateResult -eq $false)
    {
        $VMhost = Get-VMHost -Name $VMhost
        if($VMhost.connectionstate -eq "Maintenance")
        {
            read-host "The host failed to patch and currently in maintenance mode. press enter if you need to remove maintenance mode or press CTRL + C to exit"
            Set-VMHost $VMhost -State Connected -Confirm:$false -ErrorAction Inquire | Select-Object Name,State | Format-Table -AutoSize
            continue
        }
    }


    $validated = validateESXiCred -VMhost $VMhost.name -Credential $cred
    #validate ESXi credentials
    while($validated -ne $true)
    {
        $cred = Get-Credential
        $validated = validateESXiCred -VMhost $VMhost.name -Credential $cred         
          
    }
    

    #check SLP service and enable
    checkSLP -VMhost $VMhost.name -Credential $cred 
        
    Set-VMHost $VMhost -State Connected -Confirm:$false -ErrorAction Inquire | Select-Object Name,State | Format-Table -AutoSize
    #Sleep for 5 seconds for the datastores to come back up
    Start-Sleep -seconds 5

    write-host "Enabling Alarms" 
    enableAlarm($VMhost)
}

write-host "Patching $cluster Cluster is completed successfully." 
$exclude = get-content "ExcludeHosts.txt"

if($exclude)
{
    write-host "Below hosts had some issues with patching. Therefore please check and remediate manually." 
    $exclude
}








