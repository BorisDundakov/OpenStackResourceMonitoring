Assuming you mean the bootstrap-openstack-lab.sh script we just discussed, its purpose is to build the OpenStack lab from scratch and then configure the deployment VM to have internet access through the corporate NTLM proxy.

At a high level:

config.env
    |
    v
bootstrap-openstack-lab.sh
    |
    +--> Create OpenStack networks
    +--> Create subnets
    +--> Create router
    +--> Create security group
    +--> Create SSH keypair
    +--> Create VM ports
    +--> Create VMs
    +--> Allocate floating IP
    |
    +--> SSH into deployment VM
    |
    +--> Install CNTLM
    +--> Configure CNTLM
    +--> Configure APT proxy
    +--> Enable Docker proxy access
    |
    v
Working OpenStack lab
1. It loads your configuration

Instead of having things like:

bobi-lab-mgmnt-net
192.0.2.0/24
bobi-lab-router
m1.small

hard-coded throughout the script, it reads them from:

config.env

This means you can change the environment without changing the actual bootstrap logic.

2. It creates the OpenStack networking

It creates:

bobi-lab-mgmnt-net
    |
    +-- bobi-lab-mgmnt-subnet
        192.0.2.0/24

and:

bobi-lab-edge-net
    |
    +-- bobi-lab-edge-subnet
        192.0.3.0/24

Then it creates:

bobi-lab-router

and connects both subnets to it.

Finally, it connects the router to:

external-corporate-net

So the private networks have a path toward the external network.

3. It creates the security group

It creates your lab security group and allows:

TCP 22
ICMP

TCP 22 allows SSH access.

ICMP allows things such as:

ping <address>
4. It handles the SSH key

It uses your configured SSH key, for example:

~/.ssh/id_ed25519_bobi_lab

If necessary, the script generates the key.

It then uploads the public key to OpenStack as:

bobi-lab-key

The private key stays on your local machine.

5. It creates fixed ports for the deployment VM

Rather than simply saying:

--network bobi-lab-mgmnt-net

it creates Neutron ports with explicitly assigned IPs.

For example:

bobi-lab-mgmt-port
    192.0.2.145

and:

bobi-lab-edge-port
    192.0.3.210

The deployment VM is then attached to those ports.

This gives you predictable addressing.

6. It creates the VMs

It creates:

bobi-lab-depl-node-VM

using Ubuntu 24.04.

This is the important machine in the setup.

It also creates:

bobi-lab-host1-VM

using CirrOS.

Conceptually:

                Router
                   |
        +----------+----------+
        |                     |
 Management                Edge
 192.0.2.0/24            192.0.3.0/24
        |                     |
        +----------+----------+
                   |
          Deployment VM
        /               \
 192.0.2.145          192.0.3.210
7. It gives the deployment VM a floating IP

The script creates a floating IP from:

external-corporate-net

and attaches it to the deployment VM.

This gives you a way to SSH into the VM from outside the private OpenStack networks.

At the end, instead of making you manually run:

openstack floating ip list

the script prints something like:

Deployment node floating IP:

    10.40.112.101

SSH access:

    ssh -i ~/.ssh/id_ed25519_bobi_lab ubuntu@10.40.112.101
8. It installs CNTLM on the deployment VM

The script downloads the CNTLM .deb package locally, copies it to the deployment VM, and installs it.

Then it generates:

/etc/cntlm.conf

using the values from config.env.

The important part is:

Corporate Proxy
       ^
       |
     CNTLM
    :3128
       ^
       |
 Applications

CNTLM handles the NTLM authentication with the corporate proxy.

Therefore applications don't need to know how to authenticate against the corporate proxy themselves.

9. It configures CNTLM for Docker

This is an important part of your setup.

CNTLM listens on:

3128

rather than only:

127.0.0.1:3128

That allows Docker containers to reach it through the Docker bridge, typically:

172.17.0.1:3128

So a container can do:

Container
    |
    | HTTP_PROXY=http://172.17.0.1:3128
    v
Deployment VM
    |
    v
CNTLM :3128
    |
    v
Corporate Proxy
    |
    v
Internet
10. It configures APT

The script creates:

/etc/apt/apt.conf.d/95proxies

so that APT uses:

127.0.0.1:3128

instead of attempting to communicate directly with the corporate proxy.

So:

sudo apt update

becomes:

APT
 ↓
CNTLM
 ↓
Corporate Proxy
 ↓
