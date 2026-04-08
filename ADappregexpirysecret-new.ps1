# Limit Microsoft Graph SDK function loading
$env:Graph_Sdk_SetCmdletExportMode = "Selective"

# Import required modules
Import-Module Microsoft.Graph.Applications -DisableNameChecking
Import-Module Microsoft.Graph.Users -DisableNameChecking
Import-Module Az.Accounts -DisableNameChecking
Import-Module Az.Storage -DisableNameChecking

# Reuse pipeline Az login (service connection): token for Microsoft Graph (same app as ARM context)
if (-not (Get-AzContext)) {
    throw "No Az context. Run from AzurePowerShell@5 with a service connection, or Connect-AzAccount first."
}
# Az 13.5+ returns PSSecureAccessToken; Connect-MgGraph needs the .Token (SecureString), not the wrapper object
$graphAccess = Get-AzAccessToken -ResourceTypeName MSGraph
Connect-MgGraph -AccessToken $graphAccess.Token

# Storage account & files
$resourceGroupName = ""
$storageAccountName = ""
$containerName = ""
$blobNames = @("file.csv", "Config.csv")
$localPath = ""

$storageAccount = Get-AzStorageAccount -ResourceGroupName $resourceGroupName -Name $storageAccountName
$storageAccountKey = (Get-AzStorageAccountKey -ResourceGroupName $resourceGroupName -Name $storageAccountName).Value[0]
$context = New-AzStorageContext -StorageAccountName $storageAccount.StorageAccountName -StorageAccountKey $storageAccountKey

# Secret expiration thresholds
$LimitExpirationDays = 30
$LimitExpirationDays1 = -1
$LimitExpirationDays2 = 0

$AllSecretsToExpire = @()
$AllSecretsAlreadyExpired = @()

foreach ($blobName in $blobNames) {
    $localFilePath = Join-Path -Path $localPath -ChildPath $blobName    
    Get-AzStorageBlobContent -Container $containerName -Blob $blobName -Destination $localFilePath -Context $context

    $csvData = Import-Csv -Path $localFilePath
    $ids = $csvData.id

    foreach ($objectid in $ids) {
        $objectidClean = $objectid.Trim().ToLower()
        Write-Output "Processing ObjectId: $objectidClean"

        try {
            $AppRegistration = Get-MgApplication -Filter "id eq '$objectidClean'"
            if (!$AppRegistration) {
                Write-Output "Application with ObjectId $objectidClean not found"
                continue
            }
        } catch {
            Write-Output "Error fetching application with ObjectId $objectidClean"
            continue
        }

        $AppDisplayName = $AppRegistration.DisplayName
        $AppId = $AppRegistration.AppId
        $AppObjectId = $AppRegistration.Id

        # Fetch and resolve owners using Microsoft Graph
        $owners = Get-MgApplicationOwner -ApplicationId $AppObjectId
        $resolvedOwners = @()

        foreach ($owner in $owners) {
            $ownerId = $owner.Id
            try {
                $directoryObject = Get-MgDirectoryObject -DirectoryObjectId $ownerId
                $props = $directoryObject.AdditionalProperties
                $odataType = $props.'@odata.type'

                switch ($odataType) {
                    "#microsoft.graph.user" {
                        $displayName = $props.displayName
                        $userPrincipalName = $props.userPrincipalName
                        if ($displayName -and $userPrincipalName) {
                            $resolvedOwners += "$displayName <$userPrincipalName>"
                        } elseif ($userPrincipalName) {
                            $resolvedOwners += $userPrincipalName
                        } else {
                            $resolvedOwners += "Unknown User <$ownerId>"
                        }
                    }
                    "#microsoft.graph.servicePrincipal" {
                        $spnName = $props.displayName
                        $resolvedOwners += "$spnName (Service Principal)"
                    }
                    default {
                        $resolvedOwners += "Unknown <$ownerId>"
                    }
                }
            } catch {
                $resolvedOwners += "Unknown <$ownerId>"
            }
        }

        $userPrincipalNames = if ($resolvedOwners.Count -gt 0) { $resolvedOwners -join ", " } else { "No Owner Assigned" }

        # Flattened Secret Expiry Collection
        foreach ($cred in $AppRegistration.PasswordCredentials + $AppRegistration.KeyCredentials) {
            if (
                $cred.EndDateTime -lt (Get-Date).AddDays($LimitExpirationDays) -and
                $cred.EndDateTime -gt (Get-Date).AddDays($LimitExpirationDays2) -and
                $cred.KeyId -and $cred.EndDateTime
            ) {
                $AllSecretsToExpire += [PSCustomObject]@{
                    App        = $AppDisplayName
                    AppId      = $AppId
                    Type       = $cred.GetType().Name
                    SecretId   = $cred.KeyId
                    EndDate    = $cred.EndDateTime
                    SecretName = $cred.DisplayName
                    Owner      = $userPrincipalNames
                }
            }
            elseif (
                $cred.EndDateTime -lt (Get-Date).AddDays($LimitExpirationDays1) -and
                $cred.KeyId -and $cred.EndDateTime
            ) {
                $AllSecretsAlreadyExpired += [PSCustomObject]@{
                    App        = $AppDisplayName
                    AppId      = $AppId
                    Type       = $cred.GetType().Name
                    SecretId   = $cred.KeyId
                    EndDate    = $cred.EndDateTime
                    SecretName = $cred.DisplayName
                    Owner      = $userPrincipalNames
                }
            }
        }
    }
}

