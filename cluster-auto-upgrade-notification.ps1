# Setting TLS Protocol
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Prevent PowerShell from trying to use system proxy (prevents NonInteractive prompts)
try {
    [System.Net.WebRequest]::DefaultWebProxy = $null
} catch {
    Write-Warning "Could not disable DefaultWebProxy: $_"
}

$env:HTTP_PROXY  = ''
$env:HTTPS_PROXY = ''
$env:http_proxy  = ''
$env:https_proxy = ''

# Variables

$file = Get-Content "<txt_file_path>"

# Email details
$from = ""
$to = ""
$cc = ""
$subject = "IMPORTANT - S&C - ACTION REQUIRED : NON-PROD : AKS CLUSTER WITHOUT AUTOMATIC UPGRADE"
$maildomain = "xxx.com"
$apikey = $env:MAILGUN_API_KEY

# Initialize an array to store clusters
$AllAKSClusterNames = @()

# Authentication

# Connect Azure Environment
Write-Output "Installing Azure PowerShell modules..."
Install-Module Az.Accounts, Az.Storage, Az.Compute, Az.Resources, Az.MonitoringSolutions, Az.OperationalInsights, Az.ResourceGraph -Force -AllowClobber -Confirm:$false -AcceptLicense
Import-Module Az.Accounts, Az.Storage, Az.Compute, Az.Resources, Az.MonitoringSolutions, Az.OperationalInsights, Az.ResourceGraph -Force

Write-Output "Azure context is already established by Azure DevOps task"
Write-Output "Current Azure context:"
Get-AzContext | Select-Object Account, Subscription, Tenant | Format-List

$Tenant = $env:AZURE_TENANT_ID
if (-not $Tenant) {
    $Tenant = $env:tenantId
}
if (-not $Tenant) {
    try {
        $Tenant = (Get-AzContext).Tenant.Id
    } catch {
        throw "Tenant ID not found. Ensure AzureCLI task is configured with addSpnToEnvironment: true or Azure PowerShell context is available."
    }
}

# Get service principal credentials from Azure DevOps environment variables
# These are set by AzureCLI task with addSpnToEnvironment: true
$ClientId = $env:AZURE_CLIENT_ID
if (-not $ClientId) {
    $ClientId = $env:servicePrincipalId
}
$ClientSecret = $env:AZURE_CLIENT_SECRET
if (-not $ClientSecret) {
    $ClientSecret = $env:servicePrincipalKey
}

if (-not $ClientId -or -not $ClientSecret) {
    throw "Service principal credentials not found in environment variables. Ensure AzureCLI task is configured with addSpnToEnvironment: true."
}

$Resource = "https://management.azure.com/"
$RequestAccessTokenUri = "https://login.microsoftonline.com/$Tenant/oauth2/token"
$Body = "grant_type=client_credentials&resource=$Resource&client_id=$ClientId&client_secret=$ClientSecret"

# Acquire access token (non-interactive)
Try {
    $Token = Invoke-RestMethod `
        -Method Post `
        -Uri $RequestAccessTokenUri `
        -Body $Body `
        -ContentType 'application/x-www-form-urlencoded' `
        -TimeoutSec 60 `
        -ErrorAction Stop `
        -Proxy $null
}
Catch {
    Write-Error "Failed to acquire access token: $_"
    throw
}

$Headers = @{ Authorization = "$($Token.token_type) $($Token.access_token)" }

# Query AKS APIs
foreach ($aksurl in $file) {
    Try {
        $response = Invoke-RestMethod `
            -Method Get `
            -Uri $aksurl `
            -Headers $Headers `
            -TimeoutSec 60 `
            -ErrorAction Stop `
            -Proxy $null
    }
    Catch {
        Write-Warning "Failed to query $aksurl : $_"
        continue
    }

    $obj2 = ($response | Get-Member -MemberType NoteProperty).Name
    $result = foreach ($item in $obj2) {
        $response.$item | Select-Object `
            @{n="AKSClusterName"; e={ $_.name }},
            @{n="ClusterId"; e={ $_.id }},
            @{n="AutoUpgrade"; e={
                if ([string]::IsNullOrEmpty($_.properties.autoUpgradeProfile.upgradeChannel) -and
                    -not [string]::IsNullOrEmpty($_.name)) { "none" }
                else { $_.properties.autoUpgradeProfile.upgradeChannel }
            }},
            @{n="CurrentClusterVersion"; e={ $_.properties.currentKubernetesVersion }}
    }

    $AllAKSClusterNames += $result
}

