#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\deploy.ps1')

$script:passed = 0
function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}
function Test-Case {
    param([string] $Name, [scriptblock] $Run)
    & $Run
    $script:passed++
    Write-Host "PASS: $Name"
}
function Assert-Throws {
    param([scriptblock] $Run, [string] $Pattern)
    try { & $Run }
    catch {
        if ($_.Exception.Message -like $Pattern) { return }
        throw "Expected error '$Pattern', got '$($_.Exception.Message)'."
    }
    throw "Expected error '$Pattern', but the call succeeded."
}
function Copy-Config {
    return ($script:validConfig | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable)
}

$script:validConfig = Read-DeploymentConfig -Path (Join-Path $PSScriptRoot '..\deployment.config.json')
$script:catalog = @($validConfig.models | ForEach-Object {
    @{
        kind = 'AIServices'
        model = @{
            name = $_.model
            version = $_.version
            skus = @(@{
                name = 'GlobalStandard'
                usageName = "OpenAI.GlobalStandard.$($_.model)"
                capacity = @{ minimum = 1; maximum = 100; step = 1 }
            })
        }
    }
})
$script:usage = @($validConfig.models | ForEach-Object {
    @{ name = @{ value = "OpenAI.GlobalStandard.$($_.model)" }; limit = 100; currentValue = 0 }
})

Test-Case 'Default config has all three expected model deployments' {
    Assert-True ($validConfig.models.Count -eq 3) 'Expected three models.'
    Assert-True ($validConfig.location -eq 'francecentral') 'Expected France Central.'
    Assert-True ($validConfig.models[0].name -eq 'rca-agent') 'Expected agent deployment.'
    Assert-True ($validConfig.models[0].model -eq 'gpt-5.4' -and $validConfig.models[0].version -eq '2026-03-05') 'Expected GPT-5.4 agent.'
    Assert-True ($validConfig.models[1].model -eq 'gpt-5.4-mini' -and $validConfig.models[1].version -eq '2026-03-17') 'Expected GPT-5.4-mini planner.'
    Assert-True ($validConfig.models[2].model -eq 'text-embedding-3-large') 'Embedding model must remain unchanged.'
}
Test-Case 'Compiled ARM serializes model writes before project creation' {
    $compiled = & az bicep build --file (Join-Path $PSScriptRoot '..\main.bicep') --stdout --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw 'Bicep compilation failed.' }
    $template = $compiled -join "`n" | ConvertFrom-Json -AsHashtable
    $project = $template.resources['project']
    $models = $template.resources['deployments']
    Assert-True ($null -ne $project -and $null -ne $models) 'Expected project and model deployment resources.'
    Assert-True ($project.dependsOn -contains 'deployments') 'Project must wait for the entire model deployment collection.'
    Assert-True ($models.copy.mode -eq 'serial' -and $models.copy.batchSize -eq 1) 'Model writes must be serialized.'
    Assert-True ($models.dependsOn -notcontains 'project') 'Model deployment must not depend on the project (dependency cycle).'
}
Test-Case 'Invalid configuration is rejected before provisioning' {
    $file = Join-Path ([IO.Path]::GetTempPath()) "rca-test-$([Guid]::NewGuid()).json"
    try {
        $bad = Copy-Config
        $bad.prefix = 'TOO-LONG-AND-INVALID'
        $bad | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $file
        Assert-Throws { Read-DeploymentConfig -Path $file } '*prefix must*'
        $bad = Copy-Config
        $bad.models[1].name = $bad.models[0].name
        $bad | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $file
        Assert-Throws { Read-DeploymentConfig -Path $file } '*names must be unique*'
        $bad = Copy-Config
        $bad.models[0].capacity = 1.5
        $bad | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $file
        Assert-Throws { Read-DeploymentConfig -Path $file } '*must be an integer*'
    }
    finally { Remove-Item -LiteralPath $file }
}
Test-Case 'Valid model catalog and quota pass' {
    Assert-ModelAvailability -Config $validConfig -Catalog $catalog -Usage $usage
}
Test-Case 'Catalog entries for other account kinds do not cause false unavailability' {
    $otherKind = $catalog | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
    foreach ($entry in $otherKind) { $entry.kind = 'OpenAI' }
    Assert-ModelAvailability -Config $validConfig -Catalog (@($catalog) + @($otherKind)) -Usage $usage
}
Test-Case 'Nullable GPT-5.4 capacity limits are supported' {
    $nullable = $catalog | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
    foreach ($entry in $nullable) {
        $entry.model.skus[0].capacity = @{ minimum = $null; maximum = 10000000; step = $null; allowedValues = $null }
    }
    Assert-ModelAvailability -Config $validConfig -Catalog $nullable -Usage $usage
    $nullable[0].model.skus[0].capacity.maximum = 5
    Assert-Throws { Assert-ModelAvailability -Config $validConfig -Catalog $nullable -Usage $usage } '*Invalid capacity*'
}
Test-Case 'Unavailable model version fails without a fallback' {
    $bad = Copy-Config
    $bad.models[0].version = 'not-a-real-version'
    Assert-Throws { Assert-ModelAvailability -Config $bad -Catalog $catalog -Usage $usage } '*not available*'
}
Test-Case 'Unsupported SKU fails without a fallback' {
    $bad = Copy-Config
    $bad.modelSku = 'DataZoneStandard'
    Assert-Throws { Assert-ModelAvailability -Config $bad -Catalog $catalog -Usage $usage } '*does not support*'
}
Test-Case 'Insufficient quota blocks provisioning' {
    $lowQuota = @($usage | ForEach-Object { @{ name = $_.name; limit = 0; currentValue = 0 } })
    Assert-Throws { Assert-ModelAvailability -Config $validConfig -Catalog $catalog -Usage $lowQuota } '*Insufficient quota*'
}
Test-Case 'Reruns credit existing deployments when quota is exhausted' {
    $allocatedUsage = @($validConfig.models | ForEach-Object {
        @{ name = @{ value = "OpenAI.GlobalStandard.$($_.model)" }; limit = $_.capacity; currentValue = $_.capacity }
    })
    $existing = @($validConfig.models | ForEach-Object {
        @{ name = $_.name; sku = @{ name = 'GlobalStandard'; capacity = $_.capacity }; properties = @{ model = @{ name = $_.model } } }
    })
    Assert-ModelAvailability -Config $validConfig -Catalog $catalog -Usage $allocatedUsage -ExistingDeployments $existing
}
Test-Case 'Quota is aggregated for models sharing a quota pool' {
    $sharedCatalog = $catalog | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
    foreach ($entry in $sharedCatalog) { $entry.model.skus[0].usageName = 'shared-pool' }
    $sharedQuota = @(@{ name = @{ value = 'shared-pool' }; limit = 15; currentValue = 0 })
    Assert-Throws { Assert-ModelAvailability -Config $validConfig -Catalog $sharedCatalog -Usage $sharedQuota } '*need 21 additional units*'
}
Test-Case 'Non-HTTP errors retain their original meaning' {
    Assert-True ((Get-HttpStatusCode -Exception ([Exception]::new('DNS failure'))) -eq 0) 'Unexpected HTTP status.'
}