Internet
11. It verifies the setup

The script doesn't simply create everything and assume it worked.

It checks things such as:

OpenStack authentication
VM creation
SSH availability
CNTLM installation
CNTLM service status
CNTLM listening on port 3128

If everything succeeds, it prints the connection information and points you back to README.md.

In one sentence

The script turns an empty OpenStack project into your complete lab environment, creates the networking and VMs, gives you SSH access through a floating IP, and configures the deployment VM as an NTLM-authenticated internet/proxy gateway for both APT and Docker.

The key design idea is that config.env describes the environment, while bootstrap-openstack-lab.sh contains the logic for building it.

#!/bin/bash
# monitor_resources.sh
# Monitors OpenStack hypervisors and aggregated resource usage
# Works even if memory_mb/vcpus are missing
# Shows running VMs, load average, and thresholds

set -e

# --- Project VM thresholds (can be customized) ---
declare -A PROJECT_VM_THRESHOLD
PROJECT_VM_THRESHOLD=( ["dev"]=3 ["prod"]=10 )

# --- Colors for CLI ---
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
RESET="\e[0m"

echo -e "\n🖥️  OpenStack Hypervisor Resource Monitoring"
echo "===========================================\n"

# ----------- Step 1: Aggregated Hypervisor Stats -----------
STATS_JSON=$(openstack hypervisor stats show -f json)

MEM_TOTAL=$(echo "$STATS_JSON" | jq '.memory_mb // 0')
MEM_USED=$(echo "$STATS_JSON" | jq '.memory_mb_used // 0')
VCPU_TOTAL=$(echo "$STATS_JSON" | jq '.vcpus // 0')
VCPU_USED=$(echo "$STATS_JSON" | jq '.vcpus_used // 0')
RUNNING_VMS=$(echo "$STATS_JSON" | jq '.running_vms // 0')

if [[ "$MEM_TOTAL" -eq 0 ]]; then MEM_PERCENT="N/A"; else MEM_PERCENT=$(awk "BEGIN {printf \"%.1f\", ($MEM_USED/$MEM_TOTAL)*100}"); fi
if [[ "$VCPU_TOTAL" -eq 0 ]]; then VCPU_PERCENT="N/A"; else VCPU_PERCENT=$(awk "BEGIN {printf \"%.1f\", ($VCPU_USED/$VCPU_TOTAL)*100}"); fi

echo -e "Aggregated Stats Across All Hypervisors:"
echo "Memory: $MEM_USED MB / $MEM_TOTAL MB ($MEM_PERCENT%)"
echo "VCPUs: $VCPU_USED / $VCPU_TOTAL ($VCPU_PERCENT%)"
echo "Running VMs: $RUNNING_VMS"

# Compare running VMs to thresholds
for PROJECT in "${!PROJECT_VM_THRESHOLD[@]}"; do
    THRESHOLD=${PROJECT_VM_THRESHOLD[$PROJECT]}
    if (( RUNNING_VMS >= THRESHOLD )); then
        echo -e "${RED}⚠️  Running VMs exceed threshold for $PROJECT ($RUNNING_VMS >= $THRESHOLD)${RESET}"
    else
        echo -e "${GREEN}✅ Running VMs for $PROJECT are OK ($RUNNING_VMS / $THRESHOLD)${RESET}"
    fi
done

# ----------- Step 2: Per-Hypervisor Stats -----------
HYPERVISORS=$(openstack hypervisor list -f value -c "Hypervisor Hostname")

if [[ -z "$HYPERVISORS" ]]; then
    echo -e "\n⚠️  No hypervisors found"
    exit 0
fi

