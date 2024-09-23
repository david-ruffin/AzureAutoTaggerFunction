# This script processes an Event Grid event to extract relevant metadata,
# determines whether to update or add tags to an Azure resource, and
# handles potential errors during the tagging process.

param($eventGridEvent, $TriggerMetadata)

# Import required Azure modules and check for successful import.
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

# Convert the event grid event to JSON format for logging and debugging purposes.
$eventGridEvent | ConvertTo-Json -Depth 5 | Write-Host

# Fetch the current date in 'M/d/yyyy' format.
$date = Get-Date -Format 'M/d/yyyy'

# Convert the current date and time to Pacific Standard Time (PST) and format it.
$time_PST = [System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId((Get-Date), 'Pacific Standard Time').ToString("hh:mmtt") + ' PST'

# Extract relevant claims data from the event payload.
$name = $eventGridEvent.data.claims.name
$appid = $eventGridEvent.data.claims.appid
$email = $eventGridEvent.data.claims.'http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress'
$resourceId = $eventGridEvent.data.resourceUri
$operationName = $eventGridEvent.data.operationName
$subject = $eventGridEvent.subject

# Check if 'ipaddr' is present in the claims; if not, assume the event was not initiated by an end user and skip tagging.
if (-not $eventGridEvent.data.claims.ipaddr) {
    Write-Host "No IP address found in the event data. Skipping tagging for resource $resourceId."
    return
}

# Determine the 'Creator' tag based on the extracted data.
# If the 'name' claim is not null, use it; otherwise, use the service principal ID.
$creator = $name -ne $null ? $name : ("Service Principal ID " + $appid)

# Output extracted information for debugging purposes.
Write-Host "Name: $name"
Write-Host "Resource ID: $resourceId"
Write-Host "Email: $email"
Write-Host "App ID: $appid"
Write-Host "Date: $date"
Write-Host "Time PST: $time_PST"
Write-Host "Creator: $creator"
Write-Host "Operation Name: $operationName"
Write-Host "Subject: $subject"

# Define a list of resource types to ignore to prevent unnecessary tagging.
$ignore = @(
    "providers/Microsoft.Resources/deployments",
    "providers/Microsoft.Resources/tags",
    "providers/Microsoft.Network/frontdoor"
)

# Check if the resourceId matches any pattern in the ignore list.
foreach ($ignorePattern in $ignore) {
    if ($resourceId -like "*$ignorePattern*") {
        Write-Host "Resource $resourceId is in the ignore list. Skipping..."
        return
    }
}

# Main logic block with error handling to ensure robustness.
try {
    # Attempt to retrieve the current tags on the resource using its resourceId.
    Write-Host "Attempting to retrieve current tags for resource $resourceId..."
    $currentTags = Get-AzTag -ResourceId $resourceId
    Write-Host "Current Tags: $currentTags"

    # Initialize tags if they are null or empty.
    if (-not $currentTags -or -not $currentTags.Tags) {
        Write-Host "No tags found on resource $resourceId. Proceeding to add new tags."
        # Initialize an empty tags hashtable.
        $currentTags = @{ Tags = @{} }
    } else {
        # Output the existing tags for debugging purposes.
        Write-Host "Current Tags: $($currentTags.Tags | ConvertTo-Json)"
    }

    # Check if any of the key tags already exist (Creator, DateCreated, or TimeCreatedInPST).
    Write-Host "Checking for existing key tags (Creator, DateCreated, TimeCreatedInPST)..."
    if ($currentTags.Tags -and (
        $currentTags.Tags.ContainsKey("Creator") -or 
        $currentTags.Tags.ContainsKey("DateCreated") -or 
        $currentTags.Tags.ContainsKey("TimeCreatedInPST"))) {
        Write-Host "One or more of the required tags (Creator, DateCreated, TimeCreatedInPST) already exist."

        # Existing resource logic: Update LastModifiedBy and LastModifiedDate tags.
        Write-Host "Resource is pre-existing. Updating LastModifiedBy and LastModifiedDate tags..."

        # Prepare tags to update for pre-existing resources.
        $modifiedTags = @{
            LastModifiedBy = $creator
            LastModifiedDate = $date
        }
        Write-Host "Tags to be updated: $($modifiedTags | ConvertTo-Json)"

        # Apply the updated tags to the resource using 'Update-AzTag' with the 'Merge' operation.
        Write-Host "Applying LastModified tags to resource $resourceId..."
        Update-AzTag -ResourceId $resourceId -Tag $modifiedTags -Operation Merge

        # Output a success message upon completion.
        Write-Host "LastModified tags have been updated for the resource with ID $resourceId."
    }
    else {
        # New resource logic: Add Creator, DateCreated, and TimeCreatedInPST tags.
        Write-Host "No existing key tags found. Resource is new. Preparing to add new tags..."

        # Prepare tags to add for new resources.
        $tagsToUpdate = @{
            Creator = $creator
            DateCreated = $date
            TimeCreatedInPST = $time_PST
        }
        Write-Host "Tags to be added: $($tagsToUpdate | ConvertTo-Json)"

        # Apply the new tags to the resource using 'Update-AzTag' with the 'Merge' operation.
        Write-Host "Applying new tags to resource $resourceId..."
        Update-AzTag -ResourceId $resourceId -Tag $tagsToUpdate -Operation Merge

        # Output a success message upon completion.
        Write-Host "Tags have been added for the new resource with ID $resourceId."
    }

} catch {
    # Handle any errors that occur during the tagging process by logging the error message and stack trace.
    Write-Host "Failed to update tags for resource $resourceId. Error: $($_.Exception.Message)"
    Write-Host "Stack Trace: $($_.Exception.StackTrace)"
}

# Output the current user context for auditing or logging purposes.
# whoami
