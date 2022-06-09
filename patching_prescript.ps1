<#
.SYNOPSIS
 Barebones script for Update Management Pre/Post

.DESCRIPTION
  This script is intended to be run as a part of Update Management pre/post-scripts.
  It requires the Automation account's system-assigned managed identity.

.PARAMETER SoftwareUpdateConfigurationRunContext
  This is a system variable which is automatically passed in by Update Management during a deployment.
#>

param(
    [string]$SoftwareUpdateConfigurationRunContext
)

#region BoilerplateAuthentication
# Ensures you do not inherit an AzContext in your runbook
Disable-AzContextAutosave -Scope Process

# Connect to Azure with system-assigned managed identity
$AzureContext = (Connect-AzAccount -Identity).context

# set and store context
$AzureContext = Set-AzContext -SubscriptionName $AzureContext.Subscription -DefaultProfile $AzureContext
#endregion BoilerplateAuthentication

#If you wish to use the run context, it must be converted from JSON
$context = ConvertFrom-Json $SoftwareUpdateConfigurationRunContext
#Access the properties of the SoftwareUpdateConfigurationRunContext
$vmIds = $context.SoftwareUpdateConfigurationSettings.AzureVirtualMachines | Sort-Object -Unique
$runId = $context.SoftwareUpdateConfigurationRunId

$AutomationResource = Get-AzResource -ResourceType Microsoft.Automation/AutomationAccounts
foreach ($Automation in $AutomationResource)
{
    $Job = Get-AzAutomationJob -ResourceGroupName $Automation.ResourceGroupName -AutomationAccountName $Automation.Name -Id $PSPrivateMetadata.JobId.Guid -ErrorAction SilentlyContinue
    if(!([string]::IsNullOrEmpty($Job)))
    {
        $ResourceGroup = $Job.ResourceGroupName
        $AutomationAccount = $Job.AutomationAccountName
        break;
    }
}

#Create variable named after this run so it can be retrieved
New-AzAutomationVariable -ResourceGroupName $ResourceGroup -AutomationAccountName $AutomationAccount -Name $runId -Value "" -Encrypted $false

$updatedMachines = @()
$startableStates = "stopped","stopping", "deallocated", "deallocating"
$jobIDs= New-Object System.Collections.Generic.List[System.Object]


$vmIds | ForEach-Object {
    $vmId = $_
    $split = $vmId -split "/";
    $subscriptionId = $split[2];
    $rg = $split[4];
    $name = $split[8];
    Write-Output ("Subscription Id = " + $subscriptionId)
    $mute = Select-AzSubscription -SubscriptionId $subscriptionId
    $vm = Get-AzVM -ResourceGroupName $rg -Name $name -Status
    $state = ($vm.Statuses[1].Displaystatus -split " ")[1]
    if($state -in $startableStates){
        Write-Output "Starting '$($name)' ..."
        $updatedMachines += $vmId
        $newJob = Start-ThreadJob -ScriptBlock { param($resource,$vmname) Start-azVM -ResourceGroupName $resource -Name $vmname} -ArgumentList $rg,$name
        $jobIDs.Add($newJob.Id)
    }else{
        Write-Output ($name + ": no ation taken. State: " + $state)
    }
}

$updatedMachinesCommaSeperated = $updatedMachines -join "," 
#Wait until all machines have finished starting before proceeding to the Update Deployment 
$jobsList = $jobIDs.ToArray() 
if ($jobsList) 
{ 
    Write-Output "Waiting for machines to finish starting..." 
    Wait-Job -Id $jobsList 
} 
 
foreach($id in $jobsList) 
{ 
    $job = Get-Job -Id $id 
    if ($job.Error) 
    { 
        Write-Output $job.Error 
    } 
 
} 

Write-output $updatedMachinesCommaSeperated 
#Store output in the automation variable 
Set-AutomationVariable –Name $runId -Value $updatedMachinesCommaSeperated