echo -e "\nPer-Hypervisor Stats:"
for HYPER in $HYPERVISORS; do
    INFO_JSON=$(openstack hypervisor show "$HYPER" -f json)
    
    MEM_TOTAL=$(echo "$INFO_JSON" | jq '.memory_mb // 0')
    MEM_USED=$(echo "$INFO_JSON" | jq '.memory_mb_used // 0')
    VCPU_TOTAL=$(echo "$INFO_JSON" | jq '.vcpus // 0')
    VCPU_USED=$(echo "$INFO_JSON" | jq '.vcpus_used // 0')
    RUNNING_VMS=$(echo "$INFO_JSON" | jq '.running_vms // 0')
    LOAD_AVG=$(echo "$INFO_JSON" | jq -r '.load_average // "0,0,0"')

    if [[ "$MEM_TOTAL" -eq 0 ]]; then MEM_PERCENT="N/A"; else MEM_PERCENT=$(awk "BEGIN {printf \"%.1f\", ($MEM_USED/$MEM_TOTAL)*100}"); fi
    if [[ "$VCPU_TOTAL" -eq 0 ]]; then VCPU_PERCENT="N/A"; else VCPU_PERCENT=$(awk "BEGIN {printf \"%.1f\", ($VCPU_USED/$VCPU_TOTAL)*100}"); fi

    # Parse load average
    read LOAD_1 LOAD_5 LOAD_15 <<<$(echo $LOAD_AVG | tr ',' ' ')

    echo -e "\nHypervisor: $HYPER"
    echo "Memory: $MEM_USED / $MEM_TOTAL ($MEM_PERCENT%)"
    echo "VCPUs: $VCPU_USED / $VCPU_TOTAL ($VCPU_PERCENT%)"
    echo "Running VMs: $RUNNING_VMS"
    echo "Load Average: $LOAD_1 (1 min), $LOAD_5 (5 min), $LOAD_15 (15 min)"

    # Running VMs thresholds
    for PROJECT in "${!PROJECT_VM_THRESHOLD[@]}"; do
        THRESHOLD=${PROJECT_VM_THRESHOLD[$PROJECT]}
        if (( RUNNING_VMS >= THRESHOLD )); then
            echo -e "${RED}⚠️  Running VMs exceed threshold for $PROJECT ($RUNNING_VMS >= $THRESHOLD)${RESET}"
        else
            echo -e "${GREEN}✅ Running VMs for $PROJECT are OK ($RUNNING_VMS / $THRESHOLD)${RESET}"
        fi
    done

    # Optional: warn if load > 70% of vCPUs (if available)
    if [[ "$VCPU_TOTAL" -gt 0 ]]; then
        CPU_LOAD_PERCENT=$(awk "BEGIN {printf \"%.0f\", ($LOAD_1/$VCPU_TOTAL)*100}")
        if (( CPU_LOAD_PERCENT > 70 )); then
            echo -e "${RED}⚠️  High CPU load: $CPU_LOAD_PERCENT% of total vCPUs${RESET}"
        else
            echo -e "${GREEN}✅ CPU load OK: $CPU_LOAD_PERCENT% of total vCPUs${RESET}"
        fi
    fi
done
I mean this oen

Yes — this is a different script. This one is an OpenStack infrastructure monitoring script, not part of the lab bootstrap.

Its purpose is to periodically/manually inspect the resource utilization of OpenStack compute nodes (hypervisors) and print warnings when resources or VM counts become high.

What it does

The script has essentially two levels of monitoring:

OpenStack Cloud
      |
      +-----------------------+
      |                       |
      v                       v
Aggregated statistics    Per-hypervisor statistics
      |                       |
      |                       +-- Memory
      |                       +-- VCPUs
      |                       +-- Running VMs
      |                       +-- Load average
      |
      +-- Total memory
      +-- Used memory
      +-- Total VCPUs
      +-- Used VCPUs
      +-- Running VMs
1. Gets overall OpenStack resource usage

This command:

openstack hypervisor stats show -f json

gets statistics for all hypervisors combined.

It extracts:

Total memory
Used memory
Total VCPUs
Used VCPUs
Running VMs

For example, it could produce something conceptually like:

Aggregated Stats Across All Hypervisors:
Memory: 24576 MB / 65536 MB (37.5%)
VCPUs: 8 / 24 (33.3%)
Running VMs: 7

The // 0 in:

jq '.memory_mb // 0'

means that if the OpenStack API doesn't provide the value, the script treats it as 0 rather than crashing.

That's why the script can work even when certain hypervisor fields are missing.

2. Checks VM thresholds

At the top you have:

declare -A PROJECT_VM_THRESHOLD
PROJECT_VM_THRESHOLD=( ["dev"]=3 ["prod"]=10 )

This defines thresholds:

dev  → 3 VMs
prod → 10 VMs

However, there is an important problem here:

The script does not actually determine how many VMs belong to dev or prod.

It takes the total number of running VMs:

RUNNING_VMS

and compares that same number against both thresholds.

So if there are 5 VMs:

dev  → 5 >= 3  → WARNING
prod → 5 >= 10 → OK

It does not mean that the dev project has 5 VMs.

