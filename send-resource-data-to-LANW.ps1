#Connects to the Azure environment
Param(
    [string] $AppID,
    [string] $AppKey,
    [string] $SubscriptionID,
    [string] $WorkSpaceId,
    [string] $PrimaryKey
)


#########----> Setup Azure Environment
$TenantID = ""
$tablename = "Resources_with_Bypass_Governance_Policy_Tag"


#########----> Setting TLS Protocol
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12


#########----> Connect Azure Environment

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
    Connect-AzAccount -Tenant $TenantID -Credential $Credential -ServicePrincipal  | Out-Null
    Select-AzSubscription $SubscriptionID -Tenant $TenantID | Out-Null
    Write-Output "connection established"
}

Initialize-EnvironmentConnection -TenantID $TenantID -SubscriptionID $SubscriptionID -AppID $AppID -AppKey $AppKey

Select-AzSubscription "" -Tenant "" | Out-Null ##
Select-AzSubscription "" -Tenant "" | Out-Null ##
Select-AzSubscription "" -Tenant "" | Out-Null ##
Select-AzSubscription "" -Tenant "" | Out-Null ##
Select-AzSubscription "" -Tenant "" | Out-Null ##
Select-AzSubscription "" -Tenant "" | Out-Null ##


#########----> Run Query
Write-Output "Fetching Data"

try{

    # Search-AzGraph -Query "resources | extend tagsString=tostring(tags) | project id,ResourceName=name,resourceGroup,type,location,tags,subscriptionId | summarize TotalResourcesCount=count(),UntaggedResourcesCount=countif((isnull(tags['ESG_Grouping'])) and (isnull(tags['ESG_grouping'])) and (isnull(tags['eSG_Grouping']))),TaggedResourcesCount=countif((isnotnull(tags['ESG_Grouping'])) or (isnotnull(tags['ESG_grouping'])) or (isnotnull(tags['eSG_Grouping']))) by subscriptionId | join kind = leftouter( ResourceContainers | where type == 'microsoft.resources/subscriptions' | where name contains 'ESG_UAT' or name contains 'ESG_Prod' or name contains 'ESG_Non-Prod' or name contains 'CarbonDelta_Non-Prod' or name contains 'DataPlatform_Non-Prod' or name contains 'DataPlatform_Prod' | project SubscriptionName=name, subscriptionId) on subscriptionId | project SubscriptionName,TotalResourcesCount,UntaggedResourcesCount,TaggedResourcesCount | where isnotempty(SubscriptionName) | sort by SubscriptionName desc" | Export-Csv ./azgraphreult.csv -NoTypeInformation
    #$output=Search-AzGraph -Query "resources | extend tagsString=tostring(tags) | project id,ResourceName=name,resourceGroup,type,location,tags,subscriptionId | summarize TotalResourcesCount=count(),UntaggedResourcesCount=countif((isnull(tags['ESG_Grouping'])) and (isnull(tags['ESG_grouping'])) and (isnull(tags['Esg_grouping'])) and (isnull(tags['esg_grouping'])) and (isnull(tags['eSG_Grouping']))), TaggedResourcesCount=countif((isnotnull(tags['ESG_Grouping'])) or (isnotnull(tags['ESG_grouping'])) or (isnotnull(tags['Esg_grouping'])) or (isnotnull(tags['esg_grouping'])) or (isnotnull(tags['eSG_Grouping'])))  by subscriptionId | join kind = leftouter( ResourceContainers | where type == 'microsoft.resources/subscriptions' | where name contains 'ESG_UAT' or name contains 'ESG_Prod' or name contains 'ESG_Non-Prod' or name contains 'CarbonDelta_Non-Prod' or name contains 'DataPlatform_Non-Prod' or name contains 'DataPlatform_Prod' | project SubscriptionName=name, subscriptionId) on subscriptionId | project SubscriptionName,TotalResourcesCount,UntaggedResourcesCount,TaggedResourcesCount | where isnotempty(SubscriptionName) | sort by SubscriptionName desc"
    $output=Search-AzGraph -Query "resources | extend tagsString=tostring(tags) | where (isnotnull(tags['BypassGovernancePolicy'])) | project id,ResourceName=name,resourceGroup,type,location,tags,subscriptionId | project ResourceName,resourceGroup,type,location,tags,subscriptionId | join kind = leftouter( ResourceContainers | where type == 'microsoft.resources/subscriptions' | where name contains 'ESG_UAT' or name contains 'ESG_Prod' or name contains 'ESG_Non-Prod' or name contains 'CarbonDelta_Non-Prod' or name contains 'DataPlatform_Non-Prod' or name contains 'DataPlatform_Prod' | project SubscriptionName=name, subscriptionId) on subscriptionId | project SubscriptionName,ResourceName,resourceGroup,type,location,tags | where isnotempty(SubscriptionName) | sort by SubscriptionName desc" -First 1000
    $queryOutput = $output | ForEach-Object {
    [PSCustomObject]@{
        "Subscription Name" = $_.SubscriptionName
        "Resource Name" = $_.ResourceName
        "Resource group" = $_.resourceGroup
        "Resource Type" = $_.type
        "Resource Location" = $_.location
        "Resource tags" = $_.tags -join ','
    }
}
$queryOutput | export-csv ./azgraphreult.csv -force -notypeinformation
# $queryOutput

}
catch {

    Write-Output " Error : Unable to run query : $_"
    break
    return
}



