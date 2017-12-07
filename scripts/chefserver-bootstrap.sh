#!/bin/bash -xe
export PATH=$PATH:/usr/local/bin

PROTOCOL='https://'
FQDN=`grep 'fqdn' /tmp/chefautomate.txt | sed 's/fqdn://g'`
TEMP_URL=${PROTOCOL}${FQDN}/data-collector/v0/
ROOT_URL=`echo $TEMP_URL | sed 's/\"//gi' | sed 's/^h/\"h/gi' | sed 's/\/$/\/\"/gi'`
OLDHOST=`curl http://169.254.169.254/latest/meta-data/public-hostname` 

function update_chef_fqdn() {
    sleep 10
    service nscd restart
    HOST=`curl http://169.254.169.254/latest/meta-data/public-hostname`
    echo "OLD: ${OLDHOST}"
    echo "NEW: ${HOST}"
    echo "api_fqdn $HOST" | sudo tee -a /etc/chef-marketplace/marketplace.rb

    #Update config files with the new Elastic IP
    sed "s/${OLDHOST}/${HOST}/" /etc/opscode/chef-server.rb > /etc/opscode/chef-server.rb-new
    mv /etc/opscode/chef-server.rb-new /etc/opscode/chef-server.rb

    sed "s/${OLDHOST}/${HOST}/" /etc/motd > /etc/motd-new
    mv /etc/motd-new /etc/motd

    hnLine=`grep -n 'frontend_url' /var/opt/chef-marketplace/biscotti/etc/config.yml | awk {'print $1'} | sed 's/\://'`
    hnLineNum=`echo "$hnLine + 0" | bc`
    sed "s/${OLDHOST}/${HOST}/" /var/opt/chef-marketplace/biscotti/etc/config.yml > /var/opt/chef-marketplace/biscotti/etc/config.yml-new
    mv /var/opt/chef-marketplace/biscotti/etc/config.yml-new /var/opt/chef-marketplace/biscotti/etc/config.yml

    sed "s/${OLDHOST}/${HOST}/" /var/opt/chef-marketplace/biscotti/etc/config.yml > /var/opt/chef-marketplace/biscotti/etc/config.yml-new
    mv /var/opt/chef-marketplace/biscotti/etc/config.yml-new /var/opt/chef-marketplace/biscotti/etc/config.yml

    sed "s/${OLDHOST}/${HOST}/" /etc/delivery/delivery.rb > /etc/delivery/delivery.rb-new
    mv /etc/delivery/delivery.rb-new /etc/delivery/delivery.rb

    sed "s/${OLDHOST}/${HOST}/" /var/opt/chef-marketplace/reckoner/etc/reckoner.rb > /var/opt/chef-marketplace/reckoner/etc/reckoner.rb-new
    mv /var/opt/chef-marketplace/reckoner/etc/reckoner.rb-new /var/opt/chef-marketplace/reckoner/etc/reckoner.rb

    sed "s/${OLDHOST}/${HOST}/" /opt/chef-marketplace/embedded/service/reckoner/conf/reckoner.rb > /opt/chef-marketplace/embedded/service/reckoner/conf/reckoner.rb-new
    mv /opt/chef-marketplace/embedded/service/reckoner/conf/reckoner.rb-new /opt/chef-marketplace/embedded/service/reckoner/conf/reckoner.rb
   
    #Reconfigure and restart backend sevices.
    chef-marketplace-ctl hostname $HOST
    chef-marketplace-ctl stop biscotti
    chef-marketplace-ctl start biscotti
    automate-ctl reconfigure
    chef-server-ctl reconfigure
    automate-ctl restart
    chef-server-ctl restart
    chef-server-ctl restart nginx

    if [ $? -eq 0 ]; then
        echo "Successfully updated Chef Automate Services updated."
    else
        echo "An error occured."
        exit 1
    fi
    echo "${FUNCNAME[0]} Ended"
}


