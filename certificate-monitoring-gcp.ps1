# ---------------- Config (edit as needed) ----------------
$projectid = "

# Mail settings (Mailgun)
$maildomain = ""
$from = ""
# Primary recipients for weekly summary (comma-separated)
$to = ""
$cc = ""


# Thresholds (days)
$thresholdDays = 30         # weekly summary threshold (adjust as needed)
$pdThresholdDays = 7        # PagerDuty urgent threshold

# PagerDuty email integration address
$pdTo = ""

# -------------------------------------------------------

# Helper: determine run type from environment (resilient)
$runTypeCandidates = @(
    $env:BUILD_CRONSCHEDULE_DISPLAYNAME,
    $env:BUILD_CRON_SCHEDULE_DISPLAYNAME,
    $env:BUILD_CRON_SCHEDULE,
    $env:SCHEDULE_DISPLAYNAME
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

if ($runTypeCandidates.Count -gt 0) {
    $runType = $runTypeCandidates[0]
} else {
    $runType = $null
}

$IsWeeklyEmailRun = $false
$IsDailyPagerDutyRun = $false


# ---- Robust schedule detection ----
if ($runType) {
    Write-Output "Detected pipeline schedule display name: '$runType'"

    # normalize and inspect the token (trim, to-lower)
    $rt = $runType.ToString().Trim().ToLowerInvariant()

    # Accept exact names, contains matches, and common short labels like 'w'/'weekly'/'daily'
    if ($rt -eq "weekly-email-run" -or $rt -like "*weekly*" -or $rt -in @("w","weekly")) {
        $IsWeeklyEmailRun = $true
    }
    if ($rt -eq "daily-pagerduty-run" -or $rt -like "*pagerduty*" -or $rt -like "*daily*" -or $rt -in @("d","daily")) {
        $IsDailyPagerDutyRun = $true
    }

    # defensive: if runType is non-empty but didn't match anything, log a warning
    if (-not $IsWeeklyEmailRun -and -not $IsDailyPagerDutyRun) {
        Write-Warning "Schedule display name '$runType' did not match expected tokens. Defaulting to weekly + daily for safety."
        $IsWeeklyEmailRun = $true
        $IsDailyPagerDutyRun = $true
    }
} else {
    Write-Warning "Could not detect schedule display name from environment. Defaulting to both behaviors (weekly email + daily PagerDuty) for safety."
    $IsWeeklyEmailRun = $true
    $IsDailyPagerDutyRun = $true
}
Write-Output "IsWeeklyEmailRun = $IsWeeklyEmailRun ; IsDailyPagerDutyRun = $IsDailyPagerDutyRun"
# ---- end patch ----

# Mailgun auth from env (pipeline variable group)
$apikey = $env:DTC_MailgunAPI
if ([string]::IsNullOrWhiteSpace($apikey)) {
    Write-Error "Mailgun API key not found in environment variable 'DTC_MailgunAPI'. Aborting email send."
    exit 2
}
$idpass = "api:$($apikey)"
$basicauth = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($idpass))
$headers = @{ Authorization = "Basic $basicauth" }
$mailgunUrl = "https://api.mailgun.net/v3/$maildomain/messages"  # v3 recommended; adjust if needed

# Set date thresholds
$currentDate = Get-Date
$thresholdDate = $currentDate.AddDays($thresholdDays)
$pdThresholdDate = $currentDate.AddDays($pdThresholdDays)

# Prepare result lists
$combinedResults = @()
$expired = @()
$expiringSoon = @()
$pdUrgent = @()

# ---------- Utility: resolve expiry string from JSON object ----------
function Resolve-ExpiryString {
    param($obj)

    # Common candidate properties (observed across APIs / versions)
    $candidates = @(
        $obj.expireTime,
        $obj.expirationTime,
        $obj.expire_time,
        $obj.expire_date,
        $obj.expireAt,
        $obj.expiry,
        $obj.validTo,
        $obj.valid_to,
        $obj.expireOn,
        $obj.notAfter,
        $obj.validityEnd,
        ($obj.metadata | Select-Object -ExpandProperty expireTime -ErrorAction SilentlyContinue)
    )

    foreach ($cand in $candidates) {
        if ($null -ne $cand) {
            $s = $cand.ToString().Trim()
            if (-not [string]::IsNullOrWhiteSpace($s)) { return $s }
        }
    }

    # Also attempt to inspect nested arrays/objects that might contain time strings:
    try {
        $props = $obj | Get-Member -MemberType NoteProperty,Property -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
        foreach ($p in $props) {
            $val = $obj.$p
            if ($val -is [string]) {
                if ($val -match '\d{4}-\d{2}-\d{2}') { return $val.Trim() }
            } elseif ($val -is [object]) {
                $nested = $val | ConvertTo-Json -Depth 3 -ErrorAction SilentlyContinue
                if ($nested -and ($nested -match '\d{4}-\d{2}-\d{2}')) { return ($nested -replace '"','').Trim() }
            }
        }
    } catch { }

    return $null
}

