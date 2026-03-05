<#
Create-wordpress-k8s-fixed.ps1
Comprehensive deployment script for MySQL + WordPress on Minikube with PVC + Ingress.
Run as Administrator. Back up anything you need before running.

FIXES APPLIED:
  1. WordPress now has its own PV + PVC (mounts /var/www/html) - prevents data loss on pod restart
  2. livenessProbe added to both MySQL and WordPress - restarts stuck containers
  3. resource requests/limits added to both containers - prevents OOM kills
  4. MySQL readiness probe no longer leaks password in process list
  5. WordPress readinessProbe initialDelaySeconds increased (10->30) + failureThreshold added
  6. Ingress host: field removed (IP addresses are invalid hostnames) - now a catch-all rule
#>

# ---------------- Configuration ----------------
$k8sFolder               = Join-Path $env:USERPROFILE "k8s"
$kubectlInstallDir       = "C:\Program Files\Kubernetes"
$minikubeInstallDir      = "C:\Program Files\minikube"
$mysqlSecretName         = "mysql-secrets"
$mysqlRootPassword       = "root-password"
$mysqlUser               = "wpuser"
$mysqlPassword           = "user-password"
$mysqlDatabase           = "wordpress"
$mysqlDeploymentName     = "mysql-deployment"
$mysqlServiceName        = "mysql-service"
$wordpressDeploymentName = "wordpress-deployment"
$wordpressServiceName    = "wordpress-service"
$wordpressNodePort       = 30080
$wordpressIngressPath    = "/"
# MySQL storage
$pvName                  = "mysql-pv"
$pvcName                 = "mysql-pvc"
$pvHostPath              = "/data/mysql"
$pvStorage               = "1Gi"
# WordPress storage (FIX #1)
$wpPvName                = "wordpress-pv"
$wpPvcName               = "wordpress-pvc"
$wpPvHostPath            = "/data/wordpress"
$wpPvStorage             = "2Gi"

$portForwardLocal               = 8080
$waitTimeout                    = "180s"
$minikubeStartTimeoutSeconds    = 300
$kubectlApplyRetries            = 3
$kubectlApplyRetryDelay         = 5
$ingressControllerWaitSeconds   = 180
$ingressControllerPollInterval  = 5

# ---------------- Helper functions ----------------
function Info([string]$m) { Write-Output ("[INFO]  {0}" -f $m) }
function Warn([string]$m) { Write-Output ("[WARN]  {0}" -f $m) }
function Err([string]$m)  { Write-Output ("[ERROR] {0}" -f $m) }

function Try-Run([string]$cmd) {
    try {
        $out = Invoke-Expression $cmd 2>&1
        return @{ Success = $true; Output = $out }
    } catch {
        return @{ Success = $false; Output = $_.Exception.Message }
    }
}

function Download-File([string]$url, [string]$dest) {
    try {
        $wc = New-Object System.Net.WebClient
        $wc.DownloadFile($url, $dest)
        return $true
    } catch {
        Warn ("Failed to download {0}: {1}" -f $url, $_.Exception.Message)
        return $false
    }
}

function Ensure-Dir([string]$path) {
    if (-not (Test-Path $path)) {
        New-Item -ItemType Directory -Path $path | Out-Null
    }
}

function Add-To-UserPath([string]$dir) {
    $userPath = [Environment]::GetEnvironmentVariable('Path','User') -as [string]
    if (-not $userPath) { $userPath = "" }
    if ($userPath -notmatch [regex]::Escape($dir)) {
        $new = ($userPath.TrimEnd(';') + ';' + $dir).Trim(';')
        try {
            [Environment]::SetEnvironmentVariable('Path', $new, 'User')
            $env:Path = $env:Path + ";" + $dir
            Info ("Added {0} to user PATH" -f $dir)
        } catch {
            Warn ("Failed to update user PATH: {0}" -f $_.Exception.Message)
        }
    } else {
        Info ("{0} already in user PATH" -f $dir)
    }
}

function Wait-For-Condition([scriptblock]$check, [int]$timeoutSeconds, [int]$intervalSeconds = 5, [string]$waitingMessage = "Waiting...") {
    $start = Get-Date
    while ((Get-Date) -lt $start.AddSeconds($timeoutSeconds)) {
        try {
            if (& $check) { return $true }
        } catch {}
        Write-Output $waitingMessage
        Start-Sleep -Seconds $intervalSeconds
    }
    return $false
}

