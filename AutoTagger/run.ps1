# Input binding parameter for Event Grid events
param($eventGridEvent, $TriggerMetadata)

# Import required Azure modules and check for successful import
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

# Log the full event for debugging
$eventGridEvent | ConvertTo-Json -Depth 5 | Write-Host

# Get current date in M/d/yyyy format
$date = Get-Date -Format 'M/d/yyyy'

# Convert to Pacific Time
$timeZone = [System.TimeZoneInfo]::FindSystemTimeZoneById("Pacific Standard Time")
$time_PST = [System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId((Get-Date), $timeZone.Id).ToString("hh:mmtt")

# Extract event data
$claims = $eventGridEvent.data.claims
$resourceId = $eventGridEvent.data.resourceUri
$operationName = $eventGridEvent.data.operationName
$subject = $eventGridEvent.subject
$principalType = $eventGridEvent.data.authorization.evidence.principalType
$ipAddress = $claims.ipaddr

# Validate IP address
if (-not $ipAddress) {
    Write-Host "No IP address found in the claims. Skipping tagging for resource $resourceId"
    return
}

Write-Host "IP Address: $ipAddress"

# Validate principal type
$allowedPrincipalTypes = @("User", "ServicePrincipal", "ManagedIdentity")
if ($principalType -notin $allowedPrincipalTypes) {
    Write-Host "Event initiated by $principalType. Skipping tagging for resource $resourceId"
    return
}

# Determine creator identity
$name = $claims.name
$email = $claims.'http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress'

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

# Log extracted information
Write-Host "Name: $name"
Write-Host "Email: $email"
Write-Host "Creator: $creator"
Write-Host "Resource ID: $resourceId"
Write-Host "Principal Type: $principalType"
Write-Host "Date: $date"
Write-Host "Time PST: $time_PST"
Write-Host "Operation Name: $operationName"
Write-Host "Subject: $subject"

# Define included resource types
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
)

# Determine resource type
if ($resourceId -match "^/subscriptions/[^/]+/resourceGroups/[^/]+$") {
    $resourceType = "Microsoft.Resources/resourceGroups"
    Write-Host "Resource Type: $resourceType"
    
    $resourceGroup = Get-AzResourceGroup -ResourceId $resourceId -ErrorAction SilentlyContinue
    if ($resourceGroup -eq $null) {
        Write-Host "Failed to retrieve resource group. Skipping tagging for resource group $resourceId"
        return
    }
} else {
    $resource = Get-AzResource -ResourceId $resourceId -ErrorAction SilentlyContinue
    if ($resource -ne $null) {
        $resourceType = $resource.ResourceType
        Write-Host "Resource Type: $resourceType"
    } else {
        Write-Host "Failed to retrieve resource. Skipping tagging for resource $resourceId"
        return
    }
}

# Validate resource type
if ($resourceType -eq $null -or $includedResourceTypes -notcontains $resourceType) {
    Write-Host "Resource type $resourceType is not in the included list. Skipping tagging for resource $resourceId"
    return
}

# Main tagging logic with error handling
try {
    # Get current tags
    if ($resourceType -eq "Microsoft.Resources/resourceGroups") {
        $currentTags = @{ Tags = $resourceGroup.Tags }
    } else {
        Write-Host "Retrieving current tags for resource $resourceId..."
        $currentTags = Get-AzTag -ResourceId $resourceId
    }

    # Initialize tags if null
    if (-not $currentTags -or -not $currentTags.Tags) {
        Write-Host "No tags found. Initializing new tags."
        $currentTags = @{ Tags = @{} }
    } else {
        Write-Host "Current Tags: $($currentTags.Tags | ConvertTo-Json)"
    }

    # Define immutable tags that indicate an existing resource
    $immutableTags = @("Creator", "DateCreated", "TimeCreatedInPST")
    
    # Check if ANY of the immutable tags exist
    $isExistingResource = $false
    foreach ($tag in $immutableTags) {
        if ($currentTags.Tags.ContainsKey($tag)) {
            $isExistingResource = $true
            Write-Host "Found existing immutable tag: $tag"
            break
        }
    }

    if ($isExistingResource) {
        # Existing resource - only update LastModified metadata
        # Do not touch the immutable tags
        Write-Host "Existing resource detected - only updating modification metadata"
        
        $modifiedTags = @{
            LastModifiedBy = $creator
            LastModifiedDate = $date
        }
        Write-Host "Updating LastModified tags: $($modifiedTags | ConvertTo-Json)"
        Update-AzTag -ResourceId $resourceId -Tag $modifiedTags -Operation Merge
    }
    else {
        # New resource - set all initial tags
        Write-Host "New resource - setting all initial tags"
        
        $tagsToUpdate = @{
            # Immutable tags
            Creator = $creator
            DateCreated = $date
            TimeCreatedInPST = $time_PST
            # Modifiable tags
            LastModifiedBy = $creator
            LastModifiedDate = $date
        }
        Write-Host "Setting initial tags: $($tagsToUpdate | ConvertTo-Json)"
        Update-AzTag -ResourceId $resourceId -Tag $tagsToUpdate -Operation Merge
    }

    Write-Host "Successfully updated tags for resource $resourceId"

} catch {
    Write-Host "Failed to update tags for resource $resourceId. Error: $($_.Exception.Message)"
    Write-Host "Stack Trace: $($_.Exception.StackTrace)"
}
