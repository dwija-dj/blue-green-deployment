#!/bin/bash
# full-run.sh - End-to-end automation for Blue-Green deployment lab (No EKS)
# Run from project root (~/blue-green-deployment)

set -euo pipefail
IFS=$'\n\t'

# -------- CONFIG --------
AWS_REGION="ap-south-1"
SSH_KEY_PATH="$HOME/.ssh/jenkins-key"
SSH_PUB_PATH="$HOME/.ssh/jenkins-key.pub"
TERRAFORM_DIR="terraform"
ANSIBLE_DIR="ansible"
APP_DIR="application"
JENKINS_PORT=8080
JENKINS_USER="admin"
DOCKERHUB_USER=""
DOCKERHUB_PASS=""
JENKINS_JOB_NAME="blue-green-pipeline"
# ------------------------

info(){ echo -e "\e[1;34m[INFO]\e[0m $*"; }
ok(){ echo -e "\e[1;32m[OK]\e[0m $*"; }
err(){ echo -e "\e[1;31m[ERR]\e[0m $*"; exit 1; }

# ✅ Check required tools (Removed eksctl)
for bin in terraform aws ansible kubectl ssh scp curl java; do
  if ! command -v $bin &>/dev/null; then
    err "Required tool '$bin' is missing. Install it and re-run the script."
  fi
done

# ✅ DockerHub credentials
read -p "Docker Hub username: " DOCKERHUB_USER
read -s -p "Docker Hub password (input hidden): " DOCKERHUB_PASS
echo

# ✅ Terraform (Provision EC2)
info "1) Running Terraform to provision EC2 for Jenkins..."
cd "$TERRAFORM_DIR"
terraform init -input=false
terraform apply -auto-approve -input=false
ok "Terraform infra created successfully."

# ✅ Get Jenkins IP
JENKINS_IP=$(terraform output -raw jenkins_public_ip 2>/dev/null || true)
cd - >/dev/null

if [ -z "$JENKINS_IP" ]; then
  err "Failed to fetch Jenkins IP. Check Terraform output variable names."
fi
ok "Jenkins EC2 IP: $JENKINS_IP"

# ✅ Update Ansible inventory
info "2) Updating Ansible inventory..."
INVENTORY_FILE="$ANSIBLE_DIR/inventory.ini"
cat > "$INVENTORY_FILE" <<EOF
[jenkins]
$JENKINS_IP ansible_user=ubuntu ansible_ssh_private_key_file=$SSH_KEY_PATH ansible_ssh_common_args='-o StrictHostKeyChecking=no'
EOF
ok "Inventory updated."

# ✅ Configure Jenkins via Ansible
info "3) Running Ansible playbook for Jenkins setup..."
ansible-playbook -i "$INVENTORY_FILE" "$ANSIBLE_DIR/jenkins_setup.yml"
ok "Jenkins setup completed on EC2."

# ✅ Wait for Jenkins readiness
info "4) Waiting for Jenkins to start..."
for i in {1..30}; do
  if nc -z "$JENKINS_IP" $JENKINS_PORT &>/dev/null; then
    ok "Jenkins is live at http://$JENKINS_IP:$JENKINS_PORT"
    break
  fi
  sleep 5
done