# ---------------- Kubectl-safe wrappers ----------------
function Kubectl-Get([string]$args) {
    if ([string]::IsNullOrWhiteSpace($args)) { return $null }
    $res = Try-Run ("kubectl get $args 2>&1")
    if ($res.Success) { return $res.Output } else { return $null }
}
function Kubectl-Describe([string]$args) {
    if ([string]::IsNullOrWhiteSpace($args)) { return $null }
    $res = Try-Run ("kubectl describe $args 2>&1")
    if ($res.Success) { return $res.Output } else { return $null }
}
function Kubectl-Apply-With-Retry-Return([string]$file) {
    for ($i=1; $i -le $kubectlApplyRetries; $i++) {
        $res = Try-Run ("kubectl apply -f `"$file`"")
        if ($res.Success) { Info ("Applied {0}" -f $file); return $res }
        Warn ("kubectl apply failed for {0} (attempt {1}/{2}): {3}" -f $file, $i, $kubectlApplyRetries, $res.Output)
        Start-Sleep -Seconds $kubectlApplyRetryDelay
    }
    Warn ("Attempting final apply with --validate=false for {0}" -f $file)
    $res2 = Try-Run ("kubectl apply --validate=false -f `"$file`"")
    if ($res2.Success) { Info ("Applied {0} with --validate=false" -f $file); return $res2 }
    Warn ("Final apply with --validate=false also failed for {0}: {1}" -f $file, $res2.Output)
    return $res2
}

# ---------------- Preflight: ensure kubectl and minikube ----------------
Info "Preflight: checking kubectl and minikube availability..."

$kubectlCmd  = Get-Command kubectl  -ErrorAction SilentlyContinue
$minikubeCmd = Get-Command minikube -ErrorAction SilentlyContinue

if (-not $kubectlCmd) {
    Info "kubectl not found. Downloading kubectl (stable) to $kubectlInstallDir..."
    Ensure-Dir $kubectlInstallDir
    try {
        $stable = (Invoke-RestMethod -Uri "https://dl.k8s.io/release/stable.txt" -UseBasicParsing).Trim()
    } catch {
        Warn "Could not fetch stable kubectl version; falling back to 'latest' token."
        $stable = "latest"
    }
    if ($stable -eq "latest") {
        $kubectlUrl = "https://dl.k8s.io/release/latest/bin/windows/amd64/kubectl.exe"
    } else {
        $kubectlUrl = "https://dl.k8s.io/release/$stable/bin/windows/amd64/kubectl.exe"
    }
    $kubectlDest = Join-Path $kubectlInstallDir "kubectl.exe"
    if (Download-File -url $kubectlUrl -dest $kubectlDest) {
        Add-To-UserPath $kubectlInstallDir
        Info "kubectl downloaded."
    } else {
        Err "kubectl download failed. Install kubectl manually and re-run the script."
        exit 1
    }
} else {
    Info ("kubectl found at {0}" -f $kubectlCmd.Source)
}

if (-not $minikubeCmd) {
    Info "minikube not found. Downloading minikube to $minikubeInstallDir..."
    Ensure-Dir $minikubeInstallDir
    $minikubeUrl  = "https://storage.googleapis.com/minikube/releases/latest/minikube-windows-amd64.exe"
    $minikubeDest = Join-Path $minikubeInstallDir "minikube.exe"
    if (Download-File -url $minikubeUrl -dest $minikubeDest) {
        Add-To-UserPath $minikubeInstallDir
        Info "minikube downloaded."
    } else {
        Err "minikube download failed. Install minikube manually and re-run the script."
        exit 1
    }
} else {
    Info ("minikube found at {0}" -f $minikubeCmd.Source)
}

# Refresh command lookup in current session
$kubectlCmd  = Get-Command kubectl  -ErrorAction SilentlyContinue
$minikubeCmd = Get-Command minikube -ErrorAction SilentlyContinue
if (-not $kubectlCmd -or -not $minikubeCmd) {
    Warn "Commands may not be available in this session. PATH updated; continuing."
    Start-Sleep -Seconds 1
}

# ---------------- Ensure k8s folder exists ----------------
if (-not (Test-Path -Path $k8sFolder)) {
    New-Item -ItemType Directory -Path $k8sFolder | Out-Null
}

# ---------------- YAML templates ----------------
$secretTemplate = @'
apiVersion: v1
kind: Secret
metadata:
  name: __MYSQL_SECRET__
type: Opaque
stringData:
  MYSQL_ROOT_PASSWORD: __MYSQL_ROOT_PASSWORD__
  MYSQL_PASSWORD: __MYSQL_PASSWORD__
'@

# FIX #2 (liveness) + FIX #3 (resources) + FIX #4 (probe no longer leaks password)
$mysqlDeploymentTemplate = @'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: __MYSQL_DEPLOYMENT__
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mysql
  template:
    metadata:
      labels:
        app: mysql
    spec:
      containers:
      - name: mysql
        image: mysql:8.0
        ports:
        - containerPort: 3306
        env:
        - name: MYSQL_ROOT_PASSWORD
          valueFrom:
            secretKeyRef:
              name: __MYSQL_SECRET__
              key: MYSQL_ROOT_PASSWORD
        - name: MYSQL_DATABASE
          value: __MYSQL_DATABASE__
        - name: MYSQL_USER
          value: __MYSQL_USER__
        - name: MYSQL_PASSWORD
          valueFrom:
            secretKeyRef:
              name: __MYSQL_SECRET__
              key: MYSQL_PASSWORD
        resources:
          requests:
            memory: "256Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
            cpu: "500m"
        readinessProbe:
          exec:
            command:
            - mysqladmin
            - ping
            - -h
            - "127.0.0.1"
          initialDelaySeconds: 20
          periodSeconds: 10
          failureThreshold: 6
        livenessProbe:
          exec:
            command:
            - mysqladmin
            - ping
            - -h
            - "127.0.0.1"
          initialDelaySeconds: 30
          periodSeconds: 20
          failureThreshold: 3
        volumeMounts:
        - name: mysql-data
          mountPath: /var/lib/mysql
      volumes:
      - name: mysql-data
        persistentVolumeClaim:
          claimName: __MYSQL_PVC__
'@

$mysqlServiceTemplate = @'
apiVersion: v1
kind: Service
metadata:
  name: __MYSQL_SERVICE__
spec:
  selector:
    app: mysql
  ports:
    - port: 3306
      targetPort: 3306
      protocol: TCP
  type: ClusterIP
'@

# FIX #1 (WP PVC volume mount) + FIX #2 (liveness) + FIX #3 (resources) + FIX #5 (probe timing)
$wpDeploymentTemplate = @'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: __WP_DEPLOYMENT__
spec:
  replicas: 1
  selector:
    matchLabels:
      app: wordpress
  template:
    metadata:
      labels:
        app: wordpress
    spec:
      containers:
      - name: wordpress
        image: wordpress:latest
        ports:
        - containerPort: 80
        env:
        - name: WORDPRESS_DB_HOST
          value: "__MYSQL_SERVICE__:3306"
        - name: WORDPRESS_DB_NAME
          value: "__MYSQL_DATABASE__"
        - name: WORDPRESS_DB_USER
          value: "__MYSQL_USER__"
        - name: WORDPRESS_DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: __MYSQL_SECRET__
              key: MYSQL_PASSWORD
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
            cpu: "500m"
        readinessProbe:
          httpGet:
            path: /wp-login.php
            port: 80
          initialDelaySeconds: 30
          periodSeconds: 10
          failureThreshold: 6
        livenessProbe:
          httpGet:
            path: /wp-login.php
            port: 80
          initialDelaySeconds: 60
          periodSeconds: 20
          failureThreshold: 3
        volumeMounts:
        - name: wordpress-data
          mountPath: /var/www/html
      volumes:
      - name: wordpress-data
        persistentVolumeClaim:
          claimName: __WP_PVC_NAME__
'@

$wpServiceTemplate = @'
apiVersion: v1
kind: Service
metadata:
  name: __WP_SERVICE__
spec:
  type: NodePort
  selector:
    app: wordpress
  ports:
    - port: 80
      targetPort: 80
      nodePort: __WP_NODEPORT__
'@

$pvTemplate = @'
apiVersion: v1
kind: PersistentVolume
metadata:
  name: __PV_NAME__
spec:
  capacity:
    storage: __PV_STORAGE__
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: manual
  hostPath:
    path: "__PV_HOSTPATH__"
'@

$pvcTemplate = @'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: __PVC_NAME__
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: __PV_STORAGE__
  storageClassName: manual
'@

# FIX #6: Ingress uses no host: field (catch-all) — IP addresses are invalid Ingress hostnames
$ingressTemplate = @'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: wordpress-ingress
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  rules:
  - http:
      paths:
      - path: __INGRESS_PATH__
        pathType: Prefix
        backend:
          service:
            name: __WP_SERVICE__
            port:
              number: 80
'@

# ---------------- Replace placeholders ----------------
$secretYaml = $secretTemplate `
    -replace "__MYSQL_SECRET__",        $mysqlSecretName `
    -replace "__MYSQL_ROOT_PASSWORD__", $mysqlRootPassword `
    -replace "__MYSQL_PASSWORD__",      $mysqlPassword

$mysqlDeploymentYaml = $mysqlDeploymentTemplate `
    -replace "__MYSQL_DEPLOYMENT__", $mysqlDeploymentName `
    -replace "__MYSQL_SECRET__",     $mysqlSecretName `
    -replace "__MYSQL_DATABASE__",   $mysqlDatabase `
    -replace "__MYSQL_USER__",       $mysqlUser `
    -replace "__MYSQL_PVC__",        $pvcName

$mysqlServiceYaml = $mysqlServiceTemplate `
    -replace "__MYSQL_SERVICE__", $mysqlServiceName

$wpDeploymentYaml = $wpDeploymentTemplate `
    -replace "__WP_DEPLOYMENT__",  $wordpressDeploymentName `
    -replace "__MYSQL_SERVICE__",  $mysqlServiceName `
    -replace "__MYSQL_DATABASE__", $mysqlDatabase `
    -replace "__MYSQL_USER__",     $mysqlUser `
    -replace "__MYSQL_SECRET__",   $mysqlSecretName `
    -replace "__WP_PVC_NAME__",    $wpPvcName

$wpServiceYaml = $wpServiceTemplate `
    -replace "__WP_SERVICE__",  $wordpressServiceName `
    -replace "__WP_NODEPORT__", $wordpressNodePort

# MySQL PV + PVC
$pvYaml = $pvTemplate `
    -replace "__PV_NAME__",    $pvName `
    -replace "__PV_STORAGE__", $pvStorage `
    -replace "__PV_HOSTPATH__",$pvHostPath

$pvcYaml = $pvcTemplate `
    -replace "__PVC_NAME__",   $pvcName `
    -replace "__PV_STORAGE__", $pvStorage

# WordPress PV + PVC (FIX #1)
$wpPvYaml = $pvTemplate `
    -replace "__PV_NAME__",    $wpPvName `
    -replace "__PV_STORAGE__", $wpPvStorage `
    -replace "__PV_HOSTPATH__",$wpPvHostPath

$wpPvcYaml = $pvcTemplate `
    -replace "__PVC_NAME__",   $wpPvcName `
    -replace "__PV_STORAGE__", $wpPvStorage

# Ingress (FIX #6: no host substitution)
$ingressYaml = $ingressTemplate `
    -replace "__INGRESS_PATH__", $wordpressIngressPath `
    -replace "__WP_SERVICE__",   $wordpressServiceName

# ---------------- Write YAML files ----------------
$secretPath           = Join-Path $k8sFolder "mysql-secret.yaml"
$pvPath               = Join-Path $k8sFolder "mysql-pv.yaml"
$pvcPath              = Join-Path $k8sFolder "mysql-pvc.yaml"
$wpPvPath             = Join-Path $k8sFolder "wordpress-pv.yaml"
$wpPvcPath            = Join-Path $k8sFolder "wordpress-pvc.yaml"
$mysqlDeploymentPath  = Join-Path $k8sFolder "mysql-deployment.yaml"
$mysqlServicePath     = Join-Path $k8sFolder "mysql-service.yaml"
$wpDeploymentPath     = Join-Path $k8sFolder "wordpress-deployment.yaml"
$wpServicePath        = Join-Path $k8sFolder "wordpress-service.yaml"
$ingressPath          = Join-Path $k8sFolder "wordpress-ingress.yaml"

$secretYaml          | Out-File -FilePath $secretPath          -Encoding utf8
$pvYaml              | Out-File -FilePath $pvPath              -Encoding utf8
$pvcYaml             | Out-File -FilePath $pvcPath             -Encoding utf8
$wpPvYaml            | Out-File -FilePath $wpPvPath            -Encoding utf8
$wpPvcYaml           | Out-File -FilePath $wpPvcPath           -Encoding utf8
$mysqlDeploymentYaml | Out-File -FilePath $mysqlDeploymentPath -Encoding utf8
$mysqlServiceYaml    | Out-File -FilePath $mysqlServicePath    -Encoding utf8
$wpDeploymentYaml    | Out-File -FilePath $wpDeploymentPath    -Encoding utf8
$wpServiceYaml       | Out-File -FilePath $wpServicePath       -Encoding utf8
$ingressYaml         | Out-File -FilePath $ingressPath         -Encoding utf8

Info ("Wrote YAML files to {0}" -f $k8sFolder)
Info "Files: mysql-secret.yaml, mysql-pv.yaml, mysql-pvc.yaml, wordpress-pv.yaml, wordpress-pvc.yaml, mysql-deployment.yaml, mysql-service.yaml, wordpress-deployment.yaml, wordpress-service.yaml, wordpress-ingress.yaml"

# ---------------- Minikube status check and start (robust) ----------------
function Test-MinikubeApi {
    try {
        & kubectl cluster-info 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { return $true }
    } catch {}
    return $false
}

function Test-MinikubeStatus {
    try {
        $fmt = "{{.Host}}|{{.Kubelet}}|{{.APIServer}}"
        $out = & minikube status --format $fmt 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($out)) { return $null }
        $parts = $out.Trim() -split '\|'
        return @{ Host = $parts[0]; Kubelet = $parts[1]; APIServer = $parts[2] }
    } catch {
        return $null
    }
}

Info "Checking Minikube status (robust check)..."

$minikubeStatus = Test-MinikubeStatus
$apiReachable   = Test-MinikubeApi
$needStart      = $false

if ($minikubeStatus -ne $null) {
    Info ("minikube status: Host={0} Kubelet={1} APIServer={2}" -f $minikubeStatus.Host, $minikubeStatus.Kubelet, $minikubeStatus.APIServer)
} else {
    Info "minikube status command returned no structured output or minikube not installed."
}

if ($apiReachable) {
    Info "Kubernetes API is reachable via kubectl. Skipping minikube start."
} else {
    if ($minikubeStatus -ne $null -and $minikubeStatus.Host -match "Running" -and ($minikubeStatus.APIServer -match "Running" -or $minikubeStatus.Kubelet -match "Running")) {
        Warn "minikube reports running but kubectl cannot reach the API. Waiting briefly and re-checking..."
        Start-Sleep -Seconds 8
        $apiReachable = Test-MinikubeApi
        if ($apiReachable) {
            Info "Kubernetes API became reachable after wait. Continuing without starting minikube."
        } else {
            Warn "API still unreachable. Attempting to start/restart minikube to recover."
            $needStart = $true
        }
    } else {
        Info "Minikube not running or status unknown. Will start Minikube."
        $needStart = $true
    }

    if ($needStart) {
        Info "Starting Minikube (this may take several minutes)..."
        $startResult = Try-Run "minikube start"
        if (-not $startResult.Success) {
            Warn ("minikube start failed: {0}" -f $startResult.Output)
            Info "Retrying minikube start once more..."
            $startResult = Try-Run "minikube start"
            if (-not $startResult.Success) {
                Err "minikube start failed twice. Inspect minikube logs and environment before continuing."
                Write-Output $startResult.Output
                exit 1
            }
        }
        $apiReady = Wait-For-Condition -check { Test-MinikubeApi } -timeoutSeconds 180 -intervalSeconds 5 -waitingMessage "Waiting for Kubernetes API to become reachable..."
        if ($apiReady) {
            Info "Kubernetes API is reachable after starting Minikube."
        } else {
            Warn "Kubernetes API did not become reachable within timeout. Check 'minikube logs' and 'kubectl get nodes'."
        }
    }
}

# ---------------- Apply manifests with retries and validate-fallback ----------------
Info "Applying manifests to Kubernetes..."
$secretRes = Kubectl-Apply-With-Retry-Return $secretPath
if (-not $secretRes.Success) { Err "Failed to apply secret; aborting."; exit 1 }

# MySQL storage
$pvRes  = Kubectl-Apply-With-Retry-Return $pvPath
if (-not $pvRes.Success)  { Warn "MySQL PV apply failed; continuing (you may retry manually)." }
$pvcRes = Kubectl-Apply-With-Retry-Return $pvcPath
if (-not $pvcRes.Success) { Warn "MySQL PVC apply failed; continuing." }

# WordPress storage (FIX #1)
$wpPvRes  = Kubectl-Apply-With-Retry-Return $wpPvPath
if (-not $wpPvRes.Success)  { Warn "WordPress PV apply failed; continuing." }
$wpPvcRes = Kubectl-Apply-With-Retry-Return $wpPvcPath
if (-not $wpPvcRes.Success) { Warn "WordPress PVC apply failed; continuing." }

$mysqlDepRes = Kubectl-Apply-With-Retry-Return $mysqlDeploymentPath
if (-not $mysqlDepRes.Success) { Warn "MySQL deployment apply failed; continuing." }
$mysqlSvcRes = Kubectl-Apply-With-Retry-Return $mysqlServicePath
if (-not $mysqlSvcRes.Success) { Warn "MySQL service apply failed; continuing." }
$wpDepRes = Kubectl-Apply-With-Retry-Return $wpDeploymentPath
if (-not $wpDepRes.Success) { Warn "WordPress deployment apply failed; continuing." }
$wpSvcRes = Kubectl-Apply-With-Retry-Return $wpServicePath
if (-not $wpSvcRes.Success) { Warn "WordPress service apply failed; continuing." }

# ---------------- Enable ingress addon and wait for controller ----------------
Info "Enabling Minikube ingress addon (if not already enabled)..."
$enableRes = Try-Run "minikube addons enable ingress"
if (-not $enableRes.Success) {
    Warn ("minikube addons enable ingress returned an error: {0}" -f $enableRes.Output)
    Warn "Continuing — the addon command may have failed but we'll still poll for controller pods."
} else {
    Info "minikube addons enable ingress returned; now waiting for ingress controller to appear."
}

function IngressController-Ready {
    $namespaces = @("ingress-nginx","kube-system","ingress-nginx-system")
    foreach ($ns in $namespaces) {
        $deploys = Try-Run ("kubectl get deployment -n $ns -o jsonpath='{.items[*].metadata.name}' 2>$null")
        if ($deploys.Success -and $deploys.Output) {
            $names = ($deploys.Output -join "`n").Trim()
            if ($names -match "ingress-nginx-controller" -or $names -match "nginx-ingress-controller" -or $names -match "ingress-nginx") {
                $avail = Try-Run ("kubectl get deployment -n $ns -l app.kubernetes.io/name=ingress-nginx -o jsonpath='{.items[*].status.availableReplicas}' 2>$null")
                if ($avail.Success -and $avail.Output) {
                    $val = $avail.Output.Trim()
                    if ($val -ne "" -and [int]$val -gt 0) { return $true }
                }
                $pods = Try-Run ("kubectl get pods -n $ns -l app.kubernetes.io/name=ingress-nginx -o jsonpath='{.items[*].status.phase}' 2>$null")
                if ($pods.Success -and $pods.Output) {
                    $phases = $pods.Output.Trim()
                    if ($phases -match "Running") { return $true }
                }
            }
        }
    }
    return $false
}

