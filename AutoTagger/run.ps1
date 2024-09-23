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
$timeZone = [System.TimeZoneInfo]::FindSystemTimeZoneById("Pacific Standard Time")
$time_PST = [System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId((Get-Date), $timeZone.Id).ToString("hh:mmtt")

# Extract relevant data from the event payload.
$claims = $eventGridEvent.data.claims
$resourceId = $eventGridEvent.data.resourceUri
$operationName = $eventGridEvent.data.operationName
$subject = $eventGridEvent.subject

# Extract the principal type from the event data.
$principalType = $eventGridEvent.data.authorization.evidence.principalType

# Extract the IP address from 'ipaddr' in claims.
$ipAddress = $claims.ipaddr

# Check if the IP address is present; if not, skip tagging this resource.
if (-not $ipAddress) {
    Write-Host "No IP address found in the claims. Skipping tagging for resource $resourceId."
    return
}

# Output the IP address for debugging purposes.
Write-Host "IP Address: $ipAddress"

# Check if the principal type is acceptable; if not, skip tagging.
$allowedPrincipalTypes = @("User", "ServicePrincipal", "ManagedIdentity")
if ($principalType -notin $allowedPrincipalTypes) {
    Write-Host "Event initiated by $principalType. Skipping tagging for resource $resourceId."
    return
}

# Extract the 'name' and 'email' claims.
$name = $claims.name
$email = $claims.'http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress'

# Determine the 'Creator' tag based on the extracted data.
if ($name -ne $null) {
    $creator = $name
} elseif ($email -ne $null) {
    $creator = $email
} elseif ($principalType -eq "ServicePrincipal" -or $principalType -eq "ManagedIdentity") {
    $appid = $claims.appid
    $creator = "Service Principal ID " + $appid
} else {
    $creator = "Unknown"
}

# Output extracted information for debugging purposes.
Write-Host "Name: $name"
Write-Host "Email: $email"
Write-Host "Creator: $creator"
Write-Host "Resource ID: $resourceId"
Write-Host "Principal Type: $principalType"
Write-Host "Date: $date"
Write-Host "Time PST: $time_PST"
Write-Host "Operation Name: $operationName"
Write-Host "Subject: $subject"

# Define the list of resource types to include.
$includedResourceTypes = @(
    "Microsoft.Compute/virtualMachines",
    "Microsoft.Compute/virtualMachineScaleSets",
    "Microsoft.Storage/storageAccounts",
    "Microsoft.Sql/servers",
    "Microsoft.Sql/servers/databases",
    "Microsoft.KeyVault/vaults",
    "Microsoft.Network/virtualNetworks",
    "Microsoft.Network/networkSecurityGroups",
    "Microsoft.Network/publicIPAddresses",
    "Microsoft.Network/loadBalancers",
    "Microsoft.Network/applicationGateways",
    "Microsoft.Web/sites",
    "Microsoft.Web/serverfarms",
    "Microsoft.ContainerService/managedClusters",
    "Microsoft.OperationalInsights/workspaces",
    "Microsoft.Resources/resourceGroups",
    "Microsoft.DocumentDB/databaseAccounts",
    "Microsoft.AppConfiguration/configurationStores",
    "Microsoft.EventHub/namespaces",
    "Microsoft.ServiceBus/namespaces",
    "Microsoft.Relay/namespaces",
    "Microsoft.Cache/Redis",
    "Microsoft.Search/searchServices",
    "Microsoft.SignalRService/SignalR",
    "Microsoft.DataFactory/factories",
    "Microsoft.Logic/workflows",
    "Microsoft.MachineLearningServices/workspaces",
    "Microsoft.Insights/components",
    "Microsoft.Automation/automationAccounts",
    "Microsoft.RecoveryServices/vaults",
    "Microsoft.Network/trafficManagerProfiles"
    # Add other common, taggable resource types as needed.
)

# Attempt to retrieve the resource to get its resource type.
$resource = Get-AzResource -ResourceId $resourceId -ErrorAction SilentlyContinue

if ($resource -ne $null) {
    $resourceType = $resource.ResourceType
    Write-Host "Resource Type: $resourceType"
} else {
    Write-Host "Failed to retrieve resource. Skipping tagging for resource $resourceId."
    return
}

# Check if the resource type is in the included list.
if ($resourceType -eq $null -or $includedResourceTypes -notcontains $resourceType) {
    Write-Host "Resource type $resourceType is not in the included list. Skipping tagging for resource $resourceId."
    return
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

    # Check if any of the key tags already exist (Creator, DateCreated, TimeCreatedInPST).
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