# Kubernetes EOL data
$clustercount = 0
$CurrentDate = Get-Date -Format "yyyy-MM-dd"
$kubernetesversion = "https://endoflife.date/api/azure-kubernetes-service.json"

Try {
    $kubernetesversionresponse = Invoke-RestMethod `
        -Method Get `
        -Uri $kubernetesversion `
        -TimeoutSec 60 `
        -ErrorAction Stop `
        -Proxy $null
}
Catch {
    Write-Error "Failed to retrieve Kubernetes EOL data: $_"
    throw
}

$kubernetesversionresult = $kubernetesversionresponse | ForEach-Object {
    [PSCustomObject]@{
        Version        = $_.cycle
        Date           = $_.eol
        Formatted_Date = [datetime]::ParseExact($_.eol,'yyyy-MM-dd',$null).ToString('dd-MM-yyyy')
        EOLReached     = if ($_.eol -gt $CurrentDate) { "No" } else { "Yes" }
    }
}

# ---------------- EMAIL LOGIC (UNCHANGED) ----------------

if ($AllAKSClusterNames.Count -gt 0) {

    $EmailBody = "<html><body>"
    $EmailBody += "<h2 style='color:red'>Devops team , please enable auto upgrade on below mentioned AKS clusters in xxx Subscription : </h2>"
    $EmailBody += "<table style='border-collapse: collapse; width: 100%; border: 1px solid black;'>"
    $EmailBody += "<tr><th>AKS ClusterName</th><th>Resource Group</th><th>Current AKS Cluster Version</th><th>EOL Date for AKS Version</th></tr>"

    foreach ($akscluster in $AllAKSClusterNames) {
        if ($akscluster.AutoUpgrade -eq "none") {
            $clustercount++
            $rg = ($akscluster.ClusterId -split '/')[4]
            $shortVersion = $akscluster.CurrentClusterVersion.Substring(0,$akscluster.CurrentClusterVersion.LastIndexOf('.'))
            $eol = foreach ($k in $kubernetesversionresult) { if ($k.Version -eq $shortVersion) { $k.Formatted_Date; break } }
            $reached = foreach ($k in $kubernetesversionresult) { if ($k.Version -eq $shortVersion) { $k.EOLReached; break } }

            if ($reached -eq "Yes") {
                $EmailBody += "<tr bgcolor='red'><td>$($akscluster.AKSClusterName)</td><td>$rg</td><td>$($akscluster.CurrentClusterVersion)</td><td>$eol</td></tr>"
            } else {
                $EmailBody += "<tr><td>$($akscluster.AKSClusterName)</td><td>$rg</td><td>$($akscluster.CurrentClusterVersion)</td><td>$eol</td></tr>"
            }
        }
    }

    $EmailBody += "</table>"
    $EmailBody += "<p style='color:red'>Note : Please check the column 'EOL Date for AKS Version' and upgrade clusters reaching EOL.</p>"
    $EmailBody += "</body></html>"

    $idpass = "api:$apikey"
    $basicauth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($idpass))
    $headers = @{ Authorization = "Basic $basicauth" }
    $url = "https://api.mailgun.net/v2/$maildomain/messages"
    $body = @{
        from    = $from
        to      = $to
        cc      = $cc
        subject = $subject
        html    = $EmailBody
    }

    if ($clustercount -ne 0) {
        Invoke-RestMethod `
            -Uri $url `
            -Method Post `
            -Headers $headers `
            -Body $body `
            -TimeoutSec 60 `
            -ErrorAction Stop `
            -Proxy $null
    } else {
        Write-Output "All AKS clusters in xxx Subscription are enabled for automatic upgrades"
    }
}
else {
    Write-Output "No AKS Clusters found in the API response"
}

# ---------------- END SCRIPT ----------------