# ✅ Get Jenkins initial admin password
info "Fetching Jenkins initial admin password..."
JENKINS_INITIAL_PASS=$(ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PATH" ubuntu@"$JENKINS_IP" "sudo cat /var/lib/jenkins/secrets/initialAdminPassword" || true)
[ -z "$JENKINS_INITIAL_PASS" ] && err "Could not fetch Jenkins admin password."
ok "Retrieved Jenkins admin password."

# ✅ Install Jenkins plugins
info "5) Installing Jenkins plugins..."
JENKINS_CLI_JAR="/tmp/jenkins-cli.jar"
curl -sS "http://$JENKINS_IP:$JENKINS_PORT/jnlpJars/jenkins-cli.jar" -o "$JENKINS_CLI_JAR"
PLUGINS="git workflow-aggregator docker-workflow pipeline-utility-steps credentials-binding configuration-as-code"
# java -jar "$JENKINS_CLI_JAR" -s "http://$JENKINS_IP:$JENKINS_PORT/" -auth "$JENKINS_USER:$JENKINS_INITIAL_PASS" install-plugin $PLUGINS || true
for plugin in git workflow-aggregator docker-workflow pipeline-utility-steps credentials-binding configuration-as-code; do
    java -jar "$JENKINS_CLI_JAR" -s "http://$JENKINS_IP:$JENKINS_PORT/" -auth "$JENKINS_USER:$JENKINS_INITIAL_PASS" install-plugin "$plugin" || true
done

ok "Plugins installed."

# ✅ Jenkins restart
info "Restarting Jenkins safely..."
java -jar "$JENKINS_CLI_JAR" -s "http://$JENKINS_IP:$JENKINS_PORT/" -auth "$JENKINS_USER:$JENKINS_INITIAL_PASS" safe-restart || true
sleep 30

# ✅ Create DockerHub credentials in Jenkins
info "6) Creating DockerHub credentials in Jenkins..."
# CRUMB_JSON=$(curl -s -u "$JENKINS_USER:$JENKINS_INITIAL_PASS" "http://$JENKINS_IP:$JENKINS_PORT/crumbIssuer/api/json" || true)
# CRUMB=$(echo "$CRUMB_JSON" | jq -r '.crumb // empty')
CRUMB_JSON=$(curl -s -u "$JENKINS_USER:$JENKINS_INITIAL_PASS" "http://$JENKINS_IP:$JENKINS_PORT/crumbIssuer/api/json" || true)
CRUMB=$(echo "$CRUMB_JSON" | grep -oP '"crumb"\s*:\s*"\K[^"]+')


if [ -n "$CRUMB" ]; then
  CRED_PAYLOAD=$(cat <<JSON
{
  "": "0",
  "credentials": {
    "scope": "GLOBAL",
    "id": "dockerhub-credentials",
    "username": "$DOCKERHUB_USER",
    "password": "$DOCKERHUB_PASS",
    "description": "Docker Hub credentials for pipeline",
    "\$class": "com.cloudbees.plugins.credentials.impl.UsernamePasswordCredentialsImpl"
  }
}
JSON
)
  curl -s -u "$JENKINS_USER:$JENKINS_INITIAL_PASS" -H "Jenkins-Crumb:$CRUMB" -H "Content-Type:application/json" \
    -X POST "http://$JENKINS_IP:$JENKINS_PORT/credentials/store/system/domain/_/createCredentials" \
    --data-raw "$CRED_PAYLOAD" || true
  ok "DockerHub credentials added to Jenkins."
else
  info "Skipping automated credential creation (crumb unavailable). Add manually if needed."
fi

# ✅ Kubernetes (local or existing cluster only)
info "7) Applying Kubernetes manifests (if kubectl is configured)..."
if kubectl config current-context &>/dev/null; then
  kubectl apply -f "$APP_DIR/k8s/namespace.yaml" || true
  kubectl apply -f "$APP_DIR/k8s/deployment-blue.yaml" || true
  kubectl apply -f "$APP_DIR/k8s/deployment-green.yaml" || true
  kubectl apply -f "$APP_DIR/k8s/service.yaml" || true
  ok "Kubernetes manifests applied."
else
  info "No kubeconfig found. Skipping Kubernetes deploy."
fi

# ✅ Jenkins pipeline job (optional)
if [ -n "$CRUMB" ]; then
  read -p "Enter GitHub repo HTTPS URL (e.g., https://github.com/your/repo.git): " GIT_REPO_URL
  JOB_CONFIG_XML=$(cat <<XML
<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job">
  <description>Blue-Green pipeline job</description>
  <keepDependencies>false</keepDependencies>
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsScmFlowDefinition">
    <scm class="hudson.plugins.git.GitSCM">
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
</flow-definition>
XML
)
  curl -s -u "$JENKINS_USER:$JENKINS_INITIAL_PASS" \
    -H "Jenkins-Crumb:$CRUMB" -H "Content-Type:application/xml" \
    -X POST "http://$JENKINS_IP:$JENKINS_PORT/createItem?name=$JENKINS_JOB_NAME" \
    --data-binary "$JOB_CONFIG_XML" || true
  ok "Pipeline job '$JENKINS_JOB_NAME' created."
fi

# ✅ Summary
ok "ALL TASKS COMPLETE!"
echo "-----------------------------------------------------------"
echo "Jenkins URL:     http://$JENKINS_IP:$JENKINS_PORT"
echo "Username:        $JENKINS_USER"
echo "Admin Password:  $JENKINS_INITIAL_PASS"
echo
echo "To check pods (if local cluster configured):"
echo "  kubectl -n blue-green get pods"
echo
echo "To manually switch service traffic:"
echo "  kubectl patch service myapp-service -n blue-green -p '{\"spec\":{\"selector\":{\"color\":\"green\"}}}'"
echo "-----------------------------------------------------------"