$script:calls = [Collections.Generic.List[string]]::new()
$script:mode = 'create'
$script:assigned = $false
$script:started = $false
$script:outputs = @{
    databricksWorkspaceUrl = @{ value = 'https://example.azuredatabricks.net' }
    databricksWorkspaceNumber = @{ value = '123' }
}
function Start-Sleep {}
function Invoke-DatabricksRequest {
    param($WorkspaceUrl, $Headers, $Path, $Method = 'GET', $Body)
    $script:calls.Add("$Method $Path")
    switch ($Path) {
        '/api/2.1/unity-catalog/current-metastore-assignment' {
            if ($script:mode -eq 'no-metastore') { return @{} }
            if ($script:mode -eq 'attach' -and -not $script:assigned) { return @{} }
            return @{ metastore_id = 'metastore-1' }
        }
        '/api/2.1/unity-catalog/workspaces/123/metastore' {
            Assert-True ($Method -eq 'PUT' -and $Body.metastore_id -eq 'metastore-1') 'Invalid metastore assignment request.'
            $script:assigned = $true
            return @{}
        }
        '/api/2.0/sql/warehouses' {
            if ($Method -eq 'GET') {
                if ($script:mode -eq 'reuse') {
                    return @{ warehouses = @(@{
                        id = 'warehouse-1'; name = $validConfig.warehouseName
                        cluster_size = $validConfig.warehouseSize
                        min_num_clusters = 1; max_num_clusters = 1
                        auto_stop_mins = $validConfig.warehouseAutoStopMinutes
                        enable_serverless_compute = $true; warehouse_type = 'PRO'
                    }) }
                }
                return @{}
            }
            Assert-True $Body.enable_serverless_compute 'Serverless flag must be true.'
            Assert-True ($Body.auto_stop_mins -eq 5) 'Expected five-minute auto-stop.'
            Assert-True ($Body.max_num_clusters -eq 1) 'Expected one cluster maximum.'
            return @{ id = 'warehouse-1' }
        }
        '/api/2.0/sql/warehouses/warehouse-1' {
            if ($script:mode -eq 'stopped' -and -not $script:started) {
                return @{ id = 'warehouse-1'; state = 'STOPPED'; enable_serverless_compute = $true }
            }
            return @{ id = 'warehouse-1'; state = 'RUNNING'; enable_serverless_compute = ($script:mode -ne 'classic') }
        }
        '/api/2.0/sql/warehouses/warehouse-1/start' {
            $script:started = $true
            return
        }
        '/api/2.0/sql/statements' {
            Assert-True ($Body.statement -eq 'SELECT 1 AS deployment_check') 'Expected actual SQL smoke test.'
            if ($script:mode -eq 'sql-fail') { return @{ status = @{ state = 'FAILED'; error = @{ message = 'Permission denied' } } } }
            if ($script:mode -eq 'sql-pending') { return @{ statement_id = 'query-1'; status = @{ state = 'PENDING' } } }
            return @{ status = @{ state = 'SUCCEEDED' }; result = @{ data_array = @(, @('1')) } }
        }
        '/api/2.0/sql/statements/query-1' {
            return @{ status = @{ state = 'SUCCEEDED' }; result = @{ data_array = @(, @('1')) } }
        }
        default { throw "Unexpected Databricks request: $Method $Path" }
    }
}
Test-Case 'Fresh workspace creates serverless warehouse and verifies SQL' {
    $calls.Clear()
    $result = Initialize-Databricks -Config $validConfig -Outputs $outputs -Headers @{}
    Assert-True ($result.warehouseId -eq 'warehouse-1') 'Missing warehouse output.'
    Assert-True ($result.metastoreId -eq 'metastore-1') 'Missing metastore output.'
    Assert-True ($calls.Contains('POST /api/2.0/sql/warehouses')) 'Warehouse was not created.'
    Assert-True ($calls.Contains('POST /api/2.0/sql/statements')) 'SQL was not tested.'
}
Test-Case 'Matching warehouse is reused without recreation or modification' {
    $script:mode = 'reuse'
    $calls.Clear()
    $null = Initialize-Databricks -Config $validConfig -Outputs $outputs -Headers @{}
    Assert-True (-not $calls.Contains('POST /api/2.0/sql/warehouses')) 'Warehouse was recreated.'
    Assert-True (-not $calls.Contains('POST /api/2.0/sql/warehouses/warehouse-1/edit')) 'Unchanged warehouse was edited.'
}
Test-Case 'Conflicting metastore is never replaced' {
    Assert-Throws { Initialize-Databricks -Config $validConfig -Outputs $outputs -Headers @{} -MetastoreId 'another-metastore' } '*Refusing to replace*'
}
Test-Case 'Missing Unity Catalog blocks successful completion' {
    $script:mode = 'no-metastore'
    Assert-Throws { Initialize-Databricks -Config $validConfig -Outputs $outputs -Headers @{} } '*Unity Catalog is not enabled*'
}
Test-Case 'Existing regional metastore is assigned when explicitly requested' {
    $script:mode = 'attach'
    $calls.Clear()
    $result = Initialize-Databricks -Config $validConfig -Outputs $outputs -Headers @{} -MetastoreId 'metastore-1'
    Assert-True ($result.metastoreId -eq 'metastore-1') 'Metastore was not assigned.'
    Assert-True ($calls.Contains('PUT /api/2.1/unity-catalog/workspaces/123/metastore')) 'Assignment API was not called.'
}
Test-Case 'Stopped warehouse is started and verified before SQL runs' {
    $script:mode = 'stopped'
    $calls.Clear()
    $null = Initialize-Databricks -Config $validConfig -Outputs $outputs -Headers @{}
    Assert-True ($calls.Contains('POST /api/2.0/sql/warehouses/warehouse-1/start')) 'Stopped warehouse was not started.'
    Assert-True ($calls.Contains('POST /api/2.0/sql/statements')) 'SQL was not tested after starting warehouse.'
}
Test-Case 'Asynchronous SQL smoke test is polled to completion' {
    $script:mode = 'sql-pending'
    $calls.Clear()
    $null = Initialize-Databricks -Config $validConfig -Outputs $outputs -Headers @{}
    Assert-True ($calls.Contains('GET /api/2.0/sql/statements/query-1')) 'Pending query was not polled.'
}
Test-Case 'Classic compute is rejected rather than accepted as a fallback' {
    $script:mode = 'classic'
    Assert-Throws { Initialize-Databricks -Config $validConfig -Outputs $outputs -Headers @{} } '*not serverless*'
}
Test-Case 'Failed SQL smoke test blocks successful completion' {
    $script:mode = 'sql-fail'
    Assert-Throws { Initialize-Databricks -Config $validConfig -Outputs $outputs -Headers @{} } '*SQL smoke test failed*'
}