# Helper: robust choose-first-non-empty-string function
function FirstNonEmptyString {
    param([Parameter(Mandatory=$true)][object[]]$values)
    foreach ($v in $values) {
        if ($null -ne $v) {
            $s = $v.ToString().Trim()
            if (-not [string]::IsNullOrWhiteSpace($s)) { return $s }
        }
    }
    return ""
}

# ---------- Fetch certificates using gcloud JSON output ----------
try {
    $certificateJson = & gcloud certificate-manager certificates list --project=$projectid --format=json 2>$null
} catch {
    Write-Warning "gcloud certificate-manager returned an error: $_"
    $certificateJson = $null
}

try {
    $sslCertJson = & gcloud compute ssl-certificates list --project=$projectid --filter="type:SELF_MANAGED" --format=json 2>$null
} catch {
    Write-Warning "gcloud compute ssl-certificates returned an error: $_"
    $sslCertJson = $null
}

# Parse certificate-manager list
if ($certificateJson -and $certificateJson.Trim()) {
    try {
        $certObjs = $certificateJson | ConvertFrom-Json
        foreach ($r in $certObjs) {
            # build Name robustly (avoid using -or which returns boolean)
            $nameVal = FirstNonEmptyString -values @($r.name, $r.displayName, $r.id, $r.domain, $r.dnsName, $r.selfLink)
            $hostname = $null
            if ($r.sanDnsnames) {
                if ($r.sanDnsnames -is [System.Collections.IEnumerable] -and -not ($r.sanDnsnames -is [string])) {
                    $hostname = ($r.sanDnsnames -join ",")
                } else {
                    $hostname = $r.sanDnsnames.ToString()
                }
            } else {
                $hostname = FirstNonEmptyString -values @($r.domain, $r.dnsName, $r.name)
            }

            $combinedResults += [PSCustomObject]@{
                Name = $nameVal
                Hostname = $hostname
                RawExpiry = Resolve-ExpiryString -obj $r
                RawObject = $r
                Source = "certificate-manager/list"
            }
        }
    } catch {
        Write-Warning "Failed to parse certificate-manager JSON output: $_"
    }
}

# Parse compute ssl-certificates list (use $certHost instead of $host)
if ($sslCertJson -and $sslCertJson.Trim()) {
    try {
        $sslObjs = $sslCertJson | ConvertFrom-Json
        foreach ($r in $sslObjs) {
            # build Name robustly
            $nameVal = FirstNonEmptyString -values @($r.name, $r.id, $r.selfLink)
            $certHost = ""
            if ($r.subjectAlternativeNames) {
                if ($r.subjectAlternativeNames -is [System.Collections.IEnumerable] -and -not ($r.subjectAlternativeNames -is [string])) {
                    $certHost = ($r.subjectAlternativeNames -join ",")
                } else {
                    $certHost = $r.subjectAlternativeNames.ToString()
                }
            } else {
                $certHost = FirstNonEmptyString -values @($r.domain, $r.dnsName, $r.name)
            }

            $combinedResults += [PSCustomObject]@{
                Name = $nameVal
                Hostname = $certHost
                RawExpiry = Resolve-ExpiryString -obj $r
                RawObject = $r
                Source = "compute/ssl-certificates/list"
            }
        }
    } catch {
        Write-Warning "Failed to parse ssl-certificates JSON output: $_"
    }
}

Write-Output "Total certificate rows found: $($combinedResults.Count)"

