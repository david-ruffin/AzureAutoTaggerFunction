# This script processes an Event Grid event to extract relevant metadata,
# determines whether to update or add tags to an Azure resource, and
# handles potential errors during the tagging process.

param($eventGridEvent, $TriggerMetadata)

# Import required modules and check success
Import-Module Az.Resources
if (-not $?) {
    Write-Host "Failed to import Az.Resources module. Exiting script."
    exit 1
} else {
    Write-Host "Successfully imported Az.Resources module."
}

Import-Module Az.Accounts
if (-not $?) {
    Write-Host "Failed to import Az.Accounts module. Exiting script."
    exit 1
} else {
    Write-Host "Successfully imported Az.Accounts module."
}

# Convert the event grid event to JSON format and output it to the console.
$eventGridEvent | ConvertTo-Json -Depth 5 | Write-Host

# Fetch the current date in 'M/d/yyyy' format.
$date = Get-Date -Format 'M/d/yyyy'

# Convert the current date and time to Pacific Standard Time (PST).
$time_PST = [System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId((Get-Date), 'Pacific Standard Time').ToString("hh:mmtt") + ' PST'

# Extract relevant claims data from the event payload.
$name = $eventGridEvent.data.claims.name
$appid = $eventGridEvent.data.claims.appid
$email = $eventGridEvent.data.claims.'http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress'
$resourceId = $eventGridEvent.data.resourceUri
$operationName = $eventGridEvent.data.operationName
$subject = $eventGridEvent.subject

# Check if 'ipaddr' is present; if not, skip tagging this resource.
if (-not $eventGridEvent.data.claims.ipaddr) {
    Write-Host "No IP address found in the event data. Skipping tagging for resource $resourceId."
    return
}

# Determine the 'Creator' tag based on the extracted data.
$creator = $name -ne $null ? $name : ("Service Principal ID " + $appid)

# Output extracted information for debugging.
Write-Host "Name: $name"
Write-Host "resourceId: $resourceId"
Write-Host "email: $email"
Write-Host "appid: $appid"
Write-Host "date: $date"
Write-Host "time_PST: $time_PST"
Write-Host "creator: $creator"
Write-Host "Operation Name: $operationName"
Write-Host "Subject: $subject "

# Define a list of resource types to ignore.
$ignore = @(
    "providers/Microsoft.Resources/deployments",
    "providers/Microsoft.Resources/tags",
    "providers/Microsoft.Network/frontdoor"
)

# Check if the resourceId is in the ignore list.
foreach ($ignorePattern in $ignore) {
    if ($resourceId -like "*$ignorePattern*") {
        Write-Host "Resource $resourceId is in the ignore list. Skipping..."
        return
    }
}

# Main logic block with error handling.
try {
    # Retrieve the current tags on the resource using its resourceId.
    Write-Host "Attempting to retrieve current tags for resource $resourceId..."
    $currentTags = Get-AzTag -ResourceId $resourceId
    write-host "Current Tags: $currentTags"
    
    if ($currentTags -eq $null) {
        Write-Host "No tags found on resource $resourceId. Proceeding to add new tags."
        $currentTags = @{ Tags = @{} }  # Initialize empty tag hashtable
    } else {
        Write-Host "Current Tags: $($currentTags.Tags | ConvertTo-Json)"
    }

    # Check if any of the key tags already exist (Creator, DateCreated, or TimeCreatedInPST).
    Write-Host "Checking for existing key tags (Creator, DateCreated, TimeCreatedInPST)..."
    if ($currentTags.Tags.ContainsKey("Creator") -or 
        $currentTags.Tags.ContainsKey("DateCreated") -or 
        $currentTags.Tags.ContainsKey("TimeCreatedInPST")) {
        Write-Host "One or more of the required tags (Creator, DateCreated, TimeCreatedInPST) already exist. Exiting without adding tags."
        return
    }

    # If none of the key tags exist, proceed to add them.
    Write-Host "Preparing to add new tags..."
    $tagsToUpdate = @{
        Creator = $creator
        DateCreated = $date
        TimeCreatedInPST = $time_PST
    }
    Write-Host "Tags to be added: $($tagsToUpdate | ConvertTo-Json)"

    # Apply the tags to the resource using the 'Update-AzTag' cmdlet with the 'Merge' operation.
    Write-Host "Applying tags to resource $resourceId..."
    Update-AzTag -ResourceId $resourceId -Tag $tagsToUpdate -Operation Merge

    # Output a success message to the console.
    Write-Host "Tags have been added for the resource with ID $resourceId."

} catch {
    # Handle any errors that occur during the tagging process.
    Write-Host "Failed to update tags for resource $resourceId. Error: $($_.Exception.Message)"
    Write-Host "Stack Trace: $($_.Exception.StackTrace)"
}

# Output the current user context for auditing or logging purposes.
whoami