Info ("Waiting up to {0} seconds for ingress controller to become ready..." -f $ingressControllerWaitSeconds)
$ingressReady = Wait-For-Condition -check { IngressController-Ready } -timeoutSeconds $ingressControllerWaitSeconds -intervalSeconds $ingressControllerPollInterval -waitingMessage "Waiting for ingress controller pods..."
if ($ingressReady) {
    Info "Ingress controller appears ready."
} else {
    Warn "Timed out waiting for ingress controller. You can inspect with: kubectl get pods -n ingress-nginx -o wide"
    Warn "Continuing script; ingress may not be available yet."
}

# ---------------- Wait for deployments ----------------
Info "Waiting for MySQL deployment to be available..."
Try-Run ("kubectl wait --for=condition=available --timeout=$waitTimeout deployment/$mysqlDeploymentName") | Out-Null

Info "Waiting for WordPress deployment to be available..."
Try-Run ("kubectl wait --for=condition=available --timeout=$waitTimeout deployment/$wordpressDeploymentName") | Out-Null

# ---------------- Status ----------------
Write-Output "`n--- Pods (status) ---"
$podsOut = Kubectl-Get "pods -o wide"
if ($podsOut) { $podsOut | ForEach-Object { Write-Output $_ } } else { Write-Output "Could not list pods." }

