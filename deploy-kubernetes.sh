# set -x

KUBE_MASTER_PREFIX=kube-master-
KUBE_NODE_PREFIX=kube-node-
HOSTS=/tmp/ansible-hosts
KNOWN_HOSTS_FILE=~/.ssh/known_hosts
SSH_ID_KEY=~/.ssh/k8s_rsa.pub

# This var is not used anymore
TIMEOUT=600
PORT_SPEED=10

. ./kubernetes.cfg

# Need to determine operating system for certain SL CLI commands
PLATFORM_TYPE=$(uname)

# Set the default OS if OS is not configured
if [ -z ${OS+x} ]; then
   OS=CENTOS_LATEST_64
fi


# Set the server type
if [ $SERVER_TYPE  == "bare" ]; then
  SERVER_MESSAGE="bare metal server"
  CLI_TYPE=server
  SPEC="--size $SIZE --port-speed $PORT_SPEED --os $OS"
  STATUS_FIELD="status"
  STATUS_VALUE="ACTIVE"
else
  SERVER_MESSAGE="virtual server"
  CLI_TYPE=vs
  SPEC="--cpu $CPU --memory $MEMORY --os $OS"
  STATUS_FIELD="state"
  STATUS_VALUE="RUNNING"
fi

# Args: $1: VLAN number
function get_vlan_id {
   VLAN_ID=`slcli vlan list | grep "$1" | awk '{print $1}'`
}

# Args: $1: label $2: VLAN number
function build_vlan_arg {
  if [ -z $2 ]; then
#    if [ "${1}" == "--vlan-private" ]; then
#      VLAN_ARG="--private"
#    else
      VLAN_ARG=""
#    fi
  else
     get_vlan_id $2
     VLAN_ARG="$1 $VLAN_ID"
  fi
}

# Args: $1: name
function create_server {
  # Creates the machine
  echo -e "\n\033[32m[INFO] Creating $1 with $CPU cpu(s) and $MEMORY GB of RAM.\033[0m"
  TEMP_FILE=/tmp/create-vs.out
  build_vlan_arg "--vlan-private" $PRIVATE_VLAN
  PRIVATE_ARG=$VLAN_ARG
  build_vlan_arg "--vlan-public" $PUBLIC_VLAN
  PUBLIC_ARG=$VLAN_ARG

  echo -e "\n\033[32m[INFO] Deploying $SERVER_MESSAGE $1.\033[0m"
  echo "Command: slcli $CLI_TYPE create --hostname $1 --domain $DOMAIN $SPEC --datacenter $DATACENTER --billing $BILLING_METHOD  $PRIVATE_ARG $PUBLIC_ARG"
  yes | slcli $CLI_TYPE create --hostname $1 --domain $DOMAIN $SPEC --datacenter $DATACENTER --billing $BILLING_METHOD  $PRIVATE_ARG $PUBLIC_ARG | tee $TEMP_FILE
}
slcli vm create --hostname kube-playground-ed --domain softlayer.com --cpu 8 --memory 8192 --os UBUNTU_LATEST_64 --datacenter lon02 --billing hourly --vlan-private 524954 --vlan-public 524956

# Args: $1: name
function get_server_id {
  echo -e "\n\033[32m[INFO] Getting VS_ID of $1.$DOMAIN.\033[0m"

  # Extract virtual server ID
  echo "Command: slcli $CLI_TYPE list --hostname $1 --domain $DOMAIN | grep $1 > $TEMP_FILE"
  slcli $CLI_TYPE list --hostname $1 --domain $DOMAIN | grep $1 > $TEMP_FILE

  # Consider only the first returned result
  VS_ID=`head -1 $TEMP_FILE | awk '{print $1}'`
}


# Args: $1: name
function create_kube {
  # Check whether kube master exists
  TEMP_FILE=/tmp/deploy-kubernetes.out
  echo -e "\n\033[32m[INFO] Checking whether kube master exists.\033[0m"
  slcli $CLI_TYPE list --hostname $1 --domain $DOMAIN | grep $1 > $TEMP_FILE
  COUNT=`wc $TEMP_FILE | awk '{print $1}'`

  # Determine whether to create the kube-master
  if [ $COUNT -eq 0 ]; then
    create_server $1
  else
    echo -e "\n\033[32m[INFO] $1 is already created.\033[0m"
  fi

  # Wait kube master to be ready
  while true; do
    echo -e "\033[32m[INFO] Waiting for $SERVER_MESSAGE $1 to be ready.\033[0m"
    get_server_id $1
    echo "Command: slcli $CLI_TYPE detail $VS_ID | grep $STATUS_FIELD | awk '{print $2}'"
    STATE=`slcli $CLI_TYPE detail $VS_ID | grep $STATUS_FIELD | awk '{print $2}'`
    if [ "$STATE" == "$STATUS_VALUE" ]; then
      break
    else
      sleep 5
    fi
  done
}

