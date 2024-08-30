# Param definition to accept Event Grid data and metadata
param($eventGridEvent, $TriggerMetadata)

# Convert the event grid event to JSON format and output it to the console.
# This is useful for debugging or logging purposes.
$eventGridEvent | ConvertTo-Json -Depth 5 | Write-Host

# Fetch and format the current date and time with timezone adjustments
$date = Get-Date -Format 'M/d/yyyy'
$time = [System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId((Get-Date), 'Pacific Standard Time').ToString("hh:mmtt") + ' PST'

# Extract claims data from the event payload
$name = $eventGridEvent.data.claims.name
$appid = $eventGridEvent.data.claims.appid
$email = $eventGridEvent.data.claims.'http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress'
$resourceId = $eventGridEvent.data.resourceUri

# Determine 'Creator' and 'LastModifiedBy' based on available data
# Prefers user name, falls back to appid if name is not present, labels service principal explicitly
$creator = $name -ne $null ? $name : ("Service Principal ID " + $appid)
$lastModifiedBy = $email -ne $null ? $email : ("Service Principal ID " + $appid)

# Output the extracted information to the console for debugging or logging purposes.
Write-Host "######################"
Write-Host "Name: $name"
Write-Host "resourceId: $resourceId"
Write-Host "email: $email"
Write-Host "appid: $appid"
Write-Host "date: $date"
Write-Host "time_PST: $time_PST"
Write-Host "creator: $creator"
Write-Host "lastModifiedBy: $lastModifiedBy"

# Attempt to retrieve and tag the resource, handling any errors encountered
try {
    $resource = Get-AzResource -ResourceId $resourceId -ErrorAction Stop

    # Ensure the resource is valid and not a deployment type resource
    if ($resource -and $resource.ResourceId -notlike '*Microsoft.Resources/deployments*') {
        # Retrieve existing tags, or initialize if none exist
        $existingTags = (Get-AzTag -ResourceId $resourceId).Properties.Tags

        # Initialize 'Creator', 'DateCreated', and 'TimeCreatedInPST' tags if not already set
        if (-not $existingTags['Creator']) {
            $existingTags['Creator'] = $creator
            $existingTags['DateCreated'] = $date
            $existingTags['TimeCreatedInPST'] = $time
        }

        # Always update 'LastModifiedBy' and 'LastModifiedTimeStamp' tags to reflect latest changes
        $existingTags['LastModifiedBy'] = $lastModifiedBy
        $existingTags['LastModifiedTimeStamp'] = Get-Date -Format o

        # Apply the updated tags to the resource
        Set-AzTag -ResourceId $resourceId -Tag $existingTags -Operation Merge
    }
    else {
        Write-Output "Excluded resource type or no resource found."
    }
}
catch {
    # Log any exceptions encountered during the process
    Write-Output "Error accessing or modifying the resource: $_"
}