Write-Output "`n--- Services (status) ---"
$svcOut = Kubectl-Get "svc -o wide"
if ($svcOut) { $svcOut | ForEach-Object { Write-Output $_ } } else { Write-Output "Could not list services." }

Write-Output "`n--- PersistentVolumes / PVCs ---"
$pvOut = Kubectl-Get "pv,pvc -o wide"
if ($pvOut) { $pvOut | ForEach-Object { Write-Output $_ } } else { Write-Output "Could not list PV/PVC." }

# ---------------- Apply Ingress (FIX #6: no host field) ----------------
function Run-Trim([string]$cmd) {
    $out = Invoke-Expression $cmd 2>$null
    if ($null -eq $out) { return "" }
    return ($out | Out-String).Trim()
}

Info "Applying ingress manifest (catch-all, no host restriction)..."
$ingRes = Kubectl-Apply-With-Retry-Return $ingressPath
if (-not $ingRes.Success) {
    Warn "Ingress apply failed. Attempted with validate fallback. Output:"
    Write-Output $ingRes.Output
}

$exists = Try-Run "kubectl get ingress wordpress-ingress -o yaml 2>$null"
if ($exists.Success -and $exists.Output) {
    Info "Ingress resource created in default namespace."
    $desc = Try-Run "kubectl describe ingress wordpress-ingress 2>$null"
    if ($desc.Success) { $desc.Output | ForEach-Object { Write-Output $_ } }
} else {
    Warn "Ingress resource not found in default namespace after apply."
    Warn "Gathering diagnostics..."

    $allIngress = Try-Run "kubectl get ingress -A -o wide 2>$null"
    if ($allIngress.Success -and $allIngress.Output) { $allIngress.Output | ForEach-Object { Write-Output $_ } } else { Write-Output "No ingress resources found across namespaces." }

    $events = Try-Run "kubectl get events -A --sort-by='.lastTimestamp' 2>$null"
    if ($events.Success -and $events.Output) {
        $lines = $events.Output -split "`n"
        $lines | Select-Object -Last 50 | ForEach-Object { Write-Output $_ }
    } else { Write-Output "Could not fetch events." }

    $ingPods = Try-Run "kubectl get pods -n ingress-nginx -o wide 2>$null"
    if ($ingPods.Success -and $ingPods.Output) { $ingPods.Output | ForEach-Object { Write-Output $_ } } else { Write-Output "No ingress-nginx pods found." }
}

