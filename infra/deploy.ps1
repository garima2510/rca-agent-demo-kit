#requires -Version 7.0
[CmdletBinding()]
param(
    [string] $SubscriptionId,
    [string] $ConfigFile = (Join-Path $PSScriptRoot 'deployment.config.json'),
    [string] $MetastoreId,
    [switch] $ValidateOnly,
    [switch] $Yes
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-DeploymentLog {
    param([string] $Message)

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message"
}

function Invoke-AzJson {
    param([Parameter(Mandatory)][string[]] $Arguments)

    $operation = $Arguments[0..([Math]::Min(2, $Arguments.Count - 1))] -join ' '
    Write-DeploymentLog "Starting Azure CLI: $operation"
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $result = & az @Arguments --only-show-errors --output json
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI failed: az $($Arguments[0..([Math]::Min(2, $Arguments.Count - 1))] -join ' '). See the CLI error above."
    }
    Write-DeploymentLog "Completed: $operation ($([int] $timer.Elapsed.TotalSeconds)s)"
    if ($result) {
        return ($result -join "`n" | ConvertFrom-Json -AsHashtable)
    }
}

function Wait-ArmDeployment {
    param([string] $Subscription, [string] $ResourceGroup, [string] $Name)

    $scope = @('--subscription', $Subscription, '--resource-group', $ResourceGroup, '--name', $Name)
    $seen = @{}
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $deployment = Invoke-AzJson -Arguments (@('deployment', 'group', 'show') + $scope)
        $state = $deployment.properties.provisioningState
        $operations = @(Invoke-AzJson -Arguments (@('deployment', 'operation', 'group', 'list') + $scope))
        foreach ($operation in $operations) {
            $properties = $operation.properties
            if (-not $properties['targetResource']) { continue }
            $resource = $properties.targetResource
            $resourceState = $properties.provisioningState
            $key = "$($resource.resourceType)/$($resource.resourceName)"
            if (-not $seen.ContainsKey($key) -or $seen[$key] -ne $resourceState) {
                Write-DeploymentLog "Resource $($resource.resourceName) [$($resource.resourceType)]: $resourceState"
                $seen[$key] = $resourceState
                if ($resourceState -eq 'Failed' -and $properties['statusMessage']) {
                    Write-Host ($properties.statusMessage | ConvertTo-Json -Depth 20)
                }
            }
        }
        Write-DeploymentLog "ARM deployment: $state | elapsed $($timer.Elapsed.ToString('hh\:mm\:ss'))"
        if ($state -eq 'Succeeded') { return $deployment }
        if ($state -in @('Failed', 'Canceled')) {
            $detail = $deployment.properties['error'] | ConvertTo-Json -Depth 20 -Compress
            throw "ARM deployment '$Name' $state. $detail Inspect resource group > Deployments > $Name."
        }
        Start-Sleep -Seconds 15
    }
}

function Read-DeploymentConfig {
    param([string] $Path)

    $config = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    foreach ($key in @('resourceGroupName', 'location', 'prefix', 'modelSku', 'models', 'warehouseName', 'warehouseSize', 'warehouseAutoStopMinutes')) {
        if (-not $config.ContainsKey($key) -or $null -eq $config[$key] -or "$($config[$key])".Trim() -eq '') {
            throw "Configuration is missing '$key'."
        }
    }
    if ($config.prefix -cnotmatch '^[a-z][a-z0-9]{2,10}$') {
        throw 'prefix must be 3-11 lowercase letters/digits, starting with a letter.'
    }
    if ($config.resourceGroupName -notmatch '^[a-zA-Z0-9_-]{1,80}$') {
        throw 'resourceGroupName must contain 1-80 letters, digits, underscores or hyphens.'
    }
    if ($config.location -cnotmatch '^[a-z0-9]+$') {
        throw 'location must be an Azure region name such as francecentral.'
    }
    if ($config.modelSku -notin @('GlobalStandard', 'DataZoneStandard')) {
        throw 'modelSku must be GlobalStandard or DataZoneStandard.'
    }
    if ($config.models.Count -ne 3) {
        throw 'Configure exactly three models: agent, query planner and embedding.'
    }
    $names = @()
    foreach ($model in $config.models) {
        foreach ($key in @('name', 'model', 'version', 'capacity')) {
            if (-not $model.ContainsKey($key) -or "$($model[$key])".Trim() -eq '') {
                throw "A model deployment is missing '$key'."
            }
        }
        if ($model.name -notmatch '^[a-zA-Z0-9_-]{1,64}$' -or $model.name -in $names) {
            throw 'Model deployment names must be unique and contain only letters, digits, underscores or hyphens.'
        }
        $names += $model.name
        if ($model.capacity -isnot [long] -and $model.capacity -isnot [int]) {
            throw "Capacity for $($model.name) must be an integer."
        }
        if ($model.capacity -lt 1) {
            throw "Capacity for $($model.name) must be positive."
        }
    }
    if ($config.warehouseAutoStopMinutes -isnot [long] -and $config.warehouseAutoStopMinutes -isnot [int]) {
        throw 'warehouseAutoStopMinutes must be an integer.'
    }
    if ($config.warehouseAutoStopMinutes -lt 5 -or $config.warehouseAutoStopMinutes -gt 120) {
        throw 'warehouseAutoStopMinutes must be between 5 and 120.'
    }
    if ($config.warehouseSize -notin @('2X-Small', 'X-Small', 'Small', 'Medium', 'Large', 'X-Large')) {
        throw 'Unsupported warehouseSize. Use 2X-Small, X-Small, Small, Medium, Large or X-Large.'
    }
    return $config
}