So the variable name PROJECT_VM_THRESHOLD is somewhat misleading in the current implementation.

3. Finds all hypervisors

This command:

openstack hypervisor list -f value -c "Hypervisor Hostname"

returns the names of the compute nodes.

For example:

compute01
compute02
compute03

The script then loops over them:

for HYPER in $HYPERVISORS; do

and examines each one individually.

4. Gets statistics for every hypervisor

For each hypervisor it runs:

openstack hypervisor show "$HYPER" -f json

and extracts:

memory_mb
memory_mb_used

vcpus
vcpus_used

running_vms

load_average

So you might get:

Hypervisor: compute01
Memory: 8192 / 16384 (50.0%)
VCPUs: 4 / 8 (50.0%)
Running VMs: 3
Load Average: 2.10 (1 min), 1.80 (5 min), 1.50 (15 min)
5. Calculates memory and CPU utilization

For memory:

(MEM_USED / MEM_TOTAL) * 100

For example:

8192 / 16384 = 50%

For VCPUs:

(VCPU_USED / VCPU_TOTAL) * 100

So:

4 / 8 = 50%

If OpenStack reports zero total memory or VCPUs, it prints:

N/A

instead of attempting division by zero.

6. Displays the Linux load average

It extracts:

LOAD_AVG

and splits it into:

1-minute
5-minute
15-minute

For example:

Load Average: 2.10 (1 min), 1.80 (5 min), 1.50 (15 min)

This is useful because CPU utilization and Linux load average are not quite the same thing.

A high load average can indicate CPU contention, but can also include processes waiting on I/O.

7. Performs a CPU-load check

This part:

CPU_LOAD_PERCENT=$(awk "BEGIN {printf \"%.0f\", ($LOAD_1/$VCPU_TOTAL)*100}")

compares the 1-minute load average against the number of vCPUs.

For example:

8 vCPUs
load average = 2

gives:

2 / 8 × 100 = 25%

Then it uses:

if (( CPU_LOAD_PERCENT > 70 ))

So:

≤ 70%  → OK
> 70%  → WARNING

For example:

✅ CPU load OK: 45% of total vCPUs

or:

⚠️ High CPU load: 85% of total vCPUs
What the script is really monitoring

The important distinction is that this script monitors OpenStack compute capacity, not the individual VMs themselves.

It answers questions such as:

How much RAM does my OpenStack cloud have?

How much RAM is currently allocated?

How many vCPUs are allocated?

How many VMs are running?

Which hypervisor is becoming heavily loaded?

Is the load average high relative to the hypervisor's vCPU capacity?

So conceptually:

             OPENSTACK CLOUD
                    |
        +-----------+-----------+
        |                       |
        v                       v
   Overall usage          Individual hosts
        |                       |
        |                 +-----+-----+
        |                 |           |
        v                 v           v
   Total RAM          compute01   compute02
   Used RAM               |           |
   Total VCPU             |           |
   Used VCPU              +-----+-----+
   Running VMs                  |
                                v
                         RAM / VCPU / VMs
                         Load Average
One thing I would change

The biggest issue is this:

PROJECT_VM_THRESHOLD=( ["dev"]=3 ["prod"]=10 )

The script pretends to perform project-specific VM monitoring but doesn't actually query projects.

If the intention is:

"Warn me if project dev has more than 3 running VMs and project prod has more than 10"

then the script needs to query the servers and count them per project.

If instead the intention is simply:

"Warn me if the OpenStack cloud/hypervisor has more than X VMs"

then PROJECT_VM_THRESHOLD should be renamed to something like:

RUNNING_VM_THRESHOLD=10

and the duplicated project loop should be removed.

That would make the script considerably cleaner and more accurate.

generate an extremely short readme about this
# OpenStack Resource Monitor

`monitor_resources.sh` monitors OpenStack hypervisor resource usage and reports:

- Aggregated memory and vCPU utilization
- Total running VMs
- Per-hypervisor memory and vCPU utilization
- Per-hypervisor running VMs
- 1, 5 and 15-minute load averages
- High CPU load warnings

## Usage

Make the script executable:

    chmod +x monitor_resources.sh

Run it:

    ./monitor_resources.sh

## Requirements

- OpenStack CLI
- `jq`
- `awk`
- Valid OpenStack authentication

## Configuration

VM thresholds can be customized at the top of the script:

    PROJECT_VM_THRESHOLD=( ["dev"]=3 ["prod"]=10 )