$script:cliCalls = [Collections.Generic.List[string]]::new()
$script:cliFailure = $false
$script:armStates = [Collections.Generic.Queue[string]]::new()
function az {
    $script:cliCalls.Add($args -join ' ')
    $global:LASTEXITCODE = if ($script:cliFailure) { 7 } else { 0 }
    if ($script:cliFailure) { return }
    if ($args[0] -eq 'deployment') {
        if ($args[1] -eq 'group' -and $args[2] -eq 'show') {
            $state = $script:armStates.Dequeue()
            return (@{ properties = @{ provisioningState = $state; outputs = @{ endpoint = @{ value = 'test-endpoint' } }; error = @{ code = 'TestFailure' } } } | ConvertTo-Json -Depth 20)
        }
        if ($args[1] -eq 'operation' -and $args[2] -eq 'group') {
            return '[{"properties":{"targetResource":{"resourceName":"test-resource","resourceType":"Test/resource"},"provisioningState":"Running"}}]'
        }
    }
    switch ("$($args[0]) $($args[1])") {
        'bicep build' { return '{}' }
        'account list' { return '[{"id":"test-subscription","name":"Offline test","state":"Enabled"}]' }
        'group exists' { return 'false' }
        'cognitiveservices model' { return (ConvertTo-Json -InputObject $script:catalog -Depth 20) }
        'cognitiveservices usage' { return (ConvertTo-Json -InputObject $script:usage -Depth 20) }
        default { throw "Unexpected CLI operation in offline test: $($args -join ' ')" }
    }
}
Test-Case 'Azure CLI failures are not swallowed' {
    $script:cliFailure = $true
    Assert-Throws { Invoke-AzJson -Arguments @('account', 'list') } '*Azure CLI failed*'
    $script:cliFailure = $false
}
Test-Case 'ARM monitor polls until success and preserves deployment outputs' {
    $script:armStates.Enqueue('Running')
    $script:armStates.Enqueue('Succeeded')
    $result = Wait-ArmDeployment -Subscription 'test-subscription' -ResourceGroup 'test-rg' -Name 'test-deployment'
    Assert-True ($result.properties.outputs.endpoint.value -eq 'test-endpoint') 'Monitor lost deployment outputs.'
    Assert-True ($script:armStates.Count -eq 0) 'Monitor did not wait for success.'
}
Test-Case 'ARM monitor rejects failed and canceled deployments' {
    foreach ($state in @('Failed', 'Canceled')) {
        $script:armStates.Enqueue($state)
        Assert-Throws { Wait-ArmDeployment -Subscription 'test-subscription' -ResourceGroup 'test-rg' -Name 'test-deployment' } "*$state*TestFailure*"
    }
}
Test-Case 'ValidateOnly runs real orchestration without resource-changing CLI commands' {
    $script:cliCalls.Clear()
    $SubscriptionId = 'test-subscription'
    $ValidateOnly = $true
    Start-RcaDeployment
    Assert-True ($cliCalls.Count -eq 5) "Expected five read-only CLI operations, got $($cliCalls.Count)."
    Assert-True (@($cliCalls | Where-Object { $_ -match 'register|create|deployment group' }).Count -eq 0) 'Preflight changed resources.'
    Assert-True (@($cliCalls | Where-Object { $_ -like '*--subscription test-subscription*' }).Count -eq 3) 'Subscription was not scoped on all resource queries.'
}

Write-Host "`n$script:passed offline deployment tests passed. No Azure resources were created."