function request_eip() {
    export Region=`curl http://169.254.169.254/latest/meta-data/placement/availability-zone | rev | cut -c 2- | rev`

    #Check if EIP already assigned.
    ALLOC=1
    ZERO=0
    INSTANCE_IP=`ifconfig -a | grep inet | awk {'print $2'} | sed 's/addr://g' | head -1`
    ASSIGNED=$(aws ec2 describe-addresses --region $Region --output text | grep $INSTANCE_IP | wc -l)
    if [ "$ASSIGNED" -gt "$ZERO" ]; then
        echo "Already assigned an EIP."
    else
        aws ec2 describe-addresses --region $Region --output text > /query.txt
        #Ensure we are only using EIPs from our Stack
        line=`curl http://169.254.169.254/latest/user-data/ | grep EIP | sed 's/EIP=//g'`
        IFS=$':' DIRS=(${line//$','/:})       # Replace comma with colons.
        for (( i=0 ; i<${#DIRS[@]} ; i++ )); do
            EIP=`echo ${DIRS[i]} | sed 's/\"//g'`
            echo "$i: $EIP"
            if [ "$EIP" != "" ]; then
                #echo "$i: $EIP"
                grep "$EIP" /query.txt >> /query2.txt;
            fi
        done
        mv /query2.txt /query.txt


        AVAILABLE_EIPs=`cat /query.txt | wc -l`

        if [ "$AVAILABLE_EIPs" -gt "$ZERO" ]; then
            FIELD_COUNT="5"
            INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
            echo "Running associate_eip_now"
            while read name;
            do
                #EIP_ENTRY=$(echo $name | grep eip | wc -l)
                EIP_ENTRY=$(echo $name | grep eni | wc -l)
                echo "EIP: $EIP_ENTRY"
                if [ "$EIP_ENTRY" -eq 1 ]; then
                    echo "Already associated with an instance"
                    echo ""
                else
                    export EIP=`echo "$name" | sed 's/[\s]+/,/g' | awk {'print $4'}`
                    EIPALLOC=`echo $name | awk {'print $2'}`
                    echo "NAME: $name"
                    echo "EIP: $EIP"
                    echo "EIPALLOC: $EIPALLOC"
                    aws ec2 associate-address --instance-id $INSTANCE_ID --allocation-id $EIPALLOC --region $Region
                fi
            done < /query.txt
        else
            echo "[ERROR] No Elastic IPs available in this region"
            exit 1
        fi

        INSTANCE_IP=`ifconfig -a | grep inet | awk {'print $2'} | sed 's/addr://g' | head -1`
        ASSIGNED=$(aws ec2 describe-addresses --region $Region --output text | grep $INSTANCE_IP | wc -l)
        if [ "$ASSIGNED" -eq 1 ]; then
            echo "EIP successfully assigned."
            #Update the FQDN in chef with the new EIP
            echo "Updating Chef FQDN to reflect the new EIP address"
            update_chef_fqdn
        else
            #Retry
            while [ "$ASSIGNED" -eq "$ZERO" ]
            do
                sleep 3
                request_eip
                INSTANCE_IP=`ifconfig -a | grep inet | awk {'print $2'} | sed 's/addr://g' | head -1`
                ASSIGNED=$(aws ec2 describe-addresses --region $Region --output text | grep $INSTANCE_IP | wc -l)
            done
        fi
    fi

    echo "${FUNCNAME[0]} Ended"
}

function call_request_eip() {
    Region=`curl http://169.254.169.254/latest/meta-data/placement/availability-zone | rev | cut -c 2- | rev`
    ZERO=0
    INSTANCE_IP=`ifconfig -a | grep inet | awk {'print $2'} | sed 's/addr://g' | head -1`
    ASSIGNED=$(aws ec2 describe-addresses --region $Region --output text | grep $INSTANCE_IP | wc -l)
    if [ "$ASSIGNED" -gt "$ZERO" ]; then
        echo "Already assigned an EIP."
    else
        WAIT=$(shuf -i 1-30 -n 1)
        sleep "$WAIT"
        request_eip
    fi

    echo "${FUNCNAME[0]} Ended"
}

call_request_eip

