#!/usr/bin/env bash

ERROR=$(tput setaf 1; echo -n "[!]"; tput sgr0)
OK=$(tput setaf 2; echo -n "[✓]"; tput sgr0)
INFO=$(tput setaf 3; echo -n "[-]"; tput sgr0)

# Global variables
LAB=
PROVIDER=
METHOD=
JOB=
PROVIDERS="virtualbox vmware azure proxmox"
LABS=$(ls -A ad/ |grep -v 'TEMPLATE')
TASKS="check install start stop status restart destroy disablevagrant enablevagrant"
METHODS="local docker"


print_usage() {
  echo "${ERROR} Usage: ./goad.sh -t task -l lab -p provider -m method"
  echo "${INFO} -t : task must be one of the following:"
  echo "   - check   : verify dependencies";
  echo "   - install : create the lab";
  echo "   - start   : start the lab";
  echo "   - stop    : stop the lab";
  echo "   - restart : reload the lab";
  echo "   - status  : show lab info and status";
  echo "   - destroy : trash the lab";
  echo "${INFO} -l : lab must be one of the following:"
  for lab in $LABS;  do
    echo "   - $lab";
  done
  echo "${INFO} -p : provider must be one of the following:"
  for p in $PROVIDERS;  do
    echo "   - $p";
  done
  echo "${INFO} -m : method must be one of the following (optional, default : local):"
  echo "   - local : to use local ansible install (default)";
  echo "   - docker : to use docker ansible install";
  echo
  echo "${OK} example: ./goad.sh -t check -l GOAD -p virtualbox -m local";
  exit 0
}

function exists_in_list() {
    LIST=$1
    VALUE=$2
    echo $LIST | tr " " '\n' | grep -F -q -x "$VALUE"
}

while getopts t:l:p:m: flag
  do
      case "${flag}" in
          t) TASK=${OPTARG};;
          l) LAB=${OPTARG};;
          p) PROVIDER=${OPTARG};;
          m) METHOD=${OPTARG};;
      esac
  done

  if exists_in_list "$TASKS" "$TASK"; then
    echo "${OK} Task: $TASK"
  else
    echo "${ERROR} Task: \"$TASK\" unknow"
    print_usage
  fi

  if exists_in_list "$LABS" "$LAB"; then
    echo "${OK} Lab: $LAB"
  else
    echo "${ERROR} Lab: $LAB not allowed"
    print_usage
  fi

  if exists_in_list "$PROVIDERS" "$PROVIDER"; then
    echo "${OK} Provider: $PROVIDER"
  else
    echo "${ERROR} Provider: $PROVIDER not allowed"
    print_usage
  fi

  if [ -z $METHOD ]; then
     METHOD="local"
  else
    if exists_in_list "$METHODS" "$METHOD"; then
      echo "${OK} Method: $METHOD"
    else
      echo "${ERROR} Method: $METHOD not allowed"
      print_usage
    fi
  fi
# check if the lab provider folder exist
if [[ -d "ad/$LAB/providers/$PROVIDER" ]]; then
   echo "${OK} folder ad/$LAB/providers/$PROVIDER found"
else
   echo "${ERROR} folder ad/$LAB/providers/$PROVIDER not found"
   exit 1
fi


print_azure_info() {
    echo -e "\n\n"
    echo "Ubuntu jumpbox IP: $public_ip"

    echo "You can now connect to the jumpbox using the following command:"
    echo "ssh -i ad/$lab/providers/$provider/ssh_keys/ubuntu-jumpbox.pem goad@$public_ip"
    echo -e "\n\n"

    echo "${OK} ssh/config :"
    echo "Host goad_azure"
    echo "    Hostname $public_ip"
    echo "    User goad"
    echo "    Port 22"
    echo "    IdentityFile $CURRENT_DIR/ad/$lab/providers/$provider/ssh_keys/ubuntu-jumpbox.pem"
}