# Build HTML Email
$EmailBody = "<html><body>"
$EmailBody += "<h2 style='color:red; font-weight:bold;'>Azure AD App Registration Secrets Expiring within the next 30 days :</h2>"
$EmailBody += "<table border='1' cellpadding='5'><tr><th>App Name</th><th>AppId</th><th>SecretId</th><th>End Date UTC</th><th>Owner(s)</th></tr>"
foreach ($secret in $AllSecretsToExpire) {
    $EmailBody += "<tr><td>$($secret.App)</td><td>$($secret.AppId)</td><td>$($secret.SecretId)</td><td><strong>$($secret.EndDate)</strong></td><td>$($secret.Owner)</td></tr>"
}
$EmailBody += "</table>"

$EmailBody += "<h2>Secrets Already Expired</h2>"
$EmailBody += "<table border='1' cellpadding='5'><tr><th>App Name</th><th>AppId</th><th>SecretId</th><th>End Date UTC</th><th>Owner(s)</th></tr>"
foreach ($secret in $AllSecretsAlreadyExpired) {
    $EmailBody += "<tr><td>$($secret.App)</td><td>$($secret.AppId)</td><td>$($secret.SecretId)</td><td><strong>$($secret.EndDate)</strong></td><td>$($secret.Owner)</td></tr>"
}
$EmailBody += "</table>"
$EmailBody += "<p><b>Action Required:</b> Please renew expiring secrets or remove unused ones.</p>"
$EmailBody += "</body></html>"

# Email sending
$from = ""
$to = ""
$cc = ""


$subject = "ESG Azure AD App Registration Expiry Notification"
$maildomain = ""  # Replace with your Mailgun domain
$apikey = $env:MAILGUN_API_KEY

$idpass = "api:$($apikey)"
$basicauth = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($idpass))
$headers = @{ Authorization = "Basic $basicauth" }
$url = "https://api.mailgun.net/v2/$maildomain/messages"
$body = @{
    from    = $from
    to      = $to
    cc      = $cc
    subject = $subject
    html    = $EmailBody
}
Invoke-RestMethod -Uri $url -Method Post -Headers $headers -Body $body

# Cleanup
Disconnect-MgGraph
Disconnect-AzAccount -Scope Process -ErrorAction SilentlyContinue
Clear-AzContext -Scope Process -ErrorAction SilentlyContinue