# ---------------- Final resources ----------------
Write-Output "`nFinal pods:"
$podsOut = Kubectl-Get "pods -o wide"
if ($podsOut) { $podsOut | ForEach-Object { Write-Output $_ } } else { Write-Output "Could not list pods." }

Write-Output "`nFinal services:"
$svcOut = Kubectl-Get "svc -o wide"
if ($svcOut) { $svcOut | ForEach-Object { Write-Output $_ } } else { Write-Output "Could not list services." }

Write-Output "`nFinal ingress:"
$finalIngress = Try-Run "kubectl get ingress -o wide 2>$null"
if ($finalIngress.Success -and $finalIngress.Output) { $finalIngress.Output | ForEach-Object { Write-Output $_ } } else { Write-Output "No ingress resources found in default namespace." }

# ---------------- Open URL logic ----------------
$minikubeIP = Run-Trim "minikube ip"
$svcUrl     = Run-Trim "minikube service --url $wordpressServiceName"

if ($svcUrl -ne "") {
    $openUrl = "$svcUrl/wp-admin/"
    Info ("Opening (minikube service --url): {0}" -f $openUrl)
    Start-Process $openUrl
    return
}

if ($minikubeIP -ne "") {
    $openUrl = "http://$minikubeIP/wp-admin/"
    Info ("Opening (ingress catch-all): {0}" -f $openUrl)
    Start-Process $openUrl
    return
}

Info "Falling back to kubectl port-forward on localhost:$portForwardLocal..."
$pfCommand = "kubectl port-forward svc/$wordpressServiceName $portForwardLocal`:80"
Start-Process powershell -ArgumentList "-NoExit","-Command",$pfCommand
Start-Sleep -Seconds 2
$openUrl = "http://localhost:$portForwardLocal/wp-admin/"
Info ("Opening (port-forward): {0}" -f $openUrl)
Start-Process $openUrl

Info "Script finished. If WordPress shows 'Error establishing a database connection', check MySQL pod logs: kubectl logs deployment/mysql-deployment"