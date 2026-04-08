# Email details
$from = ""
$to = ""
$cc = ""
$subject = "List of Resources that are older than 1 month in Sandbox Subscription in GCP"
$maildomain = ""  # Replace with your Mailgun domain
$apikey = ""      # Replace with your Mailgun API key

gcloud auth activate-service-account --key-file "<gcp_secret_key_file_path>"
$oneMonthAgo = (Get-Date).AddMonths(-1)
$commandOutput = gcloud asset search-all-resources --scope='projects/<project_id>' --order-by='createTime' --format='json'
$resources = $commandOutput | ConvertFrom-Json
$selectedResources = $resources | Where-Object { $_.createTime -ne $null } | Where-Object { [datetime]::Parse($_.createTime) -lt $oneMonthAgo } | ForEach-Object {
    [PSCustomObject]@{
        # Name = $_.name
		DisplayName = $_.displayName
        ResourceType = $_.assetType
        CreateTime = $_.createTime
        Location = $_.location
        Labels = $_.labels
    }
}
$CurrentDate = Get-Date
$Dateplus2 = $CurrentDate.AddDays(2)
$FormattedDate = $Dateplus2.ToString("dddd , MMMM dd , yyyy")
$EmailBody = "<html><body>"
$EmailBody += "<h2>Following are the resources in Sandbox Subscription in GCP that are older than 1 month. </h2>"
$EmailBody += "<p style='color:red'><b>Note : </b></p>"
$EmailBody += "<p style='color:red'>1.Please contact your team members and request them to review and remove any unnecessary resources.</p>"
$EmailBody += "<p style='color:red'>2.Please be advised that team will be deleting the resources by $($FormattedDate) . If you require any resources to be retained, please send an email to 'msci_esg_devops@msci.com'.</p>"
$EmailBody += "<table style='border-collapse: collapse; width: 100%; border: 1px solid black;'>"
$EmailBody += "<tr><th style='border: 1px solid black; padding: 8px;'>Resource Name</th><th style='border: 1px solid black; padding: 8px;'>Resource Type</th><th style='border: 1px solid black; padding: 8px;'>Creation Time</th><th style='border: 1px solid black; padding: 8px;'>Location</th><th style='border: 1px solid black; padding: 8px;'>Labels</th></tr>"

foreach ($r in $selectedResources) {
    $EmailBody += "<tr><td style='border: 1px solid black; padding: 8px;'>$($r.DisplayName)</td><td style='border: 1px solid black; padding: 8px;'>$($r.ResourceType)</td><td style='border: 1px solid black; padding: 8px;'>$($r.CreateTime)</td><td style='border: 1px solid black; padding: 8px;'>$($r.Location)</td><td style='border: 1px solid black; padding: 8px;'>$($r.Labels)</td></tr>"
}
$EmailBody += "</table>"
$EmailBody += "</body></html>"
$idpass = "api:$($apikey)"
$basicauth = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($idpass))
$headers = @{
        Authorization = "Basic $basicauth"
    }
$url = "https://api.mailgun.net/v2/$maildomain/messages"
$body = @{
        from = $from;
        to = $to;
        cc = $cc;
        subject = $subject;
        html = $EmailBody
    }
    Invoke-RestMethod -Uri $url -Method Post -Headers $headers -Body $body