function Assert-ModelAvailability {
    param([hashtable] $Config, [array] $Catalog, [array] $Usage, [array] $ExistingDeployments = @())

    $requiredQuota = @{}
    foreach ($deployment in $Config.models) {
        $matches = @($Catalog | Where-Object {
            $_.kind -eq 'AIServices' -and $_.model.name -eq $deployment.model -and $_.model.version -eq $deployment.version
        })
        if ($matches.Count -ne 1) {
            throw "Model $($deployment.model) version $($deployment.version) is not available in $($Config.location). Edit deployment.config.json; no model/region fallback is applied."
        }
        $skus = @($matches[0].model.skus | Where-Object { $_.name -eq $Config.modelSku })
        if ($skus.Count -ne 1) {
            throw "$($deployment.model) does not support $($Config.modelSku) in $($Config.location)."
        }
        $sku = $skus[0]
        if ($sku.ContainsKey('capacity') -and $null -ne $sku.capacity) {
            $limits = $sku.capacity
            $minimum = $limits['minimum']
            $maximum = $limits['maximum']
            $step = $limits['step']
            $stepBase = if ($null -ne $minimum) { $minimum } else { 0 }
            if (($null -ne $minimum -and $deployment.capacity -lt $minimum) -or
                ($null -ne $maximum -and $deployment.capacity -gt $maximum) -or
                ($null -ne $step -and $step -gt 0 -and (($deployment.capacity - $stepBase) % $step) -ne 0) -or
                ($limits['allowedValues'] -and $deployment.capacity -notin $limits['allowedValues'])) {
                throw "Invalid capacity for $($deployment.name). Allowed: $($limits.minimum)-$($limits.maximum), step $($limits.step)."
            }
        }
        if (-not $sku.ContainsKey('usageName') -or -not $sku.usageName) {
            throw "The catalog did not return a quota usageName for $($deployment.model)/$($Config.modelSku). Cannot safely check quota."
        }
        $quotaName = $sku.usageName
        if (-not $requiredQuota.ContainsKey($quotaName)) { $requiredQuota[$quotaName] = 0 }
        $credit = 0
        foreach ($existing in $ExistingDeployments) {
            if ($existing.name -eq $deployment.name -and $existing.sku.name -eq $Config.modelSku -and
                $existing.properties.model.name -eq $deployment.model) {
                $credit = $existing.sku.capacity
            }
        }
        $requiredQuota[$quotaName] += [Math]::Max(0, $deployment.capacity - $credit)
    }
    foreach ($quotaName in $requiredQuota.Keys) {
        $quota = @($Usage | Where-Object { $_.name.value -eq $quotaName })
        if ($quota.Count -ne 1) { throw "Cannot find subscription quota '$quotaName' in $($Config.location)." }
        $available = $quota[0].limit - $quota[0].currentValue
        if ($available -lt $requiredQuota[$quotaName]) {
            throw "Insufficient quota for $quotaName in $($Config.location): need $($requiredQuota[$quotaName]) additional units, have $available. Request quota or explicitly change the configuration."
        }
        Write-Host "Quota OK: $quotaName ($available available; $($requiredQuota[$quotaName]) additional required)."
    }
}

