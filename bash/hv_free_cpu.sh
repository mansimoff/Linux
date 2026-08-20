#!/bin/bash

# Общее количество логических CPU
total_cpus=$(nproc)
echo "Всего логических CPU: $total_cpus"

# Суммарное выделение vCPU всем запущенным VM
total_vcpus=0
for vm in $(virsh list --state-running --name); do
    vcpus=$(virsh dominfo $vm | grep "CPU" | awk '{print $2}' | head -1)
    echo "VM $vm использует: $vcpus vCPU"
    total_vcpus=$((total_vcpus + vcpus))
done

echo "Всего выделено vCPU: $total_vcpus"
echo "Теоретически свободно vCPU: $((total_cpus - total_vcpus))"

# Реальная загрузка CPU
load=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)
echo "Текущая загрузка CPU: $load%"

