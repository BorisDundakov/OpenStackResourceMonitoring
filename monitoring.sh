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

