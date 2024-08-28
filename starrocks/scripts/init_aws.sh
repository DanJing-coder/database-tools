      
#!/bin/bash

export PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin:/root/bin
clear
echo -e "\n\033[36mStep 1: Initializing script and check root privilege\033[0m"
if [ "$(id -u)" = "0" ];then
	echo -e "\033[33mIs running, please wait!\033[0m"
        yum install -y parted > /dev/null 2>&1
        yum install -y e2fsprogs > /dev/null 2>&1
	echo -e "\033[32mSuccess, the script is ready to be installed!\033[0m"
else
	echo -e "\033[31mError, this script must be run as root!\n\033[0m"
	exit 1
fi
echo -e "\n\033[36mStep 2: Show all active disks:\033[0m"
Disks=$(fdisk -l 2>/dev/null | grep -o -E "/dev/nvme[0-9]n1|/dev/xvd[a-z]|/dev/sd[a-z]" | grep -v -E "/dev/nvme0n1|/dev/xvda|/dev/sda")
echo -e "\n\033[36mStep 3: The disk is partitioning and formatting\033[0m"
echo -e "\033[33mIs running, please wait!\033[0m"
fdisk_mkfs() {
parted $1 << EOF
mklabel gpt
mkpart primary 1 100%
align-check optimal 1
print
quit
EOF
partprobe
sleep 2
mkfs.ext4 $2
}

SPOT=1
echo ${Disks}
for disk in ${Disks}
do
    if [[ ${disk} =~ "/dev/nvme*" ]];then
        partition=${disk}p1
    else
        partition=${disk}1
    fi
    fdisk_mkfs ${disk} ${partition} > /dev/null 2>&1
    echo -e "\033[32mSuccess, the disk has been partitioned and formatted!\033[0m"
    echo -e "\n\033[36mStep 5: Make a directory and mount it\033[0m"
    mkdir -p /home/disk${SPOT} > /dev/null 2>&1
    mount ${partition} /home/disk${SPOT}
    echo -e "\033[32mSuccess, the mount is completed!\033[0m"
    echo -e "\n\033[36mStep 6: Write configuration to /etc/fstab and mount device\033[0m"
    UUID=$(blkid -s UUID "${parttion}" | awk '{ print $2 }' | tr -d '"')
    if [ -n "${UUID}" ]; then
    	echo "${UUID}" "/home/disk${SPOT}" 'ext4 defaults 0 0' >> /etc/fstab
    else
    	echo "${partition}" "/home/disk${SPOT}" 'ext4 defaults 0 0' >> /etc/fstab
    fi
    let SPOT++
done
echo -e "\033[32mSuccess, the /etc/fstab is Write!\033[0m"
echo -e "\n\033[36mStep 7: Show information about the file system on which each FILE resides\033[0m"
df -h
sleep 2
echo -e "\n\033[36mStep 8: Show the write configuration to /etc/fstab\033[0m"
cat /etc/fstab
echo -e "\n\033[36mStep 9: Begin to create user sr\033[0m"
cd /home/disk1

cat << EOF > password
sr@test
sr@test
EOF

useradd -d /home/disk1/sr -m sr
mkdir sr/.ssh
touch sr/.ssh/authorized_keys
chown sr:sr -R sr/.ssh
chmod 600 sr/.ssh/authorized_keys
passwd sr < password
rm password

echo 'sr ALL=(ALL) NOPASSWD:ALL' | sudo EDITOR='tee -a' visudo

echo -e "\n\033[36mStep 9: Create user sr successful.\033[0m"