# ---------- For entries missing expiry, attempt per-cert describe fallback ----------
foreach ($c in $combinedResults) {
    if (-not $c.RawExpiry) {
        Write-Output "No expiry value found for $($c.Name) from list output. Attempting per-cert describe fallback..."
        $descExpiry = $null
        try {
            if ($c.Source -like "compute*") {
                $descJson = & gcloud compute ssl-certificates describe $($c.Name) --project=$projectid --format=json 2>$null
            } else {
                $descJson = & gcloud certificate-manager certificates describe $($c.Name) --project=$projectid --format=json 2>$null
            }

            if ($descJson -and $descJson.Trim()) {
                $descObj = $descJson | ConvertFrom-Json
                $descExpiry = Resolve-ExpiryString -obj $descObj
                if ($descExpiry) {
                    $c.RawExpiry = $descExpiry
                    $c.RawObject = $descObj
                    Write-Output "Found expiry via describe for $($c.Name): $descExpiry"
                } else {
                    Write-Warning "Describe returned no expiry field for $($c.Name). Dumping short object for inspection."
                    try { $descObj | ConvertTo-Json -Depth 4 | Write-Output } catch { Write-Warning "Could not convert described object to JSON for $($c.Name)." }
                }
            } else {
                Write-Warning "Describe produced no output for $($c.Name)."
            }
        } catch {
            Write-Warning "Describe attempt failed for $($c.Name): $_"
        }
    }
}

# ---------- Parse expiry strings into DateTime and classify ----------
foreach ($c in $combinedResults) {
    if (-not $c.RawExpiry) {
        Write-Warning "No expiry value for certificate '$($c.Name)' - skipping."
        continue
    }

    $parsedExpiry = $null
    try {
        $parsedExpiry = Get-Date $c.RawExpiry -ErrorAction Stop
    } catch {
        $tryStr = $c.RawExpiry.Trim() -replace 'Z$',''
        try {
            $parsedExpiry = Get-Date $tryStr -ErrorAction Stop
        } catch {
            Write-Warning "Failed to parse expiry '$($c.RawExpiry)' for certificate '$($c.Name)' - skipping."
            continue
        }
    }

    $entry = [PSCustomObject]@{
        Name = $c.Name
        HostName = $c.Hostname
        ExpiryDate = $parsedExpiry.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        RawExpiry = $c.RawExpiry
        ParsedExpiry = $parsedExpiry
    }

    if ($parsedExpiry -lt $currentDate) {
        $expired += $entry
    } elseif ($parsedExpiry -le $thresholdDate) {
        $expiringSoon += $entry
    }

    if (($parsedExpiry -le $pdThresholdDate) -and ($parsedExpiry -ge $currentDate)) {
        $pdUrgent += $entry
    }
}

# ---------- Logging results ----------
if ($expired.Count -gt 0) {
    Write-Output "Expired certificates:"
    $expired | Format-Table -AutoSize
} else {
    Write-Output "No expired certificates found."
}

if ($expiringSoon.Count -gt 0) {
    Write-Output "Certificates expiring within $thresholdDays days:"
    $expiringSoon | Format-Table -AutoSize
} else {
    Write-Output "No certificates expiring within $thresholdDays days."
}

Write-Output "PagerDuty-urgent certificates (<= $pdThresholdDays days): $($pdUrgent.Count)"

# If nothing to report at all, exit cleanly
if (($expired.Count + $expiringSoon.Count + $pdUrgent.Count) -eq 0) {
    Write-Output "There are no certificates that are expired or expiring within threshold periods. No email sent."
    exit 0
}

