#!/bin/bash
# Simple script to generate test logs for CloudWatch Agent testing

LOG_FILE="/tmp/tempLogs"

echo "Starting log generation to ${LOG_FILE}..."

# Create initial log entry
echo "$(date '+%Y-%m-%d %H:%M:%S') - Log generation started" >> "${LOG_FILE}"

# Generate logs every 10 seconds
counter=1
while true; do
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Test log entry #${counter}" >> "${LOG_FILE}"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - CloudWatch Agent test message: Hello from k3ipv6test" >> "${LOG_FILE}"
    counter=$((counter + 1))
    sleep 10
done