install_providing(){
  lab=$1
  provider=$2

  case $provider in
    "virtualbox"|"vmware")
        cd "ad/$lab/providers/$provider"
        echo "${OK} launch vagrant"
        vagrant up
        result=$?
        if [ ! $result -eq 0 ]; then
          cd -
          echo "${ERROR} vagrant finish with error abort"
          exit 1
        fi
        cd -
      ;;
    "proxmox")
      if [ -d "ad/$lab/providers/$provider/terraform" ]; then
        cd "ad/$lab/providers/$provider/terraform"
        echo "${OK} Initializing Terraform..."
        terraform init

        result=$?
        if [ ! $result -eq 0 ]; then
          echo "${ERROR} terraform init finish with error abort"
          exit 1
        fi

        echo "${OK} Apply Terraform..."
        terraform apply
        result=$?
        if [ ! $result -eq 0 ]; then
          echo "${ERROR} terraform apply finish with error abort"
          exit 1
        fi

        echo "${OK} Ready to launch provisioning"
        cd -
      else
        echo "${ERROR} folder ad/$lab/providers/$provider/terraform not found"
        exit 1
      fi
      ;;
    "azure")
      if [ -d "ad/$lab/providers/$provider/terraform" ]; then
          cd "ad/$lab/providers/$provider/terraform"
          echo "${OK} Initializing Terraform..."
          terraform init

          result=$?
          if [ ! $result -eq 0 ]; then
            echo "${ERROR} terraform init finish with error abort"
            exit 1
          fi

          echo "${OK} Apply Terraform..."
          terraform apply
          result=$?
          if [ ! $result -eq 0 ]; then
            echo "${ERROR} terraform apply finish with error abort"
            exit 1
          fi

          # Get the public IP address of the VM
          echo "${OK} Getting jumpbox IP address..."
          public_ip=$(terraform output -raw ubuntu-jumpbox-ip)
          print_azure_info
          cd -

          echo "${OK} Rsync goad to jumpbox"
          rsync -a --exclude-from='.gitignore' -e "ssh -o 'StrictHostKeyChecking no' -i $CURRENT_DIR/ad/$lab/providers/$provider/ssh_keys/ubuntu-jumpbox.pem" "$CURRENT_DIR/" goad@$public_ip:~/GOAD/

          echo "${OK} Running setup script on jumpbox..."
          ssh -o "StrictHostKeyChecking no" -i "ad/$lab/providers/$provider/ssh_keys/ubuntu-jumpbox.pem" goad@$public_ip 'bash -s' <scripts/setup_azure.sh

          echo "${OK} Ready to launch provisioning"
      else
        echo "${ERROR} folder ad/$lab/providers/$provider/terraform not found"
        exit 1
      fi
      ;;
  esac
}

install_provisioning(){
  lab=$1
  provider=$2
  method=$3
  case $provider in
    "virtualbox"|"vmware"|"proxmox")
        case $method in
          "local")
              cd ansible
              export ANSIBLE_COMMAND="ansible-playbook -i ../ad/$lab/data/inventory -i ../ad/$lab/providers/$provider/inventory"
              ../scripts/provisionning.sh
              cd -
            ;;
          "docker")
              use_sudo=""
              if id -nG "$USER" | grep -qw "docker"; then
                  echo $USER belongs to docker group
              else
                  echo $USER does not belong to docker group
                  echo "${INFO} Root password could be asked for docker interaction"
                  use_sudo="sudo"
              fi

              ALREADY_BUILD=$($use_sudo docker images |grep -c "goadansible")
              if [[ $ALREADY_BUILD -eq 0 ]]; then
                echo "[+] Build container"
                $use_sudo docker build -t goadansible .
                echo "${OK} Container goadansible creation complete"
              fi
              echo "${OK} Start provisioning from docker"
              $use_sudo docker run -ti --rm --network host -h goadansible -v $(pwd):/goad -w /goad/ansible goadansible /bin/bash -c "ANSIBLE_COMMAND='ansible-playbook -i ../ad/$lab/data/inventory -i ../ad/$lab/providers/$provider/inventory' ../scripts/provisionning.sh"
            ;;
        esac
      ;;
    "azure")
          cd "ad/$lab/providers/$provider/terraform"
          public_ip=$(terraform output -raw ubuntu-jumpbox-ip)
          cd -
           case $method in
            "local")
                ssh -tt -o "StrictHostKeyChecking no" -i "$CURRENT_DIR/ad/$lab/providers/$provider/ssh_keys/ubuntu-jumpbox.pem" goad@$public_ip << EOF
                  cd /home/goad/GOAD/ansible
                  export ANSIBLE_COMMAND="ansible-playbook -i ../ad/$lab/data/inventory -i ../ad/$lab/providers/$provider/inventory"
                  ../scripts/provisionning.sh
                  exit
EOF
                print_azure_info
              ;;
            *)
              echo "${ERROR} $method install on azure not implemented, use local"
              ;;
          esac
      ;;
  esac
}

