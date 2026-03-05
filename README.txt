

<# Automated script of: 
Understanding the Project Files: A Beginner's Guide to Kubernetes
https://github.com/davbaster/wordpress-k8s-example

Run the Script from PowerShell ISE
================================================================================
  Create-wordpress-k8s-fixed.ps1
  Full deployment script for MySQL + WordPress on Minikube (Windows)
  with Persistent Storage, Ingress, Secrets, Probes, and Resource Limits.
================================================================================

OVERVIEW
--------
This script automates the end-to-end deployment of a WordPress site backed by
a MySQL database, running inside a local Kubernetes cluster managed by Minikube.
It is designed to run on Windows (PowerShell, as Administrator) and handles
everything from tool installation through to opening the WordPress admin page
in your browser.

--------------------------------------------------------------------------------
SECTION 1 — CONFIGURATION
--------------------------------------------------------------------------------
All tunable parameters are defined at the top of the script as variables:
  - Folder paths for kubectl, minikube, and generated YAML files.
  - MySQL credentials (root password, app user, app password, database name).
  - Kubernetes resource names for deployments, services, secrets, PVs, and PVCs.
  - WordPress NodePort (30080) and Ingress path (/).
  - Storage sizes: 1Gi for MySQL, 2Gi for WordPress.
  - Timeouts and retry counts for apply operations and controller readiness waits.

--------------------------------------------------------------------------------
SECTION 2 — HELPER FUNCTIONS
--------------------------------------------------------------------------------
A set of reusable utility functions used throughout the script:
  - Info / Warn / Err     : Formatted log output ([INFO], [WARN], [ERROR]).
  - Try-Run               : Safely executes a shell command and returns a result
                            object { Success, Output } without throwing exceptions.
  - Download-File         : Downloads a file from a URL using WebClient.
  - Ensure-Dir            : Creates a directory if it does not already exist.
  - Add-To-UserPath       : Appends a directory to the current user's PATH
                            (both the persistent registry value and the live session).
  - Wait-For-Condition    : Polls a scriptblock repeatedly until it returns $true
                            or a timeout is reached. Used for readiness checks.

--------------------------------------------------------------------------------
SECTION 3 — KUBECTL-SAFE WRAPPERS
--------------------------------------------------------------------------------
Thin wrappers around common kubectl commands that swallow errors and return
structured results, preventing the script from crashing on transient failures:
  - Kubectl-Get                       : Runs "kubectl get <args>".
  - Kubectl-Describe                  : Runs "kubectl describe <args>".
  - Kubectl-Apply-With-Retry-Return   : Applies a YAML manifest file with up to
                                        3 retries. On persistent failure, retries
                                        once more with --validate=false as a last
                                        resort, and always returns the result.

--------------------------------------------------------------------------------
SECTION 4 — PREFLIGHT: TOOL INSTALLATION
--------------------------------------------------------------------------------
Checks whether kubectl and minikube are available on the system PATH.
  - If kubectl is missing: downloads the latest stable release from dl.k8s.io
    into C:\Program Files\Kubernetes and adds it to the user PATH.
  - If minikube is missing: downloads the latest release from the official
    Google Cloud Storage bucket into C:\Program Files\minikube and adds it
    to the user PATH.
  - After downloads, refreshes the command lookup so the rest of the script
    can use both tools immediately without reopening the terminal.

--------------------------------------------------------------------------------
SECTION 5 — YAML TEMPLATE GENERATION
--------------------------------------------------------------------------------
All Kubernetes manifests are defined as PowerShell here-strings with
__PLACEHOLDER__ tokens, then rendered by string replacement into final YAML
and written to $env:USERPROFILE\k8s\. The following resources are generated:

  mysql-secret.yaml
    A Kubernetes Secret (type Opaque) holding MYSQL_ROOT_PASSWORD and
    MYSQL_PASSWORD, referenced by both the MySQL and WordPress deployments
    via secretKeyRef so credentials are never hard-coded in plain-text env vars.

  mysql-pv.yaml / mysql-pvc.yaml
    A 1Gi PersistentVolume backed by a Minikube hostPath (/data/mysql) and
    a matching PersistentVolumeClaim using storageClassName: manual.
    This ensures MySQL data survives pod restarts.

  wordpress-pv.yaml / wordpress-pvc.yaml
    A 2Gi PersistentVolume backed by hostPath (/data/wordpress) and its PVC.
    Mounted at /var/www/html inside the WordPress container, this preserves
    themes, plugins, uploads, and wp-config.php across pod restarts — without
    this, WordPress loses all state whenever its pod is rescheduled.

  mysql-deployment.yaml
    Deploys mysql:8.0 with:
      - Credentials injected from the Secret.
      - The mysql-pvc volume mounted at /var/lib/mysql.
      - A readinessProbe (mysqladmin ping, delay 20s, period 10s) that gates
        traffic until MySQL is fully initialised.
      - A livenessProbe (mysqladmin ping, delay 30s, period 20s) that restarts
        the container if MySQL becomes unresponsive.
      - Resource limits (256Mi–512Mi RAM, 100m–500m CPU) to prevent the
        container from consuming all available Minikube memory.
      - The probe command does NOT embed the password in the process list.

  mysql-service.yaml
    A ClusterIP Service exposing port 3306 internally so WordPress can reach
    MySQL using the service DNS name (mysql-service:3306).

  wordpress-deployment.yaml
    Deploys wordpress:latest with:
      - DB connection env vars pointing at mysql-service:3306.
      - DB password injected from the Secret.
      - The wordpress-pvc volume mounted at /var/www/html.
      - A readinessProbe (HTTP GET /wp-login.php, delay 30s, period 10s,
        failureThreshold 6) that prevents traffic until WordPress is ready.
      - A livenessProbe (HTTP GET /wp-login.php, delay 60s, period 20s) that
        restarts the container if WordPress stops responding.
      - Resource limits (128Mi–512Mi RAM, 100m–500m CPU).

  wordpress-service.yaml
    A NodePort Service exposing port 80 of WordPress as NodePort 30080,
    making it reachable directly via the Minikube node IP.

  wordpress-ingress.yaml
    An nginx Ingress resource routing all HTTP traffic (path /) to the
    WordPress service on port 80. The host: field is intentionally omitted
    so the rule acts as a catch-all — using a Minikube IP as a hostname
    would be invalid and silently ignored by the ingress controller.

