# Installs the SoftLayer CLI
#pip install --upgrade pip
#pip install softlayer

. ./deploy-kubernetes.cfg

# Authenticates to SL
echo "[softlayer]" > ~/.softlayer
echo "username = $USER" >> ~/.softlayer
echo "api_key = $API_KEY" >> ~/.softlayer
echo "endpoint_url = https://api.softlayer.com/xmlrpc/v3.1/" >> ~/.softlayer
echo "timeout = 0" >> ~/.softlayer

echo Using the following SoftLayer configuration
slcli config show

# Creates the kube master
TEMP_FILE=/tmp/destroy_kubernetes.out
slcli vs list --domain $DOMAIN > $TEMP_FILE
for id in `cat $TEMP_FILE | awk '{print $1}'`
do
   echo Deleting server $id
   echo $id | slcli vs cancel $id
done