# Arg $1: hostname
function obtain_root_pwd {
  unset PASSWORD
  get_server_id $1

  while [ -z $PASSWORD ]; do
    echo -e "\n\033[32m[INFO] Obtaining root password for $1.\033[0m"

    # Obtain the root password
    echo "Command: slcli $CLI_TYPE detail $VS_ID --passwords > $TEMP_FILE"
    slcli $CLI_TYPE detail $VS_ID --passwords > $TEMP_FILE

    # Remove "remote users"
    # it seems that for Ubuntu it's print $4; however, for Mac, it's print $3
    if [ $SERVER_TYPE == "bare" ]; then
      PASSWORD=`grep root $TEMP_FILE | grep -v "remote users" | awk '{print $3}'`
    elif [ $PLATFORM_TYPE == "Linux" ] || [ $FORCE_LINUX == "true" ]; then
      PASSWORD=`grep root $TEMP_FILE | grep -v "remote users" | awk '{print $4}'`
    elif [ $PLATFORM_TYPE == "Darwin" ]; then
      PASSWORD=`grep root $TEMP_FILE | grep -v "remote users" | awk '{print $3}'`
    fi
  done
  echo PASSWORD $PASSWORD
}

# Args $1: hostname
function obtain_ip {
  echo -e "\n\033[32m[INFO] Obtaining IP address for $1.\033[0m"
  get_server_id $1

  echo -e "\n\033[32m[INFO] Server: $VS_ID.\033[0m"
  echo "Command: slcli $CLI_TYPE detail $VS_ID --passwords > $TEMP_FILE"
  # Obtain the IP address
  slcli $CLI_TYPE detail $VS_ID --passwords > $TEMP_FILE

  if [ $CONNECTION  == "VPN" ]; then
    IP_ADDRESS=`grep private_ip $TEMP_FILE | awk '{print $2}'`
  else
    IP_ADDRESS=`grep public_ip $TEMP_FILE | awk '{print $2}'`
  fi
}

# From the standpoint of ansible, kube-master-2 is a 'node'
function update_hosts_file {
  # Update ansible hosts file
  echo -e "\n\033[32m[INFO] Updating ansible hosts files.\033[0m"
  echo > $HOSTS
  echo "[kube-master]" >> $HOSTS

  obtain_ip ${KUBE_MASTER_PREFIX}1
  MASTER1_IP=$IP_ADDRESS
  echo "kube-master-1 ansible_host=$IP_ADDRESS ansible_user=root" >> $HOSTS

  echo "[kube-node]" >> $HOSTS
  ## Echoes in the format of "kube-node-1 ansible_host=$IP_ADDRESS ansible_user=root" >> $HOSTS
  for(( x=1; x <= ${NUM_NODES}; x++))
  do
    obtain_ip "${KUBE_NODE_PREFIX}${x}"
    export NODE${x}_IP=$IP_ADDRESS
    echo "${KUBE_NODE_PREFIX}${x} ansible_host=$IP_ADDRESS ansible_user=root" >> $HOSTS
  done
}

#Args: $1: PASSWORD, $2: IP Address
function set_ssh_key {
  #Remove entry from known_hosts
  echo -e "\n\033[32m[INFO] Finding to remove entry from known_hosts.\033[0m"
  if [ -f "$KNOWN_HOSTS_FILE" ]
  then
    echo -e "\n\033[32m[INFO] Checking host's entry after the known_hosts file is found.\033[0m"
    entry_count=`ssh-keygen -F $2 -f ${KNOWN_HOSTS_FILE} | wc -l`
    if [ $entry_count -gt 0 ]
    then
      echo -e "\n\033[32m[INFO] Removing entry from known_hosts.\033[0m"
  	  ssh-keygen -R $2 -f $KNOWN_HOSTS_FILE
  	fi
  else
    echo -e "\n\033[32m[INFO] The known_hosts file is not found.\033[0m"
  fi

  # Log in to the machine
  echo -e "\n\033[32m[INFO] Copying public key to remote.\033[0m"
  sshpass -p $1 ssh-copy-id -i $SSH_ID_KEY -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' root@$2
}