disablevagrant(){
  echo "${OK} Will disable the vagrant user (vagrant up vagrant halt will no more work, you will have to start and stop vm by hand)"
  read -r -p "Are you sure? [y/N] " response
  case "$response" in
      [yY][eE][sS]|[yY]) 
          echo "${OK} start disable vagrant user"
          ;;
      *)
          echo "abort"
          exit
          ;;
  esac
  case $PROVIDER in
    "virtualbox"|"vmware"|"proxmox")
        case $METHOD in
          "local")
              cd ansible
              ansible-playbook -i ../ad/$LAB/providers/$PROVIDER/inventory_disablevagrant disable_vagrant.yml
              cd -
            ;;
          "docker")
              use_sudo=""
              if id -nG "$USER" | grep -qw "docker"; then
                  echo $USER belongs to docker group
              else
                  echo $USER does not belong to docker group
                  echo "${INFO} Root password could be asked for docker interaction"
                  use_sudo="sudo"
              fi

              ALREADY_BUILD=$($use_sudo docker images |grep -c "goadansible")
              if [[ $ALREADY_BUILD -eq 0 ]]; then
                echo "[+] Build container"
                $use_sudo docker build -t goadansible .
                echo "${OK} Container goadansible creation complete"
              fi
              echo "${OK} Start provisioning from docker"
              $use_sudo docker run -ti --rm --network host -h goadansible -v $(pwd):/goad -w /goad/ansible goadansible /bin/bash -c "ansible-playbook -i ../ad/$LAB/providers/$PROVIDER/inventory_disablevagrant disable_vagrant.yml"
            ;;
        esac
      ;;
    "azure")
          echo "Vagrant user not used in azure, skip."
      ;;
  esac
}

enablevagrant(){
  case $PROVIDER in
    "virtualbox"|"vmware"|"proxmox")
        case $METHOD in
          "local")
              cd ansible
              ansible-playbook -i ../ad/$LAB/providers/$PROVIDER/inventory_disablevagrant enable_vagrant.yml
              cd -
            ;;
          "docker")
              use_sudo=""
              if id -nG "$USER" | grep -qw "docker"; then
                  echo $USER belongs to docker group
              else
                  echo $USER does not belong to docker group
                  echo "${INFO} Root password could be asked for docker interaction"
                  use_sudo="sudo"
              fi

              ALREADY_BUILD=$($use_sudo docker images |grep -c "goadansible")
              if [[ $ALREADY_BUILD -eq 0 ]]; then
                echo "[+] Build container"
                $use_sudo docker build -t goadansible .
                echo "${OK} Container goadansible creation complete"
              fi
              echo "${OK} Start provisioning from docker"
              $use_sudo docker run -ti --rm --network host -h goadansible -v $(pwd):/goad -w /goad/ansible goadansible /bin/bash -c "ansible-playbook -i ../ad/$LAB/providers/$PROVIDER/inventory_disablevagrant enable_vagrant.yml"
            ;;
        esac
      ;;
    "azure")
          echo "Vagrant user not used in azure, skip."
      ;;
  esac
}

install(){
  echo "${OK} Launch installation for: $LAB / $PROVIDER / $METHOD"
  cd $CURRENT_DIR
  install_providing $LAB $PROVIDER
  cd $CURRENT_DIR
  install_provisioning $LAB $PROVIDER $METHOD
}

check(){
  echo "${OK} Launch check : ./scripts/check.sh $PROVIDER $METHOD"
  ./scripts/check.sh $PROVIDER $METHOD
  check_result=$?
  if [ $check_result -eq 0 ]; then
    echo "${OK} Check is ok, you can start the installation"
  else
    echo "${ERROR} Check is not ok, please fix the errors and retry"
    echo "${INFO} You could also run the setup script"
  fi
}