function Invoke-DatabricksRequest {
    param(
        [string] $WorkspaceUrl,
        [hashtable] $Headers,
        [string] $Path,
        [string] $Method = 'GET',
        [hashtable] $Body
    )

    for ($attempt = 1; $attempt -le 6; $attempt++) {
        try {
            $parameters = @{
                Uri = "$WorkspaceUrl$Path"
                Headers = $Headers
                Method = $Method
                ContentType = 'application/json'
                TimeoutSec = 120
            }
            if ($null -ne $Body) { $parameters.Body = $Body | ConvertTo-Json -Depth 20 -Compress }
            $response = Invoke-WebRequest @parameters
            if ($response.Content) {
                return ($response.Content | ConvertFrom-Json -AsHashtable)
            }
            return
        }
        catch {
            $status = Get-HttpStatusCode -Exception $_.Exception
            if ($status -in @(401, 403, 429, 500, 502, 503, 504) -and $attempt -lt 6) {
                Write-Warning "Databricks $Method $Path returned HTTP $status; retry $attempt/5 in 15 seconds."
                Start-Sleep -Seconds 15
                continue
            }
            throw
        }
    }
}

function Get-HttpStatusCode {
    param([Exception] $Exception)

    $response = $Exception.PSObject.Properties['Response']
    if ($response -and $response.Value) { return [int] $response.Value.StatusCode }
    return 0
}

function Initialize-Databricks {
    param([hashtable] $Config, [hashtable] $Outputs, [hashtable] $Headers, [string] $MetastoreId)

    Write-DeploymentLog '[7/8] Checking Databricks Unity Catalog and configuring serverless SQL.'
    $url = $Outputs.databricksWorkspaceUrl.value
    $request = @{ WorkspaceUrl = $url; Headers = $Headers }
    $assignment = $null
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        try {
            $assignment = Invoke-DatabricksRequest @request -Path '/api/2.1/unity-catalog/current-metastore-assignment'
        }
        catch {
            if ((Get-HttpStatusCode -Exception $_.Exception) -ne 404) { throw }
            Write-Warning 'This workspace does not yet have a Unity Catalog metastore assignment.'
        }
        if (($assignment -and $assignment['metastore_id']) -or $MetastoreId -or $attempt -eq 6) { break }
        Write-Host 'Waiting 10 seconds for automatic Unity Catalog assignment...'
        Start-Sleep -Seconds 10
    }
    if ($assignment -and $assignment['metastore_id']) {
        if ($MetastoreId -and $assignment.metastore_id -ne $MetastoreId) {
            throw "Workspace already uses metastore $($assignment.metastore_id). Refusing to replace it with $MetastoreId."
        }
    }
    elseif ($MetastoreId) {
        $workspaceNumber = $Outputs.databricksWorkspaceNumber.value
        $null = Invoke-DatabricksRequest @request -Path "/api/2.1/unity-catalog/workspaces/$workspaceNumber/metastore" -Method PUT -Body @{
            metastore_id = $MetastoreId
            default_catalog_name = 'main'
        }
        $assignment = Invoke-DatabricksRequest @request -Path '/api/2.1/unity-catalog/current-metastore-assignment'
    }
    if (-not $assignment -or -not $assignment['metastore_id']) {
        throw 'Unity Catalog is not enabled. Ask a Databricks account admin to create/assign a France Central metastore, then rerun with -MetastoreId <id>. Azure resources remain deployed; the deployment is NOT complete.'
    }
    Write-Host "Unity Catalog verified: $($assignment.metastore_id)"

    $warehouses = Invoke-DatabricksRequest @request -Path '/api/2.0/sql/warehouses'
    $existing = @($warehouses['warehouses'] | Where-Object { $_ -and $_.name -eq $Config.warehouseName })
    if ($existing.Count -gt 1) { throw "More than one warehouse named '$($Config.warehouseName)' exists." }
    $settings = @{
        name = $Config.warehouseName
        cluster_size = $Config.warehouseSize
        min_num_clusters = 1
        max_num_clusters = 1
        auto_stop_mins = $Config.warehouseAutoStopMinutes
        enable_serverless_compute = $true
        warehouse_type = 'PRO'
    }
    if ($existing.Count -eq 1) {
        $warehouseId = $existing[0].id
        Write-DeploymentLog "Reusing SQL warehouse '$($Config.warehouseName)' ($warehouseId)."
        $changed = @($settings.Keys | Where-Object { $existing[0][$_] -ne $settings[$_] })
        if ($changed.Count -gt 0) {
            Write-DeploymentLog 'Updating SQL warehouse settings.'
            $null = Invoke-DatabricksRequest @request -Path "/api/2.0/sql/warehouses/$warehouseId/edit" -Method POST -Body $settings
        }
    }
    else {
        Write-DeploymentLog "Creating serverless SQL warehouse '$($Config.warehouseName)'."
        $created = Invoke-DatabricksRequest @request -Path '/api/2.0/sql/warehouses' -Method POST -Body $settings
        $warehouseId = $created.id
    }
    if (-not $warehouseId) { throw 'Databricks did not return a warehouse ID.' }
    $warehouse = Invoke-DatabricksRequest @request -Path "/api/2.0/sql/warehouses/$warehouseId"
    $deadline = [DateTime]::UtcNow.AddMinutes(20)
    while ($warehouse.state -ne 'RUNNING') {
        if ($warehouse.state -in @('DELETING', 'DELETED') -or [DateTime]::UtcNow -gt $deadline) {
            throw "Warehouse $warehouseId did not become RUNNING within 20 minutes. Inspect $url/sql/warehouses/$warehouseId."
        }
        if ($warehouse.state -eq 'STOPPED') {
            $null = Invoke-DatabricksRequest @request -Path "/api/2.0/sql/warehouses/$warehouseId/start" -Method POST
        }
        Write-DeploymentLog "Waiting for serverless warehouse: $($warehouse.state)..."
        Start-Sleep -Seconds 15
        $warehouse = Invoke-DatabricksRequest @request -Path "/api/2.0/sql/warehouses/$warehouseId"
    }
    if (-not $warehouse.enable_serverless_compute) { throw 'Warehouse is not serverless. No classic-compute fallback is permitted.' }
    Write-DeploymentLog '[8/8] Serverless warehouse is RUNNING. Executing SQL smoke test (SELECT 1).'
    $statement = Invoke-DatabricksRequest @request -Path '/api/2.0/sql/statements' -Method POST -Body @{
        warehouse_id = $warehouseId
        statement = 'SELECT 1 AS deployment_check'
        wait_timeout = '50s'
        on_wait_timeout = 'CONTINUE'
    }
    $deadline = [DateTime]::UtcNow.AddMinutes(3)
    while ($statement.status.state -in @('PENDING', 'RUNNING') -and [DateTime]::UtcNow -lt $deadline) {
        Write-DeploymentLog "SQL smoke test: $($statement.status.state)"
        Start-Sleep -Seconds 5
        $statement = Invoke-DatabricksRequest @request -Path "/api/2.0/sql/statements/$($statement.statement_id)"
    }
    if ($statement.status.state -ne 'SUCCEEDED') {
        throw "SQL smoke test failed: $($statement.status | ConvertTo-Json -Depth 10 -Compress)"
    }
    if ($statement.result.data_array[0][0] -ne '1') { throw 'SQL smoke test returned an unexpected result.' }
    Write-DeploymentLog 'SQL smoke test passed.'
    return @{ warehouseId = $warehouseId; metastoreId = $assignment.metastore_id }
}