#Args: $1: master hostname $2: master IP
function configure_master {
  echo -e "\n\033[32m[INFO] Configuring master.\033[0m"

  # Get kube master password
  obtain_root_pwd $1

  # Set the SSH key
  set_ssh_key $PASSWORD $2
  
  # Create inventory file
  echo -e "\n\033[32m[INFO] Creating inventory file.\033[0m"
  INVENTORY=/tmp/inventory
  echo > $INVENTORY
  echo "[masters]" >> $INVENTORY
  echo "kube-master-1" >> $INVENTORY
  echo >> $INVENTORY
  echo "[etcd]" >> $INVENTORY
  echo "kube-master-1" >> $INVENTORY
  echo >> $INVENTORY
  echo "[nodes]" >> $INVENTORY
  ## Echoes in the format of "$NODE1_IP" >> $INVENTORY
  for(( x=1; x <= ${NUM_NODES}; x++))
  do
    TMP1=$(echo \${NODE${x}_IP})
    LOCAL_IP=$(eval echo ${TMP1})
    echo "${LOCAL_IP}" >> ${INVENTORY}
  done

  # Create ansible.cfg
  echo -e "\n\033[32m[INFO] Creating ansible.cfg.\033[0m"
  ANSIBLE_CFG=/tmp/ansible.cfg
  echo "[defaults]" > $ANSIBLE_CFG
  echo "host_key_checking = False" >> $ANSIBLE_CFG

}

#Args: $1: IP address
function install_python {
  echo -e "\n\033[32m[INFO] Installing python.\033[0m"

  # SSH to host
  ssh -o StrictHostKeyChecking=no root@$1 \
  "add-apt-repository ppa:fkrull/deadsnakes && apt-get update && apt install -y python2.7 &&"\
  " ln -fs /usr/bin/python2.7 /usr/bin/python" 

}


function configure_masters {
  configure_master ${KUBE_MASTER_PREFIX}1 $MASTER1_IP

  install_python $MASTER1_IP

  # Execute kube-master playbook
  echo -e "\n\033[32m[INFO] Executing kube-master playbook.\033[0m"
  echo "Command: ansible-playbook -v -i $HOSTS ansible/kube-master.yaml -e 'master_ip=$MASTER1_IP'"
  ansible-playbook -vvvv -i $HOSTS ansible/kube-master.yaml -e "master_ip=$MASTER1_IP"
}

# Args $1 Node name
function configure_node {
  echo -e "\n\033[32m[INFO] Configuring node $1.\033[0m"

  # Get kube master password
  obtain_root_pwd $1

  # Get master IP address
  obtain_ip $1
  NODE_IP=$IP_ADDRESS
  echo IP Address: $NODE_IP

  # Set the SSH key
  set_ssh_key $PASSWORD $NODE_IP

  install_python $NODE_IP

}

function configure_nodes {
  echo -e "\n\033[32m[INFO] Configuring nodes.\033[0m"
  for(( x=1; x <= ${NUM_NODES}; x++))
  do
    configure_node "${KUBE_NODE_PREFIX}${x}"
  done

  # Execute kube-master playbook
  ansible-playbook -v -i $HOSTS ansible/kube-node.yaml --extra-vars "master_ip=$MASTER1_IP"
}

function create_nodes {
  for(( x=1; x <= ${NUM_NODES}; x++))
  do
    create_kube "${KUBE_NODE_PREFIX}${x}"
  done
}

function create_masters {
  create_kube "${KUBE_MASTER_PREFIX}1"
}

function configure_kubectl {
   kubectl cluster-info
}

function deploy_testapp {
  rm -rf /tmp/guestbook
  mkdir /tmp/guestbook
  cd /tmp/guestbook
  git clone https://github.com/kubernetes/kubernetes.git
  cd kubernetes
  git reset --hard 6a657e0bc25eafd44fa042b079c36f8f0413d420
  kubectl create -f examples/guestbook/all-in-one/guestbook-all-in-one.yaml --validate=false
}

echo -e "\n\033[32m[INFO] Using the following SoftLayer configuration.\033[0m"
slcli config show

echo -e "\n\033[32m[INFO] Creating the vm of kubes.\033[0m"
create_masters
create_nodes

echo -e "\n\033[32m[INFO] Updating the vm of master.\033[0m"
update_hosts_file

echo -e "\n\033[32m[INFO] Configuring the vm of kubes.\033[0m"
configure_masters
configure_nodes

configure_kubectl

# deploy_testapp

echo -e "\n\033[32m[INFO] Congratulations! You can log on to the kube masters by issuing ssh root@$MASTER1_IP.\033[0m"
