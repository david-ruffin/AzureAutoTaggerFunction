# This script processes an Event Grid event to extract relevant metadata,
# determines whether to update or add tags to an Azure resource, and
# handles potential errors during the tagging process.

param($eventGridEvent, $TriggerMetadata)

# Convert the event grid event to JSON format and output it to the console.
# This is useful for debugging or logging purposes.
$eventGridEvent | ConvertTo-Json -Depth 5 | Write-Host

# Fetch the current date in 'M/d/yyyy' format.
$date = Get-Date -Format 'M/d/yyyy'

# Convert the current date and time to Pacific Standard Time (PST).
# The time is formatted as 'hh:mmtt' (e.g., 02:30PM) and the string 'PST' is appended.
$time_PST = [System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId((Get-Date), 'Pacific Standard Time').ToString("hh:mmtt") + ' PST'

# Extract relevant claims data from the event payload.
# 'name' is the user's name, 'appid' is the application ID, and 'email' is the user's email.
# 'resourceId' is the identifier for the Azure resource that triggered the event.
$name = $eventGridEvent.data.claims.name
$appid = $eventGridEvent.data.claims.appid
$email = $eventGridEvent.data.claims.'http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress'
$resourceId = $eventGridEvent.data.resourceUri
$ipaddr = $eventGridEvent.data.claims.ipaddr

# Check if 'ipaddr' is present; if not, skip tagging this resource.
if (-not $ipaddr) {
    Write-Host "No IP address found in the event data. Skipping tagging for resource $resourceId."
    return
}

# Determine the 'Creator' and 'LastModifiedBy' tags based on the extracted data.
# If 'name' is not null, it is used as 'Creator'; otherwise, the application ID (appid) is used.
# Similarly, 'LastModifiedBy' is set to the email if available, or the appid if not.
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
Write-Host "##### List PowerShell Modules ####"
get-module


# Define a list of resource types to ignore when attempting to add tags.
# These are resource types that either do not support tags or have specific reasons to be excluded.
$ignore = @(
    "providers/Microsoft.Resources/deployments",
    "providers/Microsoft.Resources/tags",
    "providers/Microsoft.Network/frontdoor"
)

# Check if the resourceId matches any of the patterns in the $ignore list.
# If a match is found, the script outputs a message and exits early, skipping the tagging process.
foreach ($ignorePattern in $ignore) {
    if ($resourceId -like "*$ignorePattern*") {
        Write-Host "Resource $resourceId is in the ignore list. Skipping..."
        return
    }
}

# Start of the main logic block where errors are handled.
try {
    # Retrieve the current tags on the resource using its resourceId.
    # This is necessary to determine whether to update existing tags or add new ones.
    $currentTags = Get-AzTag -ResourceId $resourceId

    # Initialize a hashtable to store the tags that will be added or updated.
    $tagsToUpdate = @{}

    # Check if any of the tags 'Creator', 'DateCreated', or 'TimeCreatedInPST' already exist.
    # If they do, update the 'LastModifiedBy' and 'LastModifiedDate' tags.
    if ($currentTags.Tags -contains "Creator" -or $currentTags.Tags -contains "DateCreated" -or $currentTags.Tags -contains "TimeCreatedInPST") {
        $tagsToUpdate["LastModifiedBy"] = $lastModifiedBy
        $tagsToUpdate["LastModifiedDate"] = $date
    } else {
        # If none of the key tags exist, add the initial set of tags including 'Creator', 'DateCreated', and 'TimeCreatedInPST'.
        $tagsToUpdate["Creator"] = $creator
        $tagsToUpdate["DateCreated"] = $date
        $tagsToUpdate["TimeCreatedInPST"] = $time_PST
    }

    # Apply the tags to the resource using the 'Update-AzTag' cmdlet with the 'Merge' operation.
    # 'Merge' ensures that the new tags are added without removing existing ones.
    Update-AzTag -ResourceId $resourceId -Tag $tagsToUpdate -Operation Merge

    # Output a success message to the console.
    Write-Host "Tags have been updated for the resource with ID $resourceId."
} catch {
    # If an error occurs during the tagging process, catch the exception.
    # Output an error message to the console along with the exception details.
    Write-Host "Failed to update tags for resource $resourceId. Error: $_"
}

# Output the current user context for auditing or logging purposes.
whoami
