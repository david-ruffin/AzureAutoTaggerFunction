param($eventGridEvent, $TriggerMetadata)

Import-Module Az.Resources
if (-not $?) {
    Write-Host "Failed to import Az.Resources module. Exiting script."
    exit 1
}

Import-Module Az.Accounts
if (-not $?) {
    Write-Host "Failed to import Az.Accounts module. Exiting script."
    exit 1
}

# Log the full event for debugging
$eventGridEvent | ConvertTo-Json -Depth 5 | Write-Host

# Get current date/time in Pacific timezone
$date = Get-Date -Format 'M/d/yyyy'
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

# Validate principal type
$allowedPrincipalTypes = @("User", "ServicePrincipal", "ManagedIdentity")
if ($principalType -notin $allowedPrincipalTypes) {
    Write-Host "Event initiated by $principalType. Skipping tagging for resource $resourceId"
    return
}

# Determine creator identity
$name = $claims.name
$email = $claims.'http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress'

if ($name) {
    $creator = $name
}
elseif ($email) {
    $creator = $email
}
elseif ($principalType -eq "ServicePrincipal" -or $principalType -eq "ManagedIdentity") {
    $appid = $claims.appid
    $creator = "Service Principal ID " + $appid
}
else {
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

# Get resource type and current tags
if ($resourceId -match "^/subscriptions/[^/]+/resourceGroups/[^/]+$") {
    $resourceType = "Microsoft.Resources/resourceGroups"
    Write-Host "Resource Type: $resourceType"
    
    $resourceGroup = Get-AzResourceGroup -ResourceId $resourceId -ErrorAction SilentlyContinue
    if (-not $resourceGroup) {
        Write-Host "Failed to retrieve resource group. Skipping tagging for resource group $resourceId"
        return
    }
    $currentTags = @{ Tags = $resourceGroup.Tags }
} 
else {
    $resource = Get-AzResource -ResourceId $resourceId -ErrorAction SilentlyContinue
    if (-not $resource) {
        Write-Host "Failed to retrieve resource. Skipping tagging for resource $resourceId"
        return
    }
    $resourceType = $resource.ResourceType
    Write-Host "Resource Type: $resourceType"
    $currentTags = Get-AzTag -ResourceId $resourceId -ErrorAction SilentlyContinue
}

# Validate resource type
if (-not $resourceType -or $includedResourceTypes -notcontains $resourceType) {
    Write-Host "Resource type $resourceType is not in the included list. Skipping tagging for resource $resourceId"
    return
}

try {
    if (-not $currentTags -or -not $currentTags.Tags -or -not $currentTags.Tags.ContainsKey("Creator")) {
        Write-Host "No Creator tag found - setting initial tags while preserving existing tags"
        
        # Initialize with any existing tags
        $tagsToUpdate = @{}
        if ($currentTags -and $currentTags.Tags) {
            $currentTags.Tags.GetEnumerator() | ForEach-Object {
                $tagsToUpdate[$_.Key] = $_.Value
            }
        }

        # Add our new tags
        $tagsToUpdate["Creator"] = $creator
        $tagsToUpdate["DateCreated"] = $date
        $tagsToUpdate["TimeCreatedInPST"] = $time_PST
        $tagsToUpdate["LastModifiedBy"] = $creator
        $tagsToUpdate["LastModifiedDate"] = $date

        Write-Host "Merging initial tags: $($tagsToUpdate | ConvertTo-Json)"
        Update-AzTag -ResourceId $resourceId -Tag $tagsToUpdate -Operation Merge
    }
    else {
        Write-Host "Creator tag exists - only updating LastModifiedBy and LastModifiedDate"
        $modifiedTags = @{
            LastModifiedBy = $creator
            LastModifiedDate = $date
        }
        Write-Host "Updating LastModified tags: $($modifiedTags | ConvertTo-Json)"
        Update-AzTag -ResourceId $resourceId -Tag $modifiedTags -Operation Merge
    }

    Write-Host "Successfully updated tags for resource $resourceId"
}
catch {
    Write-Host "Failed to update tags for resource $resourceId. Error: $($_.Exception.Message)"
    Write-Host "Stack Trace: $($_.Exception.StackTrace)"
}