#########----> Push to Log Analytics

Write-Output "Pushing to Log Analytics"

$sharedKey = $PrimaryKey
$customerId = $WorkSpaceId

# Specify the name of the record type that you'll be creating
$logType = $tablename

# Optional name of a field that includes the timestamp for the data. If the time field is not specified, Azure Monitor assumes the time is the message ingestion time
$TimeStampField = ""

#CSV Operation
$csv_ = Import-Csv ./azgraphreult.csv
$json = ConvertTo-Json $csv_
#$json

# Create the function to create the authorization signature
Function Build-Signature ($customerId, $sharedKey, $date, $contentLength, $method, $contentType, $resource)
{
    $xHeaders = "x-ms-date:" + $date
    $stringToHash = $method + "`n" + $contentLength + "`n" + $contentType + "`n" + $xHeaders + "`n" + $resource

    $bytesToHash = [Text.Encoding]::UTF8.GetBytes($stringToHash)
    $keyBytes = [Convert]::FromBase64String($sharedKey)

    $sha256 = New-Object System.Security.Cryptography.HMACSHA256
    $sha256.Key = $keyBytes
    $calculatedHash = $sha256.ComputeHash($bytesToHash)
    $encodedHash = [Convert]::ToBase64String($calculatedHash)
    $authorization = 'SharedKey {0}:{1}' -f $customerId,$encodedHash
    return $authorization
}

# Create the function to create and post the request
Function Post-LogAnalyticsData($customerId, $sharedKey, $body, $logType)
{
    $method = "POST"
    $contentType = "application/json"
    $resource = "/api/logs"
    $rfc1123date = [DateTime]::UtcNow.ToString("r")
    $contentLength = $body.Length
    $signature = Build-Signature `
        -customerId $customerId `
        -sharedKey $sharedKey `
        -date $rfc1123date `
        -contentLength $contentLength `
        -method $method `
        -contentType $contentType `
        -resource $resource
    $uri = "https://" + $customerId + ".ods.opinsights.azure.com" + $resource + "?api-version=2016-04-01"

    $headers = @{
        "Authorization" = $signature;
        "Log-Type" = $logType;
        "x-ms-date" = $rfc1123date;
        "time-generated-field" = $TimeStampField;
    }

    $response = Invoke-WebRequest -Uri $uri -Method $method -ContentType $contentType -Headers $headers -Body $body -UseBasicParsing
    return $response.StatusCode

}

# Submit the data to the API endpoint
Post-LogAnalyticsData -customerId $customerId -sharedKey $sharedKey -body ([System.Text.Encoding]::UTF8.GetBytes($json)) -logType $logType

Write-Output "Data Push Completed"

sleep 2

Remove-Item ./azgraphreult.csv