--------------------------------------------------------------------------------
SECTION 6 — MINIKUBE START (ROBUST)
--------------------------------------------------------------------------------
Before applying any manifests the script verifies the cluster is reachable:
  - Queries "minikube status" for Host / Kubelet / APIServer state.
  - Independently tests whether "kubectl cluster-info" succeeds.
  - If the API is already reachable, skips starting Minikube entirely.
  - If Minikube reports Running but kubectl cannot connect, waits 8 seconds
    and retries before deciding a restart is needed.
  - If a start is needed: runs "minikube start", retries once on failure,
    then polls until the Kubernetes API becomes reachable (up to 180 seconds).

--------------------------------------------------------------------------------
SECTION 7 — MANIFEST APPLICATION
--------------------------------------------------------------------------------
Applies all generated YAML files in dependency order using
Kubectl-Apply-With-Retry-Return:
  1. Secret
  2. MySQL PV → MySQL PVC
  3. WordPress PV → WordPress PVC
  4. MySQL Deployment → MySQL Service
  5. WordPress Deployment → WordPress Service

--------------------------------------------------------------------------------
SECTION 8 — INGRESS CONTROLLER SETUP
--------------------------------------------------------------------------------
  - Enables the Minikube ingress addon ("minikube addons enable ingress"),
    which installs the nginx ingress controller into the cluster.
  - Polls the ingress-nginx (and kube-system) namespace for up to 180 seconds
    checking both availableReplicas on the controller Deployment and the pod
    Running phase before proceeding.

--------------------------------------------------------------------------------
SECTION 9 — DEPLOYMENT READINESS WAIT
--------------------------------------------------------------------------------
Uses "kubectl wait --for=condition=available --timeout=180s" on both the
MySQL and WordPress Deployments to block until Kubernetes confirms that the
required number of replicas are healthy and passing their readiness probes.

--------------------------------------------------------------------------------
SECTION 10 — STATUS REPORTING
--------------------------------------------------------------------------------
Prints a mid-run and final snapshot of the cluster state to the console:
  - All pods with wide output (node, IP, status, restarts).
  - All services with wide output (cluster IP, external IP, ports).
  - All PersistentVolumes and PersistentVolumeClaims.
  - The applied Ingress resource (described in full if creation succeeds,
    or diagnostics including events and controller pod state if it fails).

--------------------------------------------------------------------------------
SECTION 11 — URL OPENING
--------------------------------------------------------------------------------
Determines the best available URL for the WordPress admin page and opens it
in the default browser, trying access methods in priority order:
  1. "minikube service --url wordpress-service"  (tunnel/NodePort URL)
  2. http://<minikube-ip>/wp-admin/              (via Ingress catch-all)
  3. kubectl port-forward in a new PowerShell window, then http://localhost:8080/

================================================================================
PREREQUISITES
================================================================================
  - Windows 10/11, PowerShell 5.1+, run as Administrator.
  - A working hypervisor: Docker Desktop, Hyper-V, or VirtualBox.
  - Outbound internet access to download kubectl, minikube, and container images.
  - At least 4 GB RAM and 20 GB free disk allocated to Minikube.

================================================================================
USAGE
================================================================================
  Right-click PowerShell → "Run as Administrator", then:

    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
    .\Create-wordpress-k8s-fixed.ps1

  To tear everything down afterwards:
    minikube delete

================================================================================
#>