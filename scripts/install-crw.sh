declare -r SCRIPT_DIR=$(cd -P $(dirname $0) && pwd)

declare TARGET_PROJECT="codeready"

# Install codeready
oc new-project $TARGET_PROJECT

# cat <<EOF | oc apply -n $TARGET_PROJECT -f -
# apiVersion: operators.coreos.com/v1alpha2
# kind: OperatorGroup
# metadata:
#   name: che-operator-group
#   namespace: codeready
#   generateName: che-
#   annotations:
#     olm.providedAPIs: CheCluster.v1.org.eclipse.che
# spec:
#   targetNamespaces:
#   - codeready
# EOF

echo "Installing CodeReady Workspace Operator Subscription"
cat <<EOF | oc apply -n $TARGET_PROJECT -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: codeready-workspaces
spec:
  channel: latest
  installPlanApproval: Automatic
  name: codeready-workspaces
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  startingCSV: crwoperator.v2.3.0
EOF

# Wait for checluster to be a thing
echo "Waiting for CheCluster CRDs"
while [ true ] ; do
  if [ "$(oc explain checluster)" ] ; then
    break
  fi
  echo -n .
  sleep 10
done

echo "Creating the CodeReady Workspace"
cat <<EOF | oc apply -n $TARGET_PROJECT -f -
apiVersion: org.eclipse.che/v1
kind: CheCluster
metadata:
  name: codeready-workspaces
spec:
  server:
    cheFlavor: codeready
    tlsSupport: true
    selfSignedCert: false
    serverMemoryRequest: '2Gi'
    serverMemoryLimit: '6Gi'
  database:
    externalDb: false
    chePostgresHostName: ''
    chePostgresPort: ''
    chePostgresUser: ''
    chePostgresPassword: ''
    chePostgresDb: ''
  auth:
    openShiftoAuth: true
    externalKeycloak: false
    keycloakURL: ''
    keycloakRealm: ''
    keycloakClientId: ''
  storage:
    pvcStrategy: per-workspace
    pvcClaimSize: 1Gi
    preCreateSubPaths: true
    # postgresPVCStorageClassName: ibmc-block-gold
    # workspacePVCStorageClassName: ibmc-block-gold
EOF

# get routing suffix
HOSTNAME_SUFFIX=$(oc whoami --show-server | sed "s#https://api.\([^:]*\):6443#apps.\1#g")
echo "Hostname suffix is ${HOSTNAME_SUFFIX}"

# Wait for che to be up by calling external URL of readiness check
echo "Waiting for Che to come up (at http://codeready-${TARGET_PROJECT}.${HOSTNAME_SUFFIX}/api/system/state/)..."
while [ 1 ]; do
  STAT=$(curl -L -s -w '%{http_code}' -o /dev/null http://codeready-${TARGET_PROJECT}.${HOSTNAME_SUFFIX}/api/system/state/)
  if [ "$STAT" = 200 ] ; then
    break
  fi
  echo -n .
  sleep 10
done

# # Import stack definition
# echo "Getting token"
# SSO_CHE_TOKEN=$(curl -s -d "username=admin&password=admin&grant_type=password&client_id=admin-cli" \
#   -X POST http://keycloak-${TARGET_PROJECT}.${HOSTNAME_SUFFIX}/auth/realms/codeready/protocol/openid-connect/token | \
#   jq  -r '.access_token')

# echo "Installing Workspace (${SCRIPT_DIR}/inventory-workspace-maven.json) at: http://codeready-${TARGET_PROJECT}.${HOSTNAME_SUFFIX}/api/stack"
# curl -X POST --header 'Content-Type: application/json' --header 'Accept: application/json' \
#     --header "Authorization: Bearer ${SSO_CHE_TOKEN}" -d @${SCRIPT_DIR}/inventory-workspace-maven.json \
#     "http://codeready-${TARGET_PROJECT}.${HOSTNAME_SUFFIX}/api/workspace/devfile"