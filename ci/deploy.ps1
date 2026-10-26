[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('store', 'payment')]
    [string]$Component,
    [Parameter(Mandatory = $true)]
    [string]$Image,
    [string]$KubeContext = 'etudiant_37@log430',
    [ValidateSet('log430-espace-etudiant-10')]
    [string]$Namespace = 'log430-espace-etudiant-10'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Log430Root = Split-Path -Parent $PSScriptRoot
$Log430ManifestTemp = $null
$Log430KubeArguments = @('--context', $KubeContext, '--namespace', $Namespace)

function Invoke-Log430Kubectl {
    param([string[]]$Arguments, [switch]$Capture)
    $result = & kubectl @Log430KubeArguments @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "kubectl failed (exit $LASTEXITCODE): $($Arguments -join ' ')"
    }
    if ($Capture) { return ($result -join "`n") }
    $result | ForEach-Object { Write-Host $_ }
}

function Set-Log430ConfigMap {
    param([string]$Name, [string]$Source)
    $yaml = Invoke-Log430Kubectl -Capture -Arguments @(
        'create', 'configmap', $Name, "--from-file=$Source",
        '--dry-run=client', '-o', 'yaml'
    )
    $yaml | & kubectl @Log430KubeArguments apply -f -
    if ($LASTEXITCODE -ne 0) { throw "Could not apply ConfigMap $Name" }
}

Push-Location $Log430Root
try {
    if ($Component -eq 'store') {
        $Log430ImageBase = 'ghcr.io/picodoux/log430-labo5-a26'
        $Log430Deployments = @('mysql', 'redis', 'store-manager', 'api-gateway')
        $Log430Application = 'store-manager'
    } else {
        $Log430ImageBase = 'ghcr.io/picodoux/log430-labo5-payment'
        $Log430Deployments = @('mysql-payments', 'payments-api')
        $Log430Application = 'payments-api'
    }

    if ($Image -notmatch ('^' + [regex]::Escape($Log430ImageBase) + ':[0-9a-f]{40}$')) {
        throw 'Expected the component image tagged with the full Git commit SHA.'
    }

    $Log430Server = Invoke-Log430Kubectl -Capture -Arguments @(
        'config', 'view', '--minify', '-o', 'jsonpath={.clusters[0].cluster.server}'
    )
    if ($Log430Server.TrimEnd('/') -ne 'https://atreides.logti.etsmtl.ca:16443') {
        throw "Unexpected Kubernetes server: $Log430Server"
    }
    Write-Host "Deploying $Image to $Namespace using context $KubeContext"
    Invoke-Log430Kubectl -Arguments @('auth', 'whoami')

    if ($Component -eq 'store') {
        Set-Log430ConfigMap -Name 'krakend-config' -Source 'krakend.json=./config/krakend-k8s.json'
        Set-Log430ConfigMap -Name 'db-init' -Source './db-init/'
    } else {
        Set-Log430ConfigMap -Name 'payments-db-init' -Source './db-init/'
    }

    $Log430Manifest = [IO.File]::ReadAllText((Join-Path $Log430Root 'k8s-manifests.yml'))
    $Log430OldImage = $Log430ImageBase + ':latest'
    if (-not $Log430Manifest.Contains($Log430OldImage)) {
        throw "The manifest must contain $Log430OldImage"
    }
    $Log430Manifest = $Log430Manifest.Replace($Log430OldImage, $Image)
    $Log430ManifestTemp = Join-Path ([IO.Path]::GetTempPath()) ("log430-" + [guid]::NewGuid().ToString('N') + '.yml')
    [IO.File]::WriteAllText($Log430ManifestTemp, $Log430Manifest, [Text.UTF8Encoding]::new($false))
    Invoke-Log430Kubectl -Arguments @('apply', '-f', $Log430ManifestTemp)

    if ($Component -eq 'store') {
        # The gateway mounts its ConfigMap with subPath and must reload it.
        Invoke-Log430Kubectl -Arguments @('rollout', 'restart', 'deployment/api-gateway')
    }
    foreach ($Log430Deployment in $Log430Deployments) {
        Invoke-Log430Kubectl -Arguments @('rollout', 'status', "deployment/$Log430Deployment", '--timeout=180s')
    }

    # Exactly one functional order/payment check. No Locust load on the cluster.
    $Log430Smoke = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'smoke.py'))
    $Log430Smoke | & kubectl @Log430KubeArguments exec -i deployment/store-manager -- python - `
        --store http://store-manager:5000 --payment http://payments-api:5009 --gateway http://api-gateway:8080
    if ($LASTEXITCODE -ne 0) { throw 'The deployed order/payment flow failed.' }

    Invoke-Log430Kubectl -Arguments @('get', 'deployments,pods,services,pvc')
    Invoke-Log430Kubectl -Arguments @('get', 'deployment', $Log430Application, '-o', 'jsonpath={.spec.template.spec.containers[0].image}')
    Write-Host "`nDeployment and functional check succeeded."
} catch {
    $Log430Failure = $_
    Write-Host 'Deployment failed. Kubernetes diagnostics:'
    & kubectl @Log430KubeArguments get pods
    & kubectl @Log430KubeArguments get events --sort-by=.lastTimestamp | Select-Object -Last 15
    if ($Component -eq 'store') {
        & kubectl @Log430KubeArguments logs deployment/store-manager --tail=60
        & kubectl @Log430KubeArguments logs deployment/api-gateway --tail=60
    } else {
        & kubectl @Log430KubeArguments logs deployment/payments-api --tail=60
    }
    throw $Log430Failure
} finally {
    if ($Log430ManifestTemp -and (Test-Path $Log430ManifestTemp)) {
        Remove-Item $Log430ManifestTemp -Force
    }
    Pop-Location
}