start(){
  case $PROVIDER in
    "virtualbox"|"vmware")
          cd "ad/$LAB/providers/$PROVIDER"
          echo "${OK} start vms"
          vagrant up
          cd -
      ;;
    "proxmox")
      if ! which qm >/dev/null; then
        (echo >&2 "${ERROR} qm not found in your PATH")
        exit 1
      else
        if [ -d "ad/$LAB/providers/$PROVIDER/terraform" ]; then
          vms=$(cat ad/$LAB/providers/$PROVIDER/terraform/*.tf| grep -E 'name = ".*"'|cut -d '"' -f 2)
          for vm in "${vms[@]}"
          do
            id=$(qm list | grep $vm  | awk '{print $1}')
            echo "[+] VM id : $id"
            echo "[+] Starting $vm"
            qm start "$id"
          done
        else
          echo "${ERROR} folder ad/$LAB/providers/$PROVIDER/terraform not found"
          exit 1
        fi
      fi
      ;;
    "azure")
      az vm start --ids $(az vm list --resource-group $LAB --query "[].id" -o tsv)
      status
      ;;
  esac
}

stop(){
  case $PROVIDER in
    "virtualbox"|"vmware")
          cd "ad/$LAB/providers/$PROVIDER"
          echo "${OK} stop vms"
          vagrant halt
          cd -
      ;;
    "proxmox")
      if ! which qm >/dev/null; then
        (echo >&2 "${ERROR} qm not found in your PATH")
        exit 1
      else
        if [ -d "ad/$LAB/providers/$PROVIDER/terraform" ]; then
          vms=$(cat ad/$LAB/providers/$PROVIDER/terraform/*.tf| grep -E 'name = ".*"'|cut -d '"' -f 2)
          for vm in "${vms[@]}"
          do
            id=$(qm list | grep $vm  | awk '{print $1}')
            echo "[+] VM id : $id"
            echo "[+] Stopping $vm"
            qm stop "$id" && qm wait "$id"
          done
        else
          echo "${ERROR} folder ad/$LAB/providers/$PROVIDER/terraform not found"
          exit 1
        fi
      fi
      ;;
    "azure")
      az vm stop --ids $(az vm list --resource-group $LAB --query "[].id" -o tsv)
      status
      ;;
  esac
}

restart(){
  case $PROVIDER in
    "virtualbox"|"vmware")
          cd "ad/$LAB/providers/$PROVIDER"
          echo "${OK} restart start vms"
          vagrant reload
          cd -
      ;;
    "proxmox")
      if ! which qm >/dev/null; then
        (echo >&2 "${ERROR} qm not found in your PATH")
        exit 1
      else
        if [ -d "ad/$LAB/providers/$PROVIDER/terraform" ]; then
          vms=$(cat ad/$LAB/providers/$PROVIDER/terraform/*.tf| grep -E 'name = ".*"'|cut -d '"' -f 2)
          for vm in "${vms[@]}"
          do
            id=$(qm list | grep $vm  | awk '{print $1}')
            echo "[+] VM id is : $id"
            echo "[+] Stopping $vm"
            qm stop "$id" && qm wait "$id"
            echo "[+] Starting $vm"
            qm start "$id"
          done
        else
          echo "${ERROR} folder ad/$LAB/providers/$PROVIDER/terraform not found"
          exit 1
        fi
      fi
      ;;
    "azure")
      az vm restart --ids $(az vm list --resource-group $LAB --query "[].id" -o tsv)
      status
      ;;
  esac
}

destroy(){
  case $PROVIDER in
    "virtualbox"|"vmware")
          cd "ad/$LAB/providers/$PROVIDER"
          echo "${OK} destroy the lab"
          read -r -p "Are you sure? [y/N] " response
          case "$response" in
              [yY][eE][sS]|[yY]) 
                  vagrant destroy --force
                  ;;
              *)
                  echo "abort"
                  ;;
          esac
          cd -
      ;;
    "proxmox"|"azure")
      if [ -d "ad/$LAB/providers/$PROVIDER/terraform" ]; then
        cd "ad/$LAB/providers/$PROVIDER/terraform"
        echo "${OK} Destroy infrastructure..."
        terraform destroy
      else
        echo "${ERROR} folder ad/$LAB/providers/$PROVIDER/terraform not found"
        exit 1
      fi
      ;;
  esac
}

status(){
  case $PROVIDER in
    "virtualbox"|"vmware")
          cd "ad/$LAB/providers/$PROVIDER"
          vagrant status
          cd -
      ;;
    "proxmox")
      if ! which qm >/dev/null; then
        (echo >&2 "${ERROR} qm not found in your PATH")
        exit 1
      else
        if [ -d "ad/$LAB/providers/$PROVIDER/terraform" ]; then
          vms=$(cat ad/$LAB/providers/$PROVIDER/terraform/*.tf| grep -E 'name = ".*"'|cut -d '"' -f 2)
          for vm in "${vms[@]}"
          do
            qm list | grep $vm
          done
        else
          echo "${ERROR} folder ad/$LAB/providers/$PROVIDER/terraform not found"
          exit 1
        fi
      fi
      ;;
    "azure")
      az vm list -g $LAB -d --output table
      ;;
  esac
}

snapshot() {
  # TODO : snapshot
  echo "not implemeneted"
}

reset() {
  # TODO : reset to last snapshot
  echo "not implemeneted"
}

main() {
  CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  cd $CURRENT_DIR
  case $TASK in
    check)
      check
      ;;
    install)
      install
      ;;
    status)
      status
      ;;
    start)
      start
      ;;
    stop)
      stop
      ;;
    restart)
      restart
      ;;
    destroy)
      destroy
      ;;
    snapshot)
      snapshot
      ;;
    disablevagrant)
      disablevagrant
      ;;
    enablevagrant)
      enablevagrant
      ;;
    *)
      echo "unknow option"
      ;;
  esac
}

main
