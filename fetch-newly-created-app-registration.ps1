az login --service-principal -u <username> -p <password> --tenant <tenant_id>
# Define the date 30 days ago
$thirtyDaysAgo = (Get-Date).AddDays(-30).ToString("yyyy-MM-ddTHH:mm:ssZ")

# Get a list of all application IDs
$appIds = az ad app list --query "[].appId" -o tsv

# Initialize an array to store results
$results = @()

foreach ($appId in $appIds) {
    # Get application details including creation date
    $appDetails = az ad app show --id $appId --query "{DisplayName: displayName, AppId: appId, CreatedDateTime: createdDateTime}" -o json | ConvertFrom-Json

    # Check if the application was created in the last 30 days
    if ([datetime]$appDetails.CreatedDateTime -ge [datetime]$thirtyDaysAgo) {
        # Get owner details for the application
        $ownerIds = az ad app owner list --id $appId --query "[].userPrincipalName" -o tsv

        # Create a custom object with application details and owners
        $appInfo = [PSCustomObject]@{
            DisplayName      = $appDetails.DisplayName
            AppId            = $appDetails.AppId
            CreatedDateTime  = $appDetails.CreatedDateTime
            Owners           = ($ownerIds -join ", ")  # Join owner emails as a comma-separated string
        }

        # Add the app info to the results array
        $results += $appInfo
    }
}

# Display results
$results | Select-Object DisplayName, AppId, CreatedDateTime, Owners

