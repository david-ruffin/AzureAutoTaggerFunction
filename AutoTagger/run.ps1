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

# Extract resource and operation info
$claims = $eventGridEvent.data.claims
$resourceId = $eventGridEvent.data.resourceUri
$operationName = $eventGridEvent.data.operationName
$subject = $eventGridEvent.subject
$principalType = $eventGridEvent.data.authorization.evidence.principalType

# Skip excluded operations
$excludedOperations = @(
    "Microsoft.Resources/tags/write",
    "Microsoft.EventGrid/eventSubscriptions/write",
    "Microsoft.HybridCompute/machines/extensions/write",
    "Microsoft.EventGrid/systemTopics/write",
    "Microsoft.HybridCompute/machines/write",
    "Microsoft.Maintenance/configurationAssignments/write",
    "Microsoft.GuestConfiguration/guestConfigurationAssignments/write",
    "Microsoft.PolicyInsights/PolicyStates/write",
    "Microsoft.Compute/virtualMachines/extensions/write",
    "Microsoft.Compute/virtualMachines/installPatches/action",
    "Microsoft.Compute/virtualMachines/assessPatches/action",
    "Microsoft.PolicyInsights/policyStates/write",
    "Microsoft.PolicyInsights/attestations/write",
    "Microsoft.GuestConfiguration/configurationassignments/write",
    "Microsoft.Maintenance/updates/write",
    "Microsoft.Compute/virtualMachines/updateState/write",
    "Microsoft.Compute/restorePointCollections/restorePoints/write",
    "Microsoft.RecoveryServices/backup/write"
)

if ($excludedOperations -contains $operationName -or $operationName -like "Microsoft.RecoveryServices/backup/*") {
    Write-Host "Excluded operation: $operationName"
    return
}

# Validate principal type
$allowedPrincipalTypes = @("User", "ServicePrincipal", "ManagedIdentity")
if ($principalType -notin $allowedPrincipalTypes) {
    Write-Host "Event initiated by $principalType. Skipping tagging"
    return
}

# Get creator info
$creator = $claims.name ?? 
           $claims.'http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress' ?? 
           ($principalType -in @("ServicePrincipal","ManagedIdentity") ? "Service Principal ID $($claims.appid)" : "Unknown")

# Get current date/time
$date = Get-Date -Format 'M/d/yyyy'
$time_PST = [System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId((Get-Date), "Pacific Standard Time").ToString("hh:mmtt")

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

try {
    # Get resource type
    $resource = Get-AzResource -ResourceId $resourceId -ErrorAction Stop
    if (-not $resource) {
        Write-Host "Failed to retrieve resource $resourceId"
        return
    }
    
    if ($includedResourceTypes -notcontains $resource.ResourceType) {
        Write-Host "Resource type $($resource.ResourceType) not in included list"
        return
    }

    # Get current tags
    Write-Host "Getting tags for resource $resourceId"
    $currentTags = Get-AzTag -ResourceId $resourceId -ErrorAction Stop
    Write-Host "Current tags: $($currentTags | ConvertTo-Json)"

    # Check for Creator tag
    if ($currentTags.Properties.TagsProperty.Creator) {
        Write-Host "Creator tag exists, updating LastModified only"
        $tagsToUpdate = @{
            LastModifiedBy = $creator
            LastModifiedDate = $date
        }
    } else {
        Write-Host "No Creator tag found, setting initial tags"
        $tagsToUpdate = @{
            Creator = $creator
            DateCreated = $date
            TimeCreatedInPST = $time_PST
            LastModifiedBy = $creator
            LastModifiedDate = $date
        }
    }

    $result = Update-AzTag -ResourceId $resourceId -Tag $tagsToUpdate -Operation Merge
    Write-Host "Tag update result: $($result | ConvertTo-Json)"
}
catch {
    Write-Host "Error: $($_.Exception.Message)"
    Write-Host "Stack: $($_.Exception.StackTrace)"
}
