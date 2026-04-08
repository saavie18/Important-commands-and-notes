#!/usr/bin/pwsh

Param(
    [string] $TenantID,
    [string] $AppID,
    [string] $AppKey,
    [string] $SubscriptionID
)

# Mail
$from = ""
$to = ""

$subject = "Daily S&C Azure VM Patching Status Report"
$MailDomain = ""

$ApiKey = $env:MAILGUN_API_KEY
if ([string]::IsNullOrWhiteSpace($ApiKey)) {
    Write-Error "Mailgun API key not provided. Set MAILGUN_API_KEY env var (e.g. from Azure Key Vault task)."
    exit 1
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Set-Location -Path $PSScriptRoot

# Connect Azure Environment

function Initialize-EnvironmentConnection {
    Param (
        $TenantID,
        $SubscriptionID,
        $AppID,
        $AppKey
    )

    Write-Output "call fn() -> Initialize-EnvironmentConnection"
    Install-Module Az.Accounts, Az.Storage, Az.Compute, Az.Resources, Az.MonitoringSolutions, Az.OperationalInsights, Az.ResourceGraph -Force -AllowClobber -Confirm:$false -AcceptLicense
    Import-Module Az.Accounts, Az.Storage, Az.Compute, Az.Resources, Az.MonitoringSolutions, Az.OperationalInsights, Az.ResourceGraph -Force

    Write-Output "attempt to connect to the tenant, select subscription"
    $Password = $AppKey | ConvertTo-SecureString -AsPlainText -Force
    $Credential = New-Object System.Management.Automation.PSCredential($AppID, $Password)
    Connect-AzAccount -Tenant $TenantID -Credential $Credential -ServicePrincipal | Out-Null
    Select-AzSubscription $SubscriptionID -Tenant $TenantID | Out-Null
    Write-Output "connection established"
}

Initialize-EnvironmentConnection -TenantID $TenantID -SubscriptionID $SubscriptionID -AppID $AppID -AppKey $AppKey

Select-AzSubscription "" -Tenant $TenantID | Out-Null 
Select-AzSubscription "" -Tenant $TenantID | Out-Null 
Select-AzSubscription "" -Tenant $TenantID | Out-Null 

$filePath1 = "Failed_Patching_on_VMs.csv"
$filePath2 = "No_Patching_on_VMs.csv"

Write-Output "Fetching Data"

try {

    $allPatching = Search-AzGraph -Query "patchinstallationresources | where type =~ 'microsoft.compute/virtualmachines/patchinstallationresults' or type =~ 'microsoft.hybridcompute/machines/patchinstallationresults' | where properties.lastModifiedDateTime > ago(24h) | where properties.status in~ ('Succeeded','Failed','CompletedWithWarnings','InProgress') | parse id with * 'achines/' resourceName '/patchInstallationResults/' * | join kind = leftouter (ResourceContainers | where type == 'microsoft.resources/subscriptions' | where name contains 'xxx_Prod' or name contains 'xxx_Non-Prod' or name contains 'xx_UAT' | project SubscriptionName = name, subscriptionId) on subscriptionId | where isnotempty(SubscriptionName) | project VMName=resourceName, SubscriptionName, PatchingStatus=properties.status, PatchingTime=properties.startDateTime, Error=properties.errorDetails.details" -First 1000
    if (-not $allPatching) { $allPatching = @() }
    $successCount = ($allPatching | Where-Object { $_.PatchingStatus -eq 'Succeeded' } | Measure-Object).Count
    $failedCount  = ($allPatching | Where-Object { $_.PatchingStatus -ne 'Succeeded' } | Measure-Object).Count

    $resourceoutput1 = $allPatching | Where-Object { $_.PatchingStatus -ne 'Succeeded' }
    $queryOutputforpatchingfailure = $resourceoutput1 | ForEach-Object {
        $rawDetails = $_.Error

        if ($null -ne $rawDetails) {
            if ($rawDetails -is [string]) {
                try {
                    $details = $rawDetails | ConvertFrom-Json
                } catch {
                    $details = @($rawDetails)
                }
            } else {
                $details = @($rawDetails)
            }

            $msgList = foreach ($d in $details) {
                if ($d -is [string]) {
                    $d.Trim()
                } elseif ($d.PSObject.Properties.Name -contains 'message' -or $d.PSObject.Properties.Name -contains 'Message') {
                    $m = $d.message
                    if (-not $m) { $m = $d.Message }
                    $c = $d.code
                    if (-not $c) { $c = $d.Code }
                    if ($c) { "$m ($c)" } else { $m }
                } else {
                    ($d | ConvertTo-Json -Depth 3)
                }
            }

            $errorText = ($msgList | Where-Object { $_ -and $_.Trim() } ) -join '; '
        } else {
            $errorText = ''
        }

        [PSCustomObject]@{
            "VM Name"         = $_.VMName
            "Subscription Name" = $_.SubscriptionName
            "Patching Status" = $_.PatchingStatus
            "Patching Time"   = $_.PatchingTime
            "Error Message"   = $errorText
        }
    }
    $queryOutputforpatchingfailure | Export-Csv -Path $filePath1 -NoTypeInformation
    $resourceoutput2 = Search-AzGraph -Query "resources | where type =~ 'microsoft.compute/virtualmachines' | extend os = tolower(properties.storageProfile.osDisk.osType) | extend patchSettingsObject = iff(os == 'windows', properties.osProfile.windowsConfiguration.patchSettings, properties.osProfile.linuxConfiguration.patchSettings) | extend conf = tostring(patchSettingsObject.patchMode) | extend conf = iff(conf =~ 'AutomaticByPlatform',     iff(isnotnull(patchSettingsObject.automaticByPlatformSettings.bypassPlatformSafetyChecksOnUserSchedule)         and patchSettingsObject.automaticByPlatformSettings.bypassPlatformSafetyChecksOnUserSchedule == true,         'Customer Managed Schedules',         'Azure Managed - Safe Deployment'),     conf) | extend patchOrchestration =     iff(conf == 'AutomaticByOS', 'Windows Automatic Update',     iff(conf == 'Customer Managed Schedules', 'Customer Managed Schedules',     iff(conf == 'Azure Managed - Safe Deployment', 'Azure Managed - Safe Deployment',     iff(conf == 'ImageDefault', 'Image Default',     iff(conf == 'Manual', 'Manual', 'N/A'))))) | extend imageId = tostring(properties.storageProfile.imageReference.id) | extend imageName = iff(isnotempty(imageId), split(imageId, '/')[10], '') | extend fallbackImageName = strcat(     tostring(properties.storageProfile.imageReference.publisher), ':',     tostring(properties.storageProfile.imageReference.offer), ':',     tostring(properties.storageProfile.imageReference.sku), ':',     tostring(properties.storageProfile.imageReference.version) ) | extend finalImageName = iff(isnotempty(imageName), imageName, fallbackImageName)  | join kind = leftouter (     ResourceContainers     | where type == 'microsoft.resources/subscriptions'     | where name contains '' or name contains '' or name contains ''     | project SubscriptionName = name, subscriptionId ) on subscriptionId | where isnotempty(SubscriptionName) | project resourceId = id,           subscriptionId,           resourceGroup,           resourceName = name,           location,           operatingSystem = os,           SubscriptionName,           patchOrchestration,           finalImageName | extend VMname = split(resourceId, '/')[8] | project VMname, SubscriptionName, resourceGroup, operatingSystem, patchOrchestration, finalImageName | where resourceGroup !contains 'xx' and resourceGroup !contains 'xx' | where VMname !contains 'yy' and VMname !contains 'zzz' and VMname !contains 'xxx' and VMname !contains 'yy' | where resourceGroup !contains 'xxx' | where patchOrchestration !contains 'Customer Managed Schedules' | project VMname,SubscriptionName,resourceGroup,operatingSystem | order by SubscriptionName" -First 1000
    $queryOutputfornopatching = $resourceoutput2 | ForEach-Object {
        [PSCustomObject]@{
            "VM Name" = $_.VMname
            "Subscription Name" = $_.SubscriptionName
            "Resource group" = $_.resourceGroup
            "Operating System" = $_.operatingSystem -join ','
        }
    }
    $queryOutputfornopatching | Export-Csv -Path $filePath2 -NoTypeInformation
    $missingCount = ($queryOutputfornopatching | Measure-Object).Count
    if (-not $successCount) { $successCount = 0 }
    if (-not $failedCount)  { $failedCount  = 0 }
    if (-not $missingCount) { $missingCount = 0 }
}
catch {
    Write-Output " Error : Unable to run query : $_"
    break
    return
}

$EmailBody = "<html><body style='font-family:Segoe UI, Arial, sans-serif; padding:16px;'>"
$EmailBody += "<h2 style='margin-top:0;'>Azure VM Patch Summary (Last 24 Hours)</h2>"
$EmailBody += "<p style='font-size:14px; margin:8px 0 18px 0;'><strong>Successfully Patched:</strong> $successCount &nbsp;&nbsp; | &nbsp;&nbsp; <strong>Failed Patches:</strong> $failedCount &nbsp;&nbsp; | &nbsp;&nbsp; <strong>Missing Patching:</strong> $missingCount</p>"

if ($failedCount -gt 0 -and $queryOutputforpatchingfailure -and $queryOutputforpatchingfailure.Count -gt 0) {
    $EmailBody += "<h3>Failed Patching Details</h3>"
    $EmailBody += "<table border='1' style='border-collapse: collapse; width: 100%;'>"
    $EmailBody += "<tr><th>VM Name</th><th>Subscription Name</th><th>Status</th><th>Patching Time</th><th>Error</th></tr>"

    foreach ($r in $queryOutputforpatchingfailure) {
        $EmailBody += "<tr><td>$($r.'VM Name')</td><td>$($r.'Subscription Name')</td><td>$($r.'Patching Status')</td><td>$($r.'Patching Time')</td><td>$($r.'Error Message')</td></tr>"
    }

    $EmailBody += "</table><br>"
}

if ($missingCount -gt 0 -and $queryOutputfornopatching -and $queryOutputfornopatching.Count -gt 0) {
    $EmailBody += "<h3>VMs With No Patching Enabled</h3>"
    $EmailBody += "<table border='1' style='border-collapse: collapse; width: 100%;'>"
    $EmailBody += "<tr><th>VM Name</th><th>Subscription</th><th>Resource Group</th><th>OS</th></tr>"

    foreach ($r in $queryOutputfornopatching) {
        $EmailBody += "<tr><td>$($r.'VM Name')</td><td>$($r.'Subscription Name')</td><td>$($r.'Resource group')</td><td>$($r.'Operating System')</td></tr>"
    }

    $EmailBody += "</table><br>"
}

if ($failedCount -eq 0 -and $missingCount -eq 0) {
    $EmailBody += "<p style='color:#cfcfcf;'>All VMs patched successfully in the last 24 hours.</p>"
}

$EmailBody += "</body></html>"

$attachments = @()
if (Test-Path $filePath1) { $attachments += (Get-Item $filePath1) }
if (Test-Path $filePath2) { $attachments += (Get-Item $filePath2) }

$authHeader = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("api:$ApiKey"))
$headers = @{ Authorization = $authHeader }
$url = "https://api.mailgun.net/v3/$MailDomain/messages"
$formData = @{
    from    = $from
    to      = $to
    subject = $subject
    html    = $EmailBody
}
if ($attachments.Count -gt 0) { $formData.attachment = $attachments }

try {
    $response = Invoke-RestMethod -Uri $url -Method Post -Headers $headers -Form $formData -ErrorAction Stop
    Write-Output "Mailgun response: $response"
} catch {
    Write-Error "Failed to send email: $_"
}

Write-Output "Script completed."