# ---------- Weekly Mailgun email (thresholdDays) ----------
if ($IsWeeklyEmailRun) {
    if (($expired.Count + $expiringSoon.Count) -gt 0) {
        $EmailBody = "<html><body>"
        $EmailBody += "<h2>Following are the list of certificates that are expired or going to expire within $thresholdDays days in $projectid</h2>"

        if ($expiringSoon.Count -gt 0) {
            $EmailBody += "<h3>Certificates expiring within $thresholdDays days</h3>"
            $EmailBody += "<p style='color:red'>Requesting the Project Owners to renew the certificates before the expiry period.</p>"
            $EmailBody += "<table style='border-collapse: collapse; width: 100%; border: 1px solid black;'>"
            $EmailBody += "<tr><th style='border: 1px solid black; padding: 8px;'>Certificate Name</th><th style='border: 1px solid black; padding: 8px;'>Host Name</th><th style='border: 1px solid black; padding: 8px;'>Expiry Date (UTC)</th></tr>"
            foreach ($k in $expiringSoon | Sort-Object ParsedExpiry) {
                $EmailBody += "<tr><td style='border: 1px solid black; padding: 8px;'>$($k.Name)</td><td style='border: 1px solid black; padding: 8px;'>$($k.HostName)</td><td style='border: 1px solid black; padding: 8px;'>$($k.ExpiryDate)</td></tr>"
            }
            $EmailBody += "</table>"
        }

        if ($expired.Count -gt 0) {
            $EmailBody += "<h3 style='color:#a00;'>Expired Certificates</h3>"
            $EmailBody += "<p style='color:red'>Requesting the Project Owners to remove the expired certificates.</p>"
            $EmailBody += "<table style='border-collapse: collapse; width: 100%; border: 1px solid black;'>"
            $EmailBody += "<tr><th style='border: 1px solid black; padding: 8px;'>Certificate Name</th><th style='border: 1px solid black; padding: 8px;'>Host Name</th><th style='border: 1px solid black; padding: 8px;'>Expiry Date (UTC)</th></tr>"
            foreach ($k in $expired | Sort-Object ParsedExpiry) {
                $EmailBody += "<tr><td style='border: 1px solid black; padding: 8px;'>$($k.Name)</td><td style='border: 1px solid black; padding: 8px;'>$($k.HostName)</td><td style='border: 1px solid black; padding: 8px;'>$($k.ExpiryDate)</td></tr>"
            }
            $EmailBody += "</table>"
        }

        $EmailBody += "</body></html>"

        $subject = "IMPORTANT - S&C - ACTION REQUIRED : NON-PROD : EXPIRY NOTIFICATION : GCP CERTIFICATE : $projectid"
        $body = @{
            from = $from;
            to = $to;
            cc = $cc;
            subject = $subject;
            html = $EmailBody
        }

        try {
            Invoke-RestMethod -Uri $mailgunUrl -Method Post -Headers $headers -Body $body
            Write-Output "Expiry notification email sent to $to (project: $projectid)."
        } catch {
            Write-Error "Failed to send Mailgun email: $_"
        }
    } else {
        Write-Output "No expiries for weekly email — skipping Mailgun."
    }
} else {
    Write-Output "Not a weekly email run — skipping Mailgun weekly notification."
}

# ---------- Daily PagerDuty email (pdThresholdDays) ----------
if ($IsDailyPagerDutyRun) {
    if ($pdUrgent.Count -gt 0) {
        $pdSubject = "IMPORTANT - S&C - ACTION REQUIRED : NON-PROD : EXPIRY NOTIFICATION : GCP CERTIFICATES EXPIRING WITHIN $pdThresholdDays DAYS : $projectid"

        $pdBody = "<html><body>"
        $pdBody += "<h2 style='color:red'>URGENT: Certificates expiring within $pdThresholdDays days</h2>"
        $pdBody += "<p>Immediate action required to avoid service disruption.</p>"
        $pdBody += "<table style='border-collapse: collapse; width: 100%; border: 1px solid black;'>"
        $pdBody += "<tr><th style='border:1px solid black;padding:8px;'>Certificate</th><th style='border:1px solid black;padding:8px;'>Host</th><th style='border:1px solid black;padding:8px;'>Expiry (UTC)</th></tr>"

        foreach ($c in $pdUrgent | Sort-Object ParsedExpiry) {
            $pdBody += "<tr><td style='border:1px solid black;padding:8px;'>$($c.Name)</td><td style='border:1px solid black;padding:8px;'>$($c.HostName)</td><td style='border:1px solid black;padding:8px;'>$($c.ExpiryDate)</td></tr>"
        }

        $pdBody += "</table>"
        $pdBody += "<p>This alert was generated automatically by the certificate monitoring pipeline for project $projectid.</p>"
        $pdBody += "</body></html>"

        $pdMailBody = @{
            from    = $from
            to      = $pdTo
            subject = $pdSubject
            html    = $pdBody
        }

        try {
            Invoke-RestMethod -Uri $mailgunUrl -Method Post -Headers $headers -Body $pdMailBody
            Write-Output "PagerDuty alert email sent to $pdTo"
        } catch {
            Write-Error "Failed to send PagerDuty email alert: $_"
        }
    } else {
        Write-Output "No certificates expiring within $pdThresholdDays days — no PagerDuty email sent."
    }
} else {
    Write-Output "Not a daily PagerDuty run — skipping PagerDuty email."
}

# End of script
