#!/bin/bash
# full-run.sh - End-to-end automation for Blue-Green deployment lab
# Run from project root (~/blue-green-deployment)
set -euo pipefail
IFS=$'\n\t'

# -------- CONFIG --------
AWS_REGION="ap-south-1"
SSH_KEY_PATH="$HOME/.ssh/jenkins-key"        # private key
SSH_PUB_PATH="$HOME/.ssh/jenkins-key.pub"   # public key
TERRAFORM_DIR="terraform"
ANSIBLE_DIR="ansible"
APP_DIR="application"
# EKS_CLUSTER_NAME="bluegreen-eks"
CREATE_EKS=true     # set false to skip EKS creation if you already have a cluster
JENKINS_PORT=8080
JENKINS_USER="admin"
DOCKERHUB_USER=""   # will prompt
DOCKERHUB_PASS=""   # will prompt (not stored)
JENKINS_JOB_NAME="blue-green-pipeline"
# ------------------------

# helper prints
info(){ echo -e "\e[1;34m[INFO]\e[0m $*"; }
ok(){ echo -e "\e[1;32m[OK]\e[0m $*"; }
err(){ echo -e "\e[1;31m[ERR]\e[0m $*"; exit 1; }

# check prerequisites
for bin in terraform aws ansible kubectl jq ssh scp curl java; do
  if ! command -v $bin &>/dev/null; then
    err "Required tool '$bin' is missing. Install it and re-run the script."
  fi
done

# prompt dockerhub creds
read -p "Docker Hub username: " DOCKERHUB_USER
read -s -p "Docker Hub password (input hidden): " DOCKERHUB_PASS
echo

# 1) Terraform: init & apply (provisions EC2 + networking)
info "1) Running Terraform to provision infra (EC2 for Jenkins)..."
cd "$TERRAFORM_DIR"
terraform init -input=false
terraform apply -auto-approve -input=false
ok "Terraform apply complete."

# get jenkins public IP output
# The earlier terraform outputs used names like jenkins_public_ip or jenkins_ip.
# try common variants:
JENKINS_IP=""
for name in jenkins_public_ip jenkins_ip jenkins_public_dns jenkins_public_ip; do
  if terraform output -json 2>/dev/null | jq -e "has(\"$name\")" &>/dev/null; then
    JENKINS_IP="$(terraform output -raw $name)"
    [ -n "$JENKINS_IP" ] && break
  fi
done

if [ -z "$JENKINS_IP" ]; then
  # try outputs.tf fallback: jenkins_public_ip
  if terraform output -raw jenkins_public_ip &>/dev/null; then
    JENKINS_IP="$(terraform output -raw jenkins_public_ip)"
  fi
fi

cd - >/dev/null

if [ -z "$JENKINS_IP" ]; then
  err "Could not find Jenkins IP in Terraform outputs. Check your terraform outputs."
fi
ok "Jenkins IP: $JENKINS_IP"

# 2) Update Ansible inventory with Jenkins IP
info "2) Updating Ansible inventory..."
INVENTORY_FILE="$ANSIBLE_DIR/inventory.ini"
cat > "$INVENTORY_FILE" <<EOF
[jenkins]
$JENKINS_IP ansible_user=ubuntu ansible_ssh_private_key_file=$SSH_KEY_PATH ansible_ssh_common_args='-o StrictHostKeyChecking=no'
EOF
ok "Inventory updated: $INVENTORY_FILE"

# 3) Run Ansible playbook to configure Jenkins server
info "3) Running Ansible playbook to install Jenkins, Docker, kubectl on EC2..."
ansible-playbook -i "$INVENTORY_FILE" "$ANSIBLE_DIR/jenkins_setup.yml"
ok "Ansible playbook finished."

# 4) Wait for Jenkins to be reachable and fetch initial admin password
info "4) Waiting for Jenkins to be ready and retrieving initial admin password..."
# wait until port 8080 responds
for i in {1..30}; do
  if nc -z "$JENKINS_IP" $JENKINS_PORT &>/dev/null; then
    ok "Jenkins appears to be listening on $JENKINS_IP:$JENKINS_PORT"
    break
  fi
  info "Waiting for Jenkins... ($i/30)"
  sleep 5
done