function Start-RcaDeployment {
    $deploymentTimer = [Diagnostics.Stopwatch]::StartNew()
    Write-DeploymentLog '[1/8] Reading configuration and compiling the infrastructure template.'
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI is required. Install it from https://aka.ms/installazurecliwindows and reopen the terminal.'
    }
    $config = Read-DeploymentConfig -Path $ConfigFile
    $template = Join-Path $PSScriptRoot 'main.bicep'
    $null = Invoke-AzJson -Arguments @('bicep', 'build', '--file', $template, '--stdout')

    Write-DeploymentLog '[2/8] Checking Azure login and selecting the subscription.'
    $accounts = @(Invoke-AzJson -Arguments @('account', 'list'))
    if ($accounts.Count -eq 0) {
        $null = Invoke-AzJson -Arguments @('login')
        $accounts = @(Invoke-AzJson -Arguments @('account', 'list'))
    }
    $accounts = @($accounts | Where-Object { $_.state -eq 'Enabled' })
    if ($accounts.Count -eq 0) { throw 'No enabled Azure subscriptions are available.' }
    if ($SubscriptionId) {
        $selected = @($accounts | Where-Object { $_.id -eq $SubscriptionId })
        if ($selected.Count -ne 1) { throw "Subscription '$SubscriptionId' is not available. Run az login for the correct tenant." }
        $account = $selected[0]
    }
    else {
        for ($i = 0; $i -lt $accounts.Count; $i++) {
            Write-Host "[$($i + 1)] $($accounts[$i].name) ($($accounts[$i].id))"
        }
        $choice = Read-Host 'Select subscription number'
        $index = 0
        if (-not [int]::TryParse($choice, [ref] $index) -or $index -lt 1 -or $index -gt $accounts.Count) {
            throw 'Invalid subscription selection.'
        }
        $account = $accounts[$index - 1]
    }
    $subscription = $account.id
    Write-Host "`nSubscription: $($account.name) ($subscription)"
    Write-Host "Resource group: $($config.resourceGroupName); region: $($config.location)"
    Write-Host "Foundry project: rca-project; model SKU: $($config.modelSku)"
    $config.models | ForEach-Object { [pscustomobject] $_ } | Format-Table name, model, version, capacity | Out-Host
    Write-Host 'Also: Search Basic + semantic ranker, private blob container, Databricks Premium + serverless SQL, managed identities and RBAC.'
    Write-Warning 'Billable demo resources with public network endpoints (Entra authentication). GlobalStandard can process model requests outside the EU. No Copilot Studio or ServiceNow provisioning.'
    if (-not $ValidateOnly -and -not $Yes -and (Read-Host 'Type DEPLOY to proceed') -cne 'DEPLOY') {
        throw 'Deployment cancelled. No Azure resources were changed.'
    }

    Write-DeploymentLog '[3/8] Checking existing resources, model availability and subscription quota.'
    $groupExists = Invoke-AzJson -Arguments @('group', 'exists', '--name', $config.resourceGroupName, '--subscription', $subscription)
    $existingModels = @()
    if ($groupExists) {
        $group = Invoke-AzJson -Arguments @('group', 'show', '--name', $config.resourceGroupName, '--subscription', $subscription)
        if ($group.location -ne $config.location) { throw 'The existing resource group has a different location. Use a new resourceGroupName or match location.' }
        $resources = @(Invoke-AzJson -Arguments @('resource', 'list', '--resource-group', $config.resourceGroupName, '--subscription', $subscription))
        $accountPattern = '^' + [regex]::Escape($config.prefix) + '-[a-z0-9]{13}-ai$'
        $foundryAccounts = @($resources | Where-Object {
            $_.type -eq 'Microsoft.CognitiveServices/accounts' -and $_.name -cmatch $accountPattern -and
            $_['tags'] -and $_.tags['application'] -eq 'rca-demo-kit'
        })
        if ($foundryAccounts.Count -gt 1) { throw 'Multiple matching Foundry accounts exist. Cannot safely calculate rerun quota.' }
        foreach ($foundry in $foundryAccounts) {
            $existingModels += @(Invoke-AzJson -Arguments @('cognitiveservices', 'account', 'deployment', 'list', '--name', $foundry.name, '--resource-group', $config.resourceGroupName, '--subscription', $subscription))
        }
    }
    $catalog = @(Invoke-AzJson -Arguments @('cognitiveservices', 'model', 'list', '--location', $config.location, '--subscription', $subscription))
    $usage = @(Invoke-AzJson -Arguments @('cognitiveservices', 'usage', 'list', '--location', $config.location, '--subscription', $subscription))
    Assert-ModelAvailability -Config $config -Catalog $catalog -Usage $usage -ExistingDeployments $existingModels
    if ($ValidateOnly) {
        Write-Host 'Preflight passed: configuration, Bicep compilation, model/SKU availability and quota. No Azure resources changed. ARM policies, RBAC and Databricks readiness are checked during deployment.'
        return
    }

    Write-DeploymentLog '[4/8] Registering Azure resource providers and ensuring the resource group exists.'
    foreach ($provider in @('Microsoft.CognitiveServices', 'Microsoft.Search', 'Microsoft.Storage', 'Microsoft.Databricks')) {
        Write-DeploymentLog "Ensuring provider $provider is registered; Azure registration can take several minutes."
        $null = Invoke-AzJson -Arguments @('provider', 'register', '--namespace', $provider, '--wait', '--subscription', $subscription)
    }
    if (-not $groupExists) {
        $null = Invoke-AzJson -Arguments @('group', 'create', '--name', $config.resourceGroupName, '--location', $config.location, '--subscription', $subscription, '--tags', 'application=rca-demo-kit', 'environment=demo')
    }
    $token = Invoke-AzJson -Arguments @('account', 'get-access-token', '--resource', 'https://management.azure.com/', '--subscription', $subscription)
    $payload = $token.accessToken.Split('.')[1].Replace('-', '+').Replace('_', '/')
    $payload = $payload.PadRight($payload.Length + ((4 - $payload.Length % 4) % 4), '=')
    $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json -AsHashtable
    if (-not $claims.ContainsKey('oid') -or -not $claims.oid) { throw 'The Azure token has no object ID for operator role assignments.' }
    $principalType = if ($account.user.type -eq 'servicePrincipal') { 'ServicePrincipal' } else { 'User' }
    $parameters = @{
        '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters = @{
            prefix = @{ value = $config.prefix }
            location = @{ value = $config.location }
            operatorPrincipalId = @{ value = $claims.oid }
            operatorPrincipalType = @{ value = $principalType }
            modelSku = @{ value = $config.modelSku }
            models = @{ value = $config.models }
        }
    }
    $parameterFile = Join-Path ([IO.Path]::GetTempPath()) "rca-parameters-$([Guid]::NewGuid()).json"
    try {
        $parameters | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $parameterFile -Encoding utf8
        $deploymentArgs = @('--resource-group', $config.resourceGroupName, '--subscription', $subscription, '--name', 'rca-demo-infra', '--template-file', $template, '--parameters', "@$parameterFile")
        Write-DeploymentLog '[5/8] Validating the ARM deployment, permissions and policies. This can take several minutes.'
        $null = Invoke-AzJson -Arguments (@('deployment', 'group', 'validate') + $deploymentArgs)
        Write-DeploymentLog '[6/8] Deploying Azure resources. Resource changes and a heartbeat will be shown every ~15 seconds.'
        Write-DeploymentLog "Portal: resource group '$($config.resourceGroupName)' > Deployments > rca-demo-infra."
        $null = Invoke-AzJson -Arguments (@('deployment', 'group', 'create') + $deploymentArgs + @('--no-wait'))
        $deployment = Wait-ArmDeployment -Subscription $subscription -ResourceGroup $config.resourceGroupName -Name 'rca-demo-infra'
    }
    finally {
        if (Test-Path -LiteralPath $parameterFile) { Remove-Item -LiteralPath $parameterFile }
    }
    if ($deployment.properties.provisioningState -ne 'Succeeded') { throw 'ARM deployment did not succeed.' }
    $outputs = $deployment.properties.outputs
    $outputFile = Join-Path $PSScriptRoot 'deployment.outputs.json'
    $summary = @{ status = 'Azure resources deployed; Databricks initialization pending'; subscriptionId = $subscription; resourceGroupName = $config.resourceGroupName; location = $config.location }
    foreach ($key in $outputs.Keys) { $summary[$key] = $outputs[$key].value }
    $summary | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $outputFile -Encoding utf8
    Write-Host "Azure resources deployed. Initializing Databricks; resource details saved to $outputFile."
    $dbToken = Invoke-AzJson -Arguments @('account', 'get-access-token', '--resource', '2ff814a6-3304-4ab8-85cb-cd0e6f879c1d', '--subscription', $subscription)
    $armToken = Invoke-AzJson -Arguments @('account', 'get-access-token', '--resource', 'https://management.azure.com/', '--subscription', $subscription)
    $headers = @{
        Authorization = "Bearer $($dbToken.accessToken)"
        'X-Databricks-Azure-SP-Management-Token' = $armToken.accessToken
        'X-Databricks-Azure-Workspace-Resource-Id' = $outputs.databricksWorkspaceId.value
    }
    try {
        $databricks = Initialize-Databricks -Config $config -Outputs $outputs -Headers $headers -MetastoreId $MetastoreId
    }
    catch {
        $summary.status = 'Azure resources deployed; Databricks initialization failed'
        $summary.error = $_.Exception.Message
        $summary | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $outputFile -Encoding utf8
        throw
    }
    $summary.warehouseId = $databricks.warehouseId
    $summary.metastoreId = $databricks.metastoreId
    $summary.status = 'Step 0 complete'
    $summary | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $outputFile -Encoding utf8
    Write-DeploymentLog "Deployment finished successfully in $($deploymentTimer.Elapsed.ToString('hh\:mm\:ss'))."
    Write-Host "`nStep 0 complete. SQL smoke test passed. Details: $outputFile"
    Write-Host "Foundry: $($summary.foundryProjectEndpoint)"
    Write-Host "Databricks: $($summary.databricksWorkspaceUrl)"
    Write-Host 'Continue with setup guide Steps 1-4. ServiceNow developer-instance signup remains manual.'
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        Start-RcaDeployment
    }
    catch {
        Write-Error -Message "Deployment failed: $($_.Exception.Message) Existing resources were not deleted; fix the error and rerun." -ErrorAction Continue
        exit 1
    }
}