# retrieve admin password from EC2 via SSH
info "Retrieving Jenkins initial admin password from EC2..."
JENKINS_INITIAL_PASS=$(ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" ubuntu@"$JENKINS_IP" "sudo cat /var/lib/jenkins/secrets/initialAdminPassword" || true)
if [ -z "$JENKINS_INITIAL_PASS" ]; then
  err "Unable to fetch Jenkins initial admin password. Check SSH key and that Jenkins is installed."
fi
ok "Retrieved Jenkins initial admin password."

# 5) Install recommended Jenkins plugins via CLI (git, workflow, docker, kubernetes)
info "5) Installing Jenkins CLI and plugins..."
JENKINS_CLI_JAR="/tmp/jenkins-cli.jar"
curl -sS --retry 5 "http://$JENKINS_IP:$JENKINS_PORT/jnlpJars/jenkins-cli.jar" -o "$JENKINS_CLI_JAR"
if [ ! -f "$JENKINS_CLI_JAR" ]; then
  err "Failed to download jenkins-cli.jar — Jenkins may not be ready or blocked by setup wizard."
fi

PLUGINS="git workflow-aggregator docker-workflow kubernetes pipeline-utility-steps credentials-binding configuration-as-code"
info "Installing plugins: $PLUGINS"
# wait a few seconds then attempt plugin install using CLI with admin login
java -jar "$JENKINS_CLI_JAR" -s "http://$JENKINS_IP:$JENKINS_PORT/" -auth "$JENKINS_USER:$JENKINS_INITIAL_PASS" install-plugin $PLUGINS || true
# safe restart
java -jar "$JENKINS_CLI_JAR" -s "http://$JENKINS_IP:$JENKINS_PORT/" -auth "$JENKINS_USER:$JENKINS_INITIAL_PASS" safe-restart || true
info "Plugins requested; Jenkins is restarting (may take a minute)."
sleep 30

# 6) Create DockerHub credentials in Jenkins via REST (credentials plugin must be installed)
info "6) Creating Docker Hub credentials in Jenkins via REST API..."
# get crumb
CRUMB_JSON=$(curl -s -u "$JENKINS_USER:$JENKINS_INITIAL_PASS" "http://$JENKINS_IP:$JENKINS_PORT/crumbIssuer/api/json" || true)
CRUMB=$(echo "$CRUMB_JSON" | jq -r '.crumb // empty')
if [ -z "$CRUMB" ]; then
  info "Could not fetch crumb — Jenkins might still be restarting. Waiting 20s and retrying..."
  sleep 20
  CRUMB_JSON=$(curl -s -u "$JENKINS_USER:$JENKINS_INITIAL_PASS" "http://$JENKINS_IP:$JENKINS_PORT/crumbIssuer/api/json" || true)
  CRUMB=$(echo "$CRUMB_JSON" | jq -r '.crumb // empty')
fi

if [ -z "$CRUMB" ]; then
  info "Could not retrieve Jenkins crumb. Skipping automated credential creation. You will need to add DockerHub credentials manually in Jenkins UI."
else
  # create credentials via credentials store API
  CRED_PAYLOAD=$(cat <<JSON
{
  "": "0",
  "credentials": {
    "scope": "GLOBAL",
    "id": "dockerhub-credentials",
    "username": "$DOCKERHUB_USER",
    "password": "$DOCKERHUB_PASS",
    "description": "Docker Hub credentials for pushing images",
    "\$class": "com.cloudbees.plugins.credentials.impl.UsernamePasswordCredentialsImpl"
  }
}
JSON
)
  curl -s -u "$JENKINS_USER:$JENKINS_INITIAL_PASS" -H "Jenkins-Crumb:$CRUMB" -H "Content-Type:application/json" -X POST "http://$JENKINS_IP:$JENKINS_PORT/credentials/store/system/domain/_/createCredentials" --data-raw "$CRED_PAYLOAD" || true
  ok "Requested Jenkins to create Docker Hub credentials (id: dockerhub-credentials)."
fi

# 7) Create EKS cluster (optional)
# if [ "$CREATE_EKS" = true ]; then
#   info "7) Creating EKS cluster with eksctl (this may take 8-15 minutes)..."
#   eksctl create cluster --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" --nodes 2 --node-type t3.medium --nodegroup-name lab-nodes
#   ok "EKS cluster created."
# fi

# 8) Ensure kubeconfig is present and copy to Jenkins EC2
info "8) Setting up kubeconfig for Jenkins user on EC2..."
# local kubeconfig path
LOCAL_KUBECONFIG="$HOME/.kube/config"
if [ ! -f "$LOCAL_KUBECONFIG" ]; then
  # attempt to update kubeconfig for created cluster
  if [ "$CREATE_EKS" = true ]; then
    aws eks update-kubeconfig --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION"
  else
    err "No kubeconfig found locally. Please ensure kubectl configured to talk to your cluster."
  fi
fi

# copy kubeconfig to Jenkins user (place under /var/lib/jenkins/.kube/config)
scp -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" "$LOCAL_KUBECONFIG" ubuntu@"$JENKINS_IP":/tmp/kubeconfig
ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" ubuntu@"$JENKINS_IP" "sudo mkdir -p /var/lib/jenkins/.kube && sudo mv /tmp/kubeconfig /var/lib/jenkins/.kube/config && sudo chown -R jenkins:jenkins /var/lib/jenkins/.kube && sudo chmod 644 /var/lib/jenkins/.kube/config"
ok "Kubeconfig copied to Jenkins user."

# 9) Apply Kubernetes manifests (namespace + blue/green + service)
info "9) Deploying k8s manifests (namespace, blue & green deployments, service)..."
kubectl apply -f "$APP_DIR/k8s/namespace.yaml"
kubectl apply -f "$APP_DIR/k8s/deployment-blue.yaml"
kubectl apply -f "$APP_DIR/k8s/deployment-green.yaml"
kubectl apply -f "$APP_DIR/k8s/service.yaml"
ok "Kubernetes manifests applied."

# wait for pods to be ready
info "Waiting for pods to become ready..."
kubectl -n blue-green rollout status deployment/myapp-blue --timeout=180s || true
kubectl -n blue-green rollout status deployment/myapp-green --timeout=180s || true
ok "Deployments rolled out (or timed out)."

# 10) Create Jenkins pipeline job via REST (if plugins available)
info "10) Creating Jenkins pipeline job from Jenkinsfile in repo..."
# job config xml payload (pipeline job that uses pipeline script from SCM)
JOB_CONFIG_XML="<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin='workflow-job@2.40'>
  <description>Blue-Green Pipeline job</description>
  <keepDependencies>false</keepDependencies>
  <properties/>
  <definition class='org.jenkinsci.plugins.workflow.cps.CpsScmFlowDefinition' plugin='workflow-cps@2.1036'>
    <scm class='hudson.plugins.git.GitSCM' plugin='git@4.11.3'>
      <configVersion>2</configVersion>
      <userRemoteConfigs>
        <hudson.plugins.git.UserRemoteConfig>
          <url>$(git rev-parse --show-toplevel | sed "s|$HOME/||" >/dev/null 2>&1 || true)</url>
        </hudson.plugins.git.UserRemoteConfig>
      </userRemoteConfigs>
      <branches>
        <hudson.plugins.git.BranchSpec>
          <name>*/main</name>
        </hudson.plugins.git.BranchSpec>
      </branches>
      <doGenerateSubmoduleConfigurations>false</doGenerateSubmoduleConfigurations>
      <submoduleCfg class='list'/>
      <extensions/>
    </scm>
    <scriptPath>Jenkinsfile</scriptPath>
    <lightweight>true</lightweight>
  </definition>
  <triggers/>
</flow-definition>"

# The above job creation using SCM URL requires a proper repo URL - we'll create a simple pipeline job that triggers a remote job which pulls from local workspace.
# Simpler approach: create a freestyle job that runs a shell to trigger kubectl/update; but we want pipeline from SCM. Ask user to set job manually if creation fails.

# Try to create job via REST if crumb available
if [ -n "$CRUMB" ]; then
  # Update job XML with your repo URL (prompt)
  read -p "Enter GitHub repo HTTPS URL (e.g. https://github.com/your-org/your-repo.git) to create Jenkins pipeline job automatically: " GIT_REPO_URL
  JOB_CONFIG_XML=$(cat <<XML
<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job">
  <description>Blue-Green pipeline (auto-created)</description>
  <keepDependencies>false</keepDependencies>
  <properties/>
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsScmFlowDefinition">
    <scm class="hudson.plugins.git.GitSCM">
      <configVersion>2</configVersion>
      <userRemoteConfigs>
        <hudson.plugins.git.UserRemoteConfig>
          <url>${GIT_REPO_URL}</url>
        </hudson.plugins.git.UserRemoteConfig>
      </userRemoteConfigs>
      <branches>
        <hudson.plugins.git.BranchSpec>
          <name>*/main</name>
        </hudson.plugins.git.BranchSpec>
      </branches>
    </scm>
    <scriptPath>Jenkinsfile</scriptPath>
    <lightweight>true</lightweight>
  </definition>
  <triggers/>
</flow-definition>
XML
)
  curl -s -u "$JENKINS_USER:$JENKINS_INITIAL_PASS" -H "Jenkins-Crumb:$CRUMB" -H "Content-Type:application/xml" -X POST "http://$JENKINS_IP:$JENKINS_PORT/createItem?name=$JENKINS_JOB_NAME" --data-binary "$JOB_CONFIG_XML" || true
  ok "Requested Jenkins to create job '$JENKINS_JOB_NAME'."
else
  info "No Jenkins crumb — skipping automatic job creation. Create job manually in Jenkins UI."
fi

# 11) Kick off the pipeline build (if job exists)
info "11) Triggering Jenkins job build (if created)..."
if [ -n "$CRUMB" ]; then
  curl -s -u "$JENKINS_USER:$JENKINS_INITIAL_PASS" -X POST "http://$JENKINS_IP:$JENKINS_PORT/job/$JENKINS_JOB_NAME/build" -H "Jenkins-Crumb:$CRUMB" || true
  ok "Build trigger requested for job '$JENKINS_JOB_NAME'."
else
  info "Manual step: Create pipeline job in Jenkins UI pointing to your repo's Jenkinsfile, then click 'Build Now'."
fi

# 12) Final output and verification hints
echo
ok "FULL RUN COMPLETE (best-effort)."
echo "Access Jenkins: http://$JENKINS_IP:$JENKINS_PORT"
echo "Admin username: $JENKINS_USER"
echo "Initial admin password (retrieved): $JENKINS_INITIAL_PASS"
echo
echo "Kubernetes namespace (blue-green) resources:"
kubectl -n blue-green get all || true
echo
echo "To switch traffic manually:"
echo "  kubectl patch service myapp-service -n blue-green -p '{\"spec\":{\"selector\":{\"color\":\"green\"}}}'"
echo
echo "NOTE: If any automated step fails (Jenkins plugin install, job creation) you can finish the small remaining steps in Jenkins UI."